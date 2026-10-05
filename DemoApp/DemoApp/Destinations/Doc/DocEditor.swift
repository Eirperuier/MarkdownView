//
//  DocEditor.swift
//  DemoApp
//
//  Editing in the reading view (doc.md §6.2). Three rules keep it predictable:
//
//  1. The model is the only truth. Keystrokes don't edit the text storage; they become
//     DocKit steps, and the block re-renders from the model (in the editing markdown
//     style, which shows the model's text exactly — edge spaces, empty blocks).
//  2. The editor's selection, in model coordinates, is the only truth for the cursor.
//     A keystroke that arrives before the last one has rendered edits at that
//     selection, not at the stale storage's. Each render puts the cursor back from it,
//     synchronously, before the frame is drawn.
//  3. A text view is "in sync" when its storage is the block's marker followed by the
//     model's text. Offsets convert by that prefix; nothing is trusted out of sync.
//
//  IME composition is the one native edit: it runs in the storage and commits as one
//  step when the marked text is gone.
//

import SwiftUI
import UIKit
import ObjectiveC
import DocKit
import MarkdownView

@MainActor
final class DocEditor {
    let demo: DocDemo
    /// One undo manager for the whole document: every text view answers ⌘Z, shake
    /// and the three-finger swipe with it, and its actions run the DocKit history (§7).
    let undoManager = UndoManager()

    private var hooks: [DocBlockID: MarkdownSelectableTextHooks] = [:]
    /// Text views per block: the one on screen, and any TiledView renders off screen to
    /// measure a row. Only the one in the key window is edited.
    private var views: [DocBlockID: [WeakTextView]] = [:]
    private var delegates: [ObjectIdentifier: DocTextDelegate] = [:]
    /// The storage each text view showed after its last render.
    private var rendered: [ObjectIdentifier: String] = [:]
    /// Where the cursor is, in the model.
    private(set) var selection: DocSelection?
    /// The next render of the selection's block should also take keyboard focus.
    private var wantsFocus = false
    private var placingSelection = false
    /// Typing session for undo merging: moving the cursor starts a new one.
    private var session: UInt64 = 0

    var isEditable = true {
        didSet {
            for view in allViews {
                view.isEditable = isEditable
                if !isEditable { view.resignFirstResponder() }
            }
        }
    }

    init(demo: DocDemo) {
        self.demo = demo
        undoManager.groupsByEvent = true
    }

    private var allViews: [UITextView] { views.values.flatMap { $0 }.compactMap(\.view) }

    /// One hooks object per block, reused so the environment stays equal.
    func hooks(for id: DocBlockID) -> MarkdownSelectableTextHooks {
        if let existing = hooks[id] { return existing }
        let made = MarkdownSelectableTextHooks(
            onTextViewReady: { [weak self] in self?.attach($0, to: id) },
            onSelectionChanged: { [weak self] in self?.selectionChanged($0, in: id) },
            editMenu: { [weak self] textView, range, suggested in
                self?.editMenu(textView, range: range, suggested: suggested, in: id)
            },
            onContentChanged: { [weak self] in self?.contentChanged($0, in: id) }
        )
        hooks[id] = made
        return made
    }

    // MARK: Text views

    private func attach(_ textView: UITextView, to id: DocBlockID) {
        // Text views come from a pool: forget whatever block this one showed before.
        views = views.mapValues { $0.filter { $0.view != nil && $0.view !== textView } }
        views[id, default: []].append(WeakTextView(view: textView))
        textView.isEditable = isEditable
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        let original = (textView.delegate as? DocTextDelegate)?.original ?? textView.delegate
        let delegate = DocTextDelegate(original: original, block: id, editor: self)
        delegates[ObjectIdentifier(textView)] = delegate
        textView.delegate = delegate
        TextViewHooks.install(on: type(of: textView))
    }

