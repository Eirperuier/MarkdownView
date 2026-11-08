//
//  MarkdownTextBuilder.swift
//  MarkdownUIKit
//
//  Markdown to one attributed string, its map to plain units, and the room a whole document
//  gives it at its edges (paragraph spacing does nothing at a text's start and end).
//

import Markdown
import MarkdownCore
import RichTextCore
import UIKit

/// What text comes to.
public struct MarkdownText {
    public let attributed: NSAttributedString
    /// Plain units in all: what a reveal's frontier counts up to.
    public let revealTotal: Int
    /// For each Character in `attributed`, where it starts in plain. Never decreasing.
    public let storageToPlain: [Int]
    /// The room a document gives this block above and below.
    public let topEdgeInset: CGFloat
    public let bottomEdgeInset: CGFloat
}

/// Whether a text built off the main thread met something only that thread can make.
final class MarkdownBuildGate: @unchecked Sendable {
    var needsMainThread = false
}

/// A cache text being built on any thread can share.
final class MarkdownLockedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: Value, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

/// What the main thread made, on its way out of `MainActor.assumeIsolated`.
struct MarkdownMainThreadMade<Value>: @unchecked Sendable {
    let value: Value
}

public enum MarkdownTextBuilder {
    /// The same off the main thread: nil if the text has what only that thread can make.
    static func buildOffMain(markdown: String, style: MarkdownStyle, listDepthOffset: Int, inlineMath: [String: String]?, displayMath: [UUID: String]?) -> MarkdownText? {
        let gate = MarkdownBuildGate()
        let text = build(markdown: markdown, style: style, listDepthOffset: listDepthOffset, inlineMath: inlineMath, displayMath: displayMath, gate: gate)
        return gate.needsMainThread ? nil : text
    }

    /// - Parameters:
    ///   - listDepthOffset: added to list depth, for an item re-parsed alone.
    ///   - plainOffsetBase: where this text starts in plain, for a fragment of a block.
    ///   - inlineMath: formulas already taken out by a splitter, by placeholder id.
    ///   - displayMath: the same for formulas on their own, by the id in their directive.
    public static func build(
        markdown: String,
        style: MarkdownStyle,
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        inlineMath: [String: String]? = nil,
        displayMath: [UUID: String]? = nil
    ) -> MarkdownText {
        build(markdown: markdown, style: style, listDepthOffset: listDepthOffset, plainOffsetBase: plainOffsetBase, inlineMath: inlineMath, displayMath: displayMath, gate: MarkdownBuildGate())
    }

    private static func build(
        markdown: String,
        style: MarkdownStyle,
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        inlineMath: [String: String]? = nil,
        displayMath: [UUID: String]? = nil,
        gate: MarkdownBuildGate
    ) -> MarkdownText {
        // Maths out: `$…$` to a placeholder and its LaTeX to storage.
        var inlineStorage = inlineMath ?? [:]
        var displayStorage = displayMath ?? [:]
        let processed = MarkdownMathPreprocessor.preprocess(
            markdown,
            appendDisplayMath: { math in
                let id = MarkdownMathPreprocessor.displayID(for: math)
                displayStorage[id] = String(math)
                return id
            },
            appendInlineMath: { math in
                let id = MarkdownMathPreprocessor.inlineID(for: math)
                inlineStorage[id] = String(math)
                return id
            }
        )
        // Inline notes `^[…]` after maths: placeholders, read as number links. Only with footnotes
        // and where there are any, so the plain count stays the AST's.
        var text = processed
        var tokens: [Int: MarkdownFootnoteSyntax.InlineToken] = [:]
        if let footnotes = style.footnotes, !footnotes.inlineNotes.isEmpty {
            let prepared = MarkdownFootnoteSyntax.preprocessInlineNotes(processed)
            text = prepared.text
            tokens = prepared.tokens
        }
        let content = MarkdownContent(text)
        let document = content.parse(options: content.parseOptions(allowingBlockDirectives: true))
        return build(
            document: document,
            style: style,
            listDepthOffset: listDepthOffset,
            plainOffsetBase: plainOffsetBase,
            inlineMath: inlineStorage,
            displayMath: displayStorage,
            inlineFootnoteTokens: tokens,
            gate: gate
        )
    }

    /// A tree, built by the caller or parsed. Its text is read as written when
    /// `style.interpretsTextSyntax` is off.
    public static func build(
        document: Markdown.Document,
        style: MarkdownStyle,
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        inlineMath: [String: String]? = nil,
        displayMath: [UUID: String]? = nil
    ) -> MarkdownText {
        build(
            document: document,
            style: style,
            listDepthOffset: listDepthOffset,
            plainOffsetBase: plainOffsetBase,
            inlineMath: inlineMath ?? [:],
            displayMath: displayMath ?? [:],
            inlineFootnoteTokens: [:]
        )
    }

