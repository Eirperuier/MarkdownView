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
                let lastLine = view.caretRect(for: view.endOfDocument)
                let inView = CGPoint(x: max(lastLine.maxX + 40, view.bounds.maxX + 20), y: lastLine.midY)
                var point = view.convert(inView, to: nil)
                // On a narrow screen the line can reach the edge: stay inside the window.
                point.x = min(point.x, (view.window?.bounds.maxX ?? point.x) - 8)
                var hit = view.window?.hitTest(point, with: nil)
                var chain: [String] = []
                while let current = hit, chain.count < 3 { chain.append("\(Swift.type(of: current))"); hit = current.superview }
                let catcher = chain.contains { $0.contains("RowClickArea") }
                let textViewHit = chain.contains { $0.contains("TextView") }
                try self.expect(catcher || textViewHit, "click lands on \(chain)")
                // What the row's click area does (a text view hit is the text view's own click).
                if catcher { self.editor.click(block.id, at: point) } else {
                    try await self.focus(block.id, at: block.text.length)
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
            try await self.type("/分割")
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
            try await self.type("/公式")
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
            throw Failure(description: "\(step): cell \(position(key)) never got an editor with the focus; editing \(position(self.editor.tables.editing)), active \(position(self.editor.tables.active)), table \(t.database.rows.count + 1)×\(t.database.columns.count)")
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
