//
//  MarkdownCodeLines.swift
//  MarkdownCore
//
//  What a code block's text comes to, with no drawing in it: its lines, how many show, where
//  each starts in a reveal, and the icon for its language.
//

import Foundation

/// A code block shows this many lines unless it's set to show all of them.
public let markdownCodeLineLimit = 15

/// Between the lines a long code line wraps into: text's spacing, not packed tight
/// (lines of code themselves stay apart by their rows' padding).
public let markdownCodeWrappedLineSpacing: CGFloat = 6

/// A code block's text by lines.
public struct MarkdownCodeLines: Equatable, Sendable {
    /// By any newline; a last empty line, what the newline before a closing fence leaves, isn't one.
    public let lines: [String]

    public init(code: String) {
        var lines = code.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
    }

    public var count: Int { lines.count }

    /// How many show: all, or up to the limit.
    public func shownCount(showsAll: Bool) -> Int {
        showsAll ? count : min(count, markdownCodeLineLimit)
    }

    /// What's left under the limit.
    public func hiddenCount(showsAll: Bool) -> Int {
        count - shownCount(showsAll: showsAll)
    }

    public func shown(showsAll: Bool) -> ArraySlice<String> {
        lines.prefix(shownCount(showsAll: showsAll))
    }
}

/// Where each line of a code block starts and ends in reveal units, a unit a Character.
public struct MarkdownCodeRevealMetrics: Equatable, Sendable {
    private let starts: [Int]
    private let ends: [Int]
    private let total: Int

    public init(code: String) {
        var starts: [Int] = []
        var ends: [Int] = []
        var cursor = 0
        var index = code.startIndex
        while index < code.endIndex {
            let range = code.lineRange(for: index..<index)
            starts.append(cursor)
            cursor += code[range].count
            ends.append(cursor)
            index = range.upperBound
        }
        self.starts = starts
        self.ends = ends
        total = code.count
    }

    public func start(ofLine index: Int) -> Int {
        starts.indices.contains(index) ? starts[index] : total
    }

    public func end(afterLineCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ends.indices.contains(count - 1) ? ends[count - 1] : total
    }

    /// How many of the first `limit` lines have started by `count` units.
    public func visibleLineCount(revealed count: Int, limit: Int) -> Int {
        guard count > 0, limit > 0 else { return 0 }
        var visible = 0
        for index in 0..<min(limit, starts.count) {
            guard count > starts[index] else { break }
            visible += 1
        }
        return visible
    }
}

/// What the header shows for a language.
public enum MarkdownCodeLanguageIcon: Equatable, Sendable {
    /// An image in `MarkdownCodeAssets.bundle`.
    case asset(String)
    /// Letters on a quiet tile.
    case badge(String)

    public init(language: String) {
        switch language.lowercased() {
        case "swift": self = .asset("lang-swift")
        case "python", "py": self = .asset("lang-python")
        case "javascript", "js", "jsx": self = .asset("lang-javascript")
        case "typescript", "ts", "tsx": self = .asset("lang-typescript")
        case "go": self = .asset("lang-go")
        case "rust", "rs": self = .asset("lang-rust")
        case "c": self = .asset("lang-c")
        case "cpp", "c++", "cc", "cxx": self = .asset("lang-cpp")
        case "java": self = .asset("lang-java")
        case "bash", "sh", "shell", "zsh": self = .asset("lang-bash")
        case "html": self = .asset("lang-html")
        case "css": self = .asset("lang-css")
        case "ruby", "rb": self = .asset("lang-ruby")
        case "json", "jsonc": self = .asset("lang-json")
        default: self = .badge(String(language.prefix(2)).uppercased())
        }
    }
}

/// The package's images.
public enum MarkdownCodeAssets {
    public static var bundle: Bundle { .module }
}
