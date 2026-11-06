//
//  MathFirstMarkdownViewRenderer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/12.
//

@_spi(MarkdownMath) import MarkdownCore
import SwiftUI
import Markdown

struct MathFirstMarkdownViewRenderer: MarkdownViewRenderer {
    func makeBody(
        content: MarkdownContent,
        configuration: MarkdownRendererConfiguration
    ) -> some View {
        var configuration = configuration
        let rawText = Self.preprocessMath(content.raw.text, into: &configuration.math)
        let _content = MarkdownContent(raw: .plainText(rawText))
        return CmarkFirstMarkdownViewRenderer()
            .makeBody(content: _content, configuration: configuration)
    }

    /// 提取 `$…$` / `$$…$$` → 占位符(block `@math(uuid:)`、inline `⸨imath:…⸩`)并把 LaTeX 存入 `math`。
    /// 可选中渲染路径(MarkdownSelectableText)复用同一套预处理,保证 math 解析与视图渲染完全一致。
    static func preprocessMath(
        _ rawText: String,
        into math: inout MarkdownRendererConfiguration.Math
    ) -> String {
        return MarkdownMathPreprocessor.preprocess(
            rawText,
            appendDisplayMath: { math.appendDisplayMath($0) },
            appendInlineMath: { math.appendInlineMath($0) }
        )
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
        // Pandoc 货币规则(同 preprocessMath):单 $ 闭合后紧跟数字 ⇒ 货币,跳过。
        let matched = rawText[math.range]
        if matched.hasPrefix("$"), !matched.hasPrefix("$$"),
           math.range.upperBound < rawText.endIndex,
           rawText[math.range.upperBound].isNumber {
            continue
        }
        let id = UUID().uuidString
        storage[id] = String(rawText[math.range])
        let placeholder = "\(MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix)\(id)\(MarkdownRendererConfiguration.Math.inlinePlaceholderSuffix)"
        rawText.replaceSubrange(math.range, with: placeholder)
    }
    return (rawText, storage)
}
