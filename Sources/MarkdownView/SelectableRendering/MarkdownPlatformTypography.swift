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
        /// Times the text style's size (an app whose text reads larger than the system's).
        public var scale: CGFloat

        public init(_ textStyle: PlatformFont.TextStyle, weight: PlatformFont.Weight = .regular, scale: CGFloat = 1) {
            self.textStyle = textStyle
            self.weight = weight
            self.scale = scale
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

    public init(body: Style, headings: [Style], inlineCode: Style? = nil, tableBody: Style? = nil) {
        self.body = body
        self.headings = headings
        self.inlineCode = inlineCode
        self.tableBody = tableBody
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

    func heading(_ level: Int) -> Style {
        guard !headings.isEmpty else { return body }
        return headings[min(max(level, 1), headings.count) - 1]
    }
}

extension MarkdownPlatformTypography.Style {
    /// The style's font at `dynamicTypeSize`, else at the system's setting. Regular weight keeps
    /// the preferred font itself.
    func font(at dynamicTypeSize: DynamicTypeSize?, monospaced: Bool = false) -> PlatformFont {
        #if canImport(UIKit)
        let traits = dynamicTypeSize.map { UITraitCollection(preferredContentSizeCategory: $0.uiContentSizeCategory) }
        let preferred = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        let size = preferred.pointSize * scale
        if monospaced { return .monospacedSystemFont(ofSize: size, weight: weight) }
        guard weight == .regular else { return .systemFont(ofSize: size, weight: weight) }
        return scale == 1 ? preferred : preferred.withSize(size)
        #else
        let preferred = NSFont.preferredFont(forTextStyle: textStyle)
        let size = preferred.pointSize * scale
        if monospaced { return .monospacedSystemFont(ofSize: size, weight: weight) }
        guard weight == .regular else { return .systemFont(ofSize: size, weight: weight) }
        return scale == 1 ? preferred : NSFont(descriptor: preferred.fontDescriptor, size: size) ?? preferred
        #endif
    }
}

extension EnvironmentValues {
    /// The selectable text path's fonts (default `standard`).
    @Entry public var markdownPlatformTypography = MarkdownPlatformTypography.standard
    /// Whether a stream block adds the vertical padding a whole document gives it at its edges
    /// (a heading's padding, a paragraph's 5 pt). Turn it off where the app spaces blocks itself.
    @Entry public var markdownStreamBlockEdgeInsets = true
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
}
#endif
