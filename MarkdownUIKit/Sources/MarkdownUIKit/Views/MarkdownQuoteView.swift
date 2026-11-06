//
//  MarkdownQuoteView.swift
//  MarkdownUIKit
//
//  A quote: padding 8 and 20, a ground of its tint at 0.1 the whole width, a 4 pt bar at its
//  edge, corners of 3. A callout (`> [!note]`) has its header above, and its kind's colour. The
//  content is ordinary text, black and white inside.
//

import Markdown
import MarkdownCore
import UIKit

@MainActor
final class MarkdownQuoteView: UIView {
    /// The clip with its corners; the content is clipped with them. The bar has its own: a layout
    /// clips each thing it draws, so at a corner both the ground and the bar fall off.
    private let clip = UIView()
    private let barClip = UIView()
    private let ground = MarkdownColorView()
    private let bar = MarkdownColorView()
    private let host = MarkdownTextHost()
    private var header: MarkdownCalloutHeaderView?
    private var style = MarkdownStyle()
    private let verticalPadding: CGFloat = 8
    private let horizontalPadding: CGFloat = 20
    private let barWidth: CGFloat = 4
    private let headerSpacing: CGFloat = 6
    private let cornerRadius: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [clip, barClip] {
            view.clipsToBounds = true
            view.layer.cornerRadius = cornerRadius
            view.layer.cornerCurve = .continuous
            addSubview(view)
        }
        barClip.isUserInteractionEnabled = false
        clip.addSubview(ground)
        clip.addSubview(host.textView)
        barClip.addSubview(bar)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var textView: UITextView { host.textView }

    /// Inside another block a quote is in a box of its own, which cuts a first letter's overhang.
    func clipsTextToBounds() {
        host.textView.clipsToBounds = true
    }

    /// A quote from its source (`> …`): one level of markers off, a callout's first line out.
    func configure(source: String, style: MarkdownStyle, inlineMath: [String: String]?, displayMath: [UUID: String]? = nil) {
        let inner = Self.strippingQuoteMarkers(source)
        let split = MarkdownCallout.split(innerMarkdown: inner)
        let text = MarkdownTextBuilder.build(markdown: split?.body ?? inner, style: style.quoted, inlineMath: inlineMath, displayMath: displayMath)
        apply(text, callout: split?.callout, style: style)
    }

    func configure(document: Document, callout: MarkdownCallout?, style: MarkdownStyle) {
        apply(MarkdownTextBuilder.build(document: document, style: style.quoted), callout: callout, style: style)
    }

    /// Text drawn as a quote by its host, not by its markdown.
    func configure(text: MarkdownText, style: MarkdownStyle) {
        apply(text, callout: nil, style: style)
    }

    private func apply(_ text: MarkdownText, callout: MarkdownCallout?, style: MarkdownStyle) {
        self.style = style
        // The last line's room, unless the last thing is a block with its own.
        let storage = text.attributed
        let endsInBlock = storage.length > 0 && storage.attribute(.attachment, at: storage.length - 1, effectiveRange: nil) != nil
        host.insets = UIEdgeInsets(top: text.topEdgeInset, left: 0, bottom: text.bottomEdgeInset + (endsInBlock ? 0 : style.roomBelowLines ?? 0), right: 0)
        host.apply(text, style: style)
        if let callout {
            let tint = MarkdownInk.callout(callout.kind)
            ground.color = tint.markdownOpacity(0.1)
            bar.color = tint
            let view = header ?? MarkdownCalloutHeaderView()
            view.configure(callout, tint: tint, style: style)
            if header == nil { clip.addSubview(view) }
            header = view
        } else {
            ground.color = style.resolvedQuoteFill
            bar.color = style.resolvedQuoteColor
            header?.removeFromSuperview()
            header = nil
        }
        setNeedsLayout()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = max(0, width - horizontalPadding * 2)
        var height = host.height(forWidth: inner) + verticalPadding * 2
        if let header { height += header.size(forWidth: inner).height + headerSpacing }
        return height
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: height(forWidth: size.width))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = style.layoutDirection == .rightToLeft
        clip.frame = bounds
        barClip.frame = bounds
        ground.frame = clip.bounds
        bar.frame = CGRect(x: isRTL ? bounds.width - barWidth : 0, y: 0, width: barWidth, height: bounds.height)
        var y = verticalPadding
        let inner = CGRect(x: horizontalPadding, y: y, width: max(0, bounds.width - horizontalPadding * 2), height: 0)
        if let header {
            let size = header.size(forWidth: inner.width)
            let x = isRTL ? inner.maxX - size.width : inner.minX
            // A little wider than its text: a glyph's overhang falls outside its frame.
            let overhang = MarkdownCalloutHeaderView.overhang
            header.frame = CGRect(x: x - overhang, y: y, width: size.width + overhang * 2, height: size.height).markdownPixelAligned()
            y += size.height + headerSpacing
        }
        host.layout(in: CGRect(x: inner.minX, y: y, width: inner.width, height: 0), isRightToLeft: isRTL)
    }

    /// Takes a line's quote marker off (`>` after at most 3 spaces, then an optional space):
    /// in `> >` only one level.
    private static func strippingQuoteMarkers(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { line -> String in
                var s = Substring(line)
                var indent = 0
                while indent < 3, s.first == " " { s = s.dropFirst(); indent += 1 }
                guard s.first == ">" else { return line }
                s = s.dropFirst()
                if s.first == " " { s = s.dropFirst() }
                return String(s)
            }
            .joined(separator: "\n")
    }
}

