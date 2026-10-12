//
//  DocBlocks.swift
//  DemoApp
//
//  Blocks as wholes, the way Craft handles them. On the Mac a click on a block selects
//  it (⇧ extends, ⌘ adds) and a drag moves it, from anywhere on it or from the handle
//  beside the block under the pointer; only a selected block's content takes clicks (a
//  second click puts the caret in its text, edits a cell, code or math). While text is
//  edited, every block with text takes them: a click there edits it. On a phone a tap
//  edits (a link, file or image opens), a long press lifts the block: drag it to move
//  it, or let go to start selecting blocks; a swipe either way selects one too
//  (flowith's Composer), and while selecting a tap or a swipe adds or removes one.
//  Selecting a list item selects it alone; moving it takes the items nested under it.
//  Drags are the system's (Craft's): the rows lifted from where they are, landing on
//  where they go. A move is one transaction of moveBlock steps, undone in one go.
//
//  The handle, the selection, the drop line and the dimmed source rows are views in
//  the list's own scroll view (content coordinates), so they scroll with the rows.
//

import SwiftUI
import QuickLook
import DocKit
import MarkdownView
import MessagingUI

@MainActor
@Observable
final class DocBlockController: NSObject, UIGestureRecognizerDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate,
    QLPreviewControllerDataSource {
    #if targetEnvironment(macCatalyst)
    nonisolated static let usesHandles = true
    #else
    nonisolated static let usesHandles = false
    #endif
    /// The page's side margins: on the Mac room for the handle on the left (and as much
    /// on the right). The selection's dots lie over the page (Craft's): no room for them.
    nonisolated static let leadingGutter: CGFloat = usesHandles ? 40 : 20
    nonisolated static let trailingGutter: CGFloat = usesHandles ? 40 : 20

    /// How far a selected block's tint reaches above and below its text (Craft's room
    /// around a line; the space between blocks keeps neighbours' tints apart).
    nonisolated static let highlightOutset: CGFloat = 3

    /// Where the page starts across a list `width` wide: past the leading gutter, the
    /// page (at most 720 wide) centred in what the gutters leave.
    nonisolated static func pageLeft(inWidth width: CGFloat) -> CGFloat {
        let room = max(0, width - leadingGutter - trailingGutter)
        return leadingGutter + (room - min(720, room)) / 2
    }

    /// The page's width in a list `width` wide: the room between the gutters, at most 720.
    nonisolated static func pageWidth(inWidth width: CGFloat) -> CGFloat {
        min(720, max(0, width - leadingGutter - trailingGutter))
    }

    @ObservationIgnored private let demo: DocDemo
    @ObservationIgnored unowned let editor: DocEditor
    /// A phone's block selection: the chat's (MarkdownView's block selection mode), its
    /// dots over the page's right edge, a tap on any block adding or removing it, a
    /// slide down the dots taking a run; the text isn't edited, a bar offers what to do
    /// with the blocks.
    let selection: MarkdownBlockSelectionController = {
        let selection = MarkdownBlockSelectionController()
        selection.motion = FlooDesignTokens.Motion.markdown
        selection.selectsGroups = false
        return selection
    }()
    /// The Mac's selected blocks, in document order.
    private var macSelection: [DocBlockID] = []
    /// The selected blocks, in document order (a list item alone, not its nested items).
    var selected: [DocBlockID] {
        guard !Self.usesHandles else { return macSelection }
        let chosen = selection.state.selectedItemIDs
        guard !chosen.isEmpty else { return [] }
        return demo.doc.blocks.map(\.id).filter { chosen.contains($0.description) }
    }
    func isSelected(_ id: DocBlockID) -> Bool {
        Self.usesHandles ? macSelection.contains(id) : selection.state.selectedItemIDs.contains(id.description)
    }
    /// The block being typed in (its text view has the focus).
    private(set) var typing: DocBlockID?
    /// The phone's selection mode.
    var isSelecting: Bool { !Self.usesHandles && selection.state.isActive }
    /// The panel shows the selected media's layouts instead of the actions.
    var isChoosingLayout = false

    @ObservationIgnored private var anchor: DocBlockID?
    @ObservationIgnored private var head: DocBlockID?
    @ObservationIgnored private weak var reader: TiledViewReader<String>?
    @ObservationIgnored private weak var list: UICollectionView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private lazy var handle = DocBlockHandleView()
    @ObservationIgnored private lazy var keys = DocBlockKeyView()
    @ObservationIgnored private lazy var indicator: UIView = {
        let view = UIView()
        view.backgroundColor = .tintColor
        view.layer.cornerRadius = 1
        view.layer.zPosition = 7
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()
    /// The Mac's selection (a phone's is the selection's overlay).
    @ObservationIgnored private var highlights: [UIView] = []
    @ObservationIgnored private var dimmers: [UIView] = []
    /// The block under the pointer (its handle is shown), and where the pointer is in
    /// the list's frame, to find it again after a scroll.
    @ObservationIgnored private(set) var hovered: DocBlockID?
    @ObservationIgnored private var hoverPoint: CGPoint?
    @ObservationIgnored private var drag: Drag?
    /// The moved blocks while the system flies what it lifted to where they landed: their
    /// rows hidden until it's down (what flies is them).
    private var landing: [DocBlockID] = []
    @ObservationIgnored private var dragging: UIDragInteraction?
    @ObservationIgnored private var dropping: UIDropInteraction?
    /// The phone's swipe that selects a block, and the row it moves.
    @ObservationIgnored private var swipe: UIPanGestureRecognizer?
    @ObservationIgnored private var swiped: (block: DocBlockID, cell: UIView?)?
    @ObservationIgnored private var link: CADisplayLink?
    /// A click on a row outside its text (DocEditor.click), and the phone's tap that
    /// picks blocks while selecting.
    @ObservationIgnored private var rowClick: UITapGestureRecognizer?
    /// The Mac's click on a block whose content doesn't take it (blockTakes).
    @ObservationIgnored private var blockClick: UITapGestureRecognizer?
    /// The Mac's double click on a link, image or file opens it (a single one selects it).
    @ObservationIgnored private var mediaOpen: UITapGestureRecognizer?
    /// Where a link opens (the browser; the edit tests catch it).
    @ObservationIgnored var opensURL: (URL) -> Void = { UIApplication.shared.open($0) }
    /// The image Quick Look shows.
    @ObservationIgnored private var previewing: URL?
    /// Rows flying to where they landed: the selection shows once they're down.
    @ObservationIgnored private var landings = 0

    private struct Drag {
        /// The blocks picked up (the selection, or the one grabbed), and with them the
        /// items nested under them: what moves.
        var tops: [DocBlockID]
        var moving: [DocBlockID]
        var grabbed: DocBlockID
        /// Where it started (list coordinates) and where the pointer is, in the list's
        /// frame (stays put while the list scrolls under it).
        var start: CGPoint
        var point: CGPoint
        /// Whether the lift finished: a phone's block lifted and let go starts selecting.
        var isLifted = false
        /// Whether it has moved yet.
        var isMoving = false
        /// Where the blocks would go: after this block (nil: the top), or nowhere new.
        var target: DocBlockID??
    }

    init(demo: DocDemo, editor: DocEditor) {
        self.demo = demo
        self.editor = editor
        super.init()
        selection.itemsProvider = { [weak self] in
            self?.demo.rows.compactMap { row in
                row.block.map { _ in MarkdownBlockSelectionItem(id: row.id, group: "", role: .candidate) }
            } ?? []
        }
        selection.onModeChanged = { [weak self] in self?.selectingChanged($0) }
    }

    // MARK: Attaching

    /// Puts the handle, the gestures and the key responder on the list once it exists.
    func attach(_ reader: TiledViewReader<String>) {
        self.reader = reader
        guard list == nil || list?.window == nil, let container = reader.containerView,
            let list = Self.collectionView(in: container)
        else { return }
        self.list = list
        list.addSubview(indicator)
        list.addSubview(keys)
        keys.controller = self
        if Self.usesHandles {
            list.addSubview(handle)
            handle.isHidden = true
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            list.addGestureRecognizer(hover)
            handle.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleClicked(_:))))
            let click = UITapGestureRecognizer(target: self, action: #selector(blockClicked(_:)))
            click.delegate = self
            list.addGestureRecognizer(click)
            blockClick = click
        } else {
            selection.install(layout: reader)
            let swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.maximumNumberOfTouches = 1
            swipe.delegate = self
            list.addGestureRecognizer(swipe)
            self.swipe = swipe
        }
        let dragging = UIDragInteraction(delegate: self)
        dragging.isEnabled = !Self.usesHandles
        list.addInteraction(dragging)
        self.dragging = dragging
        let dropping = UIDropInteraction(delegate: self)
        list.addInteraction(dropping)
        self.dropping = dropping
        followDragAvailability()
        // On the list, not in the rows: SwiftUI's hit testing doesn't always pass a click
        // through a row's content to a view behind it.
        let click = UITapGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        click.delegate = self
        list.addGestureRecognizer(click)
        rowClick = click
        // It only takes touches on links and images, so elsewhere nothing waits for it.
        // A click doesn't wait for it either: the first click selects at once (the
        // system's double-click time would hold every click back), the second opens.
        // On a phone a tap opens them.
        if Self.usesHandles {
            let open = UITapGestureRecognizer(target: self, action: #selector(mediaDoubleClicked(_:)))
            open.numberOfTapsRequired = 2
            open.delegate = self
            list.addGestureRecognizer(open)
            mediaOpen = open
        }
        observations = [
            list.observe(\.contentSize) { [weak self] _, _ in MainActor.assumeIsolated { self?.layoutOverlays() } },
            list.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.rowsMoved() } },
        ]
    }

    private static func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for subview in view.subviews {
            if let list = collectionView(in: subview) { return list }
        }
        return nil
    }

    // MARK: Geometry

    /// A block's row (on a line with others, its part of the line).
    private func rowFrame(_ id: DocBlockID) -> CGRect? {
        reader?.frame(forItem: id.description)
    }

    /// The page's part of a block's row: less the page's margins (at most 720 wide,
    /// centred) and the space above and below it. A row on a line with others has the
    /// line's page part.
    private func pageFrame(_ id: DocBlockID) -> CGRect? {
        let rowID = id.description
        guard let row = reader?.frame(forItem: rowID) else { return nil }
        let listWidth = demo.runs[id] == nil ? row.width : list?.bounds.width ?? row.width
        let left = Self.pageLeft(inWidth: listWidth)
        let width = Self.pageWidth(inWidth: listWidth)
        let above = demo.spacingAbove[rowID] ?? 0
        let below = demo.spacingBelow[rowID] ?? 0
        return CGRect(x: left, y: row.minY + above, width: width, height: max(0, row.height - above - below))
    }

    /// The block itself: its row's page part, or a link, file or image's box where its
    /// row is placed (an image in a gallery fills its place).
    private func contentFrame(_ id: DocBlockID) -> CGRect? {
        guard let page = pageFrame(id) else { return nil }
        guard let kind = demo.doc.block(id)?.kind, DocMediaView.draws(kind), let row = rowFrame(id) else { return page }
        let run = demo.runs[id]
        let left = run == nil ? page.minX : row.minX
        let width = run == nil ? page.width : row.width
        if run?.kind == .gallery {
            return CGRect(x: left, y: page.minY, width: width, height: page.height)
        }
        guard let box = DocMediaLayout.boxSize(kind, width: width) else { return page }
        return CGRect(x: left, y: page.minY, width: min(box.width, width), height: min(box.height, page.height))
    }

    /// The committed block at a point (list coordinates): the row under it, or on a line
    /// of several, the one nearest it across.
    private func block(at point: CGPoint) -> DocBlockID? {
        guard let list, let reader else { return nil }
        let hits = reader.contentFrames(intersecting: CGRect(x: 0, y: point.y, width: list.bounds.width, height: 1))
        let level = hits.filter { $0.value.minY <= point.y && point.y < $0.value.maxY }
        func distance(_ frame: CGRect) -> CGFloat { max(frame.minX - point.x, 0, point.x - frame.maxX) }
        guard let id = (level.isEmpty ? hits : level).min(by: { distance($0.value) < distance($1.value) })?.key,
            let row = demo.rows.first(where: { $0.id == id })
        else { return nil }
        return row.block
    }

    /// Where a block's first line is, for the handle: the text's first line, or near
    /// the top of a code block, a table, an image.
    private func firstLineMidY(_ id: DocBlockID, row: CGRect) -> CGFloat {
        if let list, let textView = editor.textView(for: id), textView.window != nil {
            let line = textView.convert(textView.caretRect(for: textView.beginningOfDocument), to: list)
            if line.height > 0, line.midY > row.minY, line.midY < row.maxY { return line.midY }
        }
        return row.height < 48 ? row.midY : row.minY + 20
    }

    // MARK: Overlays

    /// Lays the handle, the selection and a drag's marks out on the rows as they are now.
    func layoutOverlays() {
        guard let list else { return }
        let existing = Set(demo.doc.blocks.map(\.id))
        if selected.contains(where: { !existing.contains($0) }) {
            setSelection(selected.filter { existing.contains($0) })
            if selected.isEmpty, isSelecting { endSelecting() }
            return
        }
        // The Mac's, as the chat's selection (MarkdownBlockSelectionStyle): a tint, one
        // per block, from a little outside the page's sides and the text's lines.
        // Links, files and images outline themselves, hugging their box (DocMediaCell).
        let text = Self.usesHandles && landings == 0 ? selected.filter { demo.doc.block($0).map { !DocMediaView.draws($0.kind) } ?? false } : []
        let outset = Self.highlightOutset
        highlights = place(text.compactMap { pageFrame($0)?.insetBy(dx: 0, dy: -outset) }, in: highlights, outset: 10) {
            let view = UIView()
            view.backgroundColor = UIColor.tintColor.withAlphaComponent(MarkdownBlockSelectionStyle.highlightOpacity)
            view.layer.cornerRadius = MarkdownBlockSelectionStyle.highlightCornerRadius
            view.layer.cornerCurve = .continuous
            view.layer.zPosition = 5
            return view
        }
        let dimmed = drag.map { $0.isMoving ? $0.moving : [] } ?? []
        dimmers = place(runs(of: dimmed), in: dimmers, outset: 6) {
            let view = UIView()
            view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.65)
            view.layer.zPosition = 6
            return view
        }
        for view in highlights + dimmers where view.superview !== list { list.addSubview(view) }
        layoutHandle()
        if drag?.isMoving == true { updateTarget() }
    }

    /// The list's cells showing these blocks (by where the layout puts them).
    private func cells(of ids: [DocBlockID]) -> [UICollectionViewCell] {
        guard let list else { return [] }
        let frames = ids.compactMap(rowFrame)
        return list.visibleCells.filter { cell in
            frames.contains { abs($0.minY - cell.frame.minY) < 0.5 && abs($0.minX - cell.frame.minX) < 0.5 && abs($0.height - cell.frame.height) < 0.5 }
        }
    }

    /// Runs of rows next to each other in the document, as one rectangle each.
    private func runs(of ids: [DocBlockID]) -> [CGRect] {
        let chosen = Set(ids)
        var rects: [CGRect] = []
        var current: CGRect?
        for block in demo.doc.blocks {
            guard chosen.contains(block.id), let frame = contentFrame(block.id) else {
                if let run = current { rects.append(run) }
                current = nil
                continue
            }
            current = current.map { $0.union(frame) } ?? frame
        }
        if let run = current { rects.append(run) }
        return rects
    }

    private func place(_ rects: [CGRect], in views: [UIView], outset: CGFloat, make: () -> UIView) -> [UIView] {
        var views = views
        while views.count < rects.count { views.append(make()) }
        for (index, view) in views.enumerated() {
            view.isUserInteractionEnabled = false
            if index < rects.count {
                view.frame = rects[index].insetBy(dx: -outset, dy: 0)
                view.isHidden = false
            } else {
                view.isHidden = true
            }
        }
        return views
    }

    private func layoutHandle() {
        guard Self.usesHandles else { return }
        guard drag == nil, !demo.isAgentWriting, let hovered, let content = contentFrame(hovered) else {
            handle.isHidden = true
            return
        }
        let size = DocBlockHandleView.size
        // One column for every block, nested or not: the handles line up.
        let left = pageFrame(hovered)?.minX ?? content.minX
        handle.frame = CGRect(x: left - size.width - 6, y: firstLineMidY(hovered, row: content) - size.height / 2,
                              width: size.width, height: size.height)
        handle.layer.zPosition = 8
        handle.isHidden = false
    }

    // MARK: Mac: the handle

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard let list else { return }
        switch recognizer.state {
        case .began, .changed:
            hoverPoint = list.convert(recognizer.location(in: list), to: list.superview)
        default:
            // Leaving the list hides the handle, but not while it is being used.
            guard drag == nil else { return }
            hoverPoint = nil
        }
        followHover()
    }

    /// The rows moved under the pointer: the block under it is found once the list is done
    /// (the offset changes in the middle of its updates, and hit-testing a row lays its
    /// content out then, the new content at the row's old size, and its animation is lost).
    private func rowsMoved() {
        guard Self.usesHandles, hoverPoint != nil, !followsHoverSoon else { return }
        followsHoverSoon = true
        DispatchQueue.main.async { [weak self] in
            self?.followsHoverSoon = false
            self?.followHover()
        }
    }

    @ObservationIgnored private var followsHoverSoon = false

    /// The block under the pointer, again: the pointer moved or the rows did.
    private func followHover() {
        guard Self.usesHandles, let list, drag == nil else { return }
        let next = hoverPoint.flatMap { block(at: list.convert($0, from: list.superview)) }
        if next != hovered { hovered = next }
        layoutHandle()
        updateDragAvailability()
    }

    @objc private func handleClicked(_ recognizer: UITapGestureRecognizer) {
        guard let hovered, !demo.isAgentWriting else { return }
        click(hovered, modifiers: recognizer.modifierFlags)
    }

    @objc private func blockClicked(_ recognizer: UITapGestureRecognizer) {
        guard let list, !demo.isAgentWriting, let id = block(at: recognizer.location(in: list)) else { return }
        click(id, modifiers: recognizer.modifierFlags)
    }

    /// Whether a block's row (`editsText`: it has text to edit) takes clicks itself (its
    /// text, cells, code, math, a link's buttons). On the Mac the selected blocks do
    /// and, while text is edited, every block with text, so a click on any other
    /// selects it and a drag moves it, and the pointer is the I-beam over text only
    /// where a click would edit it. On a phone every row does but while selecting,
    /// when a tap on any block selects it or takes it out, never edits; while the agent
    /// writes (the page a preview), every row.
    func blockTakes(_ id: DocBlockID, editsText: Bool) -> Bool {
        guard !demo.isAgentWriting else { return true }
        guard Self.usesHandles else { return !isSelecting }
        if selected.contains(id) { return true }
        guard let editing = typing ?? editor.sources.editing ?? editor.tables.editing?.block else { return false }
        return editing == id || editsText
    }

    /// Whether the Mac's click and drag on the list take a touch on `view` at `point`
    /// (list coordinates): on a block whose row doesn't take clicks, or on a selected one
    /// with nothing in it to edit (a link, file, image, divider: a click selects it
    /// again, a drag moves it).
    private func pressTakes(_ view: UIView?, at point: CGPoint) -> Bool {
        guard Self.usesHandles, !demo.isAgentWriting, drag == nil, let id = block(at: point),
            !sequence(first: view, next: { $0?.superview }).contains(where: { $0 is UIControl || $0 === handle })
        else { return false }
        let editsText = demo.rows.first { $0.block == id }?.editsText ?? false
        return !(blockTakes(id, editsText: editsText) && editsText)
    }

    /// A click on a block (or its handle): it becomes the selection; ⇧ extends the
    /// selection to it, ⌘ adds or removes it.
    func click(_ id: DocBlockID, modifiers: UIKeyModifierFlags = []) {
        if modifiers.contains(.shift), let anchor {
            extend(from: anchor, to: id)
        } else if modifiers.contains(.command) {
            if selected.contains(id) {
                setSelection(selected.filter { $0 != id })
            } else {
                setSelection(selected + [id])
            }
            anchor = id
            head = id
        } else {
            select([id])
        }
        focusKeys()
    }

    // MARK: Selection

    /// Selects these blocks (a list item alone, not the items nested under it).
    func select(_ ids: [DocBlockID]) {
        setSelection(ids)
        anchor = ids.first
        head = ids.last
    }

    private func setSelection(_ ids: [DocBlockID]) {
        if Self.usesHandles {
            let chosen = Set(ids)
            macSelection = demo.doc.blocks.map(\.id).filter { chosen.contains($0) }
        } else {
            selection.setSelection(Set(ids.map(\.description)))
        }
        layoutOverlays()
    }

    /// Everything from `anchor` to `target`, in document order.
    private func extend(from anchor: DocBlockID, to target: DocBlockID) {
        let ids = demo.doc.blocks.map(\.id)
        guard let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: target) else { return }
        let range = min(from, to)...max(from, to)
        setSelection(Array(ids[range]))
        head = target
    }

    func clear() {
        guard !selected.isEmpty || isSelecting else { return }
        anchor = nil
        head = nil
        if isSelecting { endSelecting() }
        setSelection([])
    }

    /// Typing again (a text view took the focus): the blocks aren't selected any more.
    func textEditingBegan(_ id: DocBlockID) {
        typing = id
        guard !isSelecting else { return }
        clear()
    }

    func textEditingEnded(_ id: DocBlockID) {
        if typing == id { typing = nil }
    }

    /// Whether a drag can start now. On the Mac, where the pointer is: from the handle,
    /// or from a block whose row doesn't take clicks (pickUp), so a drag on text a click
    /// would edit selects the text. On a phone, while nothing is edited: the text being
    /// typed in keeps its long press (the loupe, selecting).
    private func updateDragAvailability() {
        guard let list, let dragging, drag == nil else { return }
        if Self.usesHandles {
            dragging.isEnabled = hoverPoint.map { pickUp(at: list.convert($0, from: list.superview)) != nil } ?? false
        } else {
            dragging.isEnabled = !demo.isAgentWriting && typing == nil && editor.tables.editing == nil && editor.sources.editing == nil
        }
    }

    /// Keeps the drag's availability up with what it depends on (the selection, what's
    /// edited, the agent writing).
    private func followDragAvailability() {
        withObservationTracking { updateDragAvailability() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followDragAvailability() }
        }
    }

    /// The block before or after the selection (↑ ↓); with ⇧ the selection grows to it.
    func step(_ direction: Int, extending: Bool) {
        let ids = demo.doc.blocks.map(\.id)
        guard let current = head ?? selected.last, let index = ids.firstIndex(of: current) else { return }
        let next = index + direction
        guard ids.indices.contains(next) else { return }
        if extending, let anchor {
            extend(from: anchor, to: ids[next])
        } else {
            select([ids[next]])
        }
        if let list, let frame = rowFrame(ids[next]) {
            list.scrollRectToVisible(frame.insetBy(dx: 0, dy: -24), animated: true)
        }
    }

    /// Esc while editing a block (its text, a cell, code, maths) on the Mac: the editing
    /// ends and the block is selected, as a click on it would have.
    func selectAfterEditing(_ id: DocBlockID) {
        guard Self.usesHandles else { return }
        select([id])
        focusKeys()
    }

    /// Return: edit the selected block's text, the cursor at its end.
    func editSelection() {
        guard let first = selected.first, let block = demo.doc.block(first) else { return }
        clear()
        if block.kind.carriesText { editor.place(DocPosition(block: block.id, offset: block.text.length)) }
    }

    private func focusKeys() {
        guard Self.usesHandles, keys.window != nil else { return }
        editor.tables.endEditing()
        editor.sources.endEditing()
        keys.becomeFirstResponder()
    }

    /// The key responder lost the focus (a click into the text, a cell, another field).
    fileprivate func keysResigned() {
        guard drag == nil else { return }
        clear()
    }

    // MARK: Phone: tap, swipe, select

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer === swipe {
            guard drag == nil, !demo.isAgentWriting, let list, block(at: touch.location(in: list)) != nil else { return false }
            // Down the dots a touch slides the selection (the selection's own).
            if isSelecting, touch.location(in: list).x >= list.bounds.width - 64 { return false }
            return !sequence(first: touch.view, next: { $0?.superview }).contains { $0 is UIControl }
        }
        if recognizer === mediaOpen {
            guard drag == nil, let list, let id = block(at: touch.location(in: list)) else { return false }
            return opens(id)
        }
        if recognizer === blockClick, let list { return pressTakes(touch.view, at: touch.location(in: list)) }
        if recognizer === rowClick {
            guard !isSelecting, drag == nil, let list else { return false }
            return rowClickTakes(touch.view) && !pressTakes(touch.view, at: touch.location(in: list))
        }
        return true
    }

    /// A swipe starts across, not along the page (it scrolls).
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === swipe, let pan = recognizer as? UIPanGestureRecognizer, let list else { return true }
        let velocity = pan.velocity(in: list)
        return abs(velocity.x) > abs(velocity.y)
    }

    /// Whether a click on this view is the row's. Text views and controls take their
    /// own clicks; the handle takes its own too: the row's would put the caret in the
    /// block's text, and the text taking the focus clears the selection the handle
    /// just made (it happens with it, as a table cell's own tap does).
    private func rowClickTakes(_ view: UIView?) -> Bool {
        !sequence(first: view, next: { $0?.superview }).contains { $0 is UITextView || $0 is UIControl || $0 === handle }
    }

    // Composer's swipe: the row follows the finger, damped, and eases back; 80 points
    // across select it (or, while selecting, add or remove it).
    private static let swipeDistance: CGFloat = 80
    private static let swipeMaxOffset: CGFloat = 72
    private static let swipeDamping: CGFloat = 130
    private static let swipeFlick: CGFloat = 1200

    @objc private func swiped(_ recognizer: UIPanGestureRecognizer) {
        guard let list else { return }
        switch recognizer.state {
        case .began:
            guard let id = block(at: recognizer.location(in: list)) else { return }
            swipeBegan(id)
        case .changed:
            swipeMoved(recognizer.translation(in: list).x)
        case .ended:
            swipeEnded(recognizer.translation(in: list).x, velocity: recognizer.velocity(in: list).x)
        default:
            swipeEnded(0, velocity: 0)
        }
    }

    private func swipeBegan(_ id: DocBlockID) {
        let cell = cells(of: [id]).first
        cell?.layer.zPosition = 30
        swiped = (id, cell)
    }

    private func swipeMoved(_ x: CGFloat) {
        swiped?.cell?.transform = CGAffineTransform(translationX: Self.swipeOffset(x), y: 0)
    }

    private func swipeEnded(_ x: CGFloat, velocity: CGFloat) {
        guard let (id, cell) = swiped else { return }
        swiped = nil
        let selects = abs(x) >= Self.swipeDistance
        if selects { toggleSelecting(id) }
        UIView.animate(withDuration: abs(velocity) >= Self.swipeFlick ? 0.15 : 0.2, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            cell?.transform = .identity
        } completion: { _ in
            cell?.layer.zPosition = 0
        }
    }

    /// How far the row follows a swipe `x` across: less and less, up to 72 points.
    private static func swipeOffset(_ x: CGFloat) -> CGFloat {
        let magnitude = min(abs(x), 320)
        return swipeMaxOffset * (1 - exp(-magnitude / swipeDamping)) * (x >= 0 ? 1 : -1)
    }

    /// A block picked while selecting is added or removed (the last one out ends
    /// selecting); outside, selecting starts with it.
    private func toggleSelecting(_ id: DocBlockID) {
        guard isSelecting else { return beginSelecting(id) }
        if selected.contains(id) {
            setSelection(selected.filter { $0 != id })
            if selected.isEmpty { endSelecting() }
        } else {
            setSelection(selected + [id])
        }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // A table cell's own tap and the row's click both happen; a double click opens
        // what the click on it selected.
        recognizer === rowClick || recognizer === mediaOpen
    }

    @objc private func rowClicked(_ recognizer: UITapGestureRecognizer) {
        guard let list else { return }
        click(atWindowPoint: list.convert(recognizer.location(in: list), to: nil))
    }

    /// A click at a point of the window outside any text: the block whose row it is in
    /// takes it. On the Mac a link, file or image is selected by it (and opened by a
    /// second), as is any block whose row doesn't take clicks (blockTakes); on a phone a
    /// tap opens a link, file or image.
    func click(atWindowPoint point: CGPoint) {
        guard let list, let id = block(at: list.convert(point, from: nil)) else { return }
        if Self.usesHandles, !blockTakes(id, editsText: demo.rows.first { $0.block == id }?.editsText ?? false) { return click(id) }
        guard let kind = demo.doc.block(id)?.kind, DocMediaView.draws(kind) else { return editor.click(id, at: point) }
        if Self.usesHandles {
            click(id)
        } else if !isSelecting, opens(id) {
            open(id)
        }
    }

    @objc private func mediaDoubleClicked(_ recognizer: UITapGestureRecognizer) {
        guard let list, let id = block(at: recognizer.location(in: list)) else { return }
        open(id)
    }

    /// Whether a double click opens this block: a link, an image, a file that has
    /// somewhere to open from.
    private func opens(_ id: DocBlockID) -> Bool {
        switch demo.doc.block(id)?.kind {
        case .link?, .image?: true
        case .file(let file)?: URL(string: file.source).map { $0.isFileURL || $0.scheme?.hasPrefix("http") == true } ?? false
        default: false
        }
    }

    /// A link in the browser; an image in Quick Look; a file in either.
    func open(_ id: DocBlockID) {
        switch demo.doc.block(id)?.kind {
        case .link(let link)?:
            if let url = URL(string: link.url) { opensURL(url) }
        case .image(let image)?:
            if let picture = DocMediaLayout.asset(image.source), let data = picture.jpegData(compressionQuality: 0.95) {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent((image.alt.isEmpty ? String(localized: "Image") : image.alt) + ".jpg")
                guard (try? data.write(to: file)) != nil else { return }
                quickLook(file)
            } else if let url = URL(string: image.source), url.scheme?.hasPrefix("http") == true {
                opensURL(url)
            }
        case .file(let file)?:
            // A file on the web opens in the browser, one on disk in Quick Look. A blob
            // has nowhere to come from yet: attachments aren't stored (Docs/doc.md §3.4.1).
            guard let url = URL(string: file.source) else { return }
            if url.isFileURL { quickLook(url) } else if url.scheme?.hasPrefix("http") == true { opensURL(url) }
        default:
            break
        }
    }

    private func quickLook(_ file: URL) {
        previewing = file
        let preview = QLPreviewController()
        preview.dataSource = self
        list?.window?.rootViewController.map { root in
            var top = root
            while let presented = top.presentedViewController { top = presented }
            top.present(preview, animated: true)
        }
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (previewing ?? URL(fileURLWithPath: "/")) as NSURL }
    }

    /// Starts a phone's selection mode with `id`; on the Mac (no mode) selects it.
    func beginSelecting(_ id: DocBlockID) {
        guard !Self.usesHandles else { return select([id]) }
        anchor = id
        head = id
        selection.activateMode(preselect: [id.description])
    }

    func endSelecting() {
        guard !Self.usesHandles else {
            clear()
            return selectingChanged(false)
        }
        selection.exitMode()
    }

    /// The phone's selection mode came or went (the selection's own taps can end it,
    /// taking the last block out): no text is edited while it's on.
    private func selectingChanged(_ isOn: Bool) {
        if isOn {
            editor.isEditable = false
        } else {
            isChoosingLayout = false
            editor.panels.sheetPage = nil
            editor.isEditable = !demo.isAgentWriting
            anchor = nil
            head = nil
        }
        layoutOverlays()
    }

    // MARK: Dragging

    /// The block a drag at `point` (list coordinates) picks up, if it picks one up. On
    /// the Mac: the handle's, or a block whose row doesn't take clicks (pressTakes). On a
    /// phone: any, but not from the text being typed in or a control.
    private func pickUp(at point: CGPoint) -> DocBlockID? {
        guard let list, drag == nil, !demo.isAgentWriting else { return nil }
        let hit = list.hitTest(point, with: nil)
        let chain = sequence(first: hit, next: { $0?.superview })
        if Self.usesHandles {
            if chain.contains(where: { $0 === handle }) { return hovered }
            return pressTakes(hit, at: point) ? block(at: point) : nil
        }
        guard !chain.contains(where: { $0 is UIControl || $0?.isFirstResponder == true }) else { return nil }
        return block(at: point)
    }

    /// Picks the block up: the selection if the block is in it, else the block alone,
    /// with the items nested under them. One drag item per block (the system counts
    /// them), each lifted from its own row.
    private func beginDrag(_ id: DocBlockID, at point: CGPoint) -> [UIDragItem] {
        guard let list else { return [] }
        let tops = selected.contains(id) ? topsOfSelection() : [id]
        let moving = groups(tops).flatMap { $0 }
        drag = Drag(tops: tops, moving: moving, grabbed: id, start: point, point: list.convert(point, to: list.superview))
        handle.isHidden = true
        return moving.map { block in
            let item = UIDragItem(itemProvider: NSItemProvider())
            item.localObject = block
            return item
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let list else { return [] }
        // A lift let go before it finished may leave its drag behind.
        if drag != nil { endDrag() }
        let point = session.location(in: list)
        guard let id = pickUp(at: point) else { return [] }
        return beginDrag(id, at: point)
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        true
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
        (item.localObject as? DocBlockID).flatMap(preview)
    }

    /// A block's row as the system lifts it and lands it: its content, on the page's
    /// lifted colour on a phone, nothing behind it on the Mac (the system shows it
    /// translucent). Nil off screen.
    private func preview(_ id: DocBlockID) -> UITargetedDragPreview? {
        guard let list, let frame = contentFrame(id)?.insetBy(dx: -6, dy: -4),
            frame.intersects(DocScrolling.visible(in: list)), let cell = cells(of: [id]).first
        else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: list.convert(frame, to: cell), cornerRadius: 8)
        parameters.backgroundColor = Self.usesHandles ? .clear
            : .systemBackground.resolvedColor(with: list.traitCollection.modifyingTraits { $0.userInterfaceLevel = .elevated })
        return UITargetedDragPreview(view: cell, parameters: parameters)
    }

    func dragInteraction(_ interaction: UIDragInteraction, willAnimateLiftWith animator: UIDragAnimating, session: UIDragSession) {
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            // Let go before the lift finished: nothing happens.
            if position == .end { self.drag?.isLifted = true } else if self.drag?.isMoving != true { self.endDrag() }
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
        editor.tables.endEditing()
        editor.sources.endEditing()
        // The rows lifted on the Mac move with the pointer at once.
        if Self.usesHandles { drag?.isLifted = true }
        link = CADisplayLink(target: self, selector: #selector(autoscroll(_:)))
        link?.add(to: .main, forMode: .common)
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: UIDragSession) {
        guard var drag, !drag.isMoving, let list else { return }
        let point = session.location(in: list)
        guard hypot(point.x - drag.start.x, point.y - drag.start.y) > (Self.usesHandles ? 4 : 10) else { return }
        // Moving: the rows it lifted dim where they are (Craft's).
        drag.isMoving = true
        self.drag = drag
        layoutOverlays()
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
        guard let drag = endDrag() else { return }
        // A phone's block lifted and let go where it was: selecting starts with it
        // (Composer's).
        if !Self.usesHandles, drag.isLifted, !drag.isMoving, !isSelecting { beginSelecting(drag.grabbed) }
    }

    // MARK: Dropping

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        drag != nil && session.localDragSession != nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard var drag, let list else { return UIDropProposal(operation: .forbidden) }
        drag.point = list.convert(session.location(in: list), to: list.superview)
        self.drag = drag
        updateTarget()
        return UIDropProposal(operation: self.drag?.target != nil ? .move : .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        drag?.target = nil
        indicator.isHidden = true
    }

    /// Moves the blocks with the layout motion: the rows they leave and join go to their
    /// new places (the list's reorder), the moved ones hidden in theirs, laid out at once
    /// so what the system flies lands where they will be.
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let drag, case .some(let after) = drag.target else { return }
        landing = drag.moving
        guard reshapeMoving(drag.tops, after: after) else {
            landing = []
            return
        }
        list?.window?.layoutIfNeeded()
        layoutOverlays()
    }

    private func reshapeMoving(_ tops: [DocBlockID], after: DocBlockID?) -> Bool {
        var moved = false
        reshape { moved = move(tops, after: after) }
        return moved
    }

    /// Whether a block's row is hidden while what was lifted from it lands.
    func isLanding(_ id: DocBlockID) -> Bool { landing.contains(id) }

    /// What was lifted flies from the pointer to where its block is now, its left edge on
    /// the block's: the system's picture of it, not the row's cell (the list keeps that
    /// where it lays it out).
    func dropInteraction(_ interaction: UIDropInteraction, previewForDropping item: UIDragItem, withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? {
        guard let list, let id = item.localObject as? DocBlockID, let frame = contentFrame(id)?.insetBy(dx: -6, dy: -4) else { return nil }
        let center = CGPoint(x: frame.minX + defaultPreview.size.width / 2, y: frame.midY)
        return defaultPreview.retargetedPreview(with: UIDragPreviewTarget(container: list, center: center))
    }

    /// The drop is down: nothing stays dimmed, whatever the animations reported.
    func dropInteraction(_ interaction: UIDropInteraction, concludeDrop session: UIDropSession) {
        landings = 0
        landing = []
        layoutOverlays()
    }

    /// The moved rows stay dimmed until what flies to them is down.
    func dropInteraction(_ interaction: UIDropInteraction, item: UIDragItem, willAnimateDropWith animator: UIDragAnimating) {
        landings += 1
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.landings -= 1
            if self.landings == 0 { self.landing = [] }
            self.layoutOverlays()
        }
    }

    /// Where the blocks would land under the pointer, and the line that shows it.
    private func updateTarget() {
        guard var drag, let list else { return }
        let point = list.convert(drag.point, from: list.superview)
        let gap = runGap(at: point, moving: drag.moving) ?? gap(atY: point.y).map { ($0, nil as CGRect?) }
        let target = gap.flatMap { destination(gap: $0.index, moving: drag.moving) }
        if !Self.usesHandles, target != drag.target, drag.target != nil { UISelectionFeedbackGenerator().selectionChanged() }
        drag.target = target
        self.drag = drag
        guard let gap, target != nil else {
            indicator.isHidden = true
            return
        }
        if let line = gap.line {
            indicator.frame = line
        } else if let lineY = lineY(gap: gap.index), let content = contentFrame(drag.tops[0]) {
            indicator.frame = CGRect(x: content.minX - 6, y: lineY - 1, width: content.width + 12, height: 2)
        } else {
            indicator.isHidden = true
            return
        }
        indicator.isHidden = false
    }

    /// Over a line of cards or a gallery's that the moving blocks would join, the gap
    /// between two of its blocks nearest the point, shown by an upright line between
    /// them (Craft's). Nil elsewhere, or for blocks that wouldn't join it.
    private func runGap(at point: CGPoint, moving: [DocBlockID]) -> (index: Int, line: CGRect?)? {
        guard let reader, let list else { return nil }
        let line = reader.contentFrames(intersecting: CGRect(x: 0, y: point.y, width: list.bounds.width, height: 1))
            .filter { $0.value.minY <= point.y && point.y < $0.value.maxY }
            .compactMap { hit in demo.rows.first { $0.id == hit.key }?.block }
            .filter { demo.runs[$0]?.kind != nil }
        guard let first = line.first.flatMap({ demo.doc.block($0) }), let run = DocMediaLayout.run(first.kind),
            moving.allSatisfy({ id in demo.doc.block(id).map { DocMediaLayout.run($0.kind) == run } ?? false })
        else { return nil }
        let frames = line.compactMap { id in contentFrame(id).map { (id, $0) } }
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        guard let (id, frame) = frames.min(by: { distance($0.1) < distance($1.1) }),
            let index = demo.doc.blocks.firstIndex(where: { $0.id == id })
        else { return nil }
        let isAfter = point.x > frame.midX
        let x = (isAfter ? frame.maxX : frame.minX) + (isAfter ? 1 : -1) * DocMediaLayout.gap / 2
        return (isAfter ? index + 1 : index, CGRect(x: x - 1, y: frame.minY, width: 2, height: frame.height))
    }

    /// The gap between blocks (an index into the document's blocks) nearest `y`.
    private func gap(atY y: CGFloat) -> Int? {
        guard let list, let reader else { return nil }
        // Rows by their block's place in the document.
        let places = Dictionary(uniqueKeysWithValues: demo.doc.blocks.enumerated().map { ($1.id, $0) })
        let index = Dictionary(demo.rows.compactMap { row in row.block.flatMap { places[$0] }.map { (row.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let rows = reader.contentFrames(intersecting: list.bounds.insetBy(dx: 0, dy: -400))
            .compactMap { id, frame in index[id].map { (first: $0, end: $0 + 1, frame: frame) } }
            .sorted { $0.first < $1.first }
        // A line of several is one gap before it and one after its last.
        var frames: [(first: Int, end: Int, frame: CGRect)] = []
        for row in rows {
            if let last = frames.last, last.end == row.first, abs(last.frame.minY - row.frame.minY) < 0.5 {
                frames[frames.count - 1] = (last.first, row.end, last.frame.union(row.frame))
            } else {
                frames.append(row)
            }
        }
        guard let first = frames.first, let last = frames.last else { return nil }
        if y < first.frame.minY { return first.first }
        for row in frames where y < row.frame.maxY {
            return y < row.frame.midY ? row.first : row.end
        }
        return last.end
    }

    /// The drop line: halfway through the space above the block after the gap, or under
    /// the last block.
    private func lineY(gap: Int) -> CGFloat? {
        let blocks = demo.doc.blocks
        if blocks.indices.contains(gap), let frame = rowFrame(blocks[gap].id) {
            return frame.minY + (demo.spacingAbove[blocks[gap].id.description] ?? 0) / 2
        }
        if blocks.indices.contains(gap - 1), let frame = contentFrame(blocks[gap - 1].id) { return frame.maxY + 6 }
        return nil
    }

    /// The block the moving blocks would follow if dropped in `gap`; nil when they'd
    /// stay where they are.
    private func destination(gap: Int, moving: [DocBlockID]) -> DocBlockID?? {
        let blocks = demo.doc.blocks.map(\.id)
        let movingSet = Set(moving)
        var before = min(gap, blocks.count) - 1
        while before >= 0, movingSet.contains(blocks[before]) { before -= 1 }
        let after = before >= 0 ? blocks[before] : nil
        var order = blocks.filter { !movingSet.contains($0) }
        let at = after.flatMap { order.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        order.insert(contentsOf: moving, at: at)
        return order == blocks ? nil : .some(after)
    }

    /// Stops following the pointer.
    @discardableResult
    private func endDrag() -> Drag? {
        guard let drag else { return nil }
        self.drag = nil
        link?.invalidate()
        link = nil
        indicator.isHidden = true
        layoutOverlays()
        followHover()
        return drag
    }

    /// Near the top or bottom edge the list scrolls, faster the closer the pointer is.
    @objc private func autoscroll(_ link: CADisplayLink) {
        guard let drag, drag.isMoving, let list else { return }
        let y = list.convert(drag.point, from: list.superview).y
        let visible = DocScrolling.visible(in: list)
        let edge: CGFloat = 56
        let speed: CGFloat = if y < visible.minY + edge {
            -min(1, (visible.minY + edge - y) / edge) * 14
        } else if y > visible.maxY - edge {
            min(1, (y - (visible.maxY - edge)) / edge) * 14
        } else { 0 }
        guard speed != 0 else { return }
        let top = -list.adjustedContentInset.top
        let bottom = max(top, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height)
        let offset = min(max(list.contentOffset.y + speed, top), bottom)
        guard abs(offset - list.contentOffset.y) > 0.1 else { return }
        list.contentOffset.y = offset
        updateTarget()
    }

    // MARK: Reshaping

    /// Makes a change that reshapes blocks (a layout, an image's size, a kind): each block
    /// changes to its new shape and the rows around it go to their new places together,
    /// with the layout motion (the rows are TiledView's to move, a block's content its own).
    func reshape(_ change: () -> Void) {
        withAnimation(FlooDesignTokens.Motion.layout) { change() }
    }

    // MARK: Model

    /// Each block with the items nested under it (a list item's deeper items), in
    /// document order; a block nested under another one given is part of that one.
    func groups(_ tops: [DocBlockID]) -> [[DocBlockID]] {
        let chosen = Set(tops)
        let blocks = demo.doc.blocks
        var result: [[DocBlockID]] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            index += 1
            guard chosen.contains(block.id) else { continue }
            var group = [block.id]
            if case .listItem = block.kind {
                while index < blocks.count, blocks[index].indent > block.indent {
                    group.append(blocks[index].id)
                    index += 1
                }
            }
            result.append(group)
        }
        return result
    }

    /// The selection's outermost blocks (those not nested in another selected one).
    private func topsOfSelection() -> [DocBlockID] {
        groups(selected).map { $0[0] }
    }

    /// Moves blocks (with their nested items) to follow `after` (nil: the top), as one
    /// transaction. A block can't land nested deeper than where it goes allows: it and
    /// its items come out by as many levels as needed.
    @discardableResult
    func move(_ tops: [DocBlockID], after: DocBlockID?) -> Bool {
        let groups = groups(tops)
        let moving = groups.flatMap { $0 }
        guard !moving.isEmpty, after.map({ !moving.contains($0) }) ?? true else { return false }
        var steps: [DocStep] = []
        var previous = after
        for id in moving {
            steps.append(.moveBlock(block: id, after: previous, from: nil))
            previous = id
        }
        var before = after.flatMap { demo.doc.block($0) }.map { (kind: $0.kind, indent: $0.indent) }
        for group in groups {
            guard let top = demo.doc.block(group[0]) else { continue }
            let limit = before.map { if case .listItem = $0.kind { $0.indent + 1 } else { $0.indent } } ?? 0
            let shift = min(0, limit - top.indent)
            for id in group {
                guard let block = demo.doc.block(id) else { continue }
                let indent = max(0, block.indent + shift)
                if indent != block.indent {
                    steps.append(.setBlock(block: id, kind: block.kind, indent: indent, previousKind: block.kind, previousIndent: block.indent))
                }
                before = (block.kind, indent)
            }
        }
        return demo.edit(steps, before: editor.selection, after: editor.selection) != nil
    }

    /// Deletes the selected blocks with the items nested under them (a table's database
    /// with it). The cursor goes to the end of the text before them.
    func deleteSelection() {
        let ids = Set(groups(selected).flatMap { $0 })
        let blocks = demo.doc.blocks
        guard !ids.isEmpty else { return }
        var steps: [DocStep] = []
        for block in blocks.reversed() where ids.contains(block.id) {
            steps.append(.deleteBlock(block: block, after: nil))
            if let database = block.kind.databaseID.flatMap({ demo.doc.databases[$0] }) {
                steps.append(.deleteDatabase(database: database))
            }
        }
        // A document keeps one line to type in.
        let remaining = blocks.filter { !ids.contains($0.id) }
        var caret: DocPosition?
        if remaining.isEmpty {
            let line = DocBlock(id: demo.newBlockID(), kind: .paragraph)
            steps.append(.insertBlock(block: line, after: nil))
            caret = DocPosition(block: line.id, offset: 0)
        } else if let first = blocks.firstIndex(where: { ids.contains($0.id) }),
            let previous = blocks[..<first].last(where: { $0.kind.carriesText }) {
            caret = DocPosition(block: previous.id, offset: previous.text.length)
        }
        let after = caret.map { DocSelection(anchor: $0, head: $0) }
        let wasSelecting = isSelecting
        clear()
        guard demo.edit(steps, before: editor.selection, after: after) != nil else { return }
        if let after, !wasSelecting { editor.place(after) }
    }

    // MARK: Media

    /// What the selected links, files and images are set to (several values: mixed).
    var selectedLayouts: Set<DocLayout> { Set(media(selected).compactMap(\.layout)) }
    var selectedImageFits: Set<DocImage.Fit> { Set(media(selected).compactMap(\.image?.fit)) }
    var selectedImageSizes: Set<DocImage.Size> { Set(media(selected).compactMap(\.image?.size)) }

    private func media(_ ids: [DocBlockID]) -> [(layout: DocLayout?, image: DocImage?)] {
        let chosen = Set(ids)
        return demo.doc.blocks.filter { chosen.contains($0.id) }.compactMap { block in
            switch block.kind {
            case .link(let link): (link.layout, nil)
            case .file(let file): (file.layout, nil)
            case .image(let image): (nil, image)
            default: nil
            }
        }
    }

    /// Links and files among these blocks (the selection by default) take `layout`,
    /// in one transaction.
    func setLayout(_ layout: DocLayout, of ids: [DocBlockID]? = nil) {
        reshape { change(ids ?? selected) { kind in
            switch kind {
            case .link(var link): link.layout = layout; return .link(link: link)
            case .file(var file): file.layout = layout; return .file(file: file)
            default: return nil
            }
        } }
    }

    func setImage(fit: DocImage.Fit? = nil, size: DocImage.Size? = nil, of ids: [DocBlockID]? = nil) {
        reshape { change(ids ?? selected) { kind in
            guard case .image(var image) = kind else { return nil }
            image.fit = fit ?? image.fit
            image.size = size ?? image.size
            return .image(image: image)
        } }
    }

    private func change(_ ids: [DocBlockID], _ transform: (BlockKind) -> BlockKind?) {
        let chosen = Set(ids)
        let steps: [DocStep] = demo.doc.blocks.filter { chosen.contains($0.id) }.compactMap { block in
            guard let kind = transform(block.kind), kind != block.kind else { return nil }
            return .setBlock(block: block.id, kind: kind, indent: block.indent, previousKind: block.kind, previousIndent: block.indent)
        }
        guard !steps.isEmpty else { return }
        demo.edit(steps, before: editor.selection, after: editor.selection)
    }

    /// The selected blocks of text become `kind` (as the slash menu turns one), in one
    /// transaction; the rest stay as they are.
    func turnSelection(into kind: BlockKind) {
        reshape { editor.setKind(kind, of: selected) }
    }

    /// A copy of the selected blocks (with the items nested under them) right after the
    /// last of them, in order; a table's copy gets a database of its own. The copies of
    /// the selected ones become the selection.
    func duplicateSelection() {
        let chosen = Set(selected)
        let ids = Set(groups(selected).flatMap { $0 })
        let originals = demo.doc.blocks.filter { ids.contains($0.id) }
        guard let last = originals.last else { return }
        var steps: [DocStep] = []
        var copies: [DocBlockID] = []
        var after = last.id
        for original in originals {
            var copy = original
            copy.id = demo.newBlockID()
            if case .database(let id, let view) = original.kind, var database = demo.doc.databases[id] {
                database.id = demo.newID()
                steps.append(.createDatabase(database: database))
                copy.kind = .database(id: database.id, view: view)
            }
            steps.append(.insertBlock(block: copy, after: after))
            after = copy.id
            if chosen.contains(original.id) { copies.append(copy.id) }
        }
        guard demo.edit(steps, before: editor.selection, after: editor.selection) != nil else { return }
        setSelection(copies)
    }

    /// The selected blocks (with the items nested under them) as markdown, on the
    /// pasteboard.
    func copySelection() {
        let ids = Set(groups(selected).flatMap { $0 })
        let blocks = demo.doc.blocks.filter { ids.contains($0.id) }
        guard !blocks.isEmpty else { return }
        UIPasteboard.general.string = Doc(id: demo.doc.id, blocks: blocks, databases: demo.doc.databases).markdown
    }

    // MARK: Tests

    /// A drag as the system would run it, for the edit tests: picks `id` up (as the
    /// handle or a long press would), moves to `y` (list coordinates), drops; what flies
    /// to the rows lands 0.3 s later. Where each block's row was to land on is kept
    /// (testLandings).
    func testDrag(_ id: DocBlockID, toY y: CGFloat, x: CGFloat? = nil) {
        guard let list, let frame = contentFrame(id) else { return }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        testRunDrag(beginDrag(id, at: start), from: start, to: CGPoint(x: x ?? start.x, y: y))
    }
    var testIndicatorFrame: CGRect? { indicator.isHidden ? nil : indicator.frame }
    /// Where the last drop's rows were to land, list coordinates.
    private(set) var testLandings: [DocBlockID: CGRect] = [:]

    private func testRunDrag(_ items: [UIDragItem], from start: CGPoint, to end: CGPoint) {
        guard let list, let dragging, let dropping, !items.isEmpty else { return }
        let session = DocTestDragSession(view: list, point: start, items: items)
        dragInteraction(dragging, sessionWillBegin: session)
        session.point = end
        dragInteraction(dragging, sessionDidMove: session)
        let drop = DocTestDropSession(drag: session)
        let proposal = dropInteraction(dropping, sessionDidUpdate: drop)
        testLandings = [:]
        guard proposal.operation == .move else {
            dragInteraction(dragging, session: session, didEndWith: .cancel)
            return
        }
        // The system's pictures of what it lifted, as it drops them.
        let lifted = items.compactMap { item in (item.localObject as? DocBlockID).flatMap { id in preview(id).map { (id, $0) } } }
        dropInteraction(dropping, performDrop: drop)
        let animator = DocTestAnimator()
        for item in items {
            if let id = item.localObject as? DocBlockID,
               let preview = dropInteraction(dropping, previewForDropping: item,
                                             withDefault: lifted.first { $0.0 == id }?.1 ?? UITargetedDragPreview(view: list)) {
                let center = list.convert(preview.target.center, from: preview.target.container)
                testLandings[id] = CGRect(x: center.x - preview.size.width / 2, y: center.y - preview.size.height / 2,
                                          width: preview.size.width, height: preview.size.height)
            }
            dropInteraction(dropping, item: item, willAnimateDropWith: animator)
        }
        dragInteraction(dragging, session: session, didEndWith: .move)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            animator.finish()
            if let self { self.dropInteraction(dropping, concludeDrop: drop) }
        }
    }

    /// A long press on a phone lifting `id` and let go without moving.
    func testLiftAndLetGo(_ id: DocBlockID) {
        guard let list, let dragging, let frame = contentFrame(id) else { return }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let session = DocTestDragSession(view: list, point: start, items: beginDrag(id, at: start))
        let lift = DocTestAnimator()
        dragInteraction(dragging, willAnimateLiftWith: lift, session: session)
        lift.finish()
        dragInteraction(dragging, sessionWillBegin: session)
        dragInteraction(dragging, session: session, didEndWith: .cancel)
    }

    /// How the system would lift a block's row.
    func testLiftPreview(_ id: DocBlockID) -> UITargetedDragPreview? { preview(id) }

    /// The phone's swipe on a block, `x` across.
    func testSwipe(_ id: DocBlockID, x: CGFloat) {
        swipeBegan(id)
        swipeMoved(x)
        swipeEnded(x, velocity: 0)
    }

    func testContentFrame(_ id: DocBlockID) -> CGRect? { contentFrame(id) }

    /// A press at the middle of a block's content, moved to `y` (list coordinates) or not
    /// moved (a click), as the Mac's click and drag on the list take it; false if they
    /// don't.
    @discardableResult
    func testPress(_ id: DocBlockID, toY y: CGFloat? = nil) -> Bool {
        guard let list, let frame = contentFrame(id) else { return false }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let hit = list.window?.hitTest(list.convert(start, to: nil), with: nil)
        guard pressTakes(hit, at: start) else { return false }
        if let y {
            guard pickUp(at: start) == id else { return false }
            testRunDrag(beginDrag(id, at: start), from: start, to: CGPoint(x: start.x, y: y))
        } else {
            click(id)
        }
        return true
    }

    /// A click at the middle of a block, as the list's click takes it.
    func testClick(_ id: DocBlockID) {
        guard let list, let frame = contentFrame(id) else { return }
        click(atWindowPoint: list.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil))
    }
    func testBlock(at point: CGPoint) -> DocBlockID? { block(at: point) }

    var testRowFrame: (DocBlockID) -> CGRect? { { [weak self] in self?.rowFrame($0) } }

    /// Scrolls a block's row to the top of the list.
    func testShowAtTop(_ id: DocBlockID) {
        reader?.scrollTo(id: id.description, anchor: .top, animated: false)
    }

    /// Scrolls a block's row to the middle of the list.
    func testCenter(_ id: DocBlockID) {
        reader?.scrollTo(id: id.description, anchor: .center, animated: false)
    }

    /// Where a block's row shows right now, moving included (list coordinates).
    func testShownRowFrame(_ id: DocBlockID) -> CGRect? {
        guard let cell = testCell(id) else { return nil }
        // A row on its way shows its contents shifted (TiledView's row moves).
        let shown = cell.layer.presentation() ?? cell.layer
        return shown.frame.offsetBy(dx: shown.sublayerTransform.m41, dy: shown.sublayerTransform.m42)
    }

    /// The cell at a block's place, without its transform (a row on its way has one).
    private func testCell(_ id: DocBlockID) -> UICollectionViewCell? {
        guard let list, let frame = rowFrame(id) else { return nil }
        return list.visibleCells.first {
            abs($0.center.y - $0.bounds.height / 2 - frame.minY) < 0.5 && abs($0.center.x - $0.bounds.width / 2 - frame.minX) < 0.5
                && abs($0.bounds.height - frame.height) < 0.5
        }
    }

    /// The blocks whose rows are dimmed now (lifted, or a drop landing on them).
    /// The blocks whose rows are hidden while a drop lands on them.
    var testLanding: Set<DocBlockID> { Set(landing) }
    var testDimmed: Set<DocBlockID> {
        let shown = dimmers.filter { !$0.isHidden }.map(\.frame)
        return Set(demo.doc.blocks.map(\.id).filter { id in
            contentFrame(id).map { frame in shown.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) } } ?? false
        })
    }

    /// How far down a block's row draws its box right now, moving included (list
    /// coordinates): the bottom of the lowest layer in it that clips or has a border (a
    /// card's box, an image's frame), as SwiftUI lays them out frame by frame.
    /// The page's width in the list now.
    var testPageWidth: CGFloat { Self.pageWidth(inWidth: list?.bounds.width ?? 0) }
    var testListWidth: CGFloat? { list?.bounds.width }
    /// The list's width set to each of `widths` in turn, each laid out at once (as a
    /// window being resized): the main thread's time for each, in ms. The list keeps the
    /// last width.
    func testResize(through widths: [CGFloat]) -> [Double] {
        guard let list, let host = list.superview else { return [] }
        return widths.map { width in
            let start = CACurrentMediaTime()
            host.frame.size.width = width
            host.layoutIfNeeded()
            return (CACurrentMediaTime() - start) * 1000
        }
    }

    /// The rows on screen whose height isn't their contents' at the row's width.
    var testMisfitRows: [String] {
        guard let list else { return [] }
        return list.visibleCells.compactMap { cell in
            guard let host = cell.contentView.subviews.first else { return nil }
            let fit = host.sizeThatFits(CGSize(width: cell.bounds.width, height: .greatestFiniteMagnitude)).height
            guard abs(fit - cell.bounds.height) > 0.5 else { return nil }
            return "row at \(Int(cell.frame.minY)) is \(cell.bounds.height) high for \(fit)"
        }
    }

    func testShownBoxBottom(_ id: DocBlockID) -> CGFloat? {
        testShownBox(id)?.frame.maxY
    }

    /// Where a block's row draws its box right now, moving included (list coordinates):
    /// the layers in it that clip or have a border (a card's box, an image's frame), and
    /// how opaque the row is.
    func testShownBox(_ id: DocBlockID) -> (frame: CGRect, opacity: Float)? {
        guard let cell = testCell(id) else { return nil }
        let root = cell.layer.presentation() ?? cell.layer
        // Not the row's own layers: a box is at most as wide as the page its content is
        // laid out in (going from one place to another, wider than its place).
        let widest = (list.map { Self.pageWidth(inWidth: $0.bounds.width) } ?? cell.bounds.width - 2) + 1
        var frame: CGRect?
        // The cell's, its content view's and what it hosts (a row fading in or out).
        let hosted = cell.contentView.subviews.map { ($0.layer.presentation() ?? $0.layer).opacity }
        let opacity = root.opacity * (cell.contentView.layer.presentation() ?? cell.contentView.layer).opacity * (hosted.min() ?? 1)
        // Each layer as far as the layers clipping it show it (a picture filling its box is
        // bigger than the box).
        func visit(_ layer: CALayer, depth: Int, clip: CGRect) {
            let shown = layer.presentation() ?? layer
            // In the cell's coordinates, its contents' shift included.
            let bounds = shown.convert(shown.bounds, to: root).offsetBy(dx: root.frame.minX, dy: root.frame.minY)
            if depth > 0, shown.masksToBounds || shown.borderWidth > 0, bounds.width < widest {
                let box = bounds.intersection(clip)
                if !box.isNull { frame = frame?.union(box) ?? box }
            }
            let inner = depth > 0 && shown.masksToBounds ? clip.intersection(bounds) : clip
            for sublayer in layer.sublayers ?? [] { visit(sublayer, depth: depth + 1, clip: inner) }
        }
        visit(cell.layer, depth: 0, clip: .infinite)
        return frame.map { ($0, opacity) }
    }
    var testHighlightFrames: [CGRect] { highlights.filter { !$0.isHidden }.map(\.frame) }
    var testHandleFrame: CGRect? { Self.usesHandles && !handle.isHidden ? handle.frame : nil }

    /// Whether the row's click takes a click on the handle (it mustn't).
    var testRowClickTakesHandle: Bool { rowClickTakes(handle) }

    func testHover(_ id: DocBlockID) {
        guard let list, let frame = rowFrame(id) else { return }
        hoverPoint = list.convert(CGPoint(x: frame.midX, y: frame.midY), to: list.superview)
        followHover()
    }

    /// The key window as a PNG at `path`, for screenshots without screen recording.
    static func drawWindow(to path: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: path))
    }
}

