//
//  MarkdownBlockSelection.swift
//  MarkdownView
//
//  Craft-style block selection over a list of selectable markdown blocks.
//  Moved from ios-flowith (Views/Components/MessageBlockSelection.swift): the touch
//  source, the state machine, range and column selection, autoscroll and the overlay.
//  The list is reached through MarkdownBlockSelectionLayout instead of MessagingUI's
//  TiledViewReader, and items are MarkdownBlockSelectionItem instead of the app's
//  MessageListItem. Marks, topics, quoting, copying, sharing and the toolbar stay in the app.
//
//   - Entry: dragging a character selection handle past the block's edge
//     (± blockModeOvershoot) switches to block mode; the same finger keeps extending a
//     contiguous range from the anchor block.
//   - In block mode: tapping a block toggles it; sliding along the dot column on the
//     right selects or deselects (the opposite of the first block's state); the list
//     scrolls normally.
//   - Mechanics:
//     - Each selectable text view registers its item through `hooks(for:)` (text views
//       are pooled, so the latest `onTextViewReady` wins).
//     - On iOS 26 the handle drag is invisible to gesture recognizers anywhere in the
//       tree; only `UIApplication.sendEvent` sees it, so it is swizzled once as the touch
//       source. It only observes and always calls the original.
//     - A handle drag is a touch that begins inside a selection endpoint's hit zone
//       (mirroring the system's hit test; the hit view is useless there).
//     - The highlight and dots are a separate overlay that reads frames from the layout.
//

#if canImport(RichText) && os(iOS)
import SwiftUI
import UIKit
import RichText

/// The list the block selection runs over, in the list's content coordinates.
/// MessagingUI's `TiledViewReader<String>` fits with a one-line conformance.
@MainActor
public protocol MarkdownBlockSelectionLayout: AnyObject {
    /// The scrolling list view (or a view containing it); touches are hit-tested against it.
    var containerView: UIView? { get }
    /// Changes whenever layout or scrolling moves items; read by the overlay to redraw.
    var layoutVersion: UInt { get }
    func contentOffsetY() -> CGFloat
    func visibleContentHeight() -> CGFloat?
    func frame(forItem id: String) -> CGRect?
    /// Frames of the items intersecting `rect`, by spatial query; never iterate every item per frame.
    func contentFrames(intersecting rect: CGRect) -> [String: CGRect]
    func scrollToContentOffsetY(_ y: CGFloat)
}

/// One row of the list, in list order.
public struct MarkdownBlockSelectionItem: Identifiable, Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// Can be selected.
        case candidate
        /// Heads a group (a message, say); the group's dot sits on it.
        case groupHeader
        /// Neither; ignored.
        case other
    }

    public let id: String
    /// Items of one group (one message) select together from the group dot.
    public let group: String
    public let role: Role

    public init(id: String, group: String, role: Role) {
        self.id = id
        self.group = group
        self.role = role
    }
}

// MARK: - Touch source at sendEvent

/// Swizzles `UIApplication.sendEvent` once and routes touches to the right controller
/// (observes, never intercepts).
///
/// A registry rather than one `active` pointer: several lists can exist at once
/// (navigation stacks, previews, a list view rebuilt by SwiftUI), and a later install
/// would steal a single pointer; once that list left the window every touch was lost.
/// Routing: a controller in block mode owns all touches (its toolbar may sit outside the
/// list); otherwise the last registered controller whose list is on the window and
/// contains the touch. A touch sequence (began → ended) sticks to one controller so a
/// finger sliding past the list's edge mid-drag keeps its events.
@MainActor
private enum BlockSelectionEventTap {
    private struct WeakBox { weak var value: MarkdownBlockSelectionController? }
    private static var registered: [WeakBox] = []
    private static weak var sequenceOwner: MarkdownBlockSelectionController?
    private static var installed = false

