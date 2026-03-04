//
//  _MarkdownText.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/10/20.
//

import SwiftUI

/// A view that displays parsed HTML asynchronously.
///
/// Convert HTML into  `AttributedString` asynchronously to avoid `AttributeGraph` crash.
struct _MarkdownText: View {
    
    
    var text: AttributedString
    @State private var attributedString: AttributedString?
    @Environment(\.markdownRendererConfiguration) private var configuration
    init(_ text: AttributedString) {
        self.text = text
        
    }
    
    var body: some View {
        Group {
            if let attributedString {
                Text(attributedString)
            } else {
                Text(text)
            }
        }
        .animation(.linear(duration: 0.2), value: attributedString)
        .task(id: text) {
            var attributedString = text
            for run in text.runs.reversed() where (run.isHTML ?? false) {
                let range = run.range
                let originalHTML = String(text.characters[range])
                
                if let htmlAttrString = try? AttributedString(
                    NSAttributedString(
                        data: Data(originalHTML.utf8),
                        options: [
                            .documentType: NSAttributedString.DocumentType.html
                        ],
                        documentAttributes: nil
                    )
                ) {
                    // 如果解析结果为空（非有效 HTML 标签），保留原始文本
                    let parsedText = String(htmlAttrString.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if parsedText.isEmpty {
                        // 非有效 HTML，显示原始文本
                        attributedString.replaceSubrange(range, with: AttributedString(originalHTML))
                    } else {
                        attributedString.replaceSubrange(range, with: htmlAttrString)
                    }
                } else {
                    // 解析失败，保留原始文本
                    attributedString.replaceSubrange(range, with: AttributedString(originalHTML))
                }
            }
            for string in configuration.highlightedStrings {
                if let range = attributedString.range(of: string) {
                    attributedString[range].font?.weight(.bold)
                    attributedString[range].backgroundColor = configuration.highlightedBackgroundColor
                    attributedString[range].foregroundColor = configuration.highlightedColor
                }
            }
            self.attributedString = attributedString
        }
    }
}