    static func build(
        document: Markdown.Document,
        style: MarkdownStyle,
        listDepthOffset: Int,
        plainOffsetBase: Int,
        inlineMath: [String: String],
        displayMath: [UUID: String],
        inlineFootnoteTokens: [Int: MarkdownFootnoteSyntax.InlineToken],
        gate: MarkdownBuildGate = MarkdownBuildGate()
    ) -> MarkdownText {
        let visitor = MarkdownTextVisitor(
            style: style,
            bodyFont: style.defaultFont ?? style.typography.body.font(at: style.contentSizeCategory),
            inlineMathStorage: inlineMath,
            displayMathStorage: displayMath,
            inlineFootnoteTokens: inlineFootnoteTokens,
            listDepthOffset: listDepthOffset,
            plainOffsetBase: plainOffsetBase,
            gate: gate
        )
        let made = visitor.makeText(document)
        // Decorations before anchors: a decoration only changes attributes and uses the map
        // as it is; an anchor moves storage.
        applyRangeDecorations(style.rangeDecorations, to: made.text, storageToPlain: made.storageToPlain)
        if !style.inlineAnchors.isEmpty, !Thread.isMainThread { gate.needsMainThread = true }
        let map = gate.needsMainThread ? made.storageToPlain : insertAnchors(style.inlineAnchors, into: made.text, storageToPlain: made.storageToPlain, style: style)

        let children = Array(document.children)
        // An extended heading's subtitle is drawn a level down: its bottom room is that level's.
        let isExtendedPair = children.count == 2
            && (children[0] as? Heading).map { title in (children[1] as? Heading)?.level == title.level } == true
        func edgeInset(_ block: (any Markup)?, top: Bool) -> CGFloat {
            switch block {
            case let heading as Heading:
                let level = (!top && isExtendedPair) ? min(heading.level + 1, 6) : heading.level
                return top ? style.headingPaddings.top(level) : style.headingPaddings.bottom(level)
            case is Paragraph, is UnorderedList, is OrderedList:
                return 5
            default:
                return 0
            }
        }
        return MarkdownText(
            attributed: made.text,
            revealTotal: made.revealTotal,
            storageToPlain: map,
            topEdgeInset: edgeInset(children.first, top: true),
            bottomEdgeInset: edgeInset(children.last, top: false)
        )
    }

    /// A range's coloured underline, by plain range. Only underlineColor, no underlineStyle: the
    /// system's underline hugs the text and can't move, so the text view draws its own bar for
    /// a colour with no style, apart from the text. In list order: the last wins. A tap's link
    /// goes on with an empty link style, so it changes nothing to see.
    private static func applyRangeDecorations(_ decorations: [MarkdownRangeDecoration], to text: NSMutableAttributedString, storageToPlain map: [Int]) {
        guard !map.isEmpty, !decorations.isEmpty else { return }
        func lowerBound(_ plain: Int) -> Int {
            var lo = 0, hi = map.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if map[mid] < plain { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        let offsets = text.string.characterUTF16Offsets
        for decoration in decorations {
            let start = lowerBound(decoration.plainStart)
            let end = lowerBound(decoration.plainStart + decoration.plainLength)
            guard end > start, end < offsets.count else { continue }
            let range = NSRange(location: offsets[start], length: offsets[end] - offsets[start])
            // A clear underline is only there to make the run tap: nothing to draw.
            if decoration.underlineColor.cgColor.alpha > 0 {
                text.addAttribute(.underlineColor, value: decoration.underlineColor, range: range)
            }
            guard let url = decoration.tapURL else { continue }
            if decoration.preservesInnerLinks {
                // Only runs with no link: all of it taps, the real links keep their own.
                text.enumerateAttribute(.link, in: range) { value, run, _ in
                    if value == nil { text.addAttribute(.link, value: url, range: run) }
                }
            } else {
                text.addAttribute(.link, value: url, range: range)
            }
        }
    }

    /// Bubbles by plain offset: 1 storage character, no plain units, so the total doesn't
    /// change. From the last back, so storage indexes before it stay good.
    private static func insertAnchors(_ anchors: [MarkdownInlineAnchor], into text: NSMutableAttributedString, storageToPlain map: [Int], style: MarkdownStyle) -> [Int] {
        guard !anchors.isEmpty else { return map }
        var map = map
        let bubbleSize = style.typography.body.font(at: style.contentSizeCategory).pointSize
        for (sequence, anchor) in anchors.sorted(by: { $0.plainOffset > $1.plainOffset }).enumerated() {
            // Where: the first character starting at or past the offset.
            var lo = 0, hi = map.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if map[mid] < anchor.plainOffset { lo = mid + 1 } else { hi = mid }
            }
            let offsets = text.string.characterUTF16Offsets
            let location = lo < offsets.count ? offsets[lo] : text.length
            // A way in, not content: it doesn't copy.
            nonisolated(unsafe) let style = style
            let attachment = MainActor.assumeIsolated {
                MarkdownMainThreadMade(value: MarkdownBubbleAttachment(id: AnyHashable(1_000_000 + sequence), size: bubbleSize, url: anchor.url, style: style))
            }.value
            text.insert(NSAttributedString(string: "\u{FFFC}", attributes: [
                .attachment: attachment,
                .inlineHostingAttachment: attachment,
                .font: style.resolvedDefaultFont,
                .foregroundColor: style.resolvedTextColor,
                .paragraphStyle: location > 0
                    ? (text.attribute(.paragraphStyle, at: min(location, text.length - 1), effectiveRange: nil) ?? NSParagraphStyle.default)
                    : (text.length > 0 ? text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) ?? NSParagraphStyle.default : NSParagraphStyle.default),
            ]), at: location)
            map.insert(anchor.plainOffset, at: min(lo, map.count))
        }
        return map
    }
}
