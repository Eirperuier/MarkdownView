//
//  CodeBlockModifier.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/2/9.
//

import SwiftUI

extension View {
    /// Sets the style of code block within a MarkdownView.
    nonisolated public func codeBlockStyle(_ style: some CodeBlockStyle) -> some View {
        environment(\.codeBlockStyle, style)
    }

    /// Sets the theme of the code highlighter.
    @available(*, deprecated, message: "Highlightr is no longer used. Inject a CodeHighlighter via `.codeHighlighter(_:)` instead.")
    nonisolated public func codeHighlighterTheme(_ theme: CodeHighlighterTheme) -> some View {
        self
    }

    /// Registers a custom view-builder for fenced code blocks of the given language.
    ///
    /// By default the rendered content is embedded inside the existing code block
    /// chrome (background, border, language label) with a segmented Picker
    /// (`Preview` / `Code`) in the header to switch between the preview and the
    /// raw code. Lookup is case-insensitive. Languages without a registered
    /// renderer fall through to the standard code block path.
    ///
    /// - Parameters:
    ///   - language: Language identifier as it appears after the opening fence
    ///     (e.g. `"svg"`). Matched case-insensitively.
    ///   - bare: When `true`, the chrome is skipped entirely and the custom view
    ///     is rendered standalone (the streaming reveal fade still applies). The
    ///     `Preview`/`Code` toggle is unavailable in bare mode. Default `false`.
    ///   - content: View-builder receiving the fenced body and original language tag.
    nonisolated public func codeBlockRenderer<Content: View>(
        forLanguage language: String,
        bare: Bool = false,
        @ViewBuilder content: @escaping @MainActor @Sendable (_ code: String, _ language: String?) -> Content
    ) -> some View {
        let key = language.lowercased()
        let erased = AnyCodeBlockContentRenderer(bare: bare) { code, lang in
            AnyView(content(code, lang))
        }
        return transformEnvironment(\.codeBlockContentRenderers) { dict in
            dict[key] = erased
        }
    }
}
