//
//  SelectablePenMarkOverlay.swift
//  MarkdownView
//
//  可选中管线的行内笔迹绘制层(`:circle[…]` / `:wavy[…]`)。
//  文字本体由 UITextView 正常渲染(参与选择/reveal),笔迹画在其上的透明 overlay:
//  按 textStorage 里的 PenMarkAttribute range,经 TextKit2 enumerateTextSegments 取
//  每行 frame,逐行画笔迹(跨行 span 按行拆段,与 SwiftUI Text 管线的 PenMarkPainter 行为一致)。
//
//  流式:span 末字符过 frontier 后笔迹才出现并淡入(与原版管线"写完字才落笔"同节奏);
//  等待/淡入期间由 CADisplayLink 驱动重绘,全部定型后自动停 —— 静态消息零常驻开销。
//

#if canImport(UIKit) && canImport(RichText)
import UIKit
import RichText

@available(iOS 17.0, *)
@MainActor
final class SelectablePenMarkOverlayView: UIView {
    struct Mark {
        let range: NSRange
        let kind: MarkdownPenMarkSyntax.Kind
        let colorToken: String?
        /// 内容哈希 seed(随属性值携带):与 SwiftUI 管线同一段文字同一笔迹。
        let seed: Double
    }

    private weak var textView: UITextView?
    private var marks: [Mark] = []
    /// (textView, storage range) → 是否已完整揭示。nil = 静态内容,恒真。
    private var isRevealed: (@MainActor (UITextView, NSRange) -> Bool)?
    /// 每条 mark 首次可见的时间戳(驱动淡入),key = range.location。
    private var revealStamps: [Int: Date] = [:]
    private var displayLink: CADisplayLink?

    private static let fadeDuration: TimeInterval = 0.35
    private static let lineWidth: CGFloat = 1.8
    /// 笔迹越出文字排版框的出血余量(圈画外扩+渐松+波浪下探;与 SwiftUI 管线
    /// PenMarkPainter.displayPadding 同量级):overlay 比 textView 四周各大这么多,
    /// 且 textView 需解除 clipsToBounds(UITextView 是 scroll view,默认裁切)。
    private static let overhang: CGFloat = 12

    // MARK: - 接入

    /// textView 创建/内容更新后同步:扫描 storage 的 PenMarkAttribute,有则挂/刷 overlay,无则拆。
    static func sync(on textView: UITextView, isRevealed: (@MainActor (UITextView, NSRange) -> Bool)?) {
        var marks: [Mark] = []
        let storage = textView.textStorage
        storage.enumerateAttribute(.richTextPenMark, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let raw = value as? String,
                  let decoded = MarkdownPenMarkSyntax.decodeAttributeValue(raw) else { return }
            marks.append(Mark(range: range, kind: decoded.kind, colorToken: decoded.color, seed: decoded.seed))
        }

        let existing = textView.subviews.compactMap { $0 as? SelectablePenMarkOverlayView }.first
        guard !marks.isEmpty else {
            existing?.detach()
            return
        }

        let overlay: SelectablePenMarkOverlayView
        if let existing {
            overlay = existing
        } else {
            overlay = SelectablePenMarkOverlayView(frame: .zero)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = .clear
            overlay.isOpaque = false
            overlay.isUserInteractionEnabled = false
            overlay.contentMode = .redraw
            textView.addSubview(overlay)
        }
        // 出血区:overlay 比 textView 四周各大 overhang,行首尾/首末行的笔迹不被切;
        // 这些块级 textView 不滚动,解除裁切安全。
        overlay.frame = textView.bounds.insetBy(dx: -Self.overhang, dy: -Self.overhang)
        textView.clipsToBounds = false
        overlay.textView = textView
        overlay.marks = marks
        overlay.isRevealed = isRevealed
        overlay.setNeedsDisplay()
        overlay.updateDisplayLink()
    }

    private func detach() {
        displayLink?.invalidate()
        displayLink = nil
        textView?.clipsToBounds = true
        removeFromSuperview()
    }

    // MARK: - 流式驱动

