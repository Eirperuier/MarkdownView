//
//  MarkdownFootnotes.swift
//  MarkdownView
//
//  标准脚注(`[^id]` 引用 + `[^id]: …` 定义)与内联脚注(`^[…]`)对可选中渲染路径的支持。
//
//  swift-markdown / cmark 未启用 footnote 扩展,脚注语法在 AST 里是字面文本 ——
//  这里的策略:
//   - 标准引用/定义标记:SelectableMarkupVisitor 在 Text 节点层扫描替换成上标数字链接
//     (storage 字符数变化,但 plain 记账保持源文本字符数 → reveal / mark 坐标系不漂移);
//   - 内联脚注:render 前把 `^[…]` 预处理成占位符(同 math 管线),visitor 遇占位符换成
//     上标数字链接;plainSpan = 源 AST 的 plain 计数(`^[` + 内容 plain + `]`),与驱动方一致。
//
//  编号 / 点击 URL 由 app 注入(`markdownFootnotes(_:)`,按消息级索引算好):包层不掺 app scheme。
//

import SwiftUI
@preconcurrency import Markdown

/// app 注入的脚注上下文(按块注入;编号是消息级全局编号)。
public struct MarkdownFootnotes: Equatable, Hashable, Sendable {
    /// 标准脚注(有定义的 id 才会出现在表里;无定义的 `[^x]` 保持字面渲染)。
    public struct Reference: Equatable, Hashable, Sendable {
        /// 消息级显示编号。
        public let number: Int
        /// 引用(`[^id]`)点击 URL(app 拦截弹悬浮面板)。
        public let referenceURL: URL?
        /// 定义标记(`[^id]:`)点击 URL(app 拦截弹菜单,跳回引用位置)。
        public let definitionURL: URL?

        public init(number: Int, referenceURL: URL?, definitionURL: URL?) {
            self.number = number
            self.referenceURL = referenceURL
            self.definitionURL = definitionURL
        }
    }

    /// 本块内联脚注(按块内出现顺序,与预处理占位符的序号一一对应)。
    public struct InlineNote: Equatable, Hashable, Sendable {
        public let number: Int
        /// 点击 URL(app 拦截弹悬浮面板展示内容)。
        public let url: URL?

        public init(number: Int, url: URL?) {
            self.number = number
            self.url = url
        }
    }

    /// 标准脚注 id → 编号/URL。
    public var references: [String: Reference]
    /// 本块内联脚注(按出现顺序)。
    public var inlineNotes: [InlineNote]

    public init(references: [String: Reference] = [:], inlineNotes: [InlineNote] = []) {
        self.references = references
        self.inlineNotes = inlineNotes
    }

    public var isEmpty: Bool { references.isEmpty && inlineNotes.isEmpty }
}

extension View {
    /// 当前块的脚注上下文(按块注入;nil = 不做脚注变换)。仅可选中渲染路径消费。
    nonisolated public func markdownFootnotes(_ footnotes: MarkdownFootnotes?) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.footnotes = footnotes
        }
    }
}

// MARK: - 语法扫描 / 预处理

/// 脚注语法工具:包内(预处理/visitor)与 app(消息级索引)共用同一套扫描逻辑,
/// 保证「app 数出的内联脚注序列」与「预处理替换的占位符序列」一一对应。
public enum MarkdownFootnoteSyntax {
    /// 内联脚注占位符(与 math 占位符同风格,视觉上不可能出现在正文里)。
    static let inlinePlaceholderPrefix = "\u{2E28}fnote:"
    static let inlinePlaceholderSuffix = "\u{2E29}"