/// The six dots beside a block (Craft's): darker, on a soft background, under the pointer.
final class DocBlockHandleView: UIView {
    static let size = CGSize(width: 18, height: 24)
    private let dots = CAShapeLayer()
    private var isHovered = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        layer.addSublayer(dots)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        addInteraction(UIToolTipInteraction(defaultToolTip: String(localized: "Click to select, drag to move")))
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Block handle")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Two columns of three dots, centred.
    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter: CGFloat = 3, pitch: CGFloat = 5
        let origin = CGPoint(x: bounds.midX - (pitch + diameter) / 2, y: bounds.midY - (2 * pitch + diameter) / 2)
        let path = UIBezierPath()
        for column in 0..<2 {
            for row in 0..<3 {
                path.append(UIBezierPath(ovalIn: CGRect(x: origin.x + CGFloat(column) * pitch, y: origin.y + CGFloat(row) * pitch,
                                                        width: diameter, height: diameter)))
            }
        }
        dots.frame = bounds
        dots.path = path.cgPath
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        backgroundColor = isHovered ? .quaternarySystemFill : .clear
        dots.fillColor = (isHovered ? UIColor.secondaryLabel : .tertiaryLabel).resolvedColor(with: traitCollection).cgColor
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        isHovered = recognizer.state == .began || recognizer.state == .changed
        updateColors()
    }
}