    /// Idempotent; registering again moves the controller to the end (most recently laid out wins).
    static func register(_ controller: MarkdownBlockSelectionController) {
        install()
        registered.removeAll { $0.value == nil || $0.value === controller }
        registered.append(WeakBox(value: controller))
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:)))!
        let swizzled = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.markdownBlockSelection_sendEvent(_:)))!
        method_exchangeImplementations(original, swizzled)
    }

    static func route(_ touches: Set<UITouch>) {
        guard !touches.isEmpty else { return }
        let hasBegan = touches.contains { $0.phase == .began }
        if hasBegan || sequenceOwner == nil || sequenceOwner?.isContainerOnWindow != true {
            sequenceOwner = pickTarget(for: touches)
        }
        guard let owner = sequenceOwner else { return }
        owner.observeTouches(touches)
        if touches.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) {
            sequenceOwner = nil
        }
    }

    private static func pickTarget(for touches: Set<UITouch>) -> MarkdownBlockSelectionController? {
        registered.removeAll { $0.value == nil }
        let candidates = registered.compactMap(\.value)
        if let modeActive = candidates.last(where: { $0.state.isActive && $0.isContainerOnWindow }) {
            return modeActive
        }
        guard let touch = touches.first(where: { $0.phase != .stationary }) ?? touches.first else { return nil }
        return candidates.last(where: { $0.containsTouch(touch) })
    }
}

extension UIApplication {
    @objc fileprivate func markdownBlockSelection_sendEvent(_ event: UIEvent) {
        if event.type == .touches, let touches = event.allTouches {
            MainActor.assumeIsolated {
                BlockSelectionEventTap.route(touches)
            }
        }
        markdownBlockSelection_sendEvent(event)  // the original, after the exchange
    }
}

// MARK: - Style

/// How selected blocks look (Craft's), shared by the overlay and hosts that draw their
/// own selection (a document on the Mac).
public enum MarkdownBlockSelectionStyle {
    /// A selected block's highlight: the accent at this opacity, no border, one per
    /// block (adjacent ones stay apart).
    public static let highlightOpacity: Double = 0.10
    public static let highlightCornerRadius: CGFloat = 10
    /// How far in from the item's frame the highlight's sides are.
    public static let highlightInset: CGFloat = 6
    /// A block's dot: filled with the accent when selected, an empty ring otherwise.
    public static let dotSize: CGFloat = 18
    /// From the dot's right edge to the item's.
    public static let dotTrailing: CGFloat = 12
    public static let ringOpacity: Double = 0.35
    public static let ringWidth: CGFloat = 1.5
}

// MARK: - Observable state (the overlay and the app's toolbar read only this)

@MainActor
@Observable
public final class MarkdownBlockSelectionState {
    public internal(set) var selectedItemIDs: Set<String> = []
    public internal(set) var isActive = false
}

// MARK: - Controller

@MainActor
public final class MarkdownBlockSelectionController: NSObject {
    /// Extra per-item hooks for the app's features (marks, footnotes, topics).
    public struct HookExtensions {
        public var editMenu: (@MainActor (PlatformTextView, NSRange, [UIMenuElement]) -> UIMenu?)?
        public var linkMenu: (@MainActor (URL) -> [UIMenuElement]?)?
        public var linkTap: (@MainActor (PlatformTextView, URL, CGRect) -> Bool)?
        public var topicPreview: (@MainActor (String) -> AnyView?)?

        public init(
            editMenu: (@MainActor (PlatformTextView, NSRange, [UIMenuElement]) -> UIMenu?)? = nil,
            linkMenu: (@MainActor (URL) -> [UIMenuElement]?)? = nil,
            linkTap: (@MainActor (PlatformTextView, URL, CGRect) -> Bool)? = nil,
            topicPreview: (@MainActor (String) -> AnyView?)? = nil
        ) {
            self.editMenu = editMenu
            self.linkMenu = linkMenu
            self.linkTap = linkTap
            self.topicPreview = topicPreview
        }
    }

    public let state = MarkdownBlockSelectionState()
    /// How block mode comes and goes (a controller isn't in a view's environment, so
    /// the owner hands it the motion it renders the Markdown with).
    public var motion: MarkdownMotion = .default
    /// Called when block mode turns on or off, to swap the input bar for a toolbar.
    public var onModeChanged: ((Bool) -> Void)?
    /// The list's items in order; pulled on demand, not observed.
    public var itemsProvider: () -> [MarkdownBlockSelectionItem] = { [] }
    /// Per-item hook extensions; set before cells render (hooks are cached per item).
    public var hookExtensions: ((_ itemID: String) -> HookExtensions)?
    /// Whether candidates of a group get a group dot that selects them all (a chat's
    /// messages); off where the items are one run (a document's blocks).
    public var selectsGroups = true

