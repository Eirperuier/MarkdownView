import SwiftUI

/// Marks a run whose (placeholder) text should be drawn as an inline SF Symbol.
///
/// The run's characters are expected to be a single object-replacement
/// placeholder (`\u{FFFC}`); when building a `Text` for display, the renderer
/// swaps that run for `Text("\(Image(systemName: value))")`. Because the symbol
/// occupies a real character slot in the `AttributedString`, it flows and wraps
/// with the surrounding text and participates in the streaming reveal animation
/// like any other glyph.
public enum MarkdownInlineSymbolAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "MarkdownInlineSymbol"
}

public extension AttributedString {
    /// A single-character run that renders as an inline SF Symbol.
    /// - Parameters:
    ///   - systemName: SF Symbol name.
    ///   - link: Optional link destination (makes the symbol tappable).
    ///   - color: Optional foreground color.
    static func inlineSymbol(
        _ systemName: String,
        link: URL? = nil,
        color: Color? = nil
    ) -> AttributedString {
        var run = AttributedString("\u{FFFC}")
        run[MarkdownInlineSymbolAttribute.self] = systemName
        if let link { run.link = link }
        if let color { run.foregroundColor = color }
        return run
    }

    /// Whether any run carries an inline-symbol attribute.
    var hasInlineSymbol: Bool {
        runs.contains { $0[MarkdownInlineSymbolAttribute.self] != nil }
    }
}

/// Builds a `Text` from an `AttributedString`, substituting inline-symbol runs
/// (see ``MarkdownInlineSymbolAttribute``) with the corresponding SF Symbol.
/// Falls back to `Text(_:)` directly when there are no symbol runs.
func markdownTextWithInlineSymbols(_ attributed: AttributedString) -> Text {
    guard attributed.hasInlineSymbol else { return Text(attributed) }
    var result = Text(verbatim: "")
    for run in attributed.runs {
        if let symbol = run[MarkdownInlineSymbolAttribute.self] {
            var symbolText = Text("\(Image(systemName: symbol))")
            // Carry the run's foreground color so the symbol matches the link
            // tint. The color is stripped (→ nil) by
            // `clearingRevealSensitiveAttributes()` for hidden/frontier glyphs,
            // so the outer reveal `.foregroundColor` still governs those.
            if let color = run.foregroundColor {
                symbolText = symbolText.foregroundColor(color)
            }
            result = result + symbolText
        } else {
            result = result + Text(AttributedString(attributed[run.range]))
        }
    }
    return result
}

/// Optional app-provided hook for rendering specific links as custom inline
/// `AttributedString`s (e.g. local-file references shown as an SF Symbol +
/// filename). Returning a non-nil value makes `CmarkNodeVisitor.visitLink`
/// substitute it (merging into the text flow + reveal animation); returning
/// `nil` falls back to the default link rendering.
///
/// Mirrors `MarkdownImageRenders`: a process-wide registry rather than a value
/// on `MarkdownRendererConfiguration` (which must stay `Hashable`).
public final class MarkdownInlineLinkRenderers: @unchecked Sendable {
    public static let shared = MarkdownInlineLinkRenderers()

    private init() {}

    /// - Parameters:
    ///   - destination: The raw link destination (e.g. `local:///report.pdf`).
    ///   - text: The link's plain text label.
    ///   - tint: The configured link tint color.
    public var builder: (@MainActor (_ destination: String, _ text: String, _ tint: Color) -> AttributedString?)?
}
