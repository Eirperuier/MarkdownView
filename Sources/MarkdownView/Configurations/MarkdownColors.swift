import SwiftUI

/// The colors Markdown is drawn in, worked out by the host from what it's drawn on, as a
/// card's are from its background: text in three levels, an accent, and whether they read as
/// light or dark. Set with `markdownColors(_:)`, they reach all of it: its SwiftUI parts
/// through the foreground styles, the tint and the color scheme; its text views' runs, and the
/// views hosted in them (which don't take the environment around them), through these.
public struct MarkdownColors: Hashable, Sendable {
    public var primary: Color
    public var secondary: Color
    public var tertiary: Color
    /// Links, block quotes' bars, list markers in color: the tint.
    public var accent: Color
    /// The scheme the colors read as: dark for light text. Code's highlighting and the
    /// system's own colors follow it.
    public var scheme: ColorScheme
    /// What they're drawn on, for colors a host's views choose themselves (code's
    /// highlighting) to be made to read on it as these were.
    public var background: Color?

    public init(
        primary: Color,
        secondary: Color,
        tertiary: Color,
        accent: Color,
        scheme: ColorScheme,
        background: Color? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.accent = accent
        self.scheme = scheme
        self.background = background
    }

    /// A system color MarkdownView names as these colors: primary, secondary, gray (inline
    /// code's) as secondary, and the accent; any other as it is.
    func recolored(_ color: Color) -> Color {
        switch color {
        case .primary: primary
        case .secondary, .gray: secondary
        case .accentColor: accent
        default: color
        }
    }
}

extension EnvironmentValues {
    /// The colors the Markdown around is drawn in (`markdownColors(_:)`), for the views a host
    /// draws in it (a code block style's): nil for the system's.
    public var markdownColors: MarkdownColors? { markdownRendererConfiguration.colors }
}

extension View {
    /// Draws the Markdown inside in `colors`, everywhere it draws (MarkdownColors); nil for
    /// the system's.
    nonisolated public func markdownColors(_ colors: MarkdownColors?) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.colors = colors
        }
        .modifier(MarkdownColorsApplied(colors: colors))
    }
}

/// The colors as SwiftUI's own: the foreground styles, the tint and the scheme. Also on each
/// view a text view hosts, which starts from the window's environment, not this one.
struct MarkdownColorsApplied: ViewModifier {
    var colors: MarkdownColors?

    func body(content: Content) -> some View {
        if let colors {
            content
                .foregroundStyle(colors.primary, colors.secondary, colors.tertiary)
                .tint(colors.accent)
                .environment(\.colorScheme, colors.scheme)
        } else {
            content
        }
    }
}
