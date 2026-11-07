//
//  MarkdownStyle.swift
//  MarkdownUIKit
//
//  Everything that sets how text looks, as a value. No colour is resolved here: a nil colour
//  is the role's (`UIColor.floo(_:)`), and one set here may be dynamic.
//

import Markdown
import MarkdownCore
import RichTextCore
import UIKit

/// A list's markers.
public enum MarkdownUnorderedMarker: Equatable, Sendable {
    /// Filled at even depths, hollow at odd ones.
    case bullet
    case dash

    func marker(listDepth: Int) -> String {
        switch self {
        case .bullet: listDepth.isMultiple(of: 2) ? "•" : "◦"
        case .dash: "-"
        }
    }

    var monospaced: Bool {
        self == .bullet || self == .dash
    }
}

public enum MarkdownOrderedMarker: Equatable, Sendable {
    case digits
    case letters

    /// `index` from 0.
    func marker(at index: Int) -> String {
        switch self {
        case .digits:
            return String(index + 1) + "."
        case .letters:
            let base = 26
            func letter(_ value: Int) -> Character { Character(UnicodeScalar(UInt8(97 + value))) }
            // If index is smaller than 26, use a single letter, otherwise double letters.
            guard index >= base else { return String(letter(index)) + "." }
            let rest = index - base
            return String(letter(rest / base)) + String(letter(rest % base)) + "."
        }
    }
}

public struct MarkdownListStyle: Equatable, Sendable {
    public var leadingIndentation: CGFloat = 12
    public var unorderedMarker = MarkdownUnorderedMarker.bullet
    public var orderedMarker = MarkdownOrderedMarker.digits

    public init() {}
}

/// The room above and below a heading of each level.
public struct MarkdownHeadingPaddings: Equatable, Sendable {
    public var top: [CGFloat] = [12, 10, 8, 6, 4, 2]
    /// Half the top: a heading stands off from the section before and close to what it leads.
    public var bottom: [CGFloat] = [6, 5, 4, 3, 2, 1]

    public init() {}

    func top(_ level: Int) -> CGFloat { top[min(max(level, 1), 6) - 1] }
    func bottom(_ level: Int) -> CGFloat { bottom[min(max(level, 1), 6) - 1] }
}

/// A coloured underline on a range of plain units (a mark), drawn apart from the text.
/// Later ones in the list win on the same range.
public struct MarkdownRangeDecoration: Equatable {
    public var id: String
    public var plainStart: Int
    public var plainLength: Int
    public var underlineColor: UIColor
    /// Where a tap goes; nil isn't tappable.
    public var tapURL: URL?
    /// True: `tapURL` goes on the runs with no link yet, so real links inside keep their own.
    public var preservesInnerLinks: Bool

    public init(id: String, plainStart: Int, plainLength: Int, underlineColor: UIColor, tapURL: URL? = nil, preservesInnerLinks: Bool = false) {
        self.id = id
        self.plainStart = plainStart
        self.plainLength = plainLength
        self.underlineColor = underlineColor
        self.tapURL = tapURL
        self.preservesInnerLinks = preservesInnerLinks
    }
}

/// A small bubble at a plain offset (a topic's entry): one storage character, no plain units,
/// so reveal counts don't change.
public struct MarkdownInlineAnchor: Equatable, Sendable {
    public var id: String
    public var plainOffset: Int
    public var url: URL?

    public init(id: String, plainOffset: Int, url: URL?) {
        self.id = id
        self.plainOffset = plainOffset
        self.url = url
    }
}

/// Images an app gives for what text names: sites' icons and a chip's placeholder. Icons are
/// tinted when they're templates, as a symbol is.
public struct MarkdownIcons {
    /// A site's icon by host, or a tool chip's by its whole URL; nil while there's none.
    public var image: @MainActor (String) -> UIImage?
    /// Shown while `image` has nothing.
    public var placeholder: (@MainActor () -> UIImage?)?
    /// Asked for a host `image` has nothing for yet.
    public var prefetch: (@MainActor (String) -> Void)?

    public init(
        image: @escaping @MainActor (String) -> UIImage?,
        placeholder: (@MainActor () -> UIImage?)? = nil,
        prefetch: (@MainActor (String) -> Void)? = nil
    ) {
        self.image = image
        self.placeholder = placeholder
        self.prefetch = prefetch
    }
}

public struct MarkdownStyle {
    // Type
    public var typography = MarkdownTypography.standard
    /// Text that's only looked at is drawn in one view; the first touch or pointer on it gets a
    /// real text view. Off, it's always a text view.
    public var drawsTextUntilTouched = false
    /// The size text resolves at; nil follows the view's traits.
    public var contentSizeCategory: UIContentSizeCategory?
    /// What a run names no font of its own in: spaces from soft breaks and the newlines between
    /// blocks. Their line box counts, so it isn't always the body's. Nil: the body text style.
    public var defaultFont: UIFont?
    /// A line's extra room under its text: a nested quote's serif text sits where it would in
    /// its own line, in a line as tall as the body's.
    var roomBelowLines: CGFloat?

    /// The text style whose x-height sets an inline formula's size.
    public var inlineMathTextStyle = UIFont.TextStyle.body
    /// The same for a formula on its own, and the font of the lines around it.
    public var displayMathTextStyle = UIFont.TextStyle.body
    /// Draws a formula on its own at once. False: it comes in late unless it's cached, in the
    /// room set aside for it.
    public var rendersDisplayMathSynchronously = false

