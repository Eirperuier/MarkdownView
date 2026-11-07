//
//  MarkdownCodeHeaderView.swift
//  MarkdownUIKit
//
//  The block's header and its bottom button, as one picture each: language, expand, copy and the
//  mode switch. Nothing here is a view per control, so a row keeps its view count down.
//

import FlooUIKit
import MarkdownCore
import UIKit

/// Sizes a layout gives what's in a header.
@MainActor
enum MarkdownCodeMetrics {
    static let verticalPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 16
    static let spacing: CGFloat = 8
    static let iconSide: CGFloat = 14
    static let iconSpacing: CGFloat = 5
    static let separator: CGFloat = 1
    static let moreSeparator: CGFloat = 1
    static var hasBorderedButtons: Bool { UIDevice.current.userInterfaceIdiom == .mac }
    /// A bordered button on the Mac: this much around its label.
    static let borderedHorizontal: CGFloat = 12
    static let borderedVertical: CGFloat = 4
    static let borderedRadius: CGFloat = 6

    static func footnote(_ style: MarkdownStyle) -> UIFont {
        UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: style.contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) })
    }

    static func size(of text: NSAttributedString) -> CGSize {
        let size = text.size()
        return CGSize(width: markdownPixelCeil(size.width), height: markdownPixelCeil(size.height))
    }
}

@MainActor
final class MarkdownCodeHeaderView: UIView {
    var pressed: MarkdownCodeRegion? {
        didSet { if pressed != oldValue { setNeedsDisplay() } }
    }

    private var language: String?
    private var showsPicker = false
    private var isPreview = true
    private var showsExpand = false
    private var isCopied = false
    private var style = MarkdownStyle()
    private var parts: Parts?
    /// While the mark changes over, it's in views of its own.
    private var copyTransition: [UIView] = []

    private struct Parts {
        var height: CGFloat = 0
        var rowTop: CGFloat = 0
        var picker: CGRect?
        var previewSegment: CGRect = .zero
        var codeSegment: CGRect = .zero
        var iconBox: CGRect?
        var icon: UIImage?
        var badge: NSAttributedString?
        var badgeBox: CGRect = .zero
        var badgeOrigin: CGPoint = .zero
        var label: NSAttributedString?
        var labelOrigin: CGPoint = .zero
        var languageRect: CGRect = .zero
        var expand: CGRect?
        var expandSymbol: MarkdownSymbols.Scaled?
        var copyRect: CGRect = .zero
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = nil
        contentMode = .redraw
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownCodeHeaderView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(language: String?, showsPicker: Bool, isPreview: Bool, showsExpand: Bool, isCopied: Bool, style: MarkdownStyle) {
        guard language != self.language || showsPicker != self.showsPicker || isPreview != self.isPreview
            || showsExpand != self.showsExpand || isCopied != self.isCopied || style.contentSizeCategory != self.style.contentSizeCategory || parts == nil else { return }
        self.language = language
        self.showsPicker = showsPicker
        self.isPreview = isPreview
        self.showsExpand = showsExpand
        self.isCopied = isCopied
        self.style = style
        parts = makeParts()
        setNeedsDisplay()
    }

    func height() -> CGFloat { parts?.height ?? 0 }

    /// The tile behind a language's letters, in a shape layer of the block's.
    var badgeBox: CGRect? { parts?.badge == nil ? nil : parts?.badgeBox }
    /// The switch's track and its chosen segment, the same.
    var pickerTrack: CGRect? { parts?.picker }
    var pickerThumb: CGRect? { parts?.picker == nil ? nil : (isPreview ? parts?.previewSegment : parts?.codeSegment) }

    /// The bordered button's ground, in a shape layer of the block's.
    var expandBorder: CGRect? { MarkdownCodeMetrics.hasBorderedButtons ? parts?.expand : nil }

    var languageLabel: String { language?.localizedCapitalized ?? "" }
    var languageRect: CGRect { parts?.languageRect ?? .zero }

    func rect(of region: MarkdownCodeRegion) -> CGRect? {
        guard let parts else { return nil }
        switch region {
        case .preview: return parts.picker == nil ? nil : parts.previewSegment
        case .code: return parts.picker == nil ? nil : parts.codeSegment
        case .expand: return parts.expand
        case .copy: return copyRect(in: bounds.width)
        case .more: return nil
        }
    }

