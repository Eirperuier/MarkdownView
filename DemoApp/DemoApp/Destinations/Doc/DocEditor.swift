//
//  DocEditor.swift
//  DemoApp
//
//  Editing in the reading view (doc.md §6.2): each block's MarkdownSelectableText text
//  view turns editable, and every change the person makes becomes DocKit steps. The
//  model is the only source of truth — keystrokes don't edit the text storage; the
//  block re-renders from the model and the cursor is put back through the
//  storage → plain map. IME composition is the exception: it runs natively and commits
//  as one step when the marked text is gone.
//

import SwiftUI
import UIKit
import ObjectiveC
import DocKit
import MarkdownView

@MainActor
final class DocEditor {
    let demo: DocDemo

    private var hooks: [DocBlockID: MarkdownSelectableTextHooks] = [:]
    /// Text views per block: the one on screen, and any TiledView renders off screen to
    /// measure a row. Only the one in the key window is edited.
    private var views: [DocBlockID: [WeakTextView]] = [:]
    private var delegates: [ObjectIdentifier: DocTextDelegate] = [:]
    /// What each text view shows after its last render: the storage text and its
    /// storage → plain map. Offsets map through it; an IME commit diffs against it.
    private var rendered: [ObjectIdentifier: (text: String, map: [Int])] = [:]
    /// Where the cursor goes once the block it's in has rendered.
    private var pendingCaret: DocPosition?
    private var placingCaret = false
    /// Typing session for undo merging: moving the cursor starts a new one.
    private var session: UInt64 = 0

    var isEditable = true {
        didSet {
            for view in views.values.flatMap({ $0 }).compactMap(\.view) {
                view.isEditable = isEditable
                if !isEditable { view.resignFirstResponder() }
            }
        }
    }

    init(demo: DocDemo) {
        self.demo = demo
    }

