//
//  MarkdownSelectionView.swift
//  MarkdownUIKit
//
//  One selection over a list's rows, with the system's handles, loupe and menu: a read-only
//  `UITextInput` whose text is every row's, in order, and whose geometry is the layout the rows
//  draw with. It lies over the list's content, where the system draws the selection; the list
//  takes the gestures. Rows off screen have text but no geometry: a selection reaching into them
//  copies them and draws only what's on screen.
//

import UIKit

/// What a list gives a selection: its rows' text, and their layout while they're on screen.
@MainActor
public protocol MarkdownSelectionSource: AnyObject {
    var selectionRowCount: Int { get }
    /// A row's texts as laid out, in reading order, if it's on screen.
    func selectionTexts(ofRow row: Int) -> [MarkdownSelectableText]?
    /// A row's texts for one off screen, the same as it would have on screen: what they say and
    /// copy as, with no geometry asked of them.
    func selectionOffscreenTexts(ofRow row: Int) -> [MarkdownSelectableText]
    /// The rows on screen.
    var selectionVisibleRows: [Int] { get }
    /// The rows of the message `row` is in: a selection stays inside one.
    func selectionMessageRows(containing row: Int) -> ClosedRange<Int>
}

public extension MarkdownSelectionSource {
    func selectionMessageRows(containing row: Int) -> ClosedRange<Int> { 0...max(0, selectionRowCount - 1) }
}

final class MarkdownTextPosition: UITextPosition {
    let row: Int
    let offset: Int

    init(row: Int, offset: Int) {
        self.row = row
        self.offset = offset
    }

    static func < (a: MarkdownTextPosition, b: MarkdownTextPosition) -> Bool {
        a.row != b.row ? a.row < b.row : a.offset < b.offset
    }

    override var description: String { "(\(row), \(offset))" }
}

final class MarkdownTextRange: UITextRange {
    let from: MarkdownTextPosition
    let to: MarkdownTextPosition

    init(_ a: MarkdownTextPosition, _ b: MarkdownTextPosition) {
        (from, to) = b < a ? (b, a) : (a, b)
    }

    override var start: UITextPosition { from }
    override var end: UITextPosition { to }
    override var isEmpty: Bool { from.row == to.row && from.offset == to.offset }
}

private final class MarkdownSelectionRect: UITextSelectionRect {
    let box: CGRect
    let isStart: Bool
    let isEnd: Bool

    init(_ box: CGRect, start: Bool, end: Bool) {
        self.box = box
        isStart = start
        isEnd = end
    }

    override var rect: CGRect { box }
    override var writingDirection: NSWritingDirection { .natural }
    override var containsStart: Bool { isStart }
    override var containsEnd: Bool { isEnd }
    override var isVertical: Bool { false }
}

@MainActor
public final class MarkdownSelectionView: UIView, UITextInput {
    public weak var source: MarkdownSelectionSource?
    /// A tap on a link, with nothing selected.
    public var openURL: ((URL) -> Void)?

