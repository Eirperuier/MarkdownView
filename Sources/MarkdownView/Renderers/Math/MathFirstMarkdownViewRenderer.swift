//
//  MathFirstMarkdownViewRenderer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/12.
//

import SwiftUI
import Markdown

struct MathFirstMarkdownViewRenderer: MarkdownViewRenderer {
    func makeBody(
        content: MarkdownContent,
        configuration: MarkdownRendererConfiguration
    ) -> some View {
        var configuration = configuration
        var rawText = content.raw.text
        
        var extractor = ParsingRangesExtractor()
        extractor.visit(content.parse(options: content.parseOptions(allowingBlockDirectives: true)))
        for range in extractor.parsableRanges(in: rawText) {
            let segment = rawText[range]
            let segmentParser = MathParser(text: segment)
            for math in segmentParser.mathRepresentations.reversed() {
                if !math.kind.inline {
                    guard isStandaloneDisplayMath(math.range, in: rawText) else { continue }
                    let mathIdentifier = configuration.math.appendDisplayMath(
                        rawText[math.range]
                    )
                    rawText.replaceSubrange(
                        math.range,
                        with: "\n@math(uuid:\(mathIdentifier))\n"
                    )
                } else {
                    let mathId = configuration.math.appendInlineMath(
                        rawText[math.range]
                    )
                    rawText.replaceSubrange(
                        math.range,
                        with: "\(MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix)\(mathId)\(MarkdownRendererConfiguration.Math.inlinePlaceholderSuffix)"
                    )
                }
            }
        }
        
        let _content = MarkdownContent(raw: .plainText(rawText))
        return CmarkFirstMarkdownViewRenderer()
            .makeBody(content: _content, configuration: configuration)
    }

    private func isStandaloneDisplayMath(_ range: Range<String.Index>, in text: String) -> Bool {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map {
            text.index(after: $0)
        } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex

        let prefix = text[lineStart..<range.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let suffix = text[range.upperBound..<lineEnd]
            .trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty && suffix.isEmpty
    }
}

/// Extracts inline math expressions from raw markdown text, replacing them
/// with safe placeholders that survive cmark processing. Returns the
/// modified text and a dictionary mapping placeholder IDs to the original
/// LaTeX strings. Use `markdownInlineMathStorage(_:)` to pass the
/// dictionary into the rendering environment.
public func extractInlineMath(
    from text: String
) -> (processedText: String, inlineMathStorage: [String: String]) {
    var rawText = text
    var storage: [String: String] = [:]
    let parser = MathParser(text: rawText)
    for math in parser.mathRepresentations.reversed() where math.kind.inline {
        let id = UUID().uuidString
        storage[id] = String(rawText[math.range])
        let placeholder = "\(MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix)\(id)\(MarkdownRendererConfiguration.Math.inlinePlaceholderSuffix)"
        rawText.replaceSubrange(math.range, with: placeholder)
    }
    return (rawText, storage)
}
