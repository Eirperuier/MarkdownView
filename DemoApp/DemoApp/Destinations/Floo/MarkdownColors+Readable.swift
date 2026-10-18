import CardRuntime
import MarkdownView
import SwiftUI
import UIKit

extension MarkdownColors {
    /// The colors that read on `base`, as a card's on its own background (CardUI's
    /// ReadableOn): its text's three levels and an accent worked out from it, light on a
    /// dark base and dark on a light one.
    init(readableOn base: SRGBColor) {
        let palette = ReadableColor.palette(on: base)
        self.init(
            primary: Color(palette.primary.color),
            secondary: Color(palette.secondary.color),
            tertiary: Color(palette.tertiary.color),
            accent: Color(ReadableColor.accent(on: base)),
            scheme: palette.primary.polarity == .light ? .dark : .light,
            background: Color(base)
        )
    }
}

/// Code's highlighting on a background, as a card's colors on its own (CardUI's
/// BackgroundColors): a token's color with a hue keeps it, made to read and sit with the
/// background (ReadableColor.harmonized); one without is the theme's text or its muted
/// text (comments), which become the background's own: its text and its muted text.
enum ReadableCode {
    /// `runs`, colored by a theme for `scheme`, recolored for `base`.
    static func recolored(_ runs: [(NSRange, UIColor)], scheme: ColorScheme, on base: SRGBColor) -> [(NSRange, UIColor)] {
        let palette = ReadableColor.palette(on: base)
        let polarity = palette.primary.polarity
        let colors = runs.map { SRGBColor($0.1) }
        // The theme's text: of its colors without a hue, the one furthest from its ground
        // (the darkest on a light theme, the lightest on a dark one).
        let neutral = colors.filter { !hasHue($0) }
        let lightness = { (color: SRGBColor) in max(color.red, color.green, color.blue) }
        let text = scheme == .light ? neutral.min { lightness($0) < lightness($1) } : neutral.max { lightness($0) < lightness($1) }
        var made: [SRGBColor: UIColor] = [:]
        return zip(runs, colors).map { run, color in
            if let done = made[color] { return (run.0, done) }
            let recolored: SRGBColor
            if hasHue(color) {
                recolored = ReadableColor.harmonized(color, on: base, polarity: polarity)
            } else {
                recolored = color == text ? palette.primary.color : palette.tertiary.color
            }
            let done = UIColor(Color(recolored))
            made[color] = done
            return (run.0, done)
        }
    }

    /// Whether a color has a hue to keep, as cards tell (CardField.hue): bright enough and
    /// saturated enough to be named one.
    private static func hasHue(_ color: SRGBColor) -> Bool {
        let high = max(color.red, color.green, color.blue)
        let range = high - min(color.red, color.green, color.blue)
        return high > 0.25 && range / high > 0.3
    }
}

extension Color {
    init(_ color: SRGBColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

extension SRGBColor {
    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1))
    }

    init(_ color: Color) {
        self.init(UIColor(color))
    }
}
