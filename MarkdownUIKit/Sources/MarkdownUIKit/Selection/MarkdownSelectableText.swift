//
//  MarkdownSelectableText.swift
//  MarkdownUIKit
//
//  One run of text as it's laid out on screen, for a selection that runs across blocks: what it
//  says, and where each of its characters is, in any view's coordinates. Read from the TextKit 2
//  layout that draws it, drawn text's or a text view's, so nothing is laid out again.
//

import RichTextCore
import UIKit

@MainActor
public struct MarkdownSelectableText {
    private enum Content {
        /// Text as TextKit 2 lays it out, its layout's origin at `origin` in the view.
        case layout(NSTextLayoutManager, origin: CGPoint)
        /// Something selected whole or not at all, a formula or a picture: what it copies as, and
        /// its frame in the view.
        case whole(String, frame: CGRect)
        /// Text drawn by string drawing, a table cell's: laid out only when asked where its
        /// characters are.
        case drawn(MarkdownLazyLayout)
    }

    private let content: Content
    /// The view it's in.
    let view: UIView
    /// What comes between it and the next text of its row, as copied: a newline, or a tab between
    /// a table row's cells. One character, always.
    public internal(set) var separator: Character

    init(manager: NSTextLayoutManager, view: UIView, origin: CGPoint, separator: Character = "\n") {
        content = .layout(manager, origin: origin)
        self.view = view
        self.separator = separator
    }

    /// A formula, a picture: selected whole, copied as `string`.
    init(whole string: String, frame: CGRect, in view: UIView, separator: Character = "\n") {
        content = .whole(string, frame: frame)
        self.view = view
        self.separator = separator
    }

    /// Text drawn at `frame` in `view` by string drawing, `usesLineFragmentOrigin`.
    public init(drawn text: NSAttributedString, frame: CGRect, in view: UIView, separator: Character = "\n") {
        content = .drawn(MarkdownLazyLayout(text: text, width: frame.width))
        self.view = view
        self.separator = separator
        drawnFrame = frame
    }

    /// Where drawn text is drawn.
    private var drawnFrame = CGRect.zero

    /// What it says and copies as, apart from the view it's in: for a row gone off screen,
    /// which has no geometry. `placeholder` stands for the view.
    public func detached(in placeholder: UIView) -> MarkdownSelectableText {
        let copy: MarkdownSelectableText
        switch content {
        case .whole(let string, _): copy = MarkdownSelectableText(whole: string, frame: .zero, in: placeholder)
        case .layout, .drawn: copy = MarkdownSelectableText(drawn: NSAttributedString(attributedString: storageText ?? NSAttributedString()), frame: .zero, in: placeholder)
        }
        return copy.separated(by: separator)
    }

    /// The same, followed by `separator`.
    func separated(by separator: Character) -> MarkdownSelectableText {
        var copy = self
        copy.separator = separator
        return copy
    }

    /// Texts of a row in order, joined as copied.
    public static func joined(_ texts: [MarkdownSelectableText]) -> String {
        var joined = ""
        for (index, text) in texts.enumerated() {
            joined += text.string
            if index < texts.count - 1 { joined.append(text.separator) }
        }
        return joined
    }

    private var manager: NSTextLayoutManager? {
        switch content {
        case .layout(let manager, _): manager
        case .drawn(let lazy): lazy.manager
        case .whole: nil
        }
    }

    /// Where its layout's origin is in the view.
    private var origin: CGPoint {
        switch content {
        case .layout(_, let origin): origin
        case .drawn: drawnFrame.origin
        case .whole(_, let frame): frame.origin
        }
    }

    private var storageText: NSAttributedString? {
        if case .drawn(let lazy) = content { return lazy.text }
        guard let storage = manager?.textContentManager as? NSTextContentStorage else { return nil }
        return storage.attributedString ?? storage.textStorage
    }

    /// All of it, one character per position: an attachment is its storage character.
    public var string: String {
        switch content {
        case .layout, .drawn: storageText?.string ?? ""
        case .whole(let string, _): string
        }
    }

    public var length: Int { (string as NSString).length }

