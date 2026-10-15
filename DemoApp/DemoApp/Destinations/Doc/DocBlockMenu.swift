//
//  DocBlockMenu.swift
//  DemoApp
//
//  The Mac's right-click on a block (Craft's): the block is selected, or stays with the
//  others selected with it, and our menu (FlooDesign's action menu, by the pointer)
//  shows what can be done to them, in Craft's order: a link, file or image's layouts;
//  cut, copy, duplicate; Format (copy, paste and clear the format, lists, decorations);
//  Insert above or below; delete. Craft's assistant, Writing Tools, comments, reactions,
//  reminders, Copy As, Paste, Sort and Move To have nothing behind them here and aren't
//  in it.
//

import UIKit
import DocKit
import FlooDesign

extension DocBlockController {
    /// The menu for the selected blocks.
    func selectionMenu() -> [FlooDesignActionMenuSection] {
        let formatting = DocFormatting(editor: editor)
        var sections = mediaSections()
        sections.append(.init(.rows, [
            .action(String(localized: "Cut")) { [weak self] in
                self?.copySelection()
                self?.deleteSelection()
            },
            .action(String(localized: "Copy")) { [weak self] in self?.copySelection() },
            .action(String(localized: "Duplicate")) { [weak self] in self?.duplicateSelection() },
        ]))
        sections.append(.init(.rows, [
            formatMenu(formatting),
            .submenu(String(localized: "Insert"), sections: [.init(.rows, [
                .action(String(localized: "Insert Above")) { [weak self] in self?.insertLine(above: true) },
                .action(String(localized: "Insert Below")) { [weak self] in self?.insertLine(above: false) },
            ])]),
        ]))
        sections.append(.init(.rows, [
            .action(String(localized: "Delete"), role: .destructive) { [weak self] in self?.deleteSelection() },
        ]))
        return sections
    }

    private func formatMenu(_ formatting: DocFormatting) -> FlooDesignActionMenuItem {
        let copied = editor.panels.copiedFormat
        var rows: [FlooDesignActionMenuItem] = []
        // Lists are text's.
        if !formatting.targets.isEmpty {
            let lists: [(String, BlockKind)] = [
                (String(localized: "Todo List"), .listItem(style: .task(done: false))),
                (String(localized: "Bullet List"), .listItem(style: .bullet)),
                (String(localized: "Numbered List"), .listItem(style: .numbered)),
                (String(localized: "Toggle List"), .listItem(style: .toggle(open: true))),
            ]
            let isList = formatting.targets.contains { if case .listItem = $0.kind { true } else { false } }
            rows.append(.submenu(String(localized: "List"), sections: [.init(.rows, lists.map { title, kind in
                .action(title, isOn: formatting.kindIsOn(kind)) { formatting.setStyle(kind) }
            } + [
                .action(String(localized: "No List"), isOn: !isList) { [weak self] in
                    guard let self else { return }
                    let items = formatting.targets.filter { if case .listItem = $0.kind { true } else { false } }.map(\.id)
                    reshape { editor.setKind(.paragraph, of: items) }
                },
            ])]))
        }
        var decorations: [FlooDesignActionMenuItem] = [.action(String(localized: "Block"), isOn: formatting.isBoxed) { formatting.toggleBox() }]
        if !formatting.targets.isEmpty {
            decorations.append(.action(String(localized: "Quote"), isOn: formatting.kindIsOn(.quote)) { formatting.toggleQuote() })
        }
        rows.append(.submenu(String(localized: "Decorations"), sections: [.init(.rows, decorations)]))
        return .submenu(String(localized: "Format"), sections: [
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
            .init(.rows, rows),
        ])
    }

    /// The selected links, files and images's layouts, the one they all have ticked.
    private func mediaSections() -> [FlooDesignActionMenuSection] {
        var sections: [FlooDesignActionMenuSection] = []
        let fits = selectedImageFits, sizes = selectedImageSizes, layouts = selectedLayouts
        if !fits.isEmpty {
            sections.append(.init(title: String(localized: "Image Display"), [
                .action(String(localized: "Fit"), isOn: fits == [.fit]) { [weak self] in self?.setImage(fit: .fit) },
                .action(String(localized: "Fill"), isOn: fits == [.fill]) { [weak self] in self?.setImage(fit: .fill) },
            ]))
            sections.append(.init(title: String(localized: "Image Size"), [
                .action(String(localized: "Auto"), isOn: sizes == [.auto]) { [weak self] in self?.setImage(size: .auto) },
                .action(String(localized: "Large"), isOn: sizes == [.large]) { [weak self] in self?.setImage(size: .large) },
            ]))
        }
        if !layouts.isEmpty {
            sections.append(.init(title: String(localized: "Layout"), DocLayout.allCases.map { layout in
                .action(layout.title, isOn: layouts == [layout], id: "layout-\(layout)") { [weak self] in self?.setLayout(layout) }
            }))
        }
        return sections
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
