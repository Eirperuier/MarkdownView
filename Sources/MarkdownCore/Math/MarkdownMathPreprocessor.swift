//
//  MarkdownMathPreprocessor.swift
//  MarkdownCore
//
//  Takes maths out of markdown before cmark reads it: display maths becomes `@math(uuid:)`,
//  inline maths a placeholder (MarkdownInlineMathPlaceholder). Every renderer goes through
//  this, so the maths it finds is the same.
//

import Foundation
import Markdown

public enum MarkdownMathPreprocessor {
    /// Replaces the maths in `rawText`, handing each piece to the closures for its id.
    public static func preprocess(
        _ rawText: String,
        appendDisplayMath: (Substring) -> UUID,
        appendInlineMath: (Substring) -> String
    ) -> String {
        // 快速短路:所有 math 定界符都以 `$` 或 `\` 开头($ / $$ / \( / \[ / \begin{…})。
        // 两者都不含 ⇒ 不可能有公式 ⇒ 直接返回,省掉这里内部又一次整篇 parse(流式每 token 白跑一次全篇解析)。
        guard rawText.contains("$") || rawText.contains("\\") else { return rawText }
        var rawText = rawText
        let probe = MarkdownContent(rawText)
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
                    let mathIdentifier = appendDisplayMath(rawText[mathRep.range])
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
                    let mathId = appendInlineMath(rawText[mathRep.range])
                    rawText.replaceSubrange(
                        mathRep.range,
                        with: "\(MarkdownInlineMathPlaceholder.prefix)\(mathId)\(MarkdownInlineMathPlaceholder.suffix)"
                    )
                }
            }
        }
        return rawText
    }

    /// FNV-1a 64-bit → hex(仅 0-9a-f,cmark 安全;进程内确定)。同一公式恒得同 id → 占位符稳定。
    public static func inlineID(for math: some StringProtocol) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in String(math).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// 由公式内容确定地派生 128-bit UUID(两趟不同 seed 的 FNV-1a 拼成 16 字节)。
    public static func displayID(for math: some StringProtocol) -> UUID {
        let bytes = Array(String(math).utf8)
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 }
            return h
        }
        let h1 = fnv(0xcbf29ce484222325), h2 = fnv(0x84222325cbf29ce4)
        func byte(_ v: UInt64, _ i: Int) -> UInt8 { UInt8((v >> (UInt64(i) * 8)) & 0xff) }
        let u: uuid_t = (
            byte(h1, 0), byte(h1, 1), byte(h1, 2), byte(h1, 3),
            byte(h1, 4), byte(h1, 5), byte(h1, 6), byte(h1, 7),
            byte(h2, 0), byte(h2, 1), byte(h2, 2), byte(h2, 3),
            byte(h2, 4), byte(h2, 5), byte(h2, 6), byte(h2, 7)
        )
        return UUID(uuid: u)
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

    struct ParsingRangesExtractor: MarkupWalker {
        private var excludedRanges: [Range<SourceLocation>] = []

        func parsableRanges(in text: String) -> [Range<String.Index>] {
            var allowedRanges: [Range<String.Index>] = []
            let excludedRanges = self.excludedRanges.map {
                ($0.lowerBound.index(in: text)..<$0.upperBound.index(in: text))
            }

            let fullRange = text.startIndex..<text.endIndex
            let sortedExcluded = excludedRanges.sorted { $0.lowerBound < $1.lowerBound }
            var currentStart = fullRange.lowerBound

            for ex in sortedExcluded {
                if currentStart < ex.lowerBound {
                    allowedRanges.append(currentStart..<ex.lowerBound)
                }
                currentStart = ex.upperBound
            }
            if currentStart < fullRange.upperBound {
                allowedRanges.append(currentStart..<fullRange.upperBound)
            }
            return allowedRanges
        }

        mutating func defaultVisit(_ markup: any Markup) {
            descendInto(markup)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            guard let range = codeBlock.range else { return }
            self.excludedRanges.append(range)
        }
    }
}

fileprivate extension SourceLocation {
    func index(in string: String) -> String.Index {
        var idx = string.startIndex
        var currentLine = 1
        while currentLine < self.line && idx < string.endIndex {
            if string[idx] == "\n" {
                currentLine += 1
            }
            idx = string.index(after: idx)
        }
        guard let utf8LineStart = idx.samePosition(in: string.utf8) else {
            return string.endIndex
        }
        let byteOffset = self.column - 1
        let targetUtf8Index = string.utf8.index(utf8LineStart, offsetBy: byteOffset, limitedBy: string.utf8.endIndex) ?? string.utf8.endIndex
        return targetUtf8Index.samePosition(in: string) ?? string.endIndex
    }
}
