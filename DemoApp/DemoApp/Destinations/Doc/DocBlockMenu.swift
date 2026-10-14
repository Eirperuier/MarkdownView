//
//  DocBlockMenu.swift
//  DemoApp
//
//  The Mac's right-click on a block (Craft's): the block is selected, or stays with the
//  others selected with it, and the system's menu shows what can be done to them, in
//  Craft's order: a link, file or image's layouts; cut, copy, duplicate; Format (copy,
//  paste and clear the format, lists, decorations); Insert above or below; delete.
//  Craft's assistant, Writing Tools, comments, reactions, reminders, Copy As, Paste,
//  Sort and Move To have nothing behind them here and aren't in it (Ask Siri is the
//  system's own).
//

import UIKit
import DocKit

extension DocBlockController {
    /// The menu for the selected blocks.
    func selectionMenu() -> UIMenu {
        let formatting = DocFormatting(editor: editor)
        var sections: [UIMenuElement] = mediaSections()
        sections.append(UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Cut")) { [weak self] _ in
                self?.copySelection()
                self?.deleteSelection()
            },
            UIAction(title: String(localized: "Copy")) { [weak self] _ in self?.copySelection() },
            UIAction(title: String(localized: "Duplicate")) { [weak self] _ in self?.duplicateSelection() },
        ]))
        sections.append(UIMenu(options: .displayInline, children: [
            formatMenu(formatting),
            UIMenu(title: String(localized: "Insert"), children: [
                UIAction(title: String(localized: "Insert Above")) { [weak self] _ in self?.insertLine(above: true) },
                UIAction(title: String(localized: "Insert Below")) { [weak self] _ in self?.insertLine(above: false) },
            ]),
        ]))
        sections.append(UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Delete"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
        ]))
        return UIMenu(children: sections)
    }

    private func formatMenu(_ formatting: DocFormatting) -> UIMenu {
        let copied = editor.panels.copiedFormat
        var children: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Copy Format")) { [weak self] _ in self?.editor.panels.copiedFormat = formatting.format },
                UIAction(title: String(localized: "Paste Format"), attributes: copied == nil ? .disabled : []) { _ in
                    if let copied { formatting.paste(copied) }
                },
                UIAction(title: String(localized: "Clear Format")) { [weak self] _ in
                    guard let self else { return }
                    reshape { editor.clearFormat(of: Set(selected)) }
                },
            ]),
        ]
        // Lists are text's.
        if !formatting.targets.isEmpty {
            let lists: [(String, BlockKind)] = [
                (String(localized: "Todo List"), .listItem(style: .task(done: false))),
                (String(localized: "Bullet List"), .listItem(style: .bullet)),
                (String(localized: "Numbered List"), .listItem(style: .numbered)),
                (String(localized: "Toggle List"), .listItem(style: .toggle(open: true))),
            ]
            let isList = formatting.targets.contains { if case .listItem = $0.kind { true } else { false } }
            children.append(UIMenu(title: String(localized: "List"), children: lists.map { title, kind in
                UIAction(title: title, state: formatting.kindIsOn(kind) ? .on : .off) { _ in formatting.setStyle(kind) }
            } + [
                UIAction(title: String(localized: "No List"), state: isList ? .off : .on) { [weak self] _ in
                    guard let self else { return }
                    let items = formatting.targets.filter { if case .listItem = $0.kind { true } else { false } }.map(\.id)
                    reshape { editor.setKind(.paragraph, of: items) }
                },
            ]))
        }
        var decorations = [UIAction(title: String(localized: "Block"), state: formatting.isBoxed ? .on : .off) { _ in formatting.toggleBox() }]
        if !formatting.targets.isEmpty {
            decorations.append(UIAction(title: String(localized: "Quote"), state: formatting.kindIsOn(.quote) ? .on : .off) { _ in formatting.toggleQuote() })
        }
        children.append(UIMenu(title: String(localized: "Decorations"), children: decorations))
        return UIMenu(title: String(localized: "Format"), children: children)
    }

    /// The selected links, files and images's layouts, the one they all have ticked.
    private func mediaSections() -> [UIMenuElement] {
        var sections: [UIMenuElement] = []
        func choice(_ title: String, on: Bool, _ choose: @escaping () -> Void) -> UIAction {
            UIAction(title: title, state: on ? .on : .off) { _ in choose() }
        }
        let fits = selectedImageFits, sizes = selectedImageSizes, layouts = selectedLayouts
        if !fits.isEmpty {
            sections.append(UIMenu(title: String(localized: "Image Display"), options: .displayInline, children: [
                choice(String(localized: "Fit"), on: fits == [.fit]) { [weak self] in self?.setImage(fit: .fit) },
                choice(String(localized: "Fill"), on: fits == [.fill]) { [weak self] in self?.setImage(fit: .fill) },
            ]))
            sections.append(UIMenu(title: String(localized: "Image Size"), options: .displayInline, children: [
                choice(String(localized: "Auto"), on: sizes == [.auto]) { [weak self] in self?.setImage(size: .auto) },
                choice(String(localized: "Large"), on: sizes == [.large]) { [weak self] in self?.setImage(size: .large) },
            ]))
        }
        if !layouts.isEmpty {
            sections.append(UIMenu(title: String(localized: "Layout"), options: .displayInline, children: DocLayout.allCases.map { layout in
                choice(layout.title, on: layouts == [layout]) { [weak self] in self?.setLayout(layout) }
            }))
        }
        return sections
    }

    /// A new line of text above the first selected block, or below the last (after the
    /// items nested under it), at its level; the caret goes in it.
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
