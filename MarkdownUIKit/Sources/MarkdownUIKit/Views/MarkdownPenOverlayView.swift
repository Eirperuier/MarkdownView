//
//  MarkdownPenOverlayView.swift
//  MarkdownUIKit
//
//  Pen marks over a text view (`:circle[…]`, `:marker[…]`, `:u[…]`…). The text itself stays the
//  text view's, for selection and reveal; marks go on two clear views: the highlighter under
//  the text, the rest over it. By the pen attribute's ranges, each line's frame and baseline
//  from TextKit 2 go to PenMarkGeometry, the same geometry every path uses.
//

import FlooUIKit
import MarkdownCore
import RichTextCore
import UIKit

extension FlooMotion {
    /// A pen mark appearing as the reveal reaches its last character.
    static let markdownPenReveal = FlooMotion(duration: 0.35, curve: .linear, reduced: .same)
}

@MainActor
final class MarkdownPenOverlayView: UIView {
    struct Mark {
        let range: NSRange
        /// With a seed from its content: the same words get the same stroke.
        let mark: MarkdownPenMarkSyntax.Mark
    }

    /// Which this layer draws: true the highlighter (under the text), false the rest (over it).
    private var isUnderlay = false
    private weak var textView: UITextView?
    private var marks: [Mark] = []
    /// Whether a mark's whole range is revealed; nil: there's no reveal, all of it is.
    private var isRevealed: (@MainActor (NSRange) -> Bool)?
    /// When each mark, by its range's start, first showed: what its fade goes by.
    private var revealStamps: [Int: Date] = [:]
    private var displayLink: CADisplayLink?

    /// How far a stroke leaves the text's frame (PenMarkGeometry.overhang and a little): the
    /// overlay is that much larger each way, and the text view stops clipping (it's a scroll
    /// view, which clips by default; these don't scroll, so that's safe).
    private static let overhang: CGFloat = PenMarkGeometry.overhang + 2

