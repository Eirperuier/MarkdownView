//
//  CodeBlockContentRenderer.swift
//  MarkdownView
//

import SwiftUI

/// A custom renderer for fenced code blocks of specific languages.
///
/// When a renderer is registered for a language via
/// `.codeBlockRenderer(forLanguage:_:)`, the default code block style
/// embeds the rendered view inside its existing chrome (background,
/// border, language label) and adds a segmented Picker in the header
/// to toggle between the rendered preview and the raw code.
@preconcurrency
@MainActor
public protocol CodeBlockContentRenderer: Sendable {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(code: String, language: String?) -> Body
}

// MARK: - Type Erasure

public struct AnyCodeBlockContentRenderer: Sendable {
    /// When `true`, the host bypasses the default code block chrome
    /// (background, border, header bar, mode picker) and renders the
    /// custom view directly. The streaming reveal fade still applies.
    let bare: Bool
    private let _makeBody: @MainActor @Sendable (String, String?) -> AnyView

    public init<R: CodeBlockContentRenderer>(_ renderer: R, bare: Bool = false) {
        self.bare = bare
        self._makeBody = { code, language in
            AnyView(renderer.makeBody(code: code, language: language))
        }
    }

    init(bare: Bool = false, _ build: @escaping @MainActor @Sendable (String, String?) -> AnyView) {
        self.bare = bare
        self._makeBody = build
    }

    @MainActor
    func makeBody(code: String, language: String?) -> AnyView {
        _makeBody(code, language)
    }
}

// MARK: - Environment

struct CodeBlockContentRenderersKey: EnvironmentKey {
    static let defaultValue: [String: AnyCodeBlockContentRenderer] = [:]
}

extension EnvironmentValues {
    package var codeBlockContentRenderers: [String: AnyCodeBlockContentRenderer] {
        get { self[CodeBlockContentRenderersKey.self] }
        set { self[CodeBlockContentRenderersKey.self] = newValue }
    }
}
