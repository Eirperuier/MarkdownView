//
//  MarkdownCustomListMarker.swift
//  MarkdownView
//
//  自定义 list bullet:标准无序列表项行首 `{token}` 把 bullet 换成对应 emoji / SF Symbol。
//    - `- {🚀} 内容`      → emoji bullet(token 内含非 ASCII → emoji)
//    - `- {star.fill} 内容` → SF Symbol bullet(token 为 ASCII 符号名)
//  token 被从内容里剥掉,只作 bullet 呈现。每项独立(想统一列表就每项重复同一 token)。
//

import Foundation
import Markdown

/// 自定义 bullet 的两种来源。
public enum CustomListMarker: Equatable {
    case emoji(String)
    case symbol(String)   // SF Symbol 名(如 "star.fill")
}

extension ListItem {
    /// 检测行首 `{token}` 自定义 bullet 标记(仅无序列表项;有序/任务列表不接管)。
    /// 返回 (marker, 需从首个 Text 剥掉的字符数,含收尾空格)。
    public var customListMarkerMatch: (marker: CustomListMarker, stripCount: Int)? {
        // 任务列表([x])不接管;有序列表也不接管(仅无序 bullet)。
        guard checkbox == nil else { return nil }
        guard let paragraph = child(at: 0) as? Paragraph,
              let firstText = paragraph.child(at: 0) as? Markdown.Text else { return nil }
        return Self.parseMarkerToken(firstText.string)
    }

    /// 从(list item 内容起始的)字符串解析 `{token}` 前缀;命中返回 (marker, 需剥掉的字符数)。
    /// 容忍行首空白;`}` 后紧跟内容或一个空白都认(空白一并剥掉)——中文常不加空格。
    public static func parseMarkerToken(_ raw: String) -> (marker: CustomListMarker, stripCount: Int)? {
        let leadingWS = raw.prefix { $0 == " " || $0 == "\t" }.count
        let s = String(raw.dropFirst(leadingWS))
        guard s.hasPrefix("{"), let close = s.firstIndex(of: "}") else { return nil }
        let body = String(s[s.index(after: s.startIndex)..<close])
        guard !body.isEmpty, body.count <= 40 else { return nil }
        // 花括号内不含换行(避免把跨行 {..} 误当标记)。
        guard !body.contains("\n") else { return nil }
        var after = s.index(after: close)
        var strip = s.distance(from: s.startIndex, to: after)
        // `}` 后可选一个空白,一并剥掉。
        if after < s.endIndex, s[after] == " " || s[after] == "\t" {
            after = s.index(after: after)
            strip += 1
        }
        // 分类:纯 ASCII 符号名(字母/数字/点/连字符)→ SF Symbol;含非 ASCII → emoji。
        let isSymbolName = body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        return (isSymbolName ? .symbol(body) : .emoji(body), leadingWS + strip)
    }

    /// 去掉行首 `{token}` 前缀后的 list item(内容渲染用);无标记则原样返回。
    public func strippingCustomMarker() -> ListItem {
        guard let match = customListMarkerMatch else { return self }
        var blockChildren = children.compactMap { $0 as? BlockMarkup }
        guard blockChildren.count == childCount,
              let paragraph = blockChildren.first as? Paragraph else { return self }
        var inlines = paragraph.children.compactMap { $0 as? InlineMarkup }
        guard inlines.count == paragraph.childCount,
              let firstText = inlines.first as? Markdown.Text else { return self }
        let stripped = String(firstText.string.dropFirst(match.stripCount))
        if stripped.isEmpty {
            inlines.removeFirst()
        } else {
            inlines[0] = Markdown.Text(stripped)
        }
        blockChildren[0] = Paragraph(inlines)
        return ListItem(checkbox: checkbox, blockChildren)
    }
}