    private weak var list: UIScrollView?
    private let interaction = UITextInteraction(for: .nonEditable)
    private var selection: MarkdownTextRange?
    private var contentSizeObservation: NSKeyValueObservation?
    private lazy var linkTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    /// Three taps or clicks: the line under them.
    private lazy var lineTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedThrice(_:)))
        tap.numberOfTapsRequired = 3
        return tap
    }()
    /// Where a finger or pointer extending the selection is, in the list's visible frame.
    private var dragPoint: CGPoint?
    /// The end a drag doesn't move, while one extends the selection.
    private var dragAnchor: MarkdownTextPosition?
    private var autoScroll: CADisplayLink?
    /// The drag under way has scrolled the list: while it holds at the edge, the selection is
    /// what scrolling made it, not what the interaction would make of the finger.
    private var didAutoScroll = false
    private var followedGestures: Set<ObjectIdentifier> = []

    /// Lies over `list`'s content and selects in it.
    public init(list: UIScrollView, source: MarkdownSelectionSource) {
        self.list = list
        self.source = source
        super.init(frame: .zero)
        backgroundColor = nil
        // The rows speak for themselves.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        // Over the rows, wherever the list puts them.
        layer.zPosition = 10_000
        list.addSubview(self)
        // The interaction's gestures go on the text input's view: this. It takes touches on text
        // only (hitTest), and the list scrolls under it as it would under the rows.
        interaction.textInput = self
        addInteraction(interaction)
        followInteractionGestures()
        addGestureRecognizer(linkTap)
        addGestureRecognizer(lineTap)
        contentSizeObservation = list.observe(\.contentSize, options: [.initial, .new]) { [weak self] list, _ in
            MainActor.assumeIsolated { self?.fit(to: list) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Text on screen, and anywhere while something's selected (its handles, and a tap away that
    /// clears it); elsewhere the rows' own views.
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, let source else { return nil }
        if let selection, !selection.isEmpty { return self }
        for row in source.selectionVisibleRows {
            for text in texts(row) ?? [] where text.frame(in: self).insetBy(dx: -4, dy: -4).contains(point) {
                return self
            }
        }
        return nil
    }

    private func fit(to list: UIScrollView) {
        let size = CGSize(width: max(list.contentSize.width, list.bounds.width), height: max(list.contentSize.height, list.bounds.height))
        if frame != CGRect(origin: .zero, size: size) { frame = CGRect(origin: .zero, size: size) }
    }

    /// Rows came into view or changed: the selection is drawn again over what's there now.
    public func rowsDidChange() {
        guard selection != nil else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    public func clearSelection() {
        guard selection != nil else { return }
        inputDelegate?.selectionWillChange(self)
        selection = nil
        inputDelegate?.selectionDidChange(self)
    }

    // MARK: Rows

    private var rowCount: Int { source?.selectionRowCount ?? 0 }

    private func texts(_ row: Int) -> [MarkdownSelectableText]? {
        source?.selectionTexts(ofRow: row)
    }

    /// On screen or not: for what a row says and copies, not where.
    private func anyTexts(_ row: Int) -> [MarkdownSelectableText] {
        guard row >= 0, row < rowCount else { return [] }
        return texts(row) ?? source?.selectionOffscreenTexts(ofRow: row) ?? []
    }

    private func string(_ row: Int) -> NSString {
        MarkdownSelectableText.joined(anyTexts(row)) as NSString
    }

    private func length(_ row: Int) -> Int { string(row).length }

    /// The text a row offset is in, and the offset in it.
    private func segment(_ offset: Int, in texts: [MarkdownSelectableText]) -> (index: Int, offset: Int)? {
        var start = 0
        for (index, text) in texts.enumerated() {
            let length = text.length
            if offset <= start + length { return (index, offset - start) }
            start += length + 1
        }
        return texts.isEmpty ? nil : (texts.count - 1, texts[texts.count - 1].length)
    }

    private func clamp(_ position: MarkdownTextPosition) -> MarkdownTextPosition {
        let row = max(0, min(position.row, rowCount - 1))
        return MarkdownTextPosition(row: row, offset: max(0, min(position.offset, length(row))))
    }

    // MARK: UITextInput

    public var selectedTextRange: UITextRange? {
        get { selection }
        set {
            followInteractionGestures()
            if didAutoScroll, let point = dragPoint, edgeSpeed(at: point) != 0 { return }
            selection = (newValue as? MarkdownTextRange).map { keptInOneMessage($0, after: selection) }
        }
    }

    /// Follows the interaction's own gestures, which it adds as it needs them: a drag near the
    /// list's edge scrolls it.
    private func followInteractionGestures() {
        let recognizers = (gestureRecognizers ?? []) + interaction.gesturesForFailureRequirements
        for recognizer in recognizers where recognizer !== linkTap && recognizer !== lineTap && !followedGestures.contains(ObjectIdentifier(recognizer)) {
            followedGestures.insert(ObjectIdentifier(recognizer))
            recognizer.addTarget(self, action: #selector(followed(_:)))
        }
    }

    /// `range` with its moving end inside the message its other end is in. A drag moving an
    /// end is remembered, for scrolling at the list's edge.
    private func keptInOneMessage(_ range: MarkdownTextRange, after old: MarkdownTextRange?) -> MarkdownTextRange {
        guard rowCount > 0 else { return range }
        // The anchor is the end that stayed (a drag past it swaps the ends); a new range's is
        // its start. While a drag extends it, the end nearer the finger is the one it moves.
        func same(_ a: MarkdownTextPosition, _ b: MarkdownTextPosition) -> Bool { a.row == b.row && a.offset == b.offset }
        var anchorIsFrom = true
        if let list, let point = dragPoint, !range.isEmpty,
           let finger = closestPosition(to: list.convert(CGPoint(x: point.x + list.contentOffset.x, y: point.y + list.contentOffset.y), to: self)) {
            anchorIsFrom = abs(offset(from: finger, to: range.to)) <= abs(offset(from: finger, to: range.from))
        } else if let old, !same(range.from, old.from), !same(range.from, old.to), same(range.to, old.from) || same(range.to, old.to) {
            anchorIsFrom = false
        }
        let anchor = anchorIsFrom ? range.from : range.to
        dragAnchor = dragPoint != nil && !range.isEmpty ? anchor : nil
        let moving = anchorIsFrom ? range.to : range.from
        let clamped = clampToMessage(moving, of: anchor.row)
        return MarkdownTextRange(anchor, clamped)
    }

    private func clampToMessage(_ position: MarkdownTextPosition, of row: Int) -> MarkdownTextPosition {
        guard let rows = source?.selectionMessageRows(containing: max(0, min(row, rowCount - 1))) else { return position }
        if position.row < rows.lowerBound { return MarkdownTextPosition(row: rows.lowerBound, offset: 0) }
        if position.row > rows.upperBound { return MarkdownTextPosition(row: rows.upperBound, offset: length(rows.upperBound)) }
        return position
    }

    public var markedTextRange: UITextRange? { nil }
    public var markedTextStyle: [NSAttributedString.Key: Any]?
    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    public func unmarkText() {}
    public weak var inputDelegate: UITextInputDelegate?
    public lazy var tokenizer: UITextInputTokenizer = MarkdownSelectionTokenizer(view: self)
    public var hasText: Bool { rowCount > 0 }
    public func insertText(_ text: String) {}
    public func deleteBackward() {}
    public func replace(_ range: UITextRange, withText text: String) {}

    public var beginningOfDocument: UITextPosition { MarkdownTextPosition(row: 0, offset: 0) }

    public var endOfDocument: UITextPosition {
        let last = max(0, rowCount - 1)
        return MarkdownTextPosition(row: last, offset: length(last))
    }

    public func text(in range: UITextRange) -> String? {
        guard let range = range as? MarkdownTextRange else { return nil }
        let from = clamp(range.from), to = clamp(range.to)
        var pieces: [String] = []
        for row in from.row...max(from.row, to.row) {
            let start = row == from.row ? from.offset : 0
            let end = row == to.row ? to.offset : length(row)
            pieces.append(copied(row: row, from: start, to: end))
        }
        return pieces.joined(separator: "\n")
    }

    /// A row's text from `start` to `end`, as copied: each of its texts as it copies, with what
    /// joins them (a tab between a table row's cells).
    private func copied(row: Int, from start: Int, to end: Int) -> String {
        guard end > start else { return "" }
        let texts = anyTexts(row)
        var out = ""
        var at = 0
        for text in texts {
            let length = text.length
            let low = max(start, at), high = min(end, at + length)
            if high > low { out += text.copied(NSRange(location: low - at, length: high - low)) }
            // The separator after it, if the range goes past it.
            if at + length < end, at + length >= start { out.append(text.separator) }
            at += length + 1
            if at >= end { break }
        }
        return out
    }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let a = fromPosition as? MarkdownTextPosition, let b = toPosition as? MarkdownTextPosition else { return nil }
        return MarkdownTextRange(a, b)
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? MarkdownTextPosition, rowCount > 0 else { return nil }
        var row = position.row, at = position.offset + offset
        // Each row ends in a newline that joins it to the next.
        while at < 0 {
            guard row > 0 else { return nil }
            row -= 1
            at += length(row) + 1
        }
        while at > length(row) {
            guard row < rowCount - 1 else { return nil }
            at -= length(row) + 1
            row += 1
        }
        return MarkdownTextPosition(row: row, offset: at)
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left: self.position(from: position, offset: -offset)
        case .right: self.position(from: position, offset: offset)
        default: nil
        }
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? MarkdownTextPosition, let b = other as? MarkdownTextPosition else { return .orderedSame }
        return a < b ? .orderedAscending : b < a ? .orderedDescending : .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? MarkdownTextPosition, let b = toPosition as? MarkdownTextPosition else { return 0 }
        if a.row == b.row { return b.offset - a.offset }
        let (low, high, sign) = a < b ? (a, b, 1) : (b, a, -1)
        var distance = length(low.row) - low.offset + 1
        for row in (low.row + 1)..<high.row { distance += length(row) + 1 }
        return sign * (distance + high.offset)
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: range.start
        default: range.end
        }
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let other = self.position(from: position, in: direction, offset: 1) else { return nil }
        return textRange(from: position, to: other)
    }

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    public func firstRect(for range: UITextRange) -> CGRect {
        selectionRects(for: range).first?.rect ?? .null
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard let position = position as? MarkdownTextPosition, let texts = texts(position.row),
              let (index, offset) = segment(position.offset, in: texts) else { return .zero }
        let rect = texts[index].caretRect(at: offset, in: self)
        return rect.isNull ? .zero : rect
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let range = range as? MarkdownTextRange, rowCount > 0 else { return [] }
        let from = clamp(range.from), to = clamp(range.to)
        var boxes: [(rect: CGRect, start: Bool, end: Bool)] = []
        for row in from.row...max(from.row, to.row) {
            guard let texts = texts(row) else { continue }
            let rowStart = row == from.row ? from.offset : 0
            let rowEnd = row == to.row ? to.offset : Int.max
            var start = 0
            for text in texts {
                let length = text.length
                let low = max(rowStart, start), high = min(rowEnd, start + length)
                if high > low {
                    let rects = text.rects(for: NSRange(location: low - start, length: high - low), in: self)
                    for (index, rect) in rects.enumerated() {
                        boxes.append((rect, row == from.row && low == from.offset && index == 0, row == to.row && high == to.offset && index == rects.count - 1))
                    }
                }
                start += length + 1
            }
        }
        return boxes.map { MarkdownSelectionRect($0.rect, start: $0.start, end: $0.end) }
    }

    /// The nearest text on screen, by height first, and the place in it nearest `point`.
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let source else { return nil }
        var best: (distance: CGFloat, row: Int, offset: Int)?
        for row in source.selectionVisibleRows {
            guard let texts = texts(row) else { continue }
            var start = 0
            for text in texts {
                let frame = text.frame(in: self)
                if !frame.isNull {
                    let distance = point.y < frame.minY ? frame.minY - point.y : max(0, point.y - frame.maxY)
                    if best.map({ distance < $0.distance }) ?? true {
                        best = (distance, row, start + text.offset(closestTo: point, in: self))
                    }
                }
                start += text.length + 1
            }
        }
        return best.map { MarkdownTextPosition(row: $0.row, offset: $0.offset) }
    }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let position = closestPosition(to: point) as? MarkdownTextPosition,
              let range = range as? MarkdownTextRange else { return nil }
        if position < range.from { return range.from }
        if range.to < position { return range.to }
        return position
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        guard let position = closestPosition(to: point) else { return nil }
        return characterRange(byExtending: position, in: .right)
    }

    public var textInputView: UIView { self }

    // MARK: Menu

    public override var canBecomeFirstResponder: Bool { true }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return selection.map { !$0.isEmpty } ?? false }
        if action == #selector(selectAll(_:)) { return rowCount > 0 }
        return false
    }

    /// The whole message the selection is in, or the first on screen.
    public override func selectAll(_ sender: Any?) {
        guard rowCount > 0, let range = messageRange(containing: selection?.from.row ?? source?.selectionVisibleRows.first ?? 0) else { return }
        inputDelegate?.selectionWillChange(self)
        selection = range
        inputDelegate?.selectionDidChange(self)
    }

    /// Selects the message `row` is in.
    public func selectMessage(containing row: Int) {
        guard let range = messageRange(containing: row) else { return }
        inputDelegate?.selectionWillChange(self)
        selection = range
        inputDelegate?.selectionDidChange(self)
    }

    /// Every row of the message `row` is in.
    func messageRange(containing row: Int) -> MarkdownTextRange? {
        guard rowCount > 0, let rows = source?.selectionMessageRows(containing: max(0, min(row, rowCount - 1))) else { return nil }
        return MarkdownTextRange(MarkdownTextPosition(row: rows.lowerBound, offset: 0), MarkdownTextPosition(row: rows.upperBound, offset: length(rows.upperBound)))
    }

    /// The row's raw text, as positions count it.
    func rowString(_ row: Int) -> NSString { string(row) }
    var rowsCount: Int { rowCount }

    @objc private func tappedThrice(_ recognizer: UITapGestureRecognizer) {
        guard let position = closestPosition(to: recognizer.location(in: self)),
              let line = tokenizer.rangeEnclosingPosition(position, with: .paragraph, inDirection: .storage(.forward)) as? MarkdownTextRange else { return }
        if !isFirstResponder { becomeFirstResponder() }
        inputDelegate?.selectionWillChange(self)
        selection = line
        inputDelegate?.selectionDidChange(self)
    }

    // MARK: Scrolling at the edge



    @objc private func followed(_ recognizer: UIGestureRecognizer) {
        guard let list else { return }
        switch recognizer.state {
        case .began, .changed:
            if recognizer.state == .began { didAutoScroll = false }
            let point = recognizer.location(in: list)
            dragPoint = CGPoint(x: point.x - list.contentOffset.x, y: point.y - list.contentOffset.y)
            if autoScroll == nil {
                let link = CADisplayLink(target: self, selector: #selector(scrollTick))
                link.add(to: .main, forMode: .common)
                autoScroll = link
            }
        default:
            dragPoint = nil
            dragAnchor = nil
            didAutoScroll = false
            autoScroll?.invalidate()
            autoScroll = nil
        }
    }

    /// How fast a drag at `point` (in the list's visible frame) scrolls it: up is negative, 0
    /// away from its edges, 1 at or past one.
    private func edgeSpeed(at point: CGPoint) -> CGFloat {
        guard let list else { return 0 }
        // The edges are what's seen: a list's content insets can stand for other things (a
        // virtual content's ends), its safe area is what bars cover.
        let seen = list.safeAreaInsets
        let top = seen.top, bottom = list.bounds.height - seen.bottom
        let zone: CGFloat = 44
        if point.y < top + zone { return -min(1, (top + zone - point.y) / zone) }
        if point.y > bottom - zone { return min(1, (point.y - (bottom - zone)) / zone) }
        return 0
    }

    /// The list moves while a drag holds near its top or bottom, faster the nearer the edge,
    /// and the moving end follows what comes under the finger.
    @objc private func scrollTick() {
        guard let list, let point = dragPoint, let anchor = dragAnchor, let selection, !selection.isEmpty else { return }
        let inset = list.adjustedContentInset
        let speed = edgeSpeed(at: point)
        guard speed != 0 else { return }
        // The message ends there: nothing past it to take, so the list stays.
        if let rows = source?.selectionMessageRows(containing: anchor.row) {
            let edgeRow = speed < 0 ? rows.lowerBound : rows.upperBound
            let moving = selection.from.row == anchor.row && selection.from.offset == anchor.offset ? selection.to : selection.from
            let atEdge = speed < 0 ? (moving.row == rows.lowerBound && moving.offset == 0) : (moving.row == rows.upperBound && moving.offset >= length(rows.upperBound))
            if atEdge, source?.selectionVisibleRows.contains(edgeRow) == true { return }
        }
        let step = speed * speed.magnitude * 18
        let minY = -inset.top
        let maxY = max(minY, list.contentSize.height - list.bounds.height + inset.bottom)
        let y = max(minY, min(maxY, list.contentOffset.y + step))
        guard abs(y - list.contentOffset.y) > 0.01 else { return }
        list.contentOffset.y = y
        list.layoutIfNeeded()
        didAutoScroll = true
        let inContent = CGPoint(x: point.x + list.contentOffset.x, y: point.y + list.contentOffset.y)
        guard let under = closestPosition(to: list.convert(inContent, to: self)) as? MarkdownTextPosition else { return }
        let kept = clampToMessage(under, of: anchor.row)
        inputDelegate?.selectionWillChange(self)
        self.selection = MarkdownTextRange(anchor, kept)
        inputDelegate?.selectionDidChange(self)
    }

    public override func copy(_ sender: Any?) {
        guard let selection, let text = text(in: selection) else { return }
        UIPasteboard.general.string = text
    }

    // MARK: Links

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let source, let openURL else { return }
        let point = recognizer.location(in: self)
        for row in source.selectionVisibleRows {
            for text in texts(row) ?? [] where text.frame(in: self).contains(point) {
                let offset = text.offset(closestTo: point, in: self)
                for candidate in [offset, offset - 1] where candidate >= 0 {
                    guard let url = text.link(at: candidate),
                          text.rects(for: NSRange(location: candidate, length: 1), in: self).contains(where: { $0.contains(point) }) else { continue }
                    openURL(url)
                    return
                }
            }
        }
    }
}

