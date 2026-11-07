//
//  MarkdownTextHost.swift
//  MarkdownUIKit
//
//  A text view with its content: fills it, measures it, and places it on the pixel grid as a
//  layout does.
//

import RichTextCore
import UIKit

/// A layout's grid, in pixels per point. The screen's, not a window's: a height is measured
/// off-window too. Off the main thread it's what the main thread last saw, which is there before
/// anything is made ahead.
nonisolated var markdownPixelScale: CGFloat {
    if Thread.isMainThread {
        let scale = MainActor.assumeIsolated { max(1, UIScreen.main.scale) }
        markdownScreenScale = scale
        return scale
    }
    return markdownScreenScale
}

private nonisolated(unsafe) var markdownScreenScale: CGFloat = 2

/// To the nearest pixel: where a layout puts a frame's edges.
func markdownPixelRound(_ value: CGFloat) -> CGFloat {
    (value * markdownPixelScale).rounded() / markdownPixelScale
}

/// Up to a pixel: a layout's size for text and symbols. It divides by a pixel's size as a layout
/// does: at 3x an image's 16.666666666666668 pt comes to 17, not 16.67, which pushes what's next
/// along by a pixel.
func markdownPixelCeil(_ value: CGFloat) -> CGFloat {
    let pixel = 1 / markdownPixelScale
    return (value / pixel).rounded(.up) * pixel
}

func markdownPixelFloor(_ value: CGFloat) -> CGFloat {
    (value * markdownPixelScale).rounded(.down) / markdownPixelScale
}

