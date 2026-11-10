//
//  MarkdownPenMarkGeometry.swift
//  MarkdownView
//
//  笔迹注记的几何:一个 span 在一行上的排版框(+ 基线)→ 若干笔(路径 + 填充/描边)。
//  两条管线共用这一份 —— SwiftUI Text 的 PenMarkPainter 与可选中管线的
//  SelectablePenMarkOverlay 只负责取行框、解析颜色、按透明度落笔,同一段文字画出同一笔迹。
//
//  下划线 / 删除线也在这里画:SwiftUI Text 只认单线与虚线样式(粗线、双线被忽略),
//  自己画两条管线才一致。
//

import CoreGraphics
import Foundation
import SwiftUI

/// 颜色 token(`{color=…}` / `{c=…}`)→ 颜色。两条管线与 `:color[…]` 共用;
/// 系统色是动态色,深浅色切换时绘制层自然换色(不烤死在缓存里)。
enum MarkdownPenInk {
    /// named / 语义 / #hex。`accent` 与 `foreground` 由调用方按自己的上下文解析(返回 nil)。
    static func color(_ token: String) -> Color? {
        switch token {
        case "red", "negative", "error", "danger": .red
        case "orange", "warning": .orange
        case "yellow": .yellow
        case "green", "positive", "success": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue", "info": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        case "gray", "grey": .gray
        case "secondary": .secondary
        case "primary": .primary
        case let hex where hex.hasPrefix("#"): hexColor(hex)
        default: nil
        }
    }

    /// The ink a mark's own `color` token names: the pen's system colours, then the
    /// document palette (MarkdownColorToken, so a mark and a text in `red` agree). Nil
    /// for a token neither knows, which `color(_:)` may still read (`negative`, `teal`).
    static func chosen(_ token: String) -> Color? {
        switch token {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "purple": .purple
        case "gray", "grey": .gray
        default: MarkdownColorToken.text(token)
        }
    }

    /// `:color[…]` 的文字色:认得的 token 才上色,不认得的照常文字(不报错、不吞字)。
    static func textColor(_ token: String?) -> Color? {
        guard let token else { return nil }
        if token == "accent" { return .accentColor }
        return color(token) ?? MarkdownColorToken.text(token)
    }

    static func hexColor(_ token: String) -> Color? {
        var hex = String(token.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
