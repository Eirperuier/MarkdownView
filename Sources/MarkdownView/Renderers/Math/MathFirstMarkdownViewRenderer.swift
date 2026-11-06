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
        // 快速短路:所有 math 定界符都以 `$` 或 `\` 开头($ / $$ / \( / \[ / \begin{…})。
        // 两者都不含 ⇒ 不可能有公式 ⇒ 直接返回,省掉这里内部又一次整篇 parse(流式每 token 白跑一次全篇解析)。
        guard rawText.contains("$") || rawText.contains("\\") else { return rawText }
        var rawText = rawText
        let probe = MarkdownContent(raw: .plainText(rawText))
        var extractor = ParsingRangesExtractor()
        extractor.visit(probe.parse(options: probe.parseOptions(allowingBlockDirectives: true)))
        // parsableRanges 升序且基于**替换前**的字符串:占位符替换会改变长度,处理完靠前的
        // range 后,靠后的 range 索引即失效(String index out of bounds,典型内容 = 公式与
        // 代码块混排产生多个 parsable 段)。与段内 mathRepresentations.reversed() 同理,
        // 段间也必须从文档尾部往前处理,让未处理的(更靠前的)range 始终有效。
        for range in extractor.parsableRanges(in: rawText).reversed() {
            let segment = rawText[range]
            let segmentParser = MathParser(text: segment)
            for mathRep in segmentParser.mathRepresentations.reversed() {
                if !mathRep.kind.inline {
                    guard isStandaloneDisplayMath(mathRep.range, in: rawText) else { continue }
                    let mathIdentifier = math.appendDisplayMath(rawText[mathRep.range])
                    rawText.replaceSubrange(
                        mathRep.range,
                        with: "\n@math(uuid:\(mathIdentifier))\n"
                    )
                } else {
                    // Pandoc 货币规则:单 $ 行内公式的闭合 $ 后紧跟数字 ⇒ 是货币不是公式
                    // (典型 "$10/$50 每百万":两个 $ 被配成公式 "10/",吞掉定界符还让
                    // reveal 计数与 parser 侧错位,后文永远揭示不出来)。\(…\)/$$ 不受影响。
                    let matched = rawText[mathRep.range]
                    if matched.hasPrefix("$"), !matched.hasPrefix("$$"),
                       mathRep.range.upperBound < rawText.endIndex,
                       rawText[mathRep.range.upperBound].isNumber {
                        continue
                    }
                    let mathId = math.appendInlineMath(rawText[mathRep.range])
                    rawText.replaceSubrange(
                        mathRep.range,
                        with: "\(MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix)\(mathId)\(MarkdownRendererConfiguration.Math.inlinePlaceholderSuffix)"
                    )
                }
            }
        }
        return rawText
    }

    private static func isStandaloneDisplayMath(_ range: Range<String.Index>, in text: String) -> Bool {
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
