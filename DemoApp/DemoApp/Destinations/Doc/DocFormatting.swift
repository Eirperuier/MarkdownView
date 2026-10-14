//
//  DocFormatting.swift
//  DemoApp
//
//  What the format panels act on and what they do, shared by the Mac's panel and the
//  phone's sheet: the selected blocks, or the block the cursor is in; marks and the
//  colour on the selected text, or on the blocks' text. Read inside a view's body, so
//  the view follows the document and the selection.
//

import SwiftUI
import DocKit

/// A block's format as Copy Format takes it: its kind, its decoration, and the marks
/// all of its text has.
struct DocCopiedFormat: Equatable {
    var kind: BlockKind
    var decoration: BlockDecoration?
    var marks: [MarkKind: Mark]

    /// The marks a format carries (a link, a mention, maths are content, not format).
    static let markKinds: [MarkKind] = [.bold, .italic, .strike, .code, .color, .highlight]
}

@MainActor
struct DocFormatting {
    let editor: DocEditor
    /// A caret stands for its whole block (the phone's sheet, Craft's): its marks and
    /// colour go on all of the block's text. The Mac's panel marks only selected text.
    var caretTakesBlock = false

    private var demo: DocDemo { editor.demo }

    // MARK: What it acts on

    /// The selected blocks of text, else the one the cursor is in.
    var targets: [DocBlock] {
        let selected = Set(editor.blocks.selected)
        if !selected.isEmpty {
            return demo.doc.blocks.filter { selected.contains($0.id) && $0.kind.carriesText }
        }
        guard let id = editor.cursor.selection?.head.block, let block = editor.textBlock(id), block.kind.carriesText else { return [] }
        return [block]
    }

    /// Whether the cursor is in a table's cell: its text takes marks, not a kind or a box.
    var inCell: Bool {
        editor.blocks.selected.isEmpty && editor.cursor.selection.map { editor.tables.cell(of: $0.head.block) != nil } ?? false
    }

    /// The selected blocks of any kind, else the one the cursor is in: what a box goes around.
    var decorated: [DocBlock] {
        let selected = Set(editor.blocks.selected)
        if !selected.isEmpty { return demo.doc.blocks.filter { selected.contains($0.id) } }
        guard let id = editor.cursor.selection?.head.block, let block = demo.doc.block(id) else { return [] }
        return [block]
    }

    /// The selected text, else all the text of the selected blocks (or the caret's).
    var markRanges: [(block: DocBlockID, range: Range<Int>)] {
        if editor.blocks.selected.isEmpty, let selection = editor.cursor.selection, selection.anchor.block == selection.head.block {
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            if !range.isEmpty { return [(selection.head.block, range)] }
            if !caretTakesBlock { return [] }
        }
        return targets.filter { $0.kind.allowsMarks && !$0.text.isEmpty }.map { ($0.id, 0..<$0.text.length) }
    }

    func markIsOn(_ mark: Mark) -> Bool {
        let ranges = markRanges
        return !ranges.isEmpty && ranges.allSatisfy { range in
            editor.textBlock(range.block).map { DocEditor.covers($0.text, range.range, with: mark.kind) } ?? false
        }
    }

    func kindIsOn(_ kind: BlockKind) -> Bool {
        let blocks = targets
        return !blocks.isEmpty && blocks.allSatisfy { Self.same($0.kind, kind) }
    }

    func canIndent(_ delta: Int) -> Bool {
        targets.contains { block in
            guard case .listItem = block.kind else { return false }
            return delta < 0 ? block.indent > 0 : true
        }
    }

    var isBoxed: Bool {
        let blocks = decorated
        return !blocks.isEmpty && blocks.allSatisfy { $0.decoration == .block }
    }

    /// The text colour all of the text has, if one does.
    var color: Mark? { editor.common(.color, over: markRanges) }

    // MARK: What it does

    func setStyle(_ kind: BlockKind) {
        let ids = targets.map(\.id)
        editor.blocks.reshape { editor.setKind(kind, of: ids) }
    }

    /// One of the text styles (⌃1–⌃6): only the type changes, which has nothing to
    /// animate, so it isn't animated.
    func setTextStyle(_ kind: BlockKind) {
        editor.setKind(kind, of: targets.map(\.id))
    }

