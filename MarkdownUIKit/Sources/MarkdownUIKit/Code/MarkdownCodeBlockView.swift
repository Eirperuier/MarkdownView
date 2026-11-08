//
//  MarkdownCodeBlockView.swift
//  MarkdownUIKit
//
//  A fenced code block in the header look (`MarkdownCodeBlockStyle.Look.header`): a header
//  (language, expand, copy), its lines on stripes, "Show the Remaining" past 15 lines. Its parts are as few as they can be, as a row in a chat is measured
//  by the frame:
//
//   - The box and the stripes are shape layers: no picture to draw, nothing on the main thread.
//   - The header and the bottom button are a picture each, with no view per control. A touch is
//     one recogniser on the block, finding what's under it.
//   - All the lines are one text, a paragraph a line: one view, one layout, and a selection
//     goes across lines. The first touch on drawn text makes it a text view
//     (`style.drawsTextUntilTouched`).
//   - Colours from a highlight are rendering attributes on the layout manager. A token's colour
//     changes no geometry, so nothing is laid out again when it comes.
//
//  Whether lines wrap or scroll sideways comes from the style; wrapping is the default. The
//  default look is the box, `MarkdownCodeBoxView`.
//

import FlooUIKit
import MarkdownCore
import RichTextCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A custom renderer for a language's fenced blocks (a chart, a diagram). In the block's header
/// and box with a Preview/Code switch, or `bare` on its own.
public struct MarkdownCodeRenderer {
    /// No header, box or switch: only the view, which fades in when a reveal reaches it.
    public var bare: Bool
    /// A colour behind the header too, as a ground a preview gives itself goes under it.
    public var underHeader: UIColor?
    /// A view with `sizeThatFits` answering at a width.
    public var makeView: @MainActor (_ code: String, _ language: String?) -> UIView

    public init(bare: Bool = false, underHeader: UIColor? = nil, makeView: @escaping @MainActor (_ code: String, _ language: String?) -> UIView) {
        self.bare = bare
        self.underHeader = underHeader
        self.makeView = makeView
    }
}

/// How code blocks look and behave.
public struct MarkdownCodeBlockStyle {
    public enum Look: Sendable {
        /// DocKit's: a thin border, line numbers, every line, scrolling sideways. Its sizes are
        /// its own (`MarkdownCodeBoxMetrics`). A language with a renderer keeps the header, where
        /// its Preview/Code switch goes.
        case box
        /// A header with the language, copy and expand, lines on stripes, up to 15 of them.
        case header
    }

    public var look = Look.box
    /// The header look's text style; the font is the monospaced system font at its size.
    public var font = MarkdownTypography.Style(.caption1)
    /// In the header look, lines scroll sideways, at a fixed height each, rather than wrap.
    public var scrollsSideways = false
    /// In the header look, every line, rather than the first 15 and a button for the rest.
    public var showsAllLines = false
    /// Colours code; nil leaves it plain.
    public var highlighter: (any MarkdownCodeHighlighter)? = MarkdownHighlightrHighlighter()
    /// Renderers by lowercased language.
    public var renderers: [String: MarkdownCodeRenderer] = [:]
    /// Languages the renderers are off for: they show as code.
    public var disabledRenderers: Set<String> = []
    /// What shows in place of the lines (an editor), in the same header and box; nil the lines.
    public var replacement: (@MainActor () -> UIView?)?
    /// Draws the whole block a way of its own (MarkdownView's `CodeBlockStyle`); nil this one.
    public var custom: (@MainActor (_ code: String, _ language: String?, _ style: MarkdownStyle) -> UIView)?
    /// Called with the code a copy put on the pasteboard, after it's there.
    public var didCopy: (@MainActor (String) -> Void)?

    public init() {}

    func renderer(for language: String?) -> MarkdownCodeRenderer? {
        guard let language = language?.lowercased(), !disabledRenderers.contains(language) else { return nil }
        return renderers[language]
    }
}

