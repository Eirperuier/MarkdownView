//
//  MarkdownCodeBoxView.swift
//  MarkdownUIKit
//
//  A code block as DocKit draws it, after Craft: a thin border, a gutter of line numbers and its
//  line, the code beside it scrolling sideways. No header, no stripes, no line limit. It only
//  shows: selecting text is the text view's own, and nothing here edits.
//
//   - The box, gutter and lines are shape layers; the numbers are drawn into layers of their own.
//     A row costs the text's view, a scroll view only when a line is too long, and no more.
//   - The height comes from the line count alone: nothing's laid out to know it.
//   - Colours from a highlight are rendering attributes, which lay nothing out.
//

import FlooUIKit
import MarkdownCore
import RichTextCore
import UIKit

@MainActor
public final class MarkdownCodeBoxView: UIView, MarkdownCodeDisplay {
    var onHeightChange: (() -> Void)?

    private var code = ""
    private var language: String?
    private var style = MarkdownStyle()
    private var lines = MarkdownCodeLines(code: "")
    private var metrics = MarkdownCodeBoxMetrics(bodySize: 17)
    private var reveal: MarkdownReveal?

    private let boxFill = CAShapeLayer()
    private let gutterFill = CAShapeLayer()
    private let separator = CAShapeLayer()
    private let boxBorder = CAShapeLayer()
    private let numbers = MarkdownCodeGutterNumbers()
    private let host = MarkdownTextHost(textView: false)
    private var hostIsShowing = false
    private var scroller: MarkdownCodeScrollView?

    private var shownText = ""
    private var textWidth: (text: String, width: CGFloat)?
    private var visibleLineCount = Int.max
    private var pathKey: PathKey?
    private let highlight = MarkdownCodeHighlightLoader()
    private let fragments = MarkdownCodeBoxFragments()
    private lazy var lineReveal = {
        let reveal = MarkdownCodeLineReveal(view: self)
        reveal.onChange = { [weak self] in self?.applyVisibleLines(animated: true) }
        return reveal
    }()

    private struct PathKey: Equatable {
        var size: CGSize
        var visible: Int
        var gutter: CGFloat
    }

