//
//  DocEditingPlaces.swift
//  DemoApp
//
//  Where typing goes on the page, and what that place offers besides typing: one
//  protocol for every place the page edits text in. A block's text, a table's cell (its
//  text, or a column's name), a code or math block's source, a collection's field (a
//  record's cell, a card's title, the collection's and a view's name, its search).
//
//  A place has its menu, the one a right-click on it opens on the Mac (a table cell's is
//  Craft's cell menu, a record's its row menu); on a phone the keyboard bar has a key
//  that opens the same rows. And it has the bar's keys: the text's own (the slash, Aa,
//  ⋮, a divider, +), its menu's, and those of its menu's actions that have a key of
//  their own (Craft's f(x) in a cell). The bar shows a place's keys while the keyboard
//  is up for it (DocKeyboardBar).
//
//  The editor finds the place from what has the keyboard (its text views, a cell's
//  name, a source); SwiftUI's fields say which place they are as they take the focus
//  (`docEditingPlace`).
//

import SwiftUI
import UIKit
import DocKit
import FlooDesign

/// A key of the keyboard bar: what it shows, and what it does (an action, or the
/// system's menu of its rows).
@MainActor
struct DocBarKey {
    enum Action {
        case perform(() -> Void)
        case menu(UIMenu)
    }

    let id: String
    let title: String
    let image: UIImage?
    let action: Action
}

/// A place's own menu: what a right-click on it opens on the Mac; on a phone, the bar's
/// key for it (its symbol) opens the same.
@MainActor
struct DocPlaceMenu {
    enum Opens {
        /// Its rows: our action menu on the Mac, the system's menu of them on a phone.
        case rows(() -> [FlooDesignActionMenuSection])
        /// A menu of its own showing (a table cell's, by its cell).
        case own(() -> Void)
    }

    let title: String
    let symbol: String
    let opens: Opens

    /// The bar's key for it.
    var key: DocBarKey {
        let image = UIImage(systemName: symbol)
        switch opens {
        case .rows(let rows):
            // Made as it opens, so it shows what's so then.
            let menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in
                completion(FlooDesignContextMenus.systemMenu(rows()))
            }])
            return DocBarKey(id: "menu", title: title, image: image, action: .menu(menu))
        case .own(let show):
            return DocBarKey(id: "menu", title: title, image: image, action: .perform(show))
        }
    }

    /// Its rows for a right-click (`.flooDesignContextMenu`); nil when it shows its own.
    var rows: (() -> [FlooDesignActionMenuSection])? {
        if case .rows(let rows) = opens { rows } else { nil }
    }
}

/// Where typing goes, and what it offers besides.
@MainActor
protocol DocEditingPlace {
    /// Which place it is, as far as its keys go: they're made again when it changes.
    var id: AnyHashable { get }
    /// Its own menu (nil: it has none).
    var menu: DocPlaceMenu? { get }
    /// The bar's keys for it, left to right, before its gap and after it (the keyboard's
    /// key ends the row).
    func keys(_ editor: DocEditor) -> (leading: [DocBarKey], trailing: [DocBarKey])
}

extension DocEditingPlace {
    var menu: DocPlaceMenu? { nil }
}

// MARK: Places

/// A block's text, at the caret: the slash (not over selected text: it would type over
/// it), Aa and ⋮ for the block; a divider on an empty line, and + (what goes in at the
/// caret).
struct DocTextPlace: DocEditingPlace {
    let block: DocBlock
    let hasSelectedText: Bool

    var id: AnyHashable { ["text", block.id, block.kind, block.indent, block.text.isEmpty, hasSelectedText] as [AnyHashable] }

    func keys(_ editor: DocEditor) -> (leading: [DocBarKey], trailing: [DocBarKey]) {
        var leading: [DocBarKey] = []
        if !hasSelectedText {
            leading.append(DocBarKey(id: "slash", title: String(localized: "Commands"), image: DocKeyboardBar.slashGlyph,
                                     action: .perform { [weak editor] in editor?.typeSlash() }))
        }
        leading.append(.format { [weak editor] in editor?.blocks.formatCaretBlock() })
        leading.append(.select { [weak editor] in editor?.blocks.selectCaretBlock() })
        var trailing: [DocBarKey] = []
        if block.text.isEmpty {
            trailing.append(DocBarKey(id: "divider", title: String(localized: "Divider"), image: DocKeyboardBar.dividerGlyph,
                                      action: .perform { [weak editor, block] in
                editor?.perform(.divider, in: block, replacing: 0..<0, from: DocPosition(block: block.id, offset: 0))
            }))
        }
        if !hasSelectedText {
            trailing.append(DocBarKey(id: "insert", title: String(localized: "Insert"), image: UIImage(systemName: "plus"),
                                      action: .menu(DocInsertMenu.menu(editor: editor))))
        }
        return (leading, trailing)
    }
}

/// A table's cell (Craft's): Aa for its text (the cell's format sheet), its menu (the
/// one its ⋮ and a right-click open), f(x) where a formula may go, ⋮ for the table. A
/// column's name has its menu and ⋮.
struct DocTableCellPlace: DocEditingPlace {
    let key: DocCellKey
    let controller: DocTableController