    /// 内联脚注 `^[…]` 的出现(range 含 `^[` 与收尾 `]`;content 为中括号内的原文)。
    /// 跳过反引号 code span 与 `$…$` 数学段(与 app 索引侧保持一致的近似规则)。
    public static func inlineOccurrences(in text: String) -> [(range: Range<String.Index>, content: String)] {
        var results: [(Range<String.Index>, String)] = []
        var i = text.startIndex
        var inCodeSpan = false
        var codeSpanTicks = 0
        var inMath = false
        while i < text.endIndex {
            let c = text[i]
            if c == "`" {
                var j = i
                var run = 0
                while j < text.endIndex, text[j] == "`" { run += 1; j = text.index(after: j) }
                if inCodeSpan {
                    if run == codeSpanTicks { inCodeSpan = false }
                } else {
                    inCodeSpan = true
                    codeSpanTicks = run
                }
                i = j
                continue
            }
            if inCodeSpan { i = text.index(after: i); continue }
            if c == "$" { inMath.toggle(); i = text.index(after: i); continue }
            if inMath { i = text.index(after: i); continue }
            if c == "^" {
                let bracket = text.index(after: i)
                if bracket < text.endIndex, text[bracket] == "[" {
                    if let closing = balancedClosingBracket(in: text, openingAt: bracket) {
                        let content = String(text[text.index(after: bracket)..<closing])
                        // 空内容不算脚注(`^[]` 保持字面)。
                        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            results.append((i..<text.index(after: closing), content))
                            i = text.index(after: closing)
                            continue
                        }
                    }
                }
            }
            i = text.index(after: i)
        }
        return results
    }

    /// 从 `[` 起找到配平的 `]`(支持嵌套中括号与 `\` 转义)。找不到返回 nil。
    private static func balancedClosingBracket(
        in text: String,
        openingAt start: String.Index
    ) -> String.Index? {
        var depth = 0
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 { return i }
            }
            if c == "\n", depth == 0 { return nil }
            i = text.index(after: i)
        }
        return nil
    }

    /// 上标数字("¹²³"),用真实 Unicode 上标字符 —— 无需 baselineOffset 属性,
    /// 布局/选择/复制全链路自然成立。
    public static func superscriptDigits(_ number: Int) -> String {
        let digits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        guard number > 0 else { return "†" }
        var result = ""
        for ch in String(number) {
            if let v = ch.wholeNumberValue, v >= 0, v <= 9 {
                result.append(digits[v])
            }
        }
        return result.isEmpty ? "†" : result
    }

    /// 预处理产物:占位符序号 → (内容原文, plain 单位数)。
    struct InlineToken {
        let content: String
        /// 源文本在 AST plain 坐标系里占的单位数:`^` + `[` + 内容 plain + `]`。
        /// 驱动方(reveal frontier)按未预处理的 AST 记账,这里必须与之一致。
        let plainSpan: Int
    }

    /// 把 `^[…]` 替换成 `⸨fnote:K⸩` 占位符(K = 出现顺序)。在 math 预处理之后调用。
    static func preprocessInlineNotes(_ text: String) -> (text: String, tokens: [Int: InlineToken]) {
        let occurrences = inlineOccurrences(in: text)
        guard !occurrences.isEmpty else { return (text, [:]) }
        var tokens: [Int: InlineToken] = [:]
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for (k, occ) in occurrences.enumerated() {
            result += text[cursor..<occ.range.lowerBound]
            result += "\(inlinePlaceholderPrefix)\(k)\(inlinePlaceholderSuffix)"
            tokens[k] = InlineToken(
                content: occ.content,
                plainSpan: inlinePlainSpan(content: occ.content)
            )
            cursor = occ.range.upperBound
        }
        result += text[cursor...]
        return (result, tokens)
    }

    /// `^[content]` 在源 AST plain 坐标系的单位数:字面 `^` `[` `]` 各 1 + 内容 inline 的 plain 计数
    /// (内容里的 markup 定界符不计,与 MarkdownRevealPlainText 同源)。
    static func inlinePlainSpan(content: String) -> Int {
        let document = Markdown.Document(parsing: content)
        let plain = document.children.map { $0.markdownRevealPlainText }.joined()
        return plain.count + 3
    }
}
