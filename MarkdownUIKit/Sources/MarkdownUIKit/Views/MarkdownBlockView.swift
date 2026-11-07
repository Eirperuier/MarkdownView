//
//  MarkdownBlockView.swift
//  MarkdownUIKit
//
//  One top-level markdown block, chosen as MarkdownView's stream block is: headings, paragraphs,
//  list items and quotes as selectable text, footnote definitions a line each. Its height is
//  known synchronously, on or off a window.
//

import Markdown
@_spi(MarkdownMath) import MarkdownCore
import RichTextCore
import UIKit

/// Why a block draws nothing yet.
public enum MarkdownPendingBlock: Equatable, Sendable {
    case code, table, displayMath, image, rule, html, directive, other
}

/// One `MarkdownStreamBlock`, in UIKit.
@MainActor
public final class MarkdownBlockView: UIView {
    /// The block's height changed by itself: a formula came in late.
    public var onHeightChange: (() -> Void)?

    private enum Layout {
        case empty
        /// A leading indent (a nested item's 20 pt a level) and the text.
        case text(MarkdownTextHost, leading: CGFloat)
        case quote(MarkdownQuoteView)
        case footnotes([MarkdownTextHost])
        case math(MarkdownDisplayMathView)
        case pending(MarkdownPendingBlock)
    }

    private var layout = Layout.empty
    private var style = MarkdownStyle()
    /// What a block is drawn from, to draw it again when its size category changes.
    private var rebuild: (() -> Void)?
    private var cachedHeight: (width: CGFloat, height: CGFloat)?
    private var reveal: MarkdownReveal?
    /// The block showing: the same one again grows what shows.
    private var shownBlockID: UUID?
    private lazy var mathGate = MarkdownRevealGate { [weak self] isOpen, fades in
        guard let self, case .math(let view) = self.layout else { return }
        let change = { view.alpha = isOpen ? 1 : 0 }
        if fades, let reveal = self.reveal {
            reveal.style.motion.animate(change)
        } else {
            change()
        }
    }

    /// The block that isn't drawn yet, nil if it's drawn.
    public var pendingBlock: MarkdownPendingBlock? {
        if case .pending(let kind) = layout { return kind }
        return nil
    }

    /// The text views inside, for a host's selection and hooks.
    public var textViews: [UITextView] {
        switch layout {
        case .empty, .pending, .math: []
        case .text(let host, _): [host.textView]
        case .quote(let quote): [quote.textView]
        case .footnotes(let hosts): hosts.map(\.textView)
        }
    }

    /// The text this block came to: what a reveal needs. Nil for what isn't text.
    public var text: MarkdownText? {
        if case .text(let host, _) = layout { return host.text }
        return nil
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MarkdownBlockView, _: UITraitCollection) in
            guard view.style.contentSizeCategory == nil else { return }
            view.rebuild?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Content

    /// A block from a splitter.
    ///
    /// With a reveal, the text shows as far as it's got. The same block again, as it streams,
    /// replaces only what changed at its end.
    public func configure(_ block: MarkdownStreamBlock, style: MarkdownStyle, reveal: MarkdownReveal? = nil) {
        rebuild = { [weak self] in self?.apply(block, style: style, reveal: reveal) }
        apply(block, style: style, reveal: reveal)
    }

    /// A reveal coming to or leaving what shows, with no relayout: nil shows all of it.
    public func setReveal(_ reveal: MarkdownReveal?) {
        self.reveal = reveal
        switch layout {
        case .text(let host, _): host.setReveal(reveal)
        case .quote(let quote): quote.setReveal(reveal)
        case .footnotes(let hosts): hosts.forEach { $0.setReveal(reveal) }
        case .math: mathGate.follow(reveal?.manager)
        case .empty, .pending: break
        }
    }

    /// Whether this renderer draws all of a block. No for what isn't ported yet, and for text
    /// holding what isn't: a host shows those another way.
    /// `drawsInlineImages`: the style has an `inlineImage`.
    public nonisolated static func draws(_ block: MarkdownStreamBlock, drawsInlineImages: Bool = false) -> Bool {
        let source = block.descriptor.sourceText
        func holdsUnported() -> Bool {
            source.contains("```") || source.contains("~~~")
                || (!drawsInlineImages && source.contains("!["))
        }
        switch block.descriptor.kind {
        case .heading, .paragraph, .orderedList, .unorderedList:
            return !holdsUnported()
        case .blockQuote:
            return !holdsUnported() && !source.contains("|")
        case .codeBlock, .table, .mathBlock, .thematicBreak, .htmlBlock, .blockDirective, .unknown:
            return false
        }
    }

