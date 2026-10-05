//
//  HighlightrCodeHighlighter.swift
//  MarkdownView
//
//  The Highlightr-based highlighter MarkdownView ships: inject it with
//  `.codeHighlighter(HighlightrCodeHighlighter())`. Colours only — the code block's
//  own font stays.
//

import SwiftUI
#if canImport(Highlightr)
import Highlightr
#endif

public struct HighlightrCodeHighlighter: CodeHighlighter {
    private let theme: CodeHighlighterTheme

    public init(theme: CodeHighlighterTheme = .init(lightModeThemeName: "xcode", darkModeThemeName: "atom-one-dark")) {
        self.theme = theme
    }

    public func highlight(code: String, language: String?, colorScheme: ColorScheme, lineLimit: Int?) async throws -> AttributedString? {
        let source: String
        if let lineLimit {
            source = code.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineLimit).joined(separator: "\n")
        } else {
            source = code
        }
        guard let colored = await HighlightrEngine.shared.colored(source, language: language, theme: theme.themeName(for: colorScheme)) else { return nil }
        let attributed = NSMutableAttributedString(string: colored.string)
        for run in colored.runs { attributed.addAttribute(.foregroundColor, value: run.color, range: run.range) }
        return try? AttributedString(attributed, including: \.uiKit)
    }

    /// The same highlighting as foreground colours over `code`, for an editor's storage
    /// (nil when the language isn't known or the text came back different).
    public func foregroundColors(code: String, language: String?, colorScheme: ColorScheme) async -> [(NSRange, UIColor)]? {
        guard let colored = await HighlightrEngine.shared.colored(code, language: language, theme: theme.themeName(for: colorScheme)),
              colored.string == code
        else { return nil }
        return colored.runs.map { ($0.range, $0.color) }
    }
}

/// Highlighted code: its text and its colour runs.
struct HighlightedCode: @unchecked Sendable {
    var string: String
    var runs: [(range: NSRange, color: UIColor)]
}

/// Highlightr runs highlight.js in a JavaScript context, which is not thread-safe: one
/// engine, used one call at a time.
actor HighlightrEngine {
    static let shared = HighlightrEngine()

    #if canImport(Highlightr)
    private var highlightr: Highlightr?
    private var themeName: String?
    private var languages: Set<String> = []
    #endif

    /// `code` with the theme's colours and no fonts; nil for an unknown language.
    func colored(_ code: String, language: String?, theme: String) -> HighlightedCode? {
        #if canImport(Highlightr)
        if highlightr == nil {
            highlightr = Highlightr()
            languages = Set(highlightr?.supportedLanguages() ?? [])
        }
        guard let highlightr, let language = language?.lowercased(), languages.contains(Self.alias(language)) else { return nil }
        if themeName != theme {
            highlightr.setTheme(to: theme)
            themeName = theme
        }
        guard let result = highlightr.highlight(code, as: Self.alias(language), fastRender: true) else { return nil }
        var runs: [(range: NSRange, color: UIColor)] = []
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let color = value as? UIColor { runs.append((range, color)) }
        }
        return HighlightedCode(string: result.string, runs: runs)
        #else
        return nil
        #endif
    }

    /// Fence names highlight.js knows by another name.
    private static func alias(_ language: String) -> String {
        switch language {
        case "js": "javascript"
        case "ts": "typescript"
        case "sh", "shell", "zsh": "bash"
        case "py": "python"
        case "kt": "kotlin"
        case "c++": "cpp"
        case "md": "markdown"
        case "yml": "yaml"
        case "objc", "objective-c": "objectivec"
        default: language
        }
    }
}
