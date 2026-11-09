//
//  DocPageRowUIKit.swift
//  DemoApp
//
//  A page block and a divider as UIKit rows in the page's text column. A page block is its
//  sheet (a page with a few lines of writing at its top, Craft's) and beside it the page's
//  title and the start of its text, a line each; the list's click opens it. A divider is
//  MarkdownUIKit's thematic break. What DocPageRowView and the divider's tree drew, in frames.
//

import DocKit
import FlooUIKit
import MarkdownUIKit
import MessagingUI
import UIKit

/// A page block row's content: the page it opens.
@MainActor
struct DocPageRowContent: TiledUIKitCellContent {
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let page: DocPage
    let blocks: DocBlockController

    static func makeRowView() -> DocPageRowUIKitView { DocPageRowUIKitView() }

    func configure(_ view: DocPageRowUIKitView, context: TiledUIKitCellContext) {
        view.show(row, page: page, blocks: blocks, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocRowUIKitView.frames(of: row, width: width, contentHeight: DocPageLineView.height).height
    }

    static func prepareForReuse(_ view: DocPageRowUIKitView) {
        view.reset()
    }
}

@MainActor
final class DocPageRowUIKitView: DocRowUIKitView {
    private let line = DocPageLineView()

    init() {
        super.init(content: line)
    }

    func show(_ row: DocRow, page: DocPage, blocks: DocBlockController, context: TiledUIKitCellContext) {
        take(row, blocks: blocks, context: context)
        line.show(title: page.title, preview: page.preview)
        layOutShown()
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat { DocPageLineView.height }
}

/// The sheet, and the title and the start of the text beside it, centred down the row.
@MainActor
final class DocPageLineView: UIView {
    private let sheet = DocPageSheetView()
    private let title = UILabel()
    private let preview = UILabel()

    private typealias Metrics = DocPageMetrics

    /// The sheet's height and a little; the title and its preview a line each.
    static var height: CGFloat {
        max(Metrics.rowHeight, ceil(titleFont.lineHeight) + ceil(DocTableCellField.bodyFont.lineHeight))
    }

    private static var titleFont: UIFont {
        let body = DocTableCellField.bodyFont
        let descriptor = body.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        return UIFont(descriptor: descriptor, size: body.pointSize)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.textColor = .floo(.secondaryLabel)
        [sheet, title, preview].forEach(addSubview)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Opens the page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, preview: String) {
        self.title.text = title.isEmpty ? String(localized: "Untitled") : title
        self.title.textColor = title.isEmpty ? .floo(.disabledLabel) : .floo(.label)
        self.title.font = Self.titleFont
        self.preview.text = preview
        self.preview.font = DocTableCellField.bodyFont
        self.preview.isHidden = preview.isEmpty
        accessibilityLabel = title
        accessibilityValue = preview
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let flips = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ rect: CGRect) -> CGRect {
            flips ? CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }
        sheet.frame = place(CGRect(x: 0, y: ((bounds.height - Metrics.sheet.height) / 2).rounded(), width: Metrics.sheet.width, height: Metrics.sheet.height))
        let x = Metrics.sheet.width + Metrics.gap
        let width = max(0, bounds.width - x)
        let titleHeight = ceil(title.font.lineHeight)
        let previewHeight = preview.isHidden ? 0 : ceil(preview.font.lineHeight)
        let top = ((bounds.height - titleHeight - previewHeight) / 2).rounded()
        title.frame = place(CGRect(x: x, y: top, width: width, height: titleHeight))
        preview.frame = place(CGRect(x: x, y: top + titleHeight, width: width, height: previewHeight))
        let alignment: NSTextAlignment = flips ? .right : .left
        title.textAlignment = alignment
        preview.textAlignment = alignment
    }
}

/// A page's icon: a sheet with a few lines of writing at its top.
@MainActor
final class DocPageSheetView: UIView {
    private typealias Metrics = DocPageMetrics

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .floo(.markdownBlockControl)
        layer.cornerRadius = Metrics.sheetCorner
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        for _ in Metrics.sheetLines {
            let line = UIView()
            line.backgroundColor = .floo(.disabledLabel)
            line.layer.cornerRadius = Metrics.lineHeight / 2
            addSubview(line)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let flips = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (index, (line, width)) in zip(subviews, Metrics.sheetLines).enumerated() {
            let x = flips ? bounds.width - Metrics.sheetInset - width : Metrics.sheetInset
            line.frame = CGRect(x: x, y: Metrics.sheetInset + CGFloat(index) * (Metrics.lineHeight + Metrics.lineGap), width: width, height: Metrics.lineHeight)
        }
    }
}

// MARK: Dividers

/// A divider row's content.
@MainActor
struct DocDividerRowContent: TiledUIKitCellContent {
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let blocks: DocBlockController

    static func makeRowView() -> DocDividerRowView { DocDividerRowView() }

    func configure(_ view: DocDividerRowView, context: TiledUIKitCellContext) {
        view.show(row, blocks: blocks, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocRowUIKitView.frames(of: row, width: width, contentHeight: DocDividerRowView.contentHeight(forWidth: DocRowUIKitView.contentWidth(of: row, width: width))).height
    }

    static func prepareForReuse(_ view: DocDividerRowView) {
        view.reset()
    }
}

@MainActor
final class DocDividerRowView: DocRowUIKitView {
    private let rule = MarkdownUIKit.MarkdownBlockView()

    init() {
        super.init(content: rule)
        rule.configure(markdown: "---", style: Self.style)
    }

    func show(_ row: DocRow, blocks: DocBlockController, context: TiledUIKitCellContext) {
        take(row, blocks: blocks, context: context)
        layOutShown()
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat { Self.contentHeight(forWidth: width) }

    private static let sizing: MarkdownUIKit.MarkdownBlockView = {
        let view = MarkdownUIKit.MarkdownBlockView()
        view.configure(markdown: "---", style: style)
        return view
    }()

    static func contentHeight(forWidth width: CGFloat) -> CGFloat { sizing.height(forWidth: width) }

    /// The page's type.
    private static let style: MarkdownUIKit.MarkdownStyle = {
        var style = MarkdownUIKit.MarkdownStyle()
        style.typography = DocUIKitType.body(design: nil)
        style.addsEdgeInsets = false
        return style
    }()
}
