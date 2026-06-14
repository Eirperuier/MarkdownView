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
        runs.contains {
            $0[MarkdownInlineSymbolAttribute.self] != nil
                || $0[MarkdownLinkChipIconAttribute.self] != nil
        }
    }

    /// Whether any run carries a link-chip favicon placeholder
    /// (views observe `MarkdownLinkChips.iconRevision` when true).
    public var hasLinkChipIcon: Bool {
        runs.contains { $0[MarkdownLinkChipIconAttribute.self] != nil }
    }

    /// Whether any run belongs to a link chip(定稿路径据此挂胶囊渲染器).
    var hasLinkChipSegment: Bool {
        runs.contains { $0[MarkdownLinkChipSegmentAttribute.self] == true }
    }
}

/// Builds a `Text` from an `AttributedString`, substituting inline-symbol runs
/// (see ``MarkdownInlineSymbolAttribute``) with the corresponding SF Symbol.
/// Falls back to `Text(_:)` directly when there are no symbol runs.
@MainActor
func markdownTextWithInlineSymbols(_ attributed: AttributedString) -> Text {
    guard attributed.hasInlineSymbol else { return Text(attributed) }
    // 在调用方 body 的执行作用域内读修订号建立观察:favicon 异步载完 bump 后,
    // 持有这段文本的视图(_MarkdownText 等)body 重跑、Text 重建换上真图。
    if attributed.hasLinkChipIcon {
        _ = MarkdownLinkChips.iconRevision.value
    }
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
        } else if let host = run[MarkdownLinkChipIconAttribute.self] {
            // 链接 chip 的 favicon:缓存命中直接嵌图;未命中先 globe 占位并预取,
            // 载完 app bump iconRevision → 观察方重建 Text 换上真图。
            var iconText: Text
            if let image = MarkdownLinkChips.iconImage?(host) {
                // 位图坐在基线上、视觉偏高,下沉与文字居中。
                // foregroundColor 只对 template 模式的图(单色 SVG 字形)生效:
                // 浅色模式黑、深色模式白;普通彩色 favicon 不受影响。
                iconText = Text("\(image)")
                    .foregroundColor(.primary)
                    .baselineOffset(-2)
            } else {
                MarkdownLinkChips.prefetchIcon?(host)
                if let placeholder = MarkdownLinkChips.placeholderIcon?() {
                    // app 提供的同尺寸 template 位图:与 favicon 分支
                    // 对齐方式完全一致,替换瞬间不跳。
                    iconText = Text("\(placeholder)")
                        .foregroundColor(.secondary)
                        .baselineOffset(-2)
                } else {
                    iconText = Text("\(Image(systemName: "globe"))")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .baselineOffset(-0.5)
                }
            }
            if #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *) {
                iconText = iconText.customAttribute(MarkdownChipRunTextAttribute())
            }
            result = result + iconText
        } else if run[MarkdownLinkChipSegmentAttribute.self] == true {
            // chip 文本段:iOS 18+ 由 TextRenderer 画统一胶囊背景,剥掉逐 run 的
            // 矩形 backgroundColor;更早系统保留矩形背景作为降级。
            var segment = AttributedString(attributed[run.range])
            if #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *) {
                segment.backgroundColor = nil
                result = result + Text(segment)
                    .customAttribute(MarkdownChipRunTextAttribute())
            } else {
                result = result + Text(segment)
            }
        } else {
            result = result + Text(AttributedString(attributed[run.range]))
        }
    }
    return result
}

// MARK: - chip 胶囊绘制(iOS 18+ TextRenderer)

/// 在 Text.Layout 的 run 上标记"属于 chip",渲染器据此识别范围。
@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
struct MarkdownChipRunTextAttribute: TextAttribute {}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
enum ChipCapsulePainter {
    struct Span {
        /// 行内字符索引范围(相对整个 layout 的字符计数)。
        let charRange: Range<Int>
        let rect: CGRect
    }

    /// 扫描一行,把相邻的 chip run 合并成 span(一个 chip 一个 span;
    /// 不同 chip 之间必有非 chip 文本隔开)。
    static func spans(in line: Text.Layout.Line, startingCharIndex: Int) -> [Span] {
        var spans: [Span] = []
        var charIdx = startingCharIndex
        var current: (start: Int, rect: CGRect)?
        for run in line {
            let isChip = run[MarkdownChipRunTextAttribute.self] != nil
            if isChip {
                let rect = run.typographicBounds.rect
                if let existing = current {
                    current = (existing.start, existing.rect.union(rect))
                } else {
                    current = (charIdx, rect)
                }
            } else if let existing = current {
                spans.append(Span(charRange: existing.start..<charIdx, rect: existing.rect))
                current = nil
            }
            charIdx += run.count
        }
        if let existing = current {
            spans.append(Span(charRange: existing.start..<charIdx, rect: existing.rect))
        }
        return spans
    }

    /// 画统一胶囊背景(gray 0.1,随 chip 整体透明度)。
    /// 纵向外扩让胶囊比文字行高更丰满,接近普通 padding 包裹的胶囊观感;
    /// 正文行距 5pt,±2 外扩不会蹭到相邻行。
    static func draw(_ span: Span, opacity: Double, in ctx: inout GraphicsContext) {
        let rect = span.rect.insetBy(dx: 0, dy: -2)
        let capsule = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        ctx.fill(capsule, with: .color(.gray.opacity(0.1 * opacity)))
    }
}

/// 定稿(无 reveal)状态下专画 chip 胶囊的轻量渲染器。
@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
struct ChipCapsuleRenderer: TextRenderer {
    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var charIdx = 0
        for line in layout {
            for span in ChipCapsulePainter.spans(in: line, startingCharIndex: charIdx) {
                ChipCapsulePainter.draw(span, opacity: 1, in: &ctx)
            }
            for run in line {
                charIdx += run.count
            }
            ctx.draw(line)
        }
    }
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