/// A callout's title line: its kind's icon and title, semibold, in its colour, on one baseline.
@MainActor
final class MarkdownCalloutHeaderView: UIView {
    private var title: NSAttributedString?
    private var icon: UIImage?
    private var tint = UIColor.label
    private var font = UIFont.preferredFont(forTextStyle: .body)
    private let spacing: CGFloat = 6
    static let overhang: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownCalloutHeaderView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ callout: MarkdownCallout, tint: UIColor, style: MarkdownStyle) {
        let category = style.contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) }
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: category)
        // The quote's font: serif at body's size. Its body text sets its own.
        let semibold = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        font = semibold.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: body.pointSize) } ?? semibold
        self.tint = tint
        icon = MarkdownSymbols.image(callout.kind.symbol, pointSize: body.pointSize, weight: .regular)
        title = NSAttributedString(string: callout.title, attributes: [.font: font, .foregroundColor: tint])
        setNeedsDisplay()
    }

    /// The text's baseline in its frame: a layout keeps it on the pixel grid.
    private var textAscent: CGFloat { markdownPixelFloor(font.ascender) }

    /// Above and below the shared baseline: the text's line and the icon's, whichever is more.
    private var metrics: (ascent: CGFloat, descent: CGFloat) {
        let textHeight = markdownPixelCeil(title?.size().height ?? 0)
        var ascent = textAscent
        var descent = textHeight - textAscent
        if let icon {
            let below = icon.baselineOffsetFromBottom ?? 0
            ascent = max(ascent, icon.size.height - below)
            descent = max(descent, below)
        }
        return (ascent, descent)
    }

    func size(forWidth width: CGFloat) -> CGSize {
        let iconWidth = icon?.size.width ?? 0
        let available = max(0, width - iconWidth - spacing)
        let textSize = title?.boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size ?? .zero
        let textWidth = markdownPixelCeil(textSize.width)
        let lines = max(0, markdownPixelCeil(textSize.height) - markdownPixelCeil(title?.size().height ?? 0))
        let metrics = self.metrics
        return CGSize(width: iconWidth + spacing + textWidth, height: metrics.ascent + metrics.descent + lines)
    }

    override func draw(_ rect: CGRect) {
        UIGraphicsGetCurrentContext()?.translateBy(x: Self.overhang, y: 0)
        let metrics = self.metrics
        if let icon {
            let below = icon.baselineOffsetFromBottom ?? 0
            let y = markdownPixelRound(metrics.ascent - icon.size.height + below)
            icon.withTintColor(tint, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 0, y: y, width: icon.size.width, height: icon.size.height))
        }
        let textX = (icon?.size.width ?? 0) + spacing
        let textY = markdownPixelRound(metrics.ascent - textAscent)
        // A layout's text cuts at its own left edge: a first A's foot stops there.
        UIGraphicsGetCurrentContext()?.clip(to: CGRect(x: textX, y: -bounds.height, width: bounds.width, height: bounds.height * 3))
        title?.draw(with: CGRect(x: textX, y: textY, width: max(0, bounds.width - Self.overhang * 2 - textX), height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}
