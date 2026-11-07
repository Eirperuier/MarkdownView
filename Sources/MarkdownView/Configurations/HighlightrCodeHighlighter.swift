//
//  HighlightrCodeHighlighter.swift
//  MarkdownView
//
//  The Highlightr-based highlighter MarkdownView ships: inject it with
//  `.codeHighlighter(HighlightrCodeHighlighter())`. Colours only — the code block's
//  own font stays.
//

import MarkdownCore
import SwiftUI

public struct HighlightrCodeHighlighter: CodeHighlighter {
    private let theme: CodeHighlighterTheme

    public init(theme: CodeHighlighterTheme = .init(lightModeThemeName: "xcode", darkModeThemeName: "atom-one-dark")) {
        self.theme = theme
    }

    public func highlight(code: String, language: String?, colorScheme: ColorScheme, lineLimit: Int?) async throws -> AttributedString? {
        let themeName = theme.themeName(for: colorScheme)
        if let cached = MarkdownHighlightCache.shared.code(code, language: language, theme: themeName) {
            return Self.attributed(cached, lineLimit: lineLimit)
        }
        guard let colored = await MarkdownHighlightEngine.shared.colored(code, language: language, theme: themeName) else { return nil }
        MarkdownHighlightCache.shared.store(colored, language: language, theme: themeName)
        return Self.attributed(colored, lineLimit: lineLimit)
    }

    public func cachedHighlight(code: String, language: String?, colorScheme: ColorScheme, lineLimit: Int?) -> AttributedString? {
        MarkdownHighlightCache.shared.code(code, language: language, theme: theme.themeName(for: colorScheme)).flatMap { Self.attributed($0, lineLimit: lineLimit) }
    }

    /// The colours for `code` now, on the main thread: from the cache, else highlighted
    /// here and then (an editor showing code it hasn't coloured yet, which mustn't show
    /// a frame of plain text).
    @MainActor
    public func foregroundColorsNow(code: String, language: String?, colorScheme: ColorScheme) -> [(NSRange, UIColor)]? {
        let themeName = theme.themeName(for: colorScheme)
        if let cached = MarkdownHighlightCache.shared.code(code, language: language, theme: themeName) {
            return cached.runs.map { ($0.range, $0.uiColor) }
        }
        guard let colored = MarkdownMainHighlightEngine.shared.colored(code, language: language, theme: themeName), colored.string == code else { return nil }
        MarkdownHighlightCache.shared.store(colored, language: language, theme: themeName)
        return colored.runs.map { ($0.range, $0.uiColor) }
    }

    /// The first `lineLimit` lines (all with nil), coloured.
    private static func attributed(_ colored: MarkdownHighlightedCode, lineLimit: Int?) -> AttributedString? {
        let attributed = NSMutableAttributedString(string: colored.string)
        for run in colored.runs where NSMaxRange(run.range) <= attributed.length {
            attributed.addAttribute(.foregroundColor, value: run.uiColor, range: run.range)
        }
        if let lineLimit {
            let text = colored.string as NSString
            var end = 0
            var lines = 0
            while end < text.length, lines < lineLimit {
                end = NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0)))
                lines += 1
            }
            var cut = end
            if cut > 0, cut <= text.length, text.character(at: cut - 1) == 0x0A, lines == lineLimit { cut -= 1 }
            return try? AttributedString(attributed.attributedSubstring(from: NSRange(location: 0, length: cut)), including: \.uiKit)
        }
        return try? AttributedString(attributed, including: \.uiKit)
    }

    /// The same highlighting as foreground colours over `code`, for an editor's storage
    /// (nil when the language isn't known or the text came back different).
    public func foregroundColors(code: String, language: String?, colorScheme: ColorScheme) async -> [(NSRange, UIColor)]? {
        let themeName = theme.themeName(for: colorScheme)
        if let cached = MarkdownHighlightCache.shared.code(code, language: language, theme: themeName) {
            return cached.runs.map { ($0.range, $0.uiColor) }
        }
        guard let colored = await MarkdownHighlightEngine.shared.colored(code, language: language, theme: themeName),
              colored.string == code
        else { return nil }
        MarkdownHighlightCache.shared.store(colored, language: language, theme: themeName)
        return colored.runs.map { ($0.range, $0.uiColor) }
    }
}

private extension MarkdownCodeColorRun {
    var uiColor: UIColor { UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha) }
}