extension CGRect {
    /// This rect with its edges on the pixel grid.
    func markdownPixelAligned() -> CGRect {
        let x0 = markdownPixelRound(minX)
        let y0 = markdownPixelRound(minY)
        let x1 = markdownPixelRound(maxX)
        let y1 = markdownPixelRound(maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// In a line at a size that doesn't change by itself: needs no text view to tell of a new one.
protocol MarkdownFixedInlineAttachment {}

/// Draws itself into drawn text, in the box it has in a line, under the current traits.
protocol MarkdownDrawnInlineAttachment {
    func draw(in box: CGRect)
}

/// Keeps a text view's text where string drawing puts it. A text view floors each fragment's view
/// to the pixel grid and drops the rest, so text that's centred or at the right sits up to a pixel
/// left of the same text drawn by a table. Each fragment draws that remainder itself.
final class MarkdownTextPlacement: NSObject, NSTextLayoutManagerDelegate, @unchecked Sendable {
    private let pixel: CGFloat
    /// Where the text starts in its frame when that isn't where the layout has it: a text a hair
    /// too wide for its box. Set on the main thread, read as it draws, also on the main thread.
    var exactOffset: CGFloat?

    @MainActor
    override init() {
        pixel = 1 / markdownPixelScale
    }

    /// How far right of where its view is a fragment's text has to go.
    func shift(of fragment: NSTextLayoutFragment) -> CGFloat {
        let x = fragment.layoutFragmentFrame.minX
        return (exactOffset ?? x) - (x / pixel).rounded(.down) * pixel
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = MarkdownPlacedFragment(textElement: textElement, range: textElement.elementRange)
        fragment.placement = self
        return fragment
    }
}

private final class MarkdownPlacedFragment: NSTextLayoutFragment {
    nonisolated(unsafe) var placement: MarkdownTextPlacement?

    override func draw(at point: CGPoint, in context: CGContext) {
        var point = point
        if let placement { point.x += placement.shift(of: self) }
        super.draw(at: point, in: context)
    }
}

@MainActor
final class MarkdownTextHost {
    /// The text view: the one there is, or one taking the place of the drawn text.
    var textView: InlineAttachmentTextView {
        if let shownTextView { return shownTextView }
        let view = makeTextView()
        shownTextView = view
        if let drawn {
            MarkdownDrawnTextStats.upgrades += 1
            if let text { view.applyContent(NSMutableAttributedString(attributedString: text.attributed)) }
            view.frame = drawn.frame.insetBy(dx: MarkdownDrawnTextView.overdraw, dy: MarkdownDrawnTextView.overdraw)
            drawn.superview?.insertSubview(view, aboveSubview: drawn)
            drawn.onTouched = nil
            drawn.removeFromSuperview()
            self.drawn = nil
            if let text { finish(text) }
            if !renderingColors.isEmpty { applyRenderingColors() }
            // It takes over during a hit test: the touch asks it what's under the finger (a link)
            // before any layout pass would come.
            view.layoutIfNeeded()
            if let manager = view.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
        }
        return view
    }

    /// What's in the block's views: the drawn text, or the text view.
    var view: UIView { drawn ?? textView }

    private var shownTextView: InlineAttachmentTextView?
    private var drawn: MarkdownDrawnTextView?
    private let delegate = RichTextInteractionDelegate()
    private(set) var text: MarkdownText?
    /// The room a document gives it, or none.
    var insets = UIEdgeInsets.zero
    private var isRightToLeft = false
    /// Its frame is as wide as its longest line: text placed in the room (centred lines) would go
    /// elsewhere, and text with a hanging indent wraps by that width, a list item's last word
    /// going down a line as in a SwiftUI row. All other text keeps all the room: laying it out
    /// again at a narrower width, and then again as the frame takes that width, costs a row three
    /// layouts for nothing.
    private var placesText = false
    private var hasHangingIndent = false
    /// How far right of where its frame says drawn text draws: a part of a pixel.
    var textShift: CGFloat = 0 { didSet { drawn?.textShift = textShift } }
    private var hugsText: Bool { placesText || hasHangingIndent }
    private var rightToLeftHeights: [CGFloat: CGFloat] = [:]
    private var revealController: MarkdownRevealController?
    private var foregroundColor = UIColor.label
    private var openLink: (@MainActor @Sendable (URL) -> Void)?
    private var renderingColors: [(range: NSRange, color: UIColor)] = []
    /// Where text a table draws itself would be: this text has to land there.
    private let placement: MarkdownTextPlacement?

    init(textView: Bool = true, placement: MarkdownTextPlacement? = nil) {
        self.placement = placement
        if textView { shownTextView = makeTextView() }
    }

    private func makeTextView() -> InlineAttachmentTextView {
        let textView = RichTextViewPool.acquire(usingTextLayoutManager: true)
        textView.configureForDisplay()
        if let placement { textView.textLayoutManager?.delegate = placement }
        // A first letter's overhang stays visible, as it does in a layout that doesn't clip.
        textView.clipsToBounds = false
        textView.redrawsOnChange(of: MarkdownColorTraits.all)
        delegate.textView = textView
        textView.delegate = delegate
        textView.textDragDelegate = delegate
        textView.defaultForegroundColor = foregroundColor
        delegate.openLink = openLink
        return textView
    }

    func release() {
        revealController?.detach()
        revealController = nil
        if let shownTextView { RichTextViewPool.release(shownTextView) }
        shownTextView = nil
        drawn?.onTouched = nil
        drawn?.removeFromSuperview()
        drawn = nil
    }

    /// Whether drawn text can show all of this, with nothing but TextKit drawing it.
    private func canDraw(_ text: MarkdownText) -> Bool {
        guard !placesText, !isRightToLeft, !UIAccessibility.isVoiceOverRunning else { return false }
        return Self.isDrawable(text.attributed, allowingInlineViews: true)
    }

    /// Nothing in it needs a text view: no attachment, and no mark drawn apart from the text.
    /// - Parameter allowingInlineViews: what sits in a line at a fixed size is fine: the drawn text
    ///   places those views itself.
    nonisolated static func isDrawable(_ text: NSAttributedString, allowingInlineViews: Bool = false) -> Bool {
        var plain = true
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            let attachment = attributes[.attachment]
            let attachmentStays = attachment != nil && !(allowingInlineViews && attachment is any MarkdownFixedInlineAttachment)
            if attachmentStays || attributes[.richTextPenMark] != nil
                || (attributes[.underlineColor] != nil && attributes[.underlineStyle] == nil) {
                plain = false
                stop.pointee = true
            }
        }
        return plain
    }

    /// Whether a paragraph wraps by an indent of its own: a list item.
    nonisolated static func hasHangingIndent(_ text: NSAttributedString) -> Bool {
        var hangs = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let paragraph = value as? NSParagraphStyle, paragraph.headIndent != paragraph.firstLineHeadIndent {
                hangs = true
                stop.pointee = true
            }
        }
        return hangs
    }

    /// Replaces all that shows. `reveal` goes on before the text, or its fragments would be plain.
    /// `prepared`: this text made and laid out ahead.
    func apply(_ text: MarkdownText, style: MarkdownStyle, reveal: MarkdownReveal? = nil, prepared: MarkdownTextStack? = nil, picture: MarkdownTextPicture? = nil) {
        prepare(text, style: style)
        if style.drawsTextUntilTouched, reveal == nil, shownTextView == nil, canDraw(text) {
            let drawn = drawn ?? MarkdownDrawnTextView()
            drawn.onTouched = { [weak self] in self?.textView }
            drawn.textShift = textShift
            if let prepared {
                drawn.show(prepared: prepared, picture: picture, label: text.attributed.string)
            } else {
                drawn.narrowsToText = hasHangingIndent
                drawn.show(text.attributed, foregroundColor: foregroundColor)
            }
            self.drawn = drawn
            return
        }
        setReveal(reveal)
        // applyContent trusts a same-text prefix to be the same: an update starts clean.
        if textView.textStorage.length > 0 {
            textView.applyContent(NSMutableAttributedString())
        }
        textView.applyContent(NSMutableAttributedString(attributedString: text.attributed))
        finish(text)
    }

    /// The same block grown: only what differs from what's in the storage is replaced. What's
    /// the same keeps its layout, and its place in a reveal.
    func update(_ text: MarkdownText, style: MarkdownStyle, reveal: MarkdownReveal? = nil) {
        prepare(text, style: style)
        if let drawn, reveal == nil, canDraw(text) {
            drawn.textShift = textShift
            drawn.narrowsToText = hasHangingIndent
            drawn.show(text.attributed, foregroundColor: foregroundColor)
            if !renderingColors.isEmpty { applyRenderingColors() }
            return
        }
        setReveal(reveal)
        let tail = NSMutableAttributedString(attributedString: text.attributed)
        if textView.replaceTail(tail, nsPrefixLength: 0) == nil {
            textView.applyContent(NSMutableAttributedString())
            textView.applyContent(NSMutableAttributedString(attributedString: text.attributed))
        }
        finish(text)
    }

    /// A reveal over the text as it is; nil shows all of it, with no relayout.
    func setReveal(_ reveal: MarkdownReveal?) {
        guard let reveal else {
            guard let controller = revealController else { return }
            controller.detach()
            revealController = nil
            syncPenMarks()
            return
        }
        let controller = revealController ?? MarkdownRevealController()
        controller.placement = placement
        revealController = controller
        controller.attach(textView, reveal: reveal, storageToPlain: text?.storageToPlain ?? [])
    }

    private func prepare(_ text: MarkdownText, style: MarkdownStyle) {
        self.text = text
        isRightToLeft = style.layoutDirection == .rightToLeft
        placesText = style.typography.paragraphAlignment != .left && style.typography.paragraphAlignment != .natural
        hasHangingIndent = Self.hasHangingIndent(text.attributed)
        rightToLeftHeights.removeAll()
        foregroundColor = style.resolvedTextColor
        openLink = style.openURL
        shownTextView?.defaultForegroundColor = foregroundColor
        delegate.openLink = openLink
    }

    private func finish(_ text: MarkdownText) {
        textView.invalidateFittingSizes()
        revealController?.contentDidChange(storageToPlain: text.storageToPlain)
        syncPenMarks()
    }

    private func syncPenMarks() {
        guard let textView = shownTextView else { return }
        guard let controller = revealController else {
            MarkdownPenOverlayView.sync(on: textView)
            return
        }
        MarkdownPenOverlayView.sync(on: textView) { [weak controller] range in
            controller?.isRevealed(storageRange: range) ?? true
        }
    }

    /// What's in the text changed size by itself: nothing measured before holds.
    func textSizeDidChange() {
        shownTextView?.invalidateFittingSizes()
        shownTextView?.setNeedsLayout()
        rightToLeftHeights.removeAll()
    }

    /// Colours over the text as rendering attributes, which lay nothing out: a highlight coming
    /// in. Kept for a text view taking the drawn text's place.
    func setRenderingColors(_ runs: [(range: NSRange, color: UIColor)]) {
        renderingColors = runs
        applyRenderingColors()
    }

    /// Colours a stack made ahead has on already: for a text view taking its place.
    func holdRenderingColors(_ runs: [(range: NSRange, color: UIColor)]) {
        renderingColors = runs
    }

    private func applyRenderingColors() {
        let manager = shownTextView?.textLayoutManager ?? drawn?.layoutManager
        guard let manager else { return }
        MarkdownCodeRenderingColors.set(renderingColors, on: manager)
        shownTextView?.setNeedsDisplay()
        drawn?.setNeedsDisplay()
    }

    private var layoutManager: NSTextLayoutManager? { shownTextView?.textLayoutManager ?? drawn?.layoutManager }

    /// Puts the text at a frame already worked out: no measuring.
    func place(_ frame: CGRect) {
        if let drawn {
            _ = drawn.size(forWidth: frame.width)
            let outer = frame.insetBy(dx: -MarkdownDrawnTextView.overdraw, dy: -MarkdownDrawnTextView.overdraw)
            if drawn.frame != outer { drawn.frame = outer }
        } else if textView.frame != frame {
            textView.frame = frame
        }
    }

    /// The fragments as they stand: the same ones again means nothing was laid out.
    var layoutFragmentIDs: [ObjectIdentifier] {
        guard let manager = layoutManager else { return [] }
        var ids: [ObjectIdentifier] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            ids.append(ObjectIdentifier(fragment))
            return true
        }
        return ids
    }