    /// The touch session: none, extending from a handle, or sliding along the dot column.
    private enum DragSession {
        case none
        case handleExtend
        case columnSlide(target: Bool, anchorContentY: CGFloat)
    }
    private var session: DragSession = .none
    /// Selection at the start of a column slide (restored as the range shrinks back).
    private var columnSlideBaseline: Set<String> = []

    // Feel
    /// How far past the anchor block the touch must go to switch to block mode: too
    /// small and selecting the last line flips it (the finger sits below the line),
    /// too large and it feels sluggish.
    private static let blockModeOvershoot: CGFloat = 60
    /// Hit radius of a selection endpoint handle (mirrors the system's).
    private static let handleHitZone: CGFloat = 35
    /// Interactive width of the dot column, from the list's right edge.
    private static let dotsColumnWidth: CGFloat = 64
    /// Largest movement that still counts as a tap.
    private static let tapSlop: CGFloat = 12

    public private(set) weak var layout: (any MarkdownBlockSelectionLayout)?
    private weak var containerView: UIView?

    // Native handle drag tracking
    private struct Owner {
        weak var textView: UITextView?
        let itemID: String
    }
    private var owners: [ObjectIdentifier: Owner] = [:]
    /// Stable hook instances (identity-equatable): a fresh instance re-renders every cell.
    private var hooksCache: [String: MarkdownSelectableTextHooks] = [:]
    private weak var activeCharTextView: UITextView?
    private var activeCharItemID: String?
    private var panActive = false
    private var panSawSelectionChange = false
    /// This touch sequence began on a selection handle.
    private var sequenceIsHandleDrag = false

    // Touch session
    private var anchorItemID: String?
    private var lastTouchPoint: CGPoint = .zero
    private var touchBeganPoint: CGPoint = .zero
    private var touchMovedBeyondTap = false
    private var autoscrollLink: CADisplayLink?
    private var autoscrollSpeed: CGFloat = 0
    private let selectionHaptic = UISelectionFeedbackGenerator()
    /// The list's pan gesture, disabled during a drag session.
    private weak var suppressedScrollPan: UIGestureRecognizer?

    public override init() {
        super.init()
    }

    // MARK: Install

    /// Call once the list is laid out (idempotent): connects the sendEvent touch source.
    public func install(layout: any MarkdownBlockSelectionLayout) {
        self.layout = layout
        guard let container = layout.containerView else { return }
        if containerView !== container {
            // The list view can be rebuilt by SwiftUI; follow it, or the window guard in
            // observeTouches swallows every touch on the detached old one.
            containerView = container
        }
        BlockSelectionEventTap.register(self)
    }

    var isContainerOnWindow: Bool { containerView?.window != nil }

    func containsTouch(_ touch: UITouch) -> Bool {
        guard let container = containerView, let window = container.window else { return false }
        guard touch.window === window else { return false }
        return container.bounds.contains(touch.location(in: container))
    }

    func observeTouches(_ touches: Set<UITouch>) {
        guard let container = containerView, container.window != nil else { return }
        guard let touch = touches.first(where: { $0.phase != .stationary }) else { return }
        let point = touch.location(in: container)
        let hitInContainer = touch.view.map { $0.isDescendant(of: container) } ?? false
        switch touch.phase {
        case .began, .moved, .ended, .cancelled:
            handleTouch(phase: touch.phase, at: point, hitInContainer: hitInContainer)
        default:
            break
        }
    }

    // MARK: Cell hooks

    /// Readable from a non-isolated cell body that runs on the main thread; reading it
    /// there is tracked, so cells re-render when the mode flips.
    public nonisolated var isSelectionModeActive: Bool {
        MainActor.assumeIsolated { state.isActive }
    }

    /// Hooks for a selectable item's text view; inject with `.environment(\.markdownSelectableTextHooks, …)`.
    /// Cached per item, so the instance stays stable across renders.
    public nonisolated func hooks(for itemID: String) -> MarkdownSelectableTextHooks {
        MainActor.assumeIsolated {
            if let cached = hooksCache[itemID] { return cached }
            let extensions = hookExtensions?(itemID) ?? HookExtensions()
            let hooks = MarkdownSelectableTextHooks(
                onTextViewReady: { [weak self] textView in
                    self?.owners[ObjectIdentifier(textView)] = Owner(textView: textView, itemID: itemID)
                },
                onSelectionChanged: { [weak self] textView in
                    self?.selectionDidChange(textView)
                },
                editMenu: extensions.editMenu,
                linkMenu: extensions.linkMenu,
                linkTap: extensions.linkTap,
                topicPreview: extensions.topicPreview
            )
            hooksCache[itemID] = hooks
            return hooks
        }
    }