    /// After a text view's content changes: scans for pen attributes, adds or refreshes the two
    /// layers where there are any, removes them where not.
    static func sync(on textView: UITextView, isRevealed: (@MainActor (NSRange) -> Bool)? = nil) {
        let marks = Self.marks(in: textView.textStorage)
        let existing = textView.subviews.compactMap { $0 as? MarkdownPenOverlayView }
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
            let overlay = current ?? make(isUnderlay: isUnderlay, on: textView)
            overlay.frame = textView.bounds.insetBy(dx: -overhang, dy: -overhang)
            overlay.textView = textView
            overlay.marks = layerMarks
            overlay.isRevealed = isRevealed
            overlay.setNeedsDisplay()
            overlay.updateDisplayLink()
        }
        textView.clipsToBounds = false
    }

    /// The pen marks in a text, by their ranges.
    nonisolated static func marks(in text: NSAttributedString) -> [Mark] {
        var marks: [Mark] = []
        text.enumerateAttribute(.richTextPenMark, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let raw = value as? String,
                  let decoded = MarkdownPenMarkSyntax.decodeAttributeValue(raw) else { return }
            marks.append(Mark(range: range, mark: decoded))
        }
        return marks
    }

    /// Draws marks, the highlighter's (`isUnderlay`) or the rest, for text laid out by `manager`
    /// whose layout's origin is at `origin` in `context`. On any thread; colours resolve under
    /// the current traits.
    nonisolated static func draw(_ marks: [Mark], isUnderlay: Bool, text: NSAttributedString, manager: NSTextLayoutManager, origin: CGPoint, in context: CGContext, alpha: (Mark) -> CGFloat = { _ in 1 }) {
        for mark in marks where mark.mark.kind.isUnderlay == isUnderlay {
            let opacity = alpha(mark)
            guard opacity > 0 else { continue }
            context.saveGState()
            context.setAlpha(opacity * PenMarkGeometry.defaultInk(for: mark.mark.kind).opacity)
            let ink = Self.ink(for: mark, text: text).resolvedColor(with: UITraitCollection.current).cgColor
            for segment in segments(for: mark.range, text: text, manager: manager, origin: origin) {
                for stroke in PenMarkGeometry.strokes(for: mark.mark, in: segment.rect, baseline: segment.baseline) {
                    context.addPath(stroke.path)
                    switch stroke.mode {
                    case .fill:
                        context.setFillColor(ink)
                        context.fillPath()
                    case let .stroke(width, dash, roundCap):
                        context.setStrokeColor(ink)
                        context.setLineWidth(width)
                        context.setLineCap(roundCap ? .round : .butt)
                        context.setLineJoin(.round)
                        context.setLineDash(phase: 0, lengths: dash)
                        context.strokePath()
                    }
                }
            }
            context.restoreGState()
        }
    }

    private static func make(isUnderlay: Bool, on textView: UITextView) -> MarkdownPenOverlayView {
        let overlay = MarkdownPenOverlayView(frame: .zero)
        overlay.isUnderlay = isUnderlay
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.isUserInteractionEnabled = false
        overlay.contentMode = .redraw
        // The lower layer goes under the text's own views (the text view has no background).
        if isUnderlay { textView.insertSubview(overlay, at: 0) } else { textView.addSubview(overlay) }
        // Inks are dynamic: draw again as the traits they read change.
        overlay.registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownPenOverlayView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
        return overlay
    }

    private func detach() {
        displayLink?.invalidate()
        displayLink = nil
        if let textView, !textView.subviews.contains(where: { $0 !== self && $0 is MarkdownPenOverlayView }) {
            textView.clipsToBounds = true
        }
        removeFromSuperview()
    }

    /// Runs while a mark hasn't shown or is still fading.
    private func updateDisplayLink() {
        guard hasUnsettledMarks else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private var hasUnsettledMarks: Bool {
        let now = MarkdownRevealClock.now
        for mark in marks {
            guard isRevealed?(mark.range) ?? true else { return true }
            let stamp = revealStamps[mark.range.location] ?? .distantPast
            if now.timeIntervalSince(stamp) < FlooMotion.markdownPenReveal.duration { return true }
        }
        return false
    }

    @objc private func tick() {
        setNeedsDisplay()
        updateDisplayLink()
    }

    override func draw(_ rect: CGRect) {
        guard let textView, let manager = textView.textLayoutManager, let context = UIGraphicsGetCurrentContext() else { return }
        let now = MarkdownRevealClock.now
        let fade = FlooMotion.markdownPenReveal.duration
        let inset = textView.textContainerInset
        let origin = CGPoint(x: inset.left + Self.overhang, y: inset.top + Self.overhang)
        Self.draw(marks, isUnderlay: isUnderlay, text: textView.textStorage, manager: manager, origin: origin, in: context) { mark in
            guard isRevealed?(mark.range) ?? true else { return 0 }
            let stamp: Date
            if let known = revealStamps[mark.range.location] {
                stamp = known
            } else {
                // A whole batch visible at first (an old message opened) doesn't fade; only what
                // comes up mid-stream does.
                stamp = displayLink == nil ? .distantPast : now
                revealStamps[mark.range.location] = stamp
            }
            return min(1, max(0, now.timeIntervalSince(stamp) / fade))
        }
    }

    /// A mark's frame and baseline on each line, in this view (the text view's plus the
    /// overhang). The frame is that baseline's ascender and descender of the font, as a run's
    /// typographic bounds are: a segment's frame is the whole line box, which CJK fallback raises.
    nonisolated private static func segments(for range: NSRange, text: NSAttributedString, manager: NSTextLayoutManager, origin: CGPoint) -> [(rect: CGRect, baseline: CGFloat)] {
        guard let contentManager = manager.textContentManager else { return [] }
        let documentStart = contentManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: range.location),
              let end = contentManager.location(documentStart, offsetBy: range.location + range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        let font = (range.location < text.length
            ? text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            : nil) ?? .preferredFont(forTextStyle: .body)
        var result: [(rect: CGRect, baseline: CGFloat)] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { segmentRange, frame, _, _ in
            guard frame.width > 1 else { return true }
            let baseline = segmentRange.flatMap { Self.baseline(at: $0.location, midY: frame.midY, in: manager) }
                ?? (frame.minY + font.ascender)
            let rect = CGRect(x: frame.minX, y: baseline - font.ascender, width: frame.width, height: font.ascender - font.descender)
            result.append((rect.offsetBy(dx: origin.x, dy: origin.y), baseline + origin.y))
            return true
        }
        return result
    }

    /// The baseline of the line a location is on: the line fragment as high as the segment.
    nonisolated private static func baseline(at location: NSTextLocation, midY: CGFloat, in manager: NSTextLayoutManager) -> CGFloat? {
        guard let fragment = manager.textLayoutFragment(for: location) else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        for line in fragment.textLineFragments {
            let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
            if bounds.minY <= midY, midY <= bounds.maxY {
                return bounds.minY + line.glyphOrigin.y
            }
        }
        return nil
    }

    /// A colour token as ink: `accent` the role's, `foreground` the text's own.
    nonisolated private static func ink(for mark: Mark, text: NSAttributedString) -> UIColor {
        let fallback = PenMarkGeometry.defaultInk(for: mark.mark.kind).token
        func foreground() -> UIColor {
            guard mark.range.location < text.length else { return .floo(.markdownText) }
            return text.attribute(.foregroundColor, at: mark.range.location, effectiveRange: nil) as? UIColor ?? .floo(.markdownText)
        }
        switch mark.mark.color ?? fallback {
        case "foreground": return foreground()
        case "accent": return .floo(.markdownPenAccent)
        case let token:
            if let color = mark.mark.color.flatMap(MarkdownInk.chosenPen) ?? MarkdownInk.pen(token) { return color }
            if fallback == "foreground" { return foreground() }
            return MarkdownInk.pen(fallback) ?? .floo(.markdownText)
        }
    }
}
