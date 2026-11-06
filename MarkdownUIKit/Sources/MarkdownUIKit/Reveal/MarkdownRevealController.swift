//
//  MarkdownRevealController.swift
//  MarkdownUIKit
//
//  Character by character reveal on a text view. It's MarkdownView's RevealCoordinator with no
//  SwiftUI in it, and for the same reasons:
//
//   - It's the text layout manager's delegate, so every layout fragment is a
//     MarkdownRevealFragment, whose draw goes by the frontier and each character's first-seen time.
//   - A display link asks only for a redraw each frame. No relayout, the storage isn't touched:
//     streaming's incremental edits work as they do without a reveal, and layout stays apart
//     from drawing.
//   - Colours aren't copied anywhere. A fragment draws the text's own dynamic colours under a
//     clip and an alpha, so a theme changing mid-reveal repaints it as it does any text.
//
//  Fragments draw on the main thread and read a snapshot the tick writes, also on the main
//  thread: no crossing of threads.
//

import FlooUIKit
import MarkdownCore
import RichTextCore
import UIKit

@MainActor
final class MarkdownRevealController: NSObject, NSTextLayoutManagerDelegate {
    private weak var textView: InlineAttachmentTextView?
    private var displayLink: CADisplayLink?
    private var listenerID: UUID?
    private var manager: StreamingRevealManager?
    private var style: MarkdownRevealStyle?
    private var lastAdvance = MarkdownRevealClock.now

    // What a fragment's draw reads.
    nonisolated(unsafe) fileprivate var isActive = false
    nonisolated(unsafe) fileprivate var snapFrontier = 0
    nonisolated(unsafe) fileprivate var snapManager: StreamingRevealManager?
    nonisolated(unsafe) fileprivate var snapDuration = 0.0
    nonisolated(unsafe) fileprivate var snapColorDelay = 0.0
    nonisolated(unsafe) fileprivate var snapColorDuration = 0.0
    nonisolated(unsafe) fileprivate var snapColorSettle = 0.0
    nonisolated(unsafe) fileprivate var snapOverlay: CGFloat = 0.5
    nonisolated(unsafe) fileprivate var snapTint: CGColor = UIColor.clear.cgColor

    // Each character's first-seen time. Stamped once as it first crosses the frontier and frozen:
    // whatever the manager does afterwards (finishReveal jumping to Int.max, growth rewinding it,
    // a completion stamp covering the whole block), a stamped character keeps its own timing and
    // the block doesn't fade in as one. A draw only reads this; `advanceFirstSeen` writes it.
    nonisolated(unsafe) fileprivate var firstSeen: [Date?] = []
    nonisolated(unsafe) fileprivate var firstSeenInitialized = false
    private var stampedFrontier = 0

    /// Storage to plain, by UTF-16 unit, never decreasing. The builder's map goes by Character,
    /// but a fragment and the content manager's offsets go by UTF-16. Not expanded, an emoji (1
    /// Character, 2 or more units) leaves the frontier forever short of a fragment's end and a
    /// block's end never draws. A Character's units share one plain start, so the frontier falls
    /// on Character boundaries.
    nonisolated(unsafe) fileprivate var storageToPlain: [Int] = []
    /// The frontier never goes back on screen. A remap shrinking (a formula closing) pulls the
    /// manager's count back to rescan, but what shows stays; this only goes forward. Int.max,
    /// a passing bounce of the stream, doesn't enter it.
    private var latchedPlainFrontier = 0
    /// Attachments already shown: rebuilt text brings new views for them, which don't fade again.
    private var shownAttachments: Set<AnyHashable> = []

    private static func expandToUTF16(_ map: [Int], string: String) -> [Int] {
        // No surrogate pairs or combining sequences: the map as it is.
        let utf16Count = string.utf16.count
        guard utf16Count != string.count else { return map }
        var out: [Int] = []
        out.reserveCapacity(utf16Count)
        var index = 0
        for character in string {
            let plain = index < map.count ? map[index] : (map.last ?? 0)
            for _ in 0..<character.utf16.count { out.append(plain) }
            index += 1
        }
        return out
    }