    /// A drawn text past this many lines would be one enormous picture: a text view lays out
    /// what's on screen.
    private static let drawnLineLimit = 200

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        boxBorder.fillColor = nil
        boxBorder.lineWidth = MarkdownCodeBoxMetrics.border
        for shape in [boxFill, gutterFill, separator, boxBorder] {
            layer.addSublayer(shape)
        }
        numbers.host = layer
        highlight.apply = { [weak self] tokens in
            guard let self, self.hostIsShowing else { return false }
            self.host.setRenderingColors(MarkdownCodeTokenColors.runs(tokens, upTo: (self.shownText as NSString).length))
            return true
        }
        applyColors()
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownCodeBoxView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        lineReveal.stop()
        host.release()
    }

    // MARK: Content

    /// Shows `code`. The same block again, as it streams, grows what's there.
    public func configure(code: String, language: String?, style: MarkdownStyle, reveal: MarkdownReveal? = nil) {
        let changed = code != self.code || language != self.language
        self.code = code
        self.language = language
        self.style = style
        self.reveal = reveal.map(Self.codeReveal)
        lines = MarkdownCodeLines(code: code)
        metrics = MarkdownCodeBoxMetrics(bodySize: style.resolvedBodyTextSize)
        if reveal != nil { lineReveal.measure(code) }
        pathKey = nil
        showLines()
        lineReveal.follow(self.reveal?.manager)
        applyVisibleLines(animated: false)
        if changed { showHighlight() }
        setNeedsLayout()
    }

    /// A reveal coming to or leaving what shows, with no relayout.
    func setReveal(_ reveal: MarkdownReveal?) {
        let codeReveal = reveal.map(Self.codeReveal)
        self.reveal = codeReveal
        if codeReveal != nil { lineReveal.measure(code) }
        if hostIsShowing { host.setReveal(codeReveal) }
        lineReveal.follow(codeReveal?.manager)
        applyVisibleLines(animated: false)
    }

    private static func codeReveal(_ reveal: MarkdownReveal) -> MarkdownReveal {
        MarkdownReveal(manager: reveal.manager, style: MarkdownRevealStyle(motion: .markdownCodeReveal, highlight: .color(.clear)))
    }

    /// Lets its text view go back to the pool.
    func prepareForReuse() {
        highlight.reset()
        lineReveal.stop()
        if hostIsShowing {
            host.release()
            host.view.removeFromSuperview()
        }
        hostIsShowing = false
        shownText = ""
        code = ""
        language = nil
        visibleLineCount = Int.max
        alpha = 1
    }

    private func showLines() {
        let shown = lines.lines.joined(separator: "\n")
        let attributed = NSAttributedString(string: shown, attributes: MarkdownCodeBlockView.attributes(
            font: metrics.font,
            line: metrics.font.lineHeight,
            scrolls: true,
            rowHeight: metrics.pitch
        ))
        let text = MarkdownText(
            attributed: attributed,
            revealTotal: code.count,
            storageToPlain: Array(0..<shown.count),
            topEdgeInset: 0,
            bottomEdgeInset: 0
        )
        var hostStyle = style
        hostStyle.typography.paragraphAlignment = .natural
        if lines.count > Self.drawnLineLimit { hostStyle.drawsTextUntilTouched = false }
        if !hostIsShowing {
            // Its fragments are made as its text goes in.
            if !hostStyle.drawsTextUntilTouched, reveal == nil { offsetFragments(of: host.textView) }
            host.apply(text, style: hostStyle, reveal: reveal)
            hostIsShowing = true
        } else if shown != shownText {
            host.update(text, style: hostStyle, reveal: reveal)
            // What changed wasn't only a tail: the old colours don't fit any more.
            if !shown.hasPrefix(shownText) { host.setRenderingColors([]) }
        } else {
            host.setReveal(reveal)
        }
        shownText = shown
    }

    // MARK: Highlighting

    private func showHighlight() {
        highlight.show(code: code, language: language, highlighter: style.codeBlock.highlighter, isOnWindow: window != nil)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            highlight.cancel()
        } else {
            showHighlight()
        }
    }

    // MARK: Reveal

    private func applyVisibleLines(animated: Bool) {
        let visible = lineReveal.visibleLines(limit: lines.count).count
        guard visible != visibleLineCount else { return }
        visibleLineCount = visible
        updatePaths(animated: animated)
        placeNumbers()
    }

    // MARK: Size

    /// The height at `width`, the same on or off a window, a line never wrapping.
    public func height(forWidth width: CGFloat) -> CGFloat {
        metrics.height(lines: lines.count)
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: height(forWidth: size.width))
    }

    private var gutterWidth: CGFloat { metrics.gutterWidth(lines: lines.count) }

    /// Where the code's text starts, from the box's edge.
    private var codeStart: CGFloat {
        MarkdownCodeBoxMetrics.border + gutterWidth + MarkdownCodeBoxMetrics.separator + metrics.codeLeading
    }

    /// `codeStart` past a whole pixel: a view stands on pixels, and its fragments draw the rest.
    private var codeOverhang: CGFloat { codeStart - markdownPixelFloor(codeStart) }

    /// Where the code goes: right of the gutter's line, inside the border.
    private var codeArea: CGRect {
        let border = MarkdownCodeBoxMetrics.border
        let x = border + gutterWidth + MarkdownCodeBoxMetrics.separator
        return CGRect(x: x, y: border, width: max(0, bounds.width - x - border), height: max(0, bounds.height - border * 2))
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        placeCode()
        updatePaths(animated: false)
        placeNumbers()
    }

    private func placeCode() {
        guard hostIsShowing else { return }
        let area = codeArea.markdownPixelAligned()
        let width = longestLine()
        let leading = markdownPixelFloor(codeStart) - area.minX
        let trailing = metrics.codeLeading
        let top = metrics.edge + metrics.gap
        let height = CGFloat(lines.count) * metrics.pitch
        let view = host.view
        let content = ceil(leading + width + trailing)
        if content > area.width {
            let scroller = self.scroller ?? MarkdownCodeScrollView()
            if self.scroller == nil {
                addSubview(scroller)
                self.scroller = scroller
            }
            if scroller.frame != area { scroller.frame = area }
            scroller.contentSize = CGSize(width: content, height: area.height)
            if view.superview !== scroller { scroller.addSubview(view) }
            host.place(CGRect(x: leading, y: top, width: width, height: height).markdownPixelAligned())
        } else {
            if view.superview !== self { addSubview(view) }
            scroller?.removeFromSuperview()
            scroller = nil
            host.place(CGRect(x: area.minX + leading, y: area.minY + top, width: width, height: height).markdownPixelAligned())
        }
    }

    /// A reveal has the fragments' delegate; drawn text has its own. Off a pixel by less than one,
    /// which shows only in the antialiasing, they can do without.
    private func offsetFragments(of view: UITextView) {
        fragments.overhang = codeOverhang
        view.textLayoutManager?.delegate = fragments
    }

    /// As wide as the longest line, with room to spare so none wraps. By count where every
    /// character is a plain one of a fixed width.
    private func longestLine() -> CGFloat {
        if let textWidth, textWidth.text == shownText { return textWidth.width }
        let font = metrics.font
        let digit = metrics.digit
        var widest: CGFloat = 0
        for line in lines.lines {
            let utf8 = line.utf8
            let width = utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
                ? CGFloat(utf8.count) * digit
                : (line as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, width)
        }
        let width = markdownPixelCeil(widest + codeOverhang) + 1
        textWidth = (shownText, width)
        return width
    }

    // MARK: For a host

    /// The text view inside, made if it isn't there yet.
    var textView: UITextView? { hostIsShowing ? host.textView : nil }

    /// The code's layout fragments, for what proves nothing was laid out again.
    var layoutFragmentIDs: [ObjectIdentifier] { hostIsShowing ? host.layoutFragmentIDs : [] }

    // MARK: Drawing

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let traits = traitCollection
        boxFill.fillColor = UIColor.floo(.markdownCodeBoxFill).resolvedColor(with: traits).cgColor
        gutterFill.fillColor = UIColor.floo(.markdownCodeBoxGutter).resolvedColor(with: traits).cgColor
        separator.fillColor = UIColor.floo(.markdownCodeBoxSeparator).resolvedColor(with: traits).cgColor
        boxBorder.strokeColor = UIColor.floo(.markdownCodeBoxBorder).resolvedColor(with: traits).cgColor
        numbers.color = UIColor.floo(.markdownCodeBoxLineNumber).resolvedColor(with: traits)
        CATransaction.commit()
    }

    private func placeNumbers() {
        numbers.show(count: min(visibleLineCount, lines.count), metrics: metrics, x: MarkdownCodeBoxMetrics.border, width: gutterWidth, scale: markdownPixelScale)
    }

    /// The box as far as a reveal has got.
    private func updatePaths(animated: Bool) {
        guard bounds.width > 0 else { return }
        let key = PathKey(size: bounds.size, visible: visibleLineCount, gutter: gutterWidth)
        guard key != pathKey else { return }
        pathKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let border = MarkdownCodeBoxMetrics.border
        let radius = MarkdownCodeBoxMetrics.radius
        var height = bounds.height
        if lineReveal.isRevealing { height = min(height, metrics.height(lines: min(visibleLineCount, lines.count))) }
        let rect = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        let inner = height - border * 2
        let line = CGRect(x: border + gutterWidth, y: border, width: MarkdownCodeBoxMetrics.separator, height: inner).markdownPixelAligned()
        let paths: [(CAShapeLayer, CGPath)] = [
            (boxFill, UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath),
            (boxBorder, UIBezierPath(roundedRect: rect.insetBy(dx: border / 2, dy: border / 2), cornerRadius: radius - border / 2).cgPath),
            (gutterFill, UIBezierPath(
                roundedRect: CGRect(x: border, y: border, width: gutterWidth, height: inner),
                byRoundingCorners: [.topLeft, .bottomLeft],
                cornerRadii: CGSize(width: radius - border, height: radius - border)
            ).cgPath),
            (separator, CGPath(rect: line, transform: nil)),
        ]
        for (shape, path) in paths {
            if animated, shape.path != nil {
                FlooMotion.markdownLayout.animate(shape, "path", to: path)
            } else {
                shape.removeAnimation(forKey: "dev.floo.uikit.path")
                shape.path = path
            }
        }
    }
}

