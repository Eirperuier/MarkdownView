//
//  ChatTextSelection.swift
//  DemoApp
//
//  The chat's text selection under `-chatRenderer uikit`: one selection over the whole list, from
//  block to block and row to row, with the system's handles and menu (MarkdownSelectionView).
//

import MarkdownUIKit
import MarkdownView
import UIKit

@MainActor
final class ChatTextSelection: MarkdownSelectionSource {
    static let shared = ChatTextSelection()

    /// `-chatSelectsAcrossBlocks NO` leaves selecting to each block's text view.
    static let isOn = ChatRenderer.current == .uikit
        && (UserDefaults.standard.object(forKey: "chatSelectsAcrossBlocks") == nil || UserDefaults.standard.bool(forKey: "chatSelectsAcrossBlocks"))

    weak var conversation: ChatConversation?
    private weak var list: UICollectionView?
    private var view: MarkdownSelectionView?
    private var rowIndex: [String: Int] = [:]
    private var indexedRows: [ChatRow] = []
    private var redrawQueued = false

    /// A row showed in a list: the selection goes over that list, once.
    func attach(from row: UIView) {
        guard Self.isOn, list == nil || list?.window == nil else { return }
        var ancestor = row.superview
        while let current = ancestor, !(current is UICollectionView) { ancestor = current.superview }
        guard let list = ancestor as? UICollectionView else { return }
        view?.removeFromSuperview()
        self.list = list
        let view = MarkdownSelectionView(list: list, source: self)
        view.openURL = { url in ChatUIKitBlock.style.openURL?(url) ?? UIApplication.shared.open(url) }
        self.view = view
    }

    /// Rows came or went on screen: the selection is drawn again over them, once a pass.
    func rowsDidChange() {
        guard view != nil, !redrawQueued else { return }
        redrawQueued = true
        DispatchQueue.main.async { [self] in
            redrawQueued = false
            view?.rowsDidChange()
        }
    }

    /// What's selected, for a probe.
    var selectedText: String? {
        guard let view, let range = view.selectedTextRange, !range.isEmpty else { return nil }
        return view.text(in: range)
    }

    // MARK: MarkdownSelectionSource

    private var rows: [ChatRow] {
        let rows = conversation?.rows ?? []
        if rows.count != indexedRows.count || rows.first?.id != indexedRows.first?.id || rows.last?.id != indexedRows.last?.id {
            indexedRows = rows
            rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return rows
    }

    var selectionRowCount: Int { rows.count }

    var selectionVisibleRows: [Int] {
        _ = rows
        return shownRows().keys.sorted()
    }

    func selectionTexts(ofRow row: Int) -> [MarkdownUIKit.MarkdownSelectableText]? {
        _ = rows
        return shownRows()[row]?.blockView?.selectableTexts
    }

    func selectionString(ofRow row: Int) -> String {
        let rows = rows
        guard rows.indices.contains(row) else { return "" }
        switch rows[row].kind {
        case .prompt(let text):
            return text
        case .block(let block):
            if let view = ChatUIKitBlockViews.existingView(id: rows[row].id) {
                return view.selectableTexts.map(\.string).joined(separator: "\n")
            }
            guard MarkdownUIKit.MarkdownBlockView.draws(block) else { return "" }
            return ChatUIKitBlockViews.plainText(of: block)
        }
    }

    /// The block rows on screen, by index.
    private func shownRows() -> [Int: ChatUIKitRowView] {
        guard let list else { return [:] }
        var shown: [Int: ChatUIKitRowView] = [:]
        for cell in list.visibleCells {
            guard let rowView = Self.rowView(in: cell.contentView), let id = rowView.rowID, let index = rowIndex[id] else { continue }
            shown[index] = rowView
        }
        return shown
    }

    private static func rowView(in view: UIView, depth: Int = 0) -> ChatUIKitRowView? {
        if let row = view as? ChatUIKitRowView { return row }
        guard depth < 3 else { return nil }
        for subview in view.subviews {
            if let row = rowView(in: subview, depth: depth + 1) { return row }
        }
        return nil
    }
}
