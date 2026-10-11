//
//  DocEditTests.swift
//  DemoApp
//
//  Scripted editing against the real page: keystrokes go into the on-screen text
//  views through UIKeyInput (the keyboard's own path), and after each one the model,
//  the storage and the cursor must agree. Run with `-docDemo YES -docEditTest YES`;
//  results are printed as `DOCTEST PASS|FAIL <name>` and a `DOCTEST DONE` summary.
//

import SwiftUI
import UIKit
import DocKit
import MarkdownView

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

    /// Return at the end of every kind of block near the top, then undo: both lines
    /// must stay on screen showing their text, and undo must bring back exactly the
    /// document there was.
    private func sweepReturn() async {
        if let filter, !"Return at the end of".contains(filter) { return }
        demo.reset()
        editor.resetHistory()
        try? await Task.sleep(for: .milliseconds(300))
        let targets = demo.doc.blocks.prefix(40).enumerated().filter { $0.element.kind.allowsMarks }.map(\.offset)
        for index in targets {
            demo.reset()
            editor.resetHistory()
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
                print("DOCTEST PASS \(name)")
            } catch {
                failed += 1
                print("DOCTEST FAIL \(name): \(error)")
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
                self.demo.bringIntoView(block.id)
                try? await Task.sleep(for: .milliseconds(400))
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
        await test("Quotes, dashes and dots stay as typed (no smart punctuation)") {
            let line = try await emptyLine()
            try await self.type("don't say \"no\" -- wait...")
            try self.expect(self.text(line.id) == "don't say \"no\" -- wait...", "text \(self.text(line.id).debugDescription)")
            try await self.showsModelSoon(line.id)
        }
        await test("Slash menu: “/h2” and Return makes a heading 2") {
            let line = try await emptyLine()
            try await self.type("/")
            try self.expect(self.editor.slash.isOpen && self.editor.slash.items.count == DocSlashItem.all.count, "menu open \(self.editor.slash.isOpen) items \(self.editor.slash.items.count)")
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
        await test("Slash menu: ↓↓ then Return picks the third item; one undo takes it back") {
            let line = try await emptyLine()
            try await self.type("/")
            for _ in 0..<2 { UIApplication.shared.sendAction(Selector(("docSlashDown:")), to: nil, from: nil, for: nil) }
            try self.expect(self.editor.slash.highlighted == 2, "highlighted \(self.editor.slash.highlighted)")
            try await self.enter()
            try self.expect(self.demo.doc.block(line.id)?.kind == DocSlashItem.all[2].action.kind, "kind \(String(describing: self.demo.doc.block(line.id)?.kind))")
            try await self.undo()
            try self.expect(self.demo.doc.block(line.id)?.kind == .paragraph && self.text(line.id) == "/", "undo: \(String(describing: self.demo.doc.block(line.id)?.kind)) \(self.text(line.id).debugDescription)")
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
        await test("Slash menu: a space closes it; a slash inside a word doesn't open it") {
            let line = try await emptyLine()
            try await self.type("/x ")
            try self.expect(!self.editor.slash.isOpen, "open after a space")
            try await self.type("a/")
            try self.expect(!self.editor.slash.isOpen, "open after a letter")
            try self.expect(self.text(line.id) == "/x a/", "text \(self.text(line.id).debugDescription)")
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
        await test("Slash menu after text keeps the text: “abc /quote” makes a quote of “abc ”") {
            let line = try await emptyLine()
            try await self.type("abc /quote")
            try self.expect(self.editor.slash.highlightedItem?.id == "quote", "highlighted \(String(describing: self.editor.slash.highlightedItem?.id))")
            try await self.enter()
            try self.expect(self.demo.doc.block(line.id)?.kind == .quote && self.text(line.id) == "abc ", "\(String(describing: self.demo.doc.block(line.id)?.kind)) \(self.text(line.id).debugDescription)")
            try self.expectCursor(line.id, 4)
        }
        // MARK: Typing speed

        await test("Typing speed: keystrokes in a long paragraph render within a frame or two") {
            let block = try self.block("The trap is timing")
            // A long paragraph: the block's text four times.
            let long = String(repeating: block.text.string + " ", count: 4)
            try await self.focus(block.id, at: block.text.length)
            try await self.type(" " + long)
            try await self.settle()
            var publish: [Double] = []
            var rows: [Double] = []
            var total: [Double] = []
            for character in "abcdefghijklmnopqrstuvwxyz" {
                let start = CFAbsoluteTimeGetCurrent()
                try self.key(String(character))
                publish.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                rows.append(self.demo.lastPublishMs)
                for _ in 0..<60 {
                    if self.editor.mismatch() == nil { break }
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(1))
                }
                total.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            print("DOCPERF keystroke (ms): rows \(String(format: "%.1f", median(rows))); handling median \(String(format: "%.1f", median(publish))) max \(String(format: "%.1f", publish.max() ?? 0)); on screen median \(String(format: "%.1f", median(total))) max \(String(format: "%.1f", total.max() ?? 0)); text \(self.text(block.id).count) chars, \(self.demo.doc.blocks.count) blocks")
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
        await test("Code block: the language menu sets it") {
            let block = try codeBlock()
            _ = try await edit(block)
            self.editor.sources.setLanguage("python", of: block.id)
            try self.expect(self.demo.doc.block(block.id)?.kind == .code(language: "python"), "kind \(String(describing: self.demo.doc.block(block.id)?.kind))")
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
            let existing = try firstBlock { $0 == .math }
            if existing.id != line.id {
                let other = try await edit(existing)
                try self.expect(other.text == existing.text.string, "existing formula shows \(other.text.debugDescription)")
            }
        }

        // MARK: Tables

        /// The first table: its block, database, and a key maker (row 0 = header).
        func table() throws -> (block: DocBlockID, database: Database, key: (Int, Int) -> DocCellKey) {
            guard let block = self.demo.doc.blocks.first(where: { $0.kind.databaseID != nil }),
                  let id = block.kind.databaseID, let database = self.demo.doc.databases[id]
            else { throw Failure(description: "no table") }
            return (block.id, database, { row, column in
                DocCellKey(block: block.id, row: row == 0 ? nil : database.rows[row - 1].id, column: database.columns[column].id)
            })
        }
        func database() throws -> Database { try table().database }
        /// Clicks a cell (what MarkdownView's cell tap does) and waits for its editor.
        func click(_ row: Int, _ column: Int) async throws -> DocCellTextView {
            let t = try table()
            let snapshot = DocTableSnapshot(block: t.block, database: t.database)
            self.demo.bringIntoView(t.block)
            try? await Task.sleep(for: .milliseconds(300))
            self.editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: row, column: column))
            return try await cellEditor(t.key(row, column))
        }
        func cellEditor(_ key: DocCellKey, step: String = "") async throws -> DocCellTextView {
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
            throw Failure(description: "\(step): cell \(position(key)) never got an editor with the focus; editing \(position(self.editor.tables.editing)), active \(position(self.editor.tables.active)), table \(t.database.rows.count + 1)×\(t.database.columns.count); row \(String(describing: row)) visible \(String(describing: list.map { DocScrolling.visible(in: $0) })) bounds \(String(describing: list?.bounds)) view \(self.editor.tables.view(for: key) != nil)")
        }
        /// A key as UIKit sends it: the delegate first (Tab and Return move between cells).
        func press(_ view: DocCellTextView, _ key: String) {
            if view.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: key) { view.insertText(key) }
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
        }
        await test("Table: clicking a cell edits it in place; typing changes the cell; one undo takes the typing back") {
            let view = try await click(2, 1)
            try self.expect(view.text == "6:10", "editor shows \(view.text.debugDescription)")
            view.insertText("!")
            try? await Task.sleep(for: .milliseconds(100))
            try self.expect(self.editor.tables.view(for: try editedKey()) === view && view.isFirstResponder, "the editor was replaced while typing (focused \(view.isFirstResponder))")
            view.insertText("?")
            try self.expect(try cellText(2, 1) == "6:10!?", "cell \(String(describing: try? cellText(2, 1)))")
            try await self.undo()
            try self.expect(try cellText(2, 1) == "6:10", "undo: \(String(describing: try? cellText(2, 1)))")
            try? await Task.sleep(for: .milliseconds(100))
            let shown = self.editor.tables.view(for: try table().key(2, 1))
            try self.expect(shown?.text == "6:10", "editor after undo \(String(describing: shown?.text)) same view \(shown === view)")
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
            view.insertText("n")
            try self.expect(try cellText(rows + 1, columns) == "n", "new cell \(String(describing: try? cellText(rows + 1, columns)))")
        }
        await test("Table: every menu action changes the table, and one undo puts it back exactly") {
            let before = try database()
            let actions: [DocTableAction] = [.insertRowAbove, .insertRowBelow, .insertColumnLeft, .insertColumnRight,
                                             .moveRowUp, .moveRowDown, .moveColumnLeft, .moveColumnRight,
                                             .sortAscending, .sortDescending, .insertFormula, .deleteRow, .deleteColumn, .clearCell]
            for action in actions {
                _ = try await click(2, 1)
                let key = try editedKey()
                try self.expect(self.editor.tables.isAvailable(action, at: key), "\(action) not available")
                self.editor.tables.perform(action, at: key)
                try? await Task.sleep(for: .milliseconds(100))
                try self.expect(try database() != before, "\(action) changed nothing")
                try await self.undo()
                try self.expect(try database() == before, "undo after \(action) left the table changed")
            }
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
        await test("Table: a formula shows its result in the table, its text in the editor; 插入公式 starts one") {
            let view = try await click(4, 2)
            self.editor.tables.perform(.insertFormula, at: try editedKey())
            try? await Task.sleep(for: .milliseconds(200))
            try self.expect(try cellText(4, 2) == "=SUM(ABOVE)", "cell \(String(describing: try? cellText(4, 2)))")
            let shown = self.editor.tables.view(for: try table().key(4, 2)) ?? view
            try self.expect(shown.text == "=SUM(ABOVE)", "editor shows \(shown.text.debugDescription)")
            // 21% + 16% + 17% above it.
            let result = self.editor.tables.result(try table().key(4, 2))
            try self.expect(result == "0.54", "result \(String(describing: result))")
            let markdown = self.demo.doc.markdown(of: try table().block) ?? ""
            try self.expect(markdown.replacing("\\", with: "").contains("| 0.54 |"), "markdown \(markdown)")
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
            _ = try await click(1, 1)
            try self.expect(self.editor.tables.editing != nil, "not editing")
            UIApplication.shared.sendAction(Selector(("leaveTable")), to: nil, from: nil, for: nil)
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
        print("DOCTEST DONE pass=\(passed) fail=\(failed)")
    }

    /// The bar over a phone's keyboard (DocKeyboardBar.swift). It exists on the Mac too,
    /// only not over a keyboard, so it is driven directly.
    private func keyboardBarTests() async {
        let bar = editor.keyboardBar
        await test("the keyboard bar offers marks for selected text; bold applies and shows on") {
            let block = try self.block("Loading older")
            try await self.select(block.id, 0..<7)
            try self.expect(bar.testItems.map(\.id) == ["highlight", "bold", "italic", "strike", "code", "link", "dismiss"], "keys \(bar.testItems.map(\.id))")
            bar.testTap("bold")
            try await self.settle()
            let marks = self.demo.doc.block(block.id)?.text.marks ?? []
            try self.expect(marks.contains(MarkSpan(range: 0..<7, mark: .bold)), "marks \(marks)")
            try self.expect(bar.testItems.first { $0.id == "bold" }?.isOn == true, "bold not shown on")
        }
        await test("the keyboard bar's highlight key opens the colours; a second tap closes them") {
            let block = try self.block("Loading older")
            try await self.select(block.id, 0..<7)
            bar.testTap("highlight")
            try self.expect(bar.showsColors, "no colours")
            try self.expect(bar.testItems.first { $0.id == "highlight" }?.isOn == false, "the key isn't on for the text")
            bar.testTap("highlight")
            try self.expect(!bar.showsColors, "the colours stay")
        }
        await test("the keyboard bar's slash types a slash and opens the menu; Aa puts the format sheet in the keyboard's place") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: block.text.length)
            try self.expect(bar.testItems.map(\.id) == ["slash", "format", "more", "dismiss"], "keys \(bar.testItems.map(\.id))")
            if !DocBlockController.usesHandles {
                bar.testTap("format")
                try self.expect(self.editor.showsFormatInput && self.editor.panels.sheetPage == .main, "no sheet")
                try self.expect(bar.testItems.first { $0.id == "format" }?.isOn == true, "Aa not on")
                // A caret stands for its block: the sheet's style goes on it.
                DocFormatting(editor: self.editor, caretTakesBlock: true).setStyle(.heading(level: 2))
                try await self.settle()
                try self.expect(self.demo.doc.block(block.id)?.kind == .heading(level: 2), "kind \(String(describing: self.demo.doc.block(block.id)?.kind))")
                bar.testTap("format")
                try self.expect(!self.editor.showsFormatInput && self.editor.panels.sheetPage == nil, "the sheet stays")
            }
            bar.testTap("slash")
            try await self.settle()
            try self.expect(self.text(block.id).hasSuffix("/") && self.editor.slash.isOpen, "text \(self.text(block.id).debugDescription) open \(self.editor.slash.isOpen)")
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
                    for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(20)); shown.append(y()) }
                    let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
                    try self.expect(steps.allSatisfy { $0 <= 0.5 } && steps.allSatisfy { abs($0) < 60 }, "\(prefix) moved \(shown.map { Int($0) })")
                    let caret = view.convert(view.caretRect(for: view.selectedTextRange!.end), to: nil)
                    let list = try self.expectValue(DocScrolling.list(of: view), "no list")
                    let visible = list.convert(DocScrolling.visible(in: list), to: nil)
                    try self.expect(caret.maxY <= visible.maxY, "\(prefix): caret \(caret.maxY) under the keyboard at \(visible.maxY)")
                    try self.expect(shown.last == before || before > visible.maxY - 30, "\(prefix) moved from \(before) to \(shown.last!) though it showed")
                    let settled = y()
                    bar.testTap("dismiss")
                    for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(20)); try self.expect(y() == settled, "\(prefix) moved as the keyboard went: \(settled) → \(y())") }
                    try self.expect(!view.isFirstResponder, "\(prefix): the keyboard stayed")
                }
            }
        }
        await test("on an empty line the keyboard bar's divider key makes it a divider") {
            let block = try self.block("Loading older")
            try await self.focus(block.id, at: block.text.length)
            try await self.enter()
            let line = try self.blockAfter(block.id)
            try self.expect(bar.testItems.map(\.id) == ["slash", "format", "more", "divider", "dismiss"], "keys \(bar.testItems.map(\.id))")
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
            try self.expect(DocFormatting(editor: self.editor, caretTakesBlock: true).targets.map(\.id) == [first.id], "targets")
            DocFormatting(editor: self.editor, caretTakesBlock: true).toggleList(.listItem(style: .task(done: false)))
            try self.expect(self.demo.doc.block(first.id)?.kind == .listItem(style: .task(done: false)), "kind \(String(describing: self.demo.doc.block(first.id)?.kind))")
            blocks.endSelecting()
            try self.expect(self.editor.panels.sheetPage == nil, "the sheet stays")
        }
    }

    /// Blocks as wholes: the handle, selecting, moving (DocBlocks.swift).
    private func blockTests() async {
        let blocks = editor.blocks
        func order() -> [DocBlockID] { demo.doc.blocks.map(\.id) }
        func show(_ id: DocBlockID) async {
            demo.bringIntoView(id)
            try? await Task.sleep(for: .milliseconds(500))
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
            await test("every block's handle is in the same column, nested or not") {
                let paragraph = try self.block("这篇文档由 DocKit")
                let nested = try self.block("编号也一样")
                var xs: [CGFloat] = []
                for id in [paragraph.id, nested.id] {
                    await show(id)
                    blocks.testHover(id)
                    xs.append(try self.expectValue(blocks.testHandleFrame, "no handle").minX)
                }
                try self.expect(xs[0] == xs[1], "handles at \(xs)")
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
        await test("a list item moves with its nested items, and comes out a level where it lands") {
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
            try self.expect(moved == indents.map { $0 - 1 }, "indents \(moved), were \(indents)")
            try await self.undo()
            try self.expect(group.compactMap { self.demo.doc.block($0)?.indent } == indents, "undo left indents")
        }
        await test("a copy of the selection goes right after it, a table's with a database of its own") {
            let paragraph = try self.block("Loading older")
            let table = try self.expectValue(self.demo.doc.blocks.first { $0.kind.databaseID != nil }, "no table")
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
            let table = try self.expectValue(self.demo.doc.blocks.first { $0.kind.databaseID != nil }, "no table")
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
            let width = DocMediaLayout.pageWidth
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
        await test("a selected image fills and goes large, and draws at the page's width") {
            let image = try self.expectValue(self.demo.doc.blocks.first { if case .image = $0.kind { true } else { false } }, "no image")
            await show(image.id)
            blocks.select([image.id])
            blocks.setImage(fit: .fill, size: .large)
            guard case .image(let changed)? = self.demo.doc.block(image.id)?.kind else { throw Failure(description: "not an image") }
            try self.expect(changed.fit == .fill && changed.size == .large, "image \(changed)")
            try? await Task.sleep(for: .milliseconds(400))
            let row = try self.expectValue(blocks.testRowFrame(image.id), "no row")
            let height = DocMediaLayout.imageHeight(changed, width: DocMediaLayout.pageWidth)
            try self.expect(abs(row.height - (height + (self.demo.spacingAbove[image.id.description] ?? 0))) < 2, "row \(row.height), image \(height)")
            blocks.clear()
        }
        await test("cards next to each other share a line; a point on each picks that one") {
            let line = try self.expectValue(self.linkCards(), "no line of cards")
            await show(line[0])
            let left = try self.expectValue(blocks.testContentFrame(line[0]), "no frame")
            let right = try self.expectValue(blocks.testContentFrame(line[1]), "no frame")
            try self.expect(left.minY == right.minY && right.minX > left.maxX, "cards at \(left) and \(right)")
            try self.expect(blocks.testBlock(at: CGPoint(x: left.midX, y: left.midY)) == line[0], "left point picks another block")
            try self.expect(blocks.testBlock(at: CGPoint(x: right.midX, y: right.midY)) == line[1], "right point picks another block")
        }
        await test("a file turned into a card after cards joins their run, its row the same") {
            let pdf = try self.expectValue(self.demo.doc.blocks.first { if case .file(let file) = $0.kind { file.name.hasSuffix(".pdf") } else { false } }, "no pdf")
            let index = try self.expectValue(self.demo.rows.firstIndex { $0.block == pdf.id }, "no pdf row")
            try self.expect(index > 0 && self.demo.rows[index - 1].place?.lineHeight != nil, "the pdf doesn't follow cards")
            blocks.setLayout(.card, of: [pdf.id])
            try? await Task.sleep(for: .milliseconds(700))
            let row = try self.expectValue(self.demo.rows.first { $0.block == pdf.id }, "no pdf row")
            try self.expect(row.place.map { $0.lineHeight != nil && !$0.startsRun } == true, "the pdf didn't join the cards: \(String(describing: row.place))")
            try self.expect(blocks.testRowFrame(pdf.id).map { $0.width < DocMediaLayout.pageWidth / 2 + 1 } == true, "the pdf's row isn't a card's")
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
        await test("a card dropped on the near half of another on its line goes beside it, on the line; only it dims while it lands") {
            let line = try self.expectValue(self.linkCards(), "no line of cards")
            let (first, second) = (line[0], line[1])
            let ids = order()
            await show(first)
            let target = try self.expectValue(blocks.testContentFrame(first), "no card")
            blocks.testDrag(second, toY: target.midY, x: target.minX + 20)
            try self.expect(blocks.testDimmed == [second], "dimmed while landing \(blocks.testDimmed)")
            let after = order()
            let at = try self.expectValue(ids.firstIndex(of: first), "no card")
            try self.expect(after[at] == second && after[at + 1] == first, "order \(String(describing: after.firstIndex(of: second)))")
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
            let renderer = ImageRenderer(content: DocMediaView(kind: block.kind).frame(width: DocMediaLayout.pageWidth, alignment: .topLeading))
            renderer.scale = 1
            let image = try self.expectValue(renderer.cgImage, "not drawn")
            let data = try self.expectValue(image.dataProvider?.data.flatMap(CFDataGetBytePtr), "no pixels")
            let (perRow, step) = (image.bytesPerRow, image.bitsPerPixel / 8)
            // The text between the preview (104 tall) and the footer: white and greys only.
            var coloured = 0, all = 0
            for y in 108..<190 where y < image.height {
                for x in 0..<min(image.width, Int(DocMediaLayout.cardWidth)) {
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
            let next = try self.expectValue(rows[(index + 1)...].first { $0.place?.sharesLine != true }?.block, "nothing after the line")
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
                return rows[index].place?.sharesLine == true
            }, "no gallery")
            let (image, before) = try (self.expectValue(rows[index].block, "no image"), self.expectValue(rows[index - 1].block, "no image"))
            let line = self.line(of: image)
            let next = try self.expectValue(rows[(index + 1)...].first { $0.place?.sharesLine != true }?.block, "nothing after the gallery")
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
            blocks.opensURL = { opened.append($0) }
            defer { blocks.opensURL = { UIApplication.shared.open($0) } }
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
        await test("a list item is selected alone; dragged, its nested items go with it, each lifted from its row") {
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
            try self.expect(blocks.testDimmed.isSuperset(of: group.filter { blocks.testContentFrame($0) != nil }), "not dimmed while landing \(blocks.testDimmed)")
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
            await test("on a phone a block lifted and let go where it was starts selecting with it") {
                let block = try self.block("Loading older")
                await show(block.id)
                blocks.testLiftAndLetGo(block.id)
                try self.expect(blocks.isSelecting && blocks.selected == [block.id], "selecting \(blocks.isSelecting), \(blocks.selected.count)")
                blocks.endSelecting()
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

    /// -docTestFilter <text>: only the tests whose names contain it.
    private let filter = UserDefaults.standard.string(forKey: "docTestFilter")

    private func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
        if let filter, !name.contains(filter) { return }
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

    // MARK: Reshaping

    /// A link, file or image alone on its line, with a line starting right after it.
    private func mediaAlone(_ matches: (BlockKind) -> Bool) -> (block: DocBlock, next: DocBlockID)? {
        let rows = demo.rows
        for (index, row) in rows.enumerated() where row.place?.sharesLine != true && index + 1 < rows.count {
            guard let id = row.block, let block = demo.doc.block(id), matches(block.kind),
                  rows[index + 1].place?.sharesLine != true, let next = rows[index + 1].block else { continue }
            return (block, next)
        }
        return nil
    }

    /// The blocks on the line a block's row is on, in order.
    private func line(of id: DocBlockID) -> [DocBlockID] {
        let rows = demo.rows
        guard var start = rows.firstIndex(where: { $0.block == id }) else { return [] }
        while start > 0, rows[start].place?.sharesLine == true { start -= 1 }
        var end = start + 1
        while end < rows.count, rows[end].place?.sharesLine == true { end += 1 }
        return rows[start..<end].compactMap(\.block)
    }

    /// The first line of two or more link cards.
    private func linkCards() -> [DocBlockID]? {
        let rows = demo.rows
        for (index, row) in rows.enumerated() where index + 1 < rows.count && rows[index + 1].place?.sharesLine == true {
            guard case .link? = row.media, row.place?.sharesLine != true, let id = row.block else { continue }
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
        print("DOCTEST TRACE reshape \(start.bottom)/\(start.next) → \(trace)")
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
        func sample() throws -> (box: CGRect, opacity: Float, next: CGFloat?, still: CGRect?) {
            let box = try expectValue(blocks.testShownBox(id), "no box drawn")
            return (box.frame, box.opacity, blocks.testShownRowFrame(next)?.minY, blocks.testShownRowFrame(still))
        }
        let start = try sample()
        let began = CACurrentMediaTime()
        change()
        var samples: [(time: Double, box: CGRect, opacity: Float, next: CGFloat?, still: CGRect?)] = []
        while CACurrentMediaTime() - began < 0.7 {
            try? await Task.sleep(for: .milliseconds(8))
            let shown = try sample()
            samples.append((CACurrentMediaTime() - began, shown.box, shown.opacity, shown.next, shown.still))
        }
        let end = try expectValue(samples.last, "no samples")
        let trace = samples.map {
            String(format: "%.3f:(%.0f,%.0f %.0fx%.0f a%.2f)/%.1f", $0.time, $0.box.minX - start.box.minX, $0.box.minY - start.box.minY,
                   $0.box.width, $0.box.height, $0.opacity, ($0.next ?? .nan) - (start.next ?? .nan))
        }.joined(separator: " ")
        print("DOCTEST TRACE move \(start.box) → \(trace)")
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
        let shown = samples.compactMap(\.next)
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        let direction: CGFloat = place.minY >= (start.next ?? shown.first ?? place.minY) ? 1 : -1
        try expect(steps.allSatisfy { $0 * direction >= -1 }, "the next row went back: \(trace)")
        if let rest = end.next { try expect(abs(rest - place.minY) < 0.5, "next row rests at \(rest), its place is \(place.minY)") }
        // At rest where the layout puts its box; the row that stays never moved.
        let content = try expectValue(blocks.testContentFrame(id), "no frame")
        try expect(abs(end.box.minX - content.minX) < 1 && abs(end.box.minY - content.minY) < 1, "box rests at \(end.box), its place is \(content)")
        try expect(samples.allSatisfy { $0.still.map { abs($0.minY - stays.minY) < 0.5 && abs($0.minX - stays.minX) < 0.5 } ?? true },
                   "the row that stays moved")
    }

    // MARK: Helpers

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    private func expectValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
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
    private func rest(_ view: UIView) async {
        var shown = view.convert(view.bounds, to: nil)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(25))
            let now = view.convert(view.bounds, to: nil)
            if now == shown { return }
            shown = now
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
}
