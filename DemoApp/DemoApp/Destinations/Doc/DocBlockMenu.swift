//
//  DocBlockMenu.swift
//  DemoApp
//
//  The Mac's right-click on a block (Craft's): the block is selected, or stays with the
//  others selected with it, and our menu (FlooDesign's action menu, by the pointer)
//  shows what can be done to them, in Craft's order: cut, copy, duplicate; Format (copy,
//  paste and clear the format, then the format panel's sections, a link, file or image's
//  layout among them); Insert above or below; delete. Craft's assistant, Writing Tools, comments, reactions,
//  reminders, Copy As, Paste, Sort and Move To have nothing behind them here and aren't
//  in it.
//

import UIKit
import DocKit
import FlooDesign

extension DocBlockController {
    /// The menu for the selected blocks.
    func selectionMenu() -> [FlooDesignActionMenuSection] {
        [
            .init(.rows, [
                .action(String(localized: "Cut")) { [weak self] in
                    self?.copySelection()
                    self?.deleteSelection()
                },
                .action(String(localized: "Copy")) { [weak self] in self?.copySelection() },
                .action(String(localized: "Duplicate")) { [weak self] in self?.duplicateSelection() },
            ]),
            .init(.rows, [
                formatMenu(DocFormatting(editor: editor)),
                .submenu(String(localized: "Insert"), sections: [.init(.rows, [
                    .action(String(localized: "Insert Above")) { [weak self] in self?.insertLine(above: true) },
                    .action(String(localized: "Insert Below")) { [weak self] in self?.insertLine(above: false) },
                ])]),
            ]),
            .init(.rows, [
                .action(String(localized: "Delete"), role: .destructive) { [weak self] in self?.deleteSelection() },
            ]),
        ]
    }

    /// Format: copy, paste and clear the format above what the format panel has (the
    /// same sections, `DocFormatMenu`), changed there and left open.
    private func formatMenu(_ formatting: DocFormatting) -> FlooDesignActionMenuItem {
        let copied = editor.panels.copiedFormat
        return .submenu(String(localized: "Format"), id: "format", sections: [
            .init(.rows, [
                .action(String(localized: "Copy Format")) { [weak self] in self?.editor.panels.copiedFormat = formatting.format },
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
}