    /// The block's text view in the key window, not a measuring copy. A row deleted and
    /// inserted again (undo, redo) can leave the old cell on screen for a moment: the
    /// newest view wins.
    func textView(for id: DocBlockID) -> UITextView? {
        views[id]?.compactMap(\.view).last { $0.window?.isKeyWindow == true }
    }

    /// The storage offset where the block's text starts, when the storage shows the
    /// model (marker + text); nil otherwise. An empty block shows a zero-width space
    /// there, so its line keeps its height; the cursor sits before it.
    func textStart(in textView: UITextView, block: DocBlock) -> Int? {
        let storage = textView.text ?? ""
        let shown = block.text.isEmpty ? "\u{200B}" : block.text.string
        guard storage.hasSuffix(shown) else { return nil }
        let prefix = storage.utf16.count - shown.utf16.count
        return prefix <= 8 ? prefix : nil
    }

    private func modelOffset(_ storage: Int, start: Int, block: DocBlock) -> Int {
        min(max(0, storage - start), block.text.length)
    }

    private func contentChanged(_ textView: UITextView, in id: DocBlockID) {
        rendered[ObjectIdentifier(textView)] = textView.text ?? ""
        guard let selection, selection.head.block == id, textView.window?.isKeyWindow == true else { return }
        apply(selection, to: textView)
    }

    /// The person moved the cursor or selected: that's the new selection. Changes UIKit
    /// makes while a render replaces the storage are not the person's and are ignored
    /// (the render puts the selection back right after).
    private func selectionChanged(_ textView: UITextView, in id: DocBlockID) {
        guard !placingSelection, textView.window?.isKeyWindow == true,
            rendered[ObjectIdentifier(textView)] == textView.text,
            let block = demo.doc.block(id), let start = textStart(in: textView, block: block)
        else { return }
        let range = textView.selectedRange
        let next = DocSelection(
            anchor: .init(block: id, offset: modelOffset(range.location, start: start, block: block)),
            head: .init(block: id, offset: modelOffset(NSMaxRange(range), start: start, block: block))
        )
        if next != selection {
            selection = next
            session &+= 1
        }
    }

    /// Shows a model selection in a text view that is in sync; a no-op otherwise.
    private func apply(_ selection: DocSelection, to textView: UITextView) {
        guard let block = demo.doc.block(selection.head.block), let start = textStart(in: textView, block: block) else { return }
        let lower = min(selection.anchor.offset, selection.head.offset)
        let upper = max(selection.anchor.offset, selection.head.offset)
        let target = NSRange(location: start + min(lower, block.text.length), length: min(upper, block.text.length) - min(lower, block.text.length))
        placingSelection = true
        defer { placingSelection = false }
        if wantsFocus, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
        wantsFocus = false
        if textView.selectedRange != target { textView.selectedRange = target }
    }

    /// Moves the selection (and focus) to a model position, now if its block is shown
    /// in sync, else at its next render.
    func place(_ next: DocSelection) {
        selection = next
        wantsFocus = true
        if let textView = textView(for: next.head.block) { apply(next, to: textView) }
        settlePlacement()
    }

    private var placementTask: Task<Void, Never>?