    /// The item a text view currently renders, if it registered through ``hooks(for:)``.
    public func itemID(for textView: UITextView) -> String? {
        guard let owner = owners[ObjectIdentifier(textView)], owner.textView === textView else { return nil }
        return owner.itemID
    }

    /// Text views currently registered for an item (pooled views may have moved on; check `window`).
    public func textViews(for itemID: String) -> [UITextView] {
        owners.values.compactMap { $0.itemID == itemID ? $0.textView : nil }
    }

    private func selectionDidChange(_ textView: UITextView) {
        guard !state.isActive else {
            // No character selection in block mode (the system may commit one more at the
            // end of a drag); the block highlight is the only truth.
            if let range = textView.selectedTextRange, !range.isEmpty {
                textView.selectedTextRange = nil
            }
            return
        }
        guard let owner = owners[ObjectIdentifier(textView)], owner.textView === textView else { return }
        guard let range = textView.selectedTextRange, !range.isEmpty else {
            if activeCharTextView === textView {
                activeCharTextView = nil
                activeCharItemID = nil
            }
            return
        }
        activeCharTextView = textView
        activeCharItemID = owner.itemID
        if panActive { panSawSelectionChange = true }
        // No promotion when a selection ends pinned at a block edge: selecting to the
        // start or end and letting go is ordinary. Only dragging past the edge switches.
    }

    // MARK: Touch state machine

    private func handleTouch(phase touchPhase: UITouch.Phase, at point: CGPoint, hitInContainer: Bool) {
        lastTouchPoint = point

        switch touchPhase {
        case .began:
            panActive = true
            panSawSelectionChange = false
            touchBeganPoint = point
            touchMovedBeyondTap = false
            sequenceIsHandleDrag = !state.isActive && isPointOnSelectionHandle(point)
            // In block mode, starting on the dot column slides (target = opposite of the first block).
            if state.isActive, hitInContainer, isPointInDotsColumn(point),
               let block = candidateItemID(atScreenY: point.y) {
                let target = !state.selectedItemIDs.contains(block)
                // Snapshot and a content-space anchor: sliding back shrinks the range and
                // restores the blocks that leave it.
                columnSlideBaseline = state.selectedItemIDs
                let anchorContentY = point.y + (layout?.contentOffsetY() ?? 0)
                session = .columnSlide(target: target, anchorContentY: anchorContentY)
                setSelected(target, for: [block])
                setScrollSuppressed(true)
            }
        case .moved:
            if !touchMovedBeyondTap,
               hypot(point.x - touchBeganPoint.x, point.y - touchBeganPoint.y) > Self.tapSlop {
                touchMovedBeyondTap = true
            }
            switch session {
            case .none:
                if !state.isActive {
                    maybeEnterBlockMode(at: point, force: sequenceIsHandleDrag)
                }
            case .handleExtend:
                updateRangeSelection(at: point)
                updateAutoscroll(at: point)
            case .columnSlide(let target, let anchorContentY):
                sweepColumn(anchorContentY: anchorContentY, toScreenY: point.y, target: target)
                updateAutoscroll(at: point)
            }
        case .ended, .cancelled:
            let endedSession = session
            let wasTap = !touchMovedBeyondTap && touchPhase == .ended
            panActive = false
            sequenceIsHandleDrag = false
            session = .none
            columnSlideBaseline = []
            stopAutoscroll()
            setScrollSuppressed(false)
            // A tap in block mode: a group dot selects or clears its group; a block toggles.
            if case .none = endedSession, state.isActive, wasTap, hitInContainer {
                if isPointInDotsColumn(point),
                   let group = groups().first(where: {
                       point.y >= $0.dotAnchorFrame.minY - 6 && point.y <= $0.dotAnchorFrame.maxY + 6
                   }) {
                    toggleGroupSelection(group)
                } else if let block = candidateItemID(atScreenPoint: point) {
                    toggleSelection(block)
                }
            }
            // Nothing left selected: leave block mode.
            if state.isActive, state.selectedItemIDs.isEmpty {
                withAnimation(motion.feedback) {
                    exitMode()
                }
            }
            // The character anchor stays: after a double tap creates a selection, a later
            // handle drag still needs it. selectionDidChange clears it when the selection goes.
        default:
            break
        }
    }

