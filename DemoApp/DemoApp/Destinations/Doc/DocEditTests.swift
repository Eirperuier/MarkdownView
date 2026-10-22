//
//  DocEditTests.swift
//  DemoApp
//
//  Scripted editing against the real page: keystrokes go into the on-screen text
//  views through UIKeyInput (the keyboard's own path), and after each one the model,
//  the storage and the cursor must agree. Run with `-docDemo YES -docEditTest YES`;
//  results are printed as `DOCTEST PASS|FAIL <name>` and a `DOCTEST DONE` summary, and
//  written to doctest.log in the app's temporary folder (docTestLog).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import DocKit
import MarkdownView
import MessagingUI
import FlooDesign

/// A test's line: printed, and added to doctest.log in the app's temporary folder, for a
/// script that can't read the app's console (a simulator's app launched in the background
/// prints to no one).
func docTestLog(_ line: String) {
    print(line)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("doctest.log")
    guard let handle = try? FileHandle(forWritingTo: url) else {
        try? Data((line + "\n").utf8).write(to: url)
        return
    }
    handle.seekToEndOfFile()
    handle.write(Data((line + "\n").utf8))
    try? handle.close()
}

@MainActor
final class DocEditTests {
    private let demo: DocDemo
    private let editor: DocEditor
    /// The window's pages, when the tests run in one.
    private let pages: DocPages?
    private var passed = 0
    private var failed = 0

