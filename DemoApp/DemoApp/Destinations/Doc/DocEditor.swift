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
    /// and the three-finger swipe with it, and it is the DocKit history (§7).
    let undoManager = DocUndoManager()

    private var hooks: [DocBlockID: MarkdownSelectableTextHooks] = [:]
    /// Text views per block: the one on screen, and any TiledView renders off screen to
    /// measure a row. Only the one in the key window is edited.
    private var views: [DocBlockID: [WeakTextView]] = [:]
    private var delegates: [ObjectIdentifier: DocTextDelegate] = [:]
    /// The storage each text view showed after its last render.
    private var rendered: [ObjectIdentifier: String] = [:]
    /// Where the cursor is, in the model.
    private(set) var selection: DocSelection? {
        didSet {
            guard selection != oldValue else { return }
            updateSlash()
            keyboardBar.update()
            cursor.selection = selection
        }
    }
    /// The selection, observable (the Mac's format panel follows it).
    let cursor = DocCursor()
    /// The slash menu, and where its "/" is while it's open.
    let slash = DocSlashMenu()
    /// The tables' cells (database blocks).
    lazy var tables = DocTableController(demo: demo, editor: self)
    /// Code and math blocks, edited as their source.
    lazy var sources = DocSourceController(demo: demo, editor: self)
    /// The bar over a phone's keyboard: marks, block kinds, inserting (Craft's).
    lazy var keyboardBar = DocKeyboardBar(editor: self)
    /// Blocks as wholes: the handle, selecting blocks, moving them.
    lazy var blocks = DocBlockController(demo: demo, editor: self)
    var slashOrigin: DocPosition?
    /// The next render of the selection's block should also take keyboard focus.
    private var wantsFocus = false
    /// The text view last focused for typing. If it leaves the window while focused
    /// (its row reloaded into a new cell), the block's new view takes the focus.
    private weak var focusedView: UITextView?
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
        undoManager.editor = self
        DocScrolling.trackKeyboard()
        slash.choose = { [weak self] item in self?.chooseSlash(item) }
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
        #if !targetEnvironment(macCatalyst)
        textView.inputAccessoryView = keyboardBar
        #endif
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
    /// model (marker + text); nil otherwise. An empty block, or an empty last line,
    /// shows a zero-width space so the line keeps its height.
    func textStart(in textView: UITextView, block: DocBlock) -> Int? {
        guard let start = Self.textStart(of: textView.text ?? "", block: block) else { return nil }
        return start <= 8 ? start : nil
    }

    /// What the storage shows of a block's text, after its marker.
    static func shown(_ block: DocBlock) -> String {
        let text = block.text.string
        return text.isEmpty || text.hasSuffix("\n") ? text + "\u{200B}" : text
    }

    private func modelOffset(_ storage: Int, start: Int, block: DocBlock) -> Int {
        min(max(0, storage - start), block.text.length)
    }

    private func contentChanged(_ textView: UITextView, in id: DocBlockID) {
        rendered[ObjectIdentifier(textView)] = textView.text ?? ""
        guard let selection, selection.head.block == id, textView.window?.isKeyWindow == true else { return }
        if let focusedView, focusedView !== textView, focusedView.window == nil { wantsFocus = true }
        apply(selection, to: textView)
        if slashOrigin?.block == id { updateSlash() }
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
        // A click in an empty block can land before its zero-width space, where the caret
        // draws at the line start (before a list marker): it belongs after it.
        if block.text.isEmpty, range.length == 0, range.location <= start {
            placingSelection = true
            textView.selectedRange = NSRange(location: start + 1, length: 0)
            placingSelection = false
        }
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
        // An empty block shows a zero-width space; TextKit draws a caret before it at the
        // start of the line (before a list marker), so the caret goes after it.
        let shift = block.text.isEmpty ? 1 : 0
        let target = NSRange(location: start + shift + min(lower, block.text.length), length: min(upper, block.text.length) - min(lower, block.text.length))
        placingSelection = true
        defer { placingSelection = false }
        if wantsFocus, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
        if textView.isFirstResponder { focusedView = textView }
        wantsFocus = false
        if textView.selectedRange != target { textView.selectedRange = target }
    }

    /// A click in a block's row outside its text view: the caret goes to the nearest
    /// place in the text, as a click beside a line does in a text editor. Clicks on the
    /// text view itself are the text view's.
    func click(_ id: DocBlockID, at point: CGPoint) {
        // A link opens (not while blocks are being selected: a click picks it then).
        if case .link(let link)? = demo.doc.block(id)?.kind {
            if !blocks.isSelecting, let url = URL(string: link.url) { UIApplication.shared.open(url) }
            return
        }
        guard isEditable, let block = demo.doc.block(id), block.kind.carriesText,
            let textView = textView(for: id), let start = textStart(in: textView, block: block)
        else { return }
        let local = textView.convert(point, from: nil)
        guard !textView.bounds.contains(local), let position = textView.closestPosition(to: local) else { return }
        let offset = modelOffset(textView.offset(from: textView.beginningOfDocument, to: position), start: start, block: block)
        let caret = DocPosition(block: id, offset: offset)
        session &+= 1
        place(DocSelection(anchor: caret, head: caret))
    }

    /// Moves the selection (and focus) to a model position, now if its block is shown
    /// in sync, else at its next render.
    func place(_ next: DocSelection) {
        // Code and math blocks have their own editor.
        if let block = demo.doc.block(next.head.block), DocSourceKind(block.kind) != nil {
            selection = nil
            sources.focus(block.id, at: next.head.offset)
            return
        }
        selection = next
        wantsFocus = true
        if let textView = textView(for: next.head.block) {
            apply(next, to: textView)
            reveal(textView, block: next.head.block)
        } else {
            // The row isn't on screen (Return on the last visible line, an undo far
            // away): scroll to it; it renders, and the placement below catches it.
            demo.bringIntoView(next.head.block)
        }
        settlePlacement()
    }

    /// Scrolls when the cursor's line is outside the visible part of the page.
    /// Shows the caret's line: on screen, above the keyboard.
    private func reveal(_ textView: UITextView, block: DocBlockID) {
        let caret = textView.selectedTextRange.map { textView.caretRect(for: $0.end) } ?? textView.bounds
        DocScrolling.reveal(textView, rect: caret)
        Task { @MainActor [weak textView] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let textView, textView.isFirstResponder else { return }
            DocScrolling.reveal(textView, rect: textView.selectedTextRange.map { textView.caretRect(for: $0.end) } ?? textView.bounds)
        }
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
                guard let problem = self.mismatch() else { return }
                // The placement wants the focus: a row reloaded under it can take it away.
                if problem == "not focused" { self.wantsFocus = true }
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
        // An empty block's caret goes after its zero-width space (see `apply`).
        let shown = block.text.isEmpty ? NSRange(location: start + 1, length: 0) : expected
        if textView.selectedRange != shown { return "cursor \(textView.selectedRange) expected \(shown)" }
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
        // A web address pasted over selected text links it (the text stays).
        if !modelRange.isEmpty, block.kind.allowsMarks, let url = Self.webAddress(replacement) {
            setLink(url, over: modelRange, in: id)
            return
        }
        insert(replacement, replacing: modelRange, in: block)
    }

    /// `text` as a web address (http, https or mailto, nothing around it).
    static func webAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
              scheme == "mailto" || url.host != nil
        else { return nil }
        return trimmed
    }

    // MARK: Links

    /// Links the range to `url`; nil removes the links in it.
    func setLink(_ url: String?, over range: Range<Int>, in id: DocBlockID) {
        guard let block = demo.doc.block(id), block.kind.allowsMarks, !range.isEmpty else { return }
        let selected = DocSelection(anchor: .init(block: id, offset: range.lowerBound), head: .init(block: id, offset: range.upperBound))
        commit([.setMarks(block: id, range: range, kind: .link, spans: url.map { [MarkSpan(range: range, mark: .link(url: $0))] } ?? [], previous: [])],
               from: selected, to: selected)
        session &+= 1
    }

    /// The link the whole range has (one address throughout), if any.
    func link(over range: Range<Int>, in block: DocBlock) -> String? {
        let links = block.text.marks.compactMap { span -> (Range<Int>, String)? in
            if case .link(let url) = span.mark { (span.range, url) } else { nil }
        }
        guard let first = links.first(where: { $0.0.contains(range.lowerBound) }),
              range.allSatisfy({ offset in links.contains { $0.0.contains(offset) && $0.1 == first.1 } })
        else { return nil }
        return first.1
    }

    /// Asks for the address of a link on the range (⌘K, 格式 ▸ 链接…), prefilled with the
    /// range's link or a web address on the pasteboard.
    func promptLink(over range: Range<Int>, in id: DocBlockID, from view: UIView) {
        guard let block = demo.doc.block(id), block.kind.allowsMarks, !range.isEmpty,
              var presenter = view.window?.rootViewController
        else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let current = link(over: range, in: block)
        let alert = UIAlertController(title: current == nil ? "添加链接" : "编辑链接", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://"
            field.text = current ?? UIPasteboard.general.string.flatMap(Self.webAddress)
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if current != nil {
            alert.addAction(UIAlertAction(title: "移除链接", style: .destructive) { [weak self] _ in
                self?.setLink(nil, over: range, in: id)
            })
        }
        alert.addAction(UIAlertAction(title: "完成", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return }
            // A bare address gets https.
            let url = text.contains("://") || text.hasPrefix("mailto:") ? text : "https://" + text
            self?.setLink(url, over: range, in: id)
        })
        presenter.present(alert, animated: true)
    }

    /// Shift-Tab, Shift-Return, ⌘B, ⌘I from the text view's key commands.
    func keyCommand(_ command: DocKeyCommand, in id: DocBlockID) {
        guard isEditable, let block = movedSelection(from: id) ?? demo.doc.block(id) else { return }
        switch command {
        case .slashUp, .slashDown:
            slash.move(by: command == .slashUp ? -1 : 1)
        case .slashClose:
            dismissSlash()
        case .outdent:
            indent(block, by: -1)
        case .lineBreak:
            guard let selection, selection.head.block == block.id, block.kind.allowsMarks else { return }
            if case .heading = block.kind { return }
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            lineBreak(replacing: range, in: block)
        case .bold, .italic:
            guard let selection, selection.head.block == block.id else { return }
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            guard !range.isEmpty else { return }
            toggle(command == .bold ? .bold : .italic, over: range, in: block.id)
        case .link:
            guard let selection, selection.head.block == block.id, let view = textView(for: block.id) else { return }
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            promptLink(over: range, in: block.id, from: view)
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

    /// The marked text changed: a slash query being composed filters the menu as it goes.
    func compositionChanged(in textView: UITextView, block id: DocBlockID) {
        guard let origin = slashOrigin, origin.block == id, let block = demo.doc.block(id),
            let old = rendered[ObjectIdentifier(textView)], let start = Self.textStart(of: old, block: block)
        else { return }
        let storage = Array((textView.text ?? "").utf16)
        let from = start + origin.offset + 1
        let caret = textView.selectedRange.location
        guard from <= caret, caret <= storage.count else { return }
        slashComposing(String(decoding: storage[from..<caret], as: UTF16.self))
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
        insert(inserted.replacing("\u{200B}", with: "").replacing("\u{2028}", with: "\n"), replacing: lower..<max(lower, upper), in: block)
    }

    private static func textStart(of storage: String, block: DocBlock) -> Int? {
        let shown = shown(block)
        // A line break inside the block renders as a line separator (same length).
        let storage = storage.replacing("\u{2028}", with: "\n")
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
        // Return chooses from the menu; with nothing matching it is a Return again.
        if string == "\n", slash.isOpen, slash.highlightedItem != nil {
            chooseSlash()
            return
        }
        if string == "\n", slash.isOpen { dismissSlash() }
        if string == "\n", case .quote = block.kind, !block.text.isEmpty {
            quoteReturn(replacing: range, in: block)
            return
        }
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
        var shortcutTaken = false
        if lines.count == 1, let shortcut = shortcut(after: steps, in: block, caret: offset) {
            steps += shortcut.steps
            caret = shortcut.caret
            shortcutTaken = true
        }
        // Plain typing (or deleting) inside the line goes into the text view's storage at
        // once (§6.2): the block's re-render, a moment later, then finds it as it is.
        let patch = lines.count == 1 && !shortcutTaken ? storagePatch(for: block, replacing: range, with: string, marks: marks) : nil
        // Typing merges into one undo step until the cursor moves; a space or a line
        // break ends the step.
        let typing = lines.count == 1 && !string.isEmpty && !string.contains(" ")
        commit(steps, from: DocSelection(anchor: .init(block: block.id, offset: range.lowerBound), head: .init(block: block.id, offset: range.upperBound)),
               to: DocSelection(anchor: caret, head: caret), merge: typing ? .init(block: block.id, session: session) : nil, beforePlacing: patch)
        if !typing { session &+= 1 }
        if Self.slashes.contains(string), block.kind.allowsMarks { slashTyped(in: block, at: range.lowerBound) }
    }

    /// The same edit made straight in the block's text view, when it can be: the view in
    /// sync, plain text in one line (no line break, atom or placeholder involved), and
    /// the inserted text carrying the marks of the character before it, whose
    /// attributes it takes. Nil otherwise (the re-render does it, as for everything else).
    private func storagePatch(for block: DocBlock, replacing range: Range<Int>, with string: String, marks: [Mark]) -> (() -> Void)? {
        guard let textView = textView(for: block.id), textView.markedTextRange == nil,
              let start = textStart(in: textView, block: block),
              !block.text.isEmpty, range.lowerBound > 0,
              block.text.length - range.count + string.utf16.count > 0,
              !string.contains(where: { $0.isNewline || $0 == "\u{FFFC}" || $0 == "\u{200B}" }),
              !block.text.string.contains("\n")
        else { return nil }
        let units = Array(block.text.string.utf16)
        guard !units[range].contains(0xFFFC) else { return nil }
        let before = Set(block.text.marks.filter { $0.range.contains(range.lowerBound - 1) && !$0.mark.kind.isAtom }.map(\.mark))
        guard before == Set(marks) else { return nil }
        let location = start + range.lowerBound
        return { [weak textView] in
            guard let textView, location + range.count <= textView.textStorage.length else { return }
            let storage = textView.textStorage
            var attributes = storage.attributes(at: location - 1, effectiveRange: nil)
            attributes[.attachment] = nil
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: location, length: range.count), with: NSAttributedString(string: string, attributes: attributes))
            storage.endEditing()
        }
    }

    /// An edit that leaves the text (a table took its place): the focus goes to the table.
    func commitLeavingText(_ steps: [DocStep], from before: DocSelection) {
        guard demo.edit(steps, before: before, after: nil) != nil else { return }
        selection = nil
        session &+= 1
    }

    /// The slash menu's edit: one undo step.
    func commitSlash(_ steps: [DocStep], from before: DocSelection, to after: DocSelection) {
        commit(steps, from: before, to: after)
        session &+= 1
    }

    /// Return in a quote is a line break inside it; on its empty last line, it leaves
    /// the quote (the empty line goes, a paragraph follows).
    private func quoteReturn(replacing range: Range<Int>, in block: DocBlock) {
        let end = block.text.length
        guard range == end..<end, block.text.string.hasSuffix("\n") else {
            lineBreak(replacing: range, in: block)
            return
        }
        let next = demo.newBlockID()
        let here = DocPosition(block: block.id, offset: end)
        let there = DocPosition(block: next, offset: 0)
        commit([
            .deleteText(block: block.id, range: (end - 1)..<end, removed: DocText()),
            .splitBlock(block: block.id, at: end - 1, newID: next, newKind: .paragraph, newIndent: block.indent),
        ], from: DocSelection(anchor: here, head: here), to: DocSelection(anchor: there, head: there))
        session &+= 1
    }

    /// A line break inside the block (Shift-Return; Return in a quote).
    private func lineBreak(replacing range: Range<Int>, in block: DocBlock) {
        var steps: [DocStep] = []
        if !range.isEmpty { steps.append(.deleteText(block: block.id, range: range, removed: DocText())) }
        steps.append(.insertText(block: block.id, at: range.lowerBound, text: DocText(string: "\n")))
        let caret = DocPosition(block: block.id, offset: range.lowerBound + 1)
        commit(steps, from: DocSelection(anchor: .init(block: block.id, offset: range.lowerBound), head: .init(block: block.id, offset: range.upperBound)),
               to: DocSelection(anchor: caret, head: caret))
        session &+= 1
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
    func indent(_ block: DocBlock, by delta: Int) {
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

    private func commit(_ steps: [DocStep], from before: DocSelection, to after: DocSelection, merge: DocHistory.MergeKey? = nil,
                        beforePlacing: (() -> Void)? = nil) {
        guard demo.edit(steps, before: before, after: after, merge: merge) != nil else { return }
        beforePlacing?()
        place(after)
        if UserDefaults.standard.bool(forKey: "docTrace") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                self?.traceViews(around: after.head.block)
            }
        }
    }

    /// What the screen shows for the blocks around one: each attached text view, its
    /// storage, whether it is visible.
    private func traceViews(around id: DocBlockID) {
        guard let index = demo.doc.blocks.firstIndex(where: { $0.id == id }) else { return }
        for block in demo.doc.blocks[max(0, index - 3)...min(demo.doc.blocks.count - 1, index + 1)] {
            let all = views[block.id]?.compactMap(\.view) ?? []
            print("DOCTRACE view \(block.id == id ? ">" : " ") \(block.text.string.prefix(16).debugDescription) views=\(all.count)")
            for view in all {
                var hidden = ""
                var ancestor: UIView? = view
                while let current = ancestor {
                    if current.isHidden || current.alpha < 0.99 { hidden += " \(Swift.type(of: current)):a=\(current.alpha),h=\(current.isHidden)" }
                    ancestor = current.superview
                }
                let frame = view.window.map { view.convert(view.bounds, to: $0) }
                print("DOCTRACE      key=\(view.window?.isKeyWindow == true) fr=\(view.isFirstResponder) sel=\(view.selectedRange) start=\(textStart(in: view, block: block).map(String.init) ?? "-") frame=\(frame.map { "\(Int($0.minY))+\(Int($0.height))" } ?? "-") text=\((view.text ?? "").prefix(16).debugDescription) len=\(view.textStorage.length) sync=\(textStart(in: view, block: block) != nil)\(hidden)")
            }
        }
        guard let anchor = textView(for: id) else { return }
        var ancestor = anchor.superview
        while let view = ancestor, !(view is UICollectionView) { ancestor = view.superview }
        guard let list = ancestor as? UICollectionView else { return }
        func texts(in view: UIView) -> [UITextView] {
            view.subviews.flatMap { ($0 as? UITextView).map { [$0] } ?? texts(in: $0) }
        }
        for cell in list.visibleCells.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            let frame = cell.convert(cell.bounds, to: nil)
            let shown = texts(in: cell.contentView).map { ($0.text ?? "").prefix(12).debugDescription }
            print("DOCTRACE cell \(ObjectIdentifier(cell).hashValue % 10000) y=\(Int(frame.minY))+\(Int(frame.height)) subviews=\(cell.contentView.subviews.count) alpha=\(cell.contentView.alpha) texts=\(shown)")
        }
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
        let link = UIAction(title: Self.covers(block.text, modelRange, with: .link) ? "编辑链接…" : "链接…",
                            image: UIImage(systemName: "link")) { [weak self, weak textView] _ in
            guard let self, let textView else { return }
            self.promptLink(over: modelRange, in: id, from: textView)
        }
        let format = UIMenu(title: "格式", image: UIImage(systemName: "textformat"), children: actions + [link])
        return UIMenu(children: [format] + suggested)
    }

    static func covers(_ text: DocText, _ range: Range<Int>, with kind: MarkKind) -> Bool {
        let spans = text.marks.filter { $0.mark.kind == kind }
        return range.allSatisfy { offset in spans.contains { $0.range.contains(offset) } }
    }

    /// Blocks of text become `kind` in one transaction (a list keeps its items' levels).
    /// A block with the cursor in it goes the slash menu's way, the cursor kept.
    func setKind(_ kind: BlockKind, of ids: [DocBlockID]) {
        let chosen = Set(ids)
        let blocks = demo.doc.blocks.filter { chosen.contains($0.id) && $0.kind.carriesText && $0.kind != kind }
        if blocks.count == 1, let block = blocks.first, let head = selection?.head, head.block == block.id {
            return perform(.kind(kind), in: block, replacing: head.offset..<head.offset, from: head)
        }
        let steps: [DocStep] = blocks.map { block in
            let indent = if case .listItem = kind, case .listItem = block.kind { block.indent } else { 0 }
            return .setBlock(block: block.id, kind: kind, indent: indent, previousKind: block.kind, previousIndent: block.indent)
        }
        guard !steps.isEmpty else { return }
        demo.edit(steps, before: selection, after: selection)
    }

    /// Marks each range, or clears the mark when all of them already have it, in one
    /// transaction.
    func toggle(_ mark: Mark, over ranges: [(block: DocBlockID, range: Range<Int>)]) {
        let ranges = ranges.filter { !$0.range.isEmpty && demo.doc.block($0.block)?.kind.allowsMarks == true }
        guard !ranges.isEmpty else { return }
        let on = !ranges.allSatisfy { Self.covers(demo.doc.block($0.block)!.text, $0.range, with: mark.kind) }
        let steps: [DocStep] = ranges.map {
            .setMarks(block: $0.block, range: $0.range, kind: mark.kind, spans: on ? [MarkSpan(range: $0.range, mark: mark)] : [], previous: [])
        }
        demo.edit(steps, before: selection, after: selection)
    }

    /// List items nest one level deeper or come out one, in one transaction; an item
    /// goes no deeper than one below the item before it.
    func indent(_ ids: [DocBlockID], by delta: Int) {
        let chosen = Set(ids)
        var steps: [DocStep] = []
        var previous: (kind: BlockKind, indent: Int)?
        for block in demo.doc.blocks {
            var indent = block.indent
            if chosen.contains(block.id), case .listItem = block.kind {
                let ceiling: Int = if let previous, case .listItem = previous.kind { previous.indent + 1 } else { 0 }
                indent = min(max(0, block.indent + delta), ceiling)
                if indent != block.indent {
                    steps.append(.setBlock(block: block.id, kind: block.kind, indent: indent, previousKind: block.kind, previousIndent: block.indent))
                }
            }
            previous = (block.kind, indent)
        }
        guard !steps.isEmpty else { return }
        demo.edit(steps, before: selection, after: selection)
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

    /// One history entry back (⌘Z, the Edit menu, the toolbar).
    func requestUndo() {
        let selection = demo.undo()
        syncEditors()
        if let selection { place(selection) }
    }

    func requestRedo() {
        let selection = demo.redo()
        syncEditors()
        if let selection { place(selection) }
    }

    /// An editor typed into natively (a code block's, a table cell's) shows what it was
    /// given last; after an undo it takes the model's text now. Its row may never
    /// re-render: an undo straight after typing leaves the rows as they were before
    /// the typing, so the list sees no change.
    private func syncEditors() {
        sources.syncEditedText()
        tables.syncEditedText()
    }

    func resetHistory() {
        undoManager.removeAllActions()
        selection = nil
    }
}

