//
//  MarkdownMathViews.swift
//  MarkdownUIKit
//
//  Maths as plain views: SwaTex gives an image and its metrics, a UIImageView shows it. A
//  template image takes the role's colour as a tint. A formula with `\color` has its colours in
//  the image, so it's drawn again when the role's colour changes. What LaTeX can't read shows
//  as its source.
//

import MarkdownCore
import RichTextCore
import UIKit

enum MarkdownMath {
    /// The formula drawn. `latex` is as written, with its delimiters; a tree's has none.
    static func piece(latex: String, kind: MarkdownMathPiece.Kind, xHeight: CGFloat, foreground: String) -> MarkdownMathPiece {
        MarkdownMathRenderer.piece(latex: latex, kind: kind, xHeight: xHeight, foreground: foreground, scale: markdownPixelScale)
    }

    /// The colour a formula with `\color` draws its other glyphs in. A colour's opacity stays
    /// out of it, as the rest of the image has no way to carry it.
    static func foreground(in traits: UITraitCollection) -> String {
        var (red, green, blue): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        UIColor.floo(.markdownMath).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: nil)
        func level(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", level(red), level(green), level(blue))
    }

    /// The formula's text style in `style`, at its size.
    static func font(_ textStyle: UIFont.TextStyle, style: MarkdownStyle) -> UIFont {
        UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: style.contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) })
    }

    /// From one line's top to the next one's, as a layout steps lines: whole points.
    static func lineStep(_ font: UIFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded()
    }

    /// What's below a baseline in a line with one after it.
    static func belowBaseline(_ font: UIFont) -> CGFloat {
        (font.leading - font.descender).rounded()
    }

    /// A formula's baseline in the second line, from the top of the first, while it's no taller
    /// than the room there. On the Mac a layout rounds the ascent.
    static func secondBaseline(_ font: UIFont) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        lineStep(font) * 2 - belowBaseline(font)
        #else
        lineStep(font) + font.ascender
        #endif
    }

    /// A last line's height and what's below its baseline. On iOS the leading is only between
    /// lines. On the Mac, with a leading under a point, a last line is as tall as any other.
    static func lastLine(_ font: UIFont) -> (height: CGFloat, below: CGFloat) {
        #if targetEnvironment(macCatalyst)
        (lineStep(font), belowBaseline(font))
        #else
        (font.ascender - font.descender, -font.descender)
        #endif
    }
}

/// A formula's image, in the role's colour.
@MainActor
final class MarkdownMathImageView: UIImageView {
    private var latex = ""
    private var kind = MarkdownMathPiece.Kind.inlineEquation
    private var xHeight: CGFloat = 0
    private var foreground: String?
    private var isBaked = false
    /// Clear room around the image, in the image itself.
    var imageMargin: CGFloat = 0

    init() {
        super.init(frame: .zero)
        contentMode = .scaleToFill
        isUserInteractionEnabled = false
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownMathImageView, _: UITraitCollection) in
            view.applyColor()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ piece: MarkdownMathPiece, latex: String, xHeight: CGFloat) {
        self.latex = latex
        self.kind = piece.kind
        self.xHeight = xHeight
        image = withMargin(piece.image)
        if case .baked(let foreground) = piece.color {
            isBaked = true
            self.foreground = foreground
        } else {
            isBaked = false
            foreground = nil
        }
        applyColor()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyColor()
    }

    private func applyColor() {
        guard isBaked else {
            // A layer's colour holds what's resolved, so it's resolved here, for each trait.
            tintColor = UIColor.floo(.markdownMath).resolvedColor(with: traitCollection)
            return
        }
        let wanted = MarkdownMath.foreground(in: traitCollection)
        guard wanted != foreground else { return }
        foreground = wanted
        image = withMargin(MarkdownMath.piece(latex: latex, kind: kind, xHeight: xHeight, foreground: wanted).image)
    }

    private func withMargin(_ image: UIImage?) -> UIImage? {
        guard let image, imageMargin > 0 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let size = CGSize(width: image.size.width + imageMargin * 2, height: image.size.height + imageMargin * 2)
        let padded = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.withRenderingMode(.alwaysOriginal).draw(at: CGPoint(x: imageMargin, y: imageMargin))
        }
        return padded.withRenderingMode(image.renderingMode)
    }
}

/// Source text where a formula didn't render.
@MainActor
final class MarkdownMathSourceView: UIView {
    var text: NSAttributedString? { didSet { setNeedsDisplay() } }
    /// Set for lines on a fixed step; nil lets the text wrap.
    var lineStep: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownMathSourceView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let text else { return }
        guard let lineStep else {
            text.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            return
        }
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        for (index, line) in text.string.components(separatedBy: "\n").enumerated() where !line.isEmpty {
            NSAttributedString(string: line, attributes: attributes).draw(at: CGPoint(x: 0, y: CGFloat(index) * lineStep))
        }
    }
}

