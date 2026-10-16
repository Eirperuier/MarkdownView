//
//  DocBlockMenu.swift
//  DemoApp
//
//  The Mac's right-click on a block (Craft's): the block is selected, or stays with the
//  others selected with it, and our menu (FlooDesign's action menu, by the pointer)
//  shows what can be done to them, in Craft's order: Edit (one block of text; a code
//  block's language and Copy Code under it) or, for several, how many under a title and
//  Group (into a page); cut, copy, duplicate; Format (copy, paste and clear the format,
//  then the format panel's sections, a link, file or image's layout among them); Insert
//  above or below; Sort (several); delete. Craft's
//  assistant, Writing Tools, comments, reactions, reminders, Copy As, Paste and Move To
//  have nothing behind them here and aren't in it.
//

import UIKit
import DocKit
import FlooDesign

extension DocBlockController {
    /// The menu for the selected blocks: one block's, or several's (Craft's differ).
    func selectionMenu() -> [FlooDesignActionMenuSection] {
        let tops = groups(selected).map { $0[0] }
        let several = canGroup
        let editable = tops.first.flatMap { demo.doc.block($0) }.map { !several && $0.kind.carriesText } ?? false
        var sections: [FlooDesignActionMenuSection] = []
        if several {
            sections.append(.init(title: String(localized: "\(selected.count) items"), [
                .action(String(localized: "Group")) { [weak self] in self?.groupSelection() },
            ]))
        } else if editable, let block = tops.first {
            sections.append(.init(.rows, [.action(String(localized: "Edit")) { [weak self] in self?.edit(block) }]))
            // A code block's: its language, Copy Code.
            sections += editor.sources.codeMenu(block)
        }
        sections += [
            .init(.rows, [
                .action(String(localized: "Cut")) { [weak self] in
                    self?.copySelection()
                    self?.deleteSelection()
                },
                .action(String(localized: "Copy")) { [weak self] in self?.copySelection() },
                .action(String(localized: "Duplicate")) { [weak self] in self?.duplicateSelection() },
            ]),
            .init(.rows, [
                formatMenu(DocFormatting(editor: editor), copies: !several),
                .submenu(String(localized: "Insert"), sections: [.init(.rows, [
                    .action(String(localized: "Insert Above")) { [weak self] in self?.insertLine(above: true) },
                    .action(String(localized: "Insert Below")) { [weak self] in self?.insertLine(above: false) },
                ])]),
                .submenu(String(localized: "Sort"), sections: [.init(.rows, [
                    .action(String(localized: "Sort A → Z"), isEnabled: several) { [weak self] in self?.sortSelection(descending: false) },
                    .action(String(localized: "Sort Z → A"), isEnabled: several) { [weak self] in self?.sortSelection(descending: true) },
                ])]),
            ]),
            .init(.rows, [
                .action(String(localized: "Delete"), role: .destructive) { [weak self] in self?.deleteSelection() },
            ]),
        ]
        return sections
    }

    /// Format: copy, paste and clear the format above what the format panel has (the
    /// same sections, `DocFormatMenu`), changed there and left open.
    /// Copy Format only for one block (`copies`).
    private func formatMenu(_ formatting: DocFormatting, copies: Bool) -> FlooDesignActionMenuItem {
        let copied = editor.panels.copiedFormat
        return .submenu(String(localized: "Format"), id: "format", sections: [
            .init(.rows, [
                .action(String(localized: "Copy Format"), isEnabled: copies) { [weak self] in self?.editor.panels.copiedFormat = formatting.format },
                .action(String(localized: "Paste Format"), isEnabled: copied != nil) {
                    if let copied { formatting.paste(copied) }
                },
                .action(String(localized: "Clear Format")) { [weak self] in
                    guard let self else { return }
                    reshape { editor.clearFormat(of: Set(selected)) }
                },
            ]),
        ] + DocFormatMenu(editor: editor).sections)
    }

