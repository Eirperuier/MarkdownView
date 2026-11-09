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
import UIKit

/// A text row's content: what it shows and who edits it.
@MainActor
struct DocTextRowContent: TiledUIKitCellContent {
    /// Its row runs a reshape's animation and the rows round it move in its frames.
    var drivesRowMoves: Bool { true }

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
final class DocTextRowView: DocRowUIKitView {
    private let blockView = MarkdownUIKit.MarkdownBlockView()
    private var text: DocTextRow?
    /// The text view the editor was told of and its block: a new text view (a quote becoming
    /// a paragraph) or the row view reused for another block is told again.
    private weak var attached: UITextView?
    private var attachedBlock: DocBlockID?

    init() {
        super.init(content: blockView)
        blockView.onHeightChange = { [weak self] in
            guard let self, let row = self.row else { return }
            Self.heights.forget(row.id)
            self.contentHeightChanged()
        }
    }

    // MARK: Showing

    func show(_ row: DocRow, text: DocTextRow, editor: DocEditor, context: TiledUIKitCellContext) {
        let sameText = self.row?.id == row.id && self.text == text && self.row?.font == row.font && self.row?.role == row.role
        self.text = text
        take(row, blocks: editor.blocks, context: context)
        defer { layOutShown() }
        guard let id = row.block else { return }
        // The same text again: the storage may have been edited ahead of this render (a
        // keystroke), and is shown again only if it no longer shows the model.
        if sameText, attachedBlock == id, let textView = attached, editor.rowTextIsCurrent(textView, in: id) { return }
        Self.configure(blockView, row: row, text: text)
        guard let textView = blockView.textViews.first else { return }
        if textView !== attached || attachedBlock != id {
            editor.attachRowText(textView, to: id)
            attached = textView
            attachedBlock = id
        }
        editor.rowTextChanged(textView, in: id)
    }

    override func reset() {
        super.reset()
        text = nil
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        blockView.height(forWidth: width)
    }

    // MARK: Measuring

    private static var heights = DocRowHeights<DocTextRow>()
    private static let sizing = MarkdownUIKit.MarkdownBlockView()

    static func height(of row: DocRow, text: DocTextRow, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        heights.height(of: row, showing: text, width: width) { width in
            configure(sizing, row: row, text: text)
            return sizing.height(forWidth: width)
        }
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
        // The model's text as typed: its marks are in the tree, `==this==` and `$5` are text.
        style.interpretsTextSyntax = false
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