/// A formula in a line of text: one storage character, selected with the text around it. Copies
/// as it was written, so pasting brings the formula back. Made on any thread: its view waits for
/// a text view to ask, and drawn text draws it instead.
final class MarkdownInlineMathAttachment: RichTextAttachment, MarkdownFixedInlineAttachment, MarkdownDrawnInlineAttachment, @unchecked Sendable {
    private let latex: String
    private let source: String
    private let textFont: UIFont
    private let xHeight: CGFloat
    private let piece: MarkdownMathPiece?
    private let imageLayout: (size: CGSize, imageOrigin: CGPoint, descent: CGFloat)?
    @MainActor private var container: UIView?

    init(id: AnyHashable, latex: String, style: MarkdownStyle) {
        textFont = MarkdownMath.font(.body, style: style)
        xHeight = MarkdownMath.font(style.inlineMathTextStyle, style: style).xHeight
        self.latex = latex
        let piece = MarkdownMath.piece(latex: latex, kind: .inlineEquation, xHeight: xHeight, foreground: MarkdownMath.foreground(in: UITraitCollection.current))
        self.piece = piece
        source = latex.hasPrefix("$") || latex.hasPrefix("\\") ? latex : "$\(latex)$"
        if let metrics = piece.metrics, piece.image != nil {
            imageLayout = Self.layout(image: metrics.imageSize, offset: metrics.baselineOffset, font: textFont)
        } else {
            imageLayout = nil
        }
        super.init(id: id, sizing: .fittingLineFragment)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// As a line of text holds the image, its baseline on the line's: the box reaches up to the
    /// text's ascent or the formula's, whichever is taller, and down to the text's descent or the
    /// formula's depth, whichever is deeper. It says how far down, so it sits exactly there.
    private static func layout(image: CGSize, offset: CGFloat, font: UIFont) -> (size: CGSize, imageOrigin: CGPoint, descent: CGFloat) {
        let last = MarkdownMath.lastLine(font)
        let depth = -offset
        let ascent = max(image.height - depth, last.height - last.below)
        let descent = max(depth, last.below)
        let height = markdownPixelCeil(ascent + descent)
        // What rounding adds goes on top: the bottom stays where the descent puts it.
        let top = height - descent - image.height + depth
        return (CGSize(width: markdownPixelCeil(image.width), height: height), CGPoint(x: 0, y: markdownPixelRound(top)), descent)
    }

    override var fixedSize: CGSize? { imageLayout?.size }

    override var fixedDescent: CGFloat? { imageLayout?.descent }

    func draw(in box: CGRect) {
        guard let imageLayout, let piece, let metrics = piece.metrics, let image = piece.image else { return }
        let rect = CGRect(x: box.minX + imageLayout.imageOrigin.x, y: box.minY + imageLayout.imageOrigin.y, width: metrics.imageSize.width, height: metrics.imageSize.height)
        guard case .baked(let foreground) = piece.color else {
            image.withTintColor(UIColor.floo(.markdownMath).resolvedColor(with: UITraitCollection.current), renderingMode: .alwaysOriginal).draw(in: rect)
            return
        }
        let wanted = MarkdownMath.foreground(in: UITraitCollection.current)
        let shown = wanted == foreground ? image : MarkdownMath.piece(latex: latex, kind: piece.kind, xHeight: xHeight, foreground: wanted).image
        shown?.withRenderingMode(.alwaysOriginal).draw(in: rect)
    }

    @MainActor
    override var contentView: UIView {
        if let container { return container }
        let container = UIView()
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        if let piece, let metrics = piece.metrics, let imageLayout {
            // TextKit puts the formula at a fractional place and the layer stays there: its
            // snapped edge would cut a row of the image.
            let view = MarkdownMathImageView()
            view.imageMargin = 1
            view.show(piece, latex: latex, xHeight: xHeight)
            view.frame = CGRect(origin: imageLayout.imageOrigin, size: metrics.imageSize).insetBy(dx: -view.imageMargin, dy: -view.imageMargin)
            container.addSubview(view)
        } else {
            let view = MarkdownMathSourceView()
            view.text = sourceText
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(view)
        }
        self.container = container
        return container
    }

    private var sourceText: NSAttributedString {
        NSAttributedString(
            string: (piece?.originalText ?? latex).trimmingCharacters(in: .newlines),
            attributes: [.font: textFont, .foregroundColor: UIColor.floo(.markdownMath)]
        )
    }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? {
        if let imageLayout { return imageLayout.size }
        let text = sourceText
        let size = text.boundingRect(with: CGSize(width: proposal.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
        // Its last line is a last line's height, not a whole step.
        let height = size.height - MarkdownMath.lineStep(textFont) + MarkdownMath.lastLine(textFont).height
        return CGSize(width: markdownPixelCeil(size.width), height: markdownPixelCeil(height))
    }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}

/// A formula on its own: in a horizontal scroller if it's wider than the text, with blank lines above and
/// below it, centred in the height set aside for it, at the leading edge.
@MainActor
final class MarkdownDisplayMathView: UIView {
    private var scroller: UIScrollView?
    private let imageView = MarkdownMathImageView()
    private lazy var sourceView: MarkdownMathSourceView = {
        let view = MarkdownMathSourceView()
        (scroller ?? self).addSubview(view)
        return view
    }()
    private var hasSourceView = false
    private var contentSize = CGSize.zero
    private var reserved: CGFloat = 0
    private var imageTop: CGFloat = 0
    private var imageSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Drawn at once: SwaTex lays a formula out in microseconds, so its height is known now.
    func configure(latex: String, style: MarkdownStyle) {
        let font = MarkdownMath.font(style.displayMathTextStyle, style: style)
        reserved = MarkdownDisplayMathHeight.reserved(for: latex)
        show(MarkdownMath.piece(latex: latex, kind: .displayEquation, xHeight: font.xHeight, foreground: MarkdownMath.foreground(in: traitCollection)), latex: latex, font: font)
    }

    /// How tall a formula's image makes it, with the blank lines, on any thread.
    nonisolated static func contentHeight(image: CGSize, font: UIFont) -> CGFloat {
        let line = MarkdownMath.lineStep(font)
        let imageLine = max(line, image.height + MarkdownMath.belowBaseline(font))
        return markdownPixelCeil(line + imageLine + markdownPixelCeil(MarkdownMath.lastLine(font).height))
    }

    private func show(_ piece: MarkdownMathPiece?, latex: String, font: UIFont) {
        let line = MarkdownMath.lineStep(font)
        let last = markdownPixelCeil(MarkdownMath.lastLine(font).height)
        if let piece, let metrics = piece.metrics, piece.image != nil {
            imageView.isHidden = false
            if hasSourceView { sourceView.isHidden = true }
            imageView.show(piece, latex: latex, xHeight: font.xHeight)
            let image = metrics.imageSize
            // A tall formula goes up into the leading between the lines, down to the first
            // line's text.
            imageTop = max(MarkdownMath.secondBaseline(font) - image.height, MarkdownMath.lastLine(font).height)
            contentSize = CGSize(width: image.width, height: Self.contentHeight(image: image, font: font))
            imageSize = image
        } else {
            // What LaTeX can't read: its source with the blank lines, in the formula's place.
            imageView.isHidden = true
            hasSourceView = true
            sourceView.isHidden = false
            let text = NSAttributedString(
                string: "\n\(piece?.originalText ?? latex)\n",
                attributes: [.font: font, .foregroundColor: UIColor.floo(.markdownMath)]
            )
            sourceView.text = text
            sourceView.lineStep = line
            let size = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
            let lines = CGFloat(text.string.components(separatedBy: "\n").count)
            contentSize = CGSize(width: markdownPixelCeil(size.width), height: markdownPixelCeil((lines - 1) * line + last))
        }
        setNeedsLayout()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        max(reserved, contentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeScroller()
        let top = (bounds.height - contentSize.height) / 2
        imageView.frame = CGRect(x: 0, y: markdownPixelRound(top + imageTop), width: imageSize.width, height: imageSize.height)
        if hasSourceView {
            sourceView.frame = CGRect(x: 0, y: markdownPixelRound(top), width: contentSize.width, height: contentSize.height)
        }
    }

    /// Only for what's too wide: a scroll view is the most a row costs.
    private func placeScroller() {
        let contents: [UIView] = hasSourceView ? [imageView, sourceView] : [imageView]
        guard contentSize.width > bounds.width else {
            if let scroller {
                contents.forEach { addSubview($0) }
                scroller.removeFromSuperview()
                self.scroller = nil
            }
            return
        }
        let scroller = self.scroller ?? UIScrollView()
        if self.scroller == nil {
            scroller.showsVerticalScrollIndicator = false
            scroller.alwaysBounceVertical = false
            scroller.contentInsetAdjustmentBehavior = .never
            scroller.clipsToBounds = true
            addSubview(scroller)
            contents.forEach { scroller.addSubview($0) }
            self.scroller = scroller
        }
        scroller.frame = bounds
        scroller.contentSize = CGSize(width: contentSize.width, height: bounds.height)
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            scroller.contentOffset.x = max(0, contentSize.width - bounds.width)
        }
    }
}

/// A formula on its own inside another block: as wide as the line. Copies as it was written.
final class MarkdownDisplayMathAttachment: RichTextAttachment {
    private let mathView: MarkdownDisplayMathView
    private let source: String

    @MainActor
    init(id: AnyHashable, latex: String, style: MarkdownStyle) {
        source = latex
        mathView = MarkdownDisplayMathView()
        super.init(id: id, sizing: .fittingLineFragment)
        mathView.configure(latex: latex, style: style)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    override var contentView: UIView { mathView }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? {
        CGSize(width: proposal.width, height: mathView.height(forWidth: proposal.width))
    }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}
