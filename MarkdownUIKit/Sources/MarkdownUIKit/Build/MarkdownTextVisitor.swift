//
//  MarkdownTextVisitor.swift
//  MarkdownUIKit
//
//  The core of text rendering: markup to one NSAttributedString, text and inline attachments
//  mixed, so all of it selects continuously. Ported from MarkdownView's SelectableMarkupVisitor;
//  the reasons stay beside what they explain.
//
//  Three coordinates:
//  - storage: what's in the text storage, by Character (text 1 each, an attachment 1, a newline 1).
//  - plain: the units of `markdownRevealPlainText`, what a reveal's frontier counts. The two
//    differ at placeholders (maths is 1 character and ~11 units) and markers (characters, no units).
//  - `storageToPlain[i]`: where character i starts in plain, never decreasing.
//

import CoreText
import Markdown
import MarkdownCore
import RichTextCore
import UIKit

extension NSAttributedString.Key {
    /// What inline markup asks of a run's font. Fonts are set over one another on the way up
    /// (a heading's over a word's bold), so the traits go on last. It stays in storage: TextKit
    /// reads it too (measured: emphasis in a bold heading is drawn in the regular italic).
    fileprivate static let markdownIntent = NSAttributedString.Key.inlinePresentationIntent
    /// A highlight's ground on its text, for the last step to make the text read on it.
    fileprivate static let markdownHighlightGround = NSAttributedString.Key("MarkdownHighlightGround")
}

private typealias InlineIntent = InlinePresentationIntent

/// Runs on any thread. What only the main thread can make (an attachment) goes through
/// `attachmentString`: off that thread it gives the text up, and the gate says so.
struct MarkdownTextVisitor: MarkupVisitor {
    typealias Result = NSMutableAttributedString

    let style: MarkdownStyle
    /// Body base font.
    let bodyFont: UIFont
    /// Inline maths' LaTeX by placeholder id (from preprocessing).
    let inlineMathStorage: [String: String]
    /// Formulas on their own, by the id in their directive.
    let displayMathStorage: [UUID: String]
    /// `^[…]` placeholders by index (they match `style.footnotes.inlineNotes` in order).
    let inlineFootnoteTokens: [Int: MarkdownFootnoteSyntax.InlineToken]
    /// Added to list depth: a list item re-parsed alone has depth 0, so • / ◦ need it back.
    let listDepthOffset: Int
    let gate: MarkdownBuildGate
    /// An attachment's identity across renders.
    private var attachmentCounter = 0
    /// Text storage character cursor.
    private var revealCursor = 0
    /// Plain unit cursor, what `markdownRevealPlainText` consumes. A reveal's count is in this
    /// system, not storage's: comparing a plain frontier to a storage offset goes wrong at
    /// placeholders and markers (a closing formula would re-play characters already seen).
    private var plainCursor: Int
    private var storageToPlain: [Int] = []

    init(
        style: MarkdownStyle,
        bodyFont: UIFont,
        inlineMathStorage: [String: String],
        displayMathStorage: [UUID: String],
        inlineFootnoteTokens: [Int: MarkdownFootnoteSyntax.InlineToken] = [:],
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        gate: MarkdownBuildGate = MarkdownBuildGate()
    ) {
        self.gate = gate
        self.style = style
        self.bodyFont = bodyFont
        self.inlineMathStorage = inlineMathStorage
        self.displayMathStorage = displayMathStorage
        self.inlineFootnoteTokens = inlineFootnoteTokens
        self.listDepthOffset = listDepthOffset
        // A fragment's base (a table cell's): anchors and the map become absolute.
        self.plainCursor = plainOffsetBase
    }

    /// Appends a stretch of the map: `storageCount` characters consuming `plainSpan` units.
    /// 1:1 (text, newlines) maps character by character. Anything else (a placeholder is 1 to
    /// 11, a marker or tab has no units) anchors all of it at its start: a frontier past the
    /// start reveals it whole.
    private mutating func appendMap(storageCount: Int, plainSpan: Int) {
        if storageCount == plainSpan {
            for k in 0..<storageCount { storageToPlain.append(plainCursor + k) }
        } else {
            for _ in 0..<storageCount { storageToPlain.append(plainCursor) }
        }
        plainCursor += plainSpan
    }

    func makeText(_ markup: any Markup) -> (text: NSMutableAttributedString, revealTotal: Int, storageToPlain: [Int]) {
        var visitor = self
        let text = visitor.visit(markup)
        // revealTotal: plain units in all, in the frontier's system; the map converts a
        // frontier to a storage offset.
        return (visitor.finished(text), visitor.plainCursor, visitor.storageToPlain)
    }

    mutating func defaultVisit(_ markup: any Markup) -> NSMutableAttributedString {
        descendInto(markup)
    }

    /// Blocks are separated by a line break; the room between them is paragraph spacing.
    mutating func visitDocument(_ document: Markdown.Document) -> NSMutableAttributedString {
        let children = Array(document.children)
        // Extended heading (adjacent same-level headings as one block): the subtitle is a level
        // down, secondary, with no gap between.
        if children.count == 2,
           let title = children[0] as? Heading,
           let subtitle = children[1] as? Heading,
           subtitle.level == title.level {
            // No gap at the junction: spacing before and after go to 0, and both headings' line
            // spacing too. TextKit 2 adds the *next* paragraph's line spacing at a junction
            // (measured: the subtitle's line starts at y = lineSpacing).
            let combined = headingContainer(
                descendInto(title),
                level: title.level,
                spacingAfterOverride: 0,
                lineSpacingOverride: 0
            )
            appendMap(storageCount: 1, plainSpan: 1)  // The descriptor's plain "\n".
            combined.append(NSAttributedString(string: "\n"))
            let subLevel = min(title.level + 1, 6)
            let second = headingContainer(
                descendInto(subtitle),
                level: subLevel,
                spacingBeforeOverride: 0,
                lineSpacingOverride: 0
            )
            second.merge([.foregroundColor: UIColor.floo(.markdownSubtitle)])
            combined.append(second)
            return combined
        }

        let combined = NSMutableAttributedString()
        for child in children {
            // The separator's map comes before the child's, the order of the characters.
            // A newline between blocks counts 1 plain unit, as an extended heading's does.
            let isFirst = combined.length == 0
            if !isFirst { appendMap(storageCount: 1, plainSpan: 1) }
            let content = visit(child)
            if content.length == 0 {
                // An empty child: take the separator back, it moves no cursor.
                if !isFirst { storageToPlain.removeLast(); plainCursor -= 1 }
                continue
            }
            if !isFirst { combined.append(NSAttributedString(string: "\n")) }
            combined.append(content)
        }
        return combined
    }

    // MARK: - Inline

    mutating func visitText(_ text: Markdown.Text) -> NSMutableAttributedString {
        let plain = text.plainText
        // Inline maths' placeholders become attachments; the text around stays selectable.
        if !inlineMathStorage.isEmpty, plain.contains(MarkdownInlineMathPlaceholder.prefix) {
            return inlineMathContent(plain: plain)
        }
        // Footnotes (references, definition markers, inline placeholders) become superscript
        // number links; with no footnotes this costs nothing.
        return footnoteAwareContent(plain, isNodeStart: true)
    }

    /// A piece of plain text: autolinks, base style, and its map. Pieces between footnotes and
    /// maths all come here.
    private mutating func plainTextPiece(_ plain: String) -> NSMutableAttributedString {
        guard !plain.isEmpty else { return NSMutableAttributedString() }
        // Bare URLs and addresses (www.x.com and such that cmark misses) get the link, its
        // underline and colour; characters are 1:1, so the map doesn't change.
        if style.autolinks {
            let links = MarkdownAutolinkDetector.links(in: plain)
            if !links.isEmpty { return autolinkedPiece(plain, links: links) }
        }
        let attributed = markRevealOffsets(baseAttributed(plain), start: revealCursor)
        let n = attributed.string.count
        appendMap(storageCount: n, plainSpan: n)  // Highlight delimiters were stripped on both sides.
        revealCursor += n
        return attributed
    }

