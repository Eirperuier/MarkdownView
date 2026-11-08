//
//  MarkdownSelectableText.swift
//  MarkdownUIKit
//
//  One run of text as it's laid out on screen, for a selection that runs across blocks: what it
//  says, and where each of its characters is, in any view's coordinates. Read from the TextKit 2
//  layout that draws it, drawn text's or a text view's, so nothing is laid out again.
//

import UIKit

@MainActor
public struct MarkdownSelectableText {
    let manager: NSTextLayoutManager
    /// The view the text is in, and where its layout's origin is in that view.
    let view: UIView
    let origin: CGPoint

    /// All of it, as copied: an attachment's character comes out as nothing.
    public var string: String {
        guard let storage = manager.textContentManager as? NSTextContentStorage,
              let text = storage.attributedString ?? storage.textStorage else { return "" }
        return text.string
    }

    public var length: Int { (string as NSString).length }

    private func location(_ offset: Int) -> NSTextLocation? {
        manager.location(manager.documentRange.location, offsetBy: max(0, min(offset, length)))
    }

    private func offset(of location: NSTextLocation) -> Int {
        manager.offset(from: manager.documentRange.location, to: location)
    }

    private func convert(_ rect: CGRect, to space: UIView) -> CGRect {
        view.convert(rect.offsetBy(dx: origin.x, dy: origin.y), to: space)
    }

    /// The link under an offset, if any.
    public func link(at offset: Int) -> URL? {
        guard let storage = manager.textContentManager as? NSTextContentStorage,
              let text = storage.attributedString ?? storage.textStorage,
              offset >= 0, offset < text.length else { return nil }
        switch text.attribute(.link, at: offset, effectiveRange: nil) {
        case let url as URL: return url
        case let string as String: return URL(string: string)
        default: return nil
        }
    }

    /// The highlight of `range`, a rect a line, in `space`.
    public func rects(for range: NSRange, in space: UIView) -> [CGRect] {
        guard range.length > 0, let start = location(range.location), let end = location(NSMaxRange(range)),
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
        guard let location = location(offset) else { return .null }
        var caret = CGRect.null
        manager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in
            caret = CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
            return false
        }
        return caret.isNull ? .null : convert(caret, to: space)
    }

    /// The frame of all its lines, in `space`.
    public func frame(in space: UIView) -> CGRect {
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
                let index = line.characterIndex(for: CGPoint(x: x, y: line.typographicBounds.midY))
                // A line's index is in its paragraph's string, which the fragment's range starts.
                var offset = fragmentStart + max(0, index)
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