    /// Storage character i is revealed when storageToPlain[i] < frontier.
    private func storageFrontier(fromPlain frontier: Int) -> Int {
        if frontier == Int.max { return Int.max }
        if frontier <= 0 { return 0 }
        var low = 0, high = storageToPlain.count
        while low < high {
            let mid = (low + high) / 2
            if storageToPlain[mid] < frontier { low = mid + 1 } else { high = mid }
        }
        return low
    }

    nonisolated fileprivate func plainIndex(forStorage index: Int) -> Int {
        index >= 0 && index < storageToPlain.count ? storageToPlain[index] : index
    }

    /// Whether the manager's count has passed all of a storage range.
    func isRevealed(storageRange range: NSRange) -> Bool {
        guard let manager, range.length > 0 else { return true }
        return manager.revealedCount >= plainIndex(forStorage: NSMaxRange(range) - 1) + 1
    }

    // MARK: Attaching

    /// Before the text goes in: a fragment made before this draws everything at once.
    func attach(_ textView: InlineAttachmentTextView, reveal: MarkdownReveal, storageToPlain map: [Int]) {
        // Another manager (an empty block's was pruned and rebuilt): timings start over.
        if manager !== reveal.manager {
            if let listenerID { manager?.removeListener(listenerID) }
            listenerID = nil
            firstSeen.removeAll()
            firstSeenInitialized = false
            stampedFrontier = 0
            latchedPlainFrontier = 0
            shownAttachments.removeAll()
        }
        self.textView = textView
        manager = reveal.manager
        style = reveal.style
        storageToPlain = Self.expandToUTF16(map, string: textView.textStorage.string)
        // The clock starts again: a manager that's finished sends nothing, and an old time would
        // stop the first tick with characters frozen half way.
        lastAdvance = MarkdownRevealClock.now
        isActive = true
        let isSet = textView.textLayoutManager?.delegate === self
        textView.textLayoutManager?.delegate = self
        // What was laid out before has plain fragments.
        if !isSet, textView.textStorage.length > 0, let manager = textView.textLayoutManager {
            manager.invalidateLayout(for: manager.documentRange)
        }
        updateSnapshot()
        if listenerID == nil {
            listenerID = reveal.manager.addListener { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastAdvance = MarkdownRevealClock.now
                    self?.start()
                }
            }
        }
        textView.setNeedsDisplay()
        start()
    }

    /// Everything shows at once from here, with no relayout: a fragment draws plainly when
    /// nothing is active.
    func detach() {
        stop()
        if let listenerID { manager?.removeListener(listenerID) }
        listenerID = nil
        manager = nil
        snapManager = nil
        isActive = false
        for view in textView?.inlineAttachmentsByID.values.map(\.contentView) ?? [] { view.alpha = 1 }
        textView?.setNeedsDisplay()
    }

    /// In the same frame as a content change: nothing shows a frame of the new text undrawn, or of
    /// old timing on characters that moved.
    func contentDidChange(storageToPlain map: [Int]) {
        guard let textView, isActive else { return }
        // Past the first difference between the maps a storage index means another character (a
        // formula closing makes 28 literal characters into 1 attachment; what's after moves into
        // their indexes). Their stamps are the old characters', long settled, and would show the
        // new text solid with no fade. They're dropped, and go by the manager's stamps again.
        let old = storageToPlain
        storageToPlain = Self.expandToUTF16(map, string: textView.textStorage.string)
        var common = 0
        let shared = min(old.count, storageToPlain.count)
        while common < shared, old[common] == storageToPlain[common] { common += 1 }
        if common < old.count {
            if common < firstSeen.count {
                for index in common..<firstSeen.count { firstSeen[index] = nil }
            }
            stampedFrontier = min(stampedFrontier, common)
        }
        if storageToPlain.count < firstSeen.count {
            firstSeen.removeLast(firstSeen.count - storageToPlain.count)
        }
        updateSnapshot()
        textView.setNeedsDisplay()
        start()
    }

    // MARK: A frame

    private func updateSnapshot() {
        guard let manager, let style else { return }
        // A fragment draws in storage indexes; what shows follows the latch.
        let count = manager.revealedCount
        if count == Int.max {
            snapFrontier = Int.max
        } else {
            latchedPlainFrontier = max(latchedPlainFrontier, count)
            snapFrontier = storageFrontier(fromPlain: latchedPlainFrontier)
        }
        snapManager = manager
        let duration = manager.adaptiveFadeDuration(baseDuration: style.motion.duration)
        snapDuration = duration
        snapColorDelay = style.delay
        snapColorDuration = duration * MarkdownRevealStyle.colorDurationMultiplier
        snapColorSettle = snapColorDelay + snapColorDuration
        let traits = textView?.traitCollection ?? UITraitCollection.current
        snapOverlay = traits.userInterfaceStyle == .dark ? 0.35 : 0.5
        snapTint = tint(style.highlight, traits: traits, now: MarkdownRevealClock.now).cgColor
        advanceFirstSeen(frontier: snapFrontier, manager: manager)
        updateAttachments(frontier: snapFrontier, manager: manager, duration: duration)
    }

    /// Stamps what the frontier passed: the manager's time, else now. Stamped once, so the
    /// manager stamping a whole block with one completion time later changes nothing here.
    /// The frontier is the latched one; a bounce to Int.max stamps nothing, so it can't make a
    /// character skip its fade once the frontier is back.
    private func advanceFirstSeen(frontier: Int, manager: StreamingRevealManager) {
        guard frontier != Int.max else { return }
        let length = currentTextLength()
        // An empty text isn't "initialized": attach runs before content comes. If it counted,
        // characters with no stamp in the first real frame would fade from now.
        guard length > 0 else { return }
        if firstSeen.count < length {
            firstSeen.append(contentsOf: repeatElement(nil, count: length - firstSeen.count))
        }
        let now = MarkdownRevealClock.now
        let upper = min(frontier, firstSeen.count)
        if upper > stampedFrontier {
            for index in stampedFrontier..<upper where firstSeen[index] == nil {
                let stamp = manager.firstSeenTimestamp(at: plainIndex(forStorage: index))
                // One already past its fade isn't kept: it draws solid anyway, and may be a stale
                // stamp from an Int.max moment, which the manager will stamp afresh after a rewind.
                let settled = stamp.map { now.timeIntervalSince($0) >= snapColorSettle } ?? false
                if !settled {
                    let kept = stamp ?? (firstSeenInitialized ? now : .distantPast)
                    firstSeen[index] = kept
                    // It still has its fade to draw: the display link lives until then, as a
                    // finished manager sends nothing more.
                    if kept > .distantPast { lastAdvance = max(lastAdvance, kept) }
                }
            }
            stampedFrontier = upper
        }
        firstSeenInitialized = true
    }

    /// An attachment appears whole, once the frontier passes it. It's a view of its own, out of
    /// reach of a fragment's alpha.
    private func updateAttachments(frontier: Int, manager: StreamingRevealManager, duration: TimeInterval) {
        guard let textView, !textView.inlineAttachmentRangesByID.isEmpty, let style else { return }
        for (id, range) in textView.inlineAttachmentRangesByID {
            guard let attachment = textView.inlineAttachmentsByID[id] else { continue }
            let view = attachment.contentView
            let reached = frontier == Int.max || frontier > range.location
            guard reached else {
                view.alpha = 0
                continue
            }
            if shownAttachments.contains(id) {
                // Already shown, in this view or the one before it in rebuilt text. One in a fade
                // is left to finish.
                if view.alpha == 0 { view.alpha = 1 }
                continue
            }
            shownAttachments.insert(id)
            let stamp = manager.firstSeenTimestamp(at: plainIndex(forStorage: range.location))
            guard frontier != Int.max, MarkdownRevealGate.isFresh(stamp) else {
                view.alpha = 1
                continue
            }
            view.alpha = 0
            var motion = style.motion
            motion.duration = duration
            motion.animate { view.alpha = 1 }
        }
    }

    private func currentTextLength() -> Int {
        textView?.textStorage.length ?? firstSeen.count
    }

    /// When a fade starts for a character in storage indexes: its frozen stamp, else the manager's
    /// (settled, or past the end), else long ago, drawn solid.
    nonisolated fileprivate func stampedTimestamp(at index: Int, now: Date) -> Date {
        if index >= 0, index < firstSeen.count, let stamp = firstSeen[index] { return stamp }
        let stamp = snapManager?.firstSeenTimestamp(at: plainIndex(forStorage: index))
        return stamp ?? (firstSeenInitialized ? now : .distantPast)
    }

    // MARK: NSTextLayoutManagerDelegate

    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = MarkdownRevealFragment(textElement: textElement, range: textElement.elementRange)
        fragment.owner = self
        return fragment
    }

    // MARK: Driving

    private func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Invalidated, not paused: a link holds its target, and rows come and go.
    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleTick() {
        guard let textView else {
            stop()
            return
        }
        updateSnapshot()
        textView.setNeedsDisplay()
        // Nothing new, and the last characters are past their fade: all's still, the link stops.
        if MarkdownRevealClock.now.timeIntervalSince(lastAdvance) > snapColorSettle + 0.15 { stop() }
    }

    // MARK: The tint

    private func tint(_ highlight: MarkdownRevealStyle.Highlight, traits: UITraitCollection, now: Date) -> UIColor {
        switch highlight {
        case .color(let color):
            return color.resolvedColor(with: traits)
        case .hues(let startHue, let endHue, let saturation, let brightness):
            guard !traits.flooTheme.sets(.markdownRevealHighlight) else {
                return UIColor.floo(.markdownRevealHighlight).resolvedColor(with: traits)
            }
            let start = normalizedHue(startHue)
            let span = normalizedHue(endHue - start)
            let cycle = FlooMotion.markdownRevealHue.duration
            let progress = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            let wave = (1 - cos(progress * 2 * .pi)) * 0.5
            return UIColor(hue: normalizedHue(start + wave * span), saturation: saturation, brightness: brightness, alpha: 1)
        }
    }

    private func normalizedHue(_ hue: Double) -> Double {
        let value = hue.truncatingRemainder(dividingBy: 1)
        return value >= 0 ? value : value + 1
    }
}