/// Takes the keys while blocks are selected on the Mac: Delete, Esc, ↑ ↓ (⇧ extends),
/// Return to edit, ⌘C ⌘X; ⌘Z stays the document's.
final class DocBlockKeyView: UIView {
    weak var controller: DocBlockController?

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        alpha = 0.01
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { controller?.keysResigned() }
        return resigned
    }

    override var undoManager: UndoManager? { controller?.editor.undoManager }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(deleteBlocks)),
            UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(deleteBlocks)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(edit)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .shift, action: #selector(extendUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: .shift, action: #selector(extendDown)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) || action == #selector(cut(_:)) || action == #selector(delete(_:)) {
            return !(controller?.selected.isEmpty ?? true)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) { controller?.copySelection() }

    override func cut(_ sender: Any?) {
        controller?.copySelection()
        controller?.deleteSelection()
    }

    override func delete(_ sender: Any?) { controller?.deleteSelection() }

    @objc private func deleteBlocks() { controller?.deleteSelection() }
    @objc private func escape() { controller?.clear() }
    @objc private func edit() { controller?.editSelection() }
    @objc private func up() { controller?.step(-1, extending: false) }
    @objc private func down() { controller?.step(1, extending: false) }
    @objc private func extendUp() { controller?.step(-1, extending: true) }
    @objc private func extendDown() { controller?.step(1, extending: true) }
}

