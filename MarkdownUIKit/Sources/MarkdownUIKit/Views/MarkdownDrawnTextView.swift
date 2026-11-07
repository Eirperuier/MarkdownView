//
//  MarkdownDrawnTextView.swift
//  MarkdownUIKit
//
//  Text drawn in one view, by the same TextKit 2 a text view lays out with, for rows that are
//  only looked at. A text view costs a row a dozen views and several passes over its text; this
//  costs one view and one layout. The first touch, or a pointer moving over it, asks for a real
//  text view in its place, so selecting, links and the pointer are a text view's own. Scrolling
//  doesn't: a scroll hit-tests every row passing under a resting pointer.
//

import UIKit

@MainActor
final class MarkdownDrawnTextView: UIView, NSTextLayoutManagerDelegate {
    /// How far past the text it draws: what a first letter or an italic overhangs.
    static let overdraw: CGFloat = 4

    /// Hit: gives the text view that takes its place.
    var onTouched: (() -> UITextView?)?

    /// Wraps at the width of its longest line (see `MarkdownTextHost`).
    var narrowsToText = false

    private var measured: (width: CGFloat, size: CGSize)?
    private let storage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    private let container = NSTextContainer(size: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = nil
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        layoutManager.delegate = self
        storage.addTextLayoutManager(layoutManager)
        if UIDevice.current.userInterfaceIdiom != .phone {
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        }
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownDrawnTextView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: NSAttributedString, foregroundColor: UIColor) {
        let filled = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: filled.length)
        filled.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
            if value == nil { filled.addAttribute(.foregroundColor, value: foregroundColor, range: run) }
        }
        filled.enumerateAttribute(.font, in: range) { value, run, _ in
            if value == nil { filled.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: run) }
        }
        Self.applyIntentsAsTextViewDoes(filled, in: range)
        storage.performEditingTransaction {
            storage.textStorage?.setAttributedString(filled)
        }
        accessibilityLabel = text.string
        measured = nil
        setNeedsDisplay()
    }

    /// A text view takes `inlinePresentationIntent` over the font: emphasis alone on a bold font
    /// (in a heading) is the regular italic. Text in a storage of its own stays as it's given.
    static func applyIntentsAsTextViewDoes(_ text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.inlinePresentationIntent, in: range) { value, run, _ in
            guard let raw = value as? UInt, InlinePresentationIntent(rawValue: raw).contains(.emphasized),
                  !InlinePresentationIntent(rawValue: raw).contains(.stronglyEmphasized) else { return }
            text.enumerateAttribute(.font, in: run) { value, fontRun, _ in
                guard let font = value as? UIFont else { return }
                let traits = font.fontDescriptor.symbolicTraits
                guard traits.contains(.traitBold), traits.contains(.traitItalic),
                      let regular = font.fontDescriptor.withSymbolicTraits(traits.subtracting(.traitBold)) else { return }
                text.addAttribute(.font, value: UIFont(descriptor: regular, size: font.pointSize), range: fontRun)
            }
        }
    }

    /// The text's size at `width`: all of it wide, or as wide as its longest line, laid out again
    /// there, with `narrowsToText`.
    func size(forWidth width: CGFloat) -> CGSize {
        if let measured, measured.width == width { return measured.size }
        lay(atWidth: width)
        var size = CGSize(width: width, height: layoutManager.usageBoundsForTextContainer.height)
        if narrowsToText {
            let used = layoutManager.usageBoundsForTextContainer.width
            if used < width - 0.5 {
                lay(atWidth: used)
                size = CGSize(width: used, height: layoutManager.usageBoundsForTextContainer.height)
            }
        }
        measured = (width, size)
        return size
    }

    private func lay(atWidth width: CGFloat) {
        if container.size.width != width {
            container.size = CGSize(width: width, height: 0)
            setNeedsDisplay()
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let inset = Self.overdraw
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset > rect.maxY { return false }
            // Down to the pixel grid, as a text view puts its fragment views.
            fragment.draw(at: CGPoint(x: markdownPixelFloor(frame.minX) + inset, y: markdownPixelFloor(frame.minY) + inset), in: context)
            return true
        }
    }

    /// A link looks as its own attributes have it, as in a text view with no link attributes.
    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        renderingAttributesForLink link: Any,
        at location: any NSTextLocation,
        defaultAttributes renderingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any]? {
        [:]
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