    /// A handle dragged past the anchor block: clear the character selection, cancel the
    /// text view's gestures, enter block mode and keep extending with this touch.
    private func maybeEnterBlockMode(at point: CGPoint, force: Bool) {
        guard force || panSawSelectionChange,
              let textView = activeCharTextView,
              let anchorID = activeCharItemID,
              let range = textView.selectedTextRange, !range.isEmpty,
              let cellFrame = screenFrame(forItem: anchorID)
        else { return }

        guard point.y > cellFrame.maxY + Self.blockModeOvershoot
            || point.y < cellFrame.minY - Self.blockModeOvershoot else { return }

        // Toggling isUserInteractionEnabled cancels every gesture in flight on the text view.
        textView.selectedTextRange = nil
        textView.isUserInteractionEnabled = false
        textView.isUserInteractionEnabled = true

        activateMode(preselect: [anchorID], anchor: anchorID)
        session = .handleExtend
        setScrollSuppressed(true)
        updateRangeSelection(at: point)
    }

    /// Enters block mode with `ids` selected; `anchor` anchors a handle-driven range.
    public func activateMode(preselect ids: [String], anchor itemID: String? = nil) {
        anchorItemID = itemID ?? ids.first
        // The overlay fades in: flip isActive inside the animation, or the switch from
        // character selection to block highlight is a hard cut.
        withAnimation(motion.feedback) {
            state.isActive = true
            state.selectedItemIDs = Set(ids)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selectionHaptic.prepare()
        onModeChanged?(true)
    }

    /// Enters block mode with every candidate of a group selected.
    public func activateModeSelectingGroup(_ group: String) {
        let ids = candidateItems().filter { $0.group == group }.map(\.id)
        guard !ids.isEmpty else { return }
        activateMode(preselect: ids)
    }

    public func exitMode() {
        session = .none
        anchorItemID = nil
        stopAutoscroll()
        setScrollSuppressed(false)
        if state.isActive {
            withAnimation(motion.feedback) {
                state.isActive = false
                state.selectedItemIDs = []
            }
        }
        onModeChanged?(false)
    }

    /// Sets the selection (in block mode), as the host's own gestures pick blocks.
    public func setSelection(_ ids: Set<String>) {
        guard ids != state.selectedItemIDs else { return }
        withAnimation(motion.feedback) {
            state.selectedItemIDs = ids
        }
        selectionHaptic.selectionChanged()
    }

    /// The selected items in list order.
    public func selectedItems() -> [MarkdownBlockSelectionItem] {
        itemsProvider().filter { state.selectedItemIDs.contains($0.id) }
    }

    // MARK: Selecting

    /// Handle extension: a contiguous range in list order from the anchor block to the block under the touch.
    private func updateRangeSelection(at point: CGPoint) {
        guard let layout, let anchorID = anchorItemID else { return }
        let candidates = candidateItems()
        guard let anchorPos = candidates.firstIndex(where: { $0.id == anchorID }) else { return }

        let contentY = point.y + layout.contentOffsetY()
        // Only frames near the finger: the nearest block is local, the middle of the range is by index.
        let width = max(1, layout.containerView?.bounds.width ?? 1)
        let frames = layout.contentFrames(
            intersecting: CGRect(x: 0, y: contentY - 1200, width: width, height: 2400)
        )
        var currentPos = anchorPos
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, item) in candidates.enumerated() {
            guard let frame = frames[item.id] else { continue }
            if contentY >= frame.minY, contentY <= frame.maxY {
                currentPos = index
                break
            }
            let distance = contentY < frame.minY ? frame.minY - contentY : contentY - frame.maxY
            if distance < bestDistance {
                bestDistance = distance
                currentPos = index
            }
        }

        let range = min(anchorPos, currentPos)...max(anchorPos, currentPos)
        let selection = Set(candidates[range].map(\.id))
        if selection != state.selectedItemIDs {
            state.selectedItemIDs = selection
            selectionHaptic.selectionChanged()
        }
    }