/// The phone's actions on the selected blocks, as Craft's panel: a floating glass
/// panel of tiles, each its own color, its symbol over its name. Layout turns it into
/// the layouts of the selected links, files and images.
struct DocBlockSelectionBar: View {
    let blocks: DocBlockController

    var body: some View {
        VStack {
            if blocks.isSelecting {
                let formatting = blocks.editor.panels.sheetPage != nil
                let radius = formatting ? FlooDesignTokens.Component.FormatSheet.cornerRadius : 26
                Group {
                    if blocks.isChoosingLayout {
                        layouts
                    } else if formatting {
                        DocFormatSheet(editor: blocks.editor) { blocks.editor.panels.sheetPage = nil }
                    } else {
                        actions
                    }
                }
                .padding(formatting ? 0 : 8)
                .background(.regularMaterial, in: .rect(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(FlooDesignTokens.Motion.layout, value: blocks.isSelecting)
        .animation(FlooDesignTokens.Motion.layout, value: blocks.isChoosingLayout)
        .animation(FlooDesignTokens.Motion.layout, value: blocks.editor.panels.sheetPage == nil)
    }

    private var hasMedia: Bool {
        !blocks.selectedLayouts.isEmpty || !blocks.selectedImageFits.isEmpty
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                blocks.editor.panels.sheetPage = .main
            } label: {
                DocSelectionTile(title: String(localized: "Style"), symbol: "textformat", color: Color(red: 0.42, green: 0.13, blue: 0.78))
            }
            .accessibilityIdentifier("selection-style")
            if hasMedia {
                Button {
                    blocks.isChoosingLayout = true
                } label: {
                    DocSelectionTile(title: String(localized: "Layout"), symbol: "rectangle.split.2x1", color: Color(red: 0.2, green: 0.27, blue: 0.36))
                }
            }
            Menu {
                Button("Copy", systemImage: "doc.on.doc") {
                    blocks.copySelection()
                    blocks.endSelecting()
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { blocks.duplicateSelection() }
            } label: {
                DocSelectionTile(title: String(localized: "Actions"), symbol: "square.and.arrow.up", color: Color(red: 0.2, green: 0.27, blue: 0.36))
            }
            Button {
                blocks.deleteSelection()
            } label: {
                DocSelectionTile(title: String(localized: "Delete"), symbol: "trash", color: Color(red: 0.82, green: 0.06, blue: 0.13))
            }
        }
        .buttonStyle(.plain)
    }

    /// Craft's layout sheet: a grabber (tap or pull down to go back), then the options.
    private var layouts: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 14)
                .contentShape(Rectangle())
                .onTapGesture { blocks.isChoosingLayout = false }
            if !blocks.selectedImageFits.isEmpty {
                HStack(spacing: 8) {
                    DocLayoutSection(title: String(localized: "Image Display")) {
                        option(String(localized: "Fit"), symbol: "arrow.down.and.line.horizontal.and.arrow.up", on: blocks.selectedImageFits == [.fit]) { blocks.setImage(fit: .fit) }
                        option(String(localized: "Fill"), symbol: "square.arrowtriangle.4.outward", on: blocks.selectedImageFits == [.fill]) { blocks.setImage(fit: .fill) }
                    }
                    DocLayoutSection(title: String(localized: "Image Size")) {
                        option(String(localized: "Auto"), symbol: "rectangle.center.inset.filled", on: blocks.selectedImageSizes == [.auto]) { blocks.setImage(size: .auto) }
                        option(String(localized: "Large"), symbol: "rectangle", on: blocks.selectedImageSizes == [.large]) { blocks.setImage(size: .large) }
                    }
                }
            }
            if !blocks.selectedLayouts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(DocLayout.allCases, id: \.self) { layout in
                        Button {
                            blocks.setLayout(layout)
                        } label: {
                            DocLayoutOption(title: layout.title, isOn: blocks.selectedLayouts == [layout]) {
                                DocLayoutIllustration(layout: layout)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .gesture(DragGesture(minimumDistance: 12).onEnded { if $0.translation.height > 30 { blocks.isChoosingLayout = false } })
    }

    private func option(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DocLayoutOption(title: title, isOn: on) {
                Image(systemName: symbol).font(.system(size: 18))
            }
        }
    }

}

extension DocLayout {
    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .regular: String(localized: "Regular")
        case .card: String(localized: "Card")
        }
    }
}

/// A titled group of options (the image's fit, its size).
private struct DocLayoutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) { content() }
        }
    }
}