@MainActor
public final class MarkdownCodeBlockView: UIView, UIGestureRecognizerDelegate, MarkdownCodeDisplay, MarkdownTouchTaking {
    /// The block changed height by itself: a mode switched.
    var onHeightChange: (() -> Void)?

    // What it shows.
    private var code = ""
    private var language: String?
    private var style = MarkdownStyle()
    private var lines = MarkdownCodeLines(code: "")
    private var reveal: MarkdownReveal?

    // Parts.
    private let boxFill = CAShapeLayer()
    private let boxBorder = CAShapeLayer()
    private let headerFill = CAShapeLayer()
    private let separators = CAShapeLayer()
    private let stripes = CAShapeLayer()
    private let buttonFills = CAShapeLayer()
    /// Only for those with them: what goes under a header, a language's tile, the mode switch.
    private var underHeaderFill: CAShapeLayer?
    private var badgeFill: CAShapeLayer?
    private var pickerTrack: CAShapeLayer?
    private var pickerThumb: CAShapeLayer?
    private let header = MarkdownCodeHeaderView()
    private var more: MarkdownCodeMoreView?
    private let host = MarkdownTextHost(textView: false)
    private var hostIsShowing = false
    private var scroller: MarkdownCodeScrollView?
    /// What's in place of the lines: a renderer's, an editor.
    private var content: UIView?
    private var contentOwner: AnyObject?
    private weak var sheet: MarkdownCodeSheetController?
    private var pressRecognizer: MarkdownCodePressRecognizer?

    // State.
    private var isPreview = true
    private var isCopied = false
    private var copiedTask: Task<Void, Never>?
    private var shownText = ""
    private let highlight = MarkdownCodeHighlightLoader()
    private var measured: (width: CGFloat, rows: Rows)?
    private var pathKey: PathKey?
    private var visibleLineCount = Int.max
    private var moreIsVisible = true
    private lazy var lineReveal = {
        let reveal = MarkdownCodeLineReveal(view: self)
        reveal.onChange = { [weak self] in self?.applyVisibleLines(animated: true) }
        return reveal
    }()

    /// Row by row: where each starts under the header, and where they all end.
    private struct Rows: Equatable {
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        var total: CGFloat = 0
    }

    private struct PathKey: Equatable {
        var size: CGSize
        var rows: Rows
        var visible: Int
        var headerHeight: CGFloat
        var hasMore: Bool
    }