    /// Column slide, undoable within the gesture: candidates in [anchor, current] take
    /// `target`, the rest return to the snapshot. Anchored in content space so autoscroll
    /// doesn't drift the range.
    private func sweepColumn(anchorContentY: CGFloat, toScreenY: CGFloat, target: Bool) {
        guard let layout else { return }
        let candidates = candidateItems()
        let currentContentY = toScreenY + layout.contentOffsetY()
        let lower = min(anchorContentY, currentContentY)
        let upper = max(anchorContentY, currentContentY)
        let width = max(1, layout.containerView?.bounds.width ?? 1)
        let frames = layout.contentFrames(
            intersecting: CGRect(x: 0, y: lower - 10, width: width, height: upper - lower + 20)
        )
        var selection = columnSlideBaseline
        for item in candidates {
            guard let frame = frames[item.id] else { continue }
            if frame.maxY >= lower, frame.minY <= upper {
                if target { selection.insert(item.id) } else { selection.remove(item.id) }
            }
        }
        if selection != state.selectedItemIDs {
            state.selectedItemIDs = selection
            selectionHaptic.selectionChanged()
        }
    }

    private func setSelected(_ selected: Bool, for ids: [String]) {
        var changed = false
        for id in ids {
            if selected {
                changed = state.selectedItemIDs.insert(id).inserted || changed
            } else if state.selectedItemIDs.remove(id) != nil {
                changed = true
            }
        }
        if changed { selectionHaptic.selectionChanged() }
    }

    private func toggleSelection(_ id: String) {
        setSelected(!state.selectedItemIDs.contains(id), for: [id])
    }

    // MARK: Geometry

    func candidateItems() -> [MarkdownBlockSelectionItem] {
        itemsProvider().filter { $0.role == .candidate }
    }

    /// A group's candidates and where its dot sits (the header's frame, else a strip
    /// above the first block; screen coordinates).
    struct Group {
        let id: String
        let itemIDs: [String]
        let dotAnchorFrame: CGRect
    }

    /// Frames of items near the viewport (± padding, content coordinates) by spatial query.
    /// Never query every item: on long lists that was what froze block mode.
    func viewportFrames(padding: CGFloat = 200) -> [String: CGRect] {
        guard let layout, let container = layout.containerView else { return [:] }
        let rect = CGRect(
            x: 0,
            y: layout.contentOffsetY() - padding,
            width: max(1, container.bounds.width),
            height: container.bounds.height + padding * 2
        )
        return layout.contentFrames(intersecting: rect)
    }

    /// Groups with their dot anchors (screen coordinates); groups whose anchor isn't in
    /// `frames` are off screen and skipped.
    func groups(frames: [String: CGRect]? = nil) -> [Group] {
        guard let layout, selectsGroups else { return [] }
        let frames = frames ?? viewportFrames()
        let offsetY = layout.contentOffsetY()
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        var headerFrame: [String: CGRect] = [:]
        for item in itemsProvider() {
            switch item.role {
            case .candidate:
                if grouped[item.group] == nil {
                    order.append(item.group)
                    grouped[item.group] = []
                }
                grouped[item.group]?.append(item.id)
            case .groupHeader:
                if headerFrame[item.group] == nil, let f = frames[item.id] {
                    headerFrame[item.group] = f.offsetBy(dx: 0, dy: -offsetY)
                }
            case .other:
                break
            }
        }
        return order.compactMap { group in
            guard let ids = grouped[group], !ids.isEmpty else { return nil }
            let anchor: CGRect
            if let hf = headerFrame[group] {
                anchor = hf
            } else if let first = ids.first, let f = frames[first] {
                anchor = CGRect(x: f.minX, y: f.minY - offsetY - 24, width: f.width, height: 24)
            } else {
                return nil
            }
            return Group(id: group, itemIDs: ids, dotAnchorFrame: anchor)
        }
    }

    private func toggleGroupSelection(_ group: Group) {
        let allSelected = group.itemIDs.allSatisfy { state.selectedItemIDs.contains($0) }
        setSelected(!allSelected, for: group.itemIDs)
    }

    private func screenFrame(forItem id: String) -> CGRect? {
        guard let layout, let frame = layout.frame(forItem: id) else { return nil }
        return frame.offsetBy(dx: 0, dy: -layout.contentOffsetY())
    }