// MARK: - The fragment

final class MarkdownRevealFragment: NSTextLayoutFragment {
    nonisolated(unsafe) weak var owner: MarkdownRevealController?

    override func draw(at renderingOrigin: CGPoint, in ctx: CGContext) {
        guard let owner, owner.isActive,
              let manager = textLayoutManager,
              let contentManager = manager.textContentManager else {
            super.draw(at: renderingOrigin, in: ctx)
            return
        }

        let frontier = owner.snapFrontier
        let documentStart = contentManager.documentRange.location
        let fragmentStart = contentManager.offset(from: documentStart, to: rangeInElement.location)
        let fragmentEnd = contentManager.offset(from: documentStart, to: rangeInElement.endLocation)

        // Int.max, the finished sentinel, comes to fragmentEnd.
        let revealedEnd = min(frontier, fragmentEnd)
        guard revealedEnd > fragmentStart else { return }

        let fragmentOrigin = layoutFragmentFrame.origin
        func toLocal(_ rect: CGRect) -> CGRect {
            CGRect(
                x: renderingOrigin.x + rect.origin.x - fragmentOrigin.x,
                y: renderingOrigin.y + rect.origin.y - fragmentOrigin.y,
                width: rect.width,
                height: rect.height
            )
        }
        func segmentRects(_ from: Int, _ to: Int) -> [CGRect] {
            guard from < to,
                  let start = contentManager.location(documentStart, offsetBy: from),
                  let end = contentManager.location(documentStart, offsetBy: to),
                  let range = NSTextRange(location: start, end: end) else { return [] }
            var rects: [CGRect] = []
            manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                rects.append(toLocal(frame))
                return true
            }
            return rects
        }