    /// `range` as copied: a list's marker as Markdown writes it, an attachment as it copies (a
    /// formula's source, a chip's label), the joiner that only holds a line together left out.
    public func copied(_ range: NSRange) -> String {
        guard let text = storageText else {
            let whole = string as NSString
            return whole.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: whole.length)))
        }
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        var out = ""
        text.enumerateAttribute(.markdownListMarkerCopy, in: range) { marker, run, _ in
            if let marker = marker as? String {
                // All of a marker or none: part of one copies as nothing.
                var whole = NSRange()
                _ = text.attribute(.markdownListMarkerCopy, at: run.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: text.length))
                if run.location == whole.location { out += marker }
                return
            }
            text.enumerateAttribute(.attachment, in: run) { value, piece, _ in
                if let attachment = value as? RichTextAttachment {
                    out += attachment.replacementText()?.string ?? ""
                } else {
                    out += text.attributedSubstring(from: piece).string
                }
            }
        }
        return out.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private func location(_ offset: Int) -> NSTextLocation? {
        guard let manager else { return nil }
        return manager.location(manager.documentRange.location, offsetBy: max(0, min(offset, length)))
    }

    private func offset(of location: NSTextLocation) -> Int {
        guard let manager else { return 0 }
        return manager.offset(from: manager.documentRange.location, to: location)
    }

    private func convert(_ rect: CGRect, to space: UIView) -> CGRect {
        switch content {
        case .layout, .drawn: view.convert(rect.offsetBy(dx: origin.x, dy: origin.y), to: space)
        case .whole: view.convert(rect, to: space)
        }
    }

    /// The link under an offset, if any.
    public func link(at offset: Int) -> URL? {
        guard let text = storageText, offset >= 0, offset < text.length else { return nil }
        switch text.attribute(.link, at: offset, effectiveRange: nil) {
        case let url as URL: return url
        case let string as String: return URL(string: string)
        default: return nil
        }
    }

    /// The highlight of `range`, a rect a line, in `space`.
    public func rects(for range: NSRange, in space: UIView) -> [CGRect] {
        if case .whole(_, let frame) = content { return range.length > 0 ? [convert(frame, to: space)] : [] }
        guard range.length > 0, let manager, let start = location(range.location), let end = location(NSMaxRange(range)),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        var rects: [CGRect] = []
        manager.enumerateTextSegments(in: textRange, type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
            if rect.width > 0 || rect.height > 0 { rects.append(convert(rect, to: space)) }
            return true
        }
        return rects
    }

    /// A caret before the character at `offset`, in `space`.
    public func caretRect(at offset: Int, in space: UIView) -> CGRect {
        if case .whole(_, let frame) = content {
            return convert(CGRect(x: offset <= 0 ? frame.minX : frame.maxX - 2, y: frame.minY, width: 2, height: frame.height), to: space)
        }
        guard let manager, let location = location(offset) else { return .null }
        var caret = CGRect.null
        manager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in
            caret = CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
            return false
        }
        return caret.isNull ? .null : convert(caret, to: space)
    }

    /// The frame of all its lines, in `space`.
    public func frame(in space: UIView) -> CGRect {
        if case .whole(_, let frame) = content { return convert(frame, to: space) }
        if case .drawn = content { return view.convert(drawnFrame, to: space) }
        guard let manager else { return .null }
        var frame = CGRect.null
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            frame = frame.union(fragment.layoutFragmentFrame)
            return true
        }
        return frame.isNull ? .null : convert(frame, to: space)
    }

    /// The offset nearest a point in `space`: the line at its height, or the nearest line, and
    /// the place in that line nearest its x.
    public func offset(closestTo point: CGPoint, in space: UIView) -> Int {
        let local = space.convert(point, to: view)
        if case .whole(_, let frame) = content { return local.x < frame.midX ? 0 : length }
        guard let manager else { return 0 }
        let inLayout = CGPoint(x: local.x - origin.x, y: local.y - origin.y)
        var best: (distance: CGFloat, offset: Int)?
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            let fragmentFrame = fragment.layoutFragmentFrame
            let fragmentStart = offset(of: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds.offsetBy(dx: fragmentFrame.minX, dy: fragmentFrame.minY)
                let distance = inLayout.y < bounds.minY ? bounds.minY - inLayout.y : max(0, inLayout.y - bounds.maxY)
                if let best, best.distance <= distance { continue }
                let x = inLayout.x - fragmentFrame.minX
                var index = line.characterIndex(for: CGPoint(x: x, y: line.typographicBounds.midY))
                // Nowhere on the line (NSNotFound): its end, or its start left of it.
                if index == NSNotFound || index < 0 {
                    index = x < line.typographicBounds.midX ? line.characterRange.location : NSMaxRange(line.characterRange)
                }
                // A line's index is in its paragraph's string, which the fragment's range starts.
                var offset = fragmentStart + index
                let lineEnd = fragmentStart + NSMaxRange(line.characterRange)
                // Past a line's end is before its newline, not after it.
                if offset >= lineEnd, lineEnd > fragmentStart + line.characterRange.location {
                    let last = (string as NSString).character(at: max(0, min(lineEnd - 1, length - 1)))
                    offset = (last == 0x0A || last == 0x2029) ? lineEnd - 1 : lineEnd
                }
                best = (distance, min(offset, length))
            }
            return true
        }
        return best?.offset ?? 0
    }
}

/// Text laid out by TextKit 2 the first time it's needed, as string drawing lays it out at a width.
@MainActor
final class MarkdownLazyLayout {
    let text: NSAttributedString
    private let width: CGFloat
    private var storage: NSTextContentStorage?

    init(text: NSAttributedString, width: CGFloat) {
        self.text = text
        self.width = width
    }

    private(set) lazy var manager: NSTextLayoutManager = {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: 0))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        storage.attributedString = text
        manager.ensureLayout(for: manager.documentRange)
        self.storage = storage
        return manager
    }()
}
