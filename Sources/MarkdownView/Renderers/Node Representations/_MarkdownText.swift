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
                
                if let htmlAttrString = try? AttributedString(
                    NSAttributedString(
                        data: Data(String(text.characters[range]).utf8),
                        options: [
                            .documentType: NSAttributedString.DocumentType.html
                        ],
                        documentAttributes: nil
                    )
                ) {
                    attributedString.replaceSubrange(range, with: htmlAttrString)
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
