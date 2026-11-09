//
//  DocTextRowUIKit.swift
//  DemoApp
//
//  A paragraph, heading, list item, caption or quote as a UIKit row: MarkdownUIKit's block view
//  in the page's text column, in its decoration box when it has one, its text view the editor's.
//  The same layout the SwiftUI row had (DocRowView's page, DocRowBoxing), in frames.
//

import DocKit
import Markdown
import MarkdownUIKit
import MessagingUI
import Observation
import UIKit

/// A text row's content: what it shows and who edits it.
@MainActor
struct DocTextRowContent: TiledUIKitCellContent {
    let row: DocRow
    let text: DocTextRow
    let editor: DocEditor

    static func makeRowView() -> DocTextRowView { DocTextRowView() }

    func configure(_ view: DocTextRowView, context: TiledUIKitCellContext) {
        view.show(row, text: text, editor: editor, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocTextRowView.height(of: row, text: text, width: width, traits: traits)
    }

    static func prepareForReuse(_ view: DocTextRowView) {
        view.reset()
    }
}

@MainActor
final class DocTextRowView: UIView {
    private let blockView = MarkdownUIKit.MarkdownBlockView()
    private let box = UIView()
    private var row: DocRow?
    private var text: DocTextRow?
    private weak var editor: DocEditor?
    private var context: TiledUIKitCellContext?
    /// The text view the editor was told of and its block: a new text view (a quote becoming
    /// a paragraph) or the row view reused for another block is told again.
    private weak var attached: UITextView?
    private var attachedBlock: DocBlockID?

    private typealias Box = DocTokens.Component.DecorationBox