/// Words, sentences and paragraphs in a row's own text, the one positions count: a row's text
/// as copied is another length. A paragraph ends at a newline: a table's row, a list's item.
/// The document is the message.
@MainActor
final class MarkdownSelectionTokenizer: UITextInputStringTokenizer {
    private unowned let view: MarkdownSelectionView

    init(view: MarkdownSelectionView) {
        self.view = view
        super.init(textInput: view)
    }

    override func rangeEnclosingPosition(_ position: UITextPosition, with granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextRange? {
        guard let position = position as? MarkdownTextPosition, position.row >= 0, position.row < view.rowsCount else { return nil }
        if granularity == .document { return view.messageRange(containing: position.row) }
        guard granularity != .character, let range = Self.range(in: view.rowString(position.row), at: position.offset, granularity: granularity) else {
            return super.rangeEnclosingPosition(position, with: granularity, inDirection: direction)
        }
        return MarkdownTextRange(MarkdownTextPosition(row: position.row, offset: range.location), MarkdownTextPosition(row: position.row, offset: NSMaxRange(range)))
    }

    override func isPosition(_ position: UITextPosition, withinTextUnit granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
        guard granularity != .character, let position = position as? MarkdownTextPosition, position.row >= 0, position.row < view.rowsCount else {
            return super.isPosition(position, withinTextUnit: granularity, inDirection: direction)
        }
        if granularity == .document { return true }
        return Self.range(in: view.rowString(position.row), at: position.offset, granularity: granularity) != nil
    }

    override func isPosition(_ position: UITextPosition, atBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
        guard granularity != .character, let position = position as? MarkdownTextPosition, position.row >= 0, position.row < view.rowsCount else {
            return super.isPosition(position, atBoundary: granularity, inDirection: direction)
        }
        let string = view.rowString(position.row)
        if position.offset == 0 || position.offset == string.length { return true }
        guard let range = Self.range(in: string, at: position.offset, granularity: granularity) else { return true }
        return position.offset == range.location || position.offset == NSMaxRange(range)
    }

    /// The unit around `offset` in `string`; nil between units (spaces between words).
    static func range(in string: NSString, at offset: Int, granularity: UITextGranularity) -> NSRange? {
        let length = string.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let at = max(0, min(offset, length))
        // The paragraph: between newlines.
        var start = at, end = at
        while start > 0, !isBreak(string.character(at: start - 1)) { start -= 1 }
        while end < length, !isBreak(string.character(at: end)) { end += 1 }
        let paragraph = NSRange(location: start, length: end - start)
        switch granularity {
        case .paragraph, .line: return paragraph
        case .word, .sentence:
            var found: NSRange?
            let options: NSString.EnumerationOptions = granularity == .word ? .byWords : .bySentences
            string.enumerateSubstrings(in: paragraph, options: [options, .substringNotRequired]) { _, range, _, stop in
                if at >= range.location, at <= NSMaxRange(range) {
                    // At a boundary, the unit after it.
                    if at == NSMaxRange(range), found != nil { stop.pointee = true; return }
                    found = range
                    if at < NSMaxRange(range) { stop.pointee = true }
                }
            }
            return found
        default: return nil
        }
    }

    private static func isBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x2029 || character == 0x0D
    }
}
