//
//  MarkdownCodeHighlighting.swift
//  MarkdownCore
//
//  Highlightr with no view in it. Colours are values, so a renderer can make what it needs of
//  them. Highlightr runs highlight.js in a JavaScript context, which isn't thread-safe: one
//  engine per thread of use, an actor off the main thread and one on it.
//

import Foundation
#if canImport(Highlightr) && canImport(UIKit)
import Highlightr
import UIKit
#endif

/// A colour in sRGB components, as a theme names it.
public struct MarkdownCodeColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// A run of code in one colour, over UTF-16 units.
public struct MarkdownCodeColorRun: Equatable, Sendable {
    public var range: NSRange
    public var color: MarkdownCodeColor

    public init(range: NSRange, color: MarkdownCodeColor) {
        self.range = range
        self.color = color
    }
}

/// Highlighted code: its text and its colour runs.
public struct MarkdownHighlightedCode: Equatable, Sendable {
    public var string: String
    public var runs: [MarkdownCodeColorRun]

    public init(string: String, runs: [MarkdownCodeColorRun]) {
        self.string = string
        self.runs = runs
    }
}

/// The latest highlights by code, language and theme, shared by every renderer and an editor (so
/// a switch between them draws coloured at once).
public final class MarkdownHighlightCache: @unchecked Sendable {
    public static let shared = MarkdownHighlightCache()

    private struct Key: Hashable {
        var code: String
        var language: String
        var theme: String
    }

    private let lock = NSLock()
    private var entries: [Key: MarkdownHighlightedCode] = [:]

    public func code(_ code: String, language: String?, theme: String) -> MarkdownHighlightedCode? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(code: code, language: language?.lowercased() ?? "", theme: theme)]
    }

    public func store(_ colored: MarkdownHighlightedCode, language: String?, theme: String) {
        lock.lock()
        defer { lock.unlock() }
        // An editor stores every version typed: keep the cache small.
        if entries.count > 256 { entries.removeAll(keepingCapacity: true) }
        entries[Key(code: colored.string, language: language?.lowercased() ?? "", theme: theme)] = colored
    }
}

/// The engine off the main thread.
public actor MarkdownHighlightEngine {
    public static let shared = MarkdownHighlightEngine()
    private var engine = MarkdownHighlightInstance()

    public func colored(_ code: String, language: String?, theme: String) -> MarkdownHighlightedCode? {
        engine.colored(code, language: language, theme: theme)
    }
}

/// The engine on the main thread: an editor showing code it hasn't coloured yet, which mustn't
/// show a frame of plain text.
@MainActor
public final class MarkdownMainHighlightEngine {
    public static let shared = MarkdownMainHighlightEngine()
    private var engine = MarkdownHighlightInstance()

    public func colored(_ code: String, language: String?, theme: String) -> MarkdownHighlightedCode? {
        engine.colored(code, language: language, theme: theme)
    }
}

struct MarkdownHighlightInstance {
    #if canImport(Highlightr) && canImport(UIKit)
    private var highlightr: Highlightr?
    private var themeName: String?
    private var languages: Set<String> = []
    #endif

    /// `code` with the theme's colours and no fonts; nil for an unknown language.
    mutating func colored(_ code: String, language: String?, theme: String) -> MarkdownHighlightedCode? {
        #if canImport(Highlightr) && canImport(UIKit)
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
        var runs: [MarkdownCodeColorRun] = []
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let color = value as? UIColor else { return }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            runs.append(MarkdownCodeColorRun(range: range, color: MarkdownCodeColor(red: red, green: green, blue: blue, alpha: alpha)))
        }
        return MarkdownHighlightedCode(string: result.string, runs: runs)
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

/// A block's colours in both of a highlighter's palettes, so going from light to dark highlights
/// nothing again.
public struct MarkdownCodeTokens: Equatable, Sendable {
    public var string: String
    public var light: [MarkdownCodeColorRun]
    public var dark: [MarkdownCodeColorRun]

    public init(string: String, light: [MarkdownCodeColorRun], dark: [MarkdownCodeColorRun]) {
        self.string = string
        self.light = light
        self.dark = dark
    }
}

/// A syntax-highlighting engine (Highlightr, Tree-sitter, …), with no view or colour scheme in it.
public protocol MarkdownCodeHighlighter: Sendable {
    /// Nil falls back to plain text.
    func tokens(code: String, language: String?) async -> MarkdownCodeTokens?
    /// What's at hand for this code, synchronously: a block shown again draws coloured at once.
    func cachedTokens(code: String, language: String?) -> MarkdownCodeTokens?
}

/// Highlightr, with MarkdownView's themes.
public struct MarkdownHighlightrHighlighter: MarkdownCodeHighlighter {
    public var lightTheme: String
    public var darkTheme: String

    public init(lightTheme: String = "xcode", darkTheme: String = "atom-one-dark") {
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
    }

    public func tokens(code: String, language: String?) async -> MarkdownCodeTokens? {
        guard let light = await colored(code, language, lightTheme), let dark = await colored(code, language, darkTheme) else { return nil }
        return MarkdownCodeTokens(string: light.string, light: light.runs, dark: dark.runs)
    }

    public func cachedTokens(code: String, language: String?) -> MarkdownCodeTokens? {
        let cache = MarkdownHighlightCache.shared
        guard let light = cache.code(code, language: language, theme: lightTheme),
              let dark = cache.code(code, language: language, theme: darkTheme) else { return nil }
        return MarkdownCodeTokens(string: light.string, light: light.runs, dark: dark.runs)
    }

    private func colored(_ code: String, _ language: String?, _ theme: String) async -> MarkdownHighlightedCode? {
        if let cached = MarkdownHighlightCache.shared.code(code, language: language, theme: theme) { return cached }
        guard let colored = await MarkdownHighlightEngine.shared.colored(code, language: language, theme: theme) else { return nil }
        MarkdownHighlightCache.shared.store(colored, language: language, theme: theme)
        return colored
    }
}
