import SwiftUI
#if canImport(RichText)
import RichText
#endif

extension MarkdownPenMarkSyntax {
    /// 显示用:内容打 kind 属性、删定界符。先打属性、再从尾部删,与高亮同套路。
    static func applied(to attributed: AttributedString) -> AttributedString {
        let source = String(attributed.characters)
        let matches = matchOffsets(source)
        guard !matches.isEmpty else { return attributed }

        var result = attributed
        for m in matches {
            guard let range = characterRange(in: result, from: m.innerStart, to: m.innerEnd) else { continue }
            if m.kind == .color {
                if let color = MarkdownPenInk.textColor(m.color) { result[range].foregroundColor = color }
            } else {
                result[range][MarkdownPenMarkAttribute.self] = encodeAttributeValue(m)
            }
        }
        for m in matches.reversed() {
            if let close = characterRange(in: result, from: m.innerEnd, to: m.end) {
                result.removeSubrange(close)
            }
            if let open = characterRange(in: result, from: m.start, to: m.innerStart) {
                result.removeSubrange(open)
            }
        }
        return result
    }

    /// 可选中管线(UITextView)形态:同样剥定界符,kind 打 RichText scope 的
    /// PenMarkAttribute(scope 内的键才会桥接进 textStorage),笔迹由
    /// SelectablePenMarkOverlay 按 storage range 定位绘制。
    static func appliedSelectable(to attributed: AttributedString) -> AttributedString {
        let source = String(attributed.characters)
        let matches = matchOffsets(source)
        guard !matches.isEmpty else { return attributed }

        var result = attributed
        for m in matches {
            guard let range = characterRange(in: result, from: m.innerStart, to: m.innerEnd) else { continue }
            if m.kind == .color {
                if let color = MarkdownPenInk.textColor(m.color) { result[range].foregroundColor = color }
                continue
            }
            #if canImport(RichText)
            result[range][AttributeScopes.RichTextAttributes.PenMarkAttribute.self] = encodeAttributeValue(m)
            #endif
        }
        for m in matches.reversed() {
            if let close = characterRange(in: result, from: m.innerEnd, to: m.end) {
                result.removeSubrange(close)
            }
            if let open = characterRange(in: result, from: m.start, to: m.innerStart) {
                result.removeSubrange(open)
            }
        }
        return result
    }
}

// MARK: - 笔迹绘制(iOS 18+ TextRenderer 层)

/// Text.Layout run 上的笔迹标记(PenMarkPainter 从 run 读回实例取值)。
@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
struct PenMarkTextAttribute: TextAttribute {
    let mark: MarkdownPenMarkSyntax.Mark
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
enum PenMarkPainter {
    /// SwiftUI 把 TextRenderer 的绘制裁到 Text bounds + displayPadding —— 含笔迹的
    /// 文本必须上报这个余量,否则行首/行尾/首末行的笔迹被切。
    static let displayPadding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)

    /// 与其他来源的 displayPadding(如 CJK 斜体)合并:逐边取最大。
    static func mergedDisplayPadding(_ base: EdgeInsets, hasPenMark: Bool) -> EdgeInsets {
        guard hasPenMark else { return base }
        return EdgeInsets(
            top: max(base.top, displayPadding.top),
            leading: max(base.leading, displayPadding.leading),
            bottom: max(base.bottom, displayPadding.bottom),
            trailing: max(base.trailing, displayPadding.trailing)
        )
    }

    struct Span {
        let charRange: Range<Int>
        let rect: CGRect
        let baseline: CGFloat
        let mark: MarkdownPenMarkSyntax.Mark
    }

    /// 扫描一行,把相邻同标记的笔迹 run 合并成 span(与 ChipCapsulePainter 同构)。
    static func spans(in line: Text.Layout.Line, startingCharIndex: Int) -> [Span] {
        var spans: [Span] = []
        var charIdx = startingCharIndex
        var current: (start: Int, rect: CGRect, baseline: CGFloat, mark: MarkdownPenMarkSyntax.Mark)?

        func flush(at index: Int) {
            if let existing = current {
                spans.append(Span(
                    charRange: existing.start..<index,
                    rect: existing.rect,
                    baseline: existing.baseline,
                    mark: existing.mark
                ))
                current = nil
            }
        }

        for run in line {
            if let mark = run[PenMarkTextAttribute.self]?.mark {
                let bounds = run.typographicBounds
                if let existing = current, existing.mark == mark {
                    current = (existing.start, existing.rect.union(bounds.rect),
                               max(existing.baseline, bounds.origin.y), mark)
                } else {
                    flush(at: charIdx)
                    current = (charIdx, bounds.rect, bounds.origin.y, mark)
                }
            } else {
                flush(at: charIdx)
            }
            charIdx += run.count
        }
        flush(at: charIdx)
        return spans
    }

    /// 颜色 token → 着色(不含透明度,draw 里按图层透明度叠)。`accent` 用 SwiftUI accentColor,
    /// `foreground`(u / s 默认)用文字本身的前景(GraphicsContext 按环境解析)。
    static func shading(for mark: MarkdownPenMarkSyntax.Mark) -> GraphicsContext.Shading {
        let fallback = PenMarkGeometry.defaultInk(for: mark.kind).token
        switch mark.color ?? fallback {
        case "foreground": return .foreground
        case "accent": return .color(.accentColor)
        case let token:
            if let color = mark.color.flatMap(MarkdownPenInk.chosen) ?? MarkdownPenInk.color(token) { return .color(color) }
            if fallback == "foreground" { return .foreground }
            return .color(MarkdownPenInk.color(fallback) ?? .primary)
        }
    }

    /// 画一个 span。seed = 内容哈希(随 span 携带)—— 同一段文字跨管线/重排永远同一笔迹。
    static func draw(_ span: Span, opacity: Double, in ctx: inout GraphicsContext) {
        guard opacity > 0 else { return }
        var layer = ctx
        layer.opacity *= opacity * PenMarkGeometry.defaultInk(for: span.mark.kind).opacity
        let shading = shading(for: span.mark)
        for stroke in PenMarkGeometry.strokes(for: span.mark, in: span.rect, baseline: span.baseline) {
            let path = Path(stroke.path)
            switch stroke.mode {
            case .fill:
                layer.fill(path, with: shading)
            case let .stroke(width, dash, roundCap):
                layer.stroke(path, with: shading, style: StrokeStyle(
                    lineWidth: width,
                    lineCap: roundCap ? .round : .butt,
                    lineJoin: .round,
                    dash: dash
                ))
            }
        }
    }

    /// 本行的笔迹按图层分开:荧光笔铺在字下(先画),其余压在字上(后画)。
    static func split(_ spans: [Span]) -> (under: [Span], over: [Span]) {
        (spans.filter { $0.mark.kind.isUnderlay }, spans.filter { !$0.mark.kind.isUnderlay })
    }
}