    /// Pressed again, a list goes back to text (Craft's); items already in the style
    /// keep their state (a done task stays done).
    func toggleList(_ kind: BlockKind) {
        if kindIsOn(kind) {
            setStyle(.paragraph)
        } else {
            let ids = targets.filter { !Self.same($0.kind, kind) }.map(\.id)
            editor.blocks.reshape { editor.setKind(kind, of: ids) }
        }
    }

    func indent(by delta: Int) {
        let ids = targets.map(\.id)
        editor.blocks.reshape { editor.indent(ids, by: delta) }
    }

    func toggleQuote() {
        setStyle(kindIsOn(.quote) ? .paragraph : .quote)
    }

    func toggleBox() {
        let boxed = isBoxed
        let ids = decorated.map(\.id)
        editor.blocks.reshape { editor.setDecoration(boxed ? nil : .block, of: ids) }
    }

    func toggle(_ mark: Mark) {
        editor.toggle(mark, over: markRanges)
    }

    /// A colour from the palette (nil: the text's own), one step.
    func setColor(_ token: String?) {
        editor.endColorChanges()
        editor.set(.color, to: token.map(Mark.color), over: markRanges)
    }

    /// A colour being picked: one step however long it's dragged.
    func pickColor(_ color: Color) {
        let ranges = markRanges
        editor.set(.color, to: .color(DocColors.hex(color)), over: ranges, merge: editor.colorMergeKey(over: ranges))
    }

    /// The first target's format, for Paste Format.
    var format: DocCopiedFormat? {
        guard let block = targets.first ?? decorated.first else { return nil }
        let whole = block.kind.allowsMarks && !block.text.isEmpty ? [(block: block.id, range: 0..<block.text.length)] : []
        var marks: [MarkKind: Mark] = [:]
        for kind in DocCopiedFormat.markKinds {
            if let mark = editor.common(kind, over: whole) { marks[kind] = mark }
        }
        // A list's style, not one item's state (a done task, a closed toggle).
        let kind: BlockKind = switch block.kind {
        case .listItem(style: .task): .listItem(style: .task(done: false))
        case .listItem(style: .toggle): .listItem(style: .toggle(open: true))
        default: block.kind
        }
        return DocCopiedFormat(kind: kind, decoration: block.decoration, marks: marks)
    }

    func paste(_ format: DocCopiedFormat) {
        let ids = Set(decorated.map(\.id))
        editor.blocks.reshape { editor.apply(format, to: ids) }
    }

    // MARK: Pieces

    /// The same kind, a task's or toggle's state aside.
    static func same(_ a: BlockKind, _ b: BlockKind) -> Bool {
        switch (a, b) {
        case (.listItem(let x), .listItem(let y)):
            switch (x, y) {
            case (.bullet, .bullet), (.numbered, .numbered), (.task, .task), (.toggle, .toggle): true
            default: false
            }
        default: a == b
        }
    }

    static let marks: [(id: String, symbol: String, title: String, mark: Mark)] = [
        ("bold", "bold", String(localized: "Bold"), .bold),
        ("italic", "italic", String(localized: "Italic"), .italic),
        ("strike", "strikethrough", String(localized: "Strikethrough"), .strike),
        ("code", "chevron.left.forwardslash.chevron.right", String(localized: "Code"), .code),
    ]

    /// The text styles, Craft's: titles, then content; each its ⌃ key.
    static let styles: [(key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind)] = [
        ("1", String(localized: "Title"), 15, .bold, .heading(level: 1)),
        ("2", String(localized: "Subtitle"), 15, .bold, .heading(level: 2)),
        ("3", String(localized: "Heading"), 15, .semibold, .heading(level: 3)),
        ("4", String(localized: "Strong"), 15, .semibold, .heading(level: 4)),
        ("5", String(localized: "Body"), 15, .regular, .paragraph),
        ("6", String(localized: "Caption"), 13.5, .regular, .caption),
    ]

    static let lists: [(id: String, symbol: String, title: String, kind: BlockKind)] = [
        ("task", "checkmark.square", String(localized: "To-do"), .listItem(style: .task(done: false))),
        ("toggle", "arrowtriangle.right.fill", String(localized: "Toggle List"), .listItem(style: .toggle(open: true))),
        ("bullet", "list.bullet", String(localized: "Bulleted List"), .listItem(style: .bullet)),
        ("numbered", "list.number", String(localized: "Numbered List"), .listItem(style: .numbered)),
    ]
}