    static let cornerRadius: CGFloat = 15
    /// A wrapped line's row: this above and below its text, 10 from each side.
    nonisolated static let lineInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    /// A row when lines scroll sideways: no line in it wraps, so it's a fixed height.
    nonisolated static let scrollingRowHeight: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        boxFill.fillRule = .nonZero
        boxBorder.fillColor = nil
        boxBorder.lineWidth = 1
        for flat in [boxFill, boxBorder, headerFill, separators, stripes, buttonFills] {
            layer.addSublayer(flat)
        }
        header.isUserInteractionEnabled = false
        addSubview(header)
        highlight.apply = { [weak self] tokens in
            guard let self, self.hostIsShowing else { return false }
            self.host.setRenderingColors(MarkdownCodeTokenColors.runs(tokens, upTo: (self.shownText as NSString).length))
            return true
        }
        applyColors()
        let press = MarkdownCodePressRecognizer(target: self, action: #selector(pressed(_:)))
        press.delegate = self
        press.pressedRegion = { [weak self] point in self?.region(at: point) }
        press.onPress = { [weak self] region in self?.setPressed(region) }
        addGestureRecognizer(press)
        pressRecognizer = press
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownCodeBlockView, _: UITraitCollection) in
            view.applyColors()
            view.header.setNeedsDisplay()
            view.more?.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        lineReveal.stop()
        copiedTask?.cancel()
        host.release()
    }

    // MARK: Content

    /// Shows `code`. The same block again, as it streams, grows what's there.
    public func configure(code: String, language: String?, style: MarkdownStyle, reveal: MarkdownReveal? = nil) {
        let changedCode = code != self.code || language != self.language
        self.code = code
        self.language = language
        self.style = style
        self.reveal = reveal.map { MarkdownReveal(manager: $0.manager, style: MarkdownRevealStyle(motion: .markdownCodeReveal, highlight: .color(.clear))) }
        lines = MarkdownCodeLines(code: code)
        if reveal != nil { lineReveal.measure(code) }
        apply(changed: changedCode)
        follow(self.reveal?.manager)
        sheet?.update(code: code)
    }

    /// A reveal coming to or leaving what shows, with no relayout.
    func setReveal(_ reveal: MarkdownReveal?) {
        let codeReveal = reveal.map { MarkdownReveal(manager: $0.manager, style: MarkdownRevealStyle(motion: .markdownCodeReveal, highlight: .color(.clear))) }
        self.reveal = codeReveal
        if codeReveal != nil { lineReveal.measure(code) }
        if hostIsShowing { host.setReveal(codeReveal) }
        follow(codeReveal?.manager)
        if codeReveal == nil { applyVisibleLines(animated: false) }
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
    }

    private var customRenderer: MarkdownCodeRenderer? { style.codeBlock.renderer(for: language) }
    private var showsLines: Bool {
        if style.codeBlock.replacement?() != nil { return false }
        return customRenderer == nil || !isPreview
    }
    private var scrolls: Bool { style.codeBlock.scrollsSideways }

    private func apply(changed: Bool) {
        measured = nil
        pathKey = nil
        showContent()
        header.configure(
            language: language,
            showsPicker: customRenderer != nil,
            isPreview: isPreview,
            showsExpand: customRenderer == nil && !style.codeBlock.showsAllLines,
            isCopied: isCopied,
            style: style
        )
        if showsLines {
            showLines()
            let hidden = lines.hiddenCount(showsAll: style.codeBlock.showsAllLines)
            if hidden > 0 {
                let view = more ?? MarkdownCodeMoreView()
                if more == nil {
                    view.isUserInteractionEnabled = false
                    addSubview(view)
                    more = view
                }
                view.configure(remaining: hidden, style: style)
            } else {
                more?.removeFromSuperview()
                more = nil
            }
        } else {
            hideLines()
        }
        applyColors()
        if changed, showsLines { showHighlight() }
        setNeedsLayout()
        setNeedsAccessibilityUpdate()
    }

    private func showContent() {
        let wanted: AnyObject?
        var make: (() -> UIView?)?
        if let replacement = style.codeBlock.replacement, let view = replacement() {
            wanted = view
            make = { view }
        } else if let renderer = customRenderer, isPreview {
            let key = "\(language ?? "")\u{0}\(code)" as NSString
            if let owner = contentOwner as? NSString, owner == key {
                wanted = owner
            } else {
                wanted = key
                make = { [code, language] in renderer.makeView(code, language) }
            }
        } else {
            wanted = nil
        }
        if wanted === contentOwner { return }
        if let owner = contentOwner as? NSString, let key = wanted as? NSString, owner == key { return }
        content?.removeFromSuperview()
        content = nil
        contentOwner = wanted
        guard let view = make?() else { return }
        insertSubview(view, belowSubview: header)
        content = view
    }

    private func hideLines() {
        if hostIsShowing {
            host.release()
            host.view.removeFromSuperview()
            hostIsShowing = false
        }
        shownText = ""
        scroller?.removeFromSuperview()
        scroller = nil
        more?.removeFromSuperview()
        more = nil
    }

    private func codeFont() -> UIFont {
        style.codeBlock.font.font(at: style.contentSizeCategory, monospaced: true)
    }

    private func lineHeight() -> CGFloat {
        style.codeBlock.font.lineHeight(at: style.contentSizeCategory)
    }

    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: Self.attributes(font: codeFont(), line: lineHeight(), scrolls: scrolls))
    }

    /// A paragraph a line. Line spacing comes after a paragraph's last line too, so a row's padding
    /// is what's left after it. A layout's single line is the text style's height (`line`), a little
    /// taller than the monospaced font's own, and its wrapped lines are the font's: the difference
    /// goes under a paragraph, so text stays where the font puts it, and a line with a taller
    /// fallback font (Chinese in a comment) can grow.
    nonisolated static func attributes(font: UIFont, line: CGFloat, scrolls: Bool, rowHeight: CGFloat = scrollingRowHeight, rowPadding: CGFloat = lineInsets.top + lineInsets.bottom) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        if scrolls {
            paragraph.paragraphSpacing = rowHeight - font.lineHeight
            paragraph.lineBreakMode = .byClipping
            paragraph.minimumLineHeight = font.lineHeight
            paragraph.maximumLineHeight = font.lineHeight
        } else {
            paragraph.lineSpacing = markdownCodeWrappedLineSpacing
            paragraph.paragraphSpacing = rowPadding + line - font.lineHeight - markdownCodeWrappedLineSpacing
        }
        paragraph.baseWritingDirection = .leftToRight
        return [
            .font: font,
            .foregroundColor: UIColor.floo(.markdownCodeText),
            .paragraphStyle: paragraph,
        ]
    }

    private func showLines() {
        let shown = lines.shown(showsAll: style.codeBlock.showsAllLines).joined(separator: "\n")
        let text = MarkdownText(
            attributed: attributed(shown),
            revealTotal: code.count,
            storageToPlain: Array(0..<shown.count),
            topEdgeInset: 0,
            bottomEdgeInset: 0
        )
        var hostStyle = style
        hostStyle.typography.paragraphAlignment = .natural
        if !hostIsShowing {
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
        placeHost()
    }

    private func placeHost() {
        let view = host.view
        if scrolls {
            let scroller = self.scroller ?? MarkdownCodeScrollView()
            if self.scroller == nil {
                insertSubview(scroller, belowSubview: header)
                self.scroller = scroller
            }
            if view.superview !== scroller { scroller.addSubview(view) }
        } else {
            scroller?.removeFromSuperview()
            scroller = nil
            if view.superview !== self { insertSubview(view, belowSubview: header) }
        }
    }

    // MARK: Highlighting

    private func showHighlight() {
        highlight.show(code: code, language: language, highlighter: style.codeBlock.highlighter, isOnWindow: window != nil)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            highlight.cancel()
            return
        }
        if showsLines { showHighlight() }
    }

    // MARK: Reveal

    private func follow(_ manager: StreamingRevealManager?) {
        lineReveal.follow(manager)
        applyVisibleLines(animated: false)
    }

    /// Lines the reveal has reached: their stripes, the button past them, and the box when it
    /// goes by lines.
    private func applyVisibleLines(animated: Bool) {
        let limit = lines.shownCount(showsAll: style.codeBlock.showsAllLines)
        let (visible, moreVisible) = lineReveal.visibleLines(limit: limit)
        if moreVisible != moreIsVisible {
            moreIsVisible = moreVisible
            more?.alpha = moreVisible ? 1 : 0
            setNeedsAccessibilityUpdate()
        }
        guard visible != visibleLineCount else { return }
        visibleLineCount = visible
        updatePaths(animated: animated && scrolls)
    }

    // MARK: Size

    private func rows(forWidth width: CGFloat) -> Rows {
        if let measured, measured.width == width { return measured.rows }
        var rows = Rows()
        let count = lines.shownCount(showsAll: style.codeBlock.showsAllLines)
        if scrolls {
            for index in 0..<count {
                rows.tops.append(CGFloat(index) * Self.scrollingRowHeight)
                rows.heights.append(Self.scrollingRowHeight)
            }
            rows.total = CGFloat(count) * Self.scrollingRowHeight
        } else {
            let insets = Self.lineInsets
            let inner = max(0, width - insets.left - insets.right)
            let padding = insets.top + insets.bottom
            let shown = lines.shown(showsAll: style.codeBlock.showsAllLines)
            if MarkdownCodeMeasure.allFit(shown, in: inner, font: codeFont()) {
                // Nothing to lay out to know this.
                let height = lineHeight() + padding
                for index in 0..<count {
                    rows.tops.append(CGFloat(index) * height)
                    rows.heights.append(height)
                }
                rows.total = CGFloat(count) * height
            } else {
                let measured = MarkdownCodeMeasure.paragraphs(of: attributed(shownText), width: inner)
                for index in 0..<count {
                    let top = index < measured.tops.count ? measured.tops[index] : (measured.tops.last ?? 0)
                    rows.tops.append(top)
                    rows.heights.append(index + 1 < measured.tops.count ? measured.tops[index + 1] - top : measured.lastHeight + padding + lineHeight() - codeFont().lineHeight)
                }
                rows.total = (rows.tops.last ?? 0) + (rows.heights.last ?? 0)
            }
            // A run of text lays out at a whole number of points: the last row takes what's left.
            let whole = markdownPixelRound(rows.total).rounded(.up)
            if !rows.heights.isEmpty { rows.heights[rows.heights.count - 1] += whole - rows.total }
            rows.total = whole
        }
        measured = (width, rows)
        return rows
    }

    private func headerHeight() -> CGFloat { header.height() }

    /// The height at `width`, the same on or off a window.
    public func height(forWidth width: CGFloat) -> CGFloat {
        if let view = content {
            let top = headerHeight()
            return top + view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        guard showsLines else { return headerHeight() }
        return headerHeight() + rows(forWidth: width).total + (more?.height(forWidth: width) ?? 0)
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: height(forWidth: size.width))
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsAccessibilityUpdate()
        let headerBottom = headerHeight()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerBottom)
        var bottom = headerBottom
        if let content {
            let height = content.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
            content.frame = CGRect(x: 0, y: headerBottom, width: bounds.width, height: height)
            // The block's corners cut it.
            content.layer.cornerRadius = Self.cornerRadius
            content.layer.cornerCurve = .continuous
            content.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            content.layer.masksToBounds = true
            bottom += height
        } else if showsLines {
            let rows = rows(forWidth: bounds.width)
            let insets = Self.lineInsets
            if let scroller {
                let width = textWidth()
                scroller.frame = CGRect(x: 0, y: headerBottom, width: bounds.width, height: rows.total)
                scroller.contentSize = CGSize(width: max(bounds.width, width + insets.left + insets.right), height: rows.total)
                host.place(CGRect(x: insets.left, y: insets.top, width: width, height: rows.total).markdownPixelAligned())
                scroller.layer.cornerRadius = more == nil ? Self.cornerRadius : 0
                scroller.layer.cornerCurve = .continuous
                scroller.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            } else {
                host.place(CGRect(x: insets.left, y: headerBottom + insets.top, width: bounds.width - insets.left - insets.right, height: rows.total).markdownPixelAligned())
            }
            bottom += rows.total
        }
        if let more {
            let height = more.height(forWidth: bounds.width)
            more.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: height)
        }
        updatePaths(animated: false)
    }

    /// As wide as the longest line, with room to spare so none wraps.
    private func textWidth() -> CGFloat {
        let font = codeFont()
        var widest: CGFloat = 0
        for line in lines.shown(showsAll: style.codeBlock.showsAllLines) {
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, width)
        }
        return markdownPixelCeil(widest) + 1
    }

    // MARK: Paths

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let traits = traitCollection
        boxFill.fillColor = UIColor.floo(.markdownCodeFill).resolvedColor(with: traits).cgColor
        boxBorder.strokeColor = UIColor.floo(.markdownCodeBorder).resolvedColor(with: traits).cgColor
        headerFill.fillColor = UIColor.floo(.markdownCodeFill).resolvedColor(with: traits).cgColor
        separators.fillColor = UIColor.floo(.markdownCodeSeparator).resolvedColor(with: traits).cgColor
        stripes.fillColor = UIColor.floo(.markdownCodeStripe).resolvedColor(with: traits).cgColor
        buttonFills.fillColor = UIColor.floo(.markdownCodeButtonFill).resolvedColor(with: traits).cgColor
        underHeaderFill?.fillColor = customRenderer?.underHeader?.resolvedColor(with: traits).cgColor
        badgeFill?.fillColor = UIColor.floo(.markdownCodeBadgeFill).resolvedColor(with: traits).cgColor
        pickerTrack?.fillColor = UIColor.floo(.markdownCodePickerTrack).resolvedColor(with: traits).cgColor
        pickerThumb?.fillColor = UIColor.floo(.markdownCodePickerThumb).resolvedColor(with: traits).cgColor
        CATransaction.commit()
    }

    private func updatePaths(animated: Bool) {
        guard bounds.width > 0 else { return }
        let headerBottom = headerHeight()
        let rows = showsLines && content == nil ? rows(forWidth: bounds.width) : Rows()
        let hasMore = more != nil
        let key = PathKey(size: bounds.size, rows: rows, visible: visibleLineCount, headerHeight: headerBottom, hasMore: hasMore)
        guard key != pathKey else { return }
        pathKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let visible = min(visibleLineCount, rows.tops.count)
        // Lines going by a reveal: the box comes down with them.
        var boxHeight = bounds.height
        if scrolls, showsLines, content == nil, lineReveal.isRevealing {
            boxHeight = min(bounds.height, headerBottom + CGFloat(visible) * Self.scrollingRowHeight + (moreIsVisible ? (more?.bounds.height ?? 0) : 0))
        }
        boxHeight = min(boxHeight, height(forWidth: bounds.width))
        let box = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: bounds.width, height: boxHeight), cornerRadius: Self.cornerRadius).cgPath
        if animated, boxFill.path != nil {
            FlooMotion.markdownLayout.animate(boxFill, "path", to: box)
            FlooMotion.markdownLayout.animate(boxBorder, "path", to: box)
        } else {
            boxFill.removeAnimation(forKey: "dev.floo.uikit.path")
            boxBorder.removeAnimation(forKey: "dev.floo.uikit.path")
            boxFill.path = box
            boxBorder.path = box
        }
        let corners = box
        let top = CGRect(x: 0, y: 0, width: bounds.width, height: headerBottom)
        let headerShape = CGPath(rect: top, transform: nil).intersection(corners)
        headerFill.path = headerShape
        let underHeader = customRenderer?.underHeader != nil && isPreview
        place(&underHeaderFill, below: headerFill, path: underHeader ? headerShape : nil)
        place(&badgeFill, below: header.layer, path: header.badgeBox.map { UIBezierPath(roundedRect: $0, cornerRadius: 3).cgPath })
        place(&pickerTrack, below: header.layer, path: header.pickerTrack.map { UIBezierPath(roundedRect: $0, cornerRadius: 6).cgPath })
        place(&pickerThumb, below: header.layer, path: header.pickerThumb.map { UIBezierPath(roundedRect: $0, cornerRadius: 4).cgPath })
        applyColors()
        let lines = CGMutablePath()
        let line = MarkdownCodeMetrics.separator
        lines.addRect(CGRect(x: 0, y: headerBottom - line, width: bounds.width, height: line))
        let buttons = CGMutablePath()
        if let expand = header.expandBorder {
            buttons.addPath(UIBezierPath(roundedRect: expand, cornerRadius: MarkdownCodeMetrics.borderedRadius).cgPath)
        }
        if let more {
            let height = more.height(forWidth: bounds.width)
            let y = headerBottom + rows.total
            lines.addRect(CGRect(x: 0, y: y, width: bounds.width, height: line))
            if MarkdownCodeMetrics.hasBorderedButtons, moreIsVisible {
                let button = CGRect(x: 0, y: y + line, width: bounds.width, height: height - line)
                buttons.addPath(UIBezierPath(roundedRect: button, cornerRadius: MarkdownCodeMetrics.borderedRadius).cgPath.intersection(corners))
            }
        }
        separators.path = lines
        buttonFills.path = buttons
        let striped = CGMutablePath()
        var touchesBottom = false
        let scale = markdownPixelScale
        for index in 0..<visible where index % 2 != 0 {
            let rect = CGRect(x: 0, y: headerBottom + rows.tops[index], width: bounds.width, height: rows.heights[index])
            striped.addRect(rect)
            if rect.maxY >= bounds.height - 1 / scale { touchesBottom = true }
        }
        // The last row's stripe has the box's corners.
        stripes.path = touchesBottom ? striped.intersection(corners) : striped
    }

    /// A layer that's there only while it has a shape.
    private func place(_ shape: inout CAShapeLayer?, below sibling: CALayer, path: CGPath?) {
        guard let path else {
            shape?.removeFromSuperlayer()
            shape = nil
            return
        }
        if shape == nil {
            shape = CAShapeLayer()
            layer.insertSublayer(shape!, below: sibling)
        }
        shape?.path = path
    }

    // MARK: Touches

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        if region(at: point) != nil { return self }
        return super.hitTest(point, with: event)
    }

    public func takesTouch(at point: CGPoint) -> Bool { region(at: point) != nil }

    private func region(at point: CGPoint) -> MarkdownCodeRegion? {
        if let region = header.region(at: convert(point, to: header)) { return region }
        if let more, moreIsVisible, more.frame.contains(point), more.buttonRect.contains(convert(point, to: more)) { return .more }
        return nil
    }

    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        region(at: touch.location(in: self)) != nil
    }

    private func setPressed(_ region: MarkdownCodeRegion?) {
        header.pressed = region
        more?.isPressed = region == .more
    }

    @objc private func pressed(_ recognizer: MarkdownCodePressRecognizer) {
        guard recognizer.state == .ended, let region = recognizer.region else { return }
        perform(region)
    }

    private func perform(_ region: MarkdownCodeRegion) {
        switch region {
        case .copy: copyCode()
        case .expand, .more: showSheet()
        case .preview: switchMode(preview: true)
        case .code: switchMode(preview: false)
        }
    }

    private func copyCode() {
        UIPasteboard.general.string = code
        style.codeBlock.didCopy?(code)
        setCopied(true)
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.setCopied(false)
        }
    }

    private func setCopied(_ copied: Bool) {
        isCopied = copied
        header.setCopied(copied)
        setNeedsAccessibilityUpdate()
    }

    private func switchMode(preview: Bool) {
        guard isPreview != preview else { return }
        FlooMotion.markdownFeedback.fade(layer)
        isPreview = preview
        apply(changed: true)
        layoutIfNeeded()
        onHeightChange?()
    }

    private func showSheet() {
        guard let presenter = presentingController() else { return }
        let sheet = MarkdownCodeSheetController(code: code, language: language, style: style)
        presenter.present(UINavigationController(rootViewController: sheet), animated: true)
        self.sheet = sheet
    }

    private func presentingController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if var controller = current as? UIViewController {
                while let next = controller.presentedViewController { controller = next }
                return controller
            }
            responder = current.next
        }
        return nil
    }

    // MARK: For a host

    /// The text view inside, made if it isn't there yet.
    var textView: UITextView? { hostIsShowing ? host.textView : nil }
    var selectableText: MarkdownSelectableText? { hostIsShowing ? host.selectableText : nil }

    /// The code's layout fragments, for what proves nothing was laid out again.
    var layoutFragmentIDs: [ObjectIdentifier] { hostIsShowing ? host.layoutFragmentIDs : [] }

    // MARK: Accessibility

    private func setNeedsAccessibilityUpdate() {
        accessibilityElementsCache = nil
    }

    private var accessibilityElementsCache: [Any]?

    public override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    public override var accessibilityElements: [Any]? {
        get {
            // Kept: the system holds these weakly.
            if let accessibilityElementsCache { return accessibilityElementsCache }
            var elements: [Any] = []
            func button(_ label: String, _ rect: CGRect?, in view: UIView) {
                guard let rect else { return }
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = label
                element.accessibilityTraits = .button
                element.accessibilityFrameInContainerSpace = view.convert(rect, to: self)
                elements.append(element)
            }
            button(header.languageLabel, header.languageLabel.isEmpty ? nil : header.languageRect, in: header)
            if let element = elements.last as? UIAccessibilityElement { element.accessibilityTraits = .staticText }
            button("Preview", header.rect(of: .preview), in: header)
            button("Code", header.rect(of: .code), in: header)
            button("Expand", header.rect(of: .expand), in: header)
            button(isCopied ? "Copied" : "Copy", header.rect(of: .copy), in: header)
            if let content { elements.append(content) }
            if hostIsShowing { elements.append(scroller ?? host.view) }
            if let more, moreIsVisible { button(more.label, more.buttonRect, in: more) }
            accessibilityElementsCache = elements
            return elements
        }
        set {}
    }
}