    /// One hooks object per block, reused so the environment stays equal.
    func hooks(for id: DocBlockID) -> MarkdownSelectableTextHooks {
        if let existing = hooks[id] { return existing }
        let made = MarkdownSelectableTextHooks(
            onTextViewReady: { [weak self] in self?.attach($0, to: id) },
            onSelectionChanged: { [weak self] _ in self?.selectionChanged() },
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
        let original = (textView.delegate as? DocTextDelegate)?.original ?? textView.delegate
        let delegate = DocTextDelegate(original: original, block: id, editor: self)
        delegates[ObjectIdentifier(textView)] = delegate
        textView.delegate = delegate
        DeleteBackwardHook.install(on: type(of: textView))
    }

    private func contentChanged(_ textView: UITextView, in id: DocBlockID) {
        let map = MarkdownSelectableTextPlainMap.storageToPlain(for: textView) ?? []
        rendered[ObjectIdentifier(textView)] = (textView.text ?? "", map)
        // SwiftUI may run an update with the previous content first; wait for the one
        // that shows the model (one plain unit per model character).
        if let caret = pendingCaret, caret.block == id, textView.window?.isKeyWindow == true, let block = demo.doc.block(id),
            (map.last.map { $0 + 1 } ?? 0) == block.text.string.count
        {
            place(caret)
        }
    }

    private func selectionChanged() {
        if !placingCaret { session &+= 1 }
    }

    /// Puts the cursor at a model position, now or once its block has rendered.
    func place(_ caret: DocPosition) {
        guard let textView = onScreen(caret.block), let snapshot = rendered[ObjectIdentifier(textView)],
            let block = demo.doc.block(caret.block)
        else {
            pendingCaret = caret
            return
        }
        pendingCaret = nil
        placingCaret = true
        defer { placingCaret = false }
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        let location = Self.storageOffset(model: caret.offset, text: block.text, storage: snapshot.text, map: snapshot.map)
        textView.selectedRange = NSRange(location: location, length: 0)
    }

    /// The block's text view in the key window, not a measuring copy.
    private func onScreen(_ id: DocBlockID) -> UITextView? {
        views[id]?.compactMap(\.view).first { $0.window?.isKeyWindow == true }
    }

    // MARK: Offsets

    /// Storage UTF-16 offset → model UTF-16 offset, through the plain map (one plain
    /// unit per model character; markers and the like map to the next text).
    static func modelOffset(storage location: Int, storage text: String, map: [Int], model: DocText) -> Int {
        let index = String.Index(utf16Offset: min(location, text.utf16.count), in: text)
        let character = text.distance(from: text.startIndex, to: index)
        let plain = character < map.count ? map[character] : (map.last.map { $0 + 1 } ?? 0)
        let prefix = model.string.prefix(max(0, plain))
        return min(model.length, prefix.utf16.count)
    }

    static func storageOffset(model offset: Int, text model: DocText, storage text: String, map: [Int]) -> Int {
        let modelIndex = String.Index(utf16Offset: min(offset, model.length), in: model.string)
        let plain = model.string.distance(from: model.string.startIndex, to: modelIndex)
        // The last storage character at this plain offset: past list markers to the text.
        let character = map.lastIndex(of: plain) ?? map.firstIndex { $0 > plain } ?? text.count
        return text.index(text.startIndex, offsetBy: min(character, text.count)).utf16Offset(in: text)
    }

    private func modelRange(_ range: NSRange, in textView: UITextView, block: DocBlock) -> Range<Int>? {
        guard let snapshot = rendered[ObjectIdentifier(textView)] else { return nil }
        let lower = Self.modelOffset(storage: range.location, storage: snapshot.text, map: snapshot.map, model: block.text)
        let upper = Self.modelOffset(storage: NSMaxRange(range), storage: snapshot.text, map: snapshot.map, model: block.text)
        return lower..<max(lower, upper)
    }

    // MARK: Input

    /// A change UIKit proposes; always handled here, never applied by UIKit.
    func replace(_ range: NSRange, with replacement: String, in textView: UITextView, block id: DocBlockID) {
        guard let block = demo.doc.block(id), block.kind.carriesText,
            let range = modelRange(range, in: textView, block: block)
        else { return }
        if replacement == "\t" {
            indent(block, by: 1)
            return
        }
        // Backspace over a list marker: nothing of the text goes, so it's a backspace
        // at the start of the block.
        if replacement.isEmpty, range.isEmpty, range.lowerBound == 0 {
            _ = deleteBackward(atStartOf: block)
            return
        }
        insert(replacement, replacing: range, in: block)
    }

    /// The marked text is gone: whatever the IME left in the storage is one insertion.
    func commitComposition(in textView: UITextView, block id: DocBlockID) {
        guard let block = demo.doc.block(id), let snapshot = rendered[ObjectIdentifier(textView)] else { return }
        let old = Array(snapshot.text.utf16)
        let new = Array((textView.text ?? "").utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let inserted = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
        let lower = Self.modelOffset(storage: prefix, storage: snapshot.text, map: snapshot.map, model: block.text)
        let upper = Self.modelOffset(storage: old.count - suffix, storage: snapshot.text, map: snapshot.map, model: block.text)
        textView.undoManager?.enableUndoRegistration()
        insert(inserted, replacing: lower..<max(lower, upper), in: block)
    }

    /// Text typed or pasted over `range`. Line breaks split the block; markdown
    /// shortcuts at the start of a block or around a word become their formatting.
    private func insert(_ string: String, replacing range: Range<Int>, in block: DocBlock) {
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, block.text.isEmpty, range.isEmpty, string == "\n" {
            if leaveEmptyBlock(block) { return }
        }
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
        let typing = lines.count == 1 && !string.isEmpty && !string.contains(" ")
        commit(steps, from: DocSelection(anchor: .init(block: block.id, offset: range.lowerBound), head: .init(block: block.id, offset: range.upperBound)),
               to: caret, merge: typing ? .init(block: block.id, session: session) : nil)
    }

    /// Return in an empty list item or quote leaves it: out one level, then to a paragraph.
    private func leaveEmptyBlock(_ block: DocBlock) -> Bool {
        switch block.kind {
        case .listItem where block.indent > 0:
            indent(block, by: -1)
        case .listItem, .quote:
            commitSet(block, kind: .paragraph, indent: 0)
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
    /// False when the cursor isn't at the start: UIKit deletes as usual.
    func deleteBackward(in textView: UITextView, block id: DocBlockID) -> Bool {
        guard let block = demo.doc.block(id), textView.selectedRange.length == 0,
            let range = modelRange(textView.selectedRange, in: textView, block: block), range.lowerBound == 0
        else { return false }
        return deleteBackward(atStartOf: block)
    }

    private func deleteBackward(atStartOf block: DocBlock) -> Bool {
        let id = block.id
        switch block.kind {
        case .listItem where block.indent > 0:
            indent(block, by: -1)
        case .listItem, .heading, .quote:
            commitSet(block, kind: .paragraph, indent: 0)
        default:
            guard let index = demo.doc.blocks.firstIndex(where: { $0.id == id }), index > 0 else { return true }
            let previous = demo.doc.blocks[index - 1]
            let here = DocSelection(anchor: .init(block: id, offset: 0), head: .init(block: id, offset: 0))
            if previous.kind.carriesText {
                guard previous.kind.allowsMarks || block.text.marks.isEmpty else { return true }
                commit([.joinBlock(block: id, into: previous.id, at: 0, kind: block.kind, indent: block.indent)],
                       from: here, to: .init(block: previous.id, offset: previous.text.length))
            } else {
                commit([.deleteBlock(block: previous, after: nil)], from: here, to: .init(block: id, offset: 0))
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
        commitSet(block, kind: block.kind, indent: indent)
    }

    private func commitSet(_ block: DocBlock, kind: BlockKind, indent: Int) {
        let caret = DocPosition(block: block.id, offset: 0)
        commit([.setBlock(block: block.id, kind: kind, indent: indent, previousKind: block.kind, previousIndent: block.indent)],
               from: DocSelection(anchor: caret, head: caret), to: caret)
    }

    private func commit(_ steps: [DocStep], from before: DocSelection, to caret: DocPosition, merge: DocHistory.MergeKey? = nil) {
        let depth = demo.undoDepth
        guard demo.edit(steps, before: before, after: DocSelection(anchor: caret, head: caret), merge: merge) != nil else { return }
        // One system undo action per history entry; typing merged into the last entry adds none.
        if demo.undoDepth > depth, let manager = onScreen(before.anchor.block)?.undoManager {
            undoManager = manager
            manager.registerUndo(withTarget: self) { $0.undo() }
        }
        place(caret)
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
                    let open = wrap.lowerBound - delimiter.utf16.count
                    let close = wrap.upperBound
                    let inner = (wrap.lowerBound - delimiter.utf16.count)..<(wrap.upperBound - delimiter.utf16.count)
                    return ([.deleteText(block: block.id, range: close..<(close + delimiter.utf16.count), removed: DocText()),
                             .deleteText(block: block.id, range: open..<wrap.lowerBound, removed: DocText()),
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
        guard text.hasSuffix(delimiter) else { return nil }
        let body = text.dropLast(delimiter.count)
        guard let open = body.range(of: delimiter, options: .backwards) else { return nil }
        let inner = body[open.upperBound...]
        guard !inner.isEmpty, inner.first != " ", inner.last != " ", !inner.contains(delimiter.first!) else { return nil }
        let lower = text.utf16.distance(from: text.startIndex, to: open.upperBound)
        return lower..<(lower + inner.utf16.count)
    }

    // MARK: Undo

    /// The system undo manager the history is mirrored into (⌘Z, shake, three-finger
    /// swipe all reach it); its actions call back into the DocKit history (§7).
    private weak var undoManager: UndoManager?

    /// Bar buttons go through the same manager as ⌘Z, so the two stacks stay in step.
    func requestUndo() {
        if let undoManager, undoManager.canUndo { undoManager.undo() } else { undo() }
    }

    func requestRedo() {
        if let undoManager, undoManager.canRedo { undoManager.redo() } else { redo() }
    }

    private func undo() {
        guard let selection = demo.undo() else { return }
        undoManager?.registerUndo(withTarget: self) { $0.redo() }
        place(selection.head)
    }

    private func redo() {
        guard let selection = demo.redo() else { return }
        undoManager?.registerUndo(withTarget: self) { $0.undo() }
        place(selection.head)
    }
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
            // UIKit's own typing undo would edit the storage behind the model's back.
            if !composing { textView.undoManager?.disableUndoRegistration() }
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

/// UIKit doesn't ask the delegate about backspace with the cursor at the very start,
/// so the text view class gets a `deleteBackward` that asks the editor first. (The
/// real version belongs in RichText's text view; this is the prototype hook.)
@MainActor
private enum DeleteBackwardHook {
    private static var installed: Set<ObjectIdentifier> = []

    static func install(on type: AnyClass) {
        guard installed.insert(ObjectIdentifier(type)).inserted else { return }
        let selector = #selector(UITextView.deleteBackward)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        typealias Implementation = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        let replacement: @convention(block) (AnyObject) -> Void = { object in
            let handled = MainActor.assumeIsolated {
                guard let textView = object as? UITextView, let delegate = textView.delegate as? DocTextDelegate,
                    let editor = delegate.editor, editor.isEditable
                else { return false }
                return editor.deleteBackward(in: textView, block: delegate.block)
            }
            if !handled { original(object, selector) }
        }
        let implementation = imp_implementationWithBlock(replacement)
        if !class_addMethod(type, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}
