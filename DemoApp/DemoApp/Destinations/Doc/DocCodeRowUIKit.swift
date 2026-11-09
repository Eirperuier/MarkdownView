//
//  DocCodeRowUIKit.swift
//  DemoApp
//
//  A code block as a UIKit row: Craft's box (DocCodeMetrics), read and edited alike. The
//  gutter with the lines' numbers, its line, and the code's text view (scrolling sideways,
//  its caret's line lit) inside a thin border; while it's edited, a faint ring around the box.
//

import DocKit
import FlooUIKit
import MessagingUI
import Observation
import SwiftUI
import UIKit

/// A code row's content: its block, its code and language, and who edits it.
@MainActor
struct DocCodeRowContent: TiledUIKitCellContent {
    /// Its row runs a reshape's animation and the rows round it move in its frames.
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let block: DocBlockID
    let code: String
    let language: String?
    let sources: DocSourceController

    static func makeRowView() -> DocCodeRowView { DocCodeRowView() }

    func configure(_ view: DocCodeRowView, context: TiledUIKitCellContext) {
        view.show(row, block: block, code: code, language: language, sources: sources, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocCodeRowView.height(of: row, code: code, width: width)
    }

    static func prepareForReuse(_ view: DocCodeRowView) {
        view.reset()
    }
}

@MainActor
final class DocCodeRowView: DocRowUIKitView {
    private let box = DocCodeBoxView()

    init() {
        super.init(content: box)
    }

    func show(_ row: DocRow, block: DocBlockID, code: String, language: String?, sources: DocSourceController, context: TiledUIKitCellContext) {
        let grew = box.code != code
        take(row, blocks: sources.editor.blocks, context: context)
        box.show(block: block, code: code, language: language, controller: sources)
        if grew { box.setNeedsLayout() }
        layOutShown()
    }

    override func reset() {
        super.reset()
        box.forget()
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        box.height(forWidth: width)
    }

    private static var heights = DocRowHeights<String>()
    private static let sizing = DocCodeBoxView()

    static func height(of row: DocRow, code: String, width: CGFloat) -> CGFloat {
        heights.height(of: row, showing: code, width: width) { width in
            sizing.show(block: nil, code: code, language: nil, controller: nil)
            return sizing.height(forWidth: width)
        }
    }
}

/// Craft's code box: the gutter, its line and the code's text view, in a thin border on a
/// faint fill; ringed while its block is edited.
@MainActor
final class DocCodeBoxView: UIView {
    private let metrics = DocCodeMetrics(font: docCodeFont)
    private let gutter = DocCodeGutterView()
    private let separator = UIView()
    private let textView = DocSourceTextView.make(code: true)
    private let ring = UIView()
    private(set) var code: String?
    private var block: DocBlockID?
    private var language: String?
    private weak var controller: DocSourceController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = DocCodeMetrics.radius
        layer.cornerCurve = .continuous
        layer.borderWidth = DocCodeMetrics.border
        backgroundColor = UIColor { DocTokens.UIKitColor.primary.resolvedColor(with: $0).withAlphaComponent(DocCodeMetrics.fillOpacity) }
        separator.backgroundColor = UIColor { DocTokens.UIKitColor.primary.resolvedColor(with: $0).withAlphaComponent(DocCodeMetrics.lineOpacity) }
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = DocCodeMetrics.radius + DocCodeMetrics.ringOffset
        ring.layer.cornerCurve = .continuous
        ring.layer.borderWidth = DocCodeMetrics.border
        ring.alpha = 0
        gutter.metrics = metrics
        addSubview(gutter)
        addSubview(separator)
        addSubview(textView)
        addSubview(ring)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.updateColors()
            view.configureText()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `code` of `block` (nil: only measured), edited through `controller`.
    func show(block: DocBlockID?, code: String, language: String?, controller: DocSourceController?) {
        self.block = block
        self.code = code
        self.language = language
        self.controller = controller
        gutter.lines = code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        configureText()
        followEditing()
        setNeedsLayout()
    }

    func forget() {
        block = nil
        controller = nil
        ring.alpha = 0
    }

    private func configureText() {
        guard let code else { return }
        textView.configure(block: block, text: code, controller: controller, font: docCodeFont, insets: .zero, language: language, code: metrics,
                           scheme: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
    }

    /// Ringed while its block is edited, coming and going in the reveal's motion.
    private func followEditing() {
        guard let controller, let block else { return }
        withObservationTracking {
            let editing = controller.editing == block
            if (ring.alpha == 1) != editing {
                FlooMotion.appear.animate { self.ring.alpha = editing ? 1 : 0 }
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.block == block else { return }
                self.followEditing()
            }
        }
    }

    private func updateColors() {
        let traits = traitCollection
        layer.borderColor = DocTokens.UIKitColor.primary.resolvedColor(with: traits).withAlphaComponent(DocCodeMetrics.lineOpacity).cgColor
        ring.layer.borderColor = UIColor.floo(.label).resolvedColor(with: traits).withAlphaComponent(DocCodeMetrics.ringOpacity).cgColor
    }

    private var gutterWidth: CGFloat { metrics.gutterWidth(lines: gutter.lines) }

    private func textWidth(in width: CGFloat) -> CGFloat {
        max(0, width - DocCodeMetrics.border * 2 - gutterWidth - DocCodeMetrics.separator)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        DocCodeMetrics.border * 2 + textView.fittingHeight(width: textWidth(in: width))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // On whole pixels, as SwiftUI's stack placed them: the separator is half a point wide.
        let scale = max(1, traitCollection.displayScale)
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let inner = bounds.insetBy(dx: DocCodeMetrics.border, dy: DocCodeMetrics.border)
        gutter.frame = CGRect(x: inner.minX, y: inner.minY, width: gutterWidth, height: inner.height)
        separator.frame = CGRect(x: gutter.frame.maxX, y: inner.minY, width: DocCodeMetrics.separator, height: inner.height)
        let textX = pixel(separator.frame.maxX)
        let textFrame = CGRect(x: textX, y: inner.minY, width: inner.maxX - textX, height: inner.height)
        if textView.frame != textFrame { textView.frame = textFrame }
        ring.frame = bounds.insetBy(dx: -DocCodeMetrics.ringOffset, dy: -DocCodeMetrics.ringOffset)
    }
}

/// A code block's gutter: its lines' numbers, right-aligned on the lines' pitch, on a fill a
/// little lighter than the box's. It stays where it is while the code scrolls sideways.
final class DocCodeGutterView: UIView {
    var metrics: DocCodeMetrics?
    var lines = 1 {
        didSet { if lines != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.cornerRadius = DocCodeMetrics.radius - DocCodeMetrics.border
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        backgroundColor = UIColor { DocTokens.UIKitColor.primary.resolvedColor(with: $0).withAlphaComponent(DocCodeMetrics.gutterOpacity) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.setNeedsDisplay() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let metrics else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.font,
            .foregroundColor: UIColor.floo(.disabledLabel).resolvedColor(with: traitCollection),
        ]
        let right = bounds.width - metrics.numberTrailing
        let lineHeight = metrics.font.lineHeight
        for number in 1...max(1, lines) {
            let top = metrics.edge + CGFloat(number - 1) * metrics.pitch
            guard top < rect.maxY, top + metrics.pitch > rect.minY else { continue }
            let string = "\(number)" as NSString
            let width = string.size(withAttributes: attributes).width
            string.draw(at: CGPoint(x: right - width, y: top + (metrics.pitch - lineHeight) / 2), withAttributes: attributes)
        }
    }
}