/// The gutter's numbers, drawn into a layer per so many lines: a long block's would be one
/// enormous picture, and a stream's new line draws only itself.
@MainActor
final class MarkdownCodeGutterNumbers {
    private static let pageLines = 128

    weak var host: CALayer?
    var color = UIColor.tertiaryLabel {
        didSet {
            for page in pages {
                page.color = color
                page.setNeedsDisplay()
            }
        }
    }

    private var pages: [MarkdownCodeGutterPage] = []
    private var shown: (count: Int, x: CGFloat, width: CGFloat, pitch: CGFloat, top: CGFloat, font: UIFont)?

    func show(count: Int, metrics: MarkdownCodeBoxMetrics, x: CGFloat, width: CGFloat, scale: CGFloat) {
        let top = MarkdownCodeBoxMetrics.border + metrics.edge
        let pitch = metrics.pitch
        let font = metrics.font
        let same = shown.map { $0.x == x && $0.width == width && $0.pitch == pitch && $0.top == top && $0.font == font } ?? false
        if same, shown?.count == count { return }
        let pageCount = count == 0 ? 0 : (count - 1) / Self.pageLines + 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        while pages.count > pageCount { pages.removeLast().removeFromSuperlayer() }
        while pages.count < pageCount {
            let page = MarkdownCodeGutterPage()
            page.contentsScale = scale
            page.color = color
            host?.addSublayer(page)
            pages.append(page)
        }
        let trailing = width - metrics.numberTrailing
        for (index, page) in pages.enumerated() {
            let first = index * Self.pageLines
            let lines = min(count - first, Self.pageLines)
            let frame = CGRect(x: x, y: top + CGFloat(first) * pitch, width: width, height: CGFloat(Self.pageLines) * pitch)
            page.frame = frame
            let changed = page.configure(first: first + 1, lines: lines, pitch: pitch, lineHeight: metrics.lineHeight, trailing: trailing, font: font)
            if !same { page.setNeedsDisplay() } else if changed.count > 0 {
                page.setNeedsDisplay(CGRect(x: 0, y: CGFloat(changed.lowerBound) * pitch, width: width, height: CGFloat(changed.count) * pitch))
            }
        }
        shown = (count, x, width, pitch, top, font)
    }
}

