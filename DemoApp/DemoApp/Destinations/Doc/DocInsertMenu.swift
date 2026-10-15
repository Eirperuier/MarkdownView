//
//  DocInsertMenu.swift
//  DemoApp
//
//  The phone's + key (Craft's): the system's menu, of what goes in at the caret. More
//  (a submenu, which the system unfolds in place) holds the blocks: the text styles,
//  lists and decorations, a divider; a table and a page; code and a formula. Then where
//  images and files come from (DocInsertSources), and Live Text, the camera's words
//  typed at the caret. Each row has its drawn icon (DocBlockIcon), as the command menu's.
//  A command does what the command menu's does, on the caret's block with nothing typed.
//

import SwiftUI
import UIKit
import DocKit

@MainActor
enum DocInsertMenu {
    /// The menu, made as it opens (what the caret's block and this device have now).
    static func menu(editor: DocEditor) -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak editor] completion in
            completion(editor.map(elements) ?? [])
        }])
    }

    /// More's commands, by the command menu's ids, in Craft's sections.
    private static let more = [["style", "list", "decorations", "divider"], ["table", "page"], ["code", "math"]]
    /// The sources, by id, in Craft's sections (Live Text joins the first).
    private static let sources = [["insert-file", "insert-scan"], ["insert-image", "insert-photos", "insert-camera"]]

    static func elements(_ editor: DocEditor) -> [UIMenuElement] {
        let commands = Dictionary(DocCommand.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let blocks = more.map { ids in inline(ids.compactMap { commands[$0] }.map { element($0, editor: editor) }) }
        let more = UIMenu(title: String(localized: "More"), image: UIImage(systemName: "ellipsis.circle"), children: blocks)
        var places = sources.map { ids in ids.compactMap { commands[$0] }.map { element($0, editor: editor) } }
        if let liveText = liveText(editor) { places[0].append(liveText) }
        return [inline([more])] + places.filter { !$0.isEmpty }.map(inline)
    }

    private static func inline(_ children: [UIMenuElement]) -> UIMenu {
        UIMenu(options: .displayInline, children: children)
    }

    /// A command's row: a group is a submenu of its commands.
    private static func element(_ command: DocCommand, editor: DocEditor) -> UIMenuElement {
        let image = DocBlockIcon.Glyph.of(command).map(DocBlockIcon.image) ?? UIImage(systemName: command.symbol)
        if command.isGroup {
            return UIMenu(title: command.title, image: image, children: command.children.map { element($0, editor: editor) })
        }
        return UIAction(title: command.title, image: image) { [weak editor] _ in
            guard let action = command.action else { return }
            editor?.performAtCaret(action)
        }
    }

    /// The camera's words typed at the caret, where this device reads them.
    private static func liveText(_ editor: DocEditor) -> UIMenuElement? {
        guard let selection = editor.selection, let view = editor.textView(for: selection.head.block),
              view.canPerformAction(#selector(UIResponder.captureTextFromCamera(_:)), withSender: nil)
        else { return nil }
        return UIAction(title: String(localized: "Live Text"), image: DocBlockIcon.image(.liveText)) { [weak view] _ in
            view?.captureTextFromCamera(nil)
        }
    }
}

extension DocEditor {
    /// A command on the caret's block, nothing typed for it (the + key's menu).
    func performAtCaret(_ action: DocCommand.Action) {
        guard let selection, let block = demo.doc.block(selection.head.block) else { return }
        let caret = selection.head
        perform(action, in: block, replacing: caret.offset..<caret.offset, from: caret)
        keyboardBar.update()
    }
}