    private func isPointInDotsColumn(_ point: CGPoint) -> Bool {
        guard let container = containerView else { return false }
        return point.x >= container.bounds.width - Self.dotsColumnWidth
    }

    private func candidateItemID(atScreenY y: CGFloat) -> String? {
        let offsetY = layout?.contentOffsetY() ?? 0
        let frames = viewportFrames()
        for item in candidateItems() {
            if let frame = frames[item.id], y >= frame.minY - offsetY, y <= frame.maxY - offsetY {
                return item.id
            }
        }
        return nil
    }

    private func candidateItemID(atScreenPoint point: CGPoint) -> String? {
        let offsetY = layout?.contentOffsetY() ?? 0
        let frames = viewportFrames()
        for item in candidateItems() {
            if let frame = frames[item.id], frame.offsetBy(dx: 0, dy: -offsetY).contains(point) {
                return item.id
            }
        }
        return nil
    }

    /// Whether a point (container coordinates) is inside an endpoint handle of the active selection.
    private func isPointOnSelectionHandle(_ point: CGPoint) -> Bool {
        guard let textView = activeCharTextView,
              let container = containerView,
              let range = textView.selectedTextRange, !range.isEmpty else { return false }
        let zone = Self.handleHitZone
        for position in [range.start, range.end] {
            let caret = textView.caretRect(for: position)
            guard caret.origin.x.isFinite, caret.origin.y.isFinite else { continue }
            let inContainer = container.convert(caret, from: textView)
            if inContainer.insetBy(dx: -zone, dy: -zone).contains(point) { return true }
        }
        return false
    }

    // MARK: Scroll suppression and edge autoscroll

    private func setScrollSuppressed(_ suppressed: Bool) {
        if suppressed {
            guard suppressedScrollPan == nil, let container = containerView else { return }
            let scrollView = (container as? UIScrollView) ?? Self.firstScrollView(in: container)
            suppressedScrollPan = scrollView?.panGestureRecognizer
            suppressedScrollPan?.isEnabled = false
        } else {
            suppressedScrollPan?.isEnabled = true
            suppressedScrollPan = nil
        }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scroll = subview as? UIScrollView { return scroll }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }

    private func updateAutoscroll(at point: CGPoint) {
        guard let container = containerView else { return }
        let zone: CGFloat = 90
        let height = container.bounds.height
        var speed: CGFloat = 0
        if point.y < zone {
            speed = -(zone - point.y) / zone * 14
        } else if point.y > height - zone {
            speed = (point.y - (height - zone)) / zone * 14
        }
        autoscrollSpeed = speed
        if speed == 0 {
            stopAutoscroll()
            return
        }
        if autoscrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoscrollTick))
            link.add(to: .main, forMode: .common)
            autoscrollLink = link
        }
    }

    @objc private func autoscrollTick() {
        guard let layout else {
            stopAutoscroll()
            return
        }
        switch session {
        case .handleExtend:
            layout.scrollToContentOffsetY(layout.contentOffsetY() + autoscrollSpeed)
            updateRangeSelection(at: lastTouchPoint)
        case .columnSlide(let target, let anchorContentY):
            layout.scrollToContentOffsetY(layout.contentOffsetY() + autoscrollSpeed)
            // The anchor is in content space: rescanning widens the range as the list scrolls.
            sweepColumn(anchorContentY: anchorContentY, toScreenY: lastTouchPoint.y, target: target)
        case .none:
            stopAutoscroll()
        }
    }

    private func stopAutoscroll() {
        autoscrollLink?.invalidate()
        autoscrollLink = nil
    }
}

// MARK: - Highlight and dot column overlay

/// Selected-block highlights and the dot column (Craft style), drawn in a layer over the
/// list: frames come from the layout, minus the content offset. It takes no touches;
/// the controller's sendEvent state machine handles all interaction.
public struct MarkdownBlockSelectionOverlay: View {
    let controller: MarkdownBlockSelectionController
    let accent: Color
    let topInset: (MarkdownBlockSelectionItem) -> CGFloat
    let bottomInset: (MarkdownBlockSelectionItem) -> CGFloat
    let highlights: (MarkdownBlockSelectionItem) -> Bool
    @Environment(\.markdownMotion) private var motion