/// One run of a gutter's numbers.
final class MarkdownCodeGutterPage: CALayer {
    nonisolated(unsafe) var color = UIColor.tertiaryLabel
    private nonisolated(unsafe) var first = 1
    private nonisolated(unsafe) var lines = 0
    private nonisolated(unsafe) var pitch: CGFloat = 0
    private nonisolated(unsafe) var lineHeight: CGFloat = 0
    private nonisolated(unsafe) var trailing: CGFloat = 0
    private nonisolated(unsafe) var font = UIFont.systemFont(ofSize: 11)

    /// Which of its lines differ now, by position.
    @MainActor
    func configure(first: Int, lines: Int, pitch: CGFloat, lineHeight: CGFloat, trailing: CGFloat, font: UIFont) -> Range<Int> {
        let old = self.lines
        self.first = first
        self.lines = lines
        self.pitch = pitch
        self.lineHeight = lineHeight
        self.trailing = trailing
        self.font = font
        return min(old, lines)..<max(old, lines)
    }

    /// Its contents change with no fade.
    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in context: CGContext) {
        guard lines > 0 else { return }
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let clip = context.boundingBoxOfClipPath
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let scale = contentsScale
        for index in 0..<lines {
            let y = CGFloat(index) * pitch
            guard y + pitch > clip.minY, y < clip.maxY else { continue }
            let number = String(first + index) as NSString
            // On the pixel grid, as a layout puts a label: its size up to a pixel, then placed.
            let width = (number.size(withAttributes: attributes).width * scale).rounded(.up) / scale
            number.draw(at: CGPoint(
                x: ((trailing - width) * scale).rounded() / scale,
                y: ((pitch - lineHeight) / 2 * scale).rounded(.down) / scale + y
            ), withAttributes: attributes)
        }
    }
}

/// Makes a text view's fragments draw off the pixel its lines stand on.
final class MarkdownCodeBoxFragments: NSObject, NSTextLayoutManagerDelegate {
    nonisolated(unsafe) var overhang: CGFloat = 0

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = MarkdownCodeBoxFragment(textElement: textElement, range: textElement.elementRange)
        fragment.overhang = overhang
        return fragment
    }
}

final class MarkdownCodeBoxFragment: NSTextLayoutFragment {
    nonisolated(unsafe) var overhang: CGFloat = 0

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.insetBy(dx: -1, dy: 0) }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: CGPoint(x: point.x + overhang, y: point.y), in: context)
    }
}
