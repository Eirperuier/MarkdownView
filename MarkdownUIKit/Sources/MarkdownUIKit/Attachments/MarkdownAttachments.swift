//
//  MarkdownAttachments.swift
//  MarkdownUIKit
//
//  What sits inline with text: plain views a RichTextAttachment places. TextKit asks for a
//  size, the text view puts the view where it went. Each is one storage character.
//

import Markdown
import MarkdownCore
import RichTextCore
import UIKit

/// A view with a fixed size in a line.
class MarkdownViewAttachment: RichTextAttachment {
    private let view: UIView
    private let size: CGSize
    private let replacement: NSAttributedString?

    @MainActor
    init(id: AnyHashable, view: UIView, size: CGSize, replacement: String? = nil) {
        self.view = view
        self.size = size
        self.replacement = replacement.map { NSAttributedString(string: $0) }
        super.init(id: id, sizing: .fittingLineFragment)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    override var contentView: UIView { view }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? { size }

    override func replacementText() -> NSAttributedString? { replacement }
}

/// A block with nothing drawn yet: no room, and it copies as its source.
final class MarkdownEmptyAttachment: MarkdownViewAttachment {
    @MainActor
    init(id: AnyHashable, replacement: String? = nil) {
        let view = UIView()
        view.isUserInteractionEnabled = false
        super.init(id: id, view: view, size: .zero, replacement: replacement)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A flat colour in a layer, with corners. Its colour is dynamic, the layer's is resolved: it's
/// resolved again whenever a trait that colour reads changes. In a layer so it composites as a
/// shape does, with fractional edges as they fall.
@MainActor
final class MarkdownColorView: UIView {
    var color: UIColor? { didSet { applyColor() } }

    init(color: UIColor? = nil, cornerRadius: CGFloat = 0) {
        self.color = color
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        applyColor()
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownColorView, _: UITraitCollection) in
            view.applyColor()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyColor() {
        layer.backgroundColor = color?.resolvedColor(with: traitCollection).cgColor
    }
}

/// SF Symbols and icons in a view of their own, on a capsule if they have one. A template takes
/// `color`, set again when the traits that colour reads change.
///
/// TextKit puts an attachment at a fractional x and the layers stay there, as a hosted view's
/// do. The canvas has a margin, or a layer's snapped edge would cut what falls past a pixel.
/// The capsule is a layer with soft edges: drawn, its translucent colour comes out a level off.
/// An image at its natural size is a view, as a hosted image is. One scaled from a bigger size
/// is drawn, as a vector, on the pixel grid; a view of it would blur.
@MainActor
class MarkdownGlyphView: UIView {
    private final class Canvas: UIView {
        weak var owner: MarkdownGlyphView?

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.translateBy(x: MarkdownGlyphView.canvasMargin, y: MarkdownGlyphView.canvasMargin)
            owner?.drawContent()
        }
    }

    private final class VectorCanvas: UIView {
        weak var owner: MarkdownGlyphView?

        override func draw(_ rect: CGRect) {
            owner?.drawVector(origin: frame.origin)
        }
    }

    fileprivate static let canvasMargin: CGFloat = 1

    var image: UIImage? { didSet { applyImage() } }
    var color: UIColor? { didSet { applyImage() } }
    /// A symbol from `MarkdownSymbols`, its image, frame and outline.
    func show(_ symbol: MarkdownSymbols.Scaled) {
        image = symbol.image
        imageFrame = symbol.frame
        imageOutline = symbol.outline.map { ($0, symbol.outlineScale) }
    }
    /// Where the image goes, in this view.
    var imageFrame: CGRect = .zero { didSet { setNeedsLayout() } }
    /// Drawn as a vector at `imageFrame` exactly, not as a view: for a symbol scaled from a
    /// bigger size.
    /// A disc's symbol goes to the next pixel down, not the nearest: measured from a list's bullets.
    var vectorSnapsDown = false
    /// Draws this outline instead of `image`, from the corner of `imageFrame`.
    var imageOutline: (path: CGPath, scale: CGFloat)?
    var drawsImageAsVector = false {
        didSet {
            imageView.isHidden = drawsImageAsVector
            vector.isHidden = !drawsImageAsVector
        }
    }
    var imageCornerRadius: CGFloat = 0 {
        didSet {
            imageView.layer.cornerRadius = imageCornerRadius
            imageView.layer.cornerCurve = .continuous
            imageView.clipsToBounds = imageCornerRadius > 0
        }
    }
    /// The capsule behind it all.
    var capsuleColor: UIColor? {
        didSet {
            capsule.color = capsuleColor
            capsule.isHidden = capsuleColor == nil
        }
    }
    /// Its frame in this view, nil for all of it.
    var capsuleFrame: CGRect? { didSet { setNeedsLayout() } }
    var onTap: (() -> Void)? {
        didSet {
            guard onTap != nil, tapRecognizer == nil else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            addGestureRecognizer(recognizer)
            tapRecognizer = recognizer
            isUserInteractionEnabled = true
        }
    }

    private var vectorShift = CGPoint.zero
    private let canvas = Canvas()
    private let imageView = UIImageView()
    private let vector = VectorCanvas()
    private let capsule = MarkdownColorView()
    private var tapRecognizer: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        canvas.owner = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentMode = .redraw
        canvas.isUserInteractionEnabled = false
        capsule.isHidden = true
        capsule.layer.allowsEdgeAntialiasing = true
        addSubview(capsule)
        addSubview(canvas)
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        vector.owner = self
        vector.backgroundColor = .clear
        vector.isOpaque = false
        vector.contentMode = .redraw
        vector.isUserInteractionEnabled = false
        vector.isHidden = true
        addSubview(vector)
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownGlyphView, _: UITraitCollection) in
            view.canvas.setNeedsDisplay()
            view.vector.setNeedsDisplay()
            view.applyImage()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin = Self.canvasMargin
        canvas.frame = bounds.insetBy(dx: -margin, dy: -margin)
        let box = capsuleFrame ?? bounds
        capsule.frame = box
        capsule.layer.cornerRadius = min(box.width, box.height) / 2
        var snapped = imageFrame
        snapped.origin.x = markdownPixelFloor(frame.minX + imageFrame.minX) - frame.minX
        snapped.origin.y = markdownPixelRound(frame.minY + imageFrame.minY) - frame.minY
        imageView.frame = snapped
        if drawsImageAsVector {
            // On the pixel grid in the window, as a layout's layer goes, to the nearest pixel. What's
            // inside it keeps its own place.
            let shift = CGPoint(x: markdownPixelRound(frame.minX) - frame.minX, y: (vectorSnapsDown ? markdownPixelCeil(frame.minY) : markdownPixelRound(frame.minY)) - frame.minY)
            let box = bounds.insetBy(dx: -Self.canvasMargin, dy: -Self.canvasMargin).offsetBy(dx: shift.x, dy: shift.y)
            vectorShift = shift
            if vector.frame != box {
                vector.frame = box
                vector.setNeedsDisplay()
            }
        }
    }

