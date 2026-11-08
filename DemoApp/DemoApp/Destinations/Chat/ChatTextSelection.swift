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
    /// The last message on screen selected whole.
    func selectAll() {
        guard let last = selectionVisibleRows.last else { return }
        view?.selectMessage(containing: last)
    }

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
        return shownRows()[row]?.selectableTexts
    }

    /// A prompt is a message; a reply's blocks together are one.
    func selectionMessageRows(containing row: Int) -> ClosedRange<Int> {
        let rows = rows
        guard rows.indices.contains(row) else { return 0...max(0, rows.count - 1) }
        func key(_ index: Int) -> String {
            if case .prompt = rows[index].kind { return "\(rows[index].exchange)p" }
            return "\(rows[index].exchange)r"
        }
        let message = key(row)
        var low = row, high = row
        while low > 0, key(low - 1) == message { low -= 1 }
        while high < rows.count - 1, key(high + 1) == message { high += 1 }
        return low...high
    }

    func selectionOffscreenTexts(ofRow row: Int) -> [MarkdownUIKit.MarkdownSelectableText] {
        let rows = rows
        guard rows.indices.contains(row), let list else { return [] }
        switch rows[row].kind {
        case .prompt(let text):
            let string = NSAttributedString(string: text, attributes: [.font: ChatUIKitPromptLayout.font(list.traitCollection)])
            return [MarkdownUIKit.MarkdownSelectableText(drawn: string, frame: .zero, in: list)]
        case .block(let block):
            let width = ChatUIKitRowLayout.textWidth(in: list.bounds.width)
            let key = OffscreenKey(id: rows[row].id, source: block.source, width: width, category: list.traitCollection.preferredContentSizeCategory)
            if let known = offscreenTexts[key] { return known }
            // The row's view, laid out as a row would: its text is then the same as on screen.
            let view = ChatUIKitBlockViews.view(id: rows[row].id, block: block, reveal: nil, traits: list.traitCollection)
            if view.superview == nil {
                let size = CGSize(width: width, height: view.height(forWidth: width))
                if view.bounds.size != size { view.frame = CGRect(origin: .zero, size: size) }
                view.layoutIfNeeded()
            }
            let texts = view.selectableTexts.map { $0.detached(in: list) }
            if offscreenTexts.count > 2048 { offscreenTexts.removeAll() }
            offscreenTexts[key] = texts
            return texts
        }
    }

    private struct OffscreenKey: Hashable {
        let id: String
        let source: String
        let width: CGFloat
        let category: UIContentSizeCategory
    }

    /// Rows' texts as they were on screen, or would be: a selection asks for them often.
    private var offscreenTexts: [OffscreenKey: [MarkdownUIKit.MarkdownSelectableText]] = [:]

    /// The block rows on screen, by index.
    private func shownRows() -> [Int: any ChatSelectableRowView] {
        guard let list else { return [:] }
        var shown: [Int: any ChatSelectableRowView] = [:]
        for cell in list.visibleCells {
            guard let rowView = Self.rowView(in: cell.contentView), let id = rowView.rowID, let index = rowIndex[id] else { continue }
            shown[index] = rowView
        }
        return shown
    }

    private static func rowView(in view: UIView, depth: Int = 0) -> (any ChatSelectableRowView)? {
        if let row = view as? any ChatSelectableRowView { return row }
        guard depth < 3 else { return nil }
        for subview in view.subviews {
            if let row = rowView(in: subview, depth: depth + 1) { return row }
        }
        return nil
    }
}

/// A row's view whose text a selection across rows takes.
@MainActor
protocol ChatSelectableRowView: UIView {
    var rowID: String? { get }
    /// Its text as laid out, in reading order.
    var selectableTexts: [MarkdownUIKit.MarkdownSelectableText] { get }
}

extension ChatUIKitRowView: ChatSelectableRowView {
    var selectableTexts: [MarkdownUIKit.MarkdownSelectableText] { blockView?.selectableTexts ?? [] }
}

extension ChatUIKitPromptView: ChatSelectableRowView {}