        let revealedRects = revealedEnd >= fragmentEnd
            ? [CGRect(origin: renderingOrigin, size: layoutFragmentFrame.size)]
            : segmentRects(fragmentStart, revealedEnd)
        guard !revealedRects.isEmpty else { return }

        let now = MarkdownRevealClock.now
        let duration = owner.snapDuration
        let settle = owner.snapColorSettle
        let colorDelay = owner.snapColorDelay
        let colorDuration = owner.snapColorDuration
        let overlay = owner.snapOverlay
        // Opacity follows age over the duration; the tint's strength is (1 - colourPhase) × overlay.
        // Colour takes 1.8 × as long, so the tint trails the opacity.
        func phase(_ index: Int) -> CGFloat {
            let age = now.timeIntervalSince(owner.stampedTimestamp(at: index, now: now))
            return duration > 0 ? CGFloat(max(0, min(1, age / duration))) : 1
        }
        func tintStrength(_ index: Int) -> CGFloat {
            let age = now.timeIntervalSince(owner.stampedTimestamp(at: index, now: now))
            let colorAge = max(0, age - colorDelay)
            let colorPhase = colorDuration > 0 ? max(0, min(1, colorAge / colorDuration)) : (age >= colorDelay ? 1 : 0)
            return (1 - CGFloat(colorPhase)) * overlay
        }

