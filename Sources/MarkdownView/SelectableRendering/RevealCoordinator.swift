//
//  RevealCoordinator.swift
//  MarkdownView
//
//  逐字 reveal:完整移植 SwiftUI 的 RevealFadeRenderer(TextRenderer)到 UITextView(TextKit 2)。
//  二者同底层(Core Text glyph 绘制)。做法:
//   - coordinator 作 NSTextLayoutManagerDelegate,把每个 layout fragment 换成 RevealFadeFragment;
//   - RevealFadeFragment.draw 里逐 glyph 复刻 RevealFadeRenderer:按字符位置 vs revealedCount 决定
//     不画/淡入/定型,淡入用 opacity phase + tint overlay,firstSeen 从 manager 读、draw 时现算 age;
//   - CADisplayLink 每帧 setNeedsDisplay() —— 只重绘(redraw)、不 relayout、不碰 textStorage。
//  因此:3.0 stream 增量原样生效,渲染与布局彻底分离,60fps 逐字淡入。
//
//  并发:coordinator 在主线程 tick 更新一份 nonisolated(unsafe) 快照(frontier/fade/tint),
//  fragment.draw 也在主线程(TextKit 2 绘制),只读快照 + manager.firstSeenTimestamp(nonisolated) —— 无跨线程。
//

#if canImport(RichText) && canImport(UIKit)
import UIKit
import SwiftUI
import RichText
import CoreText

@available(iOS 17.0, *)
@MainActor
final class RevealCoordinator: NSObject, NSTextLayoutManagerDelegate {
    private weak var textView: PlatformTextView?
    private var displayLink: CADisplayLink?
    private var listenerID: UUID?
    private var manager: StreamingRevealManager?
    private var fade: MarkdownFadeRevealConfig?
    private var colorScheme: ColorScheme = .light
    private var lastAdvance = Date()

    // fragment.draw 读的快照:tick 在主线程写,draw 也在主线程读,故 nonisolated(unsafe) 安全。
    nonisolated(unsafe) fileprivate var snapFrontier = 0
    nonisolated(unsafe) fileprivate var snapManager: StreamingRevealManager?
    nonisolated(unsafe) fileprivate var snapDuration = 0.0
    nonisolated(unsafe) fileprivate var snapColorDelay = 0.0
    nonisolated(unsafe) fileprivate var snapColorDuration = 0.0
    nonisolated(unsafe) fileprivate var snapColorSettle = 0.0
    nonisolated(unsafe) fileprivate var snapOverlay: CGFloat = 0.5
    nonisolated(unsafe) fileprivate var snapTint: UIColor = .clear

    // ===== per-glyph 首见时间戳缓存(镜像原版 RevealFadeRenderer.FadeState.firstSeen)=====
    // 每个字第一次越过 frontier 被画成"已揭示"时,把它此刻的戳冻结进来;此后无论 manager 怎么变
    //(finishReveal 把 revealedCount 跳 Int.max、内容增长又 rewind、completionTimestamp 覆盖整段…),
    // 已冻结的字都保持自己的 fade 时序 → 不会被"整段同一个 completionTimestamp"重定时成一起淡入(= 直接到完成态)。
    // fragment.draw 只读它;推进/回退在主线程 advanceFirstSeen() 里写。
    nonisolated(unsafe) fileprivate var firstSeen: [Date?] = []
    nonisolated(unsafe) fileprivate var firstSeenInitialized = false
    private var stampedFrontier = 0

    /// storage↔plain 坐标映射(storageToPlain[i] = 第 i 个 textStorage 字符的 plain 单位起点,非降)。
    /// manager.revealedCount / firstSeenTimestamp 都在 plain 坐标系(app normalize 后占位符 11 单位、
    /// marker 0 单位),fragment 绘制在 textStorage 坐标系 —— 全部经此映射换算,不能直接混用。
    nonisolated(unsafe) fileprivate var storageToPlain: [Int] = []

