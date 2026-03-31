//
//  CodeHighlighter.swift
//  MarkdownView
//
//  Abstraction for syntax highlighting engines.
//  The main app can inject a Tree-sitter (or other) implementation;
//  MarkdownView ships a lightweight Highlightr-based default.
//

import SwiftUI

/// Abstracts a syntax-highlighting engine so that the concrete
/// implementation (Highlightr, Tree-sitter, …) lives outside the package.
public protocol CodeHighlighter: Sendable {
    /// Highlight source code and return an ``AttributedString``.
    ///
    /// - Parameters:
    ///   - code:        Full source code of the block.
    ///   - language:    Optional language identifier (e.g. "swift").
    ///   - colorScheme: Current UI color scheme for theme selection.
    ///   - lineLimit:   When non-nil, only build highlighted output for
    ///                  the first *lineLimit* lines.  Implementations are
    ///                  free to parse the full code for context accuracy
    ///                  but should limit the returned AttributedString.
    /// - Returns: Highlighted attributed string, or `nil` to fall back
    ///            to plain-text rendering.
    func highlight(
        code: String,
        language: String?,
        colorScheme: ColorScheme,
        lineLimit: Int?
    ) async throws -> AttributedString?
}

// MARK: - Environment plumbing

/// Box that erases the concrete ``CodeHighlighter`` so it can live
/// inside SwiftUI's `EnvironmentValues` (which requires `Sendable`).
public final class AnyCodeHighlighter: @unchecked Sendable {
    public let wrapped: any CodeHighlighter

    public init(_ highlighter: any CodeHighlighter) {
        self.wrapped = highlighter
    }
}

private struct CodeHighlighterKey: EnvironmentKey {
    static let defaultValue: AnyCodeHighlighter? = nil
}

extension EnvironmentValues {
    /// The injected syntax highlighter.  When `nil`, code blocks are
    /// rendered as plain text without syntax highlighting.
    public var codeHighlighter: AnyCodeHighlighter? {
        get { self[CodeHighlighterKey.self] }
        set { self[CodeHighlighterKey.self] = newValue }
    }
}

extension View {
    /// Injects a custom ``CodeHighlighter`` into the environment so
    /// that all ``MarkdownView`` code blocks use it.
    public func codeHighlighter(_ highlighter: some CodeHighlighter) -> some View {
        environment(\.codeHighlighter, AnyCodeHighlighter(highlighter))
    }
}