    fileprivate func drawVector(origin: CGPoint) {
        let rect = imageFrame.offsetBy(dx: vectorShift.x - origin.x, dy: vectorShift.y - origin.y)
        if let imageOutline, let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: imageOutline.scale, y: imageOutline.scale)
            (color ?? .label).setFill()
            context.addPath(imageOutline.path)
            context.fillPath()
            context.restoreGState()
            return
        }
        guard let image else { return }
        let drawn = if let color, image.isSymbolImage || image.renderingMode == .alwaysTemplate {
            image.withTintColor(color, renderingMode: .alwaysOriginal)
        } else {
            image
        }
        drawn.draw(in: rect)
    }

    override var frame: CGRect {
        didSet {
            if frame.origin != oldValue.origin { setNeedsLayout() }
        }
    }

    @objc private func tapped() { onTap?() }

    private func applyImage() {
        guard let image, let color, image.isSymbolImage || image.renderingMode == .alwaysTemplate else {
            imageView.image = image
            return
        }
        imageView.image = image.withRenderingMode(.alwaysTemplate)
        imageView.tintColor = color
    }

    /// For what a subclass draws by hand. Text goes here.
    func drawContent() {}
}

@MainActor
enum MarkdownSymbols {
    /// A symbol at `pointSize`.
    static func image(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular, scale: UIImage.SymbolScale = .default) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: scale))
    }

    /// A symbol as a layout draws one, by frame or at a size that isn't one it was hinted for:
    /// the glyph's own outline, its alignment rect on the box. Without the outline, a big image
    /// scaled, within a pixel of it.
    struct Scaled {
        let image: UIImage
        /// Where `image` goes, or, with `outline`, the outline's corner and size.
        let frame: CGRect
        var outline: CGPath?
        var outlineScale: CGFloat = 1
    }

    /// Where a resizable, scaled-to-fit symbol goes in `box`. A layout fits the rect the symbol
    /// aligns by at the text's size (`textSize`), which is rounded to half points and is a
    /// little more than what it draws: how much of the box it fills depends on the symbol and
    /// on that size. A non-symbol image just fits.
    static func fit(_ image: UIImage, in box: CGRect, textSize: CGFloat) -> Scaled {
        guard image.isSymbolImage,
              let atText = image.applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: textSize)),
              let rect = glyph(of: atText)?.alignmentRect ?? fallbackRect(of: atText), rect.width > 0, rect.height > 0
        else {
            guard image.size.width > 0, image.size.height > 0 else { return Scaled(image: image, frame: box) }
            let scale = min(box.width / image.size.width, box.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return Scaled(image: image, frame: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
        }
        let fitted = min(box.width / rect.width, box.height / rect.height)
        let target = CGPoint(x: box.midX - rect.width * fitted / 2, y: box.midY - rect.height * fitted / 2)
        return place(atText, at: target, scale: fitted, referenceOf: image, pointSize: textSize)
    }

    /// A symbol at `pointSize`, unscaled, its layout size centred in `box`. A layout keeps that
    /// rect's corner on the pixel grid, in its host.
    static func scaled(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular, in box: CGRect) -> Scaled? {
        guard let atSize = image(name, pointSize: pointSize, weight: weight) else { return nil }
        #if targetEnvironment(macCatalyst)
        guard let rect = glyph(of: atSize)?.alignmentRect ?? fallbackRect(of: atSize) else { return nil }
        #endif
        let laidOut = laidOutSize(atSize)
        let corner = CGPoint(x: markdownPixelRound(box.midX - laidOut.width / 2), y: markdownPixelRound(box.midY - laidOut.height / 2))
        #if targetEnvironment(macCatalyst)
        let origin = glyph(of: atSize)?.unroundedOrigin ?? rect.origin
        return place(atSize, at: CGPoint(x: corner.x + origin.x, y: corner.y + origin.y), scale: 1, referenceOf: atSize, pointSize: pointSize)
        #else
        // On an iPhone the image itself comes closest: within 26 levels on a list's star, where an
        // outline is up to 254 off.
        return Scaled(image: atSize, frame: CGRect(origin: corner, size: atSize.size))
        #endif
    }

    /// `symbol` scaled, with the corner of the rect it aligns by at `target`.
    private static func place(_ symbol: UIImage, at target: CGPoint, scale: CGFloat, referenceOf source: UIImage, pointSize: CGFloat) -> Scaled {
        if let glyph = glyph(of: symbol), let outline = glyph.outline {
            return Scaled(
                image: symbol,
                frame: CGRect(origin: target, size: CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)),
                outline: outline,
                outlineScale: scale / symbol.scale
            )
        }
        let reference = source.applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: referenceSize)) ?? symbol
        let unit = scale * pointSize / referenceSize
        let corner = fallbackRect(of: reference)?.origin ?? .zero
        return Scaled(image: reference, frame: CGRect(
            x: target.x - corner.x * unit,
            y: target.y - corner.y * unit,
            width: reference.size.width * unit,
            height: reference.size.height * unit
        ))
    }

    private static let referenceSize: CGFloat = 64

    /// A symbol's size in a layout: up to a half point.
    static func laidOutSize(_ image: UIImage) -> CGSize {
        CGSize(width: markdownPixelCeil(image.size.width), height: markdownPixelCeil(image.size.height))
    }

    /// A symbol has a point each side at the sizes text has, when the glyph doesn't say.
    private static func fallbackRect(of image: UIImage) -> CGRect? {
        image.isSymbolImage ? CGRect(origin: .zero, size: image.size).insetBy(dx: 1, dy: 1) : nil
    }

    private struct Glyph {
        let alignmentRect: CGRect
        /// Where the outline starts in the image: the rect before rounding.
        var unroundedOrigin: CGPoint?
        let outline: CGPath?
    }

    /// What a layout reads and UIImage doesn't say: its `alignmentRectInsets` aren't this rect.
    /// Private and read with care: nil where it isn't there. UI only, nothing leaves the process.
    private static func glyph(of image: UIImage) -> Glyph? {
        let content = "content", vectorGlyph = "vectorGlyph", alignmentRect = "alignmentRect", path = NSSelectorFromString("CGPath")
        guard image.isSymbolImage, image.responds(to: NSSelectorFromString(content)),
              let holder = image.value(forKey: content) as? NSObject,
              holder.responds(to: NSSelectorFromString(vectorGlyph)),
              let glyph = holder.value(forKey: vectorGlyph) as? NSObject,
              glyph.responds(to: NSSelectorFromString(alignmentRect)),
              let rect = (glyph.value(forKey: alignmentRect) as? NSValue)?.cgRectValue
        else { return nil }
        let unrounded = "alignmentRectUnrounded"
        let origin = glyph.responds(to: NSSelectorFromString(unrounded)) ? (glyph.value(forKey: unrounded) as? NSValue)?.cgRectValue.origin : nil
        guard glyph.responds(to: path) else { return Glyph(alignmentRect: rect, unroundedOrigin: origin, outline: nil) }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<CGPath>?
        let outline = unsafeBitCast(glyph.method(for: path), to: Getter.self)(glyph, path)?.takeUnretainedValue()
        return Glyph(alignmentRect: rect, unroundedOrigin: origin, outline: outline)
    }
}