    func region(at point: CGPoint) -> MarkdownCodeRegion? {
        for region: MarkdownCodeRegion in [.preview, .code, .expand, .copy] {
            if let rect = rect(of: region), rect.insetBy(dx: -4, dy: -6).contains(point) { return region }
        }
        return nil
    }

    private func copyLabel(_ copied: Bool) -> NSAttributedString {
        NSAttributedString(string: copied ? "Copied" : "Copy", attributes: [
            .font: MarkdownCodeMetrics.footnote(style),
            .foregroundColor: UIColor.floo(.markdownCodeAction),
        ])
    }

    private func copySymbol(_ copied: Bool) -> UIImage? {
        MarkdownSymbols.image(copied ? "checkmark" : "square.on.square", pointSize: MarkdownCodeMetrics.footnote(style).pointSize)
    }

    /// The width a Label's symbol takes, and its gap: a Label sets its icon in a box.
    private func copySize(_ copied: Bool) -> (symbolBox: CGSize, label: CGSize, total: CGSize) {
        let label = MarkdownCodeMetrics.size(of: copyLabel(copied))
        let symbol = copySymbol(copied).map { MarkdownSymbols.laidOutSize($0) } ?? .zero
        let gap: CGFloat = 8
        // A Label comes a point taller than either.
        return (symbol, label, CGSize(width: symbol.width + gap + label.width, height: max(symbol.height, label.height) + (MarkdownCodeMetrics.hasBorderedButtons ? 1 : 0)))
    }

    private func copyRect(in width: CGFloat) -> CGRect {
        guard let parts else { return .zero }
        let size = copySize(isCopied).total
        // The button's -4 each side.
        let x = width - MarkdownCodeMetrics.horizontalPadding + 4 - size.width
        return CGRect(x: x, y: parts.rowTop + (rowHeight(parts) - size.height) / 2, width: size.width, height: size.height)
    }

    private func rowHeight(_ parts: Parts) -> CGFloat {
        parts.height - MarkdownCodeMetrics.separator - MarkdownCodeMetrics.verticalPadding * 2
    }