    /// - Parameters:
    ///   - topInset: spacing a cell keeps above its content, left out of the highlight.
    ///   - bottomInset: spacing a cell keeps below its content (its share of the gap
    ///     between blocks), left out of the highlight so adjacent blocks stay apart.
    ///   - highlights: whether a selected item is tinted (one that marks itself, a card
    ///     outlining its box, isn't).
    public init(
        controller: MarkdownBlockSelectionController,
        accent: Color = .accentColor,
        topInset: @escaping (MarkdownBlockSelectionItem) -> CGFloat = { _ in 0 },
        bottomInset: @escaping (MarkdownBlockSelectionItem) -> CGFloat = { _ in 0 },
        highlights: @escaping (MarkdownBlockSelectionItem) -> Bool = { _ in true }
    ) {
        self.controller = controller
        self.accent = accent
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.highlights = highlights
    }

    public var body: some View {
        let state = controller.state
        if state.isActive, let layout = controller.layout {
            // Redraw on scroll and layout changes.
            let _ = layout.layoutVersion
            let offsetY = layout.contentOffsetY()
            let viewportHeight = (layout.visibleContentHeight() ?? layout.containerView?.bounds.height ?? 0)
                + (layout.containerView?.safeAreaInsets.top ?? 0)
            let visibleRange = (-200.0)...(viewportHeight + 200)
            let frames = controller.viewportFrames(padding: 200)
            let visible = controller.candidateItems().filter { frames[$0.id] != nil }
            ZStack(alignment: .topLeading) {
                ForEach(visible) { item in
                    if state.selectedItemIDs.contains(item.id), highlights(item), let frame = frames[item.id] {
                        let top = topInset(item)
                        let contentHeight = max(0, frame.height - top - bottomInset(item))
                        let inset = MarkdownBlockSelectionStyle.highlightInset
                        RoundedRectangle(cornerRadius: MarkdownBlockSelectionStyle.highlightCornerRadius, style: .continuous)
                            .fill(accent.opacity(MarkdownBlockSelectionStyle.highlightOpacity))
                            .frame(width: max(0, frame.width - inset * 2), height: contentHeight)
                            .offset(x: frame.minX + inset, y: frame.minY + top - offsetY)
                    }
                }
                // Candidate dots: filled when selected, an empty ring otherwise, centered on the content.
                ForEach(visible) { item in
                    if let frame = frames[item.id] {
                        let selected = state.selectedItemIDs.contains(item.id)
                        let top = topInset(item)
                        let contentHeight = max(0, frame.height - top - bottomInset(item))
                        let size = MarkdownBlockSelectionStyle.dotSize
                        Circle()
                            .fill(selected ? accent : Color.clear)
                            .overlay {
                                if !selected {
                                    Circle().strokeBorder(.secondary.opacity(MarkdownBlockSelectionStyle.ringOpacity),
                                                          lineWidth: MarkdownBlockSelectionStyle.ringWidth)
                                }
                            }
                            .frame(width: size, height: size)
                            .offset(
                                x: frame.maxX - MarkdownBlockSelectionStyle.dotTrailing - size,
                                y: frame.minY + top - offsetY + contentHeight / 2 - size / 2
                            )
                            .animation(motion.feedback, value: selected)
                    }
                }
                // Group dots: all selected filled, some selected faint, none an empty ring.
                ForEach(controller.groups(frames: frames), id: \.id) { group in
                    let y = group.dotAnchorFrame.midY
                    if visibleRange.contains(y) {
                        let selectedCount = group.itemIDs.filter { state.selectedItemIDs.contains($0) }.count
                        let fillOpacity: Double = selectedCount == group.itemIDs.count ? 1 : (selectedCount > 0 ? 0.35 : 0)
                        Circle()
                            .fill(accent.opacity(fillOpacity))
                            .overlay {
                                if selectedCount == 0 {
                                    Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1.5)
                                }
                            }
                            .frame(width: 22, height: 22)
                            .offset(x: group.dotAnchorFrame.maxX - 32, y: y - 11)
                            .animation(motion.feedback, value: selectedCount)
                    }
                }
            }
            // Offsets don't size the stack: pin it to the container's top-leading corner,
            // where the frames' origin is, whatever alignment the caller's overlay uses.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
#endif
