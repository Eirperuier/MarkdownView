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
        ("gray", String(localized: "Gray")), ("slate", String(localized: "Slate")), ("purple", String(localized: "Purple")), ("blue", String(localized: "Blue")), ("cyan", String(localized: "Cyan")),
        ("mint", String(localized: "Mint")), ("green", String(localized: "Green")), ("lemon", String(localized: "Lemon")), ("yellow", String(localized: "Yellow")), ("red", String(localized: "Red")),
    ]

    /// The selection toolbar's highlights and text colours, in Craft's order.
    static let highlights: [(token: String, title: String)] = [
        ("yellow", String(localized: "Yellow")), ("green", String(localized: "Green")), ("mint", String(localized: "Mint")), ("blue", String(localized: "Blue")), ("purple", String(localized: "Purple")), ("red", String(localized: "Red")), ("orange", String(localized: "Orange")),
    ]
    static let texts: [(token: String, title: String)] = [
        ("blue", String(localized: "Blue")), ("purple", String(localized: "Purple")), ("red", String(localized: "Red")), ("orange", String(localized: "Orange")), ("slate", String(localized: "Slate")), ("brown", String(localized: "Brown")),
    ]

    static func swatch(_ token: String) -> Color {
        MarkdownColorToken.text(token) ?? .primary
    }

    /// A highlight as it looks on the page.
    static func highlightSwatch(_ token: String) -> Color {
        MarkdownColorToken.highlight(token) ?? .clear
    }

    /// A highlight of any hue (drawn light over the page, as the palette's are).
    static func highlight(hue: Double) -> Color {
        Color(hue: hue, saturation: 0.9, brightness: 1)
    }

    /// The hues along a slider's track, and the ring around "any colour".
    static let hues = LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 0.75, brightness: 1) },
                                     startPoint: .leading, endPoint: .trailing)
    static let rainbow = AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)

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