    /// A new row's text view renders before it is in the window, and becoming first
    /// responder can move the cursor afterwards; for a few frames after a placement, the
    /// selection is re-applied until the screen shows it.
    private func settlePlacement() {
        placementTask?.cancel()
        placementTask = Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled, let selection = self.selection else { return }
                if self.mismatch() == nil { return }
                if let textView = self.textView(for: selection.head.block) { self.apply(selection, to: textView) }
            }
        }
    }

    func place(_ position: DocPosition) {
        place(DocSelection(anchor: position, head: position))
    }

    /// Whether everything shown matches the model: the selection's block in sync, its
    /// cursor where the model says. For the edit tests.
    func mismatch() -> String? {
        guard let selection else { return nil }
        guard let block = demo.doc.block(selection.head.block) else { return "selection in a missing block" }
        guard let textView = textView(for: block.id) else { return "block not on screen" }
        guard let start = textStart(in: textView, block: block) else {
            return "storage \((textView.text ?? "").debugDescription) is not the model \(block.text.string.debugDescription)"
        }
        let lower = min(selection.anchor.offset, selection.head.offset)
        let upper = max(selection.anchor.offset, selection.head.offset)
        let expected = NSRange(location: start + lower, length: upper - lower)
        // In an empty block either side of the zero-width space is the same place.
        let alsoFine = block.text.isEmpty && textView.selectedRange == NSRange(location: start + 1, length: 0)
        if textView.selectedRange != expected, !alsoFine { return "cursor \(textView.selectedRange) expected \(expected)" }
        if !textView.isFirstResponder { return "not focused" }
        return nil
    }

    // MARK: Input

    /// The model range a proposed change covers: from the storage when the view is in
    /// sync, from the editor's selection when a render is still pending.
    private func modelRange(_ range: NSRange, deleting: Bool, in textView: UITextView, block: DocBlock) -> Range<Int>? {
        if rendered[ObjectIdentifier(textView)] == textView.text, let start = textStart(in: textView, block: block) {
            let lower = modelOffset(range.location, start: start, block: block)
            let upper = modelOffset(NSMaxRange(range), start: start, block: block)
            return lower..<max(lower, upper)
        }
        guard let selection, selection.head.block == block.id else { return nil }
        let lower = min(selection.anchor.offset, selection.head.offset)
        let upper = max(selection.anchor.offset, selection.head.offset)
        if deleting, lower == upper {
            return previousCharacter(before: lower, in: block.text)..<lower
        }
        return lower..<upper
    }

    private func previousCharacter(before offset: Int, in text: DocText) -> Int {
        guard offset > 0 else { return 0 }
        let string = text.string
        let index = String.Index(utf16Offset: offset, in: string)
        return string.index(before: index).utf16Offset(in: string)
    }

    /// A change UIKit proposes; always handled here, never applied by UIKit.
    func replace(_ range: NSRange, with replacement: String, in textView: UITextView, block id: DocBlockID) {
        // Keys typed right after Return (or an undo) still arrive at the old block's
        // text view, before the new one has rendered and taken focus: they belong where
        // the selection already is.
        if let moved = movedSelection(from: id) {
            redirect(replacement, to: moved)
            return
        }
        guard let block = demo.doc.block(id), block.kind.carriesText,
            let modelRange = modelRange(range, deleting: replacement.isEmpty, in: textView, block: block)
        else { return }
        if replacement == "\t" {
            indent(block, by: 1)
            return
        }
        // Deleting with nothing of the text in range (the cursor at the start, or over a
        // list marker) is a backspace at the start of the block.
        if replacement.isEmpty, modelRange.isEmpty {
            if modelRange.lowerBound == 0 { _ = deleteBackward(atStartOf: block) }
            return
        }
        insert(replacement, replacing: modelRange, in: block)
    }

    /// Shift-Tab, ⌘B, ⌘I from the text view's key commands.
    func keyCommand(_ command: DocKeyCommand, in id: DocBlockID) {
        guard isEditable, let block = movedSelection(from: id) ?? demo.doc.block(id) else { return }
        switch command {
        case .outdent:
            indent(block, by: -1)
        case .bold, .italic:
            guard let selection, selection.head.block == block.id else { return }
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            guard !range.isEmpty else { return }
            toggle(command == .bold ? .bold : .italic, over: range, in: block.id)
        }
    }

    /// The selection's block, when it isn't the block of the text view a key came from.
    private func movedSelection(from id: DocBlockID) -> DocBlock? {
        guard let selection, selection.head.block != id, let block = demo.doc.block(selection.head.block),
            block.kind.carriesText
        else { return nil }
        return block
    }

    private func redirect(_ replacement: String, to block: DocBlock) {
        guard let selection else { return }
        let lower = min(selection.anchor.offset, selection.head.offset)
        let upper = max(selection.anchor.offset, selection.head.offset)
        if replacement.isEmpty, lower == upper {
            if lower == 0 { _ = deleteBackward(atStartOf: block) } else {
                insert("", replacing: previousCharacter(before: lower, in: block.text)..<lower, in: block)
            }
            return
        }
        if replacement == "\t" {
            indent(block, by: 1)
            return
        }
        insert(replacement, replacing: lower..<upper, in: block)
    }

    /// Backspace with the cursor at the very start, which UIKit doesn't send to the
    /// delegate. False hands it back to UIKit.
    func deleteBackward(in textView: UITextView, block id: DocBlockID) -> Bool {
        if let moved = movedSelection(from: id) {
            redirect("", to: moved)
            return true
        }
        guard let block = demo.doc.block(id), let range = modelRange(textView.selectedRange, deleting: false, in: textView, block: block),
            range.isEmpty, range.lowerBound == 0
        else { return false }
        return deleteBackward(atStartOf: block)
    }

    /// The marked text is gone: whatever the IME left in the storage is one insertion.
    func commitComposition(in textView: UITextView, block id: DocBlockID) {
        undoManager.enableUndoRegistration()
        guard let block = demo.doc.block(id), let old = rendered[ObjectIdentifier(textView)],
            let start = Self.textStart(of: old, block: block)
        else { return }
        let before = Array(old.utf16)
        let after = Array((textView.text ?? "").utf16)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let inserted = String(decoding: after[prefix..<(after.count - suffix)], as: UTF16.self)
        let lower = modelOffset(prefix, start: start, block: block)
        let upper = modelOffset(before.count - suffix, start: start, block: block)
        // The storage now differs from the model until the commit renders.
        insert(inserted.replacing("\u{200B}", with: ""), replacing: lower..<max(lower, upper), in: block)
    }

    private static func textStart(of storage: String, block: DocBlock) -> Int? {
        let shown = block.text.isEmpty ? "\u{200B}" : block.text.string
        guard storage.hasSuffix(shown) else { return nil }
        return storage.utf16.count - shown.utf16.count
    }

    func compositionBegan() {
        // UIKit's own typing undo would edit the storage behind the model's back.
        undoManager.disableUndoRegistration()
    }

    /// Text typed or pasted over `range`. Line breaks split the block; markdown
    /// shortcuts at the start of a block or around a word become their formatting.
    private func insert(_ string: String, replacing range: Range<Int>, in block: DocBlock) {
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if string == "\n", block.text.isEmpty, leaveEmptyBlock(block) { return }
        var steps: [DocStep] = []
        if !range.isEmpty { steps.append(.deleteText(block: block.id, range: range, removed: DocText())) }
        let marks = block.kind.allowsMarks ? block.text.marksForInsertion(at: range.lowerBound) : []
        var current = block.id
        var offset = range.lowerBound
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let next = demo.newBlockID()
                steps.append(.splitBlock(block: current, at: offset, newID: next, newKind: Self.kindAfterSplit(block.kind), newIndent: block.indent))
                current = next
                offset = 0
            }
            guard !line.isEmpty else { continue }
            let length = line.utf16.count
            steps.append(.insertText(block: current, at: offset, text: DocText(string: line, marks: marks.map { MarkSpan(range: 0..<length, mark: $0) })))
            offset += length
        }
        var caret = DocPosition(block: current, offset: offset)
        if lines.count == 1, let shortcut = shortcut(after: steps, in: block, caret: offset) {
            steps += shortcut.steps
            caret = shortcut.caret
        }
        // Typing merges into one undo step until the cursor moves; a space or a line
        // break ends the step.
        let typing = lines.count == 1 && !string.isEmpty && !string.contains(" ")
        commit(steps, from: DocSelection(anchor: .init(block: block.id, offset: range.lowerBound), head: .init(block: block.id, offset: range.upperBound)),
               to: DocSelection(anchor: caret, head: caret), merge: typing ? .init(block: block.id, session: session) : nil)
        if !typing { session &+= 1 }
    }

    /// Return in an empty list item or quote leaves it: out one level, then to a paragraph.
    private func leaveEmptyBlock(_ block: DocBlock) -> Bool {
        switch block.kind {
        case .listItem where block.indent > 0:
            indent(block, by: -1)
        case .listItem, .quote:
            setKind(block, kind: .paragraph, indent: 0)
        default:
            return false
        }
        return true
    }

    private static func kindAfterSplit(_ kind: BlockKind) -> BlockKind {
        switch kind {
        case .listItem(.task): .listItem(style: .task(done: false))
        case .listItem(.toggle): .listItem(style: .toggle(open: true))
        case .listItem, .quote: kind
        default: .paragraph
        }
    }

    /// Backspace with the cursor at the start of a block: a list item steps out a
    /// level, then becomes a paragraph; a heading or quote becomes a paragraph; a
    /// paragraph joins the block before it (or deletes a divider or image there).
    private func deleteBackward(atStartOf block: DocBlock) -> Bool {
        let id = block.id
        switch block.kind {
        case .listItem where block.indent > 0:
            indent(block, by: -1)
        case .listItem, .heading, .quote:
            setKind(block, kind: .paragraph, indent: 0)
        default:
            guard let index = demo.doc.blocks.firstIndex(where: { $0.id == id }), index > 0 else { return true }
            let previous = demo.doc.blocks[index - 1]
            let here = DocSelection(anchor: .init(block: id, offset: 0), head: .init(block: id, offset: 0))
            if previous.kind.carriesText {
                guard previous.kind.allowsMarks || block.text.marks.isEmpty else { return true }
                let joined = DocPosition(block: previous.id, offset: previous.text.length)
                commit([.joinBlock(block: id, into: previous.id, at: 0, kind: block.kind, indent: block.indent)],
                       from: here, to: DocSelection(anchor: joined, head: joined))
            } else {
                commit([.deleteBlock(block: previous, after: nil)], from: here, to: here)
            }
        }
        return true
    }

    /// Tab nests a list item under the one before it (one level at most).
    private func indent(_ block: DocBlock, by delta: Int) {
        guard case .listItem = block.kind, let index = demo.doc.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let ceiling: Int = if index > 0, case .listItem = demo.doc.blocks[index - 1].kind { demo.doc.blocks[index - 1].indent + 1 } else { 0 }
        let indent = min(max(0, block.indent + delta), ceiling)
        guard indent != block.indent else { return }
        setKind(block, kind: block.kind, indent: indent)
    }

    /// Changes a block's kind or indent; the cursor stays where it is in the text.
    private func setKind(_ block: DocBlock, kind: BlockKind, indent: Int) {
        let start = DocPosition(block: block.id, offset: 0)
        let here = selection.flatMap { $0.head.block == block.id ? $0 : nil } ?? DocSelection(anchor: start, head: start)
        commit([.setBlock(block: block.id, kind: kind, indent: indent, previousKind: block.kind, previousIndent: block.indent)],
               from: here, to: here)
    }

    private func commit(_ steps: [DocStep], from before: DocSelection, to after: DocSelection, merge: DocHistory.MergeKey? = nil) {
        let depth = demo.undoDepth
        guard demo.edit(steps, before: before, after: after, merge: merge) != nil else { return }
        // One undo action per history entry; typing merged into the last entry adds none.
        if demo.undoDepth > depth {
            undoManager.registerUndo(withTarget: self) { $0.undoAction() }
        }
        place(after)
    }

    // MARK: Formatting

    /// The selection's edit menu, with the inline marks added (Composer had them).
    private func editMenu(_ textView: UITextView, range: NSRange, suggested: [UIMenuElement], in id: DocBlockID) -> UIMenu? {
        guard isEditable, range.length > 0, let block = demo.doc.block(id), block.kind.allowsMarks,
            let start = textStart(in: textView, block: block)
        else { return nil }
        let modelRange = modelOffset(range.location, start: start, block: block)..<modelOffset(NSMaxRange(range), start: start, block: block)
        guard !modelRange.isEmpty else { return nil }
        let items: [(String, String, Mark)] = [
            ("加粗", "bold", .bold), ("斜体", "italic", .italic), ("删除线", "strikethrough", .strike),
            ("代码", "chevron.left.forwardslash.chevron.right", .code), ("高亮", "highlighter", .highlight(color: nil)),
        ]
        let actions = items.map { (title, image, mark) in
            let on = Self.covers(block.text, modelRange, with: mark.kind)
            return UIAction(title: title, image: UIImage(systemName: image), state: on ? .on : .off) { [weak self] _ in
                self?.toggle(mark, over: modelRange, in: id)
            }
        }
        let format = UIMenu(title: "格式", image: UIImage(systemName: "textformat"), children: actions)
        return UIMenu(children: [format] + suggested)
    }

    private static func covers(_ text: DocText, _ range: Range<Int>, with kind: MarkKind) -> Bool {
        let spans = text.marks.filter { $0.mark.kind == kind }
        return range.allSatisfy { offset in spans.contains { $0.range.contains(offset) } }
    }

    /// Marks the range, or clears the mark when all of it already has one.
    func toggle(_ mark: Mark, over range: Range<Int>, in id: DocBlockID) {
        guard let block = demo.doc.block(id), block.kind.allowsMarks else { return }
        let on = !Self.covers(block.text, range, with: mark.kind)
        let selected = DocSelection(anchor: .init(block: id, offset: range.lowerBound), head: .init(block: id, offset: range.upperBound))
        commit([.setMarks(block: id, range: range, kind: mark.kind, spans: on ? [MarkSpan(range: range, mark: mark)] : [], previous: [])],
               from: selected, to: selected)
    }

    // MARK: Shortcuts

    /// `# `, `- `, `1. `, `[] `, `> ` at the start of a paragraph change its kind;
    /// ```` ``` ```` makes it code and `---` a divider; `**x**` and `` `x` `` around
    /// a word become bold and code (§6.2). Each is part of the keystroke's transaction,
    /// so one undo takes it back.
    private func shortcut(after steps: [DocStep], in block: DocBlock, caret: Int) -> (steps: [DocStep], caret: DocPosition)? {
        var scratch = demo.doc
        guard (try? scratch.apply(DocTransaction(steps: steps, author: demo.person, time: .now))) != nil,
            let edited = scratch.block(block.id)
        else { return nil }
        let text = edited.text.string
        let typed = String(text.utf16.prefix(caret)) ?? ""
        let start = DocPosition(block: block.id, offset: 0)
        func becomes(_ kind: BlockKind, removing count: Int) -> (steps: [DocStep], caret: DocPosition) {
            ([.deleteText(block: block.id, range: 0..<count, removed: DocText()),
              .setBlock(block: block.id, kind: kind, indent: block.indent, previousKind: block.kind, previousIndent: block.indent)], start)
        }
        if block.kind == .paragraph, typed.hasSuffix(" "), let kind = Self.prefixKind(String(typed.dropLast())) {
            return becomes(kind, removing: typed.utf16.count)
        }
        if block.kind == .paragraph, text == "```" { return becomes(.code(language: nil), removing: 3) }
        if block.kind == .paragraph, text == "---" {
            let next = demo.newBlockID()
            var result = becomes(.divider, removing: 3)
            result.steps.append(.insertBlock(block: DocBlock(id: next, kind: .paragraph), after: block.id))
            result.caret = DocPosition(block: next, offset: 0)
            return result
        }
        if block.kind.allowsMarks {
            for (delimiter, mark) in [("**", Mark.bold), ("`", .code)] {
                if let wrap = Self.wrapped(typed, delimiter: delimiter) {
                    let width = delimiter.utf16.count
                    let inner = (wrap.lowerBound - width)..<(wrap.upperBound - width)
                    return ([.deleteText(block: block.id, range: wrap.upperBound..<(wrap.upperBound + width), removed: DocText()),
                             .deleteText(block: block.id, range: (wrap.lowerBound - width)..<wrap.lowerBound, removed: DocText()),
                             .setMarks(block: block.id, range: inner, kind: mark.kind, spans: [MarkSpan(range: inner, mark: mark)], previous: [])],
                            DocPosition(block: block.id, offset: inner.upperBound))
                }
            }
        }
        return nil
    }

    private static func prefixKind(_ prefix: String) -> BlockKind? {
        switch prefix {
        case "#", "##", "###", "####", "#####", "######": .heading(level: prefix.count)
        case "-", "*", "+": .listItem(style: .bullet)
        case "[]", "[ ]": .listItem(style: .task(done: false))
        case "[x]": .listItem(style: .task(done: true))
        case ">": .quote
        default: prefix.dropLast().allSatisfy(\.isNumber) && prefix.count > 1 && (prefix.last == "." || prefix.last == ")")
            ? .listItem(style: .numbered) : nil
        }
    }

    /// The UTF-16 range of `x` when `text` ends with `<d>x<d>` (x non-empty, not
    /// padded with spaces, without the delimiter).
    private static func wrapped(_ text: String, delimiter: String) -> Range<Int>? {
        guard text.hasSuffix(delimiter), let mark = delimiter.first else { return nil }
        let body = text.dropLast(delimiter.count)
        guard let open = body.range(of: delimiter, options: .backwards) else { return nil }
        let inner = body[open.upperBound...]
        guard !inner.isEmpty, inner.first != " ", inner.last != " ", !inner.contains(mark) else { return nil }
        let lower = text.utf16.distance(from: text.startIndex, to: open.upperBound)
        return lower..<(lower + inner.utf16.count)
    }

    // MARK: Undo

    func requestUndo() {
        if undoManager.canUndo { undoManager.undo() }
    }

    func requestRedo() {
        if undoManager.canRedo { undoManager.redo() }
    }

    func resetHistory() {
        undoManager.removeAllActions()
        selection = nil
    }

    /// Registering the opposite action while undoing is what puts it on the redo stack.
    private func undoAction() {
        undoManager.registerUndo(withTarget: self) { $0.redoAction() }
        if let selection = demo.undo() { place(selection) }
    }

    private func redoAction() {
        undoManager.registerUndo(withTarget: self) { $0.undoAction() }
        if let selection = demo.redo() { place(selection) }
    }
}