    // Layout
    /// Between a paragraph's lines.
    public var lineSpacing: CGFloat = 0
    /// Between blocks in one text.
    public var componentSpacing: CGFloat = 10
    public var headingPaddings = MarkdownHeadingPaddings()
    public var list = MarkdownListStyle()
    public var codeBlock = MarkdownCodeBlockStyle()
    /// Whether a block adds the room a whole document gives it at its edges (a heading's
    /// padding, a paragraph's 5 pt). Off where the host spaces blocks itself.
    public var addsEdgeInsets = true
    public var layoutDirection = UIUserInterfaceLayoutDirection.leftToRight

    // Colours: nil is the role's
    /// Text with no colour of its own.
    public var textColor: UIColor?
    public var linkColor: UIColor?
    public var strongColor: UIColor?
    public var inlineCodeColor: UIColor?
    public var quoteColor: UIColor?
    public var highlightFill: UIColor?
    /// Text on a highlight; nil keeps its own colour.
    public var highlightText: UIColor?
    /// A colour per heading level from 1 (MarkdownView's heading styles); nil the text's.
    public var headingColors: [Int: UIColor] = [:]

    // Text features
    /// Whether bare addresses in text become links.
    public var autolinks = true
    /// Whether a web link shows its site's icon before it.
    public var linkSiteIcons = false
    public var icons: MarkdownIcons?
    /// Footnote numbers and where they go; nil leaves `[^1]` as it's written.
    public var footnotes: MarkdownFootnotes?
    /// Whether `==highlight==` and `:circle[…]` in text are read as marks. Off for a tree:
    /// its text is text, its marks are nodes.
    public var interpretsTextSyntax = true
    public var rangeDecorations: [MarkdownRangeDecoration] = []
    public var inlineAnchors: [MarkdownInlineAnchor] = []
    /// Directives something renders, by name; any other shows its content as markdown.
    public var blockDirectives: [String: @MainActor (MarkdownDirectiveRequest) -> UIView] = [:]
    /// Where a relative image path starts. Nil shows such an image's description.
    public var baseURL: URL?
    /// Images a URL scheme draws itself, in place of loading them. The view says its size in
    /// `sizeThatFits(_:)`.
    public var imageRenderers: [String: @MainActor (MarkdownImageRequest) -> UIView] = [:]
    /// Turns a link into custom text (a local file's icon and name); nil keeps the link.
    public var inlineLinkBuilder: (@MainActor (_ destination: String, _ label: String, _ tint: UIColor) -> NSAttributedString?)?

    // Actions
    /// Links, chips, icons and bubbles open through this; nil leaves them to the system.
    public var openURL: (@MainActor (URL) -> Void)?

    // Seams for what isn't drawn here yet
    /// Draws inline maths in place of LaTeXCore.
    public var inlineMath: (@MainActor (_ latex: String, _ font: UIFont) -> RichTextAttachment)?
    /// Draws an inline image. Nil keeps no room.
    public var inlineImage: (@MainActor (_ image: Markdown.Image, _ style: MarkdownStyle) -> RichTextAttachment?)?
    /// Draws a block that isn't text inside text (a code fence in a quote). Nil keeps no room.
    public var nestedBlock: (@MainActor (_ block: any Markup, _ style: MarkdownStyle) -> RichTextAttachment?)?

    /// Inside a quote: bold text and links black and white, not the theme's colour.
    var isQuoted = false
    /// Who hears that something in this text changed size by itself.
    var lateSize: MarkdownLateSize?

    public init() {}
}

extension MarkdownStyle {
    /// The style a quote's content is drawn in.
    var quoted: MarkdownStyle {
        var style = self
        style.isQuoted = true
        style.linkColor = nil
        style.strongColor = nil
        return style
    }

    /// A name as written, or in another case.
    func blockDirective(named name: String) -> (@MainActor (MarkdownDirectiveRequest) -> UIView)? {
        blockDirectives[name] ?? blockDirectives.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    func imageRenderer(forScheme scheme: String) -> (@MainActor (MarkdownImageRequest) -> UIView)? {
        imageRenderers[scheme] ?? imageRenderers.first { $0.key.lowercased() == scheme.lowercased() }?.value
    }

    var resolvedDefaultFont: UIFont {
        defaultFont ?? UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) }
        )
    }

    /// The body text style's size: what a view with no font of its own lays out at.
    var resolvedBodyTextSize: CGFloat {
        UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) }
        ).pointSize
    }

    var resolvedTextColor: UIColor { textColor ?? .floo(.markdownText) }
    var resolvedLinkColor: UIColor { linkColor ?? (isQuoted ? .floo(.markdownQuoteEmphasis) : .floo(.markdownLink)) }
    var resolvedStrongColor: UIColor { strongColor ?? (isQuoted ? .floo(.markdownQuoteEmphasis) : .floo(.markdownStrong)) }
    var resolvedInlineCodeColor: UIColor { inlineCodeColor ?? .floo(.markdownInlineCode) }
    var resolvedInlineCodeFill: UIColor { inlineCodeColor.map { $0.markdownOpacity(0.1) } ?? .floo(.markdownInlineCodeFill) }
    var resolvedQuoteColor: UIColor { quoteColor ?? .floo(.markdownQuote) }
    var resolvedQuoteFill: UIColor { quoteColor.map { $0.markdownOpacity(0.1) } ?? .floo(.markdownQuoteFill) }
    var resolvedHighlightFill: UIColor { highlightFill ?? .floo(.markdownHighlight) }
}
