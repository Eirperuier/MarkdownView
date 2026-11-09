import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension MarkdownInlineStyle {
    /// 合并到一段内容上的属性:文字色、高亮底色(默认高亮沿用 MarkdownHighlightSyntax 的
    /// 底色/字色)。笔迹另由调用方按管线打各自的 key。
    func colorAttributes() -> AttributeContainer {
        var container = AttributeContainer()
        if let color, let resolved = MarkdownColorToken.text(color) {
            container.foregroundColor = resolved
        }
        if let highlight {
            if let token = highlight {
                if let background = MarkdownColorToken.highlight(token) { container.backgroundColor = background }
            } else {
                container.backgroundColor = MarkdownHighlightSyntax.backgroundColor ?? MarkdownColorToken.highlight("yellow")
                if color == nil, let foreground = MarkdownHighlightSyntax.foregroundColor { container.foregroundColor = foreground }
            }
        }
        return container
    }
}

extension MarkdownColorToken {
    /// 文字色;不认识的 token → nil(文字保持原色)。
    public static func text(_ token: String) -> Color? {
        if token == "accent" { return .accentColor }
        if let hex = hexValue(token) { return rgb(hex) }
        guard let shade = shades[token] else { return nil }
        return adaptive(light: shade.light, dark: shade.dark, alpha: 1)
    }

    /// 高亮底色:同色相的浅底(深色模式略浓)。
    public static func highlight(_ token: String) -> Color? {
        if token == "accent" { return Color.accentColor.opacity(0.22) }
        if let hex = hexValue(token) { return rgb(hex).opacity(0.3) }
        guard let shade = shades[token] else { return nil }
        return adaptive(light: shade.dark, dark: shade.dark, alpha: 0.3, darkAlpha: 0.32)
    }

    /// A table cell's fill: the hue at one of three strengths, light to strong (a `#rrggbb`
    /// as it is); nil for a hue it doesn't know.
    public static func fill(_ token: String, strength: Int) -> Color? {
        if let hex = hexValue(token) { return rgb(hex) }
        guard let shade = shades[token] else { return nil }
        let alphas: [(light: CGFloat, dark: CGFloat)] = [(0.14, 0.2), (0.28, 0.36), (0.5, 0.56)]
        let alpha = alphas[min(max(strength, 1), alphas.count) - 1]
        return adaptive(light: shade.dark, dark: shade.dark, alpha: alpha.light, darkAlpha: alpha.dark)
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    private static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat, darkAlpha: CGFloat? = nil) -> Color {
        func components(_ value: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
        }
        let (lr, lg, lb) = components(light)
        let (dr, dg, db) = components(dark)
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dr, green: dg, blue: db, alpha: darkAlpha ?? alpha)
                : UIColor(red: lr, green: lg, blue: lb, alpha: alpha)
        })
        #elseif os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: dr, green: dg, blue: db, alpha: darkAlpha ?? alpha)
                : NSColor(red: lr, green: lg, blue: lb, alpha: alpha)
        })
        #else
        return Color(red: lr, green: lg, blue: lb).opacity(alpha)
        #endif
    }
}