    private func makeParts() -> Parts {
        typealias M = MarkdownCodeMetrics
        var parts = Parts()
        let footnote = M.footnote(style)
        let secondary = UIColor.floo(.markdownCodeLanguage)

        // First what sets the row's height.
        var rowHeight = copySize(isCopied).total.height
        let label = language.map { NSAttributedString(string: $0.localizedCapitalized, attributes: [.font: footnote, .foregroundColor: secondary]) }
        let labelSize = label.map(M.size(of:)) ?? .zero
        rowHeight = max(rowHeight, labelSize.height)
        let expandImage = showsExpand ? MarkdownSymbols.image("arrow.up.left.and.arrow.down.right", pointSize: footnote.pointSize) : nil
        let expandSize = expandImage.map { MarkdownSymbols.laidOutSize($0) } ?? .zero
        var expandBox = expandSize
        if showsExpand, M.hasBorderedButtons {
            expandBox = CGSize(width: expandSize.width + M.borderedHorizontal * 2, height: expandSize.height + M.borderedVertical * 2)
        }
        rowHeight = max(rowHeight, expandBox.height)

        var pickerBox = CGSize.zero
        var previewSize = CGSize.zero, codeSize = CGSize.zero
        if showsPicker {
            let semibold = UIFont.systemFont(ofSize: 11, weight: .semibold)
            previewSize = M.size(of: NSAttributedString(string: "Preview", attributes: [.font: semibold]))
            codeSize = M.size(of: NSAttributedString(string: "Code", attributes: [.font: semibold]))
            pickerBox = CGSize(
                width: previewSize.width + codeSize.width + 8 * 4 + 2 + 2 * 2,
                height: max(previewSize.height, codeSize.height) + 3 * 2 + 2 * 2
            )
            // The switch hangs 2 past the row each way.
            rowHeight = max(rowHeight, pickerBox.height - 4)
        }

        parts.height = rowHeight + M.verticalPadding * 2 + M.separator
        parts.rowTop = M.verticalPadding

        // Then along the row.
        var x = M.horizontalPadding
        func centred(_ height: CGFloat) -> CGFloat { markdownPixelRound(parts.rowTop + (rowHeight - height) / 2) }
        if showsPicker {
            let y = centred(pickerBox.height)
            parts.picker = CGRect(x: x, y: y, width: pickerBox.width, height: pickerBox.height)
            let segmentHeight = pickerBox.height - 4
            parts.previewSegment = CGRect(x: x + 2, y: y + 2, width: previewSize.width + 16, height: segmentHeight)
            parts.codeSegment = CGRect(x: parts.previewSegment.maxX + 2, y: y + 2, width: codeSize.width + 16, height: segmentHeight)
            x += pickerBox.width + M.spacing
        }
        if let language {
            let start = x
            switch MarkdownCodeLanguageIcon(language: language) {
            case .asset(let name):
                parts.icon = UIImage(named: name, in: MarkdownCodeAssets.bundle, compatibleWith: nil)
                let box = CGRect(x: x, y: centred(M.iconSide), width: M.iconSide, height: M.iconSide)
                parts.iconBox = box
                x += M.iconSide
            case .badge(let letters):
                let text = NSAttributedString(string: letters, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: UIColor.floo(.markdownCodeBadgeText),
                ])
                let size = M.size(of: text)
                let box = CGSize(width: size.width + 8, height: size.height + 4)
                parts.badgeBox = CGRect(x: x, y: centred(box.height), width: box.width, height: box.height)
                parts.badge = text
                parts.badgeOrigin = CGPoint(x: x + 4, y: parts.badgeBox.minY + 2)
                x += box.width
            }
            x += M.iconSpacing
            parts.label = label
            parts.labelOrigin = CGPoint(x: x, y: centred(labelSize.height))
            x += labelSize.width
            parts.languageRect = CGRect(x: start, y: parts.rowTop, width: x - start, height: rowHeight)
            x += M.spacing
        }
        if showsExpand, let expandImage {
            let box = CGRect(x: x, y: centred(expandBox.height), width: expandBox.width, height: expandBox.height)
            parts.expand = box
            parts.expandSymbol = Self.placed(expandImage, in: box)
        }
        return parts
    }

    override func draw(_ rect: CGRect) {
        guard let parts, let context = UIGraphicsGetCurrentContext() else { return }
        typealias M = MarkdownCodeMetrics
        if let picker = parts.picker { drawPicker(picker, parts: parts) }
        if let box = parts.iconBox, let icon = parts.icon { icon.draw(in: box) }
        parts.badge?.draw(at: parts.badgeOrigin)
        parts.label?.draw(at: parts.labelOrigin)
        if parts.expand != nil {
            context.saveGState()
            if pressed == .expand { context.setAlpha(0.6) }
            parts.expandSymbol.map { Self.draw($0, color: UIColor.floo(.markdownCodeSecondaryAction)) }
            context.restoreGState()
        }
        if copyTransition.isEmpty {
            context.saveGState()
            if pressed == .copy { context.setAlpha(0.6) }
            drawCopy(isCopied, at: copyRect(in: bounds.width).origin)
            context.restoreGState()
        }
    }

    private func drawCopy(_ copied: Bool, at origin: CGPoint) {
        let size = copySize(copied)
        let box = CGRect(x: origin.x, y: origin.y, width: size.symbolBox.width, height: size.total.height)
        if let image = copySymbol(copied) {
            Self.draw(Self.placed(image, in: box), color: UIColor.floo(.markdownCodeAction))
        }
        copyLabel(copied).draw(at: CGPoint(x: origin.x + size.total.width - size.label.width, y: origin.y + (size.total.height - size.label.height) / 2))
    }

    /// A symbol at its own size, its layout size centred in `box`, its corner on the pixel grid.
    private static func placed(_ image: UIImage, in box: CGRect) -> MarkdownSymbols.Scaled {
        let size = MarkdownSymbols.laidOutSize(image)
        // A half pixel goes up.
        let y = ((box.midY - size.height / 2) * markdownPixelScale - 0.5 - 1e-6).rounded(.up) / markdownPixelScale
        let corner = CGPoint(x: markdownPixelRound(box.midX - size.width / 2), y: y)
        return MarkdownSymbols.Scaled(image: image, frame: CGRect(origin: corner, size: image.size))
    }

