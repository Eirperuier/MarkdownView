//
//  MarkdownBlockDirective.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/2/22.
//

import SwiftUI
import Markdown
import MarkdownCore

struct MarkdownBlockDirective: View {
    var blockDirective: BlockDirective
    @Environment(\.markdownRendererConfiguration) private var configuration
    
    var body: some View {
        if configuration.allowedBlockDirectiveRenderers.contains(blockDirective.name),
           let renderer = BlockDirectiveRenderers.named(blockDirective.name) {
            let configuration = BlockDirectiveRendererConfiguration(
                wrappedString: blockDirective.markdownWrappedString,
                arguments: blockDirective
                    .argumentText
                    .parseNameValueArguments()
                    .map { BlockDirectiveRendererConfiguration.Argument($0) }
            )
            renderer
                .makeBody(configuration: configuration)
                .erasedToAnyView()
                .streamingRevealFadeIn()
        } else {
            // 未注册/未启用的指令(典型:用户消息以 `@xxx` 开头,swift-markdown 把整段
            // 吞成 BlockDirective):descendInto 只渲染花括号体,单行 @xxx 无 children →
            // 整条消息渲染成空白。回退为按**原文**当普通 markdown 渲染(re-parse 时
            // 默认不开 directive,无递归)。
            CmarkNodeVisitor(configuration: configuration)
                .makeBody(for: Markdown.Document(parsing: blockDirective.format()))
        }
    }
}
