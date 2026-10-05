//
//  DocEditTests.swift
//  DemoApp
//
//  Scripted editing against the real page: keystrokes go into the on-screen text
//  views through UIKeyInput (the keyboard's own path), and after each one the model,
//  the storage and the cursor must agree. Run with `-docDemo YES -docEditTest YES`;
//  results are printed as `DOCTEST PASS|FAIL <name>` and a `DOCTEST DONE` summary.
//

import UIKit
import DocKit

@MainActor
final class DocEditTests {
    private let demo: DocDemo
    private let editor: DocEditor
    private var passed = 0
    private var failed = 0

    init(demo: DocDemo, editor: DocEditor) {
        self.demo = demo
        self.editor = editor
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func run() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        await test("typing in the middle") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 1)
            try await self.type("XYZ")
            try self.expect(self.text(block.id).hasPrefix("LXYZoading"), "text \(self.text(block.id).prefix(16))")
            try self.expectCursor(block.id, 4)
        }
        await test("typing fast, ahead of the renders") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 1)
            try await self.type("abcde", waitEach: false)
            try self.expect(self.text(block.id).hasPrefix("Labcdeoading"), "text \(self.text(block.id).prefix(16))")
            try self.expectCursor(block.id, 6)
        }
        await test("spaces, also at the end") {
            let block = try self.block("Loading older")
            let end = block.text.length
            try await self.focus(block.id, at: end)
            try await self.type(" ")
            try self.expect(self.text(block.id).hasSuffix("update. "), "text end \(self.text(block.id).suffix(10).debugDescription)")
            try self.expectCursor(block.id, end + 1)
            try await self.type(" z")
            try self.expect(self.text(block.id).hasSuffix("update.  z"), "text end \(self.text(block.id).suffix(10).debugDescription)")
        }
        await test("Return in the middle splits, typing goes on in the new block") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 7)
            try await self.enter()
            let next = try self.blockAfter(block.id)
            try self.expect(self.text(block.id) == "Loading", "head \(self.text(block.id).debugDescription)")
            try self.expect(self.text(next.id).hasPrefix(" older"), "tail \(self.text(next.id).prefix(10).debugDescription)")
            try self.expectCursor(next.id, 0)
            try await self.type("Q")
            try self.expect(self.text(next.id).hasPrefix("Q older"), "tail \(self.text(next.id).prefix(10).debugDescription)")
        }
        await test("Return at the end opens an empty paragraph you can type in") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            let next = try self.blockAfter(block.id)
            try self.expect(next.text.isEmpty && next.kind == .paragraph, "new block \(next.kind) \(next.text.string.debugDescription)")
            try self.expectCursor(next.id, 0)
            try await self.type("hi")
            try self.expect(self.text(next.id) == "hi", "new block \(self.text(next.id).debugDescription)")
        }
        await test("Return twice leaves two empty lines") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            try await self.enter()
            let first = try self.blockAfter(block.id)
            let second = try self.blockAfter(first.id)
            try self.expect(first.text.isEmpty && second.text.isEmpty, "\(first.text.string.debugDescription) \(second.text.string.debugDescription)")
            try self.expectCursor(second.id, 0)
        }
        await test("Backspace in the middle deletes one character") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 3)
            try await self.backspace()
            try self.expect(self.text(block.id).hasPrefix("Loding"), "text \(self.text(block.id).prefix(10))")
            try self.expectCursor(block.id, 2)
        }
        await test("Backspace at the start joins the block into the one before") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 7)
            try await self.enter()
            let next = try self.blockAfter(block.id)
            try await self.backspace()
            try self.expect(self.demo.doc.block(next.id) == nil, "tail still there")
            try self.expect(self.text(block.id).hasPrefix("Loading older"), "joined \(self.text(block.id).prefix(16))")
            try self.expectCursor(block.id, 7)
        }
        await test("Return in a list item makes the next item; Return on an empty one leaves the list") {
            let item = try self.block("行首输入")
            try await self.focus(item.id, at: item.text.length)
            try await self.enter()
            let next = try self.blockAfter(item.id)
            try self.expect(next.kind == item.kind, "new item kind \(next.kind)")
            try await self.type("x")
            try self.expect(self.text(next.id) == "x", "new item \(self.text(next.id).debugDescription)")
            try await self.enter()
            let empty = try self.blockAfter(next.id)
            try await self.enter()
            try self.expect(self.demo.doc.block(empty.id)?.kind == .paragraph, "left the list: \(String(describing: self.demo.doc.block(empty.id)?.kind))")
            try self.expectCursor(empty.id, 0)
        }
        await test("- and a space make a list item") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            let next = try self.blockAfter(block.id)
            try await self.type("- ")
            try self.expect(self.demo.doc.block(next.id)?.kind == .listItem(style: .bullet), "kind \(String(describing: self.demo.doc.block(next.id)?.kind))")
            try self.expect(self.text(next.id).isEmpty, "text \(self.text(next.id).debugDescription)")
            try await self.type("a")
            try self.expect(self.text(next.id) == "a", "text \(self.text(next.id).debugDescription)")
        }
        await test("Undo takes back a typing burst and puts the cursor back; Redo restores it") {
            let block = try self.block("Loading older")
            let original = block.text.string
            try await self.focus(block.id, at: 1)
            try await self.type("abc")
            try await self.undo()
            try self.expect(self.text(block.id) == original, "after undo \(self.text(block.id).prefix(12))")
            try self.expectCursor(block.id, 1)
            try await self.redo()
            try self.expect(self.text(block.id).hasPrefix("Labcoading"), "after redo \(self.text(block.id).prefix(12))")
        }
        await test("Undo takes back a split") {
            let block = try self.block("Loading older")
            let original = block.text.string
            try await self.focus(block.id, at: 7)
            try await self.enter()
            try await self.undo()
            try self.expect(self.text(block.id) == original, "after undo \(self.text(block.id).prefix(12))")
            try self.expectCursor(block.id, 7)
        }
        await test("Typing over a selection replaces it") {
            let block = try self.block("Loading older")
            try await self.select(block.id, 1..<4)
            try await self.type("Z")
            try self.expect(self.text(block.id).hasPrefix("LZing"), "text \(self.text(block.id).prefix(10))")
            try self.expectCursor(block.id, 2)
        }
        await test("Formatting a selection bolds it and keeps it selected") {
            let block = try self.block("Loading older")
            try await self.select(block.id, 0..<7)
            self.editor.toggle(.bold, over: 0..<7, in: block.id)
            try await self.settle()
            let marks = self.demo.doc.block(block.id)?.text.marks ?? []
            try self.expect(marks.contains(MarkSpan(range: 0..<7, mark: .bold)), "marks \(marks)")
            try self.expect(self.editor.selection == DocSelection(anchor: .init(block: block.id, offset: 0), head: .init(block: block.id, offset: 7)), "selection \(String(describing: self.editor.selection))")
        }
        await test("Return then typing at once, before the new line has rendered") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 7)
            let first = try self.view()
            @MainActor func press(_ string: String) {
                if first.delegate?.textView?(first, shouldChangeTextIn: first.selectedRange, replacementText: string) ?? true { first.insertText(string) }
            }
            press("\n")
            press("Q")
            try await self.settle()
            let next = try self.blockAfter(block.id)
            try self.expect(self.text(block.id) == "Loading", "head \(self.text(block.id).debugDescription)")
            try self.expect(self.text(next.id).hasPrefix("Q older"), "tail \(self.text(next.id).prefix(10).debugDescription)")
            try self.expectCursor(next.id, 1)
        }
        await test("Undo and Redo step through typing, Return and typing again") {
            let block = try self.block("Loading older")
            let original = block.text.string
            try await self.focus(block.id, at: block.text.length)
            try await self.type("ab")
            try await self.enter()
            try await self.type("cd")
            try await self.undo()
            try await self.undo()
            try await self.undo()
            try self.expect(self.text(block.id) == original, "after undos \(self.text(block.id).suffix(12).debugDescription)")
            try self.expect(self.demo.doc.blocks.count == self.blockCountAtStart, "blocks \(self.demo.doc.blocks.count)")
            try self.expectCursor(block.id, original.utf16.count)
            try await self.redo()
            try await self.redo()
            try await self.redo()
            let next = try self.blockAfter(block.id)
            try self.expect(self.text(block.id).hasSuffix("update.ab") && self.text(next.id) == "cd", "after redos \(self.text(block.id).suffix(10).debugDescription) \(self.text(next.id).debugDescription)")
        }
        await test("Edit ▸ Undo (what ⌘Z sends) reaches the document history") {
            let block = try self.block("Loading older")
            let original = block.text.string
            try await self.focus(block.id, at: 1)
            try await self.type("xy")
            try self.expect(try self.view().undoManager === self.editor.undoManager, "text view answers with another undo manager")
            UIApplication.shared.sendAction(Selector(("undo:")), to: nil, from: nil, for: nil)
            try await self.settle()
            try self.expect(self.text(block.id) == original, "after undo: \(self.text(block.id).prefix(10))")
        }
        await test("Backspace in an empty line removes it and goes to the end of the line before") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            try await self.backspace()
            try self.expect(self.demo.doc.blocks.count == self.blockCountAtStart, "blocks \(self.demo.doc.blocks.count)")
            try self.expectCursor(block.id, block.text.length)
        }
        await test("Backspace at the start of a list item makes it a paragraph") {
            let item = try self.block("行首输入")
            try await self.focus(item.id, at: 0)
            try await self.backspace()
            try self.expect(self.demo.doc.block(item.id)?.kind == .paragraph, "kind \(String(describing: self.demo.doc.block(item.id)?.kind))")
            try self.expectCursor(item.id, 0)
        }
        await test("Tab nests a list item, the cursor stays put") {
            let item = try self.block("行首输入")
            try await self.focus(item.id, at: 2)
            try await self.type("\t")
            try self.expect(self.demo.doc.block(item.id)?.indent == 1, "indent \(String(describing: self.demo.doc.block(item.id)?.indent))")
            try self.expectCursor(item.id, 2)
        }
        await test("Shift-Tab (the key command) steps a nested item out") {
            let item = try self.block("嵌套列表")
            let indent = item.indent
            try await self.focus(item.id, at: 1)
            UIApplication.shared.sendAction(Selector(("docOutdent:")), to: nil, from: nil, for: nil)
            try await self.settle()
            try self.expect(self.demo.doc.block(item.id)?.indent == indent - 1, "indent \(String(describing: self.demo.doc.block(item.id)?.indent)) was \(indent)")
            try self.expectCursor(item.id, 1)
        }
        await test("⌘B (the key command) bolds the selection") {
            let block = try self.block("Loading older")
            try await self.select(block.id, 0..<7)
            UIApplication.shared.sendAction(Selector(("docBold:")), to: nil, from: nil, for: nil)
            try await self.settle()
            let marks = self.demo.doc.block(block.id)?.text.marks ?? []
            try self.expect(marks.contains(MarkSpan(range: 0..<7, mark: .bold)), "marks \(marks)")
        }
        await test("Return in a heading continues with a paragraph") {
            let heading = try self.block("第 1 节")
            try await self.focus(heading.id, at: heading.text.length)
            try await self.enter()
            let next = try self.blockAfter(heading.id)
            try self.expect(next.kind == .paragraph && next.text.isEmpty, "next \(next.kind)")
            try self.expectCursor(next.id, 0)
        }
        await test("**word** becomes bold") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 0)
            try await self.type("**ab**")
            let text = self.demo.doc.block(block.id)?.text
            try self.expect(text?.string.hasPrefix("abLoading") == true, "text \(String(describing: text?.string.prefix(12)))")
            try self.expect(text?.marks.contains(MarkSpan(range: 0..<2, mark: .bold)) == true, "marks \(String(describing: text?.marks))")
            try self.expectCursor(block.id, 2)
        }
        print("DOCTEST DONE pass=\(passed) fail=\(failed)")
    }

    private var blockCountAtStart = 0

    private func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
        demo.reset()
        editor.resetHistory()
        blockCountAtStart = demo.doc.blocks.count
        try? await Task.sleep(for: .milliseconds(300))
        do {
            try await body()
            passed += 1
            print("DOCTEST PASS \(name)")
        } catch {
            failed += 1
            print("DOCTEST FAIL \(name): \(error)")
        }
    }

    // MARK: Helpers

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    private func expectCursor(_ id: DocBlockID, _ offset: Int) throws {
        let caret = DocPosition(block: id, offset: offset)
        try expect(editor.selection == DocSelection(anchor: caret, head: caret), "selection \(String(describing: editor.selection)) expected \(offset)")
        if let problem = editor.mismatch() { throw Failure(description: problem) }
    }

    private func block(_ prefix: String) throws -> DocBlock {
        guard let block = demo.doc.blocks.first(where: { $0.text.string.hasPrefix(prefix) }) else {
            throw Failure(description: "no block starting \(prefix)")
        }
        return block
    }

    private func blockAfter(_ id: DocBlockID) throws -> DocBlock {
        guard let index = demo.doc.blocks.firstIndex(where: { $0.id == id }), index + 1 < demo.doc.blocks.count else {
            throw Failure(description: "no block after")
        }
        return demo.doc.blocks[index + 1]
    }

    private func text(_ id: DocBlockID) -> String {
        demo.doc.block(id)?.text.string ?? "<gone>"
    }

    /// Waits until the screen shows the model with the cursor where the model says.
    private func settle() async throws {
        for _ in 0..<80 {
            if editor.mismatch() == nil { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let row = editor.selection.flatMap { selection in demo.rows.first { $0.block == selection.head.block } }
        throw Failure(description: "never settled: \(editor.mismatch() ?? "") | row \(row?.blocks.map(\.source) ?? [])")
    }

    private func view() throws -> UITextView {
        guard let selection = editor.selection, let view = editor.textView(for: selection.head.block) else {
            throw Failure(description: "no focused text view")
        }
        return view
    }

    private func focus(_ id: DocBlockID, at offset: Int) async throws {
        editor.place(DocPosition(block: id, offset: offset))
        try await settle()
    }

    private func select(_ id: DocBlockID, _ range: Range<Int>) async throws {
        editor.place(DocSelection(anchor: .init(block: id, offset: range.lowerBound), head: .init(block: id, offset: range.upperBound)))
        try await settle()
    }

    /// A key the way the keyboard sends it: the delegate is asked first, and only a
    /// yes lets the text view apply it (programmatic `insertText` skips the delegate).
    private func key(_ string: String) throws {
        let view = try view()
        let range = view.selectedRange
        if view.delegate?.textView?(view, shouldChangeTextIn: range, replacementText: string) ?? true {
            view.insertText(string)
        }
    }

    private func type(_ string: String, waitEach: Bool = true) async throws {
        for character in string {
            try key(String(character))
            if waitEach { try await settle() }
        }
        try await settle()
    }

    private func enter() async throws {
        try key("\n")
        try await settle()
    }

    /// Backspace as the keyboard does it: at the very start the text view's
    /// `deleteBackward` runs (UIKit asks no one); elsewhere the delegate is asked about
    /// the character before the cursor.
    private func backspace() async throws {
        let view = try view()
        var range = view.selectedRange
        if range.length == 0 {
            guard range.location > 0 else {
                view.deleteBackward()
                try await settle()
                return
            }
            range = (view.text as NSString).rangeOfComposedCharacterSequence(at: range.location - 1)
        }
        if view.delegate?.textView?(view, shouldChangeTextIn: range, replacementText: "") ?? true {
            view.deleteBackward()
        }
        try await settle()
    }

    private func undo() async throws {
        editor.requestUndo()
        try await settle()
    }

    private func redo() async throws {
        editor.requestRedo()
        try await settle()
    }
}