/// A task's mark: filled and tinted when done, a ring in secondary when not.
final class MarkdownTaskAttachment: MarkdownViewAttachment {
    @MainActor
    init(id: AnyHashable, checked: Bool, size: CGFloat) {
        let view = MarkdownGlyphView()
        let image = MarkdownSymbols.image(checked ? "checkmark.circle.fill" : "circle", pointSize: size)
        view.image = image
        view.color = .floo(checked ? .markdownTaskDone : .markdownTaskOpen)
        let bounds = image?.size ?? CGSize(width: size, height: size)
        view.imageFrame = CGRect(origin: .zero, size: bounds)
        super.init(id: id, view: view, size: bounds, replacement: checked ? "[x]" : "[ ]")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A custom symbol bullet: a symbol on a disc `diameter` wide (the marker's width).
final class MarkdownListSymbolAttachment: MarkdownViewAttachment {
    @MainActor
    init(id: AnyHashable, systemName: String, diameter: CGFloat) {
        let view = MarkdownGlyphView()
        view.color = .floo(.markdownOnSymbolBullet)
        view.capsuleColor = .floo(.markdownSymbolBullet)
        // A layout sizes the disc up to a half point.
        let side = markdownPixelCeil(diameter)
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        if let symbol = MarkdownSymbols.scaled(systemName, pointSize: diameter * 0.52, weight: .semibold, in: box) {
            view.show(symbol)
            view.drawsImageAsVector = symbol.outline != nil
            view.vectorSnapsDown = true
        }
        // It copies as a standard bullet.
        super.init(id: id, view: view, size: box.size, replacement: "- ")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A custom link's leading symbol: at the text's size, in its colour, tapped as the link. Room
/// after it is the NBSP in the text, which also holds it to the name at a line break.
final class MarkdownInlineSymbolAttachment: MarkdownViewAttachment {
    @MainActor
    init(id: AnyHashable, systemName: String, font: UIFont, color: UIColor, url: URL?, style: MarkdownStyle) {
        let view = MarkdownGlyphView()
        let image = MarkdownSymbols.image(systemName, pointSize: font.pointSize)
        view.image = image
        view.color = color
        let bounds = image?.size ?? .zero
        view.imageFrame = CGRect(origin: .zero, size: bounds)
        if let url, let open = style.openURL { view.onTap = { open(url) } }
        super.init(id: id, view: view, size: bounds)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A web link's site icon: the app's, or a globe in the link's colour until then or where
/// there's none. A square a little taller than the capitals, centred in the font's ascender to
/// descender (set in it as glyphs are, it sits on the text's middle), with the same room each
/// side whatever is beside it (CJK sets no space). Opens the link, as its text does.
final class MarkdownSiteIconAttachment: MarkdownViewAttachment {
    @MainActor
    init(id: AnyHashable, host: String, url: URL, font: UIFont, color: UIColor, style: MarkdownStyle) {
        let size = font.pointSize
        let side = (size * 1.07).rounded()
        let room = (size * 0.2).rounded()
        let height = max(font.ascender - font.descender, side)
        let box = CGRect(x: room, y: (height - side) / 2, width: side, height: side)
        let view = MarkdownGlyphView()
        let textSize = style.resolvedBodyTextSize
        if let icon = style.icons?.image(host) {
            view.show(MarkdownSymbols.fit(icon, in: box, textSize: textSize))
            view.color = .floo(.markdownText)
            view.drawsImageAsVector = icon.isSymbolImage
        } else {
            style.icons?.prefetch?(host)
            let inset = side / 16
            if let globe = MarkdownSymbols.image("globe", pointSize: side).map({ MarkdownSymbols.fit($0, in: box.insetBy(dx: inset, dy: inset), textSize: textSize) }) {
                view.show(globe)
            }
            view.color = color
            view.drawsImageAsVector = true
        }
        if let open = style.openURL { view.onTap = { open(url) } }
        super.init(id: id, view: view, size: CGSize(width: side + room * 2, height: height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A citation chip: icon, label and "+N" in a capsule 18 high, pressed into the body's line box
/// (a taller attachment would open the line up). Selects as one unit and copies as its label.
final class MarkdownChipAttachment: MarkdownViewAttachment {
    private final class ChipView: MarkdownGlyphView {
        var label: NSAttributedString?
        var labelOrigin: CGPoint = .zero
        var count: NSAttributedString?
        var countOrigin: CGPoint = .zero

        override func drawContent() {
            super.drawContent()
            // Without the font's leading: a footnote's is 2.49 pt on an iPhone.
            label?.draw(with: CGRect(origin: labelOrigin, size: CGSize(width: bounds.width, height: bounds.height)), options: [.usesLineFragmentOrigin], context: nil)
            count?.draw(with: CGRect(origin: countOrigin, size: CGSize(width: bounds.width, height: bounds.height)), options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    @MainActor
    init(id: AnyHashable, label: String, urls: [String], style: MarkdownStyle) {
        let category = style.contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) }
        let view = ChipView()
        let text = NSAttributedString(string: label.count > 28 ? String(label.prefix(27)) + "…" : label, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: category),
            .foregroundColor: UIColor.floo(.markdownChipText),
        ])
        let more = urls.count > 1 ? NSAttributedString(string: "+\(urls.count - 1)", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: category),
            .foregroundColor: UIColor.floo(.markdownChipCount),
        ]) : nil
        let height: CGFloat = 18
        let iconSide: CGFloat = 11
        let spacing: CGFloat = 3
        let padding: CGFloat = 7
        let textSize = CGSize(width: markdownPixelCeil(text.size().width), height: markdownPixelCeil(text.size().height))
        let moreSize = more.map { CGSize(width: markdownPixelCeil($0.size().width), height: markdownPixelCeil($0.size().height)) } ?? .zero
        var width = padding + iconSide + spacing + textSize.width + padding
        if more != nil { width += spacing + moreSize.width }

        // The icon: a tool chip's key is its whole URL, a web page's its host.
        let key: String
        if let first = urls.first {
            key = first.lowercased().hasPrefix("\(MarkdownLinkChips.toolScheme)://") ? first : (URL(string: first)?.host() ?? first)
        } else {
            key = ""
        }
        // The row is on the pixel grid in the capsule, the icon centred in the row as it falls.
        let rowHeight = max(iconSide, textSize.height, moreSize.height)
        let iconBox = CGRect(x: padding, y: markdownPixelRound((height - rowHeight) / 2) + (rowHeight - iconSide) / 2, width: iconSide, height: iconSide)
        let bodySize = style.resolvedBodyTextSize
        if let icon = style.icons?.image(key) {
            view.show(MarkdownSymbols.fit(icon, in: iconBox, textSize: bodySize))
            view.color = .floo(.markdownText)
            view.imageCornerRadius = 3
            view.drawsImageAsVector = icon.isSymbolImage
        } else {
            style.icons?.prefetch?(key)
            let image = style.icons?.placeholder?() ?? MarkdownSymbols.image("globe", pointSize: iconSide, weight: .medium)
            if let fitted = image.map({ MarkdownSymbols.fit($0, in: iconBox, textSize: bodySize) }) {
                view.show(fitted)
            } else {
                view.imageFrame = iconBox
            }
            view.color = .floo(.markdownChipText)
            view.drawsImageAsVector = image?.isSymbolImage ?? false
        }
        view.capsuleColor = .floo(.markdownChipFill)
        view.label = text
        // A half pixel goes up.
        func pixelY(_ value: CGFloat) -> CGFloat { (value * markdownPixelScale - 0.5 - 1e-6).rounded(.up) / markdownPixelScale }
        view.labelOrigin = CGPoint(x: padding + iconSide + spacing, y: pixelY((height - textSize.height) / 2))
        view.count = more
        view.countOrigin = CGPoint(x: padding + iconSide + spacing + textSize.width + spacing, y: pixelY((height - moreSize.height) / 2))
        // A tap throws the synthetic chip URL; the host decides (a sheet, say).
        if let open = style.openURL, let url = MarkdownLinkChips.chipURL(for: urls) {
            view.onTap = { open(url) }
        }
        super.init(id: id, view: view, size: CGSize(width: width, height: height), replacement: label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A topic's bubble at the end of a selection: a way in, not content, so it doesn't copy.
final class MarkdownBubbleAttachment: MarkdownViewAttachment {
    @MainActor
    init(id: AnyHashable, size: CGFloat, url: URL?, style: MarkdownStyle) {
        let view = MarkdownGlyphView()
        let image = MarkdownSymbols.image("ellipsis.bubble", pointSize: size * 0.72)
        let imageSize = image.map { MarkdownSymbols.laidOutSize($0) } ?? .zero
        let capsule = CGSize(width: imageSize.width + 10, height: imageSize.height + 5)
        view.color = .floo(.markdownBubbleIcon)
        view.capsuleColor = .floo(.markdownBubbleFill)
        view.capsuleFrame = CGRect(x: 3, y: 0, width: capsule.width, height: capsule.height)
        let inner = CGRect(x: 3 + 5, y: 2.5, width: imageSize.width, height: imageSize.height)
        if let symbol = MarkdownSymbols.scaled("ellipsis.bubble", pointSize: size * 0.72, in: inner) {
            view.show(symbol)
            view.drawsImageAsVector = symbol.outline != nil
        }
        if let url, let open = style.openURL { view.onTap = { open(url) } }
        super.init(id: id, view: view, size: CGSize(width: capsule.width + 3, height: capsule.height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A quote inside another block: its decoration around its content, as wide as the line.
final class MarkdownNestedQuoteAttachment: RichTextAttachment {
    private let quoteView: MarkdownQuoteView
    private let source: String

    @MainActor
    init(id: AnyHashable, quote: BlockQuote, style: MarkdownStyle) {
        let view = MarkdownQuoteView()
        view.clipsTextToBounds()
        let body = quote.callout?.body ?? quote
        let inner = Document(body.children.compactMap { $0 as? BlockMarkup })
        // Inside another block the quote's serif font reaches runs with no font of their own. At
        // the top level a text view sets body before that can.
        var quoteStyle = style
        let plain = style.resolvedDefaultFont
        // A text style's descriptor ignores a design: it starts from the system font.
        quoteStyle.defaultFont = UIFont.systemFont(ofSize: plain.pointSize).fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: plain.pointSize) } ?? plain
        #if targetEnvironment(macCatalyst)
        // Measured, Mac only, cause not found: a nested quote's line is 1 pt taller than a serif
        // line in TextKit 2.
        quoteStyle.roomBelowLines = 1
        #else
        // A layout's line goes up to a pixel; TextKit's stays at the font's 20.29.
        if style.isQuoted, let serif = quoteStyle.defaultFont { quoteStyle.roomBelowLines = markdownPixelCeil(serif.lineHeight) - serif.lineHeight }
        #endif
        // An image inside comes in late: this quote is measured again, and whatever it's in.
        let lateSize = MarkdownLateSize()
        quoteStyle.lateSize = lateSize
        view.configure(document: inner, callout: quote.callout?.callout, style: quoteStyle)
        quoteView = view
        source = quote.format()
        super.init(id: id, sizing: .fittingLineFragment)
        lateSize.onChange = { [weak self, weak view, outer = style.lateSize] in
            view?.textSizeDidChange()
            self?.markdownSizeDidChange(outer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    override var contentView: UIView { quoteView }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? {
        CGSize(width: proposal.width, height: quoteView.height(forWidth: proposal.width))
    }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}
