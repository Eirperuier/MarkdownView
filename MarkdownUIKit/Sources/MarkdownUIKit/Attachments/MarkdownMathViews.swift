//
//  MarkdownMathViews.swift
//  MarkdownUIKit
//
//  Maths as plain views: LaTeXCore gives an image and its metrics, a UIImageView shows it. A
//  template image takes the role's colour as a tint. A formula with `\color` has its colours in
//  the image, so it's drawn again when the role's colour changes. What LaTeX can't read shows
//  as its source.
//

import LaTeXCore
import MarkdownCore
import RichTextCore
import UIKit

@MainActor
enum MarkdownMath {
    /// The formula's pieces. `latex` is as written, with its delimiters; a tree's has none.
    static func piece(latex: String, kind: LaTeXMathPiece.Kind, xHeight: CGFloat, foreground: String) -> LaTeXMathPiece? {
        let options = LaTeXMathOptions(displayScale: markdownPixelScale, explicitColorForeground: foreground)
        let size = LaTeXMathSize.xHeight(xHeight)
        let pieces = LaTeXMathRenderer.render(.equations(latex), size: size, options: options)
        if let equation = pieces.first(where: { $0.kind != .text }) { return equation }
        return LaTeXMathRenderer.render(kind == .displayEquation ? .display(latex) : .inline(latex), size: size, options: options).first
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

    /// A line of text in `font`, its leading in, as a layout measures it.
    static func lineHeight(_ font: UIFont) -> CGFloat {
        markdownPixelCeil(font.ascender - font.descender + font.leading)
    }

    /// What's below a line's baseline: the font's, and its leading, less a pixel a layout rounds
    /// off.
    static func belowBaseline(_ font: UIFont) -> CGFloat {
        font.leading - font.descender - 1 / markdownPixelScale
    }

    /// A line holding an image `height` tall on its baseline.
    static func imageLineHeight(_ height: CGFloat, font: UIFont) -> CGFloat {
        max(lineHeight(font), height + belowBaseline(font))
    }
}

/// A formula's image, in the role's colour.
@MainActor
final class MarkdownMathImageView: UIImageView {
    private var latex = ""
    private var kind = LaTeXMathPiece.Kind.inlineEquation
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

