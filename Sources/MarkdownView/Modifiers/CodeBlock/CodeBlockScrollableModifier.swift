//
//  CodeBlockScrollableModifier.swift
//  MarkdownView
//
//  Created by OpenAI on 2026/6/6.
//

import SwiftUI

extension View {
    /// Enables horizontal scrolling for markdown code blocks.
    nonisolated public func markdownCodeBlockScrollable(_ scrollable: Bool = true) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.codeBlock.scrollable = scrollable
        }
    }
}