enum DocKeyCommand {
    case outdent, bold, italic
}

struct WeakTextView {
    weak var view: UITextView?
}

/// Stands in front of RichText's own delegate: takes the edits, forwards the rest.
@MainActor
final class DocTextDelegate: NSObject, UITextViewDelegate {
    nonisolated(unsafe) weak var original: (any UITextViewDelegate)?
    let block: DocBlockID
    weak var editor: DocEditor?
    private var composing = false

    init(original: (any UITextViewDelegate)?, block: DocBlockID, editor: DocEditor) {
        self.original = original
        self.block = block
        self.editor = editor
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let editor, editor.isEditable else { return false }
        // IME: composition runs natively, committed as one step when it ends.
        if textView.markedTextRange != nil || Self.startsComposition(text, in: textView) {
            if !composing { editor.compositionBegan() }
            composing = true
            return true
        }
        editor.replace(range, with: text, in: textView, block: block)
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        guard composing, textView.markedTextRange == nil else { return }
        composing = false
        editor?.commitComposition(in: textView, block: block)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        original?.textViewDidChangeSelection?(textView)
    }

    /// Letters typed with a Chinese, Japanese or Korean keyboard start marked text.
    private static func startsComposition(_ text: String, in textView: UITextView) -> Bool {
        guard let language = textView.textInputMode?.primaryLanguage,
            ["zh", "ja", "ko"].contains(where: language.hasPrefix)
        else { return false }
        return !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isLetter }
    }
}

