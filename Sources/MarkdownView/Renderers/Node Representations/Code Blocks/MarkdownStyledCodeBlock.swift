//
//  MarkdownStyledCodeBlock.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/3/25.
//

import SwiftUI

struct MarkdownStyledCodeBlock: View {
    var configuration: CodeBlockStyleConfiguration
    @Environment(\.codeBlockStyle) private var codeBlockStyle
    @Environment(\.codeBlockContentRenderers) private var customRenderers

    private var bareRenderer: AnyCodeBlockContentRenderer? {
        guard let lang = configuration.language?.lowercased(),
              let renderer = customRenderers[lang],
              renderer.bare else { return nil }
        return renderer
    }

    var body: some View {
        Group {
            if let renderer = bareRenderer {
                renderer.makeBody(code: configuration.code, language: configuration.language)
            } else {
                codeBlockStyle
                    .makeBody(configuration: configuration)
                    .erasedToAnyView()
            }
        }
        .streamingRevealFadeIn()
    }
}