    private mutating func autolinkedPiece(_ plain: String, links: [(url: URL, characters: Range<Int>)]) -> NSMutableAttributedString {
        let characters = Array(plain)
        let content = NSMutableAttributedString()
        var cursor = 0
        func piece(_ range: Range<Int>, _ attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
            NSAttributedString(string: String(characters[range]), attributes: attributes)
        }
        var previous: URL?
        for link in links {
            if link.characters.lowerBound > cursor {
                let range = cursor..<link.characters.lowerBound
                appendMap(storageCount: range.count, plainSpan: range.count)
                revealCursor += range.count
                content.append(piece(range, [.font: bodyFont]))
                previous = nil
            }
            // Each web address after its site's icon, when links show them.
            if link.url != previous, let icon = siteIconPiece(for: link.url) { content.append(icon) }
            previous = link.url
            appendMap(storageCount: link.characters.count, plainSpan: link.characters.count)
            revealCursor += link.characters.count
            content.append(piece(link.characters, [
                .font: bodyFont,
                .link: link.url,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: linkColor,
            ]))
            cursor = link.characters.upperBound
        }
        if cursor < characters.count {
            let range = cursor..<characters.count
            appendMap(storageCount: range.count, plainSpan: range.count)
            revealCursor += range.count
            content.append(piece(range, [.font: bodyFont]))
        }
        return content
    }

    // MARK: - Footnotes (references [^id], definition markers [^id]:, inline placeholders)

    private enum FootnoteToken {
        case reference(id: String)
        case definition(id: String)
        case inlineNote(index: Int)
    }

    /// Splits text at footnote tokens: a token becomes a number link, a gap plain text.
    /// `isNodeStart`: a definition marker only counts at a Text node's start (a paragraph's or
    /// after a soft break: a line's start).
    private mutating func footnoteAwareContent(_ plain: String, isNodeStart: Bool) -> NSMutableAttributedString {
        guard let footnotes = style.footnotes, !footnotes.isEmpty else {
            return plainTextPiece(plain)
        }
        let mayHaveStandard = !footnotes.references.isEmpty && plain.contains("[^")
        let mayHaveInline = !inlineFootnoteTokens.isEmpty
            && plain.contains(MarkdownFootnoteSyntax.inlinePlaceholderPrefix)
        guard mayHaveStandard || mayHaveInline else { return plainTextPiece(plain) }

        let content = NSMutableAttributedString()
        var cursor = plain.startIndex
        while cursor < plain.endIndex {
            guard let (token, range) = nextFootnoteToken(
                in: plain,
                from: cursor,
                allowDefinition: isNodeStart && cursor == plain.startIndex,
                footnotes: footnotes
            ) else { break }
            if range.lowerBound > cursor {
                content.append(plainTextPiece(String(plain[cursor..<range.lowerBound])))
            }
            content.append(footnotePiece(token, sourceText: String(plain[range]), footnotes: footnotes))
            cursor = range.upperBound
        }
        if cursor < plain.endIndex {
            content.append(plainTextPiece(String(plain[cursor...])))
        }
        return content
    }

    /// The nearest token from `cursor`. A `[^x]` with no definition isn't one: it stays literal.
    private func nextFootnoteToken(
        in plain: String,
        from cursor: String.Index,
        allowDefinition: Bool,
        footnotes: MarkdownFootnotes
    ) -> (FootnoteToken, Range<String.Index>)? {
        var search = cursor
        var standard: (FootnoteToken, Range<String.Index>)?
        while search < plain.endIndex, standard == nil,
              let open = plain.range(of: "[^", range: search..<plain.endIndex) {
            // The id: what's after `[^` up to `]`, not empty, with no white space or brackets.
            var idEnd = open.upperBound
            while idEnd < plain.endIndex {
                let c = plain[idEnd]
                if c == "]" { break }
                if c.isWhitespace || c == "[" { idEnd = plain.endIndex; break }
                idEnd = plain.index(after: idEnd)
            }
            guard idEnd < plain.endIndex, plain[idEnd] == "]", idEnd > open.upperBound else {
                search = open.upperBound
                continue
            }
            let id = String(plain[open.upperBound..<idEnd])
            let afterBracket = plain.index(after: idEnd)
            guard footnotes.references[id] != nil else {
                search = afterBracket
                continue
            }
            if afterBracket < plain.endIndex, plain[afterBracket] == ":" {
                // A definition marker only at a node's start; elsewhere `[^id]:` stays literal.
                if allowDefinition, open.lowerBound == plain.startIndex {
                    standard = (.definition(id: id), open.lowerBound..<plain.index(after: afterBracket))
                } else {
                    search = plain.index(after: afterBracket)
                    continue
                }
            } else {
                standard = (.reference(id: id), open.lowerBound..<afterBracket)
            }
        }

        var inline: (FootnoteToken, Range<String.Index>)?
        if !inlineFootnoteTokens.isEmpty,
           let prefixRange = plain.range(of: MarkdownFootnoteSyntax.inlinePlaceholderPrefix, range: cursor..<plain.endIndex),
           let suffixRange = plain.range(of: MarkdownFootnoteSyntax.inlinePlaceholderSuffix, range: prefixRange.upperBound..<plain.endIndex),
           let index = Int(plain[prefixRange.upperBound..<suffixRange.lowerBound]) {
            inline = (.inlineNote(index: index), prefixRange.lowerBound..<suffixRange.upperBound)
        }

        switch (standard, inline) {
        case (nil, nil): return nil
        case (let s?, nil): return s
        case (nil, let i?): return i
        case (let s?, let i?): return s.1.lowerBound <= i.1.lowerBound ? s : i
        }
    }