/// Two things the text view class can't be asked through its delegate, added to the
/// class: backspace with the cursor at the very start (UIKit doesn't consult the
/// delegate), and which undo manager it answers ⌘Z with. (The real version belongs in
/// RichText's text view; this is the prototype hook.)
@MainActor
private enum TextViewHooks {
    private static var installed: Set<ObjectIdentifier> = []

    static func install(on type: AnyClass) {
        guard installed.insert(ObjectIdentifier(type)).inserted else { return }
        installDeleteBackward(on: type)
        installUndoManager(on: type)
        installKeyCommands(on: type)
    }

    /// Shift-Tab steps a list item out, ⌘B and ⌘I toggle bold and italic (Composer had
    /// them; UIKit's own versions would edit the storage, not the model).
    private static let commands: [(input: String, flags: UIKeyModifierFlags, selector: Selector, command: DocKeyCommand, title: String)] = [
        ("\t", .shift, Selector(("docOutdent:")), .outdent, "减少缩进"),
        ("b", .command, Selector(("docBold:")), .bold, "加粗"),
        ("i", .command, Selector(("docItalic:")), .italic, "斜体"),
    ]

    private static func installKeyCommands(on type: AnyClass) {
        for entry in commands {
            let action: @convention(block) (AnyObject, AnyObject?) -> Void = { object, _ in
                MainActor.assumeIsolated {
                    guard let (_, delegate, editor) = editor(of: object) else { return }
                    editor.keyCommand(entry.command, in: delegate.block)
                }
            }
            class_addMethod(type, entry.selector, imp_implementationWithBlock(action), "v@:@")
        }
        let selector = #selector(getter: UIResponder.keyCommands)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        typealias Implementation = @convention(c) (AnyObject, Selector) -> [UIKeyCommand]?
        let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        let replacement: @convention(block) (AnyObject) -> [UIKeyCommand]? = { object in
            let ours = MainActor.assumeIsolated { () -> [UIKeyCommand] in
                guard editor(of: object) != nil else { return [] }
                return commands.map { entry in
                    let command = UIKeyCommand(title: entry.title, action: entry.selector, input: entry.input, modifierFlags: entry.flags)
                    command.wantsPriorityOverSystemBehavior = true
                    return command
                }
            }
            return (original(object, selector) ?? []) + ours
        }
        override(type, selector, with: imp_implementationWithBlock(replacement), types: method_getTypeEncoding(method))
    }