    /// The text's own size at `width`, inside the insets.
    func fittingSize(width: CGFloat) -> CGSize {
        let inner = max(0, width - insets.left - insets.right)
        if let drawn { return drawn.size(forWidth: inner) }
        guard isRightToLeft || (RichTextPerf.on("fit") && !hugsText) else {
            return textView.fittingSize(proposedWidth: inner, proposedHeight: nil)
        }
        // Right to left, a hanging indent makes the reported width too narrow, and cut to it an
        // item wraps early. It keeps all the room; its text is flush right anyway.
        if let height = rightToLeftHeights[inner] { return CGSize(width: inner, height: height) }
        let height = textView.sizeThatFits(CGSize(width: inner, height: 1_000_000)).height
        rightToLeftHeights[inner] = height
        return CGSize(width: inner, height: height)
    }

    /// With the insets.
    func height(forWidth width: CGFloat) -> CGFloat {
        fittingSize(width: width).height + insets.top + insets.bottom
    }

    /// Places the text in `rect`, at the size it asks for, at the leading edge.
    func layout(in rect: CGRect, isRightToLeft: Bool) {
        let size = fittingSize(width: rect.width)
        let x = isRightToLeft ? rect.maxX - insets.right - size.width : rect.minX + insets.left
        let frame = CGRect(x: x, y: rect.minY + insets.top, width: size.width, height: size.height).markdownPixelAligned()
        if let drawn {
            let outer = frame.insetBy(dx: -MarkdownDrawnTextView.overdraw, dy: -MarkdownDrawnTextView.overdraw)
            if drawn.frame != outer { drawn.frame = outer }
            return
        }
        if textView.frame != frame {
            textView.frame = frame
            MarkdownPenOverlayView.sync(on: textView)
        }
    }
}