    init(demo: DocDemo, editor: DocEditor, pages: DocPages? = nil) {
        self.demo = demo
        self.editor = editor
        self.pages = pages
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Return at the end of every kind of block near the top, then undo: both lines
    /// must stay on screen showing their text, and undo must bring back exactly the
    /// document there was.
    private func sweepReturn() async {
        if let filter, !"Return at the end of".contains(filter) { return }
        editor.resetDocument()
        try? await Task.sleep(for: .milliseconds(300))
        let targets = demo.doc.blocks.prefix(40).enumerated().filter { $0.element.kind.allowsMarks }.map(\.offset)
        for index in targets {
            editor.resetDocument()
            try? await Task.sleep(for: .milliseconds(250))
            let before = demo.doc.blocks.map { ($0.kind, $0.indent, $0.text.string) }
            let block = demo.doc.blocks[index]
            let name = "Return at the end of \(block.kind) “\(block.text.string.prefix(12))”"
            do {
                try await focus(block.id, at: block.text.length)
                try await enter()
                // A quote takes Return as a line break of its own (tested below).
                let isQuote = if case .quote = block.kind { true } else { false }
                let next = isQuote ? block : try blockAfter(block.id)
                try expect(text(block.id) == block.text.string + (isQuote ? "\n" : ""), "block changed to \(text(block.id).prefix(20).debugDescription)")
                try await showsModelSoon(block.id)
                try await showsModelSoon(next.id)
                try await rowsAround(index)
                try await undo()
                try await rowsAround(index)
                let after = demo.doc.blocks.map { ($0.kind, $0.indent, $0.text.string) }
                try expect(after.count == before.count && zip(after, before).allSatisfy { $0 == $1 }, "undo left \(after.count) blocks, had \(before.count)")
                try showsModel(block.id)
                // Return, Backspace, Return: the row after it goes and comes back.
                try await focus(block.id, at: block.text.length)
                try await enter()
                try await backspace()
                try await enter()
                try? await Task.sleep(for: .milliseconds(700))
                try showsModel(block.id)
                if !isQuote { try showsModel(try blockAfter(block.id).id) }
                passed += 1
                docTestLog("DOCTEST PASS \(name)")
            } catch {
                failed += 1
                docTestLog("DOCTEST FAIL \(name): \(error)")
            }
        }
    }

    /// Every row near the edit is laid out with a height (a row measured at zero is
    /// a block that vanished from the page).
    private func rowsAround(_ index: Int) async throws {
        try? await Task.sleep(for: .milliseconds(150))
        let rows = demo.rows
        guard let position = rows.firstIndex(where: { $0.block == demo.doc.blocks[index].id }) else { return }
        for row in rows[max(0, position - 2)..<min(rows.count, position + 4)] {
            let frame = demo.rowFrame(row.id)
            try expect((frame?.height ?? 0) > 1, "row \(row.blocks.first?.source.prefix(16) ?? "") has frame \(String(describing: frame))")
        }
    }

    /// The block's row is on screen with a height and shows the model's text.
    private func showsModel(_ id: DocBlockID) throws {
        guard let block = demo.doc.block(id) else { throw Failure(description: "block gone") }
        guard let view = editor.textView(for: id) else { throw Failure(description: "no text view for \(block.kind) \(block.text.string.prefix(12).debugDescription)") }
        try expect(view.bounds.height > 1, "\(block.kind) row has no height")
        try expect(editor.textStart(in: view, block: block) != nil, "\(block.kind) shows \((view.text ?? "").prefix(20).debugDescription), model \(block.text.string.prefix(20).debugDescription)")
        try drawn(view, block)
    }

    /// `showsModel`, allowing the list's fade-in of a row (under half a second).
    private func showsModelSoon(_ id: DocBlockID) async throws {
        for _ in 0..<12 {
            if (try? showsModel(id)) != nil { return }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try showsModel(id)
    }

    /// The text is actually visible: no hidden or transparent view on the way up, and
    /// the characters aren't drawn in a clear color (the reveal's hidden state).
    private func drawn(_ view: UITextView, _ block: DocBlock) throws {
        var ancestor: UIView? = view
        while let current = ancestor {
            try expect(!current.isHidden && current.alpha > 0.01 && current.layer.opacity > 0.01,
                       "\(block.kind) hidden at \(Swift.type(of: current)) alpha=\(current.alpha) opacity=\(current.layer.opacity) hidden=\(current.isHidden)")
            ancestor = current.superview
        }
        guard !block.text.isEmpty, let storage = view.attributedText, storage.length > 0 else { return }
        let index = storage.length - 1
        let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
        var alpha: CGFloat = 1
        color?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        try expect(alpha > 0.01, "\(block.kind) text drawn with alpha \(alpha)")
        // TextKit 2 lays out lazily: an empty layout means nothing gets drawn.
        if let layout = view.textLayoutManager {
            var fragments = 0
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { _ in
                fragments += 1
                return true
            }
            try expect(fragments > 0, "\(block.kind) has no laid-out text")
        }
    }

    func run() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("doctest.log"))
        await test("Return, Backspace, Return at a person's pace keeps the line on screen") {
            let block = try self.block("The trap is timing")
            try await self.focus(block.id, at: block.text.length)
            for step in 0..<3 {
                try? await Task.sleep(for: .milliseconds(1500))
                if step == 1 { try await self.backspace() } else { try await self.enter() }
                try? await Task.sleep(for: .milliseconds(1500))
                try self.showsModel(block.id)
                if let next = try? self.blockAfter(block.id) { try self.showsModel(next.id) }
            }
        }
        await sweepReturn()
        await test("Return on the last line on screen scrolls only so far that the new line shows, not to the middle") {
            let block = try self.block("Loading older")
            await self.bringIntoView(block.id)
            let text = try self.expectValue(self.editor.textView(for: block.id), "no text view")
            let list = try self.expectValue(DocScrolling.list(of: text), "no list")
            try? await Task.sleep(for: .milliseconds(600))
            // The line's last line at the bottom of what shows.
            let visible = DocScrolling.visible(in: list)
            let bottom = text.convert(text.bounds, to: list).maxY
            list.setContentOffset(CGPoint(x: list.contentOffset.x, y: list.contentOffset.y + bottom - visible.maxY + 4), animated: false)
            try? await Task.sleep(for: .milliseconds(300))
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            try? await Task.sleep(for: .milliseconds(1000))
            let next = try self.blockAfter(block.id)
            let line = try self.expectValue(self.editor.textView(for: next.id), "the new line isn't shown")
            let frame = line.convert(line.bounds, to: list)
            let shown = DocScrolling.visible(in: list)
            try self.expect(frame.minY >= shown.minY && frame.maxY <= shown.maxY, "the new line \(frame) isn't on screen \(shown)")
            try self.expect(frame.maxY > shown.maxY - 120, "the new line went to \(frame.maxY - shown.minY) of \(shown.height): moved to the middle")
        }
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
        await test("Backspace at the start of an indented paragraph steps it out a level; at the page's edge it joins the one before") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 7)
            try await self.enter()
            let next = try self.blockAfter(block.id)
            try await self.type("\t")
            try self.expect(self.demo.doc.block(next.id)?.indent == block.indent + 1, "Tab: indent \(String(describing: self.demo.doc.block(next.id)?.indent))")
            try await self.backspace()
            try self.expect(self.demo.doc.block(next.id)?.indent == block.indent, "backspace: indent \(String(describing: self.demo.doc.block(next.id)?.indent))")
            try self.expectCursor(next.id, 0)
            try await self.backspace()
            try self.expect(self.demo.doc.block(next.id) == nil, "the second backspace didn't join it")
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
        await test("A click puts the caret where it is and the page stays: on a table's cell, beside a line's text") {
            @MainActor func list() throws -> UIScrollView {
                try self.expectValue(self.editor.allTextViews.lazy.compactMap { DocScrolling.list(of: $0) }.first, "no list")
            }
            /// The block on screen above the middle (where a scroll leaves it, not centred),
            /// the page at rest: where the page is.
            @MainActor func placed(_ id: DocBlockID) async throws -> CGFloat {
                await self.bringIntoView(id)
                let list = try list()
                // Its scroll there has come to rest (it eases out for a while).
                var last = list.contentOffset.y
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if list.contentOffset.y == last { break }
                    last = list.contentOffset.y
                }
                list.setContentOffset(CGPoint(x: list.contentOffset.x, y: list.contentOffset.y + 120), animated: false)
                try? await Task.sleep(for: .milliseconds(300))
                return list.contentOffset.y
            }
            @MainActor func stays(_ before: CGFloat, _ what: String) async throws {
                try? await Task.sleep(for: .milliseconds(700))
                let after = try list().contentOffset.y
                try self.expect(abs(after - before) < 0.5, "\(what): the page moved \(after - before)")
            }
            let table = try self.expectValue(self.demo.doc.blocks.first { if case .database = $0.kind { true } else { false } }, "no table")
            let database = try self.expectValue(table.kind.databaseID.flatMap { self.demo.doc.databases[$0] }, "no database")
            var y = try await placed(table.id)
            self.editor.tables.tapped(DocTableSnapshot(block: table.id, database: database), at: MarkdownTableCellPosition(row: 2, column: 1))
            try await stays(y, "a cell")
            try self.expect(self.editor.tables.editing == DocCellKey(block: table.id, row: database.rows[1].id, column: database.columns[1].id), "the cell isn't edited")
            let block = try self.block("Loading older")
            y = try await placed(block.id)
            let view = try self.expectValue(self.editor.textView(for: block.id), "no text view")
            let below = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.maxY + 2), to: nil)
            self.editor.click(block.id, at: below)
            try await stays(y, "beside a line")
            try self.expect(self.editor.selection?.head.block == block.id, "the caret isn't in the line")
        }
        await test("A click before an empty list item's text puts the caret after its marker") {
            let item = try self.block("行首输入")
            try await self.focus(item.id, at: item.text.length)
            try await self.enter()
            let next = try self.blockAfter(item.id)
            let view = try self.view()
            @MainActor func drawnAfterMarker(_ when: String) throws {
                let caret = view.caretRect(for: view.selectedTextRange!.start)
                let lineStart = view.caretRect(for: view.beginningOfDocument)
                try self.expect(caret.minX > lineStart.minX + 4, "\(when): caret drawn at x=\(caret.minX), line starts at \(lineStart.minX)")
            }
            try drawnAfterMarker("after Return")
            view.selectedRange = NSRange(location: 0, length: 0)
            try await self.settle()
            let start = try self.expectValue(self.editor.textStart(in: view, block: next), "not in sync")
            try self.expect(view.selectedRange.location == start + 1, "caret at \(view.selectedRange.location), text starts at \(start)")
            try drawnAfterMarker("after a click")
            try await self.type("x")
            try self.expect(self.text(next.id) == "x", "typed \(self.text(next.id).debugDescription)")
        }
        for prefix in ["编号也一样", "行首输入", "嵌套列表", "Loading older"] {
            await test("A click right of “\(prefix)” (outside its text) puts the caret at the end of the line") {
                let block = try self.block(prefix)
                await self.bringIntoView(block.id)
                let view = try self.expectValue(self.editor.textView(for: block.id), "no text view")
                view.resignFirstResponder()
                await self.rest(view)
                let lastLine = view.caretRect(for: view.endOfDocument)
                let inView = CGPoint(x: max(lastLine.maxX + 40, view.bounds.maxX + 20), y: lastLine.midY)
                var point = view.convert(inView, to: nil)
                // On a narrow screen the line can reach the edge: stay inside the window.
                point.x = min(point.x, (view.window?.bounds.maxX ?? point.x) - 8)
                // On the Mac the first click selects the block; its row takes the next.
                if DocBlockController.usesHandles {
                    self.editor.blocks.click(atWindowPoint: point)
                    try self.expect(self.editor.blocks.selected.first == block.id, "the first click didn't select the block")
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // Outside the text the click is the list's (DocBlockController.rowClick);
                // on the text view, the text view's own.
                let hit = sequence(first: view.window?.hitTest(point, with: nil), next: { $0?.superview })
                if hit.contains(where: { $0 is UITextView }) {
                    try await self.focus(block.id, at: block.text.length)
                } else {
                    self.editor.blocks.click(atWindowPoint: point)
                }
                try await self.settle()
                try self.expectCursor(block.id, block.text.length)
                try await self.type("x")
                try self.expect(self.text(block.id) == block.text.string + "x", "typed into \(self.text(block.id).suffix(8).debugDescription)")
            }
        }
        await test("Return in a quote breaks the line inside the same quote") {
            let quote = try self.block("Never set the offset")
            try await self.focus(quote.id, at: 9)
            try await self.enter()
            try self.expect(self.demo.doc.blocks.count == self.blockCountAtStart, "blocks \(self.demo.doc.blocks.count)")
            try self.expect(self.text(quote.id) == "Never set\n the offset" + quote.text.string.dropFirst(20), "text \(self.text(quote.id).prefix(24).debugDescription)")
            try self.expectCursor(quote.id, 10)
            try await self.type("x")
            try self.expect(self.text(quote.id).hasPrefix("Never set\nx the"), "typed \(self.text(quote.id).prefix(20).debugDescription)")
            try await self.showsModelSoon(quote.id)
        }
        await test("Return at a quote's end opens an empty line in it; Backspace takes it back, no blank line left") {
            let quote = try self.block("Never set the offset")
            try await self.focus(quote.id, at: quote.text.length)
            try await self.enter()
            try self.expect(self.text(quote.id) == quote.text.string + "\n", "text ends \(self.text(quote.id).suffix(6).debugDescription)")
            try self.expectCursor(quote.id, quote.text.length + 1)
            try await self.showsModelSoon(quote.id)
            try await self.type("y")
            try self.expect(self.text(quote.id) == quote.text.string + "\ny", "typed \(self.text(quote.id).suffix(6).debugDescription)")
            try await self.backspace()
            try await self.backspace()
            try self.expect(self.text(quote.id) == quote.text.string, "after backspaces \(self.text(quote.id).suffix(6).debugDescription)")
            try self.expect(self.demo.doc.blocks.count == self.blockCountAtStart, "blocks \(self.demo.doc.blocks.count)")
            try self.expectCursor(quote.id, quote.text.length)
        }
        await test("Return on a quote's empty last line leaves the quote") {
            let quote = try self.block("Never set the offset")
            try await self.focus(quote.id, at: quote.text.length)
            try await self.enter()
            try await self.enter()
            try self.expect(self.text(quote.id) == quote.text.string, "quote \(self.text(quote.id).suffix(6).debugDescription)")
            let next = try self.blockAfter(quote.id)
            try self.expect(next.kind == .paragraph && next.text.isEmpty, "after the quote: \(next.kind) \(next.text.string.debugDescription)")
            try self.expectCursor(next.id, 0)
            try await self.undo()
            try self.expect(self.text(quote.id) == quote.text.string + "\n", "undo \(self.text(quote.id).suffix(6).debugDescription)")
        }
        await test("Shift-Return (the key command) breaks a paragraph's line in place") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 7)
            UIApplication.shared.sendAction(Selector(("docLineBreak:")), to: nil, from: nil, for: nil)
            try await self.settle()
            try self.expect(self.text(block.id).hasPrefix("Loading\n older"), "text \(self.text(block.id).prefix(16).debugDescription)")
            try self.expect(self.demo.doc.blocks.count == self.blockCountAtStart, "blocks \(self.demo.doc.blocks.count)")
            try self.expectCursor(block.id, 8)
            try await self.showsModelSoon(block.id)
        }
        /// A new empty paragraph after "Loading older…", focused.
        func emptyLine() async throws -> DocBlock {
            let block = try self.block("Loading older")
            await self.bringIntoView(block.id)
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            return try self.blockAfter(block.id)
        }
        await test("Text that looks like syntax shows as typed: ==this==, $5 and $6, :circle[x]") {
            let line = try await emptyLine()
            try await self.type("==hi== $5 and $6 :circle[x]")
            try self.expect(self.text(line.id) == "==hi== $5 and $6 :circle[x]", "model \(self.text(line.id).debugDescription)")
            try await self.showsModelSoon(line.id)
            let view = try self.expectValue(self.editor.textView(for: line.id), "no text view")
            try self.expect((view.text ?? "").contains("==hi== $5 and $6 :circle[x]"), "shows \((view.text ?? "").debugDescription)")
        }
        await test("a paragraph made a title takes its new size at once: all its text laid out, never over the row after it") {
            let line = try await emptyLine()
            try await self.type(String(repeating: "Words that wrap round the page ", count: 6), waitEach: false)
            try await self.showsModelSoon(line.id)
            try? await Task.sleep(for: .milliseconds(400))
            let view = try self.expectValue(self.editor.textView(for: line.id), "no text view")
            let next = try self.blockAfter(line.id).id
            let blocks = self.editor.blocks
            let before = view.bounds.height
            let began = CACurrentMediaTime()
            self.editor.keyCommand(.style(.heading(level: 1)), in: line.id)
            var trace: [String] = []
            while CACurrentMediaTime() - began < 0.7 {
                try? await Task.sleep(for: .milliseconds(8))
                let layout = try self.expectValue(view.textLayoutManager, "no TextKit 2")
                let document = layout.documentRange
                let laidOut = layout.textViewportLayoutController.viewportRange.map { layout.offset(from: document.location, to: $0.endLocation) } ?? 0
                let length = layout.offset(from: document.location, to: document.endLocation)
                let top = try self.expectValue(blocks.testShownFrame(of: view, in: line.id)?.minY, "no text drawn")
                let shown = layout.usageBoundsForTextContainer.maxY
                let nextTop = try self.expectValue(blocks.testShownRowFrame(next)?.minY, "next row not on screen")
                trace.append(String(format: "%.3f:h%.0f %d/%d over%.1f", CACurrentMediaTime() - began, view.bounds.height, laidOut, length, top + shown - nextTop))
                try self.expect(laidOut == length, "only \(laidOut) of \(length) laid out at \(view.bounds.height) high: \(trace)")
                try self.expect(top + shown <= nextTop + 1, "the text over the next row: \(trace)")
            }
            docTestLog("DOCTEST TRACE title grows " + trace.joined(separator: " "))
            try self.expect(view.bounds.height > before + 30, "at rest \(view.bounds.height) high, from \(before)")
        }
        await test("⌃6 makes the line a caption, drawn smaller; ⌃5 makes it body text again") {
            let line = try await emptyLine()
            try await self.type("Photo by me")
            @MainActor func fontSize() async throws -> CGFloat {
                try await self.showsModelSoon(line.id)
                let view = try self.expectValue(self.editor.textView(for: line.id), "no text view")
                return (view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0
            }
            let body = try await fontSize()
            self.editor.keyCommand(.style(.caption), in: line.id)
            try self.expect(self.demo.doc.block(line.id)?.kind == .caption, "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
            try await Task.sleep(for: .milliseconds(400))
            let caption = try await fontSize()
            try self.expect(caption > 0 && caption < body, "caption \(caption) body \(body)")
            self.editor.keyCommand(.style(.paragraph), in: line.id)
            try await Task.sleep(for: .milliseconds(400))
            try self.expect(self.demo.doc.block(line.id)?.kind == .paragraph && self.text(line.id) == "Photo by me", "back to \(String(describing: self.demo.doc.block(line.id)?.kind))")
            try self.expect(try await fontSize() == body, "body again is not body")
        }
        await test("A boxed line's Return stays in the box, Return on the empty line leaves it; the box pads the row") {
            let line = try await emptyLine()
            try await self.type("Boxed")
            try await Task.sleep(for: .milliseconds(300))
            let plain = try self.expectValue(self.demo.rowFrame(line.id.description), "no row").height
            self.editor.setDecoration(.block, of: [line.id])
            try await Task.sleep(for: .milliseconds(400))
            let boxed = try self.expectValue(self.demo.rowFrame(line.id.description), "no row").height
            try self.expect(boxed >= plain + 15, "row \(plain) → \(boxed) with its box")
            try self.expectCursor(line.id, 5)
            try await self.enter()
            let next = try self.blockAfter(line.id)
            try self.expect(next.decoration == .block, "the new line is \(String(describing: next.decoration))")
            try await self.enter()
            try self.expect(self.demo.doc.block(next.id)?.decoration == nil && self.demo.doc.blocks.contains { $0.id == next.id },
                            "Return on the empty line: \(String(describing: self.demo.doc.block(next.id)?.decoration)) cursor \(String(describing: self.editor.selection?.head)) line \(line.id) next \(next.id) after: \(self.demo.doc.blocks.drop { $0.id != line.id }.prefix(4).map { "\($0.text.string.debugDescription) \(String(describing: $0.decoration))" })")
            try self.expect(self.demo.doc.block(line.id)?.decoration == .block, "the line left its box")
            try await self.undo()
            try self.expect(self.demo.doc.block(next.id)?.decoration == .block, "undo: \(String(describing: self.demo.doc.block(next.id)?.decoration))")
        }
        await test("A block's font: its text drawn in it, Return carries it to the new line, its tile again takes it off; each one undo step") {
            let line = try await emptyLine()
            try await self.type("Serif")
            DocFormatting(editor: self.editor).setFont(.serif)
            try self.expect(self.demo.doc.block(line.id)?.font == .serif, "font \(String(describing: self.demo.doc.block(line.id)?.font))")
            try await Task.sleep(for: .milliseconds(400))
            let view = try self.expectValue(self.editor.textView(for: line.id), "no text view")
            let drawn = view.textStorage.length > 0 ? view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
            let serif = UIFont.systemFont(ofSize: 17).fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 17).familyName }
            try self.expect(drawn?.familyName == serif, "drawn in \(String(describing: drawn?.familyName)), not \(String(describing: serif))")
            self.editor.toggle(.bold, over: 0..<5, in: line.id)
            try await Task.sleep(for: .milliseconds(400))
            let bold = self.editor.textView(for: line.id).flatMap { $0.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont }
            try self.expect(bold?.familyName == serif && bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true,
                            "bold drawn in \(String(describing: bold?.fontName))")
            self.editor.toggle(.bold, over: 0..<5, in: line.id)
            try self.expect(self.demo.doc.block(line.id)?.text.marks.isEmpty == true, "still bold")
            try await self.enter()
            let next = try self.blockAfter(line.id)
            try self.expect(next.font == .serif, "the new line is in \(String(describing: next.font))")
            DocFormatting(editor: self.editor).setFont(.serif)
            try self.expect(self.demo.doc.block(next.id)?.font == nil, "pressed again: \(String(describing: self.demo.doc.block(next.id)?.font))")
            try await self.undo()
            try self.expect(self.demo.doc.block(next.id)?.font == .serif, "undo: \(String(describing: self.demo.doc.block(next.id)?.font))")
        }
        if DocBlockController.usesHandles {
            await test("Selected text brings the toolbar after a moment; a caret or a read-only page sends it away") {
                let paragraph = try self.block("这篇文档由 DocKit")
                let toolbar = self.editor.selectionToolbar
                try await self.select(paragraph.id, 0..<4)
                try await Task.sleep(for: .milliseconds(400))
                try self.expect(toolbar.isShown, "no toolbar over the selection")
                try await self.focus(paragraph.id, at: 2)
                try self.expect(!toolbar.isShown, "the toolbar stays over a caret")
                try await self.select(paragraph.id, 0..<4)
                try await Task.sleep(for: .milliseconds(400))
                self.editor.isEditable = false
                try self.expect(!toolbar.isShown, "the toolbar stays over a read-only page")
                self.editor.isEditable = true
            }
        }
        await test("Selected text's format is one list: the menu over it and the system's Format offer the same, and what each does shows in both") {
            let paragraph = try self.block("这篇文档由 DocKit")
            let format = DocTextFormat(editor: self.editor, ranges: [(paragraph.id, 0..<4)])
            let sections = format.menuSections { nil }
            try self.expect(sections.flatMap(\.controls).map(\.id) == ["text-marks", "text-highlight", "text-color", "text-pen"]
                            && sections.flatMap(\.items).map(\.title) == ["Format Panel"], "menu \(sections.flatMap(\.controls).map(\.id))")
            // Over the text it opens as the keys alone, its last key unfolding the rest.
            var unfolded = false
            let fold = Binding { unfolded } set: { unfolded = $0 }
            let strip = format.menuSections(linkFrom: { nil }, unfolded: fold)
            try self.expect(strip.count == 1 && strip.flatMap(\.controls).map(\.id) == ["text-marks"], "strip \(strip.flatMap(\.controls).map(\.id))")
            fold.wrappedValue = true
            try self.expect(format.menuSections(linkFrom: { nil }, unfolded: fold).flatMap(\.controls).map(\.id) == ["text-marks", "text-highlight", "text-color", "text-pen"], "unfolded")
            @MainActor func system() -> [String] {
                format.systemMenu(linkFrom: UIView()).children.flatMap { ($0 as? UIMenu).map { $0.options.contains(.displayInline) ? $0.children : [$0] } ?? [$0] }
                    .map { ($0 as? UIAction).map { "\($0.title)\($0.state == .on ? "✓" : "")" } ?? ($0 as? UIMenu)?.title ?? "" }
            }
            try self.expect(system() == ["Highlight", "Bold", "Italic", "Strikethrough", "Code", "Link…", "Text Color", "Highlight Color", "Pen"], "system \(system())")
            format.toggle(.bold)
            format.setHighlight("green")
            format.setColor("blue")
            format.setPen(DocTextFormat.pens[0].mark)
            try self.expect(format.isOn(.bold) && format.highlight == .highlight(color: "green") && format.color == .color("blue") && format.pen == DocTextFormat.pens[0].mark,
                            "marks \(String(describing: self.demo.doc.block(paragraph.id)?.text.marks))")
            try self.expect(system().prefix(2) == ["Highlight✓", "Bold✓"], "system after \(system())")
            for _ in 0..<4 { try await self.undo() }
            try self.expect(self.demo.doc.block(paragraph.id)?.text == paragraph.text, "the marks didn't undo")
        }
        await test("Quotes, dashes and dots stay as typed (no smart punctuation)") {
            let line = try await emptyLine()
            try await self.type("don't say \"no\" -- wait...")
            try self.expect(self.text(line.id) == "don't say \"no\" -- wait...", "text \(self.text(line.id).debugDescription)")
            try await self.showsModelSoon(line.id)
        }
        await test("Slash menu: “/h2” and Return makes a heading 2") {
            let line = try await emptyLine()
            try await self.type("/")
            try self.expect(self.editor.slash.isOpen && self.editor.slash.items.count == DocCommand.all.count, "menu open \(self.editor.slash.isOpen) items \(self.editor.slash.items.count)")
            try await self.type("h2")
            try self.expect(self.editor.slash.highlightedItem?.id == "h2", "highlighted \(String(describing: self.editor.slash.highlightedItem?.id))")
            try self.expect(self.editor.slash.anchor.height > 0, "no anchor")
            try await self.enter()
            try self.expect(!self.editor.slash.isOpen, "menu still open")
            let block = try self.expectValue(self.demo.doc.block(line.id), "block gone")
            try self.expect(block.kind == .heading(level: 2) && block.text.isEmpty, "became \(block.kind) \(block.text.string.debugDescription)")
            try self.expectCursor(line.id, 0)
            try await self.type("T")
            try self.expect(self.text(line.id) == "T", "typed \(self.text(line.id).debugDescription)")
        }
        await test("Slash menu: ↓↓ then Return opens the third group in its place, Return picks its first; one undo takes it back") {
            let line = try await emptyLine()
            try await self.type("/")
            for _ in 0..<2 { UIApplication.shared.sendAction(Selector(("docSlashDown:")), to: nil, from: nil, for: nil) }
            try self.expect(self.editor.slash.highlighted == 2, "highlighted \(self.editor.slash.highlighted)")
            try await self.enter()
            let group = DocCommand.all[2]
            try self.expect(self.editor.slash.isOpen && self.editor.slash.group?.id == group.id && self.editor.slash.items == group.children,
                            "group \(String(describing: self.editor.slash.group?.id)) items \(self.editor.slash.items.map(\.id))")
            try await self.enter()
            try self.expect(self.demo.doc.block(line.id)?.kind == group.children[0].action?.kind, "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
            try await self.undo()
            try self.expect(self.demo.doc.block(line.id)?.kind == .paragraph && self.text(line.id) == "/", "undo: \(String(describing: self.demo.doc.block(line.id)?.kind)) \(self.text(line.id).debugDescription)")
        }
        await test("Slash menu: Backspace in a group goes back to the top, nothing deleted; a tap outside closes it, the “/” stays") {
            let line = try await emptyLine()
            try await self.type("/")
            let style = try self.expectValue(DocCommand.all.firstIndex { $0.id == "style" }, "no Text Style")
            self.editor.slash.choose(DocCommand.all[style])
            try self.expect(self.editor.slash.group?.id == "style", "group \(String(describing: self.editor.slash.group?.id))")
            try await self.backspace()
            try self.expect(self.editor.slash.isOpen && self.editor.slash.group == nil && self.editor.slash.highlighted == style,
                            "open \(self.editor.slash.isOpen) group \(String(describing: self.editor.slash.group?.id)) highlighted \(self.editor.slash.highlighted)")
            try self.expect(self.text(line.id) == "/", "text \(self.text(line.id).debugDescription)")
            self.editor.slash.dismiss()
            try self.expect(!self.editor.slash.isOpen && self.text(line.id) == "/", "open \(self.editor.slash.isOpen) text \(self.text(line.id).debugDescription)")
        }
        await test("Slash menu: over the caret's line where it fits, else under it, never over the keyboard") {
            let room = CGRect(x: 0, y: 100, width: 400, height: 500)
            let low = FlooDesignMenuOverlay.frame(over: CGRect(x: 50, y: 520, width: 2, height: 20), in: room, rows: 12)
            try self.expect(low.maxY < 520 && low.minY >= room.minY, "low caret: \(low)")
            let high = FlooDesignMenuOverlay.frame(over: CGRect(x: 50, y: 120, width: 2, height: 20), in: room, rows: 12)
            try self.expect(high.minY > 140 && high.maxY <= room.maxY, "high caret: \(high)")
            let squeezed = FlooDesignMenuOverlay.frame(over: CGRect(x: 50, y: 200, width: 2, height: 20), in: CGRect(x: 0, y: 100, width: 400, height: 200), rows: 12)
            try self.expect(squeezed.maxY <= 300 && squeezed.minY >= 100, "squeezed: \(squeezed)")
            try self.expect(low.maxX <= room.maxX && high.minX >= room.minX, "out of the sides: \(low) \(high)")
        }
        await test("Slash menu: “/” typed shows it on the list, by the caret") {
            let block = try self.block("Loading older")
            self.editor.blocks.testCenter(block.id)
            try? await Task.sleep(for: .milliseconds(300))
            try await self.focus(block.id, at: block.text.length)
            try await self.type(" /")
            let menu = self.editor.slash
            try self.expect(menu.isOpen, "not open")
            let frame = menu.frame
            docTestLog("DOCTEST NOTE slash anchor \(menu.anchor) room \(menu.room) frame \(frame)")
            try self.expect(!frame.isNull && frame.height > 40 && menu.room.contains(frame), "frame \(frame) in room \(menu.room)")
            // The page holds still while it's open.
            let list = try self.expectValue(self.editor.textView(for: block.id).flatMap(DocScrolling.list), "no list")
            try self.expect(!list.isScrollEnabled, "the page scrolls under the menu")
            // A group's commands take its place under its title, the menu taking their
            // size from the caret's side: the edge by the caret and the leading edge stay.
            menu.choose(DocCommand.all[0])
            let caretSide = frame.maxY <= menu.anchor.minY ? \CGRect.maxY : \CGRect.minY
            try self.expect(menu.group != nil && menu.frame.minX == frame.minX && menu.frame[keyPath: caretSide] == frame[keyPath: caretSide],
                            "a group moved it: \(menu.frame) from \(frame)")
            // Esc goes back to the top first, then closes.
            UIApplication.shared.sendAction(Selector(("docSlashClose:")), to: nil, from: nil, for: nil)
            try self.expect(menu.isOpen && menu.group == nil && menu.frame == frame, "Esc in a group: open \(menu.isOpen) group \(String(describing: menu.group?.id)) frame \(menu.frame)")
            UIApplication.shared.sendAction(Selector(("docSlashClose:")), to: nil, from: nil, for: nil)
            try self.expect(list.isScrollEnabled, "the page doesn't scroll again")
            try await self.undo()
        }
        await test("Slash menu: Esc closes it, the “/” stays, Return is Return again") {
            let line = try await emptyLine()
            try await self.type("/")
            UIApplication.shared.sendAction(Selector(("docSlashClose:")), to: nil, from: nil, for: nil)
            try self.expect(!self.editor.slash.isOpen, "still open")
            try self.expect(self.text(line.id) == "/", "text \(self.text(line.id).debugDescription)")
            try await self.enter()
            try self.expect(self.text(line.id) == "/", "Return changed the line to \(self.text(line.id).debugDescription)")
            _ = try self.blockAfter(line.id)
        }
        await test("Slash menu: “、” (the slash key with a Chinese input method) opens it too") {
            let line = try await emptyLine()
            try await self.type("、yin")
            try self.expect(self.editor.slash.highlightedItem?.id == "quote", "highlighted \(String(describing: self.editor.slash.highlightedItem?.id))")
            try await self.enter()
            try self.expect(self.demo.doc.block(line.id)?.kind == .quote && self.text(line.id).isEmpty, "\(String(describing: self.demo.doc.block(line.id)?.kind)) \(self.text(line.id).debugDescription)")
        }
        await test("Slash menu: a pinyin query filters while it's composed, and survives the menu's updates") {
            let line = try await emptyLine()
            try await self.type("/")
            let view = try self.view()
            view.setMarkedText("bi'ao", selectedRange: NSRange(location: 5, length: 0))
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(view.markedTextRange != nil, "the marked text is gone: \((view.text ?? "").debugDescription)")
            try self.expect(self.editor.slash.highlightedItem?.id == "h1", "highlighted \(String(describing: self.editor.slash.highlightedItem?.id)) items \(self.editor.slash.items.map(\.id))")
            view.unmarkText()
            try await self.settle()
            try self.expect(self.text(line.id) == "/bi'ao", "committed \(self.text(line.id).debugDescription)")
        }
        await test("Slash menu: a space closes it; after a word it opens too, and closes once nothing matches") {
            let line = try await emptyLine()
            try await self.type("/x ")
            try self.expect(!self.editor.slash.isOpen, "open after a space")
            try await self.type("a/")
            try self.expect(self.editor.slash.isOpen, "not open after a letter")
            try await self.type("zq")
            try self.expect(!self.editor.slash.isOpen, "open with nothing matching")
            try self.expect(self.text(line.id) == "/x a/zq", "text \(self.text(line.id).debugDescription)")
        }
        await test("Slash menu: “/分割” or a click on 分割线 puts a divider in, the caret below it") {
            let line = try await emptyLine()
            try await self.type("/divider")
            try self.expect(self.editor.slash.items.map(\.id) == ["divider"], "items \(self.editor.slash.items.map(\.id))")
            self.editor.slash.choose(self.editor.slash.items[0])
            try await self.settle()
            try self.expect(self.demo.doc.block(line.id)?.kind == .divider, "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
            let next = try self.blockAfter(line.id)
            try self.expect(next.kind == .paragraph && next.text.isEmpty, "after: \(next.kind)")
            try self.expectCursor(next.id, 0)
        }
        await test("Slash menu: a source's image and file go in where the slash was, kept by their content, the caret below; one undo takes them out") {
            let source = DocTestInsertSource { [Self.pickedImage(), Self.pickedText()] }
            DocInsertSources.all.append(source)
            defer { DocInsertSources.all.removeAll { $0.id == source.id } }
            let line = try await emptyLine()
            let count = self.demo.doc.blocks.count
            try await self.type("/testsource")
            try self.expect(self.editor.slash.items.map(\.id) == [source.id], "items \(self.editor.slash.items.map(\.id))")
            try await self.enter()
            await self.editor.inserting?.value
            try await self.settle()
            guard case .image(let image)? = self.demo.doc.block(line.id)?.kind else { throw Failure(description: "line is \(String(describing: self.demo.doc.block(line.id)?.kind))") }
            let ref = try self.expectValue(DocBlobRef(source: image.source), "source \(image.source)")
            try self.expect(image.alt == "Picked", "alt \(image.alt)")
            try self.expect(image.width == 300 && image.height == 200 && image.blurHash.flatMap(DocBlobImages.blur) != nil,
                            "kept \(String(describing: image.width)) × \(String(describing: image.height)) \(String(describing: image.blurHash))")
            // The block's size lays it out though its picture isn't here.
            let away = DocImage(source: "blob:sha256:" + String(repeating: "0", count: 64), width: 400, height: 100, blurHash: image.blurHash)
            try self.expect(DocMediaLayout.imageBox(away, width: 720) == CGSize(width: 400, height: 100), "away \(DocMediaLayout.imageBox(away, width: 720))")
            let file = try self.blockAfter(line.id)
            guard case .file(let attached) = file.kind else { throw Failure(description: "after the image: \(file.kind)") }
            try self.expect(attached.name == "notes.txt" && attached.size == Self.notes.utf8.count && DocBlobRef(source: attached.source) != nil,
                            "file \(attached)")
            let next = try self.blockAfter(file.id)
            try self.expect(next.kind == .paragraph && next.text.isEmpty, "after the file: \(next.kind)")
            try self.expectCursor(next.id, 0)
            // The same content is the same ref, kept once.
            let again = try await DocBlobs.store.put(Self.writePNG(), type: .png)
            try self.expect(again.ref == ref, "kept again as \(again.ref.hex)")
            let kept = try await DocBlobs.store.file(for: ref)
            try self.expect(DocBlobImages.reads(kept), "kept file isn't the image")
            try await self.undo()
            try self.expect(self.demo.doc.blocks.count == count && self.demo.doc.block(line.id)?.kind == .paragraph && self.text(line.id) == "/testsource",
                            "after undo: \(self.demo.doc.blocks.count) blocks, \(String(describing: self.demo.doc.block(line.id)?.kind)) \(self.text(line.id).debugDescription)")
        }
        await test("Slash menu: a source after text puts what's picked after the line; nothing picked takes only the “/query”") {
            var picks: [DocPicked] = []
            let source = DocTestInsertSource { picks }
            DocInsertSources.all.append(source)
            defer { DocInsertSources.all.removeAll { $0.id == source.id } }
            let line = try await emptyLine()
            try await self.type("abc /testsource")
            try await self.enter()
            await self.editor.inserting?.value
            try await self.settle()
            try self.expect(self.text(line.id) == "abc " && self.demo.doc.block(line.id)?.kind == .paragraph, "cancelled: \(self.text(line.id).debugDescription)")
            try self.expectCursor(line.id, 4)
            picks = [Self.pickedImage()]
            try await self.type("/testsource")
            try await self.enter()
            await self.editor.inserting?.value
            try await self.settle()
            try self.expect(self.text(line.id) == "abc ", "line \(self.text(line.id).debugDescription)")
            let image = try self.blockAfter(line.id)
            guard case .image = image.kind else { throw Failure(description: "after the line: \(image.kind)") }
            try self.expectCursor(line.id, 4)
        }
        await test("Slash menu after text keeps the text: “abc /quote” makes a quote of “abc ”") {
            let line = try await emptyLine()
            try await self.type("abc /quote")
            try self.expect(self.editor.slash.highlightedItem?.id == "quote", "highlighted \(String(describing: self.editor.slash.highlightedItem?.id))")
            try await self.enter()
            try self.expect(self.demo.doc.block(line.id)?.kind == .quote && self.text(line.id) == "abc ", "\(String(describing: self.demo.doc.block(line.id)?.kind)) \(self.text(line.id).debugDescription)")
            try self.expectCursor(line.id, 4)
        }
        // MARK: Typing speed

        await test("Resizing: each width the list goes through measures only the rows on screen, in their own cells") {
            let blocks = self.editor.blocks
            blocks.testCenter(try self.block("The trap is timing").id)
            try? await Task.sleep(for: .milliseconds(300))
            let width = try self.expectValue(blocks.testListWidth, "no list")
            let widths = (1...30).map { width - CGFloat($0) * 8 }
            defer { _ = blocks.testResize(through: [width]) }
            _ = blocks.testResize(through: widths + [width])
            let probe = TiledCellHeightProbe.shared
            probe.isEnabled = true
            probe.reset()
            let (times, arrived) = blocks.testResize(through: widths)
            let built = probe.snapshot().sizingCellMeasureCount
            probe.isEnabled = false
            let median = times.sorted()[times.count / 2]
            docTestLog("DOCPERF resize step (ms): median \(String(format: "%.1f", median)) max \(String(format: "%.1f", times.max() ?? 0)), \(built) built, \(arrived) arrived")
            // Only the rows on screen are measured at each width, in their own cells: a row is
            // built to be measured only as it comes on screen, not every row at every width
            // (that, and measuring rows off screen, took a frame).
            try self.expect(built < widths.count, "\(built) rows built to measure them in \(widths.count) widths, \(arrived) came on screen")
            // Once the width rests, the rest converge: rows anywhere show their contents' height.
            try? await Task.sleep(for: .seconds(1))
            for row in [self.demo.rows.first, self.demo.rows.last] {
                let id = try self.expectValue(row?.block, "no block row")
                blocks.testCenter(id)
                try? await Task.sleep(for: .milliseconds(300))
                let misfits = blocks.testMisfitRows
                try self.expect(misfits.isEmpty, "after resizing: \(misfits)")
            }
        }
        await test("Typing speed: keystrokes in a long paragraph render within a frame or two") {
            let block = try self.block("The trap is timing")
            // A long paragraph: the block's text four times.
            let long = String(repeating: block.text.string + " ", count: 4)
            _ = self.demo.edit([.insertText(block: block.id, at: block.text.length, text: DocText(string: " " + long))], before: nil, after: nil)
            try await self.focus(block.id, at: self.demo.doc.block(block.id)?.text.length ?? 0)
            try await self.settle()
            var publish: [Double] = []
            var rows: [Double] = []
            var total: [Double] = []
            var frames: [Double] = []
            for character in "abcdefghijklmnopqrstuvwxyz" {
                let start = CFAbsoluteTimeGetCurrent()
                var handled = 0.0
                var failure: Error?
                frames.append(await self.frameTime {
                    do { try self.key(String(character)) } catch { failure = error }
                    handled = (CFAbsoluteTimeGetCurrent() - start) * 1000
                })
                if let failure { throw failure }
                publish.append(handled)
                rows.append(self.demo.lastPublishMs)
                for _ in 0..<60 {
                    if self.editor.mismatch() == nil { break }
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(1))
                }
                total.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            docTestLog("DOCPERF keystroke (ms): rows \(String(format: "%.1f", median(rows))); handling median \(String(format: "%.1f", median(publish))) max \(String(format: "%.1f", publish.max() ?? 0)); on screen median \(String(format: "%.1f", median(total))) max \(String(format: "%.1f", total.max() ?? 0)); frame median \(String(format: "%.1f", median(frames))) max \(String(format: "%.1f", frames.max() ?? 0)); text \(self.text(block.id).count) chars, \(self.demo.doc.blocks.count) blocks")
            try self.expect(median(total) < 50, "median \(median(total)) ms")
        }

        // MARK: Links

        await test("Links: a link on the selection exports as markdown; one undo removes it; nil removes it too") {
            let block = try self.block("Loading older")
            self.editor.setLink("https://example.com", over: 0..<7, in: block.id)
            try self.expect((self.demo.doc.markdown(of: block.id) ?? "").hasPrefix("[Loading](https://example.com) older"), "markdown \(String(describing: self.demo.doc.markdown(of: block.id)?.prefix(40)))")
            try self.expect(self.editor.link(over: 0..<7, in: self.demo.doc.block(block.id)!) == "https://example.com", "link")
            try await self.undo()
            try self.expect(self.demo.doc.block(block.id)?.text == block.text, "undo left \(String(describing: self.demo.doc.block(block.id)?.text.marks)) (had \(block.text.marks))")
            self.editor.setLink("https://example.com", over: 0..<7, in: block.id)
            self.editor.setLink(nil, over: 0..<7, in: block.id)
            try self.expect(self.demo.doc.block(block.id)?.text == block.text, "removing left \(String(describing: self.demo.doc.block(block.id)?.text.marks))")
        }
        await test("Links: pasting a web address over selected text links it; elsewhere it's text") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: 0)
            let view = try self.view()
            let start = try self.expectValue(self.editor.textStart(in: view, block: block), "not in sync")
            self.editor.replace(NSRange(location: start, length: 7), with: "https://floo.app/x", in: view, block: block.id)
            try self.expect(self.text(block.id) == block.text.string, "text changed: \(self.text(block.id).prefix(20).debugDescription)")
            try self.expect(self.editor.link(over: 0..<7, in: self.demo.doc.block(block.id)!) == "https://floo.app/x", "not linked")
            try self.expect(DocEditor.webAddress("not a url") == nil && DocEditor.webAddress("ftp://x") == nil && DocEditor.webAddress(" https://a.b/c ") == "https://a.b/c", "webAddress")
        }
        await test("Markdown pasted into a line is its blocks: the words before the cursor start the first, those after end the last; a page in it opens a copy; one undo each") {
            try self.expect(!DocEditor.isMarkdown("plain words") && !DocEditor.isMarkdown("one\ntwo") && DocEditor.isMarkdown("one\n\ntwo")
                            && DocEditor.isMarkdown("## Title") && DocEditor.isMarkdown("1. first") && !DocEditor.isMarkdown("#hashtag"), "isMarkdown")
            let block = try self.block("Loading older")
            let before = self.demo.doc.blocks.map(\.id)
            try await self.focus(block.id, at: 7)
            let view = try self.view()
            let start = try self.expectValue(self.editor.textStart(in: view, block: block), "not in sync")
            self.editor.replace(NSRange(location: start + 7, length: 0), with: "**one**\n\n# Two\n\n- three", in: view, block: block.id)
            let index = try self.expectValue(self.demo.doc.blocks.firstIndex { $0.id == block.id }, "the line went")
            let lines = Array(self.demo.doc.blocks[index...].prefix(3))
            try self.expect(lines.map(\.text.string) == ["Loadingone", "Two", "three" + block.text.string.dropFirst(7)], "lines \(lines.map(\.text.string))")
            try self.expect(lines[0].kind == block.kind && lines[0].text.marks.contains { $0.range == 7..<10 && $0.mark == .bold }, "the first line: \(lines[0].kind), \(lines[0].text.marks)")
            if case .heading = lines[1].kind {} else { throw Failure(description: "not a heading: \(lines[1].kind)") }
            if case .listItem = lines[2].kind {} else { throw Failure(description: "not a list item: \(lines[2].kind)") }
            try self.expect(self.editor.selection?.head == DocPosition(block: lines[2].id, offset: 5), "cursor at \(String(describing: self.editor.selection?.head))")
            try await self.undo()
            try self.expect(self.demo.doc.blocks.map(\.id) == before && self.demo.doc.block(block.id)?.text == block.text, "the paste didn't undo")
            // A page block copied and pasted opens a page of its own.
            let pageBlock = try self.expectValue(self.demo.doc.blocks.first { if case .page = $0.kind { true } else { false } }, "no page block")
            guard case .page(let page) = pageBlock.kind else { return }
            let fence = try self.expectValue(self.demo.doc.markdown(of: pageBlock.id), "no markdown")
            try await self.focus(block.id, at: block.text.length)
            let end = try self.expectValue(self.editor.textStart(in: try self.view(), block: block), "not in sync") + block.text.length
            self.editor.replace(NSRange(location: end, length: 0), with: fence, in: try self.view(), block: block.id)
            let pasted = try self.expectValue(self.demo.doc.blocks.dropFirst(index + 1).first, "nothing pasted")
            guard case .page(let copy) = pasted.kind else { throw Failure(description: "not a page: \(pasted.kind)") }
            try self.expect(copy.doc != page.doc && copy.title == page.title, "the pasted page: \(copy.doc == page.doc ? "the same page" : copy.title)")
            try await self.undo()
            try self.expect(self.demo.doc.blocks.map(\.id) == before, "the page paste didn't undo")
        }

        // MARK: Code and math

        func firstBlock(_ match: (BlockKind) -> Bool) throws -> DocBlock {
            try self.expectValue(self.demo.doc.blocks.first { match($0.kind) }, "no such block")
        }
        func codeBlock() throws -> DocBlock { try firstBlock { if case .code = $0 { true } else { false } } }
        func sourceEditor(_ block: DocBlockID, step: String = "") async throws -> DocSourceTextView {
            for _ in 0..<60 {
                if let view = self.editor.sources.view(for: block), view.isFirstResponder { return view }
                try? await Task.sleep(for: .milliseconds(16))
            }
            throw Failure(description: "\(step): the block never got an editor with the focus (editing \(String(describing: self.editor.sources.editing)))")
        }
        func edit(_ block: DocBlock) async throws -> DocSourceTextView {
            self.demo.bringIntoView(block.id)
            try? await Task.sleep(for: .milliseconds(300))
            self.editor.sources.focus(block.id)
            return try await sourceEditor(block.id, step: "edit")
        }
        func press(_ view: DocSourceTextView, _ key: String) {
            if view.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: key) { view.insertText(key) }
        }
        func caret(_ view: DocSourceTextView, afterLine prefix: String) throws {
            let text = view.text as NSString
            let start = text.range(of: prefix)
            try self.expect(start.location != NSNotFound, "no line \(prefix)")
            let line = text.lineRange(for: start)
            view.selectedRange = NSRange(location: line.location + line.length - 1, length: 0)
        }

        if DocBlockController.usesHandles {
            await test("Esc in a code block ends the editing and selects the block") {
                let block = try codeBlock()
                let view = try await edit(block)
                try self.expect(self.escape(view), "no Esc command")
                try self.expect(self.editor.sources.editing == nil, "still editing")
                try self.expect(self.editor.blocks.selected == [block.id], "selected \(self.editor.blocks.selected.count)")
            }
            await test("Code block: while not selected its row takes events, for scrolling across; its text view takes no click, which selects the block") {
                let block = try codeBlock()
                self.editor.sources.endEditing()
                self.editor.blocks.clear()
                self.demo.bringIntoView(block.id)
                for _ in 0..<60 where self.editor.sources.testShownView(block.id) == nil { try? await Task.sleep(for: .milliseconds(16)) }
                let view = try self.expectValue(self.editor.sources.testShownView(block.id), "no source view on screen")
                let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                try self.expect(view.window != nil && self.editor.blocks.clickSelects(block.id), "the block takes clicks while not selected")
                try self.expect(view.hitTest(center, with: nil) == nil, "the text view takes a click while the block isn't selected")
                self.editor.blocks.select([block.id])
                try self.expect(view.hitTest(center, with: nil) != nil, "the text view takes no click while the block is selected")
                self.editor.blocks.clear()
            }
        }
        await test("Code block: its source is a place: the keyboard bar has Aa, the code's menu and ⋮ for the block") {
            let block = try codeBlock()
            _ = try await edit(block)
            for _ in 0..<30 where !(self.editor.editingPlace is DocSourcePlace) { try? await Task.sleep(for: .milliseconds(16)) }
            try self.expect((self.editor.editingPlace as? DocSourcePlace)?.block == block.id, "place \(String(describing: self.editor.editingPlace))")
            try self.expect(self.editor.keyboardBar.testItems.map(\.id) == ["format", "menu", "more", "dismiss"], "keys \(self.editor.keyboardBar.testItems.map(\.id))")
            self.editor.dismissKeyboard()
            try await self.settle()
            try self.expect(self.editor.sources.view(for: block.id)?.isFirstResponder != true, "the keyboard key left the source focused")
        }
        await test("Code block: clicking edits its source in place; typing is one undo step") {
            let block = try codeBlock()
            let view = try await edit(block)
            try self.expect(view.text == block.text.string, "editor shows \(view.text.prefix(20).debugDescription)")
            view.selectedRange = NSRange(location: 0, length: 0)
            view.insertText("// ")
            try? await Task.sleep(for: .milliseconds(150))
            let current = self.editor.sources.view(for: block.id)
            try self.expect(current === view && view.isFirstResponder, "the editor was replaced while typing (same \(current === view), focused \(view.isFirstResponder), now \(String(describing: current?.isFirstResponder)))")
            view.insertText("x")
            try self.expect(self.text(block.id).hasPrefix("// xstruct"), "model \(self.text(block.id).prefix(16).debugDescription)")
            try await self.undo()
            try self.expect(self.text(block.id) == block.text.string, "undo left \(self.text(block.id).prefix(16).debugDescription)")
            try? await Task.sleep(for: .milliseconds(150))
            let shown = self.editor.sources.view(for: block.id)
            try self.expect(shown?.text == block.text.string, "editor after undo: \(String(describing: shown?.text.prefix(12))) same view \(shown === view)")
        }
        await test("Code block: the editor is coloured from its first frame, and after an undo sets its text") {
            func colors(_ view: UITextView) -> Int {
                var colors = Set<UIColor>()
                view.textStorage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: view.textStorage.length)) { value, _, _ in
                    if let color = value as? UIColor { colors.insert(color) }
                }
                return colors.count
            }
            let block = try codeBlock()
            let view = try await edit(block)
            try self.expect(colors(view) >= 3, "plain on entry: \(colors(view)) colours")
            view.selectedRange = NSRange(location: 0, length: 0)
            view.insertText("// x ")
            try await self.undo()
            // The view takes the undone text on the row's next render, coloured as it does.
            var shown = view
            for _ in 0..<40 {
                shown = self.editor.sources.view(for: block.id) ?? view
                if shown.text == block.text.string { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            try self.expect(shown.text == block.text.string && colors(shown) >= 3, "after undo: \(colors(shown)) colours, view \(shown.text.prefix(12).debugDescription), model \(self.text(block.id).prefix(12).debugDescription)")
        }
        await test("Code block: the caret is a line of text tall, on a code line and on a blank one") {
            let block = try codeBlock()
            let view = try await edit(block)
            let font = try self.expectValue(view.font, "no font")
            let text = view.text as NSString
            let blank = text.range(of: "\n\n").location + 1
            for offset in [3, blank] {
                guard let position = view.position(from: view.beginningOfDocument, offset: offset) else { continue }
                let caret = view.caretRect(for: position)
                try self.expect(caret.height <= ceil(font.lineHeight) + 1, "caret at \(offset) is \(caret.height) tall (line \(font.lineHeight))")
            }
        }
        await test("Code block: a selection over several lines covers every line, and stops at its last line's text") {
            let block = try codeBlock()
            let view = try await edit(block)
            let text = view.text as NSString
            let start = text.range(of: "struct").location
            let end = text.range(of: "let id").location + 3
            guard let from = view.position(from: view.beginningOfDocument, offset: start),
                  let to = view.position(from: view.beginningOfDocument, offset: end),
                  let range = view.textRange(from: from, to: to)
            else { throw Failure(description: "no range") }
            let rects = view.selectionRects(for: range).map(\.rect).filter { $0.width > 0 && $0.height > 0 }
            // Every line from the first to the last is under some rect.
            let first = view.caretRect(for: from), last = view.caretRect(for: to)
            var y = first.midY
            while y < last.midY {
                try self.expect(rects.contains { $0.minY <= y && $0.maxY >= y }, "nothing selected at y \(y): \(rects)")
                y += 4
            }
            let lowest = try self.expectValue(rects.map(\.maxY).max(), "no rects")
            try self.expect(abs(lowest - last.maxY) <= 1, "selection ends at \(lowest), the last line's text at \(last.maxY)")
        }
        await test("Code block: Return keeps the indentation; Tab and Shift-Tab indent and outdent by four") {
            let block = try codeBlock()
            let view = try await edit(block)
            try caret(view, afterLine: "    private var ids")
            press(view, "\n")
            press(view, "x")
            try self.expect(self.text(block.id).contains("= [:]\n    x\n"), "model \(self.text(block.id).prefix(80).debugDescription)")
            press(view, "\t")
            try self.expect(self.text(block.id).contains("\n    x    \n"), "tab: \(self.text(block.id).prefix(80).debugDescription)")
            try caret(view, afterLine: "    private var ids")
            view.outdent()
            try self.expect(self.text(block.id).contains("\nprivate var ids"), "outdent: \(self.text(block.id).prefix(60).debugDescription)")
        }
        await test("Code block: ⌘Return leaves to the block below; ↑ on the first line to the one above") {
            let block = try codeBlock()
            let index = try self.expectValue(self.demo.doc.blocks.firstIndex { $0.id == block.id }, "index")
            _ = try await edit(block)
            self.editor.sources.leave(block.id, .below)
            try await self.settle()
            try self.expectCursor(self.demo.doc.blocks[index + 1].id, 0)
            try self.expect(self.editor.sources.editing == nil, "still editing")
            _ = try await edit(block)
            self.editor.sources.leave(block.id, .up)
            try await self.settle()
            let above = self.demo.doc.blocks[index - 1]
            try self.expectCursor(above.id, above.text.length)
        }
        await test("Code block: ``` makes one and edits it; Backspace in the empty block turns it into a paragraph") {
            let line = try await emptyLine()
            try await self.type("```")
            try self.expect(self.demo.doc.block(line.id)?.kind == .code(language: nil), "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
            let view = try await sourceEditor(line.id, step: "after ```")
            press(view, "let a = 1")
            try self.expect(self.text(line.id) == "let a = 1", "model \(self.text(line.id).debugDescription)")
            view.selectAll(nil)
            press(view, "")
            press(view, "")
            try self.expect(self.demo.doc.block(line.id)?.kind == .paragraph, "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
            try await self.settle()
            try self.expectCursor(line.id, 0)
        }
        await test("Code block: a long line runs on, never wrapping: the code scrolls sideways to the caret") {
            let block = try codeBlock()
            let view = try await edit(block)
            let height = view.bounds.height
            view.selectedRange = NSRange(location: 0, length: 0)
            view.insertText(String(repeating: "x", count: 400))
            try await self.settle()
            try self.expect(abs(view.bounds.height - height) < 1, "height \(height) → \(view.bounds.height)")
            try self.expect(view.contentSize.width > view.bounds.width + 100, "content \(view.contentSize.width) in \(view.bounds.width)")
            try self.expect(view.contentOffset.x > 0 && view.contentOffset.y == 0, "offset \(view.contentOffset)")
            try await self.undo()
        }
        await test("Code block: its menu sets the language and copies the code; the block's menu has it too") {
            let block = try codeBlock()
            _ = try await edit(block)
            let menu = self.editor.sources.codeMenu(block.id)
            try self.perform(menu, ["Language", "Python"])
            try self.expect(self.demo.doc.block(block.id)?.kind == .code(language: "python"), "kind \(String(describing: self.demo.doc.block(block.id)?.kind))")
            let languages = try self.expectValue(self.editor.sources.codeMenu(block.id).flatMap(\.items).first { $0.id == "language" }?.submenu, "no Language")
            try self.expect(languages.flatMap(\.items).filter { $0.isOn == true }.map(\.title) == ["Python"], "ticked \(languages.flatMap(\.items).filter { $0.isOn == true }.map(\.title))")
            try self.perform(menu, ["Language", "Plain Text"])
            try self.expect(self.demo.doc.block(block.id)?.kind == .code(language: nil), "kind \(String(describing: self.demo.doc.block(block.id)?.kind))")
            UIPasteboard.general.string = ""
            try self.perform(menu, ["Copy Code"])
            try self.expect(UIPasteboard.general.string == self.text(block.id), "pasteboard \(String(describing: UIPasteboard.general.string?.prefix(20)))")
            if DocBlockController.usesHandles {
                self.editor.sources.endEditing()
                self.editor.blocks.click(block.id)
                let titles = self.editor.blocks.selectionMenu().flatMap(\.items).map(\.title)
                try self.expect(titles.starts(with: ["Edit", "Language", "Copy Code"]), "block menu \(titles)")
            }
        }
        await test("Math block: “/公式” makes one; its LaTeX is edited above the rendered formula") {
            let line = try await emptyLine()
            try await self.type("/math")
            try self.expect(self.editor.slash.highlightedItem?.id == "math", "highlighted \(String(describing: self.editor.slash.highlightedItem?.id))")
            try await self.enter()
            try self.expect(self.demo.doc.block(line.id)?.kind == .math, "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
            let view = try await sourceEditor(line.id, step: "math")
            view.insertText("E = mc^2")
            try self.expect(self.text(line.id) == "E = mc^2", "model \(self.text(line.id).debugDescription)")
            try self.expect((self.demo.doc.markdown(of: line.id) ?? "").contains("$$\nE = mc^2\n$$"), "markdown")
            // A key: a fraction, the caret in its numerator; a symbol kept apart from a letter after it.
            let fraction = try self.expectValue(DocMathKey.keys.first { $0.name == "Fraction" }, "no fraction key")
            self.editor.sources.insert(fraction.snippet, caret: fraction.caret, in: line.id)
            try self.expect(self.text(line.id) == "E = mc^2\\frac{}{}" && view.selectedRange == NSRange(location: 14, length: 0),
                            "after the fraction key \(self.text(line.id).debugDescription), caret \(view.selectedRange)")
            view.insertText("x")
            view.selectedRange = NSRange(location: 14, length: 0)
            self.editor.sources.insert("\\alpha", in: line.id)
            try self.expect(self.text(line.id) == "E = mc^2\\frac{\\alpha x}{}", "after α \(self.text(line.id).debugDescription)")
            let existing = try firstBlock { $0 == .math }
            if existing.id != line.id {
                let other = try await edit(existing)
                try self.expect(other.text == existing.text.string, "existing formula shows \(other.text.debugDescription)")
            }
            // Its panel goes when the LaTeX lets the focus go (the keyboard's key, a click elsewhere).
            self.editor.dismissKeyboard()
            try await self.settle()
            try self.expect(self.editor.sources.editing == nil, "still editing \(String(describing: self.editor.sources.editing))")
        }

        // MARK: Tables

        /// The first table: its block, database, and a key maker (row 0 = header).
        func table() throws -> (block: DocBlockID, database: Database, key: (Int, Int) -> DocCellKey) {
            guard let block = self.demo.doc.blocks.first(where: { if case .database = $0.kind { true } else { false } }),
                  let id = block.kind.databaseID, let database = self.demo.doc.databases[id]
            else { throw Failure(description: "no table") }
            return (block.id, database, { row, column in
                DocCellKey(block: block.id, row: row == 0 ? nil : database.rows[row - 1].id, column: database.columns[column].id)
            })
        }
        func database() throws -> Database { try table().database }
        /// Clicks a cell (what MarkdownView's cell tap does) and waits for its editor.
        func click(_ row: Int, _ column: Int) async throws -> UITextView {
            let t = try table()
            let snapshot = DocTableSnapshot(block: t.block, database: t.database)
            self.demo.bringIntoView(t.block)
            try? await Task.sleep(for: .milliseconds(300))
            self.editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: row, column: column))
            return try await cellEditor(t.key(row, column))
        }
        func cellEditor(_ key: DocCellKey, step: String = "") async throws -> UITextView {
            for _ in 0..<60 {
                if let view = self.editor.tables.view(for: key), view.isFirstResponder { return view }
                try? await Task.sleep(for: .milliseconds(16))
            }
            let t = try table()
            let position = { (key: DocCellKey?) -> String in
                guard let key else { return "nil" }
                let r = key.row.flatMap { id in t.database.rows.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
                let c = t.database.columns.firstIndex { $0.id == key.column } ?? -1
                return "(\(r), \(c))"
            }
            let row = self.demo.rowFrame(key.block.description)
            let list = self.editor.allTextViews.compactMap { DocScrolling.list(of: $0) }.first
            throw Failure(description: "\(step): cell \(position(key)) never got an editor with the focus; editing \(position(self.editor.tables.editing)), active \(position(self.editor.tables.active)), table \(t.database.rows.count + 1)×\(t.database.columns.count); row \(String(describing: row)) visible \(String(describing: list.map { DocScrolling.visible(in: $0) })) bounds \(String(describing: list?.bounds)) view \(self.editor.tables.view(for: key) != nil) content \(String(describing: self.editor.blocks.testContentFrame(t.block)))")
        }
        /// A key as UIKit sends it: the delegate first (Tab and Return move between cells).
        func press(_ view: UITextView, _ key: String) {
            if view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange, replacementText: key) ?? true { view.insertText(key) }
        }
        func cellText(_ row: Int, _ column: Int) throws -> String {
            try self.editor.tables.text(table().key(row, column))
        }
        func editedKey() throws -> DocCellKey {
            try self.expectValue(self.editor.tables.active, "no active cell")
        }

        if DocBlockController.usesHandles {
            await test("Esc in a cell ends the editing and selects the table") {
                let view = try await click(2, 1)
                try self.expect(self.escape(view), "no Esc command")
                try self.expect(self.editor.tables.editing == nil, "still editing")
                try self.expect(self.editor.blocks.selected == [try table().block], "selected \(self.editor.blocks.selected.count)")
            }
            await test("Table: its row takes clicks while not selected (it scrolls across); the first click selects the table, the next edits the cell") {
                let t = try table()
                let snapshot = DocTableSnapshot(block: t.block, database: t.database)
                self.editor.tables.endEditing()
                self.editor.blocks.clear()
                self.demo.bringIntoView(t.block)
                try? await Task.sleep(for: .milliseconds(300))
                let row = try self.expectValue(self.demo.rows.first { $0.block == t.block }, "no row for the table")
                try self.expect(self.editor.blocks.blockTakes(t.block, editsText: row.editsText, takesClicks: row.takesClicks), "the table's row doesn't take clicks")
                self.editor.tables.clicked(snapshot, at: MarkdownTableCellPosition(row: 2, column: 1))
                try self.expect(self.editor.blocks.selected == [t.block] && self.editor.tables.editing == nil,
                                "first click: selected \(self.editor.blocks.selected.count), editing \(String(describing: self.editor.tables.editing))")
                self.editor.tables.clicked(snapshot, at: MarkdownTableCellPosition(row: 2, column: 1))
                _ = try await cellEditor(t.key(2, 1), step: "second click")
                self.editor.tables.endEditing()
            }
        }
        await test("Table: a cell is a place of its own: the keyboard bar has Aa, its menu, ⋮ (a column's name: its menu, ⋮); the menu key opens the cell's menu") {
            let bar = self.editor.keyboardBar
            let view = try await click(1, 0)
            let key = try editedKey()
            let place = try self.expectValue(self.editor.editingPlace as? DocTableCellPlace, "place \(String(describing: self.editor.editingPlace))")
            try self.expect(place.key == key, "place's cell \(place.key)")
            let expected = ["format", "menu"] + (self.editor.tables.isAvailable(.insertFormula, at: key) ? ["formula"] : []) + ["more", "dismiss"]
            try self.expect(bar.testItems.map(\.id) == expected, "keys \(bar.testItems.map(\.id)), wanted \(expected)")
            bar.testTap("menu")
            try self.expect(self.editor.tables.menu == DocTableMenuTarget(key: key), "menu \(String(describing: self.editor.tables.menu))")
            self.editor.tables.closeMenu()
            _ = view
            _ = try await click(0, 0)
            try self.expect(self.editor.editingPlace is DocTableCellPlace, "a column's name: \(String(describing: self.editor.editingPlace))")
            try self.expect(bar.testItems.map(\.id) == ["menu", "more", "dismiss"], "name's keys \(bar.testItems.map(\.id))")
            self.editor.dismissKeyboard()
            try? await Task.sleep(for: .milliseconds(100))
            try self.expect(self.editor.editingPlace == nil, "the keyboard key left \(String(describing: self.editor.editingPlace))")
        }
        await test("Table: clicking a cell edits it in place; typing changes the cell; one undo takes the typing back") {
            let view = try await click(2, 1)
            try self.expect(view.text == "6:10", "editor shows \(view.text.debugDescription)")
            press(view, "!")
            try? await Task.sleep(for: .milliseconds(100))
            try self.expect(self.editor.tables.view(for: try editedKey()) === view && view.isFirstResponder, "the editor was replaced while typing (focused \(view.isFirstResponder))")
            press(view, "?")
            try self.expect(try cellText(2, 1) == "6:10!?", "cell \(String(describing: try? cellText(2, 1)))")
            try await self.undo()
            try self.expect(try cellText(2, 1) == "6:10", "undo: \(String(describing: try? cellText(2, 1)))")
            try? await Task.sleep(for: .milliseconds(100))
            let shown = self.editor.tables.view(for: try table().key(2, 1))
            try self.expect(shown?.text == "6:10", "editor after undo \(String(describing: shown?.text)) same view \(shown === view)")
        }
        await test("Table: a cell's text takes marks as a paragraph's does: ⌘B bolds it, typing on stays bold, undo takes it back") {
            let view = try await click(2, 1)
            let key = try editedKey()
            let id = self.editor.tables.textID(key)
            let before = try database()
            view.selectedRange = NSRange(location: 0, length: 4)
            try? await Task.sleep(for: .milliseconds(50))
            self.editor.keyCommand(.bold, in: id)
            try? await Task.sleep(for: .milliseconds(100))
            let bold = DocText(string: "6:10", marks: [MarkSpan(range: 0..<4, mark: .bold)])
            let row = try self.expectValue(try database().rows.first { $0.id == key.row }, "no row")
            try self.expect(row.cells[key.column] == .richText(text: bold), "cell \(String(describing: row.cells[key.column]))")
            let shown = try self.expectValue(self.editor.tables.view(for: key), "no editor")
            let font = shown.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            try self.expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true, "the editor shows \(String(describing: font))")
            shown.selectedRange = NSRange(location: 4, length: 0)
            try? await Task.sleep(for: .milliseconds(50))
            press(shown, "!")
            try self.expect(self.editor.tables.docText(key) == DocText(string: "6:10!", marks: [MarkSpan(range: 0..<5, mark: .bold)]),
                            "typed \(self.editor.tables.docText(key))")
            try await self.undo()
            try await self.undo()
            try self.expect(try database() == before, "undo left the cell \(self.editor.tables.docText(key))")
        }
        await test("Table: the cell menu's Format marks all of the cell's text, or what is selected in it; shown on when on") {
            _ = try await click(3, 1)
            let key = try editedKey()
            let before = try database()
            let formatting = DocFormatting(editor: self.editor)
            formatting.toggle(.italic)
            let all = self.editor.tables.docText(key)
            try self.expect(all.marks == [MarkSpan(range: 0..<all.length, mark: .italic)], "marks \(all.marks)")
            try self.expect(formatting.markIsOn(.italic), "italic not shown on")
            formatting.setColor("red")
            try self.expect(formatting.color == .color("red"), "colour \(String(describing: formatting.color))")
            try await self.undo()
            try await self.undo()
            try self.expect(try database() == before, "undo left \(self.editor.tables.docText(key))")
        }
        await test("Table: the header row renames columns") {
            let view = try await click(0, 2)
            view.insertText("%")
            try self.expect(try database().columns[2].name == "深睡%", "column \(String(describing: try? database().columns[2].name))")
        }
        await test("Table: Tab, Shift-Tab and Return move between cells; Tab past the last column adds one, Return past the last row adds one") {
            _ = try await click(1, 0)
            var view = try await cellEditor(try editedKey(), step: "step 1")
            press(view, "\t")
            view = try await cellEditor(try table().key(1, 1), step: "step 2")
            self.editor.tables.move(.previous, from: try editedKey())
            view = try await cellEditor(try table().key(1, 0), step: "step 3")
            press(view, "\n")
            view = try await cellEditor(try table().key(2, 0), step: "step 4")
            let columns = try database().columns.count
            self.editor.tables.move(.last, from: try editedKey())
            view = try await cellEditor(try table().key(2, columns - 1), step: "step 5")
            press(view, "\t")
            try self.expect(try database().columns.count == columns + 1, "columns \(String(describing: try? database().columns.count))")
            view = try await cellEditor(try table().key(2, columns), step: "step 6")
            let rows = try database().rows.count
            self.editor.tables.move(.bottom, from: try editedKey())
            view = try await cellEditor(try table().key(rows, columns), step: "step 7")
            press(view, "\n")
            try self.expect(try database().rows.count == rows + 1, "rows \(String(describing: try? database().rows.count))")
            view = try await cellEditor(try table().key(rows + 1, columns), step: "step 8")
            press(view, "n")
            try self.expect(try cellText(rows + 1, columns) == "n", "new cell \(String(describing: try? cellText(rows + 1, columns)))")
        }
        await test("Table: every menu action changes the table, and one undo puts it back exactly") {
            let before = try database()
            // A formula is written apart from its cell (its own test).
            let actions: [DocTableAction] = [.insertRowAbove, .insertRowBelow, .insertColumnLeft, .insertColumnRight,
                                             .moveRowUp, .moveRowDown, .moveColumnLeft, .moveColumnRight,
                                             .sortAscending, .sortDescending, .deleteRow, .deleteColumn, .clearCell]
            for action in actions {
                _ = try await click(2, 1)
                let key = try editedKey()
                try self.expect(self.editor.tables.isAvailable(action, at: key), "\(action) not available")
                self.editor.tables.perform(action, at: key)
                try? await Task.sleep(for: .milliseconds(100))
                try self.expect(try database() != before, "\(action) changed nothing")
                do { try await self.undo() } catch { throw Failure(description: "undo after \(action): \(error)") }
                try self.expect(try database() == before, "undo after \(action) left the table changed")
            }
        }
        await test("Table: a cell is as tall edited as read: the table doesn't move when a cell is clicked") {
            let id = try table().block.description
            @MainActor func height() throws -> CGFloat { try self.expectValue(self.demo.rowFrame(id), "no row").height }
            _ = try await click(2, 1)
            self.editor.tables.endEditing()
            try await Task.sleep(for: .milliseconds(400))
            let read = try height()
            _ = try await click(2, 1)
            try await Task.sleep(for: .milliseconds(400))
            let edited = try height()
            try self.expect(abs(edited - read) < 0.5, "the table is \(read) high read, \(edited) with a cell edited")
        }
        await test("Table: a row added and undone leaves the table as tall as it was") {
            _ = try await click(2, 1)
            let key = try editedKey()
            // Measured with no cell edited, as the undo leaves it (its cell is gone).
            self.editor.tables.endEditing()
            try await Task.sleep(for: .milliseconds(400))
            let id = try table().block.description
            @MainActor func height() throws -> CGFloat { try self.expectValue(self.demo.rowFrame(id), "no row").height }
            let before = try height()
            self.editor.tables.perform(.insertRowBelow, at: key)
            try await Task.sleep(for: .milliseconds(500))
            let grown = try height()
            try self.expect(grown > before + 20, "row \(before) → \(grown) with a row more")
            try await self.undo()
            var after = try height()
            for _ in 0..<40 where abs(after - before) >= 1 {
                try await Task.sleep(for: .milliseconds(50))
                after = try height()
            }
            try self.expect(abs(after - before) < 1, "row \(before) → \(grown) → \(after) after the undo")
        }
        await test("Table speed: in a table of 80 rows a click, a keystroke, a row added or undone and the cell's menu each take a frame or two") {
            let t = try table()
            let databaseID = try self.expectValue(self.demo.doc.block(t.block)?.kind.databaseID, "no database")
            var after = t.database.rows.last?.id
            var steps: [DocStep] = []
            let size = UserDefaults.standard.integer(forKey: "docPerfRows") > 0 ? UserDefaults.standard.integer(forKey: "docPerfRows") : 80
            for index in 0..<max(0, size - t.database.rows.count) {
                var cells: [ColumnID: CellValue] = [:]
                for (column, field) in t.database.columns.enumerated() { cells[field.id] = .text(value: "r\(index) c\(column)") }
                let row = Row(id: self.demo.newID(), cells: cells)
                steps.append(.database(id: databaseID, step: .insertRow(row: row, after: after)))
                after = row.id
            }
            _ = self.demo.edit(steps, before: nil, after: nil)
            try await Task.sleep(for: .milliseconds(800))
            @MainActor func frame(_ action: @MainActor () -> Void) async -> Double { await self.frameTime(action) }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            func ms(_ value: Double) -> String { String(format: "%.1f", value) }

            let snapshot = DocTableSnapshot(block: t.block, database: try database())
            self.demo.bringIntoView(t.block)
            try await Task.sleep(for: .milliseconds(400))
            MarkdownRenderProbe.setEnabled(true)
            MarkdownRenderProbe.reset()
            let clicked = await frame { self.editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: size / 2, column: 1)) }
            let view = try await cellEditor(try table().key(size / 2, 1))
            let clickProbe = MarkdownRenderProbe.snapshot()
            try await self.settle()
            // The list scrolls the cell into view: typing starts once it's still.
            try await Task.sleep(for: .milliseconds(700))

            MarkdownRenderProbe.reset()
            docTestLog("DOCPERF table typing begins")
            var keys: [Double] = []
            var publish: [Double] = []
            for character in "abcdefghijklmnopqrstuvwxyz" {
                keys.append(await frame { press(view, String(character)) })
                publish.append(self.demo.lastPublishMs)
                try await self.settle()
            }
            let typeProbe = MarkdownRenderProbe.snapshot()
            let typed = try cellText(size / 2, 1)
            try self.expect(typed.hasSuffix("xyz"), "typing went to \(typed.suffix(10))")

            docTestLog("DOCPERF table rows begin")
            MarkdownRenderProbe.reset()
            var adds: [Double] = []
            var undos: [Double] = []
            var syncs: [Double] = []
            let repeats = max(5, UserDefaults.standard.integer(forKey: "docPerfRepeats"))
            for _ in 0..<repeats {
                let key = try editedKey()
                var sync = 0.0
                adds.append(await frame { let t = CACurrentMediaTime(); self.editor.tables.perform(.insertRowBelow, at: key); sync = (CACurrentMediaTime() - t) * 1000 })
                syncs.append(sync)
                try await Task.sleep(for: .milliseconds(400))
                undos.append(await frame { self.editor.requestUndo() })
                try await Task.sleep(for: .milliseconds(400))
                _ = try await click(size / 2, 1)
            }
            let add = median(adds)
            docTestLog("DOCPERF add row in its call \(ms(median(syncs))) of \(ms(add))")
            let undo = median(undos)
            let rowsProbe = MarkdownRenderProbe.snapshot()
            docTestLog("DOCPERF table menus begin")
            MarkdownRenderProbe.setEnabled(true)
            MarkdownRenderProbe.reset()
            var menus: [Double] = []
            let menuKey = try editedKey()
            for _ in 0..<repeats {
                menus.append(await frame { self.editor.tables.showMenu(menuKey) })
                try await Task.sleep(for: .milliseconds(400))
                self.editor.tables.closeMenu()
                try await Task.sleep(for: .milliseconds(300))
            }
            let menu = median(menus)
            let menuProbe = MarkdownRenderProbe.snapshot()
            docTestLog("DOCPERF table probe \(repeats) menus: table bodies \(menuProbe.markdownTableBodyCalls), contents \(menuProbe.markdownTableContentBodyCalls), layout \(menuProbe.adaptiveTableLayoutSizeCalls)× \(String(format: "%.1f", menuProbe.adaptiveTableLayoutSizeMs)) ms, cell bodies \(menuProbe.adaptiveTableCellBodyCalls)")
            MarkdownRenderProbe.setEnabled(false)

            docTestLog("DOCPERF table \(size) rows (ms): click \(ms(clicked)); keystroke median \(ms(median(keys))) max \(ms(keys.max() ?? 0)), rows published median \(ms(median(publish))); add row \(ms(add)); undo \(ms(undo)); menu \(ms(menu))")
            docTestLog("DOCPERF table probe click: layout \(clickProbe.adaptiveTableLayoutSizeCalls)× \(ms(clickProbe.adaptiveTableLayoutSizeMs)) ms, cell bodies \(clickProbe.adaptiveTableCellBodyCalls), info \(clickProbe.tableInfoEnsureFreshCalls)× \(ms(clickProbe.tableInfoEnsureFreshMs)) ms; typing 26 keys: layout \(typeProbe.adaptiveTableLayoutSizeCalls)× \(ms(typeProbe.adaptiveTableLayoutSizeMs)) ms, measures \(typeProbe.adaptiveTableLayoutIdealMeasures)+\(typeProbe.adaptiveTableLayoutConstrainedMeasures), cell bodies \(typeProbe.adaptiveTableCellBodyCalls), info \(typeProbe.tableInfoEnsureFreshCalls)× \(ms(typeProbe.tableInfoEnsureFreshMs)) ms; \(repeats) rows added and undone: layout \(rowsProbe.adaptiveTableLayoutSizeCalls)× \(ms(rowsProbe.adaptiveTableLayoutSizeMs)) ms, measures \(rowsProbe.adaptiveTableLayoutIdealMeasures)+\(rowsProbe.adaptiveTableLayoutConstrainedMeasures), cell bodies \(rowsProbe.adaptiveTableCellBodyCalls)")
            for (name, value) in [("click", clicked), ("keystroke", median(keys)), ("add row", add), ("undo", undo), ("menu", menu)] {
                try self.expect(value < 1000, "\(name) \(ms(value)) ms")
            }
        }
        await test("Table: the menu's Cut, Copy and Paste take the cell's text through the pasteboard; each is an undo step") {
            let saved = UIPasteboard.general.string
            defer { UIPasteboard.general.string = saved }
            _ = try await click(2, 1)
            let key = try editedKey()
            let text = self.editor.tables.text(key)
            try self.expect(!text.isEmpty, "the cell is empty")
            let before = try database()
            self.editor.tables.perform(.copy, at: key)
            try self.expect(UIPasteboard.general.string == text, "copy put \(String(describing: UIPasteboard.general.string))")
            self.editor.tables.perform(.cut, at: key)
            try self.expect(self.editor.tables.text(key).isEmpty, "cut left \(self.editor.tables.text(key))")
            self.editor.tables.perform(.paste, at: key)
            try? await Task.sleep(for: .milliseconds(100))
            try self.expect(self.editor.tables.text(key) == text, "paste gave \(self.editor.tables.text(key))")
            try await self.undo()
            try self.expect(self.editor.tables.text(key).isEmpty, "undoing the paste left \(self.editor.tables.text(key))")
            try await self.undo()
            try self.expect(try database() == before, "undoing the cut left the table changed")
        }
        if DocBlockController.usesHandles {
            await test("Table: a right-click on a cell not edited edits that cell and opens its menu") {
                let t = try table()
                var points: [(DocCellKey, CGPoint)] = []
                for (row, column) in [(2, 1), (1, 2), (0, 0)] {
                    let view = try await click(row, column)
                    let list = try self.expectValue(DocScrolling.list(of: view), "no list")
                    points.append((t.key(row, column), list.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)))
                }
                for (key, point) in points {
                    self.editor.tables.leave(key)
                    self.editor.blocks.clear()
                    try? await Task.sleep(for: .milliseconds(100))
                    try self.expect(self.editor.tables.editing == nil, "still editing")
                    try self.expect(!self.editor.blocks.testRightClick(at: point), "the block's menu, not the cell's")
                    _ = try await cellEditor(key)
                    try self.expect(self.editor.tables.menu == DocTableMenuTarget(key: key), "menu \(String(describing: self.editor.tables.menu)), wanted \(key)")
                }
            }
        }
        await test("Table: in a cell the format panels are the cell's: marks and a colour, on all its text at the caret; Aa on a phone opens its sheet") {
            _ = try await click(2, 1)
            let key = try editedKey()
            let formatting = DocFormatting(editor: self.editor)
            try self.expect(formatting.cell?.key == key && formatting.formats == [.marks, .color, .alignment, .typeface, .numberFormat, .fill, .table],
                            "formats \(formatting.formats.rawValue)")
            try self.expect(formatting.targets.isEmpty && formatting.decorated.isEmpty, "the table took the cell's place")
            let before = try database()
            formatting.toggle(.bold)
            try self.expect(formatting.markIsOn(.bold), "the cell isn't bold")
            if !DocBlockController.usesHandles {
                self.editor.blocks.formatCaretBlock()
                try self.expect(self.editor.panels.sheetPage == .main && !self.editor.blocks.isSelecting, "page \(String(describing: self.editor.panels.sheetPage)) selecting \(self.editor.blocks.isSelecting)")
                try self.expect(DocFormatting(editor: self.editor, caretTakesBlock: true).cell?.key == key, "the sheet isn't the cell's")
                self.editor.blocks.closeSheet()
            }
            try await self.undo()
            try self.expect(try database() == before, "undo left the cell bold")
        }
        await test("Table: a cell's alignment, typeface, number format and fill, and its table's headers, stripe, typeface and size: drawn as set, each one undo step") {
            _ = try await click(2, 1)
            let key = try editedKey()
            let before = try database()
            let cell = try self.expectValue(DocFormatting(editor: self.editor).cell, "no cell panel")
            cell.toggle(.right)
            cell.setFont(.serif)
            cell.setStyle(.numberFormat) { $0.number = .percent }
            cell.setStyle(.fill) { $0.fill = "blue-2" }
            let style = CellStyle(alignment: .right, font: .serif, number: .percent, fill: "blue-2")
            try self.expect(try database().cellStyle(row: key.row, column: key.column) == style, "style \(cell.style)")
            let row = try database().rows.firstIndex { $0.id == key.row }.map { $0 + 1 } ?? -1
            let column = try database().columns.firstIndex { $0.id == key.column } ?? -1
            let snapshot = DocTableSnapshot(block: key.block, database: try database())
            var appearance = self.editor.tables.appearance(of: snapshot)
            let look = appearance.cells[MarkdownTableCellPosition(row: row, column: column)]
            try self.expect(look?.alignment == .trailing && look?.fontDesign == .serif && look?.fill != nil, "drawn as \(String(describing: look))")
            try self.expect(appearance.stripe == .standard && appearance.headerRow && !appearance.headerColumn, "a table's own look")
            try self.expect(self.editor.tables.look(key).textAlignment == .right, "the editor isn't right-aligned")
            cell.setTable { $0.headerColumn = true }
            cell.setTable { $0.stripe = "gray-2" }
            appearance = self.editor.tables.appearance(of: DocTableSnapshot(block: key.block, database: try database()))
            let striped = if case .color = appearance.stripe { true } else { false }
            try self.expect(appearance.headerColumn && striped, "the table's look \(appearance.stripe)")
            cell.setTable { $0.stripe = TableStyle.noStripe }
            appearance = self.editor.tables.appearance(of: DocTableSnapshot(block: key.block, database: try database()))
            try self.expect(appearance.stripe == .none, "no stripe drawn as \(appearance.stripe)")
            // The table block's typeface is its cells', unless they have their own.
            self.editor.setFont(.mono, of: [key.block])
            appearance = self.editor.tables.appearance(of: DocTableSnapshot(block: key.block, database: try database()))
            let header = DocCellKey(block: key.block, row: nil, column: key.column)
            try self.expect(appearance.fontDesign == .monospaced && appearance.cells[MarkdownTableCellPosition(row: row, column: column)]?.fontDesign == .serif
                            && self.editor.tables.look(header).style.font == .mono, "the table's typeface \(String(describing: appearance.fontDesign))")
            let size = cell.size
            cell.resize(rows: size.rows + 1)
            cell.resize(columns: size.columns + 1)
            try self.expect(cell.size == (size.rows + 1, size.columns + 1), "size \(cell.size)")
            for _ in 0..<10 { try await self.undo() }
            try self.expect(try database() == before && self.demo.doc.block(key.block)?.font == nil, "ten undos didn't put the table back")
        }
        await test("Table: a header cell, a picked column and the whole table selected have the cells' panel, a setting on all of them in one step; the whole table's typeface is the table's") {
            _ = try await click(0, 1)
            let header = try editedKey()
            let before = try database()
            let first = try self.expectValue(DocFormatting(editor: self.editor).cell, "no panel in the header")
            try self.expect(first.scope == .cell && first.formats.isSuperset(of: [.alignment, .typeface, .fill]), "the header's \(first.formats.rawValue)")
            first.toggle(.center)
            try self.expect(try database().cellStyle(row: nil, column: header.column).alignment == .center, "the header isn't centred")
            _ = try await click(1, 1)
            let key = try editedKey()
            self.editor.tables.pick(.column, of: key)
            let column = try self.expectValue(DocFormatting(editor: self.editor).cell, "no panel for the column")
            try self.expect(column.scope == .line(.column), "scope \(column.scope)")
            column.setStyle(.fill) { $0.fill = "red-2" }
            let rows = try database().rows
            try self.expect(([nil] + rows.map(\.id)).allSatisfy { (try? database().cellStyle(row: $0, column: key.column).fill) == "red-2" }, "the column isn't all red")
            try self.expect(column.style.fill == "red-2", "the panel shows \(String(describing: column.style.fill))")
            self.editor.tables.endEditing()
            self.editor.blocks.beginSelecting(key.block)
            let table = try self.expectValue(DocFormatting(editor: self.editor).cell, "no panel for the table")
            try self.expect(table.scope == .table && table.style.fill == nil, "scope \(table.scope) fill \(String(describing: table.style.fill))")
            table.toggle(.right)
            try self.expect(table.cells.allSatisfy { (try? database().cellStyle(row: $0.row, column: $0.column).alignment) == .right }, "not all right-aligned")
            table.setFont(.serif)
            try self.expect(self.demo.doc.block(key.block)?.font == .serif && table.style.font == .serif, "the table's font \(String(describing: self.demo.doc.block(key.block)?.font))")
            self.editor.blocks.endSelecting()
            for _ in 0..<4 { try await self.undo() }
            try self.expect(try database() == before && self.demo.doc.block(key.block)?.font == nil, "four undos didn't put the table back")
        }
        await test("Table: a cell's menu is that cell's, and goes when another cell is edited") {
            _ = try await click(2, 1)
            let key = try editedKey()
            self.editor.tables.showMenu(key)
            try self.expect(self.editor.tables.menu == DocTableMenuTarget(key: key), "the menu isn't the cell's")
            _ = try await click(1, 1)
            try self.expect(self.editor.tables.menu == nil, "the menu stayed after another cell was edited")
        }
        await test("Table: a picked column or row: copied as a spreadsheet does, cleared and filled whole in one undo step") {
            let saved = UIPasteboard.general.string
            defer { UIPasteboard.general.string = saved }
            _ = try await click(2, 1)
            let key = try editedKey()
            let before = try database()
            let column = before.rows.map { DocTableController.text(of: $0.cells[key.column]) }
            self.editor.tables.pick(.column, of: key)
            try self.expect(self.editor.tables.line == .column && self.editor.tables.menu == DocTableMenuTarget(key: key, line: .column), "the column isn't picked")
            try self.expect(self.editor.tables.view(for: key)?.isFirstResponder == false, "the caret stayed in the cell")
            try self.expect(!self.editor.tables.isAvailable(.insertFormula, at: key, on: .column), "a formula for a column")
            self.editor.tables.perform(.copy, at: key, on: .column)
            try self.expect(UIPasteboard.general.string == column.joined(separator: "\n"), "the column copied as \(String(describing: UIPasteboard.general.string))")
            self.editor.tables.perform(.clearCell, at: key, on: .column)
            try self.expect(try database().rows.allSatisfy { DocTableController.text(of: $0.cells[key.column]).isEmpty }, "the column isn't clear")
            UIPasteboard.general.string = "x"
            self.editor.tables.perform(.paste, at: key, on: .column)
            try self.expect(try database().rows.allSatisfy { DocTableController.text(of: $0.cells[key.column]) == "x" }, "one value isn't in every cell")
            try await self.undo()
            try await self.undo()
            try self.expect(try database() == before, "two undos didn't put the column back")
            _ = try await click(2, 1)
            let cell = try editedKey()
            self.editor.tables.pick(.row, of: cell)
            self.editor.tables.perform(.copy, at: cell, on: .row)
            let row = before.rows[1]
            try self.expect(UIPasteboard.general.string == before.columns.map { DocTableController.text(of: row.cells[$0.id]) }.joined(separator: "\t"),
                            "the row copied as \(String(describing: UIPasteboard.general.string))")
            _ = try await click(2, 1)
            try self.expect(self.editor.tables.line == nil, "editing the cell again kept the row picked")
        }
        await test("Table: the dots on the edges add a column and a row, and edit the new cell beside or below") {
            _ = try await click(2, 1)
            let key = try editedKey()
            let before = try database()
            self.editor.tables.appendColumn(beside: key)
            let column = try database().columns.last!.id
            try self.expect(try database().columns.count == before.columns.count + 1, "no column")
            _ = try await cellEditor(DocCellKey(block: key.block, row: key.row, column: column), step: "the new column's cell")
            self.editor.tables.appendRow(below: key)
            let row = try database().rows.last!.id
            try self.expect(try database().rows.count == before.rows.count + 1, "no row")
            _ = try await cellEditor(DocCellKey(block: key.block, row: row, column: key.column), step: "the new row's cell")
            try await self.undo()
            try await self.undo()
            try self.expect(try database() == before, "undo left the table changed")
        }
        await test("Table: sorting orders the rows by the column, numbers as numbers, the header stays") {
            _ = try await click(1, 2)
            self.editor.tables.perform(.sortAscending, at: try editedKey())
            let column = try database().columns[2].id
            let values = try database().rows.map { DocTableController.text(of: $0.cells[column]) }
            try self.expect(values == values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "order \(values)")
            try self.expect(try database().columns[0].name == "日期", "header \(String(describing: try? database().columns[0].name))")
        }
        await test("Table: deleting it removes the block and its database; undo brings both back") {
            let t = try table()
            _ = try await click(1, 1)
            self.editor.tables.perform(.deleteTable, at: try editedKey())
            try self.expect(self.demo.doc.block(t.block) == nil && self.demo.doc.databases[t.database.id] == nil, "still there")
            try await self.undo()
            try self.expect(self.demo.doc.block(t.block) != nil && self.demo.doc.databases[t.database.id] == t.database, "not back")
        }
        await test("Table: 插入公式 writes a formula apart from its cell (a phone: the table's own page; the Mac: a panel under the cell); the cell shows its result") {
            _ = try await click(4, 2)
            let key = try editedKey()
            self.editor.tables.perform(.insertFormula, at: key)
            let t = try table()
            try await self.writeFormulaApart(at: key, table: DocTableSnapshot(block: t.block, database: t.database))
        }
        await test("Table: pasting a spreadsheet range fills cells right and down, adding rows and columns; one undo") {
            let before = try database()
            let view = try await click(4, 3)
            UIPasteboard.general.string = "a\tb\nc\td\n"
            view.paste(nil)
            try? await Task.sleep(for: .milliseconds(150))
            let after = try database()
            try self.expect(after.columns.count == before.columns.count + 1 && after.rows.count == before.rows.count + 1, "size \(after.rows.count)×\(after.columns.count)")
            let cells = [try cellText(4, 3), try cellText(4, 4), try cellText(5, 3), try cellText(5, 4)]
            try self.expect(cells == ["a", "b", "c", "d"], "cells \(cells)")
            try await self.undo()
            try self.expect(try database() == before, "undo left changes")
        }
        await test("Table: Esc leaves it; it renders as MarkdownView's table again") {
            let view = try await click(1, 1)
            try self.expect(self.editor.tables.editing != nil, "not editing")
            try self.expect(self.escape(view), "no Esc command")
            try? await Task.sleep(for: .milliseconds(100))
            try self.expect(self.editor.tables.editing == nil, "still editing")
        }
        await test("Table: “/2x3” makes a 2 × 3 table and edits its first header cell") {
            let line = try await emptyLine()
            try await self.type("/2x3")
            try self.expect(self.editor.slash.highlightedItem?.id == "table-2x3", "highlighted \(String(describing: self.editor.slash.highlightedItem?.id))")
            try await self.enter()
            let block = try self.expectValue(self.demo.doc.block(line.id), "block gone")
            let database = try self.expectValue(block.kind.databaseID.flatMap { self.demo.doc.databases[$0] }, "not a table: \(block.kind)")
            try self.expect(database.columns.count == 3 && database.rows.count == 1, "size \(database.rows.count + 1)×\(database.columns.count)")
            let view = try await cellEditor(DocCellKey(block: line.id, row: nil, column: database.columns[0].id))
            view.insertText("名称")
            try self.expect(self.demo.doc.databases[database.id]?.columns[0].name == "名称", "header \(String(describing: self.demo.doc.databases[database.id]?.columns[0].name))")
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
        await test("A colour on text shows in it; typing at its end goes on in it, at a pen mark's it doesn't; one undo each") {
            let block = try self.block("Loading older")
            self.editor.set(.color, to: .color("red"), over: [(block.id, 0..<7)])
            func rgb(_ color: UIColor?) -> [Int] {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color?.getRed(&r, green: &g, blue: &b, alpha: &a)
                return [r, g, b].map { Int(($0 * 255).rounded()) }
            }
            // Only the colour changed: the row redraws a moment later.
            var shown: [Int] = [], red: [Int] = [1]
            for _ in 0..<40 where shown != red {
                try? await Task.sleep(for: .milliseconds(25))
                guard let view = self.editor.textView(for: block.id),
                    let start = self.editor.textStart(in: view, block: self.demo.doc.block(block.id)!)
                else { continue }
                shown = rgb((view.textStorage.attribute(.foregroundColor, at: start, effectiveRange: nil) as? UIColor)?.resolvedColor(with: view.traitCollection))
                red = rgb(UIColor(MarkdownColorToken.text("red")!).resolvedColor(with: view.traitCollection))
            }
            try self.expect(shown == red, "shown in \(shown), red is \(red)")
            try await self.focus(block.id, at: 7)
            try await self.type("s")
            try self.expect(self.editor.common(.color, over: [(block.id, 0..<8)]) == .color("red"), "the typed letter isn't red")
            self.editor.set(.pen, to: .pen(kind: "circle", color: "blue"), over: [(block.id, 9..<15)])
            try await self.focus(block.id, at: 15)
            try await self.type("x")
            try self.expect(self.editor.common(.pen, over: [(block.id, 9..<15)]) == .pen(kind: "circle", color: "blue"), "pen mark lost")
            try self.expect(self.editor.common(.pen, over: [(block.id, 15..<16)]) == nil, "the pen mark grew")
            try await self.showsModelSoon(block.id)
            try await self.undo()
            try await self.undo()
            try self.expect(self.editor.common(.pen, over: [(block.id, 9..<15)]) == nil, "undo left the pen mark")
        }
        await test("A web address pasted on an empty line is its bookmark; the cursor goes under it; one undo") {
            let line = try await emptyLine()
            // An address that can't be reached: no preview comes in the middle of the test.
            try self.key("https://example.invalid/page")
            try await self.settle()
            let block = try self.expectValue(self.demo.doc.block(line.id), "block gone")
            try self.expect(block.kind == .link(link: DocLink(url: "https://example.invalid/page")), "kind \(block.kind)")
            let next = try self.blockAfter(line.id)
            try self.expect(next.kind == .paragraph && next.text.isEmpty, "next \(next.kind)")
            try self.expectCursor(next.id, 0)
            try await self.undo()
            try self.expect(self.demo.doc.block(line.id)?.kind == .paragraph && self.demo.doc.block(next.id) == nil, "undo left \(String(describing: self.demo.doc.block(line.id)?.kind))")
        }
        await test("A page's preview: Open Graph tags, else its title and description; entities, relative images, its charset") {
            let html = """
                <html><head><meta charset="utf-8"><title>  Page
                  title </title>
                <meta name="description" content="Plain">
                <meta property="og:description" content="Tom &amp; Jerry&#39;s &#x4E2D;">
                <meta content='/img/a.png' property='og:image'>
                </head></html>
                """
            let preview = DocLinkPreviews.parse(html, base: URL(string: "https://a.com/x/y")!)
            try self.expect(preview == .init(title: "Page title", summary: "Tom & Jerry's 中", image: "https://a.com/img/a.png"), "preview \(preview)")
            let filled = preview.filling(DocLink(url: "https://a.com/x/y", title: "Mine"))
            try self.expect(filled.title == "Mine" && filled.summary == "Tom & Jerry's 中", "filled \(filled)")
            let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            let data = try self.expectValue("<meta charset=\"gbk\"><title>拙政园</title>".data(using: String.Encoding(rawValue: gbk)), "no gbk")
            let text = DocLinkPreviews.decode(data, contentType: "text/html")
            try self.expect(text?.contains("拙政园") == true, "decoded \(String(describing: text))")
        }
        await blockTests()
        await keyboardBarTests()
        docTestLog("DOCTEST DONE pass=\(passed) fail=\(failed)")
    }

    /// The bar over a phone's keyboard (DocKeyboardBar.swift). It exists on the Mac too,
    /// only not over a keyboard, so it is driven directly.
    private func keyboardBarTests() async {
        let bar = editor.keyboardBar
        await test("the keyboard bar has no keys for selected text (the system's text menu has its Format), nor the slash, which would type over it") {
            let block = try self.block("Loading older")
            await self.bringIntoView(block.id)
            try await self.select(block.id, 0..<7)
            try self.expect(bar.testItems.map(\.id) == ["format", "more", "dismiss"], "keys \(bar.testItems.map(\.id))")
        }
        await test("the keyboard bar's + is the system's menu: More's blocks in sections, then where files come from; a command acts at the caret") {
            let block = try self.block("Loading older")
            await self.bringIntoView(block.id)
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            let line = try self.blockAfter(block.id)
            let titles = { (element: UIMenuElement) -> [String] in
                ((element as? UIMenu)?.children ?? []).map(\.title)
            }
            let elements = DocInsertMenu.elements(self.editor)
            let more = try self.expectValue((elements.first as? UIMenu)?.children.first as? UIMenu, "no More")
            try self.expect(more.title == "More" && more.children.map(titles) == [["Text Style", "List", "Decorations", "Divider"], ["Insert Table", "Page"], ["Code Block", "Math Block"]],
                            "More \(more.children.map(titles))")
            let places = elements.dropFirst().map(titles)
            let expected = DocDevice.isMac ? [["File"], ["Image"]] : [["File"], ["Gallery"]]
            try self.expect(places.map { $0.filter { !["Scan", "Camera", "Live Text"].contains($0) } } == expected, "sources \(places)")
            self.editor.performAtCaret(.kind(.heading(level: 1)))
            try await self.settle()
            try self.expect(self.demo.doc.block(line.id)?.kind == .heading(level: 1), "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
            try await self.undo()
        }
        await test("the keyboard bar's command key types a slash and opens the menu; Aa and ⋮ select the caret's block (Aa under the format sheet), and back") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: block.text.length)
            try self.expect(bar.testItems.map(\.id) == ["slash", "format", "more", "insert", "dismiss"], "keys \(bar.testItems.map(\.id))")
            if !DocBlockController.usesHandles {
                // Aa selects the caret's block and opens the sheet over it; closed, the
                // caret is back where it was.
                try await self.focus(block.id, at: 4)
                bar.testTap("format")
                try self.expect(self.editor.blocks.isSelecting && self.editor.blocks.selected == [block.id], "not selecting the caret's block")
                try self.expect(self.editor.panels.sheetPage == .main, "no sheet")
                DocFormatting(editor: self.editor, caretTakesBlock: true).setStyle(.heading(level: 2))
                try await self.settle()
                try self.expect(self.demo.doc.block(block.id)?.kind == .heading(level: 2), "kind \(String(describing: self.demo.doc.block(block.id)?.kind))")
                self.editor.blocks.closeSheet()
                try await self.settle()
                try self.expect(!self.editor.blocks.isSelecting && self.editor.panels.sheetPage == nil, "still selecting")
                let caret = self.editor.selection
                try self.expect(caret?.head == DocPosition(block: block.id, offset: 4) && caret?.anchor == caret?.head, "caret \(String(describing: caret))")
                try self.expect(self.editor.textView(for: block.id)?.isFirstResponder == true, "not editing")
                try await self.undo()
                // ⋮ selects the caret's block; done selecting, the caret is back.
                try await self.focus(block.id, at: 4)
                bar.testTap("more")
                try self.expect(self.editor.blocks.isSelecting && self.editor.blocks.selected == [block.id], "⋮ didn't select the caret's block")
                self.editor.blocks.endSelecting()
                try await self.settle()
                try self.expect(self.editor.selection?.head == DocPosition(block: block.id, offset: 4), "caret after ⋮ \(String(describing: self.editor.selection))")
                try await self.focus(block.id, at: block.text.length)
            }
            // The command key types a slash and opens the menu; Color › Blue (the slash
            // gone) colours the block's text, Delete Block deletes it.
            let text = self.text(block.id)
            bar.testTap("slash")
            try await self.settle()
            try self.expect(self.text(block.id) == text + "/" && self.editor.slash.isOpen, "text \(self.text(block.id).debugDescription) open \(self.editor.slash.isOpen)")
            let color = try self.expectValue(DocCommand.all.first { $0.id == "color" }, "no Color")
            self.editor.slash.choose(color)
            try self.expect(self.editor.slash.group?.id == "color", "Color didn't open")
            self.editor.slash.choose(try self.expectValue(color.children.first { $0.swatch == "blue" }, "no blue"))
            try await self.settle()
            try self.expect(!self.editor.slash.isOpen && self.text(block.id) == text, "open \(self.editor.slash.isOpen) text \(self.text(block.id).debugDescription)")
            try self.expect(DocFormatting(editor: self.editor, caretTakesBlock: true).color == .color("blue"), "not blue")
            // Undone: the colour, the slash's removal, the slash.
            for _ in 0..<3 { try await self.undo() }
            try self.expect(self.text(block.id) == text, "undo: \(self.text(block.id).debugDescription)")
            try await self.focus(block.id, at: text.utf16.count)
            bar.testTap("slash")
            self.editor.slash.choose(try self.expectValue(DocCommand.all.first { $0.id == "delete" }, "no Delete Block"))
            try await self.settle()
            try self.expect(self.demo.doc.block(block.id) == nil, "not deleted")
            try await self.undo()
            try self.expect(self.text(block.id) == text, "undo: \(self.text(block.id).debugDescription)")
        }
        if !DocBlockController.usesHandles {
            await test("the keyboard comes and goes without the page jumping; its key hides it") {
                // Two lines: one the keyboard leaves uncovered, one low on the page it covers.
                for prefix in ["Loading older", "Apply the insert"] {
                    let block = try self.block(prefix)
                    if prefix == "Loading older" { self.demo.bringIntoView(block.id) }
                    try? await Task.sleep(for: .seconds(1))
                    let view = try self.expectValue(self.editor.textView(for: block.id), "no view for \(prefix)")
                    func y() -> CGFloat { view.convert(view.bounds, to: nil).minY }
                    let before = y()
                    // A tap's way in: the text view takes the focus itself.
                    view.becomeFirstResponder()
                    view.selectedRange = NSRange(location: 3, length: 0)
                    var shown = [before]
                    // How far below its place the bar shows (it rises with the keyboard).
                    var below: [CGFloat] = []
                    for _ in 0..<50 {
                        try? await Task.sleep(for: .milliseconds(20))
                        shown.append(y())
                        below.append((bar.layer.presentation()?.frame.minY ?? bar.frame.minY) - bar.frame.minY)
                    }
                    try self.expect(below.prefix(5).contains { $0 > 20 } && abs(below.last ?? 1) < 0.5, "\(prefix): the bar didn't rise, below its place by \(below.map { Int($0) })")
                    let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
                    try self.expect(steps.allSatisfy { $0 <= 0.5 } && steps.allSatisfy { abs($0) < 60 }, "\(prefix) moved \(shown.map { Int($0) })")
                    let caret = view.convert(view.caretRect(for: view.selectedTextRange!.end), to: nil)
                    let list = try self.expectValue(DocScrolling.list(of: view), "no list")
                    let visible = list.convert(DocScrolling.visible(in: list), to: nil)
                    try self.expect(caret.maxY <= visible.maxY, "\(prefix): caret \(caret.maxY) under the keyboard at \(visible.maxY)")
                    try self.expect(shown.last == before || before > visible.maxY - 30, "\(prefix) moved from \(before) to \(shown.last!) though it showed")
                    // The bar is the page's, on the keyboard's top; the caret's line above it too.
                    let window = try self.expectValue(view.window, "no window")
                    let keyboard = window.convert(DocScrolling.keyboard, from: nil)
                    let onPage = bar.convert(bar.bounds, to: window)
                    try self.expect(bar.window === window && self.editor.keyboardBarStage.isShown && abs(onPage.maxY - keyboard.minY) < 1,
                                    "\(prefix): the bar at \(onPage) in \(String(describing: bar.window)), the keyboard at \(keyboard)")
                    try self.expect(caret.maxY <= onPage.minY, "\(prefix): caret \(caret.maxY) under the bar at \(onPage.minY)")
                    let settled = y()
                    bar.testTap("dismiss")
                    for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(20)); try self.expect(y() == settled, "\(prefix) moved as the keyboard went: \(settled) → \(y())") }
                    try self.expect(!view.isFirstResponder, "\(prefix): the keyboard stayed")
                    let gone = bar.convert(bar.bounds, to: window)
                    try self.expect(!self.editor.keyboardBarStage.isShown && gone.minY >= window.bounds.maxY - 0.5, "\(prefix): the bar stayed at \(gone)")
                }
            }
        }
        await test("on an empty line the keyboard bar's divider key makes it a divider") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            let line = try self.blockAfter(block.id)
            try self.expect(bar.testItems.map(\.id) == ["slash", "format", "more", "divider", "insert", "dismiss"], "keys \(bar.testItems.map(\.id))")
            bar.testTap("divider")
            try await self.settle()
            try self.expect(self.demo.doc.block(line.id)?.kind == .divider, "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
        }
        await test("Copy Format takes a block's kind, box and marks; Paste Format gives them to the selected blocks, one undo") {
            let source = try self.block("Loading older")
            let target = try self.block("第 2 节")
            let blocks = self.editor.blocks
            self.editor.setKind(.heading(level: 3), of: [source.id])
            self.editor.setDecoration(.block, of: [source.id])
            self.editor.toggle(.bold, over: [(source.id, 0..<self.demo.doc.block(source.id)!.text.length)])
            self.editor.set(.color, to: .color("red"), over: [(source.id, 0..<self.demo.doc.block(source.id)!.text.length)])
            blocks.beginSelecting(source.id)
            let copied = try self.expectValue(DocFormatting(editor: self.editor).format, "no format")
            try self.expect(copied.kind == .heading(level: 3) && copied.decoration == .block && copied.marks == [.bold: .bold, .color: .color("red")], "copied \(copied)")
            blocks.select([target.id])
            try self.expect(blocks.selected == [target.id], "selected \(blocks.selected)")
            DocFormatting(editor: self.editor).paste(copied)
            let pasted = try self.expectValue(self.demo.doc.block(target.id), "no target")
            let whole = 0..<pasted.text.length
            try self.expect(pasted.kind == .heading(level: 3) && pasted.decoration == .block, "pasted \(pasted.kind) \(String(describing: pasted.decoration))")
            try self.expect(pasted.text.marks.contains(MarkSpan(range: whole, mark: .bold)) && pasted.text.marks.contains(MarkSpan(range: whole, mark: .color("red"))), "marks \(pasted.text.marks)")
            blocks.endSelecting()
            try await self.undo()
            try self.expect(self.demo.doc.block(target.id)?.kind == target.kind && self.demo.doc.block(target.id)?.decoration == nil
                            && self.demo.doc.block(target.id)?.text.marks == target.text.marks, "undo: \(String(describing: self.demo.doc.block(target.id)))")
        }
        await test("the selection bar's Style opens the sheet on the selected blocks; leaving the selection closes it") {
            let first = try self.block("Loading older")
            let blocks = self.editor.blocks
            blocks.beginSelecting(first.id)
            self.editor.panels.sheetPage = .main
            if !DocBlockController.usesHandles {
                // A sheet as tall as its pages (Craft's), over the bottom of the window.
                try? await Task.sleep(for: .milliseconds(800))
                let sheets = blocks.testSheetFrames
                let pages = FlooDesignTokens.Component.FormatSheet.page
                try self.expect(sheets.count == 1 && sheets[0].height > pages && sheets[0].height < pages + 80,
                                "sheets \(sheets) for pages \(pages) tall")
                // Another page opens in a sheet over it, and goes back to it.
                self.editor.panels.sheetPage = .colors
                try? await Task.sleep(for: .milliseconds(800))
                try self.expect(blocks.testSheetFrames.count == 2, "colours: sheets \(blocks.testSheetFrames)")
                self.editor.panels.sheetPage = .main
                try? await Task.sleep(for: .milliseconds(800))
                try self.expect(blocks.testSheetFrames.count == 1, "back: sheets \(blocks.testSheetFrames)")
            }
            try self.expect(DocFormatting(editor: self.editor, caretTakesBlock: true).targets.map(\.id) == [first.id], "targets")
            DocFormatting(editor: self.editor, caretTakesBlock: true).toggleList(.listItem(style: .task(done: false)))
            try self.expect(self.demo.doc.block(first.id)?.kind == .listItem(style: .task(done: false)), "kind \(String(describing: self.demo.doc.block(first.id)?.kind))")
            blocks.endSelecting()
            try self.expect(self.editor.panels.sheetPage == nil, "the sheet stays")
            if !DocBlockController.usesHandles {
                try? await Task.sleep(for: .milliseconds(800))
                try self.expect(blocks.testSheetFrames.isEmpty, "sheets stay on screen: \(blocks.testSheetFrames)")
            }
        }
        await test("what each block takes decides the format panels: text its styles and marks, an image its size and fit, a table alone its cells' panel; together, a style goes on the text only") {
            let blocks = self.editor.blocks
            let text = try self.block("Loading older")
            let image = try self.expectValue(self.demo.doc.blocks.first { if case .image = $0.kind { true } else { false } }, "no image")
            let table = try self.expectValue(self.demo.doc.blocks.first { if case .database = $0.kind { true } else { false } }, "no table")
            blocks.beginSelecting(text.id)
            for (ids, formats) in [([text.id], DocFormats.text), ([image.id], [.indent, .box, .image])] {
                blocks.select(ids)
                let taken = DocFormatting(editor: self.editor).formats
                try self.expect(taken == formats, "\(ids): \(taken.rawValue), wanted \(formats.rawValue)")
            }
            blocks.select([table.id])
            let cells = DocFormatting(editor: self.editor).cell
            try self.expect(cells?.scope == .table && cells?.formats.isSuperset(of: [.alignment, .typeface, .fill, .table]) == true,
                            "the table's panel \(String(describing: cells?.scope)) \(String(describing: cells?.formats.rawValue))")
            blocks.select([text.id, image.id])
            let formatting = DocFormatting(editor: self.editor)
            try self.expect(formatting.takes(.textStyle) && formatting.takes(.image) && formatting.targets.map(\.id) == [text.id], "targets \(formatting.targets.map(\.id))")
            formatting.setStyle(.heading(level: 3))
            try await self.settle()
            try self.expect(self.demo.doc.block(text.id)?.kind == .heading(level: 3) && self.demo.doc.block(image.id)?.kind == image.kind,
                            "kinds \(String(describing: self.demo.doc.block(text.id)?.kind)) \(String(describing: self.demo.doc.block(image.id)?.kind))")
            blocks.endSelecting()
            try await self.undo()
            try self.expect(self.demo.doc.block(text.id)?.kind == text.kind, "undo left \(String(describing: self.demo.doc.block(text.id)?.kind))")
        }
    }

    /// Blocks as wholes: the handle, selecting, moving (DocBlocks.swift).
    private func blockTests() async {
        let blocks = editor.blocks
        func order() -> [DocBlockID] { demo.doc.blocks.map(\.id) }
        func show(_ id: DocBlockID) async {
            await self.bringIntoView(id)
        }
        if DocBlockController.usesHandles {
            await test("the handle shows beside the block under the pointer, at its first line") {
                let heading = try self.block("第 1 节")
                await show(heading.id)
                blocks.testHover(heading.id)
                let handle = try self.expectValue(blocks.testHandleFrame, "no handle")
                let row = try self.expectValue(blocks.testRowFrame(heading.id), "no row")
                let line = try self.expectValue(self.editor.textView(for: heading.id).map { $0.convert($0.caretRect(for: $0.beginningOfDocument), to: nil) }, "no text view")
                let list = try self.expectValue(self.editor.textView(for: heading.id).flatMap { DocScrolling.list(of: $0) }, "no list")
                let lineInList = list.convert(line, from: nil)
                try self.expect(abs(handle.midY - lineInList.midY) < 1, "handle at \(handle.midY), first line at \(lineInList.midY)")
                try self.expect(handle.maxX <= lineInList.minX && handle.minX >= row.minX, "handle \(handle) beside \(lineInList)")
            }
            await test("a click on the handle is the handle's only: the row's click doesn't put the caret in the text") {
                try self.expect(!blocks.testRowClickTakesHandle, "the row's click takes the handle's clicks")
            }
            await test("an indented block's handle goes in with it, a level's step a level") {
                let paragraph = try self.block("这篇文档由 DocKit")
                let nested = try self.block("编号也一样")
                var xs: [CGFloat] = []
                for id in [paragraph.id, nested.id] {
                    await show(id)
                    blocks.testHover(id)
                    xs.append(try self.expectValue(blocks.testHandleFrame, "no handle").minX)
                }
                let wanted = DocBlockController.indentWidth(nested.indent - paragraph.indent)
                try self.expect(abs(xs[1] - xs[0] - wanted) < 0.5, "handles at \(xs), \(wanted) apart wanted")
            }
            await test("the selection's tint and the handle go in with the block, in the rows' motion") {
                let block = try self.block("Loading older")
                await show(block.id)
                blocks.select([block.id])
                blocks.testHover(block.id)
                try? await Task.sleep(for: .milliseconds(200))
                let before = try self.expectValue(blocks.testHighlights.first?.frame, "no tint")
                let handle = try self.expectValue(blocks.testHandleFrame, "no handle")
                blocks.indentSelection(by: 1)
                try? await Task.sleep(for: .milliseconds(120))
                let step = DocBlockController.indentWidth(1)
                let moving = try self.expectValue(blocks.testHighlights.first, "no tint")
                try self.expect(abs(moving.frame.minX - before.minX - step) < 0.5, "tint going to \(moving.frame.minX), was \(before.minX)")
                try self.expect(moving.shown.minX > before.minX + 0.5 && moving.shown.minX < moving.frame.minX - 0.5,
                                "tint at \(moving.shown.minX) mid-way, from \(before.minX) to \(moving.frame.minX)")
                try? await Task.sleep(for: .milliseconds(700))
                let settled = try self.expectValue(blocks.testHighlights.first, "no tint")
                try self.expect(abs(settled.shown.minX - settled.frame.minX) < 0.5, "tint stopped at \(settled.shown.minX)")
                let moved = try self.expectValue(blocks.testHandleFrame, "no handle")
                try self.expect(abs(moved.minX - handle.minX - step) < 0.5, "handle at \(moved.minX), was \(handle.minX)")
                try await self.undo()
                blocks.clear()
            }
            await test("a click on a block's text selects the block; only then does the text take clicks") {
                let block = try self.block("Loading older")
                await show(block.id)
                self.editor.dismissKeyboard()
                blocks.clear()
                try? await Task.sleep(for: .milliseconds(100))
                let view = try self.expectValue(self.editor.textView(for: block.id), "no text view")
                await self.rest(view)
                let point = view.convert(CGPoint(x: 30, y: view.caretRect(for: view.beginningOfDocument).midY), to: nil)
                func hitsText() -> Bool {
                    sequence(first: view.window?.hitTest(point, with: nil), next: { $0?.superview }).contains { $0 === view }
                }
                try self.expect(!hitsText(), "the text takes a click before the block is selected")
                try self.expect(blocks.testPress(block.id), "the press doesn't take the click")
                try self.expect(blocks.selected == [block.id], "selected \(blocks.selected.count)")
                try self.expect(self.editor.textView(for: block.id)?.isFirstResponder != true, "the caret went into the text")
                try? await Task.sleep(for: .milliseconds(100))
                try self.expect(hitsText(), "the selected block's text doesn't take the next click")
                try self.expect(!blocks.testPress(block.id), "the press takes the selected text's click")
                try await self.focus(block.id, at: 3)
                try self.expect(blocks.selected.isEmpty && blocks.typing == block.id, "typing \(String(describing: blocks.typing)), selected \(blocks.selected.count)")
                try self.expect(hitsText(), "the text being typed in doesn't take clicks")
            }
            await test("Esc in a block's text ends the editing and selects the block") {
                let block = try self.block("Loading older")
                await show(block.id)
                try await self.focus(block.id, at: 3)
                let view = try self.view()
                let escapes = (view.keyCommands ?? []).filter { $0.input == UIKeyCommand.inputEscape }.map(\.action)
                try self.expect(escapes == [Selector(("docSelectBlock:"))], "Esc does \(escapes)")
                try self.expect(self.escape(view), "no Esc command")
                try self.expect(blocks.selected == [block.id], "selected \(blocks.selected.count)")
                try self.expect(blocks.typing == nil && !view.isFirstResponder, "still typing")
            }
            await test("while text is edited, every block's text takes clicks; once it isn't, a click selects again") {
                let block = try self.block("Loading older")
                await show(block.id)
                let ids = order()
                let index = try self.expectValue(ids.firstIndex(of: block.id), "no index")
                let other = try self.expectValue(ids[(index + 1)...].first { id in
                    self.demo.rows.first { $0.block == id }?.text != nil && self.editor.textView(for: id) != nil
                }, "no text block after it on screen")
                let view = try self.expectValue(self.editor.textView(for: other), "no text view")
                await self.rest(view)
                let point = view.convert(CGPoint(x: 30, y: view.caretRect(for: view.beginningOfDocument).midY), to: nil)
                func hitsText() -> Bool {
                    sequence(first: view.window?.hitTest(point, with: nil), next: { $0?.superview }).contains { $0 === view }
                }
                try await self.focus(block.id, at: 3)
                try? await Task.sleep(for: .milliseconds(100))
                try self.expect(hitsText(), "another block's text doesn't take clicks while editing")
                try self.expect(!blocks.testPress(other), "the press takes another text's click while editing")
                self.editor.dismissKeyboard()
                try? await Task.sleep(for: .milliseconds(100))
                try self.expect(blocks.typing == nil, "still typing in \(String(describing: blocks.typing))")
                try self.expect(!hitsText(), "a text takes clicks with nothing edited")
            }
            await test("a right-click on a block selects it and shows its menu: Format has the format panel's sections under copy, paste and clear, its list turns it into a list item; Insert Below edits a new line under it; one undo each") {
                let block = try self.block("Loading older")
                await show(block.id)
                self.editor.dismissKeyboard()
                blocks.clear()
                try? await Task.sleep(for: .milliseconds(100))
                let before = order()
                let row = try self.expectValue(blocks.testRowFrame(block.id), "no row")
                try self.expect(blocks.testRightClick(at: CGPoint(x: row.midX, y: row.midY)), "no menu")
                FlooDesignContextMenus.close()
                try self.expect(blocks.selected == [block.id], "selected \(blocks.selected.count)")
                let titles = blocks.selectionMenu().flatMap(\.items).map(\.title)
                try self.expect(titles == ["Edit", "Cut", "Copy", "Duplicate", "Format", "Insert", "Sort", "Delete"], "menu \(titles)")
                let format = try self.expectValue(blocks.selectionMenu().flatMap(\.items).first { $0.title == "Format" }?.submenu, "no Format")
                let panel = DocFormatMenu(editor: self.editor).sections
                try self.expect(format.first?.items.map(\.title) == ["Copy Format", "Paste Format", "Clear Format"]
                                && format.dropFirst().map { $0.controls.map(\.id) } == panel.map { $0.controls.map(\.id) },
                                "Format \(format.map { $0.items.map(\.title) + $0.controls.map(\.id) })")
                DocFormatting(editor: self.editor).toggleList(.listItem(style: .bullet))
                try self.expect(self.demo.doc.block(block.id)?.kind == .listItem(style: .bullet), "kind \(String(describing: self.demo.doc.block(block.id)?.kind))")
                try await self.undo()
                try self.expect(self.demo.doc.block(block.id)?.kind == block.kind, "undo left \(String(describing: self.demo.doc.block(block.id)?.kind))")
                blocks.click(block.id)
                try self.perform(blocks.selectionMenu(), ["Insert", "Insert Below"])
                let index = try self.expectValue(before.firstIndex(of: block.id), "no index")
                let line = try self.expectValue(self.demo.doc.blocks.dropFirst(index + 1).first, "no line")
                try self.expect(order().count == before.count + 1 && line.kind == .paragraph && line.text.isEmpty, "inserted \(line.kind) \(line.text.length)")
                try self.expect(self.editor.selection?.head.block == line.id && blocks.selected.isEmpty, "the caret isn't in the new line")
                try await self.undo()
                try self.expect(order() == before, "undo didn't take the line back")
            }
            await test("several blocks selected: the menu says how many, has Group and Sort, no Edit nor Copy Format; Sort orders them by their words, Group moves them into a page block where they were; one undo each") {
                let block = try self.block("Loading older")
                await show(block.id)
                self.editor.dismissKeyboard()
                blocks.clear()
                try? await Task.sleep(for: .milliseconds(100))
                let before = order()
                let index = try self.expectValue(before.firstIndex(of: block.id), "no index")
                let next = try self.expectValue(self.demo.doc.blocks.dropFirst(index + 1).first { $0.indent <= block.indent && $0.kind.carriesText }, "no next")
                blocks.select([block.id, next.id])
                let menu = blocks.selectionMenu()
                let titles = menu.flatMap(\.items).map(\.title)
                try self.expect(menu.first?.title == "2 items" && titles == ["Group", "Cut", "Copy", "Duplicate", "Format", "Insert", "Sort", "Delete"], "menu \(String(describing: menu.first?.title)) \(titles)")
                let format = try self.expectValue(menu.flatMap(\.items).first { $0.title == "Format" }?.submenu, "no Format")
                try self.expect(format.first?.items.first.map { $0.title == "Copy Format" && !$0.isEnabled } == true, "Copy Format is on")
                // Z → A: the one whose words come later first.
                try self.perform(menu, ["Sort", "Sort Z → A"])
                let words = [block.id, next.id].map { self.demo.doc.block($0)?.text.string ?? "" }.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                let sorted = order().filter { $0 == block.id || $0 == next.id }.map { self.demo.doc.block($0)?.text.string ?? "" }
                try self.expect(sorted == words, "sorted \(sorted)")
                try await self.undo()
                try self.expect(order() == before, "undo didn't take the sort back")
                // Group: a page block where the first was, the blocks gone into it.
                blocks.select([block.id, next.id])
                let moved = blocks.groups([block.id, next.id]).flatMap { $0 }
                try self.perform(blocks.selectionMenu(), ["Group"])
                let page = try self.expectValue(self.demo.doc.blocks.dropFirst(index).first, "no page block")
                guard case .page(let made) = page.kind else { throw Failure(description: "not a page: \(page.kind)") }
                try self.expect(order().count == before.count - moved.count + 1 && moved.allSatisfy { self.demo.doc.block($0) == nil }
                                && blocks.selected == [page.id], "grouped into \(order().count) blocks, selected \(blocks.selected.count)")
                try self.expect(made.preview.hasPrefix(block.text.string.split(separator: "\n").first.map(String.init) ?? "-"), "preview \(made.preview)")
                try await self.undo()
                try self.expect(order() == before, "undo didn't take the group back")
            }
            await test("a drag on a block's text moves the block") {
                let block = try self.block("Loading older")
                await show(block.id)
                self.editor.dismissKeyboard()
                blocks.clear()
                try? await Task.sleep(for: .milliseconds(100))
                let before = order()
                let index = try self.expectValue(before.firstIndex(of: block.id), "no index")
                let target = before[index + 2]
                let frame = try self.expectValue(blocks.testRowFrame(target), "no row")
                try self.expect(blocks.testPress(block.id, toY: frame.maxY - 2), "the press doesn't take the drag")
                try self.expect(order().firstIndex(of: block.id) == index + 2, "at \(String(describing: order().firstIndex(of: block.id))), wanted \(index + 2)")
                try await self.undo()
                try self.expect(order() == before, "undo didn't restore the order")
            }
        }
        await test("a click on the handle selects the block; Delete removes it, undo brings it back") {
            let block = try self.block("Loading older")
            await show(block.id)
            let before = order()
            blocks.click(block.id)
            try self.expect(blocks.selected == [block.id], "selected \(blocks.selected.count)")
            // A phone's selection is the selection overlay's to draw.
            try self.expect(blocks.testHighlightFrames.count == (DocBlockController.usesHandles ? 1 : 0), "highlights \(blocks.testHighlightFrames.count)")
            blocks.deleteSelection()
            try self.expect(self.demo.doc.block(block.id) == nil && blocks.selected.isEmpty, "not deleted")
            try await self.undo()
            try self.expect(order() == before, "undo left \(self.demo.doc.blocks.count) blocks, had \(before.count)")
        }
        await test("dragging a block down two rows moves it there; one undo puts it back") {
            let block = try self.block("Loading older")
            await show(block.id)
            let before = order()
            let index = try self.expectValue(before.firstIndex(of: block.id), "no index")
            let target = before[index + 2]
            let frame = try self.expectValue(blocks.testRowFrame(target), "no row")
            blocks.testDrag(block.id, toY: frame.maxY - 2)
            try self.expect(order().firstIndex(of: block.id) == index + 2 && order()[index + 1] == target, "at \(String(describing: order().firstIndex(of: block.id))), wanted \(index + 2)")
            try await self.undo()
            try self.expect(order() == before, "undo didn't restore the order")
        }
        await test("dragging a block above the one before it moves it up") {
            let block = try self.block("Loading older")
            await show(block.id)
            let before = order()
            let index = try self.expectValue(before.firstIndex(of: block.id), "no index")
            let frame = try self.expectValue(blocks.testRowFrame(before[index - 1]), "no row")
            blocks.testDrag(block.id, toY: frame.minY + 2)
            try self.expect(order().firstIndex(of: block.id) == index - 1, "at \(String(describing: order().firstIndex(of: block.id))), wanted \(index - 1)")
        }
        await test("a list item moves with its nested items, each keeping its level where it lands") {
            let nested = try self.block("嵌套列表的缩进")
            let intro = try self.block("这篇文档由 DocKit")
            let group = blocks.groups([nested.id])[0]
            try self.expect(group.count == 3, "group of \(group.count)")
            let indents = group.compactMap { self.demo.doc.block($0)?.indent }
            try self.expect(blocks.move([nested.id], after: intro.id), "move failed")
            let ids = order()
            let at = try self.expectValue(ids.firstIndex(of: intro.id), "no intro")
            try self.expect(Array(ids[(at + 1)...(at + 3)]) == group, "group not after the paragraph")
            let moved = group.compactMap { self.demo.doc.block($0)?.indent }
            try self.expect(moved == indents, "indents \(moved), were \(indents)")
            try await self.undo()
            try self.expect(group.compactMap { self.demo.doc.block($0)?.indent } == indents, "undo left indents")
        }
        await test("Tab on selected blocks of any kind indents them, the row going in a step; ⇧Tab takes them back") {
            let paragraph = try self.block("Loading older")
            let table = try self.expectValue(self.demo.doc.blocks.first { if case .database = $0.kind { true } else { false } }, "no table")
            await show(paragraph.id)
            let before = try self.expectValue(blocks.testContentFrame(paragraph.id), "no frame")
            blocks.select([paragraph.id, table.id])
            blocks.indentSelection(by: 1)
            blocks.indentSelection(by: 1)
            try self.expect([paragraph.id, table.id].allSatisfy { self.demo.doc.block($0)?.indent == 2 }, "indents \([paragraph.id, table.id].map { self.demo.doc.block($0)?.indent ?? -1 })")
            try self.expect(blocks.selected == [paragraph.id, table.id], "the selection didn't stay")
            await show(paragraph.id)
            try? await Task.sleep(for: .milliseconds(700))
            let after = try self.expectValue(blocks.testContentFrame(paragraph.id), "no frame")
            let step = DocBlockController.indentWidth(2)
            try self.expect(abs(after.minX - before.minX - step) < 0.5 && abs(after.maxX - before.maxX) < 0.5, "frame \(after), was \(before)")
            let view = try self.expectValue(self.editor.textView(for: paragraph.id), "no text view")
            let text = view.convert(view.bounds, to: DocScrolling.list(of: view))
            try self.expect(text.minX >= after.minX - 0.5, "text at \(text.minX), block at \(after.minX)")
            blocks.indentSelection(by: -1)
            blocks.indentSelection(by: -1)
            blocks.indentSelection(by: -1)
            try self.expect([paragraph.id, table.id].allSatisfy { self.demo.doc.block($0)?.indent == 0 }, "not back at 0")
            blocks.clear()
        }
        await test("Indenting goes to five levels, whatever is around; a list item takes its items, those at five staying there") {
            let top = try self.block("嵌套列表的缩进")
            let group = blocks.groups([top.id])[0]
            let start = self.demo.doc.blocks
            // On screen, the bullet changes with the level: • on an even one, ◦ on an odd.
            await show(top.id)
            try self.expect(self.editor.textView(for: top.id)?.text.hasPrefix("◦") == true, "level \(top.indent) isn't ◦")
            self.editor.indent([top.id], by: 1)
            try? await Task.sleep(for: .milliseconds(300))
            let shown = try self.expectValue(self.editor.textView(for: top.id)?.text, "no text view")
            try self.expect(shown.hasPrefix("•"), "level 2's bullet is \(shown.prefix(1))")
            for _ in 0..<5 { self.editor.indent([top.id], by: 1) }
            let indents = group.compactMap { self.demo.doc.block($0)?.indent }
            try self.expect(indents == [5, 5, 5], "indents \(indents)")
            // An item can sit any level under the one before it: its bullet is its level's.
            let row = try self.expectValue(self.demo.rows.first { $0.block == top.id }?.text, "no text row")
            try self.expect(row.depth == 5, "depth \(row.depth)")
            // Out again: the first step takes the top alone (its items are at its level
            // now), then they're under it again and come along.
            for _ in 0..<6 { self.editor.indent([top.id], by: -1) }
            let out = group.compactMap { self.demo.doc.block($0)?.indent }
            try self.expect(out == [0, 1, 1], "indents \(out)")
            while self.demo.doc.blocks != start, self.demo.canUndo { try await self.undo() }
            try self.expect(self.demo.doc.blocks == start, "undo didn't take it back")
        }
        await test("a copy of the selection goes right after it, a table's with a database of its own") {
            let paragraph = try self.block("Loading older")
            let table = try self.expectValue(self.demo.doc.blocks.first { if case .database = $0.kind { true } else { false } }, "no table")
            blocks.select([paragraph.id, table.id])
            let before = self.demo.doc.blocks.count
            blocks.duplicateSelection()
            let ids = self.demo.doc.blocks.map(\.id)
            try self.expect(ids.count == before + 2, "blocks \(ids.count), had \(before)")
            let at = try self.expectValue(ids.firstIndex(of: table.id), "table gone")
            let copies = ids[(at + 1)...(at + 2)].compactMap { self.demo.doc.block($0) }
            try self.expect(copies.first?.text.string == paragraph.text.string, "first copy \(String(describing: copies.first?.text.string.prefix(12)))")
            let copied = try self.expectValue(copies.last?.kind.databaseID, "second copy isn't a table")
            try self.expect(copied != table.kind.databaseID && self.demo.doc.databases[copied] != nil, "copy shares or lacks its database")
            try self.expect(blocks.selected == copies.map(\.id), "selection isn't the copies")
            try await self.undo()
            try self.expect(self.demo.doc.blocks.count == before && self.demo.doc.databases[copied] == nil, "undo left the copies")
        }
        await test("styling the selection turns its text blocks, and leaves the rest") {
            let paragraph = try self.block("Loading older")
            let table = try self.expectValue(self.demo.doc.blocks.first { if case .database = $0.kind { true } else { false } }, "no table")
            blocks.select([paragraph.id, table.id])
            blocks.turnSelection(into: .quote)
            try self.expect(self.demo.doc.block(paragraph.id)?.kind == .quote, "paragraph is \(String(describing: self.demo.doc.block(paragraph.id)?.kind))")
            try self.expect(self.demo.doc.block(table.id)?.kind == table.kind, "table changed")
            blocks.clear()
        }
        await test("the selected links and files take the chosen layout together; one undo puts them back") {
            let media = self.demo.doc.blocks.filter { if case .link = $0.kind { true } else if case .file = $0.kind { true } else { false } }
            try self.expect(media.count >= 3, "only \(media.count) links and files")
            let before = media.map(\.kind)
            blocks.select(media.map(\.id))
            blocks.setLayout(.card)
            let layouts = media.compactMap { block -> DocLayout? in
                switch self.demo.doc.block(block.id)?.kind {
                case .link(let link)?: link.layout
                case .file(let file)?: file.layout
                default: nil
                }
            }
            try self.expect(layouts == Array(repeating: .card, count: media.count), "layouts \(layouts)")
            try self.expect(blocks.selectedLayouts == [.card], "selected layouts \(blocks.selectedLayouts)")
            try await self.undo()
            try self.expect(media.map { self.demo.doc.block($0.id)?.kind } == before, "undo didn't restore the layouts")
            blocks.clear()
        }
        await test("an image's new size changes in place; the rows after it follow in step and come to rest") {
            // The demo's images share a row: a line after the first stands it alone.
            let first = try self.expectValue(self.demo.doc.blocks.first { if case .image = $0.kind { true } else { false } }, "no image")
            _ = self.demo.edit([.insertBlock(block: DocBlock(id: self.demo.newBlockID(), kind: .paragraph, text: DocText(string: "·")), after: first.id)],
                               before: nil, after: nil)
            try? await Task.sleep(for: .milliseconds(300))
            let (image, next) = try self.expectValue(self.mediaAlone { if case .image = $0 { true } else { false } }, "no image alone before a row")
            guard case .image(let old) = image.kind else { throw Failure(description: "not an image") }
            // The change that moves its bottom most: its size or its fit.
            var sized = old, fitted = old
            sized.size = old.size == .large ? .auto : .large
            fitted.fit = old.fit == .fill ? .fit : .fill
            let width = blocks.testPageWidth
            let height = { (image: DocImage) in DocMediaLayout.imageHeight(image, width: width) }
            let new = abs(height(sized) - height(old)) > abs(height(fitted) - height(old)) ? sized : fitted
            try self.expect(abs(height(new) - height(old)) > 30, "no change moves the image's bottom")
            await show(image.id)
            try await self.expectReshape(image.id, next: next) {
                blocks.setImage(fit: new.fit, size: new.size, of: [image.id])
            }
        }
        await test("a file's new layout: its box goes from one size to the other; the rows after it follow in step and come to rest") {
            let (file, next) = try self.expectValue(self.mediaAlone {
                if case .file(let file) = $0 { file.layout != .card } else { false }
            }, "no small or regular file alone before a row")
            guard case .file(let old) = file.kind else { throw Failure(description: "not a file") }
            await show(file.id)
            try await self.expectReshape(file.id, next: next) {
                blocks.setLayout(old.layout == .small ? .regular : .small, of: [file.id])
            }
        }
        await test("a paragraph made a quote, boxed and back: its text keeps its view and goes to its place with the rows after it") {
            let paragraph = try self.block("这篇文档由 DocKit")
            let next = try self.blockAfter(paragraph.id).id
            await show(paragraph.id)
            blocks.testCenter(paragraph.id)
            let view = try self.expectValue(self.editor.textView(for: paragraph.id), "no text view")
            let changes: [(String, () -> Void)] = [
                ("quote", { self.editor.setKind(.quote, of: [paragraph.id]) }),
                ("box", { self.editor.setDecoration(.block, of: [paragraph.id]) }),
                ("unbox", { self.editor.setDecoration(nil, of: [paragraph.id]) }),
                ("paragraph", { self.editor.setKind(.paragraph, of: [paragraph.id]) }),
            ]
            for (name, change) in changes {
                try await self.expectInStep(paragraph.id, view: view, next: next, name) { blocks.reshape(change) }
                try self.expect(self.editor.textView(for: paragraph.id) === view, "\(name): the text has another view")
            }
        }
        await test("a paragraph made a quote and back again and again before it lands: its text and the rows after it keep together") {
            let paragraph = try self.block("这篇文档由 DocKit")
            let next = try self.blockAfter(paragraph.id).id
            await show(paragraph.id)
            blocks.testCenter(paragraph.id)
            let view = try self.expectValue(self.editor.textView(for: paragraph.id), "no text view")
            try await Task.sleep(for: .milliseconds(300))
            @MainActor func sample() throws -> (edge: CGFloat, next: CGFloat) {
                (try self.expectValue(blocks.testShownFrame(of: view, in: paragraph.id)?.minX, "no text drawn"),
                 try self.expectValue(blocks.testShownRowFrame(next)?.minY, "next row not on screen"))
            }
            let start = try sample()
            let began = CACurrentMediaTime()
            let kinds: [BlockKind] = [.quote, .paragraph, .quote, .paragraph]
            var samples: [(time: Double, edge: CGFloat, next: CGFloat)] = []
            for (index, kind) in kinds.enumerated() {
                blocks.reshape { self.editor.setKind(kind, of: [paragraph.id]) }
                let until = index == kinds.count - 1 ? 0.6 : 0.09
                let from = CACurrentMediaTime()
                while CACurrentMediaTime() - from < until {
                    try await Task.sleep(for: .milliseconds(8))
                    let shown = try sample()
                    samples.append((CACurrentMediaTime() - began, shown.edge, shown.next))
                }
            }
            let end = try self.expectValue(samples.last, "no samples")
            let trace = samples.map { String(format: "%.3f:%.1f/%.1f", $0.time, $0.edge - end.edge, $0.next - end.next) }.joined(separator: " ")
            docTestLog("DOCTEST TRACE back and forth \(start.edge)/\(start.next) → \(trace)")
            try self.expect(abs(end.edge - start.edge) < 0.5 && abs(end.next - start.next) < 0.5, "not back where it began: \(trace)")
            try self.expect(samples.contains { abs($0.edge - end.edge) > 6 }, "the text never moved: \(trace)")
            try self.expect(self.editor.textView(for: paragraph.id) === view, "the text has another view")
            // Every update moves the text in and the next row down in the same proportion,
            // so on the way, however the updates overlap, the next row is as far from its
            // place as that proportion of the text's distance from its place.
            let pairs = samples.map { (Double($0.edge - end.edge), Double($0.next - end.next)) }
            let ratio = pairs.map { $0.0 * $0.1 }.reduce(0, +) / max(pairs.map { $0.0 * $0.0 }.reduce(0, +), 1e-9)
            let apart = pairs.filter { abs($0.1 - ratio * $0.0) > 1.5 }
            try self.expect(ratio > 0.5, "the next row doesn't follow the text (ratio \(ratio)): \(trace)")
            try self.expect(apart.isEmpty, "\(apart.count) frames out of step (ratio \(ratio)): \(trace)")
        }
        await test("a selected image fills and goes large, and draws at the page's width") {
            let image = try self.expectValue(self.demo.doc.blocks.first { if case .image = $0.kind { true } else { false } }, "no image")
            await show(image.id)
            blocks.select([image.id])
            blocks.setImage(fit: .fill, size: .large)
            guard case .image(let changed)? = self.demo.doc.block(image.id)?.kind else { throw Failure(description: "not an image") }
            try self.expect(changed.fit == .fill && changed.size == .large, "image \(changed)")
            try? await Task.sleep(for: .milliseconds(400))
            let row = try self.expectValue(blocks.testRowFrame(image.id), "no row")
            let height = DocMediaLayout.imageHeight(changed, width: blocks.testPageWidth)
            try self.expect(abs(row.height - (height + (self.demo.spacingAbove[image.id.description] ?? 0))) < 2, "row \(row.height), image \(height)")
            blocks.clear()
        }
        await test("floo's cards: their sources compile; pieces of one grid 8 apart, in two columns where the page has room, a collection as a detail, each drawn at its place") {
            let cards = self.demo.doc.blocks.compactMap { block -> (DocBlockID, DocCard)? in
                if case .card(let card) = block.kind { (block.id, card) } else { nil }
            }
            try self.expect(cards.count == 5, "\(cards.count) cards")
            for (_, card) in cards {
                let session = DocMediaLayout.session(for: card)
                try self.expect(session.diagnostics.isEmpty && session.tree.issues.isEmpty && !session.tree.roots.isEmpty,
                                "\(card.size): \(session.diagnostics.map(\.message)) \(session.tree.issues)")
            }
            let page = blocks.testPageWidth
            // The tiled grid at 8: a glance 176 square, a summary 360 by 176, a detail 360
            // square (a collection too, on a page); two columns and the gap are 728, at no
            // less than 3/4 scale.
            let columns = page / 728 >= 0.75 ? 2 : 1
            let scale = columns == 2 ? page / 728 : page / 360
            let designs: [String: CGSize] = ["glance": CGSize(width: 176, height: 176), "summary": CGSize(width: 360, height: 176),
                                             "detail": CGSize(width: 360, height: 360), "collection": CGSize(width: 360, height: 360)]
            for (id, card) in cards {
                await show(id)
                let frame = try self.expectValue(blocks.testContentFrame(id), "no frame for \(card.size)")
                let design = try self.expectValue(designs[card.size], "a \(card.size)")
                let width = design.width * scale, height = design.height * scale
                try self.expect(abs(frame.width - width) < 1 && abs(frame.height - height) < 1,
                                "\(card.size) at \(frame), wanted \(width)x\(height) on a page \(page) wide")
                let drawn = try self.expectValue(blocks.testShownBox(id)?.frame, "\(card.size) not drawn")
                try self.expect(abs(drawn.width - width) < 2 && abs(drawn.height - height) < 2, "\(card.size) drawn at \(drawn), placed at \(frame)")
            }
            // In the order they come: two glances, a summary, a detail, a collection.
            let frames = try cards.map { try self.expectValue(blocks.testContentFrame($0.0), "no frame for \($0.1.size)") }
            // As far apart down as across: the gap at the cards' scale.
            let gutter = 8 * scale
            try self.expect(frames[0].minY == frames[1].minY && abs(frames[1].minX - frames[0].maxX - gutter) < 1, "glances at \(frames[0]) and \(frames[1])")
            if columns == 2 {
                try self.expect(frames[2].minY == frames[0].minY && abs(frames[2].minX - frames[1].maxX - gutter) < 1, "the summary not beside the glances: \(frames)")
                try self.expect(frames[3].minY == frames[4].minY && abs(frames[4].minX - frames[3].maxX - gutter) < 1, "the detail and the collection not side by side: \(frames)")
                try self.expect(abs(frames[3].minY - frames[2].maxY - gutter) < 1, "the second line not \(gutter) below the first: \(frames)")
            } else {
                try self.expect(abs(frames[2].minY - frames[0].maxY - gutter) < 1 && abs(frames[3].minY - frames[2].maxY - gutter) < 1, "one column, not \(gutter) apart: \(frames)")
            }
            // Opening one is the app's to say.
            var opened: (DocBlockID, DocCard)?
            blocks.openCard = { opened = ($0, $1) }
            blocks.open(cards[2].0)
            blocks.openCard = nil
            try self.expect(opened?.0 == cards[2].0 && opened?.1 == cards[2].1, "opened \(String(describing: opened?.1.size))")
        }
        await test("floo's views: their sources compile; each the page's width and as tall as it draws, its controls live, what it sends the agent's") {
            let views = self.demo.doc.blocks.compactMap { block -> (DocBlockID, DocView)? in
                if case .view(let view) = block.kind { (block.id, view) } else { nil }
            }
            try self.expect(views.count == 3, "\(views.count) views")
            let page = blocks.testPageWidth
            for (index, (id, view)) in views.enumerated() {
                let session = DocMediaLayout.session(for: view)
                try self.expect(session.diagnostics.isEmpty && session.tree.issues.isEmpty && !session.tree.roots.isEmpty,
                                "view \(index): \(session.diagnostics.map(\.message)) \(session.tree.issues)")
                await show(id)
                let frame = try self.expectValue(blocks.testContentFrame(id), "no frame for view \(index)")
                let drawn = try self.expectValue(DocMediaLayout.boxSize(.view(view: view), width: page), "view \(index) not measured")
                try self.expect(abs(frame.width - page) < 1 && abs(drawn.width - page) < 1, "view \(index) \(frame.width) wide (drawn \(drawn.width)), the page \(page)")
                // Taller than the guess the list starts from, and its row as tall as it draws.
                let spacing = self.demo.rows.first { $0.block == id }.map { $0.spacingAbove + $0.spacingBelow } ?? 0
                // Measured once it's drawn: up to 2 s for a slow device.
                for _ in 0..<20 where abs((blocks.testRowFrame(id)?.height ?? 0) - (drawn.height + spacing)) >= 2 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let row = try self.expectValue(blocks.testRowFrame(id), "no row for view \(index)")
                try self.expect(drawn.height > page * 0.75 / 2 && abs(row.height - (drawn.height + spacing)) < 2,
                                "view \(index): row \(row.height), drawn \(drawn.height), spacing \(spacing)")
                // Its controls take clicks, unselected (its handle selects it).
                if DocBlockController.usesHandles {
                    try self.expect(blocks.blockTakes(id, editsText: false), "view \(index) doesn't take clicks")
                }
                // -docViewShots <name>: each drawn to <name>-<n>.png in the app's (sandboxed) temporary folder.
                if let name = UserDefaults.standard.string(forKey: "docViewShots") {
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(index).png").path
                    DocBlockController.drawWindow(to: path)
                    docTestLog("DOCTEST NOTE view shot \(path)")
                }
            }
            // What a view sends goes to the agent; any other tool is refused.
            let host = try self.expectValue(blocks.cardHost, "no host")
            let answer = try await host.call("send", arguments: ["message": .string("weekend: relaxed")])
            try self.expect(answer != .null && self.demo.sentToAgent.last == "weekend: relaxed", "sent \(self.demo.sentToAgent), answer \(answer)")
            let refused = (try? await host.call("mail_send", arguments: [:])) == nil
            try self.expect(refused, "another tool ran")
        }
        await test("a collection: one set of records as a kanban and a table, each change a step that undoes") {
            let collections = self.editor.collections
            @MainActor func current() throws -> (id: DocBlockID, collection: DocCollection, database: Database) {
                let block = try self.expectValue(self.demo.doc.blocks.first { if case .collection = $0.kind { true } else { false } }, "no collection")
                guard case .collection(let collection) = block.kind, let database = self.demo.doc.databases[collection.database] else { throw Failure(description: "no database") }
                return (block.id, collection, database)
            }
            var (id, collection, database) = try current()
            await show(id)
            // Drawn, wider than nothing, as tall as its kanban, its controls live.
            let frame = try self.expectValue(blocks.testContentFrame(id), "no frame")
            try self.expect(frame.height > 200, "the collection is \(frame.height) tall")
            if DocBlockController.usesHandles { try self.expect(blocks.blockTakes(id, editsText: false), "its controls don't take clicks") }
            guard case .kanban(let group, _, _)? = collection.currentView?.layout,
                  case .select(let options)? = database.columns.first(where: { $0.id == group })?.type else { throw Failure(description: "not a kanban") }
            @MainActor func lane(_ option: OptionID) throws -> [RowID] {
                try current().database.rows.filter { DocCollectionController.option(of: $0, in: group) == option }.map(\.id)
            }
            // A card added to a column holds its option, at the column's end.
            let before = try lane(options[1].id)
            let added = try self.expectValue(collections.addRecord(to: id, in: (group, .select(option: options[1].id))), "no card added")
            let holds = try lane(options[1].id)
            try self.expect(holds == before + [added], "the column holds \(holds)")
            // A card dropped on another column, before its first card.
            let target = try lane(options[2].id)
            collections.move(added, from: .select(option: options[1].id), to: .select(option: options[2].id), groupedBy: group, before: target.first, in: id)
            let moved = try lane(options[2].id), left = try lane(options[1].id)
            try self.expect(moved == [added] + target && left == before, "moved: \(moved), left \(left)")
            try await self.undo()
            let back = try lane(options[1].id)
            try self.expect(back == before + [added], "the move undid to \(back)")
            try await self.undo()
            let gone = try lane(options[1].id)
            try self.expect(gone == before, "the card stayed: \(gone)")
            // A new column, an option of its own.
            collections.addOption("阻塞", color: "orange", to: group, in: id)
            (_, _, database) = try current()
            guard case .select(let more)? = database.columns.first(where: { $0.id == group })?.type else { throw Failure(description: "no select") }
            try self.expect(more.count == options.count + 1 && more.last?.color == "orange", "options \(more.map(\.name))")
            try await self.undo()
            // The table: the same records; a sum in its calculation row.
            let table = try self.expectValue(collection.views.first { if case .table = $0.layout { true } else { false } }, "no table view")
            collections.show(table.id, in: id)
            (_, collection, database) = try current()
            try self.expect(collection.currentView?.id == table.id, "showing \(collection.currentView?.name ?? "-")")
            let hours = try self.expectValue(database.columns.first { $0.type == .number }, "no number column")
            let sum = DocCollectionMath.value(.sum, of: hours, in: database.rows)
            let numbers: [Double] = database.rows.compactMap { if case .number(let n)? = $0.cells[hours.id] { n } else { nil } }
            let expected = numbers.reduce(0.0) { $0 + $1 }
            try self.expect(sum == expected.formatted(.number.precision(.fractionLength(0...2))), "sum \(sum), expected \(expected)")
            try await self.undo()
            (_, collection, _) = try current()
            try self.expect(collection.currentView?.id != table.id, "showing the table after undo")
        }
        await test("a collection's cells take what their fields hold: a number as written here, a link made whole, other text not at all") {
            let collections = self.editor.collections
            let block = try self.expectValue(self.demo.doc.blocks.first { if case .collection = $0.kind { true } else { false } }, "no collection")
            guard case .collection(let collection) = block.kind, let original = self.demo.doc.databases[collection.database] else { throw Failure(description: "no database") }
            @MainActor func cell(_ row: RowID, _ column: ColumnID) -> CellValue? {
                self.demo.doc.databases[collection.database]?.rows.first { $0.id == row }?.cells[column]
            }
            let row = original.rows[0].id
            let hours = try self.expectValue(original.columns.first { $0.type == .number }, "no number column")
            let before = cell(row, hours.id)
            collections.setText("12abc", row: row, column: hours.id, in: block.id)
            try self.expect(cell(row, hours.id) == before, "a word went into the number: \(String(describing: cell(row, hours.id)))")
            let thousands = 1234.5.formatted()
            collections.setText(thousands, row: row, column: hours.id, in: block.id)
            try self.expect(cell(row, hours.id) == .number(value: 1234.5), "\(thousands) is \(String(describing: cell(row, hours.id)))")

            let link = try self.expectValue(collections.addField("链接", type: .url, to: block.id), "no field")
            collections.setText("example.com/plan", row: row, column: link, in: block.id)
            try self.expect(cell(row, link) == .url(value: "https://example.com/plan"), "the link is \(String(describing: cell(row, link)))")
            collections.setText("not a link", row: row, column: link, in: block.id)
            try self.expect(cell(row, link) == .url(value: "https://example.com/plan"), "words went into the link")

            // A day typed is yyyy-MM-dd or as days show, never a lenient guess.
            try self.expect(DocFieldText.day(from: "2026-10-20") == Day(LocalDate(year: 2026, month: 10, day: 20)), "2026-10-20 isn't that day")
            try self.expect(DocFieldText.day(from: "2026-13-40") == nil, "2026-13-40 read as a day")
            // A date cell's calendar is the collection's panel, one at a time.
            let due = try self.expectValue(original.columns.first { $0.type == .date }, "no date column")
            collections.show(.date(row: row, column: due.id), in: block.id)
            try self.expect(collections.isShowing(.date(row: row, column: due.id), in: block.id), "the calendar isn't showing")
            collections.show(.options(row: row, column: original.columns.first { if case .select = $0.type { true } else { false } }!.id), in: block.id)
            try self.expect(!collections.isShowing(.date(row: row, column: due.id), in: block.id), "two panels at once")
            collections.close(.options(row: row, column: original.columns.first { if case .select = $0.type { true } else { false } }!.id), in: block.id)

            for _ in 0..<4 where self.demo.doc.databases[collection.database] != original { try await self.undo() }
            try self.expect(self.demo.doc.databases[collection.database] == original, "the cells didn't undo")
        }
        await test("a collection's fields, sorting, filters, search and groups: each a step that undoes, the views kept whole") {
            let collections = self.editor.collections
            @MainActor func current() throws -> (id: DocBlockID, collection: DocCollection, database: Database) {
                let block = try self.expectValue(self.demo.doc.blocks.first { if case .collection = $0.kind { true } else { false } }, "no collection")
                guard case .collection(let collection) = block.kind, let database = self.demo.doc.databases[collection.database] else { throw Failure(description: "no database") }
                return (block.id, collection, database)
            }
            @MainActor func snapshot() throws -> DocCollectionSnapshot {
                let (id, collection, database) = try current()
                return DocCollectionSnapshot(block: id, collection: collection, database: database)
            }
            let (id, start, original) = try current()
            let kanban = try self.expectValue(start.views.first { $0.layout.isKanban }, "no kanban")
            let table = try self.expectValue(start.views.first { !$0.layout.isKanban }, "no table")
            let group = try self.expectValue(kanban.layout.groupBy, "no group")
            let title = try self.expectValue(DocCollectionController.titleColumn(of: original), "no title")
            let hours = try self.expectValue(original.columns.first { $0.type == .number }, "no number column")
            @MainActor func view(_ id: CollectionViewID) throws -> CollectionView {
                try self.expectValue(current().collection.views.first { $0.id == id }, "no view")
            }
            @MainActor func titles(_ view: CollectionView) throws -> [String] {
                try collections.rows(snapshot(), view).map { DocFieldText.text($0.cells[title.id], in: title) }
            }

            // A field added, typed into, then made a select: its words become its options.
            let note = try self.expectValue(collections.addField("标签", type: .text, to: id), "no field")
            collections.setText("前端", row: original.rows[0].id, column: note, in: id)
            collections.setText("后端", row: original.rows[1].id, column: note, in: id)
            collections.setText("前端", row: original.rows[2].id, column: note, in: id)
            collections.editField(note, name: "方向", type: .select(options: []), in: id)
            var database = try current().database
            let field = try self.expectValue(database.columns.first { $0.id == note }, "the field is gone")
            try self.expect(field.name == "方向" && DocFieldText.options(field).map(\.name) == ["前端", "后端"], "options \(DocFieldText.options(field).map(\.name))")
            try self.expect(DocFieldText.text(database.rows[2].cells[note], in: field) == "前端", "a value didn't become its option")
            try await self.undo()
            database = try current().database
            try self.expect(database.rows[2].cells[note] == .text(value: "前端"), "the type change undid to \(String(describing: database.rows[2].cells[note]))")
            // Deleting it takes it out of the views too; undo brings both back.
            collections.setHidden(note, true, in: table.id, of: id)
            collections.deleteField(note, in: id)
            try self.expect(try current().database.columns.allSatisfy { $0.id != note } && !(try view(table.id).layout.hidden.contains(note)), "the field stayed")
            try await self.undo()
            try self.expect(try view(table.id).layout.hidden.contains(note), "the view didn't get its hidden field back")
            try await self.undo()
            for _ in 0..<4 { try await self.undo() }
            try self.expect(try current().database == original, "the field's steps didn't all undo")

            // Sorting by hours, most first; a filter on the group; a search over every field.
            collections.setSort([DatabaseSort(column: hours.id, ascending: false)], in: table.id, of: id)
            let hoursShown = try collections.rows(snapshot(), view(table.id)).compactMap { if case .number(let n)? = $0.cells[hours.id] { n } else { nil } }
            try self.expect(hoursShown == hoursShown.sorted(by: >), "sorted \(hoursShown)")
            guard case .select(let options)? = original.columns.first(where: { $0.id == group })?.type else { throw Failure(description: "no options") }
            let doing = options[1]
            collections.setFilters([CollectionFilter(column: group, condition: .is, value: .select(option: doing.id))], in: table.id, of: id)
            let kept = try collections.rows(snapshot(), view(table.id))
            try self.expect(!kept.isEmpty && kept.allSatisfy { DocCollectionController.option(of: $0, in: group) == doing.id }, "the filter kept \(kept.count)")
            // A value typed into a filter is one step.
            let typed = CollectionFilter(column: title.id, condition: .contains)
            for text in ["评", "评测"] {
                var filter = typed
                filter.value = .text(value: text)
                collections.setFilters([filter], typing: "value", in: table.id, of: id)
            }
            let typedKept = try titles(view(table.id))
            try self.expect(typedKept.allSatisfy { $0.contains("评测") }, "the typed filter kept \(typedKept)")
            try await self.undo()
            try self.expect(try view(table.id).filters.first?.condition == .is, "the typing took more than one undo")
            try await self.undo()
            try await self.undo()
            try self.expect(try view(table.id) == table, "the view didn't undo whole")
            collections.searches[id] = "手册"
            let found = try titles(view(table.id))
            try self.expect(found == ["上线手册"], "the search found \(found)")
            collections.searches[id] = nil

            // Hidden and moved fields; the table as a kanban and back.
            collections.setHidden(hours.id, true, in: table.id, of: id)
            collections.moveField(group, before: title.id, in: table.id, of: id)
            let fields = DocCollectionController.fields(try view(table.id), of: original).map(\.id)
            try self.expect(fields.first == group && !fields.contains(hours.id), "fields \(fields)")
            collections.setLayout(kanban: true, in: table.id, of: id)
            let firstSelect = try self.expectValue(DocCollectionController.selects(in: original).first, "no select")
            try self.expect(try view(table.id).layout == .kanban(groupBy: firstSelect.id, hidden: [hours.id], sort: []), "not a kanban")
            for _ in 0..<3 { try await self.undo() }
            try self.expect(try view(table.id) == table, "the layout steps didn't undo")

            // The table grouped by the select: each record under its option, the group of
            // none first; a kanban made of it keeps the field, a table made of that has none.
            collections.setGroup(group, in: table.id, of: id)
            let groups = try self.expectValue(view(table.id).groups(of: collections.rows(snapshot(), view(table.id)), in: original), "not grouped")
            let order = [""] + options.map(\.id.description)
            try self.expect(groups.map(\.rows.count).reduce(0, +) == original.rows.count
                            && groups.map(\.key) == order.filter { key in groups.contains { $0.key == key } }, "groups \(groups.map(\.key))")
            collections.setLayout(kanban: true, in: table.id, of: id)
            try self.expect(try view(table.id).layout.groupBy == group, "the kanban took another field")
            // Back to a table: not grouped, as it isn't asked to be.
            collections.setLayout(kanban: false, in: table.id, of: id)
            try self.expect(try view(table.id).layout == .table(hidden: table.layout.hidden, sort: table.layout.sort), "the table kept a group")
            for _ in 0..<3 { try await self.undo() }
            try self.expect(try view(table.id) == table, "the grouping didn't undo")
            // A kanban's group left out, and another dragged first: the order turns manual.
            let lanes = DocCollectionController.lanes(kanban, of: try collections.rows(snapshot(), kanban), in: original).map(\.key)
            collections.hide(group: lanes[0], in: kanban.id, of: id)
            try self.expect(!DocCollectionController.lanes(try view(kanban.id), of: original.rows, in: original).contains { $0.key == lanes[0] }, "the group showed")
            collections.moveGroup(lanes[2], before: lanes[0], among: lanes, in: kanban.id, of: id)
            let moved = try view(kanban.id)
            try self.expect(moved.grouping.order == .manual && DocCollectionController.lanes(moved, of: original.rows, in: original).first?.key == lanes[2], "order \(moved.grouping)")
            for _ in 0..<2 { try await self.undo() }
            try self.expect(try view(kanban.id) == kanban, "the groups' steps didn't undo")

            // A card at the top of a column; picked rows go together.
            let top = try self.expectValue(collections.addRecord(to: id, in: (group, .select(option: doing.id)), atTop: true), "no card")
            let lane = try current().database.rows.filter { DocCollectionController.option(of: $0, in: group) == doing.id }
            try self.expect(lane.first?.id == top, "the card isn't at the top")
            try await self.undo()
            collections.togglePicked(original.rows[0].id, in: id)
            collections.togglePicked(original.rows[2].id, in: id)
            collections.delete(rows: collections.selectedRows[id] ?? [], in: id)
            try self.expect(try current().database.rows.count == original.rows.count - 2, "picked rows stayed")
            try await self.undo()
            let back = try current().database
            try self.expect(back == original, "the rows came back as \(back.rows.count)")
            // A record duplicated (a card's Duplicate Item): the copy right after it, its fields the same.
            let copy = try self.expectValue(collections.duplicate(row: original.rows[1].id, in: id), "no copy")
            let copied = try current().database.rows
            try self.expect(copied.count == original.rows.count + 1 && copied[2].id == copy && copied[2].cells == original.rows[1].cells,
                            "the copy is at \(String(describing: copied.firstIndex { $0.id == copy }))")
            try await self.undo()
            // Picked rows duplicated in one step, each copy after its own.
            let copies = collections.duplicate(rows: [original.rows[0].id, original.rows[2].id], in: id)
            let twice = try current().database.rows.map(\.id)
            try self.expect(copies.count == 2 && twice[1] == copies[0] && twice[4] == copies[1], "the copies are at \(copies.map { twice.firstIndex(of: $0) })")
            try await self.undo()
            // A row inserted above one in a grouped table: before it, in its group.
            let above = try self.expectValue(collections.insertRecord(beside: original.rows[1].id, below: false, groupedBy: group, in: id), "no row")
            let inserted = try current().database.rows
            try self.expect(inserted[1].id == above && inserted[1].cells == [group: original.rows[1].cells[group]].compactMapValues { $0 },
                            "the row is at \(String(describing: inserted.firstIndex { $0.id == above }))")
            try await self.undo()
            try self.expect(try current().database == original, "the rows' steps didn't undo")

            // A multi-select ticked from its options; a new option typed in.
            let tags = try self.expectValue(collections.addField("标记", type: .multiSelect(options: []), to: id), "no field")
            let urgent = try self.expectValue(collections.addOption("紧急", to: tags, in: id), "no option")
            let later = try self.expectValue(collections.addOption("以后", to: tags, in: id), "no option")
            collections.toggle(urgent, row: original.rows[0].id, column: tags, in: id)
            collections.toggle(later, row: original.rows[0].id, column: tags, in: id)
            collections.toggle(urgent, row: original.rows[0].id, column: tags, in: id)
            let ticked = try current().database.rows[0].cells[tags]
            try self.expect(ticked == .multiSelect(options: [later]), "ticked \(String(describing: ticked))")
            collections.deleteOption(later, in: tags, of: id)
            try self.expect(try current().database.rows[0].cells[tags] == nil, "the option stayed on the record")
            for _ in 0..<7 { try await self.undo() }
            try self.expect(try current().database == original, "the multi-select steps didn't all undo")
            try self.expect(try current().collection == start, "the collection didn't come back whole")
        }
        await test("a page block opens its page; its title and preview, changed there, go back up as one undo step") {
            let pages = try self.expectValue(self.pages, "no pages")
            let block = try self.expectValue(self.demo.doc.blocks.first { if case .page = $0.kind { true } else { false } }, "no page block")
            guard case .page(let page) = block.kind else { return }
            let root = pages.current
            pages.open(block.id)
            try? await Task.sleep(for: .milliseconds(300))
            let inside = pages.current
            try self.expect(inside !== root && pages.path.count == 2, "not in the page")
            let heading = try self.expectValue(inside.demo.doc.blocks.first, "an empty page")
            try self.expect(heading.kind == .heading(level: 1) && heading.text.string == page.title, "the page starts \(heading.kind) \(heading.text.string)")
            inside.demo.edit([.insertText(block: heading.id, at: heading.text.length, text: DocText(string: "（草稿）"))], before: nil, after: nil)
            try self.expect(inside.title == page.title + "（草稿）", "the path says \(inside.title)")
            pages.back()
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(pages.current === root, "not back")
            guard case .page(let renamed)? = self.demo.doc.block(block.id)?.kind else { throw Failure(description: "the block isn't a page") }
            try self.expect(renamed.title == page.title + "（草稿）" && renamed.doc == page.doc, "the block says \(renamed.title)")
            try self.expect(!page.preview.isEmpty && renamed.preview == DocPage.summary(of: inside.demo.doc).preview, "the block's preview says \(renamed.preview)")
            try await self.undo()
            guard case .page(let undone)? = self.demo.doc.block(block.id)?.kind else { throw Failure(description: "the block isn't a page") }
            try self.expect(undone.title == page.title, "the title's undo left \(undone.title)")
            // Opened again, it's as it was left.
            pages.open(block.id)
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(pages.current === inside && inside.demo.doc.blocks.first?.text.string == page.title + "（草稿）", "the page came back new")
            pages.back(to: 0)
            try? await Task.sleep(for: .milliseconds(300))
            try await self.undo()
        }
        await test("a page block goes in as a card opens: a click selects it and a double click goes in on the Mac, a tap goes in and a long press selects it on a phone") {
            let pages = try self.expectValue(self.pages, "no pages")
            let blocks = self.editor.blocks
            let block = try self.expectValue(self.demo.doc.blocks.first { if case .page = $0.kind { true } else { false } }, "no page block")
            blocks.testCenter(block.id)
            try? await Task.sleep(for: .milliseconds(400))
            if DocBlockController.usesHandles {
                try self.expect(blocks.testPress(block.id), "the click isn't the list's")
                try self.expect(blocks.selected == [block.id] && pages.path.count == 1, "selected \(blocks.selected.count), \(pages.path.count) deep")
                // The second click of a double click.
                blocks.open(block.id)
            } else {
                try self.expect(blocks.testLiftAndLetGo(block.id) && blocks.selected == [block.id], "a long press didn't select it")
                try self.expect(pages.path.count == 1, "a long press went in")
                blocks.endSelecting()
                blocks.testClick(block.id)
            }
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(pages.path.count == 2, "not in the page")
            pages.back()
            try? await Task.sleep(for: .milliseconds(300))
            blocks.clear()
        }
        await test("a record opens as its page: the record's title over its fields, edited where the collection is; the title and what's written come back") {
            let pages = try self.expectValue(self.pages, "no pages")
            let block = try self.expectValue(self.demo.doc.blocks.first { if case .collection = $0.kind { true } else { false } }, "no collection")
            guard case .collection(let collection) = block.kind, let database = self.demo.doc.databases[collection.database] else { return }
            let title = try self.expectValue(DocCollectionController.titleColumn(of: database), "no title field")
            let record = database.rows[0]
            let named = DocFieldText.text(record.cells[title.id], in: title)
            let before = self.demo.doc
            pages.openRecord(record.id, in: block.id)
            try? await Task.sleep(for: .milliseconds(300))
            let inside = pages.current
            let link = try self.expectValue(inside.record, "not a record's page")
            try self.expect(inside.id.rawValue == record.id.rawValue && inside.title == named, "the page \(inside.title), \(inside.id)")
            let heading = try self.expectValue(inside.demo.doc.blocks.first, "an empty page")
            let fieldsRow = inside.demo.rows.firstIndex { $0.recordFields != nil }
            try self.expect(fieldsRow == 1 && inside.demo.rows[1].recordFields == database.columns.count - 1, "fields at \(String(describing: fieldsRow))")
            // A field set on the page is the record's, one step in the collection's document.
            let number = try self.expectValue(database.columns.first { $0.type == .number }, "no number field")
            link.controller.set(.number(value: 42), row: record.id, column: number.id, in: block.id)
            try self.expect(link.record?.cells[number.id] == .number(value: 42), "the field didn't take it")
            // A new title and a line written: back above, the record's title, and its page shows.
            inside.demo.edit([.insertText(block: heading.id, at: heading.text.length, text: DocText(string: "!"))], before: nil, after: nil)
            let line = try self.expectValue(inside.demo.doc.blocks.last, "no line")
            inside.demo.edit([.insertText(block: line.id, at: 0, text: DocText(string: "notes"))], before: nil, after: nil)
            try self.expect(!pages.recordHasPage(record.id), "written before it was left")
            pages.back()
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(link.title == named + "!" && pages.recordHasPage(record.id), "the record \(link.title ?? "-"), page \(pages.recordHasPage(record.id))")
            // Opened again, the page takes the record's title as it is now.
            self.editor.collections.setText(named, row: record.id, column: title.id, in: block.id)
            pages.openRecord(record.id, in: block.id)
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(pages.current === inside && inside.title == named, "the page came back as \(inside.title)")
            pages.back()
            try? await Task.sleep(for: .milliseconds(300))
            // Each change was a step in the collection's document: undone, it's as it was.
            for _ in 0..<3 where self.demo.doc != before { try await self.undo() }
            try self.expect(self.demo.doc == before, "the undos left the collection changed")
        }
        await test("/page makes the line a page of its words and goes into it") {
            let pages = try self.expectValue(self.pages, "no pages")
            let paragraph = try self.block("Loading older")
            let anchor = try self.expectValue(self.demo.doc.blocks.firstIndex { $0.id == paragraph.id }, "no index")
            let id = self.demo.newBlockID()
            let start = DocSelection(anchor: .init(block: paragraph.id, offset: 0), head: .init(block: paragraph.id, offset: 0))
            self.demo.edit([.insertBlock(block: DocBlock(id: id, kind: .paragraph, text: DocText(string: "旅行/page")), after: self.demo.doc.blocks[anchor - 1].id)],
                           before: start, after: start)
            let line = try self.expectValue(self.demo.doc.block(id), "no line")
            self.editor.perform(.page, in: line, replacing: 2..<7, from: DocPosition(block: id, offset: 7))
            try? await Task.sleep(for: .milliseconds(300))
            guard case .page(let page)? = self.demo.doc.block(id)?.kind else { throw Failure(description: "not a page: \(String(describing: self.demo.doc.block(id)?.kind))") }
            try self.expect(page.title == "旅行" && pages.path.count == 2, "page \(page.title), \(pages.path.count) deep")
            try self.expect(pages.current.demo.doc.id == page.doc, "in another page")
            pages.back()
            try? await Task.sleep(for: .milliseconds(300))
            try await self.undo()
            try await self.undo()
            try self.expect(self.demo.doc.block(id) == nil, "the line stayed")
        }
        await test("a page block grouped into another page opens from there, the way to it through that page; a duplicated page block opens a copy of its page") {
            let pages = try self.expectValue(self.pages, "no pages")
            let blocks = self.editor.blocks
            let paragraph = try self.block("Loading older")
            let before = self.demo.doc.blocks.map(\.id)
            let index = try self.expectValue(before.firstIndex(of: paragraph.id), "no index")
            // A page of the paragraph, opened and left.
            blocks.select([paragraph.id])
            try self.expect(!blocks.canGroup, "Group offered for one block")
            // A block and one nested under it are two (Craft's).
            let parent = try self.block("每一块都能直接编辑"), child = try self.block("嵌套列表")
            blocks.select([parent.id, child.id])
            try self.expect(blocks.canGroup, "Group not offered for a block and one nested under it")
            blocks.select([paragraph.id])
            blocks.groupSelection()
            let inner = try self.expectValue(self.demo.doc.blocks.dropFirst(index).first, "no page block")
            guard case .page(let innerPage) = inner.kind else { throw Failure(description: "not a page: \(inner.kind)") }
            pages.open(inner.id)
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(pages.current.demo.doc.blocks.first?.text == paragraph.text && DocPage.summary(of: pages.current.demo.doc).title.isEmpty, "the page holds \(pages.current.demo.doc.blocks.count) blocks, titled \(pages.current.title)")
            pages.back()
            try? await Task.sleep(for: .milliseconds(300))
            // That page block and the next block grouped into another page.
            let next = try self.expectValue(self.demo.doc.blocks.dropFirst(index + 1).first { $0.indent <= inner.indent }, "no next")
            blocks.select([inner.id, next.id])
            try self.expect(blocks.canGroup, "Group not offered for two blocks")
            blocks.groupSelection()
            let outer = try self.expectValue(self.demo.doc.blocks.dropFirst(index).first, "no outer page block")
            guard case .page = outer.kind else { throw Failure(description: "not a page: \(outer.kind)") }
            pages.open(outer.id)
            try? await Task.sleep(for: .milliseconds(300))
            let outside = pages.current
            let moved = try self.expectValue(outside.demo.doc.blocks.first { if case .page(let page) = $0.kind { page.doc == innerPage.doc } else { false } }, "the page block didn't move in")
            pages.open(moved.id)
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(pages.current.id == innerPage.doc && pages.current.parent?.page === outside && pages.current.ancestors.count == 2,
                            "opened from \(pages.current.ancestors.count) pages up, the right one: \(pages.current.parent?.page === outside)")
            // Written in and left, the block where it is now takes its words.
            let line = try self.expectValue(pages.current.demo.doc.blocks.first, "no line")
            pages.current.demo.edit([.insertText(block: line.id, at: 0, text: DocText(string: "新 "))], before: nil, after: nil)
            pages.back()
            try? await Task.sleep(for: .milliseconds(300))
            guard case .page(let updated)? = outside.demo.doc.block(moved.id)?.kind else { throw Failure(description: "the moved block is gone") }
            try self.expect(updated.preview.hasPrefix("新 "), "the moved block's preview: \(updated.preview)")
            // Duplicated, it opens a page of its own with the same words.
            outside.editor.blocks.select([moved.id])
            outside.editor.blocks.duplicateSelection()
            let copy = try self.expectValue(outside.demo.doc.blocks.first { $0.id != moved.id && { if case .page = $0.kind { true } else { false } }($0) }, "no copy")
            guard case .page(let copied) = copy.kind else { throw Failure(description: "not a page") }
            let original = try self.expectValue(DocStore.shared.load(innerPage.doc), "the page isn't kept")
            let duplicate = try self.expectValue(DocStore.shared.load(copied.doc), "the copy isn't kept")
            try self.expect(copied.doc != innerPage.doc && duplicate.blocks.map(\.text) == original.blocks.map(\.text)
                            && Set(duplicate.blocks.map(\.id)).isDisjoint(with: original.blocks.map(\.id)), "the copy shares the page")
            pages.back()
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<4 where self.demo.doc.blocks.map(\.id) != before { try await self.undo() }
            try self.expect(self.demo.doc.blocks.map(\.id) == before, "the groups didn't undo")
        }
        await test("a document open in two windows is one: what either changes the other has at once, its cursor kept with its words; each undoes its own") {
            let other = DocDemo(doc: self.demo.doc)
            let otherEditor = DocEditor(demo: other)
            let line = try self.block("Loading older")
            otherEditor.place(DocSelection(anchor: DocPosition(block: line.id, offset: 3), head: DocPosition(block: line.id, offset: 3)), reveals: false)
            // Typed here before the other window's cursor: there too, the cursor after it.
            self.demo.edit([.insertText(block: line.id, at: 0, text: DocText(string: "ab "))], before: nil, after: nil)
            try self.expect(other.doc == self.demo.doc, "the other window's document differs")
            try self.expect(otherEditor.selection?.head == DocPosition(block: line.id, offset: 6), "the other cursor at \(String(describing: otherEditor.selection?.head))")
            // Written there: here too. Undone there, only what it wrote goes.
            let end = try self.expectValue(other.doc.block(line.id), "no line").text.length
            other.edit([.insertText(block: line.id, at: end, text: DocText(string: " z"))], before: nil, after: nil)
            try self.expect(self.demo.doc == other.doc && self.demo.doc.block(line.id)?.text.string.hasSuffix(" z") == true, "the other window's words aren't here")
            _ = other.undo()
            try self.expect(self.demo.doc == other.doc && self.demo.doc.block(line.id)?.text.string == "ab " + line.text.string, "the other window's undo: \(self.demo.doc.block(line.id)?.text.string ?? "")")
            try await self.undo()
            try self.expect(self.demo.doc == other.doc && self.demo.doc.block(line.id)?.text == line.text && !other.canUndo, "this window's undo")
        }
        await test("cards next to each other share a line; a point on each picks that one") {
            let line = try self.expectValue(self.linkCards(), "no line of cards")
            await show(line[0])
            let left = try self.expectValue(blocks.testContentFrame(line[0]), "no frame")
            let right = try self.expectValue(blocks.testContentFrame(line[1]), "no frame")
            try self.expect(left.minY == right.minY && right.minX > left.maxX, "cards at \(left) and \(right)")
            // A column of the page the list lays them out in, inside it.
            let page = blocks.testPageWidth, column = DocMediaLayout.cardWidth(in: page)
            try self.expect([left, right].allSatisfy { abs($0.width - column) < 1 }, "cards \(left.width), \(right.width) wide, a column is \(column)")
            try self.expect(abs(right.minX - left.maxX - DocMediaLayout.gap) < 1, "cards \(right.minX - left.maxX) apart")
            let list = try self.expectValue(blocks.testListWidth, "no list")
            try self.expect(right.maxX <= DocBlockController.pageLeft(inWidth: list) + page + 0.5, "the cards run past the page: \(right.maxX)")
            try self.expect(blocks.testBlock(at: CGPoint(x: left.midX, y: left.midY)) == line[0], "left point picks another block")
            try self.expect(blocks.testBlock(at: CGPoint(x: right.midX, y: right.midY)) == line[1], "right point picks another block")
        }
        await test("cards are a column of the page wide, Craft's: three across while each is 140 or more, then two, then one") {
            let card = try self.expectValue(self.demo.doc.blocks.first { if case .link(let link) = $0.kind { link.layout == .card } else { false } }, "no card")
            let kinds = Array(repeating: card.kind, count: 3)
            // The page's widths and the cards' as Craft draws them, measured as its window narrows.
            for (width, columns, cardWidth) in [(696.0, 3, 226.0), (441.0, 3, 141.0), (432.0, 2, 212.0), (240.0, 2, 116.0), (200.0, 1, 200.0)] {
                let frames = DocMediaLayout.runFrames(kinds, width: width)
                let first = frames.filter { $0.minY == frames[0].minY }
                try self.expect(first.count == columns && first.allSatisfy { abs($0.width - cardWidth) < 1 },
                                "at \(width): \(first.map(\.width)), wanted \(columns) of \(cardWidth)")
                try self.expect(frames.allSatisfy { abs($0.width - cardWidth) < 1 } && first.last.map { abs(width - $0.maxX) < 0.5 } == true,
                                "at \(width) the cards don't fill a line: \(frames)")
            }
        }
        await test("a file turned into a card after cards joins their run, its row the same") {
            let pdf = try self.expectValue(self.demo.doc.blocks.first { if case .file(let file) = $0.kind { file.name.hasSuffix(".pdf") } else { false } }, "no pdf")
            let index = try self.expectValue(self.demo.rows.firstIndex { $0.block == pdf.id }, "no pdf row")
            try self.expect(index > 0 && self.demo.rows[index - 1].run?.kind != nil, "the pdf doesn't follow cards")
            blocks.setLayout(.card, of: [pdf.id])
            try? await Task.sleep(for: .milliseconds(700))
            let row = try self.expectValue(self.demo.rows.first { $0.block == pdf.id }, "no pdf row")
            try self.expect(row.run.map { $0.kind == .cards && $0.index > 0 } == true, "the pdf didn't join the cards: \(String(describing: row.run))")
            try self.expect(blocks.testRowFrame(pdf.id).map { $0.width < blocks.testPageWidth / 2 + 1 } == true, "the pdf's row isn't a card's")
            try await self.undo()
        }
        await test("a card dragged out of a line of cards stands on its own where it's dropped") {
            let line = try self.expectValue(self.linkCards(), "no line of cards")
            let (first, second) = (line[0], line[1])
            let ids = order()
            let at = try self.expectValue(ids.firstIndex(of: second), "no card")
            let below = ids[at + 1]
            await show(first)
            let target = try self.expectValue(blocks.testRowFrame(below), "no row below")
            blocks.testDrag(second, toY: target.maxY - 2)
            let after = order()
            try self.expect(after.firstIndex(of: second) == at + 1 && after[at] == below, "order \(String(describing: after.firstIndex(of: second))), wanted \(at + 1)")
            try? await Task.sleep(for: .milliseconds(300))
            try self.expect(self.line(of: first) == [first], "the card left behind isn't on its own: \(self.line(of: first))")
            try self.expect(self.line(of: second) == [second], "the dragged card isn't on its own: \(self.line(of: second))")
            try await self.undo()
            try self.expect(order() == ids, "undo didn't restore the order")
        }
        await test("a card dropped on the near half of another on its line goes beside it, on the line; the other slides over, the dropped one shows once it lands") {
            let line = try self.expectValue(self.linkCards(), "no line of cards")
            let (first, second) = (line[0], line[1])
            let ids = order()
            await show(first)
            let target = try self.expectValue(blocks.testContentFrame(first), "no card")
            let was = try self.expectValue(blocks.testShownBox(first)?.frame, "no card drawn")
            blocks.testDrag(second, toY: target.midY, x: target.minX + 20)
            try self.expect(blocks.testLanding == [second], "hidden while landing \(blocks.testLanding)")
            let after = order()
            let at = try self.expectValue(ids.firstIndex(of: first), "no card")
            try self.expect(after[at] == second && after[at + 1] == first, "order \(String(describing: after.firstIndex(of: second)))")
            // What flies down lands on the moved card's place; the other card goes from
            // where it was to its new place, on its way in between, never fading.
            let landing = try self.expectValue(blocks.testLandings[second], "nothing lands")
            let moved = try self.expectValue(blocks.testContentFrame(second), "no card")
            try self.expect(abs(landing.midY - moved.midY) < 1 && abs(landing.minX - (moved.minX - 6)) < 1, "lands at \(landing), the card is at \(moved)")
            let place = try self.expectValue(blocks.testContentFrame(first), "no card")
            var xs: [CGFloat] = []
            let began = CACurrentMediaTime()
            while CACurrentMediaTime() - began < 0.5 {
                try? await Task.sleep(for: .milliseconds(8))
                let shown = try self.expectValue(blocks.testShownBox(first), "no card drawn")
                try self.expect(shown.opacity > 0.99 && abs(shown.frame.minY - place.minY) < 1, "the other card shows at \(shown.frame) a\(shown.opacity)")
                xs.append(shown.frame.minX)
            }
            let partway = xs.filter { $0 > min(was.minX, place.minX) + 3 && $0 < max(was.minX, place.minX) - 3 }
            try self.expect(partway.count >= 3 && abs((xs.last ?? 0) - place.minX) < 1, "the other card went \(xs.map { Int($0) }) from \(was.minX) to \(place.minX)")
            try self.expect(zip(xs, xs.dropFirst()).allSatisfy { ($1 - $0) * (place.minX - was.minX) >= -1 }, "the other card went back: \(xs.map { Int($0) })")
            try self.expect(blocks.testLanding.isEmpty, "still hidden after landing \(blocks.testLanding)")
            try? await Task.sleep(for: .milliseconds(600))
            try self.expect(blocks.testDimmed.isEmpty, "still dimmed \(blocks.testDimmed)")
            try self.expect(self.line(of: second).prefix(2) == [second, first], "line \(self.line(of: second))")
            try await self.undo()
            try self.expect(order() == ids, "undo didn't restore the order")
        }
        await test("a card's picture stays in its place: none of it under the preview") {
            let block = try self.expectValue(self.demo.doc.blocks.first {
                if case .link(let link) = $0.kind { link.layout == .card && link.image != nil } else { false }
            }, "no card with a picture")
            let renderer = ImageRenderer(content: DocMediaView(kind: block.kind).frame(width: DocMediaLayout.cardWidth(in: blocks.testPageWidth), alignment: .topLeading))
            renderer.scale = 1
            let image = try self.expectValue(renderer.cgImage, "not drawn")
            let data = try self.expectValue(image.dataProvider?.data.flatMap(CFDataGetBytePtr), "no pixels: \(image.width)x\(image.height) bpp \(image.bitsPerPixel) provider \(image.dataProvider != nil) data \(image.dataProvider?.data.map(CFDataGetLength) ?? -1)")
            let (perRow, step) = (image.bytesPerRow, image.bitsPerPixel / 8)
            // The text between the preview (104 tall) and the footer: white and greys only.
            var coloured = 0, all = 0
            for y in 108..<190 where y < image.height {
                for x in 0..<min(image.width, Int(DocMediaLayout.cardWidth(in: blocks.testPageWidth))) {
                    let p = y * perRow + x * step
                    let (a, b, c) = (Int(data[p]), Int(data[p + 1]), Int(data[p + 2]))
                    all += 1
                    if max(a, b, c) - min(a, b, c) > 40 { coloured += 1 }
                }
            }
            try self.expect(all > 0 && coloured * 100 < all, "\(coloured) of \(all) pixels under the preview are coloured")
        }
        await test("a card turned regular leaves its line and a card again goes back: its box goes from place to place, the rows after it follow, nothing fades") {
            let line = try self.expectValue(self.linkCards(), "no line of cards")
            let card = line[1]
            let rows = self.demo.rows
            let index = try self.expectValue(rows.firstIndex { $0.block == card }, "no row")
            let next = try self.expectValue(rows[(index + 1)...].first { !self.sharesLine($0) }?.block, "nothing after the line")
            blocks.testCenter(card)
            try await self.expectMove(card, next: next, still: line[0]) { blocks.setLayout(.regular, of: [card]) }
            try self.expect(self.line(of: card) == [card], "the card didn't leave its line: \(self.line(of: card))")
            try await self.expectMove(card, next: next, still: line[0]) { blocks.setLayout(.card, of: [card]) }
            try self.expect(self.line(of: card) == line, "the card didn't go back: \(self.line(of: card))")
            try await self.undo()
            try await self.undo()
        }
        await test("an image made large leaves its gallery and made auto goes back: its box goes from place to place, the rows after it follow, nothing fades") {
            let rows = self.demo.rows
            let index = try self.expectValue(rows.indices.first { index in
                guard index > 0, case .image? = rows[index].media else { return false }
                return self.sharesLine(rows[index])
            }, "no gallery")
            let (image, before) = try (self.expectValue(rows[index].block, "no image"), self.expectValue(rows[index - 1].block, "no image"))
            let line = self.line(of: image)
            let next = try self.expectValue(rows[(index + 1)...].first { !self.sharesLine($0) }?.block, "nothing after the gallery")
            // Large, it's as tall as the page is wide: the row after it stays on screen.
            blocks.testShowAtTop(before)
            try await self.expectMove(image, next: next, still: before) { blocks.setImage(size: .large, of: [image]) }
            try self.expect(self.line(of: image) == [image], "the image didn't leave its gallery: \(self.line(of: image))")
            try await self.expectMove(image, next: next, still: before) { blocks.setImage(size: .auto, of: [image]) }
            try self.expect(self.line(of: image) == line, "the image didn't go back: \(self.line(of: image))")
            try await self.undo()
            try await self.undo()
        }
        await test("a file turned into a card after cards joins them, and back: its box goes from place to place, the rows after it follow, nothing fades") {
            let pdf = try self.expectValue(self.demo.doc.blocks.first { if case .file(let file) = $0.kind { file.name.hasSuffix(".pdf") } else { false } }, "no pdf")
            let rows = self.demo.rows
            let index = try self.expectValue(rows.firstIndex { $0.block == pdf.id }, "no pdf row")
            let card = try self.expectValue(index > 0 ? rows[index - 1].block : nil, "nothing before the pdf")
            let next = try self.expectValue(index + 1 < rows.count ? rows[index + 1].block : nil, "nothing after the pdf")
            blocks.testCenter(pdf.id)
            try await self.expectMove(pdf.id, next: next, still: card) { blocks.setLayout(.card, of: [pdf.id]) }
            try await self.expectMove(pdf.id, next: next, still: card) { blocks.setLayout(.regular, of: [pdf.id]) }
            try await self.undo()
            try await self.undo()
        }
        await test("the format panel's edits act on all the selected blocks, one undo each") {
            let first = try self.block("Loading older")
            let second = try self.block("The trap is timing")
            let before = self.demo.doc.blocks
            blocks.select([first.id, second.id])
            self.editor.setKind(.heading(level: 2), of: blocks.selected)
            try self.expect([first.id, second.id].allSatisfy { self.demo.doc.block($0)?.kind == .heading(level: 2) }, "not both headings")
            try await self.undo()
            try self.expect(self.demo.doc.blocks == before, "undo left the kinds changed")
            self.editor.toggle(.bold, over: [(first.id, 0..<first.text.length), (second.id, 0..<second.text.length)])
            try self.expect([first, second].allSatisfy { DocEditor.covers(self.demo.doc.block($0.id)!.text, 0..<$0.text.length, with: .bold) }, "not both bold")
            self.editor.toggle(.bold, over: [(first.id, 0..<first.text.length), (second.id, 0..<second.text.length)])
            try self.expect([first, second].allSatisfy { !(self.demo.doc.block($0.id)!.text.marks.contains { $0.mark == .bold }) }, "bold not cleared")
            let items = self.demo.doc.blocks.filter { if case .listItem(.numbered) = $0.kind { $0.indent == 0 } else { false } }.prefix(3).map(\.id)
            self.editor.indent(Array(items.dropFirst()), by: 1)
            try self.expect(items.dropFirst().allSatisfy { self.demo.doc.block($0)?.indent == 1 }, "items didn't nest")
            try await self.undo()
            try self.expect(items.allSatisfy { self.demo.doc.block($0)?.indent == 0 }, "one undo didn't take both back")
            blocks.clear()
        }
        await test(DocBlockController.usesHandles ? "a click on a link selects it and a double click opens it" : "a tap on a link opens it") {
            let link = try self.expectValue(self.demo.doc.blocks.first { if case .link = $0.kind { true } else { false } }, "no link")
            guard case .link(let shown) = link.kind else { return }
            await show(link.id)
            var opened: [URL] = []
            let appOpens = blocks.openURL
            blocks.openURL = OpenURLAction { opened.append($0); return .handled }
            defer { blocks.openURL = appOpens }
            blocks.testClick(link.id)
            if DocBlockController.usesHandles {
                try self.expect(blocks.selected == [link.id], "selected \(blocks.selected.count)")
                try self.expect(opened.isEmpty, "a single click opened it")
                blocks.open(link.id)
            } else {
                try self.expect(blocks.selected.isEmpty && !blocks.isSelecting, "the tap selected it")
            }
            try self.expect(opened == [URL(string: shown.url)!], "opened \(opened)")
            blocks.clear()
            if blocks.isSelecting { blocks.endSelecting() }
        }
        await test("opening an image hands the app its picture as a file") {
            let image = try self.expectValue(self.demo.doc.blocks.first {
                if case .image(let image) = $0.kind { DocMediaLayout.asset(image.source) != nil } else { false }
            }, "no image")
            var opened: [URL] = []
            let appOpens = blocks.openURL
            blocks.openURL = OpenURLAction { opened.append($0); return .handled }
            defer { blocks.openURL = appOpens }
            blocks.open(image.id)
            let file = try self.expectValue(opened.first, "nothing opened")
            try self.expect(opened.count == 1 && file.isFileURL, "opened \(opened)")
            try self.expect((try? Data(contentsOf: file)).flatMap(UIImage.init(data:)) != nil, "no picture at \(file)")
        }
        await test("a list item is selected alone; dragged, its nested items go with it (a phone lifts the item alone)") {
            let nested = try self.block("嵌套列表的缩进")
            let group = blocks.groups([nested.id])[0]
            try self.expect(group.count == 3, "group of \(group.count)")
            await show(nested.id)
            if DocBlockController.usesHandles { blocks.click(nested.id) } else { blocks.beginSelecting(nested.id) }
            try self.expect(blocks.selected == [nested.id], "selected \(blocks.selected.count)")
            try self.expect(blocks.testHighlightFrames.count == (DocBlockController.usesHandles ? 1 : 0), "highlights \(blocks.testHighlightFrames.count)")
            if let highlight = blocks.testHighlightFrames.first, let row = blocks.testContentFrame(nested.id), let child = blocks.testContentFrame(group[1]) {
                try self.expect(highlight.maxY < child.midY && highlight.minY < row.midY, "the highlight \(highlight) covers the nested item \(child)")
            }
            // A phone's long press lifts the item alone; its nested items show once it moves.
            let pickUp = blocks.testPickUp(nested.id)
            try self.expect(pickUp.lifted == (DocBlockController.usesHandles ? group : [nested.id]) && pickUp.moving == group,
                            "lifted \(pickUp.lifted.count), moving \(pickUp.moving.count) of \(group.count)")
            let preview = try self.expectValue(blocks.testLiftPreview(nested.id), "no lift preview")
            let clear = preview.parameters.backgroundColor.cgColor.alpha == 0
            try self.expect(clear == DocBlockController.usesHandles, DocBlockController.usesHandles ? "the Mac's preview has a background" : "the phone's preview has no background")
            let before = order()
            let index = try self.expectValue(before.firstIndex(of: nested.id), "no index")
            let target = try self.expectValue(blocks.testRowFrame(before[index + 3]), "no row after the group")
            blocks.testDrag(nested.id, toY: target.maxY - 2)
            let after = order()
            let at = try self.expectValue(after.firstIndex(of: nested.id), "not moved")
            try self.expect(Array(after[at...(at + 2)]) == group && at == index + 1, "the group isn't after the next block: at \(at)")
            try self.expect(blocks.testLanding.isSuperset(of: group), "not hidden while landing \(blocks.testLanding)")
            for id in group {
                guard let landing = blocks.testLandings[id], let row = blocks.testContentFrame(id) else { continue }
                try self.expect(abs(landing.midY - row.midY) < 1 && abs(landing.minX - (row.minX - 6)) < 1, "\(id) lands at \(landing), its row is at \(row)")
            }
            try self.expect(!blocks.testLandings.isEmpty, "nothing to land on")
            try? await Task.sleep(for: .milliseconds(500))
            try self.expect(blocks.testDimmed.isEmpty, "still dimmed \(blocks.testDimmed)")
            try self.expect(blocks.selected == [nested.id], "selected \(blocks.selected.count) after the drop")
            try await self.undo()
            try self.expect(order() == before, "undo didn't restore the order")
            if blocks.isSelecting { blocks.endSelecting() } else { blocks.clear() }
        }
        if DocBlockController.usesHandles {
            await test("on the Mac the page's text reads at Craft's size: body 1.16 times, headings 1.24 times the text styles") {
                @MainActor func renderedFont(_ prefix: String) throws -> UIFont {
                    let block = try self.block(prefix)
                    let view = try self.expectValue(self.editor.textView(for: block.id), "no text view for \(prefix)")
                    let text = try self.expectValue(view.attributedText, "no text")
                    let start = try self.expectValue(self.editor.textStart(in: view, block: block), "not in sync")
                    return try self.expectValue(text.attribute(.font, at: start, effectiveRange: nil) as? UIFont, "no font")
                }
                let paragraph = try self.block("Loading older")
                await show(paragraph.id)
                let body = try renderedFont("Loading older").pointSize
                let expected = UIFont.preferredFont(forTextStyle: .body).pointSize * 1.16
                try self.expect(abs(body - expected) < 0.01, "body \(body), wanted \(expected)")
                let heading = try self.block("第 1 节")
                await show(heading.id)
                let size = try renderedFont("第 1 节").pointSize
                let wanted = UIFont.preferredFont(forTextStyle: .title2).pointSize * 1.24
                try self.expect(abs(size - wanted) < 0.01, "heading \(size), wanted \(wanted)")
            }
            await test("on the Mac MarkdownView's own text is Craft's size too: its font group's and the selectable path's") {
                struct Unscaled: MarkdownFontGroup {
                    var body: Font { .body }
                    var h2: Font { .title2 }
                }
                @MainActor func height(_ view: some View) -> CGFloat {
                    UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude)).height
                }
                // One line taller by what the scale adds to its line (a heading's padding stays).
                for (text, style) in [("One line of body text", UIFont.TextStyle.body), ("## One heading", .title2)] {
                    let (scaled, plain) = (height(MarkdownView(text)), height(MarkdownView(text).fontGroup(Unscaled())))
                    let font = UIFont.preferredFont(forTextStyle: style)
                    let grows = font.withSize(MarkdownTextScale.size(of: style)).lineHeight - font.lineHeight
                    try self.expect(abs((scaled - plain) - grows) < 1.5, "\(text): \(scaled) high, \(plain) at the text style, wanted \(grows) more")
                }
                let standard = MarkdownPlatformTypography.standard
                try self.expect(standard.body.scale == 1.16 && standard.headings[0].scale == 1.24 && standard.headings[3].scale == 1.16,
                                "the selectable path's scales: \(standard.body.scale), \(standard.headings.map(\.scale))")
            }
            await test("blocks selected next to each other are highlighted each on its own, a little around their text") {
                let nested = try self.block("嵌套列表的缩进")
                let group = blocks.groups([nested.id])[0]
                await show(nested.id)
                blocks.click(group[0])
                blocks.click(group[1], modifiers: .shift)
                let frames = blocks.testHighlightFrames.sorted { $0.minY < $1.minY }
                try self.expect(frames.count == 2, "highlights \(frames.count)")
                if frames.count == 2 { try self.expect(frames[0].maxY < frames[1].minY, "the highlights touch: \(frames)") }
                if let first = frames.first, let content = blocks.testContentFrame(group[0]) {
                    let outset = DocBlockController.highlightOutset
                    try self.expect(abs(first.minY - (content.minY - outset)) < 0.5 && abs(first.maxY - (content.maxY + outset)) < 0.5,
                                    "the highlight \(first) isn't \(outset) points around the text \(content)")
                }
                blocks.clear()
            }
        } else {
            await test("on a phone the selection's dots lie over the page: its margins are the same on both sides") {
                let width: CGFloat = 400
                let left = DocBlockController.pageLeft(inWidth: width)
                try self.expect(left == DocBlockController.trailingGutter, "page from \(left), right margin \(DocBlockController.trailingGutter)")
            }
            await test("on a phone while selecting a tap on a block's text never edits it: the rows take no taps") {
                let block = try self.block("Loading older")
                await show(block.id)
                let view = try self.expectValue(self.editor.textView(for: block.id), "no text view")
                await self.rest(view)
                let point = view.convert(CGPoint(x: 30, y: view.caretRect(for: view.beginningOfDocument).midY), to: nil)
                func hitsText() -> Bool {
                    sequence(first: view.window?.hitTest(point, with: nil), next: { $0?.superview }).contains { $0 === view }
                }
                try self.expect(hitsText(), "the text takes no taps outside selecting")
                blocks.beginSelecting(block.id)
                try? await Task.sleep(for: .milliseconds(150))
                try self.expect(!hitsText(), "the text takes taps while selecting")
                try self.expect(!view.isEditable || !view.isFirstResponder, "the text is edited while selecting")
                blocks.endSelecting()
                try? await Task.sleep(for: .milliseconds(150))
                try self.expect(hitsText(), "the text takes no taps after selecting")
            }
        }
        await test("deleting a selected list item takes its nested items; undo brings them back") {
            let nested = try self.block("嵌套列表的缩进")
            let group = blocks.groups([nested.id])[0]
            await show(nested.id)
            let before = order()
            blocks.select([nested.id])
            blocks.deleteSelection()
            try self.expect(group.allSatisfy { self.demo.doc.block($0) == nil }, "the nested items stayed")
            try await self.undo()
            try self.expect(order() == before, "undo didn't restore them")
        }
        if !DocBlockController.usesHandles {
            await test("on a phone a block lifted and let go where it was starts selecting with it as the touch ends") {
                let block = try self.block("Loading older")
                await show(block.id)
                // A press the system began a drag for, then took for a scroll: its end selects nothing.
                let scroll = blocks.testPressBecomingScroll(block.id)
                try self.expect(!scroll.selecting && !scroll.dragLeft, "a scroll's end: selecting \(scroll.selecting), drag left \(scroll.dragLeft)")
                let atOnce = blocks.testLiftAndLetGo(block.id)
                try self.expect(atOnce, "selecting waited for the lift to settle back")
                try self.expect(blocks.isSelecting && blocks.selected == [block.id], "selecting \(blocks.isSelecting), \(blocks.selected.count)")
                blocks.endSelecting()
            }
            await test("on a phone a selected block gone from the document ends selecting, and its bar") {
                let block = try self.block("Loading older")
                await show(block.id)
                blocks.beginSelecting(block.id)
                try self.expect(blocks.isSelecting, "not selecting")
                // Not the bar's Delete (that ends selecting itself): an edit from elsewhere.
                let current = try self.expectValue(self.demo.doc.block(block.id), "no block")
                self.demo.edit([.deleteBlock(block: current, after: nil)], before: nil, after: nil)
                try? await Task.sleep(for: .milliseconds(300))
                try self.expect(!blocks.isSelecting, "still selecting a block that's gone")
                try await self.undo()
            }
            await test("on a phone a swipe across a block selects it, another takes it out; a short one does nothing") {
                let block = try self.block("Loading older")
                let heading = try self.block("第 2 节")
                await show(block.id)
                blocks.testSwipe(block.id, x: 40)
                try self.expect(!blocks.isSelecting, "a short swipe selected")
                blocks.testSwipe(block.id, x: -100)
                try self.expect(blocks.isSelecting && blocks.selected == [block.id], "selecting \(blocks.isSelecting), \(blocks.selected.count)")
                blocks.testSwipe(heading.id, x: 100)
                try self.expect(blocks.selected == [block.id, heading.id], "selected \(blocks.selected.count)")
                blocks.testSwipe(block.id, x: 100)
                blocks.testSwipe(heading.id, x: -100)
                try self.expect(!blocks.isSelecting, "still selecting with nothing selected")
            }
        }
        await test("several selected blocks move together, in order") {
            let first = try self.block("Loading older")
            let heading = try self.block("第 2 节")
            await show(first.id)
            blocks.click(first.id)
            blocks.click(heading.id, modifiers: .command)
            try self.expect(blocks.selected == [first.id, heading.id], "selected \(blocks.selected.count)")
            let top = try self.expectValue(self.demo.doc.blocks.first, "empty doc")
            try self.expect(blocks.move([first.id, heading.id], after: top.id), "move failed")
            try self.expect(Array(order()[1...2]) == [first.id, heading.id], "not moved together")
            blocks.clear()
        }
    }


    private var blockCountAtStart = 0

    /// -docTestFilter <text>: only the tests whose names contain it (or any of its
    /// `|`-separated parts).
    private let filter = UserDefaults.standard.string(forKey: "docTestFilter")

    private func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
        if let filter, !filter.split(separator: "|").contains(where: { name.contains($0) }) { return }
        editor.resetDocument()
        blockCountAtStart = demo.doc.blocks.count
        try? await Task.sleep(for: .milliseconds(300))
        let started = CACurrentMediaTime()
        func took() -> String { String(format: "%.1fs", CACurrentMediaTime() - started) }
        do {
            try await body()
            passed += 1
            docTestLog("DOCTEST PASS (\(took())) \(name)")
        } catch {
            failed += 1
            docTestLog("DOCTEST FAIL (\(took())) \(name): \(error)")
        }
    }

    // MARK: Reshaping

    /// A link, file or image alone on its line, with a line starting right after it.
    private func mediaAlone(_ matches: (BlockKind) -> Bool) -> (block: DocBlock, next: DocBlockID)? {
        let rows = demo.rows
        for (index, row) in rows.enumerated() where !sharesLine(row) && index + 1 < rows.count {
            guard let id = row.block, let block = demo.doc.block(id), matches(block.kind),
                  !sharesLine(rows[index + 1]), let next = rows[index + 1].block else { continue }
            return (block, next)
        }
        return nil
    }

    /// The blocks on the line a block's row is on, in order.
    private func line(of id: DocBlockID) -> [DocBlockID] {
        let rows = demo.rows
        guard var start = rows.firstIndex(where: { $0.block == id }) else { return [] }
        while start > 0, sharesLine(rows[start]) { start -= 1 }
        var end = start + 1
        while end < rows.count, sharesLine(rows[end]) { end += 1 }
        return rows[start..<end].compactMap(\.block)
    }

    /// The first line of two or more link cards.
    /// Whether a row is on the line of the row before it, at the list's width now.
    private func sharesLine(_ row: DocRow) -> Bool {
        row.run.map { DocMediaLayout.place($0, inPage: editor.blocks.testPageWidth).sharesLine } ?? false
    }

    private func linkCards() -> [DocBlockID]? {
        let rows = demo.rows
        for (index, row) in rows.enumerated() where index + 1 < rows.count && sharesLine(rows[index + 1]) {
            guard case .link? = row.media, !sharesLine(row), let id = row.block else { continue }
            return line(of: id)
        }
        return nil
    }

    /// Makes `change` to the block and watches the screen while it lands: its box (a
    /// card's, an image's frame) goes from its old bottom to its new one, the row after it
    /// from its old place to its new one, the two together, the row before stays put, and
    /// all of it comes to rest where the layout says.
    private func expectReshape(_ id: DocBlockID, next: DocBlockID, change: () -> Void) async throws {
        let blocks = editor.blocks
        blocks.testCenter(id)
        try? await Task.sleep(for: .milliseconds(300))
        let before = demo.rows.firstIndex { $0.block == id }.flatMap { $0 > 0 ? demo.rows[$0 - 1].block : nil }
        let beforeTop = before.flatMap { blocks.testShownRowFrame($0)?.minY }
        func sample() throws -> (bottom: CGFloat, next: CGFloat, before: CGFloat?) {
            (try expectValue(blocks.testShownBoxBottom(id), "no box drawn"),
             try expectValue(blocks.testShownRowFrame(next)?.minY, "next row not on screen"),
             before.flatMap { blocks.testShownRowFrame($0)?.minY })
        }
        let start = try sample()
        let began = CACurrentMediaTime()
        change()
        var samples: [(time: Double, bottom: CGFloat, next: CGFloat, before: CGFloat?)] = []
        while CACurrentMediaTime() - began < 0.7 {
            try? await Task.sleep(for: .milliseconds(8))
            let shown = try sample()
            samples.append((CACurrentMediaTime() - began, shown.bottom, shown.next, shown.before))
        }
        let end = try expectValue(samples.last, "no samples")
        let trace = samples.map { String(format: "%.3f:%.1f/%.1f", $0.time, $0.bottom - start.bottom, $0.next - start.next) }.joined(separator: " ")
        docTestLog("DOCTEST TRACE reshape \(start.bottom)/\(start.next) → \(trace)")
        func between(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool { value > min(a, b) + 3 && value < max(a, b) - 3 }
        // On its way: some frames show both partway, not one jump.
        let partway = samples.filter { between($0.bottom, start.bottom, end.bottom) && between($0.next, start.next, end.next) }
        try expect(partway.count >= 3, "only \(partway.count) frames partway: \(trace)")
        // Together: the gap between what it draws and the next row stays the gap it ends with.
        let gap = end.next - end.bottom
        let apart = samples.filter { abs(($0.next - $0.bottom) - gap) > 3 }
        try expect(apart.isEmpty, "\(apart.count) frames out of step: \(trace)")
        // Toward the end, never back, and slowing down into its place (no sudden stop).
        let steps = zip(samples, samples.dropFirst()).map { $1.next - $0.next }
        let direction: CGFloat = end.next >= start.next ? 1 : -1
        try expect(steps.allSatisfy { $0 * direction >= -1 }, "the next row went back: \(trace)")
        let lastMove = samples.lastIndex { abs($0.next - end.next) > 0.5 } ?? 0
        if lastMove > 0 { try expect(abs(steps[lastMove - 1]) < 3, "stopped from \(steps[lastMove - 1]) a frame: \(trace)") }
        // At rest where the layout says; the row before never moved.
        let next = try expectValue(blocks.testRowFrame(next), "no next row")
        try expect(abs(end.next - next.minY) < 0.5, "next row rests at \(end.next), its place is \(next.minY)")
        if let beforeTop { try expect(samples.allSatisfy { $0.before.map { abs($0 - beforeTop) < 0.5 } ?? true }, "the row before moved") }
    }

    /// Makes `change` to a block of text and watches the screen while it lands: its text
    /// goes in or out from the edge (a quote's inset, a box's) while the row after it goes
    /// to its new place, the two on their way in the same frames, not one and then the other.
    private func expectInStep(_ id: DocBlockID, view: UITextView, next: DocBlockID, _ name: String, change: () -> Void) async throws {
        let blocks = editor.blocks
        try? await Task.sleep(for: .milliseconds(300))
        func sample() throws -> (edge: CGFloat, next: CGFloat) {
            (try expectValue(blocks.testShownFrame(of: view, in: id)?.minX, "\(name): no text drawn"),
             try expectValue(blocks.testShownRowFrame(next)?.minY, "\(name): next row not on screen"))
        }
        let start = try sample()
        let began = CACurrentMediaTime()
        change()
        var samples: [(time: Double, edge: CGFloat, next: CGFloat)] = []
        while CACurrentMediaTime() - began < 0.7 {
            try? await Task.sleep(for: .milliseconds(8))
            let shown = try sample()
            samples.append((CACurrentMediaTime() - began, shown.edge, shown.next))
        }
        let end = try expectValue(samples.last, "no samples")
        let trace = samples.map { String(format: "%.3f:%.1f/%.1f", $0.time, $0.edge - start.edge, $0.next - start.next) }.joined(separator: " ")
        docTestLog("DOCTEST TRACE in step \(name) \(start.edge)/\(start.next) → \(trace)")
        func between(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool { value > min(a, b) + 2 && value < max(a, b) - 2 }
        try expect(abs(end.edge - start.edge) > 6 && abs(end.next - start.next) > 6, "\(name): nothing moved: \(trace)")
        let together = samples.filter { between($0.edge, start.edge, end.edge) && between($0.next, start.next, end.next) }
        try expect(together.count >= 3, "\(name): only \(together.count) frames with both on their way: \(trace)")
    }

    /// Makes `change` to a block that gives its box another place or size on the page and
    /// watches the screen while it lands: its box goes from its old frame to its new one
    /// (frames on the way, not a jump) without fading, the row after it goes on its way without going back,
    /// `still`'s row stays put, and all of it comes to rest where the layout says. (The row
    /// after it is watched while it's on screen: a large image can push it off.)
    private func expectMove(_ id: DocBlockID, next: DocBlockID, still: DocBlockID, change: () -> Void) async throws {
        let blocks = editor.blocks
        try? await Task.sleep(for: .milliseconds(300))
        // A doc just loaded is revealed after a moment (the list fading its new rows in).
        for _ in 0..<50 where (blocks.testShownBox(id)?.opacity ?? 0) < 0.99 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let stays = try expectValue(blocks.testShownRowFrame(still), "no row that stays")
        let startOffset = blocks.testContentOffset.y
        func sample() throws -> (box: CGRect, opacity: Float, next: CGFloat?, still: CGRect?) {
            let box = try expectValue(blocks.testShownBox(id), "no box drawn")
            return (box.frame, box.opacity, blocks.testShownRowFrame(next)?.minY, blocks.testShownRowFrame(still))
        }
        let start = try sample()
        let began = CACurrentMediaTime()
        change()
        var samples: [(time: Double, box: CGRect, opacity: Float, next: CGFloat?, still: CGRect?, offset: CGFloat)] = []
        // A long way, a spring's tail takes a while to come within half a point; rows
        // coming on screen meanwhile (text with math) are measured on the main thread and
        // hold the frames up. So past 0.7 s it's watched until the row after it is there.
        let goal = blocks.testRowFrame(next)?.minY
        func there() -> Bool {
            guard let goal, let shown = samples.last?.next else { return true }
            return abs(shown - goal) < 0.5
        }
        while CACurrentMediaTime() - began < 0.7 || (!there() && CACurrentMediaTime() - began < 1.5) {
            try? await Task.sleep(for: .milliseconds(8))
            let shown = try sample()
            samples.append((CACurrentMediaTime() - began, shown.box, shown.opacity, shown.next, shown.still, blocks.testContentOffset.y))
        }
        let end = try expectValue(samples.last, "no samples")
        let trace = samples.map {
            String(format: "%.3f:(%.0f,%.0f %.0fx%.0f a%.2f)/%.1f", $0.time, $0.box.minX - start.box.minX, $0.box.minY - start.box.minY,
                   $0.box.width, $0.box.height, $0.opacity, ($0.next ?? .nan) - (start.next ?? .nan))
        }.joined(separator: " ")
        docTestLog("DOCTEST TRACE move \(start.box) → \(trace)")
        let edges: [(CGRect) -> CGFloat] = [\.minX, \.minY, \.width, \.height]
        let changing = edges.filter { abs($0(end.box) - $0(start.box)) >= 8 }
        try expect(!changing.isEmpty, "the box didn't change: \(trace)")
        let faded = samples.filter { $0.opacity < 0.99 }
        try expect(faded.isEmpty, "\(faded.count) frames faded: \(trace)")
        // On its way: some frames show it partway in all that changes, not one jump.
        func between(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool { value > min(a, b) + 3 && value < max(a, b) - 3 }
        let partway = samples.filter { sample in changing.allSatisfy { between($0(sample.box), $0(start.box), $0(end.box)) } }
        try expect(partway.count >= 3, "only \(partway.count) frames partway: \(trace)")
        // The row after it: toward its place, never back, at rest there.
        let place = try expectValue(blocks.testRowFrame(next), "no next row")
        // On screen: rows measured above it meanwhile move the content, not what shows.
        let shown = samples.compactMap { sample in sample.next.map { $0 - sample.offset } }
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        let target = place.minY - end.offset
        let direction: CGFloat = target >= (start.next.map { $0 - startOffset } ?? shown.first ?? target) ? 1 : -1
        try expect(steps.allSatisfy { $0 * direction >= -1 }, "the next row went back: \(trace)")
        if let rest = end.next { try expect(abs(rest - place.minY) < 0.5, "next row rests at \(rest), its place is \(place.minY)") }
        // At rest where the layout puts its box; the row that stays never moved.
        let content = try expectValue(blocks.testContentFrame(id), "no frame")
        try expect(abs(end.box.minX - content.minX) < 1 && abs(end.box.minY - content.minY) < 1, "box rests at \(end.box), its place is \(content)")
        try expect(samples.allSatisfy { sample in
            sample.still.map { abs($0.minY - sample.offset - (stays.minY - startOffset)) < 0.5 && abs($0.minX - stays.minX) < 0.5 } ?? true
        }, "the row that stays moved on screen")
    }

    /// A formula written apart (DocTableFormula), for the cell at `key` (row 4, column 2 of
    /// the sample table, under 21%, 16%, 17%): taps on cells put their references in (a
    /// tap after one moves it; on the Mac through the table's own taps, the panel staying
    /// open), its own cell isn't one, an operator key; Done writes it into the cell, one
    /// undo step. On the Mac, a direction after a function's "(" names the cells it
    /// computes with, and Esc leaves the cell as it was.
    private func writeFormulaApart(at key: DocCellKey, table: DocTableSnapshot) async throws {
        let tables = editor.tables
        let before = text(of: key)
        func opened(_ step: String) async throws -> DocFormulaEditing {
            var formula: DocFormulaEditing?
            for _ in 0..<60 where formula?.field?.isFirstResponder != true {
                try? await Task.sleep(for: .milliseconds(50))
                formula = tables.formula
            }
            let editing = try expectValue(formula, "no formula")
            try expect(editing.field?.isFirstResponder == true,
                       "\(step): the field hasn't the keyboard (\(String(describing: DocFirstResponder.current.map { Swift.type(of: $0) })), field in a window: \(editing.field?.window != nil), first responder's formula is this: \((DocFirstResponder.current as? DocFormulaTextField)?.formula === editing), in a window: \((DocFirstResponder.current as? UIView)?.window != nil))")
            return editing
        }
        let editing = try await opened("opening")
        try expect(editing.text.isEmpty && editing.cell == MarkdownTableCellPosition(row: 4, column: 2), "formula \(editing.text) at \(editing.cell)")
        func tap(_ row: Int, _ column: Int) {
            let position = MarkdownTableCellPosition(row: row, column: column)
            if DocDevice.isMac { tables.tapped(table, at: position) } else { editing.point(at: position) }
        }
        tap(1, 2)
        tap(2, 2)
        try expect(editing.text == "C3", "a tap after a reference moves it: \(editing.text)")
        editing.insert("+")
        tap(4, 2)
        tap(3, 2)
        try expect(editing.text == "C3+C4" && editing.field?.text == "C3+C4", "formula \(editing.text), field \(String(describing: editing.field?.text))")
        try expect(editing.references.map(\.rows) == [2...2, 3...3], "references \(editing.references)")
        editing.field?.done?()
        for _ in 0..<60 where tables.formula != nil { try? await Task.sleep(for: .milliseconds(50)) }
        try expect(tables.formula == nil, "the formula page is still up")
        try expect(text(of: key) == "=C3+C4", "cell \(text(of: key))")
        // 16% + 17%.
        try expect(tables.result(key) == "0.33", "result \(String(describing: tables.result(key)))")
        try expect(tables.editing == key, "the cell isn't ringed")
        if DocDevice.isMac {
            tables.editFormula(key)
            let again = try await opened("reopening")
            try expect(again.text == "C3+C4", "the formula reopens as \(again.text)")
            again.field?.text = ""
            again.typed("", selection: NSRange(location: 0, length: 0))
            again.insert(function: "SUM")
            try expect(again.opensArguments, "no directions after SUM(")
            again.insert("ABOVE")
            // The body cells above it: C2 to C4.
            try expect(again.references.map(\.rows) == [1...3], "references \(again.references)")
            again.field?.cancel?()
            for _ in 0..<60 where tables.formula != nil { try? await Task.sleep(for: .milliseconds(50)) }
            try expect(tables.formula == nil && text(of: key) == "=C3+C4", "Esc left \(text(of: key))")
        }
        try await undo()
        try expect(text(of: key) == before, "undo left \(text(of: key))")
    }

    private func text(of key: DocCellKey) -> String { editor.tables.text(key) }

    // MARK: Helpers

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    private func expectValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
    }

    /// Chooses the item at `path` in a menu (titles, through submenus), as a click on it would.
    private func perform(_ menu: [FlooDesignActionMenuSection], _ path: [String]) throws {
        func find(_ sections: [FlooDesignActionMenuSection], _ path: ArraySlice<String>) -> FlooDesignActionMenuItem? {
            guard let title = path.first, let item = sections.flatMap(\.items).first(where: { $0.title == title }) else { return nil }
            if path.count == 1 { return item.submenu == nil ? item : nil }
            return item.submenu.flatMap { find($0, path.dropFirst()) }
        }
        let item = try expectValue(find(menu, path[...]), "no \(path.joined(separator: " › ")) in the menu")
        item.perform()
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
    /// Presses Esc in a responder (its key command); false if it has none.
    private func escape(_ responder: UIResponder) -> Bool {
        guard let command = responder.keyCommands?.first(where: { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty }),
            let action = command.action
        else { return false }
        responder.perform(action, with: command)
        return true
    }

    /// Until a view stops moving on screen (a scroll to it comes to rest).
    /// Brings a block's row on screen and waits for the list to be still: it scrolls
    /// there with a spring, longer the farther it goes.
    private func bringIntoView(_ id: DocBlockID) async {
        demo.bringIntoView(id)
        var offset: CGFloat?
        for _ in 0..<150 {
            try? await Task.sleep(for: .milliseconds(20))
            guard let list = editor.allTextViews.lazy.compactMap({ DocScrolling.list(of: $0) }).first,
                  let frame = demo.rowFrame(id.description), DocScrolling.visible(in: list).intersects(frame) else { continue }
            if offset == list.contentOffset.y { return }
            offset = list.contentOffset.y
        }
    }

    private func rest(_ view: UIView) async {
        var shown = view.convert(view.bounds, to: nil)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(25))
            let now = view.convert(view.bounds, to: nil)
            if now == shown { return }
            shown = now
        }
    }

    /// From the action to the end of the run loop pass it happens in: after Core
    /// Animation's commit (its observer comes before ours), so its layout and drawing.
    @MainActor private func frameTime(_ action: @MainActor () -> Void) async -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        action()
        return await withCheckedContinuation { continuation in
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { observer, _ in
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                continuation.resume(returning: (CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private func settle() async throws {
        // Let the run loop go idle once, as it does between two real key presses (an
        // undo group is one run loop pass: two keys in one pass would undo together).
        try? await Task.sleep(for: .milliseconds(5))
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

    static let notes = "Notes picked for the test.\n"

    /// A 300 × 200 PNG (at 72 dpi), in a folder of its own.
    static func writePNG() -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let url = DocInsertSources.folder().appendingPathComponent("Picked.png")
        try? image.pngData()?.write(to: url)
        return url
    }

    static func pickedImage() -> DocPicked { .file(writePNG(), name: "Picked.png", type: .png) }

    static func pickedText() -> DocPicked {
        let url = DocInsertSources.folder().appendingPathComponent("notes.txt")
        try? notes.write(to: url, atomically: true, encoding: .utf8)
        return .file(url, name: "notes.txt", type: .plainText)
    }
}

/// A source that gives what it's told, with no picker.
private struct DocTestInsertSource: DocInsertSource {
    let picks: () -> [DocPicked]
    let id = "insert-test"
    let title = "Test Source"
    let symbol = "testtube.2"
    let glyph = DocBlockIcon.Glyph.folder
    let keywords = ["testsource"]
    var isAvailable: Bool { true }

    init(picks: @escaping () -> [DocPicked]) { self.picks = picks }

    func pick(over presenter: UIViewController) async -> [DocPicked] { picks() }
}