    private static func editor(of object: AnyObject) -> (UITextView, DocTextDelegate, DocEditor)? {
        guard let textView = object as? UITextView, let delegate = textView.delegate as? DocTextDelegate,
            let editor = delegate.editor
        else { return nil }
        return (textView, delegate, editor)
    }

    private static func installDeleteBackward(on type: AnyClass) {
        let selector = #selector(UITextView.deleteBackward)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        typealias Implementation = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        let replacement: @convention(block) (AnyObject) -> Void = { object in
            let handled = MainActor.assumeIsolated {
                guard let (textView, delegate, editor) = editor(of: object), editor.isEditable else { return false }
                return editor.deleteBackward(in: textView, block: delegate.block)
            }
            if !handled { original(object, selector) }
        }
        override(type, selector, with: imp_implementationWithBlock(replacement), types: method_getTypeEncoding(method))
    }

    private static func installUndoManager(on type: AnyClass) {
        let selector = #selector(getter: UIResponder.undoManager)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        typealias Implementation = @convention(c) (AnyObject, Selector) -> UndoManager?
        let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        let replacement: @convention(block) (AnyObject) -> UndoManager? = { object in
            let manager = MainActor.assumeIsolated { editor(of: object)?.2.undoManager }
            return manager ?? original(object, selector)
        }
        override(type, selector, with: imp_implementationWithBlock(replacement), types: method_getTypeEncoding(method))
    }

    private static func override(_ type: AnyClass, _ selector: Selector, with implementation: IMP, types: UnsafePointer<CChar>?) {
        if !class_addMethod(type, selector, implementation, types), let method = class_getInstanceMethod(type, selector) {
            method_setImplementation(method, implementation)
        }
    }
}
