//
//  MarkdownDrawnTextView.swift
//  MarkdownUIKit
//
//  Text drawn in one view, by the same TextKit 2 a text view lays out with, for rows that are
//  only looked at. A text view costs a row a dozen views and several passes over its text; this
//  costs one view and one layout. The first touch, or a pointer moving over it, asks for a real
//  text view in its place, so selecting, links and the pointer are a text view's own. Scrolling
//  doesn't: a scroll hit-tests every row passing under a resting pointer. It has no draw: a
//  picture goes in its layer, drawn ahead on another thread if it can be.
//

import MarkdownCore
import UIKit

@MainActor
final class MarkdownDrawnTextView: UIView {
    /// How far past the text it draws: what a first letter or an italic overhangs.
    /// Room past the text on each side: a first letter's overhang, a pen's stroke.
    nonisolated static let overdraw: CGFloat = PenMarkGeometry.overhang + 2

    /// Hit: gives the text view that takes its place.
    var onTouched: (() -> UITextView?)?

    /// Wraps at the width of its longest line (see `MarkdownTextHost`).
    var narrowsToText = false {
        didSet { if narrowsToText != oldValue { stack?.narrowsToText = narrowsToText } }
    }

    private var stack: MarkdownTextStack?
    /// May be another view's too, with the same text: laid out once, and only read after that.
    private var stackIsPrepared = false
    private var picture: MarkdownTextPicture?
    /// What sits in the lines: a text view would place these, so this does.
    private var hasAttachments = false
    private var attachmentViews: [UIView] = []
    /// Views made here for view attachments, by attachment.
    private var ownViews: [ObjectIdentifier: UIView] = [:]

    private func ownView(for attachment: NSTextAttachment?) -> UIView? {
        guard let attachment = attachment as? MarkdownViewAttachment else { return nil }
        let key = ObjectIdentifier(attachment)
        if let known = ownViews[key] { return known }
        let made = attachment.makeView()
        ownViews[key] = made
        return made
    }

    /// How far right of where its frame says the text draws: a part of a pixel.
    var textShift: CGFloat = 0 {
        didSet { if textShift != oldValue { stack?.shift = textShift; setNeedsDisplay() } }
    }

    var layoutManager: NSTextLayoutManager? { stack?.layoutManager }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = nil
        // A picture stays the size it is, and starts at the top left.
        contentMode = .topLeft
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        if UIDevice.current.userInterfaceIdiom != .phone {
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        }
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownDrawnTextView, _: UITraitCollection) in
            view.layer.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: NSAttributedString, foregroundColor: UIColor) {
        if stack == nil || stackIsPrepared {
            stack = MarkdownTextStack()
            stackIsPrepared = false
        }
        stack?.narrowsToText = narrowsToText
        stack?.shift = textShift
        stack?.show(text, foregroundColor: foregroundColor)
        accessibilityLabel = text.string
        ownViews.removeAll()
        hasAttachments = text.containsAttachments(in: NSRange(location: 0, length: text.length))
        setNeedsDisplay()
        setNeedsLayout()
    }

    /// Takes text made and laid out ahead, and drawn if `picture` isn't nil.
    func show(prepared: MarkdownTextStack, picture: MarkdownTextPicture?, label: String) {
        stack = prepared
        stackIsPrepared = true
        narrowsToText = prepared.narrowsToText
        accessibilityLabel = label
        ownViews.removeAll()
        hasAttachments = prepared.hasViewAttachments
        setNeedsDisplay()
        self.picture = picture
        setNeedsLayout()
    }

    /// The text's size at `width`: all of it wide, or as wide as its longest line, laid out again
    /// there, with `narrowsToText`.
    func size(forWidth width: CGFloat) -> CGSize {
        guard let current = stack else { return .zero }
        if stackIsPrepared, !current.isLaidOut(atWidth: width) {
            stack = current.copy()
            stackIsPrepared = false
        }
        guard let stack else { return .zero }
        if !stack.isLaidOut(atWidth: width) {
            setNeedsDisplay()
            setNeedsLayout()
        }
        return stack.size(forWidth: width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard hasAttachments || !attachmentViews.isEmpty else { return }
        var placed: [UIView] = []
        if hasAttachments, let layoutManager {
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame
                let origin = CGPoint(x: markdownPixelFloor(frame.minX) + Self.overdraw, y: markdownPixelFloor(frame.minY) + Self.overdraw)
                for provider in fragment.textAttachmentViewProviders {
                    // A view attachment of a fixed size has no view from its provider here: this
                    // view makes its own, as the same text may show in others too.
                    guard let view = provider.view ?? ownView(for: provider.textAttachment) else { continue }
                    view.frame = fragment.frameForTextAttachment(at: provider.location).offsetBy(dx: origin.x, dy: origin.y)
                    if view.superview !== self { addSubview(view) }
                    placed.append(view)
                }
                return true
            }
        }
        for view in attachmentViews where view.superview === self && !placed.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        attachmentViews = placed
    }

    /// What shows differs now: the picture there is, if any, is no good.
    override func setNeedsDisplay() {
        picture = nil
        layer.setNeedsDisplay()
    }

    /// The picture ahead if it's right for these traits; or it's drawn here.
    override func display(_ layer: CALayer) {
        let traits = traitCollection
        let scale = traits.displayScale
        if picture.map({ $0.scale != scale || !MarkdownColorTraits.resolveAlike($0.traits, traits) }) ?? true {
            guard let stack else {
                layer.contents = nil
                return
            }
            picture = stack.picture(scale: scale, traits: traits)
        }
        layer.contentsScale = scale
        layer.contents = picture?.image
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: Self.overdraw, dy: Self.overdraw).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        guard event?.type == .touches, let textView = onTouched?() else { return self }
        return textView.hitTest(convert(point, to: textView), with: event)
    }

    /// `.began` also comes as a row scrolls under a resting pointer: only a move counts.
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        if recognizer.state == .changed { _ = onTouched?() }
    }
}

/// How many rows have changed drawn text for a text view: for probes.
@MainActor
public enum MarkdownDrawnTextStats {
    public static var upgrades = 0
}