/// One layout option: its picture over its name, outlined in the tint when chosen.
private struct DocLayoutOption<Picture: View>: View {
    let title: String
    let isOn: Bool
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        VStack(spacing: 6) {
            picture()
                .frame(height: 30)
            Text(title)
                .font(.system(size: 13))
        }
        .foregroundStyle(isOn ? Color.accentColor : .primary)
        .frame(maxWidth: .infinity, minHeight: 70)
        .padding(.horizontal, 6)
        .background(isOn ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            if isOn { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5) }
        }
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
    }
}

/// Craft's little pictures of the layouts: a warm thumbnail and lines of text.
struct DocLayoutIllustration: View {
    let layout: DocLayout

    var body: some View {
        switch layout {
        case .small:
            HStack(spacing: 3) {
                thumbnail.frame(width: 12, height: 9)
                line(width: 18)
            }
            .padding(4)
            .background(.background, in: .rect(cornerRadius: 3))
        case .regular:
            HStack(spacing: 4) {
                thumbnail.frame(width: 18, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    line(width: 22)
                    line(width: 14)
                }
            }
            .padding(4)
            .background(.background, in: .rect(cornerRadius: 3))
        case .card:
            VStack(alignment: .leading, spacing: 3) {
                thumbnail.frame(width: 34, height: 14)
                line(width: 22).padding(.leading, 2)
            }
            .padding(.bottom, 3)
            .background(.background, in: .rect(cornerRadius: 3))
        }
    }