/// Rows without a text view. Short plain lines in a monospaced font need no layout at all: most
/// code. Anything else goes through one layout manager kept for this, off any view: a UITextView's
/// own only has geometry for what's on screen at its current size.
@MainActor
enum MarkdownCodeMeasure {
    private static let storage = NSTextContentStorage()
    private static let manager: NSTextLayoutManager = {
        let manager = NSTextLayoutManager()
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        return manager
    }()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        return container
    }()
    private static var advances: [String: CGFloat] = [:]

    /// Whether every line is plain ASCII that fits on one line at `width`.
    static func allFit(_ lines: ArraySlice<String>, in width: CGFloat, font: UIFont) -> Bool {
        let key = "\(font.fontName)\u{0}\(font.pointSize)"
        let advance = advances[key] ?? ("0" as NSString).size(withAttributes: [.font: font]).width
        advances[key] = advance
        for line in lines {
            let utf8 = line.utf8
            guard CGFloat(utf8.count) * advance <= width, utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return false }
        }
        return true
    }

    /// Where each paragraph's first line starts at `width`, and the height of the last one's lines.
    /// A fragment holds the spacing before its lines, not after: its lines say where they are.
    static func paragraphs(of text: NSAttributedString, width: CGFloat) -> (tops: [CGFloat], lastHeight: CGFloat) {
        container.size = CGSize(width: width, height: 0)
        storage.performEditingTransaction { storage.textStorage?.setAttributedString(text) }
        var tops: [CGFloat] = []
        var lastHeight: CGFloat = 0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            let first = lines.first?.typographicBounds.minY ?? fragment.textLineFragments.first?.typographicBounds.minY ?? 0
            tops.append(fragment.layoutFragmentFrame.minY + first)
            lastHeight = ((lines.last ?? fragment.textLineFragments.last)?.typographicBounds.maxY ?? fragment.layoutFragmentFrame.height) - first
            return true
        }
        return (tops, lastHeight)
    }
}

