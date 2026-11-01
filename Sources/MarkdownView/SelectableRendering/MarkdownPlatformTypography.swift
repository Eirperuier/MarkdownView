//
//  MarkdownPlatformTypography.swift
//  MarkdownView
//
//  The selectable path's fonts. That path sets PlatformFonts on attributed text, where a
//  `MarkdownFontGroup`'s SwiftUI fonts can't reach, so an app names them here as text styles and
//  weights; each resolves at the environment's Dynamic Type size, as the SwiftUI path's fonts do.
//

#if canImport(RichText)
import SwiftUI
import RichText

/// The selectable text path's fonts, as text styles and weights. `standard` is the path's own
/// look; an app with its own `MarkdownFontGroup` sets the matching styles here, so headings and
/// paragraphs read the same on both paths.
public struct MarkdownPlatformTypography: Hashable, Sendable {
    public struct Style: Hashable, Sendable {
        public var textStyle: PlatformFont.TextStyle
        public var weight: PlatformFont.Weight
        /// The text style's own line height: iOS's body font keeps its leading (17 pt on a
        /// 22 pt line). False: the font's alone, the line SwiftUI's Text gives it.
        public var keepsTextStyleLeading = true
        /// The system font's design (serif, rounded, monospaced); nil, the default.
        public var design: Font.Design?

        public init(_ textStyle: PlatformFont.TextStyle, weight: PlatformFont.Weight = .regular) {
            self.textStyle = textStyle
            self.weight = weight
        }
    }

    /// Paragraphs, list items, quotes and footnotes.
    public var body: Style
    /// Heading levels from 1; levels past the end take the last.
    public var headings: [Style]
    /// Inline code, in the system's monospaced face; nil keeps it in the body font.
    public var inlineCode: Style?
    /// Table body cells once they turn selectable; nil keeps them in the body font.
    public var tableBody: Style?
    /// Bold text's weight, at least (a heavier font, a heading's, keeps its own). Bold by
    /// default, as Craft's: the system font's bold trait gives semibold, too close to the
    /// text around it (the CJK face has bold and heavier weights too).
    public var strongWeight: PlatformFont.Weight
    /// How paragraphs set their lines (a table cell's alignment); natural by default.
    public var paragraphAlignment: NSTextAlignment = .natural

    public init(body: Style, headings: [Style], inlineCode: Style? = nil, tableBody: Style? = nil,
                strongWeight: PlatformFont.Weight = .bold) {
        self.body = body
        self.headings = headings
        self.inlineCode = inlineCode
        self.tableBody = tableBody
        self.strongWeight = strongWeight
    }

    /// Body text; headings from title 1 to headline, heavy to medium.
    public static let standard = MarkdownPlatformTypography(
        body: Style(.body),
        headings: [
            Style(.title1, weight: .heavy),
            Style(.title2, weight: .bold),
            Style(.title3, weight: .semibold),
            Style(.headline, weight: .medium),
        ]
    )

    /// A table cell's: its body is the table body's, on the line SwiftUI's Text gives the
    /// cell as it reads, so a cell turned selectable or edited keeps its height.
    public var tableCell: MarkdownPlatformTypography {
        var typography = self
        typography.body = tableBody ?? body
        typography.body.keepsTextStyleLeading = false
        return typography
    }

    func heading(_ level: Int) -> Style {
        guard !headings.isEmpty else { return body }
        return headings[min(max(level, 1), headings.count) - 1]
    }
}

extension MarkdownPlatformTypography.Style {
    /// The style's font at `dynamicTypeSize`, else at the system's setting. Regular weight keeps
    /// the preferred font itself, unless it's not to keep the text style's leading.
    func font(at dynamicTypeSize: DynamicTypeSize?, monospaced: Bool = false) -> PlatformFont {
        let font = plainFont(at: dynamicTypeSize, monospaced: monospaced)
        guard !monospaced, let design = design.flatMap(Self.systemDesign) else { return font }
        #if canImport(UIKit)
        return font.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        #else
        return font.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
        #endif
    }

    #if canImport(UIKit)
    private static func systemDesign(_ design: Font.Design) -> UIFontDescriptor.SystemDesign? {
        switch design {
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        default: nil
        }
    }
    #else
    private static func systemDesign(_ design: Font.Design) -> NSFontDescriptor.SystemDesign? {
        switch design {
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        default: nil
        }
    }
    #endif

    private func plainFont(at dynamicTypeSize: DynamicTypeSize?, monospaced: Bool) -> PlatformFont {
        #if canImport(UIKit)
        let traits = dynamicTypeSize.map { UITraitCollection(preferredContentSizeCategory: $0.uiContentSizeCategory) }
        let preferred = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        if monospaced { return .monospacedSystemFont(ofSize: preferred.pointSize, weight: weight) }
        guard weight == .regular, keepsTextStyleLeading else { return .systemFont(ofSize: preferred.pointSize, weight: weight) }
        return preferred
        #else
        let preferred = NSFont.preferredFont(forTextStyle: textStyle)
        if monospaced { return .monospacedSystemFont(ofSize: preferred.pointSize, weight: weight) }
        guard weight == .regular, keepsTextStyleLeading else { return .systemFont(ofSize: preferred.pointSize, weight: weight) }
        return preferred
        #endif
    }
}

extension EnvironmentValues {
    /// The selectable text path's fonts (default `standard`).
    @Entry public var markdownPlatformTypography = MarkdownPlatformTypography.standard
    /// Whether a stream block adds the vertical padding a whole document gives it at its edges
    /// (a heading's padding, a paragraph's 5 pt). Turn it off where the app spaces blocks itself.
    @Entry public var markdownStreamBlockEdgeInsets = true
    /// Told how much of a streamed block's text is revealed so far: the size from the text's
    /// top-leading corner to the far edge and bottom of its revealed glyphs, nil once the whole
    /// block is revealed. Only selectable text with a streaming reveal reports.
    @Entry public var markdownRevealedExtent: (@MainActor (CGSize?) -> Void)? = nil
}

extension View {
    /// Sets the selectable text path's fonts for this subtree.
    nonisolated public func markdownPlatformTypography(_ typography: MarkdownPlatformTypography) -> some View {
        environment(\.markdownPlatformTypography, typography)
    }

    /// Turns a stream block's own edge padding on or off for this subtree.
    nonisolated public func markdownStreamBlockEdgeInsets(_ enabled: Bool) -> some View {
        environment(\.markdownStreamBlockEdgeInsets, enabled)
    }

    /// Tells `action` how much of each streamed block's text in this subtree is revealed so far.
    nonisolated public func markdownRevealedExtent(_ action: (@MainActor (CGSize?) -> Void)?) -> some View {
        environment(\.markdownRevealedExtent, action)
    }
}
#endif
