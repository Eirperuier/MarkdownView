//
//  SelectablePenMarkOverlay.swift
//  MarkdownView
//
//  可选中管线的行内笔迹绘制层(`:circle[…]` / `:marker[…]` / `:u[…]` …)。
//  文字本体由 UITextView 正常渲染(参与选择/reveal),笔迹画在两层透明 view 上:
//  荧光笔一层垫在文字之下,其余一层压在文字之上。按 textStorage 里的 PenMarkAttribute
//  range,经 TextKit2 enumerateTextSegments 取每行 frame 与基线,交给 PenMarkGeometry
//  (与 SwiftUI Text 管线的 PenMarkPainter 同一份几何)逐行落笔。
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
        /// 含内容哈希 seed:与 SwiftUI 管线同一段文字同一笔迹。
        let mark: MarkdownPenMarkSyntax.Mark
    }

    /// 本层画哪些:true = 荧光笔(垫在字下),false = 其余(压在字上)。
    private var isUnderlay = false
    private weak var textView: UITextView?
    private var marks: [Mark] = []
    /// (textView, storage range) → 是否已完整揭示。nil = 静态内容,恒真。
    private var isRevealed: (@MainActor (UITextView, NSRange) -> Bool)?
    /// 每条 mark 首次可见的时间戳(驱动淡入),key = range.location。
    private var revealStamps: [Int: Date] = [:]
    private var displayLink: CADisplayLink?

    private static let fadeDuration: TimeInterval = 0.35
    /// 笔迹越出文字排版框的出血余量(PenMarkGeometry.overhang + 余量):overlay 比 textView
    /// 四周各大这么多,且 textView 需解除 clipsToBounds(UITextView 是 scroll view,默认裁切)。
    private static let overhang: CGFloat = PenMarkGeometry.overhang + 2

    // MARK: - 接入

    /// textView 创建/内容更新后同步:扫描 storage 的 PenMarkAttribute,有则挂/刷两层 overlay,无则拆。
    static func sync(on textView: UITextView, isRevealed: (@MainActor (UITextView, NSRange) -> Bool)?) {
        var marks: [Mark] = []
        let storage = textView.textStorage
        storage.enumerateAttribute(.richTextPenMark, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let raw = value as? String,
                  let decoded = MarkdownPenMarkSyntax.decodeAttributeValue(raw) else { return }
            marks.append(Mark(range: range, mark: decoded))
        }
        let existing = textView.subviews.compactMap { $0 as? SelectablePenMarkOverlayView }
        guard !marks.isEmpty else {
            existing.forEach { $0.detach() }
            return
        }
        for isUnderlay in [true, false] {
            let layerMarks = marks.filter { $0.mark.kind.isUnderlay == isUnderlay }
            let current = existing.first { $0.isUnderlay == isUnderlay }
            guard !layerMarks.isEmpty else {
                current?.detach()
                continue
            }
            let overlay = current ?? Self.make(isUnderlay: isUnderlay, on: textView)
            // 出血区:overlay 比 textView 四周各大 overhang,行首尾/首末行的笔迹不被切;
            // 这些块级 textView 不滚动,解除裁切安全。
            overlay.frame = textView.bounds.insetBy(dx: -Self.overhang, dy: -Self.overhang)
            overlay.textView = textView
            overlay.marks = layerMarks
            overlay.isRevealed = isRevealed
            overlay.setNeedsDisplay()
            overlay.updateDisplayLink()
        }
        textView.clipsToBounds = false
    }

    private static func make(isUnderlay: Bool, on textView: UITextView) -> SelectablePenMarkOverlayView {
        let overlay = SelectablePenMarkOverlayView(frame: .zero)
        overlay.isUnderlay = isUnderlay
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.isUserInteractionEnabled = false
        overlay.contentMode = .redraw
        // 底层垫在文字绘制视图之下(textView 背景透明);面层在最上。
        if isUnderlay { textView.insertSubview(overlay, at: 0) } else { textView.addSubview(overlay) }
        // 颜色是动态色,深浅色切换时重画。
        overlay.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SelectablePenMarkOverlayView, _) in
            view.setNeedsDisplay()
        }
        return overlay
    }

    private func detach() {
        displayLink?.invalidate()
        displayLink = nil
        if let textView, !textView.subviews.contains(where: { $0 !== self && $0 is SelectablePenMarkOverlayView }) {
            textView.clipsToBounds = true
        }
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

            ctx.saveGState()
            ctx.setAlpha(alpha * PenMarkGeometry.defaultInk(for: mark.mark.kind).opacity)
            let ink = Self.ink(for: mark, in: textView).cgColor
            for segment in segments(for: mark.range, in: textView) {
                for stroke in PenMarkGeometry.strokes(for: mark.mark, in: segment.rect, baseline: segment.baseline) {
                    ctx.addPath(stroke.path)
                    switch stroke.mode {
                    case .fill:
                        ctx.setFillColor(ink)
                        ctx.fillPath()
                    case let .stroke(width, dash, roundCap):
                        ctx.setStrokeColor(ink)
                        ctx.setLineWidth(width)
                        ctx.setLineCap(roundCap ? .round : .butt)
                        ctx.setLineJoin(.round)
                        ctx.setLineDash(phase: 0, lengths: dash)
                        ctx.strokePath()
                    }
                }
            }
            ctx.restoreGState()
        }
    }

    /// mark 的逐行排版框 + 基线(overlay 坐标系 = textView 坐标 + overhang)。排版框取该行
    /// 基线上下按字体 ascender/descender 撑开 —— 与 SwiftUI 管线 run.typographicBounds 同义
    ///(segment frame 是整行行盒,CJK fallback 会把它撑高)。
    private func segments(for range: NSRange, in textView: UITextView) -> [(rect: CGRect, baseline: CGFloat)] {
        guard let tlm = textView.textLayoutManager,
              let contentManager = tlm.textContentManager else { return [] }
        let docStart = contentManager.documentRange.location
        guard let start = contentManager.location(docStart, offsetBy: range.location),
              let end = contentManager.location(docStart, offsetBy: range.location + range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }

        let storage = textView.textStorage
        let font = (range.location < storage.length
            ? storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            : nil) ?? textView.font ?? .preferredFont(forTextStyle: .body)
        let inset = textView.textContainerInset
        let dx = inset.left + Self.overhang
        let dy = inset.top + Self.overhang
        var result: [(rect: CGRect, baseline: CGFloat)] = []
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { segmentRange, frame, _, _ in
            guard frame.width > 1 else { return true }
            let baseline = segmentRange.flatMap { Self.baseline(at: $0.location, midY: frame.midY, in: tlm) }
                ?? (frame.minY + font.ascender)
            let rect = CGRect(x: frame.minX, y: baseline - font.ascender,
                              width: frame.width, height: font.ascender - font.descender)
            result.append((rect.offsetBy(dx: dx, dy: dy), baseline + dy))
            return true
        }
        return result
    }

    /// 某位置所在行的基线 y(容器坐标):layout fragment 里与 segment 同高的那条行片段。
    private static func baseline(at location: NSTextLocation, midY: CGFloat, in tlm: NSTextLayoutManager) -> CGFloat? {
        guard let fragment = tlm.textLayoutFragment(for: location) else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        for line in fragment.textLineFragments {
            let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
            if bounds.minY <= midY, midY <= bounds.maxY {
                return bounds.minY + line.glyphOrigin.y
            }
        }
        return nil
    }

    /// 颜色 token → 笔色(与 PenMarkPainter.shading 同色板;accent = textView.tintColor,
    /// foreground = 该段文字自己的颜色)。系统色是动态色,draw 时按当前外观解析。
    private static func ink(for mark: Mark, in textView: UITextView) -> UIColor {
        let fallback = PenMarkGeometry.defaultInk(for: mark.mark.kind).token
        func foreground() -> UIColor {
            let storage = textView.textStorage
            guard mark.range.location < storage.length else { return .label }
            return storage.attribute(.foregroundColor, at: mark.range.location, effectiveRange: nil) as? UIColor ?? .label
        }
        switch mark.mark.color ?? fallback {
        case "foreground": return foreground()
        case "accent": return textView.tintColor ?? .systemRed
        case let token:
            if let color = MarkdownPenInk.color(token) { return UIColor(color) }
            if fallback == "foreground" { return foreground() }
            return MarkdownPenInk.color(fallback).map(UIColor.init) ?? .label
        }
    }
}
#endif
