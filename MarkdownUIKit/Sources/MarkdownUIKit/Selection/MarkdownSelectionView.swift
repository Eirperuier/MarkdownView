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
        addGestureRecognizer(linkTap)
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
        set { selection = newValue as? MarkdownTextRange }
    }

    public var markedTextRange: UITextRange? { nil }
    public var markedTextStyle: [NSAttributedString.Key: Any]?
    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    public func unmarkText() {}
    public weak var inputDelegate: UITextInputDelegate?
    public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
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

    /// Every row, from the first's start to the last's end.
    public override func selectAll(_ sender: Any?) {
        guard rowCount > 0 else { return }
        inputDelegate?.selectionWillChange(self)
        selection = MarkdownTextRange(MarkdownTextPosition(row: 0, offset: 0), MarkdownTextPosition(row: rowCount - 1, offset: length(rowCount - 1)))
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