    /// A whole text in one text view, as a document's text block is.
    public func configure(markdown: String, style: MarkdownStyle) {
        rebuild = { [weak self] in self?.apply(markdown: markdown, style: style) }
        apply(markdown: markdown, style: style)
    }

    /// Text drawn as a quote by its host, not by its markdown.
    public func configureAsQuote(markdown: String, style: MarkdownStyle) {
        rebuild = { [weak self] in self?.applyAsQuote(markdown: markdown, style: style) }
        applyAsQuote(markdown: markdown, style: style)
    }

    /// Lets the text views go back to the pool.
    public func prepareForReuse() {
        clear()
        rebuild = nil
    }

    private func clear() {
        switch layout {
        case .empty, .pending: break
        case .text(let host, _): host.release()
        case .quote(let quote):
            quote.releaseText()
            quote.removeFromSuperview()
        case .footnotes(let hosts): hosts.forEach { $0.release() }
        case .math(let view):
            mathGate.stop()
            view.removeFromSuperview()
        }
        layout = .empty
        shownBlockID = nil
        reveal = nil
        cachedHeight = nil
        setNeedsLayout()
    }

    private func resolved(_ style: MarkdownStyle) -> MarkdownStyle {
        var style = style
        if style.contentSizeCategory == nil, traitCollection.preferredContentSizeCategory != .unspecified {
            style.contentSizeCategory = traitCollection.preferredContentSizeCategory
        }
        return style
    }

