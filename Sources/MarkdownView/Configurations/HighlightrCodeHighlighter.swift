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
        let themeName = theme.themeName(for: colorScheme)
        if let cached = HighlightCache.shared.code(code, language: language, theme: themeName) {
            return Self.attributed(cached, lineLimit: lineLimit)
        }
        guard let colored = await HighlightrEngine.shared.colored(code, language: language, theme: themeName) else { return nil }
        HighlightCache.shared.store(colored, language: language, theme: themeName)
        return Self.attributed(colored, lineLimit: lineLimit)
    }

    public func cachedHighlight(code: String, language: String?, colorScheme: ColorScheme, lineLimit: Int?) -> AttributedString? {
        HighlightCache.shared.code(code, language: language, theme: theme.themeName(for: colorScheme)).flatMap { Self.attributed($0, lineLimit: lineLimit) }
    }

    /// The colours for `code` now, on the main thread: from the cache, else highlighted
    /// here and then (an editor showing code it hasn't coloured yet, which mustn't show
    /// a frame of plain text).
    @MainActor
    public func foregroundColorsNow(code: String, language: String?, colorScheme: ColorScheme) -> [(NSRange, UIColor)]? {
        let themeName = theme.themeName(for: colorScheme)
        if let cached = HighlightCache.shared.code(code, language: language, theme: themeName) {
            return cached.runs.map { ($0.range, $0.color) }
        }
        guard let colored = MainHighlightr.shared.colored(code, language: language, theme: themeName), colored.string == code else { return nil }
        HighlightCache.shared.store(colored, language: language, theme: themeName)
        return colored.runs.map { ($0.range, $0.color) }
    }

    /// The first `lineLimit` lines (all with nil), coloured.
    private static func attributed(_ colored: HighlightedCode, lineLimit: Int?) -> AttributedString? {
        let attributed = NSMutableAttributedString(string: colored.string)
        for run in colored.runs where NSMaxRange(run.range) <= attributed.length {
            attributed.addAttribute(.foregroundColor, value: run.color, range: run.range)
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
        if let cached = HighlightCache.shared.code(code, language: language, theme: themeName) {
            return cached.runs.map { ($0.range, $0.color) }
        }
        guard let colored = await HighlightrEngine.shared.colored(code, language: language, theme: themeName),
              colored.string == code
        else { return nil }
        HighlightCache.shared.store(colored, language: language, theme: themeName)
        return colored.runs.map { ($0.range, $0.color) }
    }
}

/// The latest highlights by code, language and theme, shared by the read code block and
/// its editor (so a switch between them draws coloured at once).
final class HighlightCache: @unchecked Sendable {
    static let shared = HighlightCache()

    private struct Key: Hashable {
        var code: String
        var language: String
        var theme: String
    }

    private let lock = NSLock()
    private var entries: [Key: HighlightedCode] = [:]

    func code(_ code: String, language: String?, theme: String) -> HighlightedCode? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(code: code, language: language?.lowercased() ?? "", theme: theme)]
    }

    func store(_ colored: HighlightedCode, language: String?, theme: String) {
        lock.lock()
        defer { lock.unlock() }
        // An editor stores every version typed: keep the cache small.
        if entries.count > 256 { entries.removeAll(keepingCapacity: true) }
        entries[Key(code: colored.string, language: language?.lowercased() ?? "", theme: theme)] = colored
    }
}

/// Highlighted code: its text and its colour runs.
struct HighlightedCode: @unchecked Sendable {
    var string: String
    var runs: [(range: NSRange, color: UIColor)]
}

/// Highlightr runs highlight.js in a JavaScript context, which is not thread-safe: one
/// engine per thread of use — this actor off the main thread, `MainHighlightr` on it.
actor HighlightrEngine {
    static let shared = HighlightrEngine()
    private var engine = HighlightrInstance()

    func colored(_ code: String, language: String?, theme: String) -> HighlightedCode? {
        engine.colored(code, language: language, theme: theme)
    }
}

@MainActor
final class MainHighlightr {
    static let shared = MainHighlightr()
    private var engine = HighlightrInstance()

    func colored(_ code: String, language: String?, theme: String) -> HighlightedCode? {
        engine.colored(code, language: language, theme: theme)
    }
}

struct HighlightrInstance {
    #if canImport(Highlightr)
    private var highlightr: Highlightr?
    private var themeName: String?
    private var languages: Set<String> = []
    #endif

    /// `code` with the theme's colours and no fonts; nil for an unknown language.
    mutating func colored(_ code: String, language: String?, theme: String) -> HighlightedCode? {
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