        // Two windows, apart. Opacity's holds only characters truly still fading (age < duration),
        // never ones already opaque: a shared 2-stop gradient would make those half clear and pop
        // back, the flash at the end. The tint's is longer and trails. 24 settled characters in a
        // row end the scan.
        var opacityStart = revealedEnd
        var tintStart = revealedEnd
        var scan = revealedEnd - 1
        var run = 0
        while scan >= fragmentStart, run < 24 {
            let age = now.timeIntervalSince(owner.stampedTimestamp(at: scan, now: now))
            if age < settle {
                tintStart = scan
                if age < duration { opacityStart = scan }
                run = 0
            } else {
                run += 1
            }
            scan -= 1
        }

        // All settled: solid, the fast way.
        if tintStart >= revealedEnd {
            ctx.saveGState()
            ctx.clip(to: revealedRects)
            super.draw(at: renderingOrigin, in: ctx)
            ctx.restoreGState()
            return
        }

        // Opacity by plain alpha, character by character, whatever the colour. A mask would take
        // grey content (a marker, inline code's ground) for black or white. The window is small,
        // so this costs little.
        let solidRects = segmentRects(fragmentStart, opacityStart)
        if !solidRects.isEmpty {
            ctx.saveGState()
            ctx.clip(to: solidRects)
            super.draw(at: renderingOrigin, in: ctx)
            ctx.restoreGState()
        }
        if opacityStart < revealedEnd {
            for index in opacityStart..<revealedEnd {
                let alpha = phase(index)
                guard alpha > 0.001 else { continue }
                let rects = segmentRects(index, index + 1)
                guard !rects.isEmpty else { continue }
                ctx.saveGState()
                ctx.clip(to: rects)
                if alpha < 1 { ctx.setAlpha(alpha) }
                super.draw(at: renderingOrigin, in: ctx)
                ctx.restoreGState()
            }
        }

        // The tint: source-atop, character by character, so it's scaled once more by what's drawn
        // there. A gradient over a line would tint settled characters between its ends too.
        // Attachments are never tinted.
        if tintStart < revealedEnd {
            let storage = (contentManager as? NSTextContentStorage)?.textStorage
            let tint = owner.snapTint
            for index in tintStart..<revealedEnd {
                let strength = tintStrength(index)
                guard strength > 0.001 else { continue }
                if let storage, index < storage.length,
                   storage.attribute(.attachment, at: index, effectiveRange: nil) != nil {
                    continue
                }
                let rects = segmentRects(index, index + 1)
                guard !rects.isEmpty, let color = tint.copy(alpha: strength) else { continue }
                ctx.saveGState()
                ctx.clip(to: rects)
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(color)
                for rect in rects { ctx.fill(rect) }
                ctx.restoreGState()
            }
        }
    }
}