    private func apply(_ block: MarkdownStreamBlock, style given: MarkdownStyle, reveal: MarkdownReveal? = nil) {
        // The same block keeps a text view or a quote: its text grows in place.
        let growing = shownBlockID == block.id && Self.keepsView(layout, for: block.descriptor)
        if !growing { clear() }
        cachedHeight = nil
        shownBlockID = block.id
        self.reveal = reveal
        let style = resolved(given)
        self.style = given
        semanticContentAttribute = style.layoutDirection == .rightToLeft ? .forceRightToLeft : .unspecified
        let descriptor = block.descriptor
        let source = descriptor.sourceText
        let depth = descriptor.listItemContext?.depth ?? 0
        switch descriptor.kind {
        case .blockQuote:
            let quote: MarkdownQuoteView
            if case .quote(let shown) = layout {
                quote = shown
            } else {
                quote = MarkdownQuoteView()
                addSubview(quote)
            }
            quote.configure(source: source, style: style, inlineMath: block.inlineMathStorage, displayMath: block.displayMathStorage, reveal: reveal)
            layout = .quote(quote)
        case .paragraph:
            // A paragraph starting with a footnote definition draws a line per definition:
            // cmark joins adjacent definition lines into one paragraph.
            if let lines = Self.footnoteDefinitionLines(source) {
                layout = .footnotes(makeFootnotes(lines: lines, style: style, reveal: reveal))
            } else if Self.isOnlyImages(source), style.inlineImage == nil {
                layout = .pending(.image)
            } else {
                showText(source, depth: depth, style: style, block: block)
            }
        case .heading, .orderedList, .unorderedList:
            showText(Self.textBeforeFence(source, in: descriptor), depth: depth, style: style, block: block)
        case .blockDirective(let name) where !style.registeredDirectives.contains(name) && name != MarkdownTree.mathAttribute:
            // A directive nothing renders shows its content as markdown.
            showText(source, depth: 0, style: style, block: block)
        case .blockDirective(let name) where name == MarkdownTree.mathAttribute:
            // `@math(uuid:…)`: what the splitter took out.
            if let latex = Self.directiveFormula(source, in: block.displayMathStorage) {
                showMath(latex, style: style)
            } else {
                layout = .pending(.displayMath)
            }
        case .blockDirective:
            layout = .pending(.directive)
        case .codeBlock: layout = .pending(.code)
        case .table: layout = .pending(.table)
        case .mathBlock:
            if let latex = MathParser.standaloneDisplayMath(in: source, unescapingCommonMarkEscapes: true) {
                showMath(latex, style: style)
            } else {
                layout = .pending(.displayMath)
            }
        case .thematicBreak: layout = .pending(.rule)
        case .htmlBlock: layout = .pending(.html)
        case .unknown: layout = .pending(.other)
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func apply(markdown: String, style given: MarkdownStyle) {
        clear()
        let style = resolved(given)
        self.style = given
        semanticContentAttribute = style.layoutDirection == .rightToLeft ? .forceRightToLeft : .unspecified
        showText(markdown, depth: 0, style: style, block: nil)
    }

    private func applyAsQuote(markdown: String, style given: MarkdownStyle) {
        clear()
        let style = resolved(given)
        self.style = given
        let quote = MarkdownQuoteView()
        quote.configure(text: MarkdownTextBuilder.build(markdown: markdown, style: style.quoted), style: style)
        addSubview(quote)
        layout = .quote(quote)
        setNeedsLayout()
    }

    /// Only a text block or a quote that's still one goes on in the view it has.
    private static func keepsView(_ layout: Layout, for descriptor: MarkdownBlockDescriptor) -> Bool {
        switch (layout, descriptor.kind) {
        case (.quote, .blockQuote): true
        case (.text, .heading), (.text, .orderedList), (.text, .unorderedList):
            true
        case (.text, .paragraph):
            footnoteDefinitionLines(descriptor.sourceText) == nil && !isOnlyImages(descriptor.sourceText)
        default: false
        }
    }

    private func showMath(_ latex: String, style: MarkdownStyle) {
        let view = MarkdownDisplayMathView()
        view.onHeightChange = { [weak self] in
            self?.cachedHeight = nil
            self?.setNeedsLayout()
            self?.onHeightChange?()
        }
        view.configure(latex: latex, style: style)
        addSubview(view)
        layout = .math(view)
        mathGate.follow(reveal?.manager)
    }

    private static func directiveFormula(_ source: String, in storage: [UUID: String]?) -> String? {
        guard let storage, let start = source.range(of: "uuid:") else { return nil }
        let rest = source[start.upperBound...]
        let value = rest.prefix { $0 != ")" }.trimmingCharacters(in: .whitespaces)
        return UUID(uuidString: value).flatMap { storage[$0] }
    }

    private func showText(_ source: String, depth: Int, style: MarkdownStyle, block: MarkdownStreamBlock?) {
        let text = MarkdownTextBuilder.build(markdown: source, style: style, listDepthOffset: depth, inlineMath: block?.inlineMathStorage, displayMath: block?.displayMathStorage)
        let shown: MarkdownTextHost?
        if case .text(let host, _) = layout { shown = host } else { shown = nil }
        let host = shown ?? MarkdownTextHost(textView: !style.drawsTextUntilTouched)
        if style.addsEdgeInsets {
            host.insets = UIEdgeInsets(top: text.topEdgeInset, left: 0, bottom: text.bottomEdgeInset, right: 0)
        }
        if shown == nil {
            host.apply(text, style: style, reveal: reveal)
            addSubview(host.view)
        } else {
            host.update(text, style: style, reveal: reveal)
        }
        // A nested item re-parsed alone has depth 0: its 20 pt a level.
        layout = .text(host, leading: CGFloat(depth) * 20)
    }

    /// An item with a code fence: the text before it (marker included) is text, the fence a block
    /// not drawn yet. An item starting with one draws just its marker.
    private static func textBeforeFence(_ source: String, in descriptor: MarkdownBlockDescriptor) -> String {
        guard descriptor.listItemContext != nil, source.contains("```") || source.contains("~~~") else { return source }
        let lines = source.components(separatedBy: "\n")
        guard let fenceIndex = lines.firstIndex(where: { line in
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }), fenceIndex > 0 else {
            return lines.first.map { line in
                if let fence = line.range(of: "```") ?? line.range(of: "~~~") { return String(line[..<fence.lowerBound]) }
                return line
            } ?? source
        }
        return lines[..<fenceIndex].joined(separator: "\n")
    }

    /// A paragraph of nothing but images is a block that's not drawn yet.
    private static func isOnlyImages(_ source: String) -> Bool {
        guard source.contains("![") else { return false }
        let document = Document(parsing: source)
        guard document.childCount == 1, let paragraph = document.child(at: 0) as? Paragraph else { return false }
        var sawImage = false
        for child in paragraph.children {
            if child is Markdown.Image {
                sawImage = true
            } else if let text = child as? Markdown.Text, text.string.allSatisfy(\.isWhitespace) {
                continue
            } else if child is SoftBreak || child is LineBreak {
                continue
            } else {
                return false
            }
        }
        return sawImage
    }

    // MARK: Footnotes

    /// By definition line (a continuation joins the line before); nil unless the first is one.
    private static func footnoteDefinitionLines(_ source: String) -> [String]? {
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.first, MarkdownFootnoteIndex.definitionLine(first) != nil else { return nil }
        var groups: [String] = []
        for line in lines {
            if MarkdownFootnoteIndex.definitionLine(line) != nil {
                groups.append(line)
            } else if !groups.isEmpty {
                groups[groups.count - 1] += "\n" + line
            }
        }
        return groups.isEmpty ? nil : groups
    }

    /// A line each, smaller and secondary. The whole line carries the definition's URL, so a tap
    /// anywhere works; real links inside keep their own.
    private func makeFootnotes(lines: [String], style: MarkdownStyle, reveal: MarkdownReveal?) -> [MarkdownTextHost] {
        var footnoteStyle = style
        footnoteStyle.contentSizeCategory = .extraSmall
        footnoteStyle.textColor = style.textColor ?? .floo(.markdownFootnoteText)
        // Anchors are in the block's coordinates, which don't survive the split.
        footnoteStyle.inlineAnchors = []
        return lines.enumerated().map { index, line in
            var lineStyle = footnoteStyle
            lineStyle.rangeDecorations = []
            if let definition = MarkdownFootnoteIndex.definitionLine(line),
               let url = style.footnotes?.references[definition.id]?.definitionURL {
                lineStyle.rangeDecorations = [MarkdownRangeDecoration(
                    id: "fndef-\(index)-\(definition.id)",
                    plainStart: 0,
                    plainLength: max(line.count, 1),  // Clamped to the storage's end.
                    underlineColor: .clear,           // Tappable, no underline.
                    tapURL: url,
                    preservesInnerLinks: true
                )]
            }
            let host = MarkdownTextHost()
            host.apply(MarkdownTextBuilder.build(markdown: line, style: lineStyle), style: lineStyle, reveal: reveal)
            addSubview(host.textView)
            return host
        }
    }

    private static let footnoteSpacing: CGFloat = 8
    private static let footnotePadding: CGFloat = 5

    // MARK: Size

    /// The height at `width`, the same on or off a window.
    public func height(forWidth width: CGFloat) -> CGFloat {
        if let cachedHeight, cachedHeight.width == width { return cachedHeight.height }
        let height: CGFloat
        switch layout {
        case .empty, .pending:
            height = 0
        case .text(let host, let leading):
            height = host.height(forWidth: width - leading)
        case .quote(let quote):
            height = quote.height(forWidth: width)
        case .math(let view):
            height = view.height(forWidth: width)
        case .footnotes(let hosts):
            let lines = hosts.reduce(0) { $0 + $1.height(forWidth: width) }
            height = lines + CGFloat(max(0, hosts.count - 1)) * Self.footnoteSpacing + Self.footnotePadding * 2
        }
        cachedHeight = (width, height)
        return height
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: height(forWidth: size.width))
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = style.layoutDirection == .rightToLeft
        switch layout {
        case .empty, .pending:
            break
        case .text(let host, let leading):
            let rect = isRTL
                ? CGRect(x: 0, y: 0, width: bounds.width - leading, height: bounds.height)
                : CGRect(x: leading, y: 0, width: bounds.width - leading, height: bounds.height)
            host.layout(in: rect, isRightToLeft: isRTL)
        case .quote(let quote):
            quote.frame = bounds
        case .math(let view):
            view.frame = bounds
        case .footnotes(let hosts):
            var y = Self.footnotePadding
            for host in hosts {
                host.layout(in: CGRect(x: 0, y: y, width: bounds.width, height: 0), isRightToLeft: isRTL)
                y += host.height(forWidth: bounds.width) + Self.footnoteSpacing
            }
        }
    }
}