    override init(frame: CGRect) {
        super.init(frame: frame)
        box.backgroundColor = .floo(.markdownBlockDecoration)
        box.layer.cornerCurve = .continuous
        box.isUserInteractionEnabled = false
        addSubview(box)
        addSubview(blockView)
        blockView.onHeightChange = { [weak self] in
            guard let self, let row = self.row, let text = self.text else { return }
            Self.forgetHeights(of: row.id)
            self.context?.heightDidChange(to: Self.height(of: row, text: text, width: self.bounds.width, traits: self.traitCollection))
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Showing

    func show(_ row: DocRow, text: DocTextRow, editor: DocEditor, context: TiledUIKitCellContext) {
        let sameText = self.row?.id == row.id && self.text == text && self.row?.font == row.font && self.row?.role == row.role
        self.row = row
        self.text = text
        self.editor = editor
        self.context = context
        let block = row.block
        // The same text again: the storage may have been edited ahead of this render (a
        // keystroke), and is shown again only if it no longer shows the model.
        if sameText, let id = block, attachedBlock == id, let textView = attached, editor.rowTextIsCurrent(textView, in: id) {
            follow(editor.blocks, block: id)
            setNeedsLayout()
            return
        }
        Self.configure(blockView, row: row, text: text)
        if let id = block, let textView = blockView.textViews.first {
            if textView !== attached || attachedBlock != id {
                editor.attachRowText(textView, to: id)
                attached = textView
                attachedBlock = id
            }
            editor.rowTextChanged(textView, in: id)
            follow(editor.blocks, block: id)
        }
        setNeedsLayout()
    }

    /// Clicks and taps reach the text when the block controller lets them (on the Mac a click
    /// first selects the block), and a block dropped shows once what flies to it is down.
    private func follow(_ blocks: DocBlockController, block: DocBlockID) {
        guard let row else { return }
        let (editsText, takesClicks, scrollsAcross) = (row.editsText, row.takesClicks, row.scrollsAcross)
        withObservationTracking {
            blockView.isUserInteractionEnabled = blocks.blockTakes(block, editsText: editsText, takesClicks: takesClicks)
                || (DocBlockController.usesHandles && scrollsAcross)
            alpha = blocks.isLanding(block) ? 0 : 1
        } onChange: { [weak self, weak blocks] in
            DispatchQueue.main.async {
                guard let self, let blocks, self.row?.block == block else { return }
                self.follow(blocks, block: block)
            }
        }
    }

    func reset() {
        row = nil
        text = nil
        context = nil
        alpha = 1
        blockView.isUserInteractionEnabled = true
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row else { return }
        let frames = Self.frames(of: row, width: bounds.width, textHeight: blockView.height(forWidth: Self.textWidth(of: row, width: bounds.width)))
        blockView.frame = frames.text
        box.isHidden = frames.box == nil
        if let rect = frames.box {
            box.frame = rect
            let box = row.box
            var corners: CACornerMask = []
            if box?.isFirst == true { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
            if box?.isLast == true { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
            self.box.layer.cornerRadius = Box.cornerRadius
            self.box.layer.maskedCorners = corners
        }
    }

    /// Where the text and its box go in a row `width` wide, with text `textHeight` tall.
    private static func frames(of row: DocRow, width: CGFloat, textHeight: CGFloat) -> (text: CGRect, box: CGRect?, height: CGFloat) {
        let boxed = row.box != nil
        let first = row.box?.isFirst == true
        let last = row.box?.isLast == true
        let left = DocBlockController.pageLeft(inWidth: width) + DocBlockController.indentWidth(row.indent)
        let pageWidth = max(0, DocBlockController.pageWidth(inWidth: width) - DocBlockController.indentWidth(row.indent))
        // Above the box (or the text), then the box's own padding: in a box below its first
        // row, the space between rows is inside the box.
        let above = !boxed || first ? row.spacingAbove : 0
        let topPadding = !boxed ? 0 : first ? Box.padding : row.spacingAbove
        let bottomPadding = boxed && last ? Box.padding : 0
        let inset = boxed ? Box.inset : 0
        let text = CGRect(x: left + inset, y: above + topPadding, width: max(0, pageWidth - inset * 2), height: textHeight)
        let boxRect = boxed
            ? CGRect(x: left - Box.outset, y: above, width: pageWidth + Box.outset * 2, height: topPadding + textHeight + bottomPadding)
            : nil
        return (text, boxRect, above + topPadding + textHeight + bottomPadding + row.spacingBelow)
    }

    private static func textWidth(of row: DocRow, width: CGFloat) -> CGFloat {
        frames(of: row, width: width, textHeight: 0).text.width
    }

    // MARK: Measuring

    /// Heights by row and width, for the text it showed.
    private static var heights: [String: (text: DocTextRow, row: DocRow, byWidth: [CGFloat: CGFloat])] = [:]
    private static let sizing = MarkdownUIKit.MarkdownBlockView()

    static func height(of row: DocRow, text: DocTextRow, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        guard width > 0 else { return 1 }
        if let known = heights[row.id], known.text == text, known.row == row, let height = known.byWidth[width] { return height }
        configure(sizing, row: row, text: text)
        let textHeight = sizing.height(forWidth: textWidth(of: row, width: width))
        let height = frames(of: row, width: width, textHeight: textHeight).height
        var entry = heights[row.id].flatMap { $0.text == text && $0.row == row ? $0 : nil } ?? (text: text, row: row, byWidth: [:])
        entry.byWidth[width] = height
        heights[row.id] = entry
        return height
    }

    static func forgetHeights(of id: String) {
        heights[id] = nil
    }

    // MARK: Style

    private static func configure(_ view: MarkdownUIKit.MarkdownBlockView, row: DocRow, text: DocTextRow) {
        view.configure(document: text.tree.document, listDepth: text.depth, asQuote: text.isQuote, style: style(for: row))
    }

    /// The document's type (DocTypography's), its role's line spacing, its typeface, and a
    /// caption's smaller, secondary text; text views from the start, to edit in.
    private static func style(for row: DocRow) -> MarkdownUIKit.MarkdownStyle {
        var style = MarkdownUIKit.MarkdownStyle()
        let design = row.font.map(DocUIKitType.design)
        style.typography = row.role == .caption ? DocUIKitType.caption(design: design) : DocUIKitType.body(design: design)
        style.lineSpacing = row.role.lineSpacing
        style.addsEdgeInsets = false
        style.drawsTextUntilTouched = false
        if row.role == .caption { style.textColor = .floo(.secondaryLabel) }
        return style
    }
}

/// DocTypography's fonts, for MarkdownUIKit.
enum DocUIKitType {
    static func body(design: UIFontDescriptor.SystemDesign?) -> MarkdownUIKit.MarkdownTypography {
        typography(body: .init(.body), inlineCode: .init(.callout), design: design)
    }

    static func caption(design: UIFontDescriptor.SystemDesign?) -> MarkdownUIKit.MarkdownTypography {
        typography(body: .init(.footnote), inlineCode: .init(.caption1), design: design)
    }

    static func design(_ font: Typeface) -> UIFontDescriptor.SystemDesign {
        switch font {
        case .system: .default
        case .serif: .serif
        case .mono: .monospaced
        case .rounded: .rounded
        }
    }

    private static func typography(
        body: MarkdownUIKit.MarkdownTypography.Style,
        inlineCode: MarkdownUIKit.MarkdownTypography.Style,
        design: UIFontDescriptor.SystemDesign?
    ) -> MarkdownUIKit.MarkdownTypography {
        var body = body
        var headings: [MarkdownUIKit.MarkdownTypography.Style] = [
            .init(.title1, weight: .bold), .init(.title2, weight: .bold),
            .init(.title3, weight: .semibold), .init(.headline, weight: .semibold),
        ]
        if let design {
            body.design = design
            for index in headings.indices { headings[index].design = design }
        }
        return MarkdownUIKit.MarkdownTypography(body: body, headings: headings, inlineCode: inlineCode)
    }
}