/// What's touched in a block.
enum MarkdownCodeRegion: Equatable {
    case copy, expand, more, preview, code
}

/// Press on a part of a view: told when it goes down and comes up, and recognised on the way up
/// if the finger stayed. A list's pan takes over from it as from any tap.
final class MarkdownCodePressRecognizer: UIGestureRecognizer {
    var pressedRegion: ((CGPoint) -> MarkdownCodeRegion?)?
    var onPress: ((MarkdownCodeRegion?) -> Void)?
    private(set) var region: MarkdownCodeRegion?
    private var start = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, let view else {
            state = .failed
            return
        }
        start = touch.location(in: view)
        region = pressedRegion?(start)
        guard region != nil else {
            state = .failed
            return
        }
        onPress?(region)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        if hypot(point.x - start.x, point.y - start.y) > 10 {
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = region == nil ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        if region != nil { onPress?(nil) }
        // The action reads it as it ends, before this.
        Task { @MainActor [weak self] in self?.region = nil }
        super.reset()
    }

    /// A list's tap ends on the same touch and comes first; only a scroll takes the touch away.
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { preventing is UIPanGestureRecognizer }
    override func canPrevent(_ prevented: UIGestureRecognizer) -> Bool { false }
}

/// Code scrolling sideways in its block: never up and down, which is the list's.
final class MarkdownCodeScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        isDirectionalLockEnabled = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = true
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        clipsToBounds = true
        delaysContentTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A move that's more up and down than sideways is left to whatever's behind: the list.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === panGestureRecognizer else { return super.gestureRecognizerShouldBegin(recognizer) }
        let velocity = panGestureRecognizer.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }
}