/// The document's history as UIKit sees it: ⌘Z, the Edit menu and the text views'
/// undo land here, one history entry per undo. UIKit's own registrations and groups
/// (a text view keeps a typing group open until the caret moves) go to the base
/// class's stack, which nothing undoes: with them, two edits could undo as one.
final class DocUndoManager: UndoManager {
    nonisolated(unsafe) weak var editor: DocEditor?

    override var canUndo: Bool {
        MainActor.assumeIsolated { editor?.demo.canUndo ?? false }
    }

    override var canRedo: Bool {
        MainActor.assumeIsolated { editor?.demo.canRedo ?? false }
    }

    override func undo() {
        MainActor.assumeIsolated { editor?.requestUndo() }
    }

    override func undoNestedGroup() {
        undo()
    }

    override func redo() {
        MainActor.assumeIsolated { editor?.requestRedo() }
    }
}

enum DocKeyCommand {
    case outdent, bold, italic, link, lineBreak, slashUp, slashDown, slashClose
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
        // Marked text can start without asking the delegate (setMarkedText): it's a
        // composition all the same, committed when the marked text goes.
        if textView.markedTextRange != nil {
            if !composing { editor?.compositionBegan() }
            composing = true
            editor?.compositionChanged(in: textView, block: block)
        }
        guard composing, textView.markedTextRange == nil else { return }
        composing = false
        editor?.commitComposition(in: textView, block: block)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        original?.textViewDidChangeSelection?(textView)
    }

    /// Typing in the document's text again: no table cell is edited any more.
    func textViewDidBeginEditing(_ textView: UITextView) {
        original?.textViewDidBeginEditing?(textView)
        editor?.tables.endEditing()
        editor?.sources.endEditing()
        editor?.blocks.textEditingBegan()
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

    /// Shift-Tab steps a list item out, Shift-Return breaks the line inside the block,
    /// ⌘B and ⌘I toggle bold and italic, ⌘K links (Composer had
    /// them; UIKit's own versions would edit the storage, not the model).
    /// ↑, ↓ and Esc are the slash menu's only while it is open.
    private static let commands: [(input: String, flags: UIKeyModifierFlags, selector: Selector, command: DocKeyCommand, title: String, slashMenu: Bool)] = [
        ("\t", .shift, Selector(("docOutdent:")), .outdent, "减少缩进", false),
        ("\r", .shift, Selector(("docLineBreak:")), .lineBreak, "换行", false),
        ("b", .command, Selector(("docBold:")), .bold, "加粗", false),
        ("i", .command, Selector(("docItalic:")), .italic, "斜体", false),
        ("k", .command, Selector(("docLink:")), .link, "链接", false),
        (UIKeyCommand.inputUpArrow, [], Selector(("docSlashUp:")), .slashUp, "上一项", true),
        (UIKeyCommand.inputDownArrow, [], Selector(("docSlashDown:")), .slashDown, "下一项", true),
        (UIKeyCommand.inputEscape, [], Selector(("docSlashClose:")), .slashClose, "关闭菜单", true),
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
                guard let (_, _, editor) = editor(of: object) else { return [] }
                return commands.filter { !$0.slashMenu || editor.slash.isOpen }.map { entry in
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
