//
//  DocColors.swift
//  DemoApp
//
//  The colours text can take, a highlight and a pen mark: MarkdownView's colour tokens
//  in Craft's palette order, with their names, as swatches and as menu images.
//

import SwiftUI
import MarkdownView

enum DocColors {
    static let palette: [(token: String, title: String)] = [
        ("gray", "灰色"), ("slate", "深灰"), ("purple", "紫色"), ("blue", "蓝色"), ("cyan", "青色"),
        ("mint", "薄荷"), ("green", "绿色"), ("lemon", "浅黄"), ("yellow", "黄色"), ("red", "红色"),
    ]

    static func swatch(_ token: String) -> Color {
        MarkdownColorToken.text(token) ?? .primary
    }

    /// A colour dot for a menu item.
    static func dot(_ token: String) -> UIImage? {
        UIImage(systemName: "circle.fill")?.withTintColor(UIColor(swatch(token)), renderingMode: .alwaysOriginal)
    }

    /// `#rrggbb` for a picked colour (sRGB).
    static func hex(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}