    /// A new line of text above the first selected block, or below the last (after the
    /// blocks nested under it), at its level; the caret goes in it.
    func insertLine(above: Bool) {
        let blocks = demo.doc.blocks
        guard let first = selected.first, let last = selected.last,
              let reference = demo.doc.block(above ? first : last) else { return }
        let after: DocBlockID?
        if above {
            after = blocks.firstIndex { $0.id == first }.flatMap { $0 > 0 ? blocks[$0 - 1].id : nil }
        } else {
            after = groups([last]).first?.last ?? last
        }
        let line = DocBlock(id: demo.newBlockID(), kind: .paragraph, indent: reference.indent)
        let caret = DocPosition(block: line.id, offset: 0)
        let selection = DocSelection(anchor: caret, head: caret)
        clear()
        guard demo.edit([.insertBlock(block: line, after: after)], before: editor.selection, after: selection) != nil else { return }
        editor.place(selection)
    }

    /// The caret at the end of a block's text (Craft's Edit).
    func edit(_ block: DocBlockID) {
        guard let text = demo.doc.block(block)?.text else { return }
        let caret = DocPosition(block: block, offset: text.length)
        clear()
        editor.place(DocSelection(anchor: caret, head: caret))
    }

    /// The selected blocks (with the blocks nested under them) in the order of their
    /// words, from where the first of them is, one after another (Craft's Sort A → Z).
    func sortSelection(descending: Bool) {
        let groups = groups(selected)
        let blocks = demo.doc.blocks
        guard groups.count > 1, let first = blocks.firstIndex(where: { $0.id == groups[0][0] }) else { return }
        func words(_ group: [DocBlockID]) -> String { demo.doc.block(group[0])?.text.string ?? "" }
        let sorted = groups.sorted { a, b in
            let order = words(a).localizedStandardCompare(words(b))
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        var steps: [DocStep] = []
        var previous = first == 0 ? nil : blocks[first - 1].id
        for id in sorted.flatMap({ $0 }) {
            steps.append(.moveBlock(block: id, after: previous, from: nil))
            previous = id
        }
        reshape { demo.edit(steps, before: editor.selection, after: editor.selection) }
    }

    /// Whether Group is offered: two blocks or more selected, one nested under the other
    /// too (Craft's), on the Mac's menu and the phone's selection bar.
    var canGroup: Bool { selected.count > 1 }

    /// The selected blocks (with the blocks nested under them, a table's or collection's
    /// records too) moved into a new page, a page block where the first of them was
    /// (Craft's Group); the page block is selected.
    func groupSelection() {
        let ids = Set(groups(selected).flatMap { $0 })
        let blocks = demo.doc.blocks
        let moving = blocks.filter { ids.contains($0.id) }
        guard let first = blocks.firstIndex(where: { ids.contains($0.id) }) else { return }
        let lowest = moving.map(\.indent).min() ?? 0
        var databases: [DatabaseID: Database] = [:]
        var steps: [DocStep] = []
        for block in moving {
            if let id = block.kind.databaseID, let database = demo.doc.databases[id] { databases[id] = database }
        }
        let page = Doc(id: .generate(), blocks: moving.map { block in
            var block = block
            block.indent -= lowest
            return block
        }, databases: databases)
        let summary = DocPage.summary(of: page)
        let block = DocBlock(id: demo.newBlockID(), kind: .page(page: DocPage(doc: page.id, title: summary.title, preview: summary.preview)),
                             indent: blocks[first].indent)
        steps.append(.insertBlock(block: block, after: first == 0 ? nil : blocks[first - 1].id))
        for block in moving.reversed() { steps.append(.deleteBlock(block: block, after: nil)) }
        steps += databases.values.map { .deleteDatabase(database: $0) }
        DocStore.shared.save(page)
        clear()
        guard demo.edit(steps, before: editor.selection, after: editor.selection) != nil else { return }
        select([block.id])
    }
}