    private var thumbnail: some View {
        LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.3), Color(red: 0.62, green: 0.36, blue: 0.3)], startPoint: .top, endPoint: .bottom)
            .clipShape(.rect(cornerRadius: 2))
    }

    private func line(width: CGFloat) -> some View {
        Capsule().fill(Color(.systemGray3)).frame(width: width, height: 2.5)
    }
}

/// One of the panel's tiles: its color's symbol over its name, on a wash of the color.
private struct DocSelectionTile: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(height: 26)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(color.opacity(0.7))
        }
        .foregroundStyle(color)
        .frame(width: 64, height: 66)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Test sessions

/// A drag session for the edit tests: the system's drags can't be made by hand.
@MainActor
final class DocTestDragSession: NSObject, UIDragSession {
    let view: UIView
    var point: CGPoint
    let items: [UIDragItem]
    var localContext: Any?

    init(view: UIView, point: CGPoint, items: [UIDragItem]) {
        self.view = view
        self.point = point
        self.items = items
    }

    func location(in view: UIView) -> CGPoint { view.convert(point, from: self.view) }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { true }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
}

@MainActor
final class DocTestDropSession: NSObject, UIDropSession {
    let drag: DocTestDragSession
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    nonisolated let progress = Progress()

    init(drag: DocTestDragSession) { self.drag = drag }

    var localDragSession: (any UIDragSession)? { drag }
    var items: [UIDragItem] { drag.items }
    func location(in view: UIView) -> CGPoint { drag.location(in: view) }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { true }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(ofClass aClass: any NSItemProviderReading.Type, completion: @escaping ([any NSItemProviderReading]) -> Void) -> Progress {
        Progress()
    }
}

/// A lift's or a drop's animation that ends when told to.
@MainActor
final class DocTestAnimator: NSObject, UIDragAnimating {
    private var completions: [(UIViewAnimatingPosition) -> Void] = []

    func addAnimations(_ animations: @escaping () -> Void) { animations() }
    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) { completions.append(completion) }

    func finish() {
        let done = completions
        completions = []
        for completion in done { completion(.end) }
    }
}
