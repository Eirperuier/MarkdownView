//
//  DocSelectionToolbar.swift
//  DemoApp
//
//  The Mac's menu over selected text: FlooDesign's action menu above the selection's
//  first line, at the block's start, with what the text takes (DocTextFormat). It opens
//  as a strip, the marks and a link as keys; its last key unfolds the rest under them,
//  the surface growing as it does for a level, from the same corner (the strip is placed
//  where the menu unfolded fits, above the text or else below): the highlight's and the
//  text's colours
//  (their palettes open as the menu's next level), a pen mark, the format panel. It
//  comes once the selection settles, and goes when the selection collapses or leaves the
//  text; the keys stay with the text (it isn't a right-click's menu).
//

import SwiftUI
import UIKit
import DocKit
import FlooDesign

private typealias Metrics = FlooDesignTokens.Component.SelectionToolbar

/// The selected text the menu acts on (the menu reads it).
@MainActor
@Observable
final class DocSelectionToolbarModel {
    var block: DocBlockID?
    var range: Range<Int> = 0..<0
    /// More than the keys shown (each selection opens it folded).
    var isUnfolded = false

    var ranges: [(block: DocBlockID, range: Range<Int>)] {
        block.map { [($0, range)] } ?? []
    }
}

/// Shows and hides the toolbar as the selection changes (pointer devices only).
@MainActor
final class DocSelectionToolbarController {
    unowned let editor: DocEditor
    let model = DocSelectionToolbarModel()
    private let presenter = FlooDesignAnchoredPanelPresenter()
    private let anchor = UIView()
    private var pending: Task<Void, Never>?
    private(set) var isShown = false

    init(editor: DocEditor) {
        self.editor = editor
        anchor.isUserInteractionEnabled = false
        anchor.backgroundColor = .clear
    }

    /// The selection changed: the toolbar goes, and comes back where it settles.
    func selectionChanged() {
        guard DocBlockController.usesHandles else { return }
        pending?.cancel()
        // The same selection (a mark applied over it) keeps the toolbar as it is.
        if isShown, let target = target(), target.block == model.block, target.range == model.range { return place(target.view) }
        hide()
        guard let selection = editor.selection, selection.anchor != selection.head else { return }
        // Checked again once it settles: the text view may only now be taking the focus.
        pending = Task { [weak self] in
            try? await Task.sleep(for: Metrics.settleDelay)
            guard let self, !Task.isCancelled, let target = self.target() else { return }
            self.show(target)
        }
    }

    func hide() {
        pending?.cancel()
        guard isShown else { return }
        isShown = false
        presenter.hide()
        anchor.removeFromSuperview()
    }

    /// Selected text in one block of text, being edited.
    private func target() -> (block: DocBlockID, range: Range<Int>, view: UITextView)? {
        guard editor.isEditable, let selection = editor.selection, selection.anchor.block == selection.head.block,
              let block = editor.textBlock(selection.head.block), block.kind.allowsMarks,
              let view = editor.textView(for: block.id), view.isFirstResponder
        else { return nil }
        let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
        return range.isEmpty ? nil : (block.id, range, view)
    }

    private func show(_ target: (block: DocBlockID, range: Range<Int>, view: UITextView)) {
        model.block = target.block
        model.range = target.range
        model.isUnfolded = false
        place(target.view)
        presenter.anchorView = anchor
        presenter.show(
            configuration: .init(preferredEdge: .above, horizontalAlignment: .leading, anchorGap: Metrics.gap,
                                 dismissesOnOutsideTouch: false),
            content: AnyView(DocSelectionToolbar(editor: editor, model: model) { [weak self] in self?.hide() }),
            onRequestDismiss: { [weak self] in self?.hide() }
        )
        isShown = true
    }

    /// The anchor: the selected lines, from the text's start (the toolbar sits over the
    /// block, not over the selected words; under the last line where there's no room above).
    private func place(_ view: UITextView) {
        guard let range = view.selectedTextRange else { return }
        let line = view.firstRect(for: range)
        guard !line.isNull, !line.isInfinite else { return }
        let bottom = view.selectionRects(for: range).map(\.rect).filter { !$0.isNull && !$0.isEmpty }.map(\.maxY).max() ?? line.maxY
        let start = view.textContainerInset.left + view.textContainer.lineFragmentPadding - Metrics.leadingOverhang
        if anchor.superview !== view { view.addSubview(anchor) }
        anchor.frame = CGRect(x: start, y: line.minY, width: max(1, line.maxX - start), height: max(line.height, bottom - line.minY))
    }
}

/// The menu: what the selected text takes, read in its body (so it follows the text).
struct DocSelectionToolbar: View {
    let editor: DocEditor
    @Bindable var model: DocSelectionToolbarModel
    let dismiss: () -> Void

    var body: some View {
        let format = DocTextFormat(editor: editor, ranges: model.ranges)
        let view = { [editor, model] in model.block.flatMap { editor.textView(for: $0) } }
        FlooDesignActionMenu(sections: { [unfolded = $model.isUnfolded] _ in
            format.menuSections(linkFrom: view, unfolded: unfolded)
        }, unfolded: {
            format.menuSections(linkFrom: view, unfolded: .constant(true))
        }, dismiss: dismiss)
    }
}