    func show(_ piece: LaTeXMathPiece, latex: String, xHeight: CGFloat) {
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
        if let piece = MarkdownMath.piece(latex: latex, kind: kind, xHeight: xHeight, foreground: wanted) {
            image = withMargin(piece.image)
        }
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
private final class MarkdownMathSourceView: UIView {
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
/// as it was written, so pasting brings the formula back.
final class MarkdownInlineMathAttachment: RichTextAttachment {
    private let container: UIView
    private let fittedSize: (CGSize) -> CGSize
    private let source: String

    @MainActor
    init(id: AnyHashable, latex: String, style: MarkdownStyle) {
        let textFont = MarkdownMath.font(.body, style: style)
        let xHeight = MarkdownMath.font(style.inlineMathTextStyle, style: style).xHeight
        let piece = MarkdownMath.piece(latex: latex, kind: .inlineEquation, xHeight: xHeight, foreground: MarkdownMath.foreground(in: UITraitCollection.current))
        source = latex.hasPrefix("$") || latex.hasPrefix("\\") ? latex : "$\(latex)$"
        container = UIView()
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        if let piece, let metrics = piece.metrics, piece.image != nil {
            // TextKit puts the formula at a fractional place and the layer stays there: its
            // snapped edge would cut a row of the image.
            let view = MarkdownMathImageView()
            view.imageMargin = 1
            view.show(piece, latex: latex, xHeight: xHeight)
            let layout = Self.layout(image: metrics.imageSize, offset: metrics.baselineOffset, font: textFont)
            view.frame = CGRect(origin: layout.imageOrigin, size: metrics.imageSize).insetBy(dx: -view.imageMargin, dy: -view.imageMargin)
            container.addSubview(view)
            fittedSize = { _ in layout.size }
        } else {
            let text = NSAttributedString(
                string: (piece?.originalText ?? latex).trimmingCharacters(in: .newlines),
                attributes: [.font: textFont, .foregroundColor: UIColor.floo(.markdownMath)]
            )
            let view = MarkdownMathSourceView()
            view.text = text
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(view)
            fittedSize = { proposal in
                let size = text.boundingRect(with: CGSize(width: proposal.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
                return CGSize(width: markdownPixelCeil(size.width), height: markdownPixelCeil(size.height))
            }
        }
        super.init(id: id, sizing: .fittingLineFragment)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// As a line of text holds the image: the line's room for it, moved by the formula's offset
    /// from the baseline, which makes the box taller by that much.
    @MainActor
    private static func layout(image: CGSize, offset: CGFloat, font: UIFont) -> (size: CGSize, imageOrigin: CGPoint) {
        let line = MarkdownMath.imageLineHeight(image.height, font: font)
        let height = markdownPixelCeil(line + abs(offset))
        let top = max(0, line - MarkdownMath.belowBaseline(font) - image.height) + max(0, -offset)
        return (CGSize(width: image.width, height: height), CGPoint(x: 0, y: markdownPixelRound(top)))
    }

    @MainActor
    override var contentView: UIView { container }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? { fittedSize(proposal) }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}

/// A formula on its own: in a horizontal scroller as wide as the text, with blank lines above and
/// below it, centred in the height set aside for it, at the leading edge. Its height is known at
/// once if it's drawn at once, or else it starts at the height set aside and may grow.
@MainActor
final class MarkdownDisplayMathView: UIView {
    /// The height changed, after the formula came in late.
    var onHeightChange: (() -> Void)?

    private let scroller = UIScrollView()
    private let imageView = MarkdownMathImageView()
    private let sourceView = MarkdownMathSourceView()
    private var contentSize = CGSize.zero
    private var reserved: CGFloat = 0
    private var imageTop: CGFloat = 0
    private var renderTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroller.showsVerticalScrollIndicator = false
        scroller.alwaysBounceVertical = false
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.clipsToBounds = true
        addSubview(scroller)
        scroller.addSubview(imageView)
        scroller.addSubview(sourceView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { renderTask?.cancel() }

    func configure(latex: String, style: MarkdownStyle) {
        renderTask?.cancel()
        let font = MarkdownMath.font(style.displayMathTextStyle, style: style)
        reserved = MarkdownDisplayMathHeight.reserved(for: latex)
        let foreground = MarkdownMath.foreground(in: traitCollection)
        let options = LaTeXMathOptions(displayScale: markdownPixelScale, explicitColorForeground: foreground)
        let input = LaTeXMathInput.equations(latex)
        let size = LaTeXMathSize.xHeight(font.xHeight)
        if let cached = LaTeXMathRenderer.cached(input, size: size, options: options) {
            show(cached.first { $0.kind != .text } ?? cached.first, latex: latex, font: font)
        } else if style.rendersDisplayMathSynchronously {
            show(MarkdownMath.piece(latex: latex, kind: .displayEquation, xHeight: font.xHeight, foreground: foreground), latex: latex, font: font)
        } else {
            show(nil, latex: latex, font: font, isPlaceholder: true)
            renderTask = Task { [weak self] in
                let pieces = await LaTeXMathRenderer.renderAsync(input, size: size, options: options)
                guard !Task.isCancelled, let self else { return }
                self.show(pieces.first { $0.kind != .text } ?? pieces.first, latex: latex, font: font)
                self.onHeightChange?()
            }
        }
    }

    private func show(_ piece: LaTeXMathPiece?, latex: String, font: UIFont, isPlaceholder: Bool = false) {
        let line = MarkdownMath.lineHeight(font)
        if isPlaceholder {
            imageView.isHidden = true
            sourceView.isHidden = true
            contentSize = .zero
        } else if let piece, let metrics = piece.metrics, piece.image != nil {
            imageView.isHidden = false
            sourceView.isHidden = true
            imageView.show(piece, latex: latex, xHeight: font.xHeight)
            let image = metrics.imageSize
            let imageLine = MarkdownMath.imageLineHeight(image.height, font: font)
            imageTop = line + max(0, imageLine - MarkdownMath.belowBaseline(font) - image.height)
            contentSize = CGSize(width: image.width, height: markdownPixelCeil(line * 2 + imageLine))
            imageView.bounds.size = image
        } else {
            // What LaTeX can't read: its source with the blank lines, in the formula's place.
            imageView.isHidden = true
            sourceView.isHidden = false
            let text = NSAttributedString(
                string: "\n\(piece?.originalText ?? latex)\n",
                attributes: [.font: font, .foregroundColor: UIColor.floo(.markdownMath)]
            )
            sourceView.text = text
            sourceView.lineStep = line
            let size = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
            let lines = CGFloat(text.string.components(separatedBy: "\n").count)
            contentSize = CGSize(width: markdownPixelCeil(size.width), height: markdownPixelCeil(lines * line))
        }
        setNeedsLayout()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        max(reserved, contentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroller.frame = bounds
        let top = markdownPixelRound((bounds.height - contentSize.height) / 2)
        scroller.contentSize = CGSize(width: contentSize.width, height: bounds.height)
        imageView.frame = CGRect(x: 0, y: markdownPixelRound(top + imageTop), width: imageView.bounds.width, height: imageView.bounds.height)
        sourceView.frame = CGRect(x: 0, y: top, width: contentSize.width, height: contentSize.height)
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
        mathView.onHeightChange = { [weak self] in self?.contentSizeDidChange() }
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
