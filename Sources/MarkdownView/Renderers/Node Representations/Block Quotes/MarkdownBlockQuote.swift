//
//  MarkdownBlockQuote.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/2/22.
//

import SwiftUI
import Markdown

struct MarkdownBlockQuote: View {
    var blockQuote: BlockQuote
    @Environment(\.blockQuoteStyle) private var blockQuoteStyle
    
    var body: some View {
        // 提示块(`> [!note]`):首行标记剥掉作标题,内容只渲染其余部分。
        let callout = blockQuote.callout
        let configuration = BlockQuoteStyleConfiguration(
            content: BlockQuoteStyleConfiguration.Content(blockQuote: callout?.body ?? blockQuote),
            callout: callout?.callout
        )
        blockQuoteStyle
            .makeBody(configuration: configuration)
            .erasedToAnyView()
    }
}