    private static func draw(_ symbol: MarkdownSymbols.Scaled, color: UIColor) {
        symbol.image.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: symbol.frame)
    }

    private func drawPicker(_ picker: CGRect, parts: Parts) {
        for (title, rect, selected) in [("Preview", parts.previewSegment, isPreview), ("Code", parts.codeSegment, !isPreview)] {
            let text = NSAttributedString(string: title, attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
                .foregroundColor: UIColor.floo(selected ? .markdownCodePickerText : .markdownCodePickerOtherText),
            ])
            let size = MarkdownCodeMetrics.size(of: text)
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: markdownPixelRound(rect.midY - size.height / 2)))
        }
    }

    // MARK: The mark changing over

    /// Old out, new in, each fading and scaling. In views only while it lasts.
    func setCopied(_ copied: Bool) {
        guard copied != isCopied else { return }
        let old = makeCopyMark(isCopied)
        let new = makeCopyMark(copied)
        isCopied = copied
        new.alpha = 0
        new.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        addSubview(old)
        addSubview(new)
        copyTransition.forEach { $0.removeFromSuperview() }
        copyTransition = [old, new]
        setNeedsDisplay()
        FlooMotion.markdownFeedback.animate({
            old.alpha = 0
            old.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
            new.alpha = 1
            new.transform = .identity
        }, completion: { [weak self, weak old, weak new] _ in
            old?.removeFromSuperview()
            new?.removeFromSuperview()
            guard let self, self.copyTransition.first === old else { return }
            self.copyTransition = []
            self.setNeedsDisplay()
        })
    }

    private func makeCopyMark(_ copied: Bool) -> UIView {
        let size = copySize(copied).total
        let origin = CGPoint(x: bounds.width - MarkdownCodeMetrics.horizontalPadding + 4 - size.width, y: copyRect(in: bounds.width).minY)
        let mark = MarkdownCodeDrawnPart(frame: CGRect(origin: origin, size: size))
        mark.drawing = { [weak self] in self?.drawCopy(copied, at: .zero) }
        return mark
    }
}

/// A piece of a picture for as long as it moves.
private final class MarkdownCodeDrawnPart: UIView {
    var drawing: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = nil
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        drawing?()
    }
}

/// A line and "Show the Remaining N lines".
@MainActor
final class MarkdownCodeMoreView: UIView {
    var isPressed = false {
        didSet { if isPressed != oldValue { setNeedsDisplay() } }
    }

    private var text: NSAttributedString?
    private var textSize = CGSize.zero
    private var unroundedWidth: CGFloat = 0
    private(set) var label = ""

    private static let padding: CGFloat = 10
    private static let separator: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = nil
        contentMode = .redraw
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownCodeMoreView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(remaining: Int, style: MarkdownStyle) {
        let new = "Show the Remaining \(remaining) line\(remaining == 1 ? "" : "s")"
        guard new != label else { return }
        label = new
        let font = MarkdownCodeMetrics.footnote(style)
        let attributed = NSMutableAttributedString(string: new, attributes: [
            .font: font,
            .foregroundColor: UIColor.floo(.markdownCodeSecondaryAction),
        ])
        // The number's digits are monospaced.
        let digits = (new as NSString).range(of: "\(remaining)")
        attributed.addAttribute(.font, value: UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular), range: digits)
        text = attributed
        textSize = MarkdownCodeMetrics.size(of: attributed)
        unroundedWidth = attributed.size().width
        setNeedsDisplay()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        Self.separator + textSize.height + Self.padding * 2 + borderExtra * 2
    }

    private var borderExtra: CGFloat { MarkdownCodeMetrics.hasBorderedButtons ? MarkdownCodeMetrics.borderedVertical : 0 }

    var buttonRect: CGRect {
        CGRect(x: 0, y: Self.separator, width: bounds.width, height: bounds.height - Self.separator)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        if isPressed { context.setAlpha(0.6) }
        // Its box is on the pixel grid, up to a pixel wide, the text centred inside it.
        let x = markdownPixelRound((bounds.width - textSize.width) / 2) + (textSize.width - unroundedWidth) / 2
        text?.draw(at: CGPoint(x: x, y: Self.separator + Self.padding + borderExtra))
        context.restoreGState()
    }
}