    /// plain frontier → storage frontier:storage 字符 i 已揭示 ⇔ storageToPlain[i] < frontier(二分)。
    nonisolated fileprivate func storageFrontier(fromPlain frontier: Int) -> Int {
        if frontier == Int.max { return Int.max }
        if frontier <= 0 { return 0 }
        var lo = 0, hi = storageToPlain.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if storageToPlain[mid] < frontier { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    nonisolated fileprivate func plainIndex(forStorage index: Int) -> Int {
        index >= 0 && index < storageToPlain.count ? storageToPlain[index] : index
    }

    /// 绘制前沿的单调 latch(plain 坐标):remap 收缩(公式闭合等)会把 manager.revealedCount 回拉重扫,
    /// 但**已展示内容不回退**(对齐原版可见行为)——重扫期间画面保持,latch 只随 rc 前进。
    /// Int.max 瞬态(流式 bounce)不折进 latch:bounce 帧全量绘制,rewind 后回到 latch 前沿。
    private var latchedPlainFrontier = 0

    func attach(
        _ textView: PlatformTextView,
        manager: StreamingRevealManager,
        fade: MarkdownFadeRevealConfig,
        colorScheme: ColorScheme,
        storageToPlain: [Int]
    ) {
        // 换了 manager(空块被修剪后重建/cell 复用)→ 换监听 + 冻结缓存作废,重新逐字。
        if self.manager !== manager {
            if let id = listenerID { self.manager?.removeListener(id); listenerID = nil }
            firstSeen.removeAll()
            firstSeenInitialized = false
            stampedFrontier = 0
            latchedPlainFrontier = 0
        }
        self.textView = textView
        self.manager = manager
        self.fade = fade
        self.colorScheme = colorScheme
        self.storageToPlain = storageToPlain
        textView.textLayoutManager?.delegate = self
        updateSnapshot()
        subscribe(to: manager)
        textView.setNeedsDisplay()
        start()
    }

    /// manager 实例更换但 textView/内容未变(空块 manager 被 sync 修剪后随正文重建)时的显式重绑。
    /// attach 只在 textView 创建时经 onRichTextViewReady 触发一次 —— textView 若恰在死 manager
    /// 窗口期创建,coordinator 会永远订着 rc=0 的死 manager → 整块不显示。由 view 的 onChange 调这里。
    func rebind(manager: StreamingRevealManager, fade: MarkdownFadeRevealConfig, colorScheme: ColorScheme) {
        guard let textView else { return }
        attach(
            textView,
            manager: manager,
            fade: fade,
            colorScheme: colorScheme,
            storageToPlain: storageToPlain
        )
    }

    func detach() {
        stop()
        if let tlm = textView?.textLayoutManager, tlm.delegate === self {
            tlm.delegate = nil
        }
        if let id = listenerID { manager?.removeListener(id) }
        listenerID = nil
    }

    func contentDidChange(storageToPlain newMap: [Int]) {
        // splice 检测:映射表首个差异点之后,storage 下标的字符含义已变(公式闭合把 28 个字面字符
        // 拼成 1 个附件,后段文字挪进原字面区的下标)——那里的冻结戳是旧字符的(已 settle),
        // 留着会让新落位的文字被当成定型、直接实心出现(fade 消失)。作废差异区,重按 manager 戳来。
        let oldMap = storageToPlain
        storageToPlain = newMap
        var common = 0
        let n = min(oldMap.count, newMap.count)
        while common < n, oldMap[common] == newMap[common] { common += 1 }
        if common < oldMap.count {  // 非纯 append(splice/收缩)才需要作废
            if common < firstSeen.count {
                for i in common..<firstSeen.count { firstSeen[i] = nil }
            }
            stampedFrontier = min(stampedFrontier, common)
        }
        if newMap.count < firstSeen.count {
            firstSeen.removeLast(firstSeen.count - newMap.count)
        }
        updateSnapshot()
        textView?.setNeedsDisplay()
        start()
    }

    private func updateSnapshot() {
        guard let manager, let fade else { return }
        // fragment 在 textStorage 坐标系绘制 → frontier 先换算;绘制前沿走单调 latch(remap 回拉不回退画面)。
        let rc = manager.revealedCount
        if rc == Int.max {
            snapFrontier = Int.max
        } else {
            latchedPlainFrontier = max(latchedPlainFrontier, rc)
            snapFrontier = storageFrontier(fromPlain: latchedPlainFrontier)
        }
        snapManager = manager
        // 原版 duration 走 adaptiveFadeDuration(reveal 越快 fade 越短);demo scale=1.0 时等于 fade.duration。
        let effectiveDuration = manager.adaptiveFadeDuration(baseDuration: fade.duration)
        snapDuration = effectiveDuration
        snapColorDelay = fade.delay
        snapColorDuration = effectiveDuration * MarkdownFadeRevealConfig.colorDurationMultiplier
        snapColorSettle = snapColorDelay + snapColorDuration
        snapOverlay = colorScheme == .dark ? 0.35 : 0.5
        snapTint = revealTint(now: Date())
        advanceFirstSeen(frontier: snapFrontier, manager: manager)
    }

    /// 冻结 per-glyph 首见戳:frontier 前进时给新越过的字盖戳(优先 manager 的戳,已定型的不缓存)。
    /// 关键:一旦冻结,后续 manager 把整段盖成同一 completionTimestamp 也不会回改已冻结的字 → 不整段同时淡入。
    /// frontier 是**latch 后**的 storage 前沿(单调,remap 回拉不传导);Int.max 瞬态(bounce 帧)不盖戳
    /// 不污染缓存 —— bounce 全量绘制走 manager 戳回退,rewind 后回到 latch 前沿,后续正常逐字。
    private func advanceFirstSeen(frontier: Int, manager: StreamingRevealManager) {
        guard frontier != Int.max else { return }
        let textLen = currentTextLength()
        // 空文档不算「已初始化」:attach 在内容灌入前就会跑一次,若此时置 initialized,
        // 后续真正首帧里 manager 无戳的字符(块尾超出 completionEnd 的 marker 位移段)会被
        // 回退成 now → 重播 fade。对齐原版 FadeState.initialized 语义(首次画过真内容才算)。
        guard textLen > 0 else { return }
        if firstSeen.count < textLen {
            firstSeen.append(contentsOf: Array(repeating: nil, count: textLen - firstSeen.count))
        }
        let now = Date()
        let upper = min(frontier, firstSeen.count)
        if upper > stampedFrontier {
            for i in stampedFrontier..<upper where firstSeen[i] == nil {
                // manager 的戳在 plain 坐标系 → 经映射查询。
                let ms = manager.firstSeenTimestamp(at: plainIndex(forStorage: i))
                // 已过 settle 窗口的 manager 戳不缓存(它们画出来都是定型的,且可能是 Int.max 瞬窗的陈旧戳,
                // rewind 后 manager 会重发新戳——缓存会把陈旧的冻死、永久跳过淡入)。
                let settled = ms.map { now.timeIntervalSince($0) >= snapColorSettle } ?? false
                if !settled { firstSeen[i] = ms ?? (firstSeenInitialized ? now : .distantPast) }
            }
            stampedFrontier = upper
        }
        firstSeenInitialized = true
    }

    private func currentTextLength() -> Int {
        guard let cm = textView?.textLayoutManager?.textContentManager else { return firstSeen.count }
        return cm.offset(from: cm.documentRange.location, to: cm.documentRange.endLocation)
    }

    /// fragment.draw 取某字(textStorage 坐标)的 fade 起点:优先冻结缓存;
    /// 未缓存(定型/越界)按映射查 manager 戳(plain 坐标),再回退 distantPast(画实心)。
    nonisolated fileprivate func stampedTimestamp(at index: Int, now: Date) -> Date {
        if index >= 0, index < firstSeen.count, let s = firstSeen[index] { return s }
        let ms = snapManager?.firstSeenTimestamp(at: plainIndex(forStorage: index))
        return ms ?? (firstSeenInitialized ? now : .distantPast)
    }

    // MARK: - NSTextLayoutManagerDelegate

    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = RevealFadeFragment(textElement: textElement, range: textElement.elementRange)
        fragment.owner = self
        return fragment
    }

    // MARK: - 驱动

    private func subscribe(to manager: StreamingRevealManager) {
        guard listenerID == nil else { return }
        listenerID = manager.addListener { [weak self] _ in
            self?.lastAdvance = Date()
            self?.start()
        }
    }

    private func start() {
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(handleTick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func stop() {
        displayLink?.isPaused = true
    }

    @objc private func handleTick() {
        guard let textView else { stop(); return }
        updateSnapshot()  // 刷新 frontier + tint(hue 随时间)+ settle 窗口
        textView.setNeedsDisplay()
        // reveal 停止推进且最后一批字符都过了 settle 窗口 → 全定型,停 CADisplayLink 省电。
        if Date().timeIntervalSince(lastAdvance) > snapColorSettle + 0.15 { stop() }
    }

    // MARK: - reveal tint(复刻 RevealFadeRenderer 的 hue cycle)

    private func revealTint(now: Date) -> UIColor {
        guard let fade else { return .clear }
        if let startHue = fade.highlightStartHue, let endHue = fade.highlightEndHue {
            let start = normalizedHue(startHue)
            let span = normalizedHue(endHue - start)
            let cycle = 8.0
            let progress = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            let wave = (1 - cos(progress * 2 * .pi)) * 0.5
            return UIColor(hue: normalizedHue(start + wave * span), saturation: fade.hueSaturation, brightness: fade.hueBrightness, alpha: 1)
        }
        if let startHue = fade.highlightStartHue {
            return UIColor(hue: normalizedHue(startHue), saturation: fade.hueSaturation, brightness: fade.hueBrightness, alpha: 1)
        }
        return UIColor(fade.highlightColor ?? .accentColor)
    }

    private func normalizedHue(_ hue: Double) -> Double {
        let n = hue.truncatingRemainder(dividingBy: 1)
        return n >= 0 ? n : n + 1
    }
}

// MARK: - 自定义 layout fragment:逐 glyph reveal 绘制

@available(iOS 17.0, *)
final class RevealFadeFragment: NSTextLayoutFragment {
    nonisolated(unsafe) weak var owner: RevealCoordinator?

    override func draw(at renderingOrigin: CGPoint, in ctx: CGContext) {
        guard let owner,
              let tlm = textLayoutManager,
              let contentManager = tlm.textContentManager else {
            super.draw(at: renderingOrigin, in: ctx)
            return
        }

        let frontier = owner.snapFrontier  // = manager.revealedCount(原版接口,textStorage 字符数)
        let docStart = contentManager.documentRange.location
        let fragmentStart = contentManager.offset(from: docStart, to: rangeInElement.location)
        let fragmentEnd = contentManager.offset(from: docStart, to: rangeInElement.endLocation)

        let revealedEnd = min(frontier, fragmentEnd)  // Int.max(完成哨兵)时 = fragmentEnd
        guard revealedEnd > fragmentStart else { return }  // 整段未揭示 → 不画

        // 逐字淡入用「灰度渐变遮罩裁剪 super.draw」实现(色彩无关、一次画到位、不闪)。
        let fragOrigin = layoutFragmentFrame.origin
        func toLocal(_ r: CGRect) -> CGRect {
            CGRect(x: renderingOrigin.x + r.origin.x - fragOrigin.x,
                   y: renderingOrigin.y + r.origin.y - fragOrigin.y,
                   width: r.width, height: r.height)
        }
        func segmentRects(_ from: Int, _ to: Int) -> [CGRect] {
            guard from < to,
                  let s = contentManager.location(docStart, offsetBy: from),
                  let e = contentManager.location(docStart, offsetBy: to),
                  let range = NSTextRange(location: s, end: e) else { return [] }
            var out: [CGRect] = []
            tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                out.append(toLocal(frame)); return true
            }
            return out
        }

        let revealedRects: [CGRect]
        if revealedEnd >= fragmentEnd {
            revealedRects = [CGRect(origin: renderingOrigin, size: layoutFragmentFrame.size)]
        } else {
            revealedRects = segmentRects(fragmentStart, revealedEnd)
        }
        guard !revealedRects.isEmpty else { return }

        let now = Date()
        let duration = owner.snapDuration
        let settle = owner.snapColorSettle
        let colorDelay = owner.snapColorDelay
        let colorDuration = owner.snapColorDuration
        let overlay = owner.snapOverlay
        let tint = owner.snapTint
        // 逐字复刻原版 RevealFadeRenderer:opacity=phase(age/duration),tint 浓度=(1-colorPhase)*overlay
        //(colorPhase=colorAge/colorDuration,colorDuration=duration×1.8,故 tint 比 opacity 退得慢、有拖尾)。
        func phase(_ c: Int) -> CGFloat {
            let age = now.timeIntervalSince(owner.stampedTimestamp(at: c, now: now))
            return duration > 0 ? CGFloat(max(0, min(1, age / duration))) : 1
        }
        func tintConc(_ c: Int) -> CGFloat {
            let age = now.timeIntervalSince(owner.stampedTimestamp(at: c, now: now))
            let colorAge = max(0, age - colorDelay)
            let cp = colorDuration > 0 ? max(0, min(1, colorAge / colorDuration)) : (age >= colorDelay ? 1 : 0)
            return (1 - CGFloat(cp)) * overlay
        }

        // 两个独立窗口(关键:opacity 窗口只装「真在淡入(age<duration)」的字,绝不含已到不透明的字 → 不会被 2-stop 线性
        // 插成半透明再啪地弹回 = 末尾闪的根因)。tint 用更长的 settle 窗口,天然拖尾。容忍 24 个连续已定型/无戳字符。
        var opacityStart = revealedEnd  // 最左「age<duration」字:[opacityStart, revealedEnd) 才需 opacity 遮罩,之前全不透明
        var tintStart = revealedEnd     // 最左「age<settle」字:[tintStart, revealedEnd) 有 tint 高光
        do {
            var scan = revealedEnd - 1
            var run = 0
            while scan >= fragmentStart, run < 24 {
                let age = now.timeIntervalSince(owner.stampedTimestamp(at: scan, now: now))
                if age < settle {
                    tintStart = scan
                    if age < duration { opacityStart = scan }
                    run = 0
                } else { run += 1 }
                scan -= 1
            }
        }

        // 全部已定型(无 tint 无 opacity 淡入)→ 实心快路径。
        if tintStart >= revealedEnd {
            ctx.saveGState(); ctx.clip(to: revealedRects); super.draw(at: renderingOrigin, in: ctx); ctx.restoreGState()
            return
        }

        // ① opacity:[fragmentStart, opacityStart) 已定型 → 实心一次画;[opacityStart, revealedEnd) 淡入窗 → **逐字** setAlpha(phase)。
        // 关键:用 setAlpha(纯 alpha 缩放,与颜色无关)复刻原版 `outer.opacity = phase; outer.draw(glyph)`,
        // 而不是灰度渐变遮罩——遮罩会把灰色内容(灰 marker / inline code 灰底)误当黑/白处理。淡入窗很小,逐字成本可控。
        let solidRects = segmentRects(fragmentStart, opacityStart)
        if !solidRects.isEmpty {
            ctx.saveGState(); ctx.clip(to: solidRects); super.draw(at: renderingOrigin, in: ctx); ctx.restoreGState()
        }
        if opacityStart < revealedEnd {
            for c in opacityStart..<revealedEnd {
                let p = phase(c)
                guard p > 0.001 else { continue }
                let rects = segmentRects(c, c + 1)
                guard !rects.isEmpty else { continue }
                ctx.saveGState()
                ctx.clip(to: rects)
                if p < 1 { ctx.setAlpha(p) }
                super.draw(at: renderingOrigin, in: ctx)
                ctx.restoreGState()
            }
        }

        // ② tint:[tintStart, revealedEnd) **逐字** sourceAtop 填色 —— 浓度=原版逐 glyph 精确公式
        // (1-colorPhase)×overlay,sourceAtop 按该字已画像素 alpha(=phase)再衰减一次 → phase×(1-cp)×overlay。
        // 不用整行 2-stop 渐变:端点线性插值会把窗口中间早已定型的字(含反扫容忍的定型段)也染上
        // 中间浓度 → tint 带比原版宽、过于明显。附件字符(勾选框/公式 ￼)跳过 —— 原版从不 tint 附件。
        if tintStart < revealedEnd {
            let storage = (contentManager as? NSTextContentStorage)?.textStorage
            for c in tintStart..<revealedEnd {
                let conc = tintConc(c)
                guard conc > 0.001 else { continue }
                if let storage, c < storage.length,
                   storage.attribute(.attachment, at: c, effectiveRange: nil) != nil {
                    continue
                }
                let rects = segmentRects(c, c + 1)
                guard !rects.isEmpty else { continue }
                ctx.saveGState()
                ctx.clip(to: rects)
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(tint.withAlphaComponent(conc).cgColor)
                for r in rects { ctx.fill(r) }
                ctx.restoreGState()
            }
        }
    }

}

#endif