    var id: AnyHashable { ["cell", key, controller.isAvailable(.insertFormula, at: key)] as [AnyHashable] }

    var menu: DocPlaceMenu? {
        DocPlaceMenu(title: String(localized: "Table Actions"), symbol: "tablecells.badge.ellipsis",
                     opens: .own { [controller, key] in controller.showMenu(key) })
    }

    func keys(_ editor: DocEditor) -> (leading: [DocBarKey], trailing: [DocBarKey]) {
        var leading: [DocBarKey] = []
        if key.row != nil { leading.append(.format { [weak editor] in editor?.blocks.formatCaretBlock() }) }
        if let menu { leading.append(menu.key) }
        if controller.isAvailable(.insertFormula, at: key) {
            leading.append(DocBarKey(id: "formula", title: DocTableAction.insertFormula.title, image: DocKeyboardBar.formulaGlyph,
                                     action: .perform { [controller, key] in controller.perform(.insertFormula, at: key) }))
        }
        leading.append(.select { [weak editor, key] in editor?.blocks.selectBlock(key.block) })
        return (leading, [])
    }
}

/// A code or math block's source: Aa and ⋮ for the block.
struct DocSourcePlace: DocEditingPlace {
    let block: DocBlockID

    var id: AnyHashable { ["source", block] as [AnyHashable] }

    func keys(_ editor: DocEditor) -> (leading: [DocBarKey], trailing: [DocBarKey]) {
        ([.format { [weak editor, block] in editor?.blocks.formatBlock(block) },
          .select { [weak editor, block] in editor?.blocks.selectBlock(block) }], [])
    }
}

/// A field of a block's (a collection's record cell, card title, name, search): its
/// menu, if it has one, and ⋮ for its block.
struct DocFieldPlace: DocEditingPlace {
    let field: AnyHashable
    let block: DocBlockID
    var menu: DocPlaceMenu?

    var id: AnyHashable { ["field", field] as [AnyHashable] }

    func keys(_ editor: DocEditor) -> (leading: [DocBarKey], trailing: [DocBarKey]) {
        ((menu.map { [$0.key] } ?? []) + [.select { [weak editor, block] in editor?.blocks.selectBlock(block) }], [])
    }
}

@MainActor
extension DocBarKey {
    /// Aa: the block's format (Craft's Style sheet).
    static func format(_ perform: @escaping () -> Void) -> Self {
        DocBarKey(id: "format", title: String(localized: "Format"), image: DocKeyboardBar.formatGlyph, action: .perform(perform))
    }

    /// ⋮: the block selected.
    static func select(_ perform: @escaping () -> Void) -> Self {
        DocBarKey(id: "more", title: String(localized: "Select Block"), image: DocKeyboardBar.verticalEllipsis, action: .perform(perform))
    }
}

// MARK: Finding the place

extension DocEditor {
    /// Where typing goes now: what has the keyboard, as a place.
    var editingPlace: (any DocEditingPlace)? {
        switch DocFirstResponder.current {
        case let view as DocCellTextView:
            return view.key.map { DocTableCellPlace(key: $0, controller: tables) }
        case let view as DocSourceTextView:
            return view.block.map { DocSourcePlace(block: $0) }
        case let view as UITextView where allTextViews.contains(view):
            guard let selection, let block = textBlock(selection.head.block) else { return nil }
            if let cell = tables.cell(of: block.id) { return DocTableCellPlace(key: cell, controller: tables) }
            return DocTextPlace(block: block, hasSelectedText: selection.anchor != selection.head)
        case .some:
            return focusedField
        case nil:
            return nil
        }
    }

    /// A field took the focus or lost it (`docEditingPlace`).
    func field(_ place: any DocEditingPlace, isFocused: Bool) {
        if isFocused {
            focusedField = place
        } else if focusedField?.id == place.id {
            focusedField = nil
        }
        placeChanged()
    }

    /// The keyboard went to another place: the bar shows (or goes) and takes its keys.
    func placeChanged() {
        updateKeyboardBar()
        keyboardBar.update()
    }
}

extension View {
    /// This view's field is `place` while it has the focus (the keyboard bar's keys).
    func docEditingPlace(_ place: any DocEditingPlace, isFocused: Bool, editor: DocEditor) -> some View {
        onChange(of: isFocused, initial: true) { _, focused in
            if focused || editor.focusedField?.id == place.id { editor.field(place, isFocused: focused) }
        }
    }
}

/// `docEditingPlace` where a field may have no place (a record's own page).
struct DocFieldPlaceModifier: ViewModifier {
    let place: (any DocEditingPlace)?
    let isFocused: Bool
    let editor: DocEditor

    func body(content: Content) -> some View {
        if let place { content.docEditingPlace(place, isFocused: isFocused, editor: editor) } else { content }
    }
}

/// What has the keyboard (UIKit tells it only to an action sent to no one in particular).
@MainActor
enum DocFirstResponder {
    fileprivate static weak var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.docFoundFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }
}

extension UIResponder {
    @objc fileprivate func docFoundFirstResponder(_ sender: Any?) {
        DocFirstResponder.found = self
    }
}
