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

/// 在查找时禁用的自定义 renderer 语言(小写):命中即跳过自定义渲染,fence 落回标准
/// 代码块路径。与清空注册表不同,它不受子树内的重新注册影响 —— 导出树在根上设置一次
/// 即可让 mermaid/echarts 等按原生代码块显示(异步/WebView 渲染在离屏导出里出不来)。
struct CodeBlockRendererDisabledLanguagesKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    package var codeBlockContentRenderers: [String: AnyCodeBlockContentRenderer] {
        get { self[CodeBlockContentRenderersKey.self] }
        set { self[CodeBlockContentRenderersKey.self] = newValue }
    }

    package var codeBlockRendererDisabledLanguages: Set<String> {
        get { self[CodeBlockRendererDisabledLanguagesKey.self] }
        set { self[CodeBlockRendererDisabledLanguagesKey.self] = newValue }
    }
}
