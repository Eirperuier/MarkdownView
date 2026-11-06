//
//  MarkdownInlineStyle.swift
//  MarkdownView
//
//  行内样式:文字颜色、带颜色的高亮、笔迹注记,写在 swift-markdown 的行内属性节点上
//  (`^[文字](color: red)`,cmark 原生解析成 InlineAttributes 容器)。与只认纯文本的
//  `==高亮==` / `:circle[…]` 文本层语法互补:内容可以嵌套加粗、链接、公式等任意行内格式,
//  也不剥定界符(节点本身不占字符),reveal 计数天然一致。
//
//  属性写法:逗号分隔的 `key: value`(值可加引号)——
//  - `color: red`            文字颜色
//  - `highlight` / `highlight: yellow`   高亮(无值 = 默认高亮色,同 `==…==`)
//  - `pen: circle|wavy`      笔迹注记(同 `:circle[…]`)
//  - `ink: blue`             笔迹颜色(默认红笔,同 `{color=…}`)
//  颜色值是 MarkdownColorToken:色板名或 `#hex`。
//

import Foundation

public struct MarkdownInlineStyle: Hashable, Sendable {
    public var color: String?
    /// nil:不高亮;`.some(nil)`:默认高亮色;`.some(token)`:该颜色的高亮。
    public var highlight: String??
    public var pen: MarkdownPenMarkSyntax.Kind?
    public var ink: String?

    public init(color: String? = nil, highlight: String?? = nil, pen: MarkdownPenMarkSyntax.Kind? = nil, ink: String? = nil) {
        self.color = color
        self.highlight = highlight
        self.pen = pen
        self.ink = ink
    }

    /// 解析行内属性节点的属性串;一个认识的键都没有 → nil(节点按普通容器渲染)。
    public init?(attributes: String) {
        var style = MarkdownInlineStyle()
        var known = false
        var body = attributes.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{"), body.hasSuffix("}") { body = String(body.dropFirst().dropLast()) }
        for pair in body.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            let key = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            let value = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
                : ""
            switch key {
            case "color":
                guard !value.isEmpty else { continue }
                style.color = value
            case "highlight":
                style.highlight = .some(value.isEmpty || value == "true" ? nil : value)
            case "pen":
                guard let kind = MarkdownPenMarkSyntax.Kind(rawValue: value) else { continue }
                style.pen = kind
            case "ink":
                guard !value.isEmpty else { continue }
                style.ink = value
            default:
                continue
            }
            known = true
        }
        guard known else { return nil }
        self = style
    }

    /// 写回属性串(`^[…](这里)`),键序固定。
    public var attributes: String {
        var pairs: [String] = []
        if let color { pairs.append("color: \(color)") }
        if let highlight { pairs.append(highlight.map { "highlight: \($0)" } ?? "highlight") }
        if let pen { pairs.append("pen: \(pen.rawValue)") }
        if let ink { pairs.append("ink: \(ink)") }
        return pairs.joined(separator: ", ")
    }

}

/// 颜色 token:色板名(Craft 格式面板的颜色,另有 Craft 选区工具条的 orange / brown,
/// 笔迹沿用的 accent)或 `#hex`。
/// 每个名字有文字色(深浅色各一,保证在页面上可读)、高亮底色、笔色三种用法。
public enum MarkdownColorToken {
    /// 色板,按 Craft 格式面板的顺序。
    public static let palette = ["gray", "slate", "purple", "blue", "cyan", "mint", "green", "lemon", "yellow", "red"]

    /// (浅色模式文字色, 深色模式文字色)。浅色模式下取更深的同色相,浅黄之类才读得清。
    public static let shades: [String: (light: UInt32, dark: UInt32)] = [
        "gray": (0x8A8A8E, 0x9C9CA2),
        "slate": (0x4A4A52, 0x7C7C86),
        "purple": (0xB04ED6, 0xDF6CF5),
        "blue": (0x2F78F0, 0x6AA4F8),
        "cyan": (0x0796B8, 0x5FCFEA),
        "mint": (0x0C9A84, 0x7DE8D3),
        "green": (0x2E9A58, 0x83E3B1),
        "lemon": (0xA58C00, 0xFFF08A),
        "yellow": (0xC98A00, 0xF8D44E),
        "red": (0xE0484D, 0xEE6E6E),
        "orange": (0xE07A12, 0xF5A04A),
        "brown": (0x9C6B3C, 0xD4A373),
    ]

    public static func hexValue(_ token: String) -> UInt32? {
        guard token.hasPrefix("#") else { return nil }
        var hex = String(token.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 else { return nil }
        return UInt32(hex, radix: 16)
    }
}