    /// A token as a number link. Storage: the shown characters; plain: the source's units,
    /// anchored at the start as a placeholder or marker is, so the block's plain system, the
    /// frontier and mark anchors are the same as if the source were drawn literally.
    private mutating func footnotePiece(
        _ token: FootnoteToken,
        sourceText: String,
        footnotes: MarkdownFootnotes
    ) -> NSMutableAttributedString {
        let display: NSMutableAttributedString
        let plainSpan: Int
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: linkColor, .font: bodyFont]
        switch token {
        case .reference(let id):
            guard let reference = footnotes.references[id] else { return plainTextPiece(sourceText) }
            if let url = reference.referenceURL { attributes[.link] = url }
            display = NSMutableAttributedString(string: MarkdownFootnoteSyntax.superscriptDigits(reference.number), attributes: attributes)
            plainSpan = sourceText.count
        case .definition(let id):
            guard let reference = footnotes.references[id] else { return plainTextPiece(sourceText) }
            attributes[.font] = UIFont.systemFont(ofSize: bodyFont.pointSize, weight: .medium)
            if let url = reference.definitionURL { attributes[.link] = url }
            display = NSMutableAttributedString(string: "\(reference.number).", attributes: attributes)
            plainSpan = sourceText.count
        case .inlineNote(let index):
            let note = index < footnotes.inlineNotes.count ? footnotes.inlineNotes[index] : nil
            if let url = note?.url { attributes[.link] = url }
            display = NSMutableAttributedString(string: MarkdownFootnoteSyntax.superscriptDigits(note?.number ?? 0), attributes: attributes)
            // The source `^[…]`'s plain count (worked out in preprocessing): a driver counts
            // on the AST as it was before.
            plainSpan = inlineFootnoteTokens[index]?.plainSpan ?? sourceText.count
        }
        let n = display.string.count
        appendMap(storageCount: n, plainSpan: plainSpan)
        revealCursor += n
        return display
    }

    /// `font` at the typography's bold weight (a heavier one is kept), its size, italics,
    /// monospacing and design (serif, rounded) kept. Only the system's faces, the ones the
    /// typography makes; another face keeps its own bold (the bold trait).
    private func strengthened(_ font: UIFont) -> UIFont {
        let weight = style.typography.strongWeight
        guard font.familyName.hasPrefix(".") || font.fontName.hasPrefix(".") else { return font }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let current = (traits?[.weight] as? CGFloat).map { UIFont.Weight(rawValue: $0) } ?? .regular
        guard current < weight else { return font }
        let symbolic = font.fontDescriptor.symbolicTraits
        var result = symbolic.contains(.traitMonoSpace)
            ? UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: weight)
            : UIFont.systemFont(ofSize: font.pointSize, weight: weight)
        if let design = Self.systemDesign(of: font), let designed = result.fontDescriptor.withDesign(design) {
            result = UIFont(descriptor: designed, size: font.pointSize)
        }
        if symbolic.contains(.traitItalic),
           let italic = result.fontDescriptor.withSymbolicTraits(result.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            result = UIFont(descriptor: italic, size: font.pointSize)
        }
        return result
    }

    /// Which of the system font's other designs `font` is in (nil: the default one), by its
    /// family: a font's descriptor doesn't say.
    private static func systemDesign(of font: UIFont) -> UIFontDescriptor.SystemDesign? {
        let base = UIFont.systemFont(ofSize: font.pointSize)
        return [UIFontDescriptor.SystemDesign.serif, .rounded, .monospaced].first { design in
            base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: font.pointSize).familyName } == font.familyName
        }
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSMutableAttributedString {
        appendMap(storageCount: 1, plainSpan: 1)  // markdownRevealPlainText counts a soft break as "\n".
        revealCursor += 1
        return NSMutableAttributedString(string: " ")
    }

    /// A hard break inside a paragraph is a line separator (U+2028), not a newline: a newline
    /// would start a new paragraph and add the paragraph spacing, where the break only ends a line.
    mutating func visitLineBreak(_ lineBreak: Markdown.LineBreak) -> NSMutableAttributedString {
        appendMap(storageCount: 1, plainSpan: 1)
        revealCursor += 1
        return NSMutableAttributedString(string: "\u{2028}")
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSMutableAttributedString {
        let attributed = baseAttributed(inlineCode.code)
        if let codeStyle = style.typography.inlineCode {
            attributed.merge([.font: codeStyle.font(at: style.contentSizeCategory, monospaced: true)])
        }
        attributed.merge([.foregroundColor: style.resolvedInlineCodeColor, .backgroundColor: style.resolvedInlineCodeFill])
        let content = markRevealOffsets(attributed, start: revealCursor)
        let n = attributed.string.count
        appendMap(storageCount: n, plainSpan: inlineCode.markdownRevealPlainText.count)
        revealCursor += n
        return content
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSMutableAttributedString {
        // As MarkdownView's visitor: <br> a newline, the rest its source. The replacement and
        // markdownRevealPlainText come from one place, so the plain count agrees.
        let display = MarkdownInlineHTML.replacementText(for: inlineHTML.rawHTML) ?? inlineHTML.rawHTML
        let content = markRevealOffsets(baseAttributed(display), start: revealCursor)
        appendMap(storageCount: display.count, plainSpan: inlineHTML.markdownRevealPlainText.count)
        revealCursor += display.count
        return content
    }

    /// `^[…](color: red)` and such (MarkdownInlineStyle): the children as usual, then the
    /// colours over them; a pen goes on as the pen attribute, which the overlay draws. The node
    /// itself has no characters: its children keep the map.
    mutating func visitInlineAttributes(_ attributes: InlineAttributes) -> NSMutableAttributedString {
        if attributes.attributes == MarkdownTree.mathAttribute {
            return treeMathContent(attributes)
        }
        let content = descendInto(attributes)
        guard let inlineStyle = MarkdownInlineStyle(attributes: attributes.attributes) else { return content }
        var merged: [NSAttributedString.Key: Any] = [:]
        if let color = inlineStyle.color, let resolved = MarkdownInk.text(color) {
            merged[.foregroundColor] = resolved
        }
        if let highlight = inlineStyle.highlight {
            if let token = highlight {
                if let fill = MarkdownInk.highlightFill(token) {
                    merged[.backgroundColor] = fill
                    merged[.markdownHighlightGround] = fill
                }
            } else {
                merged[.backgroundColor] = style.resolvedHighlightFill
                merged[.markdownHighlightGround] = style.resolvedHighlightFill
                if inlineStyle.color == nil, let text = style.highlightText { merged[.foregroundColor] = text }
            }
        }
        if let pen = inlineStyle.pen {
            let seed = MarkdownPenMarkSyntax.contentSeed(attributes.plainText)
            merged[.richTextPenMark] = MarkdownPenMarkSyntax.encodeAttributeValue(kind: pen, color: inlineStyle.ink, seed: seed)
            if pen == .marker { merged[.markdownHighlightGround] = MarkdownInk.marker(inlineStyle.ink) }
        }
        content.merge(merged)
        return content
    }

    mutating func visitEmphasis(_ emphasis: Markdown.Emphasis) -> NSMutableAttributedString {
        applyingCJKObliqueness(mergeIntent(.emphasized, children: Array(emphasis.children)))
    }

    mutating func visitStrong(_ strong: Strong) -> NSMutableAttributedString {
        // Bold takes the emphasis colour, but not across the board: in `**==x==**` the highlight's
        // ground is the theme's colour and text in it would vanish. Only runs with no
        // highlight ground take the colour; a highlighted run keeps its own.
        let content = mergeIntent(.stronglyEmphasized, children: Array(strong.children))
        let color = strongColor
        content.enumerateAttribute(.backgroundColor, in: content.fullRange) { value, range, _ in
            if value == nil { content.addAttribute(.foregroundColor, value: color, range: range) }
        }
        // At the typography's bold weight, not the bold trait's semibold.
        content.enumerateAttribute(.font, in: content.fullRange) { value, range, _ in
            content.addAttribute(.font, value: strengthened(value as? UIFont ?? bodyFont), range: range)
        }
        return content
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSMutableAttributedString {
        // The text view draws no presentation intent: the line is its own attribute.
        let content = mergeIntent(.strikethrough, children: Array(strikethrough.children))
        content.merge([.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        return content
    }

    mutating func visitLink(_ link: Markdown.Link) -> NSMutableAttributedString {
        // The app's own inline links (a local file: its type's icon and name): without this hook
        // here a file link's icon would be lost in selectable text.
        if let custom = customInlineLinkContent(link) { return custom }
        // The link's colour, underline and `.link` (tappable). The text view's link attributes
        // are empty, so the style is what's set here, not the tint.
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let content = NSMutableAttributedString()
        if let destination = link.destination, let url = URL(string: destination) {
            attributes[.link] = url
            if let icon = siteIconPiece(for: url) { content.append(icon) }
        }
        let children = descendInto(link)
        children.merge(attributes)
        content.append(children)
        return content
    }

    /// A web link's site icon: an attachment (1 storage character, no plain units, anchored
    /// where the link starts, revealed with it) with its own even room on both sides, then a
    /// word joiner gluing it to the link's text, so a line never ends on the icon alone. Nil
    /// for links that aren't web pages', or when icons are off.
    private mutating func siteIconPiece(for url: URL) -> NSMutableAttributedString? {
        guard style.linkSiteIcons, let host = Self.siteHost(of: url) else { return nil }
        appendMap(storageCount: 1, plainSpan: 0)
        revealCursor += 1
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let font = bodyFont
        nonisolated(unsafe) let color = linkColor
        nonisolated(unsafe) let style = style
        let content = anyThreadAttachmentString(MarkdownSiteIconAttachment(id: id, host: host, url: url, font: font, color: color, style: style))
        let glue = markRevealOffsets(NSMutableAttributedString(string: "\u{2060}", attributes: [.font: bodyFont]), start: revealCursor)
        appendMap(storageCount: 1, plainSpan: 0)
        revealCursor += 1
        content.append(glue)
        return content
    }

    /// The host whose icon a link shows: a web page's only.
    private static func siteHost(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return host
    }

    /// What the builder returns splits in two: a symbol run (`.markdownInlineSymbol` on U+FFFC)
    /// becomes an attachment; TextKit 2 draws image attachments in their own subviews, which a
    /// reveal's per-character alpha can't reach, so an icon fades in whole. The rest is text in
    /// the body font with the builder's link, colour and underline, one by one when its count
    /// matches the source's plain count, else anchored at the start with the rest closed at the end.
    private mutating func customInlineLinkContent(_ link: Markdown.Link) -> NSMutableAttributedString? {
        guard let builder = style.inlineLinkBuilder, let destination = link.destination else { return nil }
        let tint = linkColor
        guard Thread.isMainThread else {
            gate.needsMainThread = true
            return nil
        }
        let label = link.plainText
        guard let built = MainActor.assumeIsolated({ MarkdownMainThreadMade(value: builder(destination, label, tint)) }).value else { return nil }

        // A first look: the text's length (less one NBSP after the symbol, counted apart)
        // decides 1:1 or anchored.
        var totalTextCount = 0
        var probeSawSymbol = false
        var probeStripped = false
        built.enumerateAttributes(in: NSRange(location: 0, length: built.length)) { attributes, range, _ in
            if attributes[.markdownInlineSymbol] != nil {
                probeSawSymbol = true
                return
            }
            var text = (built.string as NSString).substring(with: range)
            if probeSawSymbol, !probeStripped, text.hasPrefix("\u{00A0}") {
                text.removeFirst()
                probeStripped = true
            }
            totalTextCount += text.count
        }
        guard probeSawSymbol || totalTextCount > 0 else { return nil }
        let plainTotal = link.markdownRevealPlainText.count
        let oneToOne = totalTextCount == plainTotal

        let content = NSMutableAttributedString()
        var plainRemaining = plainTotal
        var sawSymbol = false
        var handledNBSP = false
        var runs: [([NSAttributedString.Key: Any], NSRange)] = []
        built.enumerateAttributes(in: NSRange(location: 0, length: built.length)) { attributes, range, _ in
            runs.append((attributes, range))
        }
        for (attributes, range) in runs {
            if let symbol = attributes[.markdownInlineSymbol] as? String {
                sawSymbol = true
                appendMap(storageCount: 1, plainSpan: 0)
                revealCursor += 1
                // Only decoration: an icon doesn't copy.
                nonisolated(unsafe) let id = nextAttachmentID()
                nonisolated(unsafe) let font = bodyFont
                nonisolated(unsafe) let color = attributes[.foregroundColor] as? UIColor ?? tint
                nonisolated(unsafe) let url = attributes[.link] as? URL
                nonisolated(unsafe) let style = style
                content.append(anyThreadAttachmentString(MarkdownInlineSymbolAttachment(id: id, systemName: symbol, font: font, color: color, url: url, style: style)))
                continue
            }
            let text = (built.string as NSString).substring(with: range)
            guard !text.isEmpty else { continue }
            // The NBSP after a symbol stays as real text: it glues the icon and the file name
            // into one unit for line breaking (UAX14 GL). As the icon's trailing room there'd be
            // a legal break after the attachment and a long name would leave it alone at a
            // line's end. Its map is apart: 1 storage, 0 plain.
            let leadingNBSP = sawSymbol && !handledNBSP && text.hasPrefix("\u{00A0}")
            if leadingNBSP { handledNBSP = true }
            var piece: [NSAttributedString.Key: Any] = [.font: bodyFont]
            if let color = attributes[.foregroundColor] { piece[.foregroundColor] = color }
            if let url = attributes[.link] { piece[.link] = url }
            if attributes[.underlineStyle] != nil { piece[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            let attributed = markRevealOffsets(NSMutableAttributedString(string: text, attributes: piece), start: revealCursor)
            let n = text.count
            if leadingNBSP {
                appendMap(storageCount: 1, plainSpan: 0)  // Anchored at the link's start, with the icon.
                let rest = n - 1
                let span = oneToOne ? rest : min(rest, plainRemaining)
                appendMap(storageCount: rest, plainSpan: span)
                plainRemaining -= span
            } else {
                let span = oneToOne ? n : min(n, plainRemaining)
                appendMap(storageCount: n, plainSpan: span)
                plainRemaining -= span
            }
            revealCursor += n
            content.append(attributed)
        }
        // What plain is left (a builder's text shorter than the source, a file name for an empty
        // label): no storage takes it up, so later nodes' anchors don't drift.
        if plainRemaining > 0 {
            appendMap(storageCount: 0, plainSpan: plainRemaining)
        }
        return content
    }

    // MARK: - Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSMutableAttributedString {
        let start = storageToPlain.count
        return paragraphContainer(applyingCrossNodeHighlight(descendInto(paragraph), storageStart: start))
    }

    mutating func visitHeading(_ heading: Heading) -> NSMutableAttributedString {
        let start = storageToPlain.count
        return headingContainer(applyingCrossNodeHighlight(descendInto(heading), storageStart: start), level: heading.level)
    }

    // Blocks that aren't text are a seam for now (MarkdownBlockView's pending kinds).
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSMutableAttributedString {
        nonisolated(unsafe) let codeBlock = codeBlock
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let style = style
        return attachmentBlock(codeBlock) { style.nestedBlock?(codeBlock, style) ?? MarkdownCodeAttachment(id: id, code: codeBlock, style: style) }
    }
    mutating func visitTable(_ table: Markdown.Table) -> NSMutableAttributedString {
        nonisolated(unsafe) let table = table
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let style = style
        nonisolated(unsafe) let inlineMath = inlineMathStorage
        nonisolated(unsafe) let displayMath = displayMathStorage
        return attachmentBlock(table) { style.nestedBlock?(table, style) ?? MarkdownTableAttachment(id: id, table: table, style: style, inlineMath: inlineMath, displayMath: displayMath) }
    }

    /// An HTML block shows as its source, as it does in MarkdownView: no web view for a row.
    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) -> NSMutableAttributedString {
        nonisolated(unsafe) let htmlBlock = htmlBlock
        if style.nestedBlock != nil {
            nonisolated(unsafe) let style = style
            return attachmentBlock(htmlBlock) { style.nestedBlock!(htmlBlock, style) ?? MarkdownEmptyAttachment(id: AnyHashable(0), replacement: htmlBlock.format()) }
        }
        let raw = htmlBlock.rawHTML
        appendMap(storageCount: raw.count, plainSpan: htmlBlock.markdownRevealPlainText.count)
        revealCursor += raw.count
        return NSMutableAttributedString(string: raw, attributes: [.font: bodyFont])
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSMutableAttributedString {
        nonisolated(unsafe) let thematicBreak = thematicBreak
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let style = style
        nonisolated(unsafe) let source = thematicBreak.format()
        return attachmentBlock(thematicBreak) { style.nestedBlock?(thematicBreak, style) ?? MarkdownRuleAttachment(id: id, source: source) }
    }

    mutating func visitBlockDirective(_ blockDirective: BlockDirective) -> NSMutableAttributedString {
        nonisolated(unsafe) let blockDirective = blockDirective
        // A directive nothing renders shows its content as markdown: MarkdownView's vanishes.
        if blockDirective.name != MarkdownTree.mathAttribute {
            if style.nestedBlock != nil {
                nonisolated(unsafe) let style = style
                return attachmentBlock(blockDirective) { style.nestedBlock!(blockDirective, style) ?? MarkdownEmptyAttachment(id: AnyHashable(0), replacement: blockDirective.format()) }
            }
            guard let renderer = style.blockDirective(named: blockDirective.name) else { return descendInto(blockDirective) }
            nonisolated(unsafe) let id = nextAttachmentID()
            nonisolated(unsafe) let source = blockDirective.format()
            return attachmentBlock(blockDirective) {
                MarkdownCustomViewAttachment(id: id, view: renderer(MarkdownDirectiveRequest(blockDirective)), source: source)
            }
        }
        if blockDirective.name == MarkdownTree.mathAttribute, style.nestedBlock == nil,
           let value = blockDirective.argumentText.parseNameValueArguments().first?.value,
           let id = UUID(uuidString: value), let latex = displayMathStorage[id] {
            nonisolated(unsafe) let id = nextAttachmentID()
            nonisolated(unsafe) let style = style
            return attachmentBlock(blockDirective) { MarkdownDisplayMathAttachment(id: id, latex: latex, style: style) }
        }
        return blockSeam(blockDirective)
    }

    mutating func visitImage(_ image: Markdown.Image) -> NSMutableAttributedString {
        nonisolated(unsafe) let image = image
        if style.inlineImage != nil, !Thread.isMainThread {
            gate.needsMainThread = true
            return NSMutableAttributedString()
        }
        if style.inlineImage != nil {
            nonisolated(unsafe) let style = style
            let seam = MainActor.assumeIsolated { MarkdownMainThreadMade(value: style.inlineImage?(image, style)) }.value
            nonisolated(unsafe) let made = seam
            if let made { return attachmentBlock(image) { made } }
        }
        // By the URL's scheme: a host's renderer, the network's two, or a path from the base.
        // Anything else shows its description.
        let written = image.source.flatMap { URL(string: $0) }
        var url: URL?
        if let written {
            if let scheme = written.scheme, let renderer = style.imageRenderer(forScheme: scheme) {
                nonisolated(unsafe) let id = nextAttachmentID()
                nonisolated(unsafe) let source = image.format()
                return attachmentBlock(image) {
                    let view = renderer(MarkdownImageRequest(url: written, alternativeText: MarkdownImageSource.alternativeText(of: image)))
                    return MarkdownCustomViewAttachment(id: id, view: view, source: source)
                }
            }
            url = style.fetchedImageURL(written)
        }
        // A picture that's come is made on any thread: text with it is built ahead.
        if let url, let loaded = MarkdownImageLoader.loaded(url) {
            let attachment = MarkdownLoadedImageAttachment(
                id: nextAttachmentID(),
                loaded: loaded,
                isAlone: image.parent is Paragraph && image.parent?.childCount == 1,
                alternativeText: MarkdownImageSource.alternativeText(of: image),
                source: image.format(),
                style: style
            )
            appendMap(storageCount: 1, plainSpan: image.markdownRevealPlainText.count)
            revealCursor += 1
            return anyThreadAttachmentString(attachment)
        }
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let shownURL = url
        nonisolated(unsafe) let style = style
        return attachmentBlock(image) { MarkdownImageAttachment(id: id, image: image, url: shownURL, style: style) }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSMutableAttributedString {
        nonisolated(unsafe) let blockQuote = blockQuote
        // A quote inside another block: black and white inside, and its own decoration as an
        // attachment. A top-level one is MarkdownBlockView's.
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let style = style
        return attachmentBlock(blockQuote) { MarkdownNestedQuoteAttachment(id: id, quote: blockQuote, style: style) }
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> NSMutableAttributedString {
        renderList(list, baseIndent: style.list.leadingIndentation)
    }

    mutating func visitOrderedList(_ list: OrderedList) -> NSMutableAttributedString {
        renderList(list, baseIndent: style.list.leadingIndentation)
    }

    /// One character for a block: its plain units anchored at its start. It copies as its source.
    private mutating func attachmentBlock(_ markup: any Markup, make: @MainActor () -> RichTextAttachment) -> NSMutableAttributedString {
        appendMap(storageCount: 1, plainSpan: markup.markdownRevealPlainText.count)
        revealCursor += 1
        return attachmentString(make)
    }

    /// A picture in an item starts at the item's content: it's narrower by that.
    private func indentImages(in text: NSAttributedString, by indent: CGFloat) {
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let image = value as? MarkdownImageAttachment {
                image.lineIndent = max(image.lineIndent, indent)
            } else if let image = value as? MarkdownLoadedImageAttachment {
                image.lineIndent = max(image.lineIndent, indent)
            }
        }
    }

    private mutating func blockSeam(_ markup: any Markup) -> NSMutableAttributedString {
        nonisolated(unsafe) let markup = markup
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let style = style
        nonisolated(unsafe) let replacement = markup.format()
        return attachmentBlock(markup) { style.nestedBlock?(markup, style) ?? MarkdownEmptyAttachment(id: id, replacement: replacement) }
    }

    // MARK: - Putting together

    mutating func descendInto(_ markup: any Markup) -> NSMutableAttributedString {
        let combined = NSMutableAttributedString()
        let children = Array(markup.children)
        var index = 0
        while index < children.count {
            // Consecutive "cite" links (white space allowed between) fold into one chip.
            if let group = MarkdownLinkChips.consecutiveChipLinks(in: children, from: index) {
                let plainSpan = (index..<group.nextIndex).reduce(0) { $0 + children[$1].markdownRevealPlainText.count }
                combined.append(chipContent(group: group, plainSpan: plainSpan))
                index = group.nextIndex
                continue
            }
            combined.append(visit(children[index]))
            index += 1
        }
        return combined
    }

    /// Emphasis, bold, strikethrough: the intent over each child whole. A child with a mixed
    /// intent inside takes only this one, as an attributed string's whole-value read gives nothing.
    private mutating func mergeIntent(_ intent: InlineIntent, children: [any Markup]) -> NSMutableAttributedString {
        let attributed = NSMutableAttributedString()
        for child in children {
            let content = visit(child)
            guard content.length > 0 else { continue }
            content.addAttribute(.markdownIntent, value: NSNumber(value: Self.uniformIntent(of: content).union(intent).rawValue), range: content.fullRange)
            attributed.append(content)
        }
        return attributed
    }

    private static func uniformIntent(of text: NSAttributedString) -> InlineIntent {
        var range = NSRange()
        guard let value = text.attribute(.markdownIntent, at: 0, effectiveRange: &range) as? NSNumber, range.length == text.length else { return [] }
        return InlineIntent(rawValue: value.uintValue)
    }

    // MARK: - Helpers

    private var linkColor: UIColor { style.resolvedLinkColor }

    private var strongColor: UIColor { style.resolvedStrongColor }

    private mutating func nextAttachmentID() -> AnyHashable {
        defer { attachmentCounter += 1 }
        return AnyHashable(attachmentCounter)
    }

    /// One storage character for what `make` makes on the main thread. Off it, nothing, and the
    /// gate tells the builder this text has to be built there.
    /// An attachment made on any thread: text with it can be built ahead.
    private func anyThreadAttachmentString(_ attachment: RichTextAttachment) -> NSMutableAttributedString {
        NSMutableAttributedString(string: "\u{FFFC}", attributes: [.attachment: attachment, .inlineHostingAttachment: attachment])
    }

    private func attachmentString(_ make: @MainActor () -> RichTextAttachment) -> NSMutableAttributedString {
        guard Thread.isMainThread else {
            gate.needsMainThread = true
            return NSMutableAttributedString()
        }
        let attachment = MainActor.assumeIsolated { MarkdownMainThreadMade(value: make()) }.value
        return NSMutableAttributedString(string: "\u{FFFC}", attributes: [.attachment: attachment, .inlineHostingAttachment: attachment])
    }

    /// Highlights across nodes: `baseAttributed` handles `==x==` a text node at a time, which
    /// misses a span split into nodes (code, bold or a link inside). Once a paragraph, heading
    /// or list item is put together, the whole is scanned: ground and text colour on, both `==`
    /// out, and the map's tail fixed (each `==` character was 1 storage and 1 plain, later plain
    /// moves down; a reveal's count has them stripped already).
    /// `storageStart`: the map's length before the content (it's at the map's tail, 1:1 with characters).
    private mutating func applyingCrossNodeHighlight(_ content: NSMutableAttributedString, storageStart: Int) -> NSMutableAttributedString {
        guard MarkdownHighlightSyntax.isEnabled, style.interpretsTextSyntax else { return content }
        let flat = content.string
        let matches = MarkdownHighlightSyntax.matchOffsets(flat)
        guard !matches.isEmpty else { return content }

        let offsets = flat.characterUTF16Offsets
        var removed = Set<Int>()
        for match in matches {
            for o in match.start..<match.innerStart { removed.insert(o) }
            for o in match.innerEnd..<match.end { removed.insert(o) }
            // An attachment in it can't take a ground: it's left as it is.
            let inner = NSRange(location: offsets[match.innerStart], length: offsets[match.innerEnd] - offsets[match.innerStart])
            content.enumerateAttributes(in: inner) { attributes, range, _ in
                guard attributes[.attachment] == nil else { return }
                if attributes[.font] == nil { content.addAttribute(.font, value: bodyFont, range: range) }
                content.addAttribute(.backgroundColor, value: style.resolvedHighlightFill, range: range)
                content.addAttribute(.markdownHighlightGround, value: style.resolvedHighlightFill, range: range)
                if let text = style.highlightText { content.addAttribute(.foregroundColor, value: text, range: range) }
            }
        }
        for o in removed.sorted(by: >) {
            content.deleteCharacters(in: NSRange(location: offsets[o], length: offsets[o + 1] - offsets[o]))
        }

        // The map's tail: delimiters out, plain after them down by how many went before.
        if storageStart <= storageToPlain.count {
            var newTail: [Int] = []
            var removedBefore = 0
            for (i, plainValue) in storageToPlain[storageStart...].enumerated() {
                if removed.contains(i) { removedBefore += 1 } else { newTail.append(plainValue - removedBefore) }
            }
            storageToPlain.replaceSubrange(storageStart..., with: newTail)
            plainCursor -= removedBefore
            revealCursor -= removedBefore
        }
        return content
    }

    /// Text in the body font, with `==x==` and pen marks applied.
    private func baseAttributed(_ string: String) -> NSMutableAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: bodyFont]
        // A base colour (a host's secondary text): with none on the run the text view draws its
        // default. Before highlights: a highlight's text colour goes over it.
        if let textColor = style.textColor { attributes[.foregroundColor] = textColor }
        let attributed = NSMutableAttributedString(string: string, attributes: attributes)
        // Pen marks: delimiters out, the attribute in storage (a reveal's count is aligned on
        // both sides); the overlay draws them.
        guard style.interpretsTextSyntax else { return attributed }
        applyHighlights(to: attributed)
        applyPenMarks(to: attributed)
        return attributed
    }

    /// Ground and text colour on the inner text, then delimiters out from the tail, so what's
    /// taken out doesn't move the matches before it.
    private func applyHighlights(to attributed: NSMutableAttributedString) {
        let matches = MarkdownHighlightSyntax.matchOffsets(attributed.string)
        guard !matches.isEmpty else { return }
        let offsets = attributed.string.characterUTF16Offsets
        for m in matches {
            let inner = NSRange(location: offsets[m.innerStart], length: offsets[m.innerEnd] - offsets[m.innerStart])
            attributed.addAttribute(.backgroundColor, value: style.resolvedHighlightFill, range: inner)
            attributed.addAttribute(.markdownHighlightGround, value: style.resolvedHighlightFill, range: inner)
            if let text = style.highlightText { attributed.addAttribute(.foregroundColor, value: text, range: inner) }
        }
        for m in matches.reversed() {
            attributed.deleteCharacters(in: NSRange(location: offsets[m.innerEnd], length: offsets[m.end] - offsets[m.innerEnd]))
            attributed.deleteCharacters(in: NSRange(location: offsets[m.start], length: offsets[m.innerStart] - offsets[m.start]))
        }
    }

    private func applyPenMarks(to attributed: NSMutableAttributedString) {
        let matches = MarkdownPenMarkSyntax.matchOffsets(attributed.string)
        guard !matches.isEmpty else { return }
        let offsets = attributed.string.characterUTF16Offsets
        for m in matches {
            let inner = NSRange(location: offsets[m.innerStart], length: offsets[m.innerEnd] - offsets[m.innerStart])
            if m.kind == .color {
                if let color = MarkdownInk.markedText(m.color) { attributed.addAttribute(.foregroundColor, value: color, range: inner) }
            } else {
                attributed.addAttribute(.richTextPenMark, value: MarkdownPenMarkSyntax.encodeAttributeValue(m), range: inner)
                if m.kind == .marker { attributed.addAttribute(.markdownHighlightGround, value: MarkdownInk.marker(m.color), range: inner) }
            }
        }
        for m in matches.reversed() {
            attributed.deleteCharacters(in: NSRange(location: offsets[m.innerEnd], length: offsets[m.end] - offsets[m.innerEnd]))
            attributed.deleteCharacters(in: NSRange(location: offsets[m.start], length: offsets[m.innerStart] - offsets[m.start]))
        }
    }

    /// A paragraph: 5 above, 5 + componentSpacing below, as MarkdownView's block padding and stack.
    /// Above goes on paragraphSpacingBefore (nothing at a document's start, the view's edge
    /// inset does that). Below goes on paragraphSpacing less the lineSpacing TextKit adds after
    /// a paragraph's last line, so the junction is 5 + componentSpacing + 5.
    private func paragraphContainer(_ content: NSMutableAttributedString) -> NSMutableAttributedString {
        // CJK line box: TextKit 2's line height is the largest of its runs' ascent + descent. CJK
        // falls back to PingFang (16 pt ≈ 22.0) taller than SF (≈ 20.29), so it grows line by
        // line where SwiftUI's Text keeps the main font's. min/maximumLineHeight are ignored
        // there (measured: pinned to 20.29, still 22.0). The one lever is taking the difference
        // off lineSpacing for a paragraph with CJK: the baseline pitch agrees (20.29 + 5) and
        // what's left is one +Δ at the paragraph's start. The junction uses the same value.
        let spacing = effectiveLineSpacing(for: content)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 5
        paragraph.paragraphSpacing = max(0, 5 + style.componentSpacing - spacing)
        paragraph.lineSpacing = spacing
        paragraph.alignment = style.typography.paragraphAlignment
        content.merge([.paragraphStyle: paragraph as NSParagraphStyle])
        return content
    }

    /// With CJK in it: line spacing less the CJK fallback's extra line box (see paragraphContainer).
    private func effectiveLineSpacing(for content: NSAttributedString) -> CGFloat {
        guard style.lineSpacing > 0 else { return style.lineSpacing }
        let delta = Self.cjkLineBoxDelta(for: bodyFont)
        guard delta > 0, content.string.contains(where: \.triggersCJKLineBox) else { return style.lineSpacing }
        return max(0, style.lineSpacing - delta)
    }

    /// PingFang's line box less the main font's, by size.
    private static let cjkLineBoxDeltaCache = MarkdownLockedCache<CGFloat, CGFloat>()
    private static func cjkLineBoxDelta(for font: UIFont) -> CGFloat {
        if let cached = cjkLineBoxDeltaCache.value(for: font.pointSize) { return cached }
        let primary = font.ascender - font.descender
        var fallback = primary
        if let pingfang = UIFont(name: "PingFangSC-Regular", size: font.pointSize) {
            fallback = pingfang.ascender - pingfang.descender
        }
        let delta = max(0, fallback - primary)
        cjkLineBoxDeltaCache.set(delta, for: font.pointSize)
        return delta
    }

    /// A heading: its font and its padding (h1 12 above and 6 below, down to h6 2 and 1). The
    /// overrides are for an extended heading's junction.
    private func headingContainer(
        _ content: NSMutableAttributedString,
        level: Int,
        spacingBeforeOverride: CGFloat? = nil,
        spacingAfterOverride: CGFloat? = nil,
        lineSpacingOverride: CGFloat? = nil
    ) -> NSMutableAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = spacingBeforeOverride ?? style.headingPaddings.top(level)
        // Below: this level's padding and the space between blocks, less TextKit's own line
        // spacing. A document's last block has none (the view's edge inset does that).
        paragraph.paragraphSpacing = spacingAfterOverride
            ?? max(0, style.headingPaddings.bottom(level) + style.componentSpacing - style.lineSpacing)
        paragraph.lineSpacing = lineSpacingOverride ?? style.lineSpacing
        var attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraph as NSParagraphStyle,
            // From the typography, at the text's size: a multiple of the body font doesn't match
            // (h2 23.8 against 22).
            .font: style.typography.heading(level).font(at: style.contentSizeCategory),
        ]
        if let color = style.headingColors[min(max(level, 1), 6)] { attributes[.foregroundColor] = color }
        content.merge(attributes)
        return content
    }

    // MARK: - Maths

    /// Text and formulas: a formula is one attachment, selectable with the text around it.
    private mutating func inlineMathContent(plain: String) -> NSMutableAttributedString {
        let content = NSMutableAttributedString()
        var search = plain.startIndex..<plain.endIndex
        while let match = firstInlineMath(in: plain, range: search) {
            if search.lowerBound < match.range.lowerBound {
                // Text between formulas may hold footnotes too (one Text node has both).
                content.append(footnoteAwareContent(
                    String(plain[search.lowerBound..<match.range.lowerBound]),
                    isNodeStart: search.lowerBound == plain.startIndex
                ))
            }
            // 1 storage character, but the plain text holds the whole placeholder (⸨imath:ID⸩,
            // ≈ 11 units): anchored at its start, so a frontier past it shows the formula whole.
            appendMap(storageCount: 1, plainSpan: plain.distance(from: match.range.lowerBound, to: match.range.upperBound))
            revealCursor += 1
            content.append(mathAttachment(latex: match.latex))
            search = match.range.upperBound..<plain.endIndex
        }
        if search.lowerBound < plain.endIndex {
            content.append(footnoteAwareContent(String(plain[search]), isNodeStart: search.lowerBound == plain.startIndex))
        }
        return content
    }

    /// A tree's inline maths node.
    private mutating func treeMathContent(_ attributes: InlineAttributes) -> NSMutableAttributedString {
        appendMap(storageCount: 1, plainSpan: attributes.markdownRevealPlainText.count)
        revealCursor += 1
        return mathAttachment(latex: attributes.plainText)
    }

    private mutating func mathAttachment(latex: String) -> NSMutableAttributedString {
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let style = style
        nonisolated(unsafe) let font = bodyFont
        if !Thread.isMainThread, style.inlineMath == nil {
            // A formula with an image needs no main thread. One that failed shows its source in a view.
            let attachment = MarkdownInlineMathAttachment(id: id, latex: latex, style: style)
            if attachment.fixedSize != nil {
                return NSMutableAttributedString(string: "\u{FFFC}", attributes: [.attachment: attachment, .inlineHostingAttachment: attachment])
            }
        }
        return attachmentString { style.inlineMath?(latex, font) ?? MarkdownInlineMathAttachment(id: id, latex: latex, style: style) }
    }

    private func firstInlineMath(in text: String, range: Range<String.Index>) -> (range: Range<String.Index>, latex: String)? {
        inlineMathStorage
            .compactMap { id, latex -> (Range<String.Index>, String)? in
                let placeholder = MarkdownInlineMathPlaceholder.prefix + id + MarkdownInlineMathPlaceholder.suffix
                guard let r = text.range(of: placeholder, range: range) else { return nil }
                return (r, latex)
            }
            .min { $0.0.lowerBound < $1.0.lowerBound }
    }

    // MARK: - Chips

    /// A chip is an attachment, not text: it selects as one unit, copying its label, never a cut
    /// through its NBSP and word joiners. What folds and how it's labelled is all MarkdownLinkChips.
    private mutating func chipContent(group: MarkdownLinkChips.ChipGroup, plainSpan: Int) -> NSMutableAttributedString {
        nonisolated(unsafe) let group = group
        appendMap(storageCount: 1, plainSpan: plainSpan)
        revealCursor += 1
        nonisolated(unsafe) let id = nextAttachmentID()
        nonisolated(unsafe) let style = style
        return anyThreadAttachmentString(MarkdownChipAttachment(id: id, label: group.label, urls: group.urls, style: style))
    }

    /// Emphasis on CJK leans (0.18, as MarkdownView's). Not with the obliqueness attribute:
    /// TextKit 2 ignores it, and this path needs TextKit 2 for its reveal. So the matrix goes in
    /// the font, which layout, drawing and selection all follow.
    private func applyingCJKObliqueness(_ content: NSMutableAttributedString) -> NSMutableAttributedString {
        let string = content.string
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            if string[index].isCJKForItalic {
                let range = NSRange(index..<next, in: string)
                if let raw = content.attribute(.markdownIntent, at: range.location, effectiveRange: nil) as? NSNumber,
                   InlineIntent(rawValue: raw.uintValue).contains(.emphasized) {
                    let base = content.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? bodyFont
                    content.addAttribute(.font, value: Self.obliqueFont(base), range: range)
                    // Take .emphasized off: CJK has no italic trait, and leaving it has the last
                    // step copy the font with a trait, which could reset the matrix.
                    var intent = InlineIntent(rawValue: raw.uintValue)
                    intent.remove(.emphasized)
                    if intent.isEmpty {
                        content.removeAttribute(.markdownIntent, range: range)
                    } else {
                        content.addAttribute(.markdownIntent, value: NSNumber(value: intent.rawValue), range: range)
                    }
                }
            }
            index = next
        }
        return content
    }

    /// The font with the 0.18 skew, kept: this goes character by character. Through CoreText:
    /// `UIFont(descriptor: …withMatrix…)` doesn't apply a matrix, CTFontCreateCopyWithAttributes does.
    private static let obliqueFontCache = MarkdownLockedCache<UIFont, UIFont>()
    private static func obliqueFont(_ font: UIFont) -> UIFont {
        if let hit = obliqueFontCache.value(for: font) { return hit }
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.18, d: 1, tx: 0, ty: 0)
        let skewed: UIFont = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, &matrix, nil)
        obliqueFontCache.set(skewed, for: font)
        return skewed
    }

    /// Doesn't set a per-character reveal offset, on purpose: nothing reads that attribute, the
    /// reveal goes by storage offsets, and setting it would split the text into N runs for
    /// nothing. Kept so the meaning and the places that would call it stay.
    private func markRevealOffsets(_ attributed: NSMutableAttributedString, start: Int) -> NSMutableAttributedString {
        attributed
    }

    // MARK: - Lists

    private mutating func renderList(_ list: any ListItemContainer & Markup, baseIndent: CGFloat) -> NSMutableAttributedString {
        let combined = NSMutableAttributedString()
        for listItem in list.listItems {
            // The newline's map comes before the item's; plain has no separator between items.
            let isFirst = combined.length == 0
            if !isFirst { appendMap(storageCount: 1, plainSpan: 0) }
            let content = renderListItem(listItem, baseIndent: baseIndent)
            if content.length == 0 {
                if !isFirst { storageToPlain.removeLast() }
                continue
            }
            if !isFirst { combined.append(NSAttributedString(string: "\n")) }
            combined.append(content)
        }
        return combined
    }

    private mutating func renderListItem(_ listItem: ListItem, baseIndent: CGFloat) -> NSMutableAttributedString {
        let spacing: CGFloat = 8  // As a list row's stack.
        // A custom bullet: the content is a copy with `{token}` taken off (the marker shows it),
        // and with no leading indentation; nesting's indent is the outer padding.
        let contentItem = listItem.strippingCustomMarker()
        let effectiveBaseIndent = listItem.customListMarkerMatch != nil ? 0 : baseIndent
        // The marker shows with the content's first character: characters but no plain units.
        let (marker, markerWidth) = makeListMarker(listItem)
        let markerStorageCount = marker.string.count
        appendMap(storageCount: markerStorageCount, plainSpan: 0)
        appendMap(storageCount: 2, plainSpan: 0)  // "\t" and the word joiner, below.
        revealCursor += markerStorageCount + 2
        let contentIndent = effectiveBaseIndent + markerWidth + spacing

        // Leading: the item's first paragraph. Trailing: nested lists and other blocks, with
        // their newline's map before their content.
        let leading = NSMutableAttributedString()
        let trailing = NSMutableAttributedString()
        var trailingSeparatorPending = false
        var sawFirstParagraph = false
        for child in contentItem.children {
            if child is Paragraph, !sawFirstParagraph {
                sawFirstParagraph = true
                let start = storageToPlain.count
                leading.append(applyingCrossNodeHighlight(descendInto(child), storageStart: start))
            } else {
                if trailing.length > 0 {
                    appendMap(storageCount: 1, plainSpan: 0)
                    revealCursor += 1
                    trailing.append(NSAttributedString(string: "\n"))
                } else if !trailingSeparatorPending {
                    // The "\n" between leading and trailing, put in below.
                    appendMap(storageCount: 1, plainSpan: 0)
                    revealCursor += 1
                    trailingSeparatorPending = true
                }
                // A nested list's base indent is this item's content, as it sits in its parent.
                if let nested = child as? UnorderedList {
                    trailing.append(renderList(nested, baseIndent: contentIndent))
                } else if let nested = child as? OrderedList {
                    trailing.append(renderList(nested, baseIndent: contentIndent))
                } else if child is Paragraph {
                    // An item's next paragraph is a paragraph of its own at the content's indent.
                    // MarkdownView's glues it to the first with no space.
                    let start = storageToPlain.count
                    trailing.append(itemParagraph(applyingCrossNodeHighlight(descendInto(child), storageStart: start), contentIndent: contentIndent))
                } else {
                    trailing.append(visit(child))
                }
            }
        }
        if trailingSeparatorPending, trailing.length == 0 {
            storageToPlain.removeLast()
            revealCursor -= 1
        }

        indentImages(in: leading, by: contentIndent)
        indentImages(in: trailing, by: contentIndent)
        // Made after the content: the CJK correction looks at the leading text.
        let itemStyle = itemParagraphStyle(for: leading, firstLineIndent: effectiveBaseIndent, contentIndent: contentIndent)
        itemStyle.tabStops = [NSTextTab(textAlignment: tabAlignment, location: contentIndent)]
        let paragraphOnly: [NSAttributedString.Key: Any] = [.paragraphStyle: itemStyle as NSParagraphStyle]
        var itemAttributes = paragraphOnly
        itemAttributes[.font] = bodyFont

        marker.merge(paragraphOnly)  // The marker keeps its colour and font, and takes the paragraph's style.
        let result = marker
        let markerEnd = result.length
        // A tab to contentIndent, then a word joiner (U+2060, no break on either side, UAX14
        // LB11). A list row was two columns, its marker never apart from its content. In one text
        // flow a tab is a legal break, so a wide first unit (a file link's icon, NBSP and long
        // name) would go to the next line and leave the marker alone. The joiner holds them: a
        // token too wide breaks inside its line, as the two columns did.
        result.append(NSAttributedString(string: "\t\u{2060}", attributes: itemAttributes))
        result.addAttribute(.markdownListMarkerCopy, value: Self.copiedMarker(listItem, depthOffset: listDepthOffset), range: NSRange(location: 0, length: markerEnd + 2))
        if leading.length > 0 {
            leading.merge(itemAttributes)
            result.append(leading)
        }
        if trailing.length > 0 {
            result.append(NSAttributedString(string: "\n", attributes: itemAttributes))
            result.append(trailing)
        }
        return result
    }

    /// Paragraph spacing as a paragraph's, since a row's content was one.
    private func itemParagraphStyle(for content: NSAttributedString, firstLineIndent: CGFloat, contentIndent: CGFloat) -> NSMutableParagraphStyle {
        let spacing = effectiveLineSpacing(for: content)
        let itemStyle = NSMutableParagraphStyle()
        itemStyle.firstLineHeadIndent = firstLineIndent  // Where the marker starts.
        itemStyle.headIndent = contentIndent             // Wrapped lines line up with the content.
        itemStyle.paragraphSpacingBefore = 5
        itemStyle.paragraphSpacing = max(0, 5 + style.componentSpacing - spacing)
        itemStyle.lineSpacing = spacing
        return itemStyle
    }

    /// A tab stop counts from the leading edge in the paragraph's direction.
    private var tabAlignment: NSTextAlignment {
        style.layoutDirection == .rightToLeft ? .natural : .left
    }

    private func itemParagraph(_ content: NSMutableAttributedString, contentIndent: CGFloat) -> NSMutableAttributedString {
        let paragraph = itemParagraphStyle(for: content, firstLineIndent: contentIndent, contentIndent: contentIndent)
        content.merge([.paragraphStyle: paragraph as NSParagraphStyle, .font: bodyFont])
        return content
    }

    /// A list item's marker as Markdown writes it, indented two spaces a level.
    private static func copiedMarker(_ listItem: ListItem, depthOffset: Int) -> String {
        var depth = depthOffset
        var parent = listItem.parent
        while let current = parent {
            if current is ListItem { depth += 1 }
            parent = current.parent
        }
        let indent = String(repeating: "  ", count: max(0, depth))
        let task = listItem.checkbox.map { $0 == .checked ? "[x] " : "[ ] " } ?? ""
        if let ordered = listItem.parent as? OrderedList {
            return indent + "\(Int(ordered.startIndex) + listItem.indexInParent). " + task
        }
        return indent + "- " + task
    }

    /// The marker: • / ◦ or a number in secondary, a symbol for a task. With its measured
    /// width, for the content's tab stop.
    private mutating func makeListMarker(_ listItem: ListItem) -> (NSMutableAttributedString, CGFloat) {
        if let found = listItem.checkbox {
            nonisolated(unsafe) let checkbox = found
            // An attachment that fades in whole, like a chip. An image attachment was tried:
            // TextKit 2 gives those their own subview, which a per-character alpha can't reach.
            let size = bodyFont.pointSize
            nonisolated(unsafe) let id = nextAttachmentID()
            return (anyThreadAttachmentString(MarkdownTaskAttachment(id: id, checked: checkbox == .checked, size: size)), size)
        }
        // A custom bullet: an emoji is text (no harm to the tab); a symbol an attachment on a
        // disc, whose width is the disc's, or it'd eat the room before the content.
        if let match = listItem.customListMarkerMatch {
            switch match.marker {
            case .emoji(let emoji):
                let width = (emoji as NSString).size(withAttributes: [.font: bodyFont]).width
                return (NSMutableAttributedString(string: emoji, attributes: [.font: bodyFont]), width)
            case .symbol(let name):
                let diameter = bodyFont.pointSize * 1.2
                nonisolated(unsafe) let id = nextAttachmentID()
                return (anyThreadAttachmentString(MarkdownListSymbolAttachment(id: id, systemName: name, diameter: diameter)), diameter)
            }
        }
        let markerText: String
        let monospaced: Bool
        if let unordered = listItem.parent as? UnorderedList {
            // Plus the offset: a re-parsed item's AST depth is 0.
            markerText = style.list.unorderedMarker.marker(listDepth: unordered.listDepth + listDepthOffset)
            monospaced = style.list.unorderedMarker.monospaced
        } else if let ordered = listItem.parent as? OrderedList {
            // From the list's start (`3.` starts at 3) plus the item's place, not only its place:
            // a re-parsed item is a one-item list with startIndex N, whose place is always 0.
            let ordinal = Int(ordered.startIndex) - 1 + listItem.indexInParent
            markerText = style.list.orderedMarker.marker(at: max(0, ordinal))
            monospaced = false
        } else {
            return (NSMutableAttributedString(), 0)
        }
        let markerFont = monospaced ? UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular) : bodyFont
        let width = (markerText as NSString).size(withAttributes: [.font: markerFont]).width
        return (NSMutableAttributedString(string: markerText, attributes: [
            .font: markerFont,
            .foregroundColor: UIColor.floo(.markdownListMarker),
        ]), width)
    }

    // MARK: - The last step

    /// What a run doesn't name: the default font and paragraph, and the text's colour. Then
    /// the traits inline markup asked for, on the fonts as they ended up.
    private func finished(_ text: NSMutableAttributedString) -> NSMutableAttributedString {
        let full = text.fullRange
        let defaultFont = style.resolvedDefaultFont
        let defaultParagraph = NSMutableParagraphStyle()
        let isRTL = style.layoutDirection == .rightToLeft
        defaultParagraph.alignment = isRTL ? .right : .left
        defaultParagraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
        defaultParagraph.lineSpacing = style.lineSpacing
        defaultParagraph.lineBreakMode = .byWordWrapping
        let textColor = style.resolvedTextColor
        text.enumerateAttributes(in: full) { attributes, range, _ in
            if attributes[.font] == nil { text.addAttribute(.font, value: defaultFont, range: range) }
            if attributes[.paragraphStyle] == nil { text.addAttribute(.paragraphStyle, value: defaultParagraph, range: range) }
            if attributes[.foregroundColor] == nil { text.addAttribute(.foregroundColor, value: textColor, range: range) }
        }
        // Text on a highlight, its own colour or the text's, made to read on the ground.
        text.enumerateAttribute(.markdownHighlightGround, in: full) { value, range, _ in
            guard let ground = value as? UIColor else { return }
            text.enumerateAttribute(.foregroundColor, in: range) { color, colorRange, _ in
                guard let color = color as? UIColor else { return }
                text.addAttribute(.foregroundColor, value: UIColor.markdown(text: color, onGround: ground), range: colorRange)
            }
        }
        text.removeAttribute(.markdownHighlightGround, range: full)
        if let room = style.roomBelowLines {
            text.enumerateAttributes(in: full) { attributes, range, _ in
                // A block in an attachment has its own lines.
                guard attributes[.attachment] == nil,
                      let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                else { return }
                paragraph.lineSpacing += room
                paragraph.paragraphSpacing += room
                text.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
        }
        text.enumerateAttribute(.markdownIntent, in: full) { value, range, _ in
            guard let raw = value as? NSNumber else { return }
            let intent = InlineIntent(rawValue: raw.uintValue)
            if intent.contains(.strikethrough) {
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            text.enumerateAttribute(.font, in: range) { fontValue, fontRange, _ in
                guard let font = fontValue as? UIFont else { return }
                text.addAttribute(.font, value: Self.applying(intent, to: font), range: fontRange)
            }
        }
        return text
    }

    private static func applying(_ intent: InlineIntent, to font: UIFont) -> UIFont {
        var traits: [CTFontSymbolicTraits] = []
        if intent.contains(.stronglyEmphasized) { traits.append(.traitBold) }
        if intent.contains(.emphasized) { traits.append(.traitItalic) }
        var resolved = CTFontCreateCopyWithAttributes(font as CTFont, 0, nil, nil)
        for trait in traits {
            let existing = CTFontGetSymbolicTraits(resolved)
            guard !existing.contains(trait),
                  let updated = CTFontCreateCopyWithSymbolicTraits(resolved, 0, nil, existing.union(trait), trait) else { continue }
            resolved = updated
        }
        return resolved as UIFont
    }
}

public extension NSAttributedString.Key {
    /// A run that's one SF Symbol, from a custom inline link builder: its value is the symbol's
    /// name, its text U+FFFC.
    static let markdownInlineSymbol = NSAttributedString.Key("MarkdownInlineSymbol")
    /// On a list item's marker and the tab after it: what it copies as, Markdown's own marker.
    static let markdownListMarkerCopy = NSAttributedString.Key("MarkdownListMarkerCopy")
}

extension NSMutableAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }

    /// Over all of it, new values winning.
    func merge(_ attributes: [NSAttributedString.Key: Any]) {
        guard !attributes.isEmpty, length > 0 else { return }
        addAttributes(attributes, range: fullRange)
    }
}

