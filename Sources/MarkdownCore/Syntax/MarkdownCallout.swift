//
//  MarkdownCallout.swift
//  MarkdownView
//
//  提示块:引用块首行 `[!kind]`(GitHub alerts / Obsidian callouts 写法)把引用换成带色提示。
//    > [!note]                 → 「Note」提示
//    > [!warning] 别在主线程做  → 标题换成自定义文字
//  首行标记从内容里剥掉(reveal 计数与显示两侧同剥),只作标题呈现;不认识的 kind 照常是引用。
//

import Foundation
import Markdown

public enum MarkdownCalloutSyntax {
    /// 默认关闭,app 启动时打开(与 MarkdownHighlightSyntax 同步)。
    nonisolated(unsafe) public static var isEnabled = false
}

package struct MarkdownCallout: Equatable {
    package enum Kind: String, CaseIterable {
        case note, tip, important, warning, caution

        package init?(token: String) {
            switch token.lowercased() {
            case "note", "info", "abstract", "summary": self = .note
            case "tip", "hint", "success", "check", "done": self = .tip
            case "important", "question", "example": self = .important
            case "warning", "attention": self = .warning
            case "caution", "danger", "error", "bug", "failure": self = .caution
            default: return nil
            }
        }

        package var symbol: String {
            switch self {
            case .note: "info.circle.fill"
            case .tip: "lightbulb.fill"
            case .important: "exclamationmark.bubble.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .caution: "exclamationmark.octagon.fill"
            }
        }

        var defaultTitle: String { rawValue.capitalized }
    }

    package let kind: Kind
    /// 首行标记后的自定义标题,nil = kind 名。
    package let customTitle: String?

    package init(kind: Kind, customTitle: String?) {
        self.kind = kind
        self.customTitle = customTitle
    }

    package var title: String { customTitle ?? kind.defaultTitle }

    /// 解析首行:`[!kind]` 后可跟标题(Obsidian 的 `[!kind]-` / `[!kind]+` 折叠符忽略)。
    package static func parse(firstLine: String) -> MarkdownCallout? {
        guard MarkdownCalloutSyntax.isEnabled else { return nil }
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("[!"), let close = line.firstIndex(of: "]") else { return nil }
        let token = line[line.index(line.startIndex, offsetBy: 2)..<close]
        guard !token.isEmpty, token.count <= 16, let kind = Kind(token: String(token)) else { return nil }
        var rest = line[line.index(after: close)...]
        if rest.first == "-" || rest.first == "+" { rest = rest.dropFirst() }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return MarkdownCallout(kind: kind, customTitle: title.isEmpty ? nil : title)
    }

    /// 引用块内部 markdown(已剥 `>`)→ 提示 + 去掉首行后的内容。
    package static func split(innerMarkdown: String) -> (callout: MarkdownCallout, body: String)? {
        let firstLine = innerMarkdown.prefix { $0 != "\n" }
        guard let callout = parse(firstLine: String(firstLine)) else { return nil }
        let body = innerMarkdown.dropFirst(firstLine.count).drop { $0 == "\n" }
        return (callout, String(body))
    }
}

extension BlockQuote {
    /// 首段首行(到第一个换行为止的纯文本 inline)是 `[!kind]` 时的提示。
    package var callout: (callout: MarkdownCallout, body: BlockQuote)? {
        guard MarkdownCalloutSyntax.isEnabled,
              let paragraph = child(at: 0) as? Paragraph else { return nil }
        var inlines = paragraph.children.compactMap { $0 as? InlineMarkup }
        guard inlines.count == paragraph.childCount else { return nil }
        // cmark 会把 `[` `!note` `]` 拆成几个相邻 Text,拼回首行再判断。
        var firstLine = ""
        var lineEnd = 0
        while lineEnd < inlines.count, let text = inlines[lineEnd] as? Markdown.Text {
            firstLine += text.string
            lineEnd += 1
        }
        guard lineEnd == inlines.count || inlines[lineEnd] is SoftBreak || inlines[lineEnd] is LineBreak,
              let callout = MarkdownCallout.parse(firstLine: firstLine) else { return nil }
        inlines.removeFirst(min(inlines.count, lineEnd + 1))

        var blocks = children.compactMap { $0 as? BlockMarkup }
        guard blocks.count == childCount else { return nil }
        if inlines.isEmpty {
            blocks.removeFirst()
        } else {
            blocks[0] = Paragraph(inlines)
        }
        return (callout, BlockQuote(blocks))
    }
}
