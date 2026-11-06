//
//  MarkdownTypography.swift
//  MarkdownUIKit
//
//  The text's fonts, as text styles and weights; each resolves at a content size category,
//  so a heading and a paragraph follow Dynamic Type together.
//

import UIKit

/// The fonts Markdown sets its text in. `standard` is the look of MarkdownView's selectable text.
public struct MarkdownTypography: Hashable, Sendable {
    public struct Style: Hashable, Sendable {
        public var textStyle: UIFont.TextStyle
        public var weight: UIFont.Weight
        /// The text style's own line height: iOS's body font keeps its leading (17 pt on a
        /// 22 pt line). False: the font's alone, the line a plain system font gives it.
        public var keepsTextStyleLeading = true
        /// The system font's design (serif, rounded, monospaced); nil, the default.
        public var design: UIFontDescriptor.SystemDesign?

        public init(_ textStyle: UIFont.TextStyle, weight: UIFont.Weight = .regular) {
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
    /// Bold text's weight, at least (a heavier font, a heading's, keeps its own). Bold by
    /// default: the system font's bold trait gives semibold, too close to the text around it
    /// (the CJK face has bold and heavier weights too).
    public var strongWeight: UIFont.Weight
    /// How paragraphs set their lines; natural by default.
    public var paragraphAlignment: NSTextAlignment = .natural

    public init(body: Style, headings: [Style], inlineCode: Style? = nil, strongWeight: UIFont.Weight = .bold) {
        self.body = body
        self.headings = headings
        self.inlineCode = inlineCode
        self.strongWeight = strongWeight
    }

    /// Body text; headings from title 1 to headline, heavy to medium.
    public static let standard = MarkdownTypography(
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

extension MarkdownTypography.Style {
    /// The style's font at `category`, else at the system's setting. Regular weight keeps the
    /// preferred font itself, unless it's not to keep the text style's leading.
    func font(at category: UIContentSizeCategory?, monospaced: Bool = false) -> UIFont {
        let font = plainFont(at: category, monospaced: monospaced)
        guard !monospaced, let design else { return font }
        return font.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
    }

    private func plainFont(at category: UIContentSizeCategory?, monospaced: Bool) -> UIFont {
        let traits = category.map { UITraitCollection(preferredContentSizeCategory: $0) }
        let preferred = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        if monospaced { return .monospacedSystemFont(ofSize: preferred.pointSize, weight: weight) }
        guard weight == .regular, keepsTextStyleLeading else { return .systemFont(ofSize: preferred.pointSize, weight: weight) }
        return preferred
    }
}