extension String {
    /// Each Character's UTF-16 offset, and the length at the end.
    var characterUTF16Offsets: [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(utf16.count + 1)
        var offset = 0
        for character in self {
            offsets.append(offset)
            offset += character.utf16.count
        }
        offsets.append(offset)
        return offsets
    }
}

private extension Character {
    /// Han and kana: leans for italics where Latin takes the italic trait.
    var isCJKForItalic: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)   // CJK Unified Ideographs
            || (0x3040...0x30FF).contains(scalar.value) // Hiragana + Katakana
            || (0x3400...0x4DBF).contains(scalar.value) // CJK Ext A
            || (0xF900...0xFAFF).contains(scalar.value) // CJK Compatibility
        }
    }

    /// What raises TextKit 2's line box to the CJK fallback's metrics: Han, kana, Hangul,
    /// fullwidth punctuation.
    var triggersCJKLineBox: Bool {
        unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value)      // Radicals, CJK punctuation, kana, bopomofo, Han
            || (0x3400...0x4DBF).contains(scalar.value)   // Ext A
            || (0xAC00...0xD7AF).contains(scalar.value)   // Hangul syllables
            || (0xF900...0xFAFF).contains(scalar.value)   // Compatibility ideographs
            || (0xFF00...0xFFEF).contains(scalar.value)   // Full and halfwidth forms
            || (0x20000...0x2FFFF).contains(scalar.value) // Ext B+
        }
    }
}