    /// 有未定型 mark(未揭示 / 淡入中)时跑 displayLink,全部定型即停。
    private func updateDisplayLink() {
        if hasUnsettledMarks {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private var hasUnsettledMarks: Bool {
        guard let textView else { return false }
        let now = Date()
        for mark in marks {
            guard markIsRevealed(mark, in: textView) else { return true }
            let stamp = revealStamps[mark.range.location] ?? .distantPast
            if now.timeIntervalSince(stamp) < Self.fadeDuration { return true }
        }
        return false
    }

    @objc private func tick() {
        setNeedsDisplay()
        if !hasUnsettledMarks {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func markIsRevealed(_ mark: Mark, in textView: UITextView) -> Bool {
        guard let isRevealed else { return true }
        return isRevealed(textView, mark.range)
    }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        guard let textView, let ctx = UIGraphicsGetCurrentContext() else { return }
        let now = Date()

        for mark in marks {
            guard markIsRevealed(mark, in: textView) else { continue }
            let stamp: Date
            if let existing = revealStamps[mark.range.location] {
                stamp = existing
            } else {
                // 首帧整批可见(打开历史消息)不做淡入;流式中途变可见才淡入。
                stamp = displayLink == nil ? .distantPast : now
                revealStamps[mark.range.location] = stamp
            }
            let age = now.timeIntervalSince(stamp)
            let alpha = Self.fadeDuration > 0 ? min(1, max(0, age / Self.fadeDuration)) : 1

            let ink = Self.ink(for: mark.colorToken, in: textView)
            for lineRect in segmentRects(for: mark.range, in: textView) {
                drawStroke(kind: mark.kind, in: lineRect, seed: mark.seed, alpha: alpha, ink: ink, ctx: ctx)
            }
        }
    }

    /// mark 的逐行 frame(textView 坐标系 = 容器坐标 + textContainerInset)。
    private func segmentRects(for range: NSRange, in textView: UITextView) -> [CGRect] {
        guard let tlm = textView.textLayoutManager,
              let contentManager = tlm.textContentManager else { return [] }
        let docStart = contentManager.documentRange.location
        guard let start = contentManager.location(docStart, offsetBy: range.location),
              let end = contentManager.location(docStart, offsetBy: range.location + range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }

        // overlay 原点在 textView 坐标 (-overhang, -overhang),换算 = inset + overhang。
        let inset = textView.textContainerInset
        var rects: [CGRect] = []
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            guard frame.width > 1 else { return true }
            rects.append(frame.offsetBy(dx: inset.left + Self.overhang, dy: inset.top + Self.overhang))
            return true
        }
        return rects
    }

    /// 颜色 token → 笔色(与 PenMarkPainter.ink 同色板;accent 用 textView.tintColor)。
    private static func ink(for token: String?, in textView: UITextView) -> UIColor {
        let base: UIColor
        switch token {
        case "blue": base = .systemBlue
        case "green": base = .systemGreen
        case "orange": base = .systemOrange
        case "purple": base = .systemPurple
        case "gray", "grey": base = .systemGray
        case "accent": base = textView.tintColor ?? .systemRed
        case let hex? where hex.hasPrefix("#"):
            base = Self.hexColor(hex) ?? .systemRed
        default: base = .systemRed
        }
        return base
    }

    private static func hexColor(_ token: String) -> UIColor? {
        var hex = String(token.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// 笔迹绘制:与 SwiftUI 管线 PenMarkPainter 同参数(UIKit 版本副本,改动需两侧同步)。
    private func drawStroke(
        kind: MarkdownPenMarkSyntax.Kind,
        in rect: CGRect,
        seed: Double,
        alpha: Double,
        ink: UIColor,
        ctx: CGContext
    ) {
        let path = UIBezierPath()
        switch kind {
        case .wavy:
            let y0 = rect.maxY + 1.5
            var x = rect.minX
            var first = true
            while x <= rect.maxX {
                let y = y0 + 1.4 * sin(x / 9 * 2 * .pi + seed)
                    + 0.7 * Self.penNoise(Double(x) / 6, seed: seed)
                if first { path.move(to: CGPoint(x: x, y: y)); first = false }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 2.5
            }
        case .circle:
            let box = rect.insetBy(dx: -5, dy: -2.5)
            let center = CGPoint(x: box.midX, y: box.midY)
            let a = box.width / 2
            let b = box.height / 2
            let start = -Double.pi * 0.75
            let end = start + 2 * .pi + .pi * 0.22
            let samples = 84
            for i in 0...samples {
                let progress = Double(i) / Double(samples)
                let t = start + (end - start) * progress
                let radiusScale = 1
                    + 0.045 * Self.penNoise(t * 1.9, seed: seed)
                    + 0.06 * progress
                let point = CGPoint(
                    x: center.x + a * radiusScale * CGFloat(cos(t)),
                    y: center.y + b * radiusScale * CGFloat(sin(t))
                )
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }

        ctx.saveGState()
        ctx.setStrokeColor(ink.withAlphaComponent(0.72 * alpha).cgColor)
        ctx.setLineWidth(Self.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path.cgPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 与 PenMarkPainter.penNoise / app 侧 handDrawnNoise 同款(参数一致,同 seed 同笔迹)。
    private static func penNoise(_ t: Double, seed: Double) -> Double {
        sin(t * 3.1 + seed * 12.9) * 0.55
            + sin(t * 7.3 + seed * 4.7) * 0.3
            + sin(t * 13.7 + seed * 7.1) * 0.15
    }
}
#endif
