//
//  DocSourceEditing.swift
//  DemoApp
//
//  Code and math blocks are edited as their source. A code block is Craft's, read and
//  edited alike (DocCodeBox): a box with a thin border, the lines numbered in a gutter
//  on its left, the code beside them, its long lines running on and scrolling sideways
//  past the gutter; while it's edited, ringed, its caret's line lit. Its language and
//  Copy Code are in its menu: the block's (a right-click on it), the text's (a
//  right-click in it on the Mac) and the keyboard bar's </> on a phone.
//  A math block is written as a cell's formula
//  is (DocTableFormula), its LaTeX in a panel and the formula, ringed, following on the
//  page: on the Mac the panel is under the block (the menus' anchored panel), on a phone
//  it's glass over the keyboard (its bar), the page scrolled to show the block above it.
//  Under the LaTeX a row of keys puts in what's long to type (a fraction, a root, powers
//  and indices, a sum, an integral; symbols in the system's menu), the caret in their
//  first braces. The panel goes when the LaTeX lets the focus go. Read, a formula is
//  MarkdownView's.
//
//  Keys: Return keeps the line's indentation, Tab / Shift-Tab indent and outdent the
//  line by four spaces, ↑ on the first line and ↓ on the last go to the block above and
//  below, ⌘Return leaves to the block below (a new paragraph at the end), Esc leaves,
//  Backspace in an empty block turns it into a paragraph. Typing is one undo step until
//  the caret moves elsewhere.
//

import CardRuntime
import FlooUIKit
import SwiftUI
import UIKit
import DocKit
import MarkdownView
import MessagingUI

enum DocSourceKind: Equatable {
    case code(language: String?)
    case math

    init?(_ kind: BlockKind) {
        switch kind {
        case .code(let language): self = .code(language: language)
        case .math: self = .math
        default: return nil
        }
    }
}

@MainActor
@Observable
final class DocSourceController {
    @ObservationIgnored private let demo: DocDemo
    @ObservationIgnored unowned let editor: DocEditor
    /// The code or math block being edited.
    private(set) var editing: DocBlockID?
    @ObservationIgnored private var views: [DocBlockID: [WeakSourceView]] = [:]
    @ObservationIgnored private var pendingFocus: (block: DocBlockID, offset: Int?, reveals: Bool)?
    @ObservationIgnored private var session: UInt64 = 0
    /// The keyboard bar's height while it's up (a phone): the math panel sits on it.
    var keyboardBarHeight: CGFloat = 0
    /// Where each math block is on the page: the page scrolls to show it over the panel.
    @ObservationIgnored var mathRows: [DocBlockID: WeakView] = [:]

    struct WeakView {
        weak var view: UIView?
    }

    /// A code block's languages (Craft's, by name), as the markdown names them.
    static let languages: [(id: String, name: String)] = [
        ("ada", "Ada"), ("bash", "Bash"), ("cpp", "C++"), ("csharp", "C#"), ("css", "CSS"), ("dart", "Dart"),
        ("dockerfile", "Dockerfile"), ("go", "Go"), ("groovy", "Groovy"), ("haskell", "Haskell"), ("html", "HTML"),
        ("java", "Java"), ("javascript", "JavaScript"), ("json", "JSON"), ("julia", "Julia"), ("kotlin", "Kotlin"),
        ("lua", "Lua"), ("markdown", "Markdown"), ("matlab", "Matlab"), ("objectivec", "Objective-C"), ("perl", "Perl"),
        ("php", "PHP"), ("prolog", "Prolog"), ("python", "Python"), ("r", "R"), ("ruby", "Ruby"), ("rust", "Rust"),
        ("scala", "Scala"), ("sql", "SQL"), ("swift", "Swift"), ("typescript", "TypeScript"), ("xml", "XML"), ("yaml", "YAML"),
    ]

    init(demo: DocDemo, editor: DocEditor) {
        self.demo = demo
        self.editor = editor
    }

    var isEditable: Bool { editor.isEditable }

    func text(_ block: DocBlockID) -> String { demo.doc.block(block)?.text.string ?? "" }

    func register(_ view: DocSourceTextView, for block: DocBlockID) {
        views[block, default: []].removeAll { $0.view == nil || $0.view === view }
        views[block, default: []].append(WeakSourceView(view: view))
        if let pending = pendingFocus, pending.block == block { focusSoon(block, at: pending.offset, reveals: pending.reveals) }
    }

    func view(for block: DocBlockID) -> DocSourceTextView? {
        views[block]?.compactMap(\.view).first { $0.window?.isKeyWindow == true }
    }

    /// The block's text view on screen, its window key or not (the tests').
    func testShownView(_ block: DocBlockID) -> DocSourceTextView? {
        views[block]?.compactMap(\.view).first { $0.window != nil }
    }

    /// Edits the block with the caret at `offset` (nil: where a click put it, or the end).
    /// `reveals`: the page scrolls to show the editor (not for a click on it).
    func focus(_ block: DocBlockID, at offset: Int? = nil, reveals: Bool = true) {
        guard isEditable, demo.doc.block(block).flatMap({ DocSourceKind($0.kind) }) != nil else { return }
        if editing != block { session &+= 1 }
        editing = block
        editor.tables.endEditing()
        guard let view = view(for: block) else { return focusSoon(block, at: offset, reveals: reveals) }
        pendingFocus = nil
        if !view.isFirstResponder { view.becomeFirstResponder() }
        if let offset {
            view.selectedRange = NSRange(location: min(offset, view.text.utf16.count), length: 0)
        } else if !view.isFirstResponder {
            view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        }
        guard reveals else { return }
        reveal(view)
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .milliseconds(450))
            if let self, let view, view.isFirstResponder { self.reveal(view) }
        }
    }

    /// The whole editor when it fits on screen (a formula's LaTeX and its preview's
    /// top), else the caret's line.
    private func reveal(_ view: DocSourceTextView) {
        if let list = DocScrolling.list(of: view), view.bounds.height + 48 <= DocScrolling.visible(in: list).height {
            DocScrolling.reveal(view)
        } else {
            DocScrolling.reveal(view, rect: view.selectedTextRange.map { view.caretRect(for: $0.end) })
        }
    }

    private func focusSoon(_ block: DocBlockID, at offset: Int?, reveals: Bool = true) {
        pendingFocus = (block, offset, reveals)
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                guard let self, let pending = self.pendingFocus, pending.block == block else { return }
                if self.view(for: block) != nil { return self.focus(block, at: offset, reveals: pending.reveals) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func syncEditedText() {
        guard let editing, let view = view(for: editing) else { return }
        view.show(text(editing))
    }

    /// The document was started over. An editor can be ahead of its row (what's typed shows
    /// before the row does), and a row that comes out the same brings it nothing.
    func showModel() {
        for (block, list) in views {
            guard demo.doc.block(block) != nil else { continue }
            let model = text(block)
            for view in list.compactMap(\.view) where view.text != model { view.show(model) }
        }
    }

    /// The panel's 完成, or a touch outside it: the source closes.
    func dismiss(_ block: DocBlockID) {
        view(for: block)?.resignFirstResponder()
        if editing == block { endEditing() }
    }

    /// The focus went elsewhere in the document.
    func endEditing() {
        let view = editing.flatMap { view(for: $0) }
        pendingFocus = nil
        editing = nil
        // A code block's text view stays on the page: it lets the focus go too.
        if let view, view.isFirstResponder { view.resignFirstResponder() }
    }

    /// The source let the focus go: a math block's panel goes with it.
    func ended(_ block: DocBlockID) {
        guard editing == block, demo.doc.block(block)?.kind == .math else { return }
        endEditing()
    }

    /// A math key: `snippet` in place of the selection, the caret `caret` units into it
    /// (in its first braces). A command run on into a letter after it is kept apart.
    func insert(_ snippet: String, caret: Int? = nil, in block: DocBlockID) {
        guard let view = view(for: block) else { return }
        var snippet = snippet
        let range = view.selectedRange
        let after = NSMaxRange(range) < view.text.utf16.count ? (view.text as NSString).substring(with: NSRange(location: NSMaxRange(range), length: 1)) : ""
        if caret == nil, snippet.last?.isLetter == true, after.first?.isLetter == true { snippet += " " }
        view.insertText(snippet)
        if let caret { view.selectedRange = NSRange(location: range.location + caret, length: 0) }
    }

    /// The page shows the math block over the phone's panel (`room` tall, on the keyboard bar).
    func revealMath(_ block: DocBlockID, over room: CGFloat) {
        DocScrolling.keyboardPanel = room
        if let row = mathRows[block]?.view { DocScrolling.reveal(row) }
        // Again once the keyboard has come up (the page's room changes under it).
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.editing == block, let row = self.mathRows[block]?.view else { return }
            DocScrolling.reveal(row)
        }
    }

    func began(_ block: DocBlockID) {
        if editing != block { session &+= 1 }
        editing = block
        editor.tables.endEditing()
    }

    /// The text view's text is now `text`: the difference becomes steps.
    func changed(_ block: DocBlockID, to text: String) {
        let old = Array(self.text(block).utf16)
        let new = Array(text.utf16)
        guard old != new else { return }
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        var steps: [DocStep] = []
        if prefix < old.count - suffix {
            steps.append(.deleteText(block: block, range: prefix..<(old.count - suffix), removed: DocText()))
        }
        if prefix < new.count - suffix {
            steps.append(.insertText(block: block, at: prefix, text: DocText(string: String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self))))
        }
        _ = demo.edit(steps, before: nil, after: nil, merge: .init(block: block, session: session))
    }

    /// The caret moved (a click, an arrow): the next typing is a new undo step.
    func caretMoved() { session &+= 1 }

    func setLanguage(_ language: String?, of block: DocBlockID) {
        guard let current = demo.doc.block(block), case .code(let old) = current.kind, old != language else { return }
        _ = demo.edit([.setBlock(block: block, kind: .code(language: language), indent: current.indent, previousKind: current.kind, previousIndent: current.indent)], before: nil, after: nil)
        session &+= 1
    }

    /// A code block's menu: its language (Plain Text, then by name) and Copy Code.
    func codeMenu(_ block: DocBlockID) -> [FlooMenuSection] {
        guard case .code(let language)? = demo.doc.block(block)?.kind else { return [] }
        let languages: [FlooMenuSection] = [
            .init([.action(String(localized: "Plain Text"), isOn: language == nil) { [weak self] in
                self?.setLanguage(nil, of: block)
            }]),
            .init(Self.languages.map { choice in
                .action(choice.name, isOn: language == choice.id) { [weak self] in self?.setLanguage(choice.id, of: block) }
            }),
        ]
        return [.init([
            .submenu(String(localized: "Language"), symbol: "chevron.left.forwardslash.chevron.right", languages),
            .action(String(localized: "Copy Code"), symbol: "doc.on.doc") { [weak self] in
                UIPasteboard.general.string = self?.text(block)
            },
        ])]
    }

    /// The menu of a code block's source as a place (nil: a math block's has none).
    func placeMenu(_ block: DocBlockID) -> DocPlaceMenu? {
        guard case .code? = demo.doc.block(block)?.kind else { return nil }
        return DocPlaceMenu(title: String(localized: "Code Block"), symbol: "chevron.left.forwardslash.chevron.right",
                            opens: .rows { [weak self] in self?.codeMenu(block) ?? [] })
    }

    enum Exit { case up, down, below }

    /// Leaves the block for its neighbour's text (a new paragraph below when there is none).
    func leave(_ block: DocBlockID, _ exit: Exit) {
        guard let index = demo.doc.blocks.firstIndex(where: { $0.id == block }) else { return }
        view(for: block)?.resignFirstResponder()
        endEditing()
        let blocks = demo.doc.blocks
        switch exit {
        case .up:
            guard let target = blocks[..<index].last(where: { $0.kind.carriesText }) else { return }
            editor.place(DocPosition(block: target.id, offset: target.text.length))
        case .down, .below:
            if let target = blocks[(index + 1)...].first(where: { $0.kind.carriesText }), exit == .down || target.id == blocks[safe: index + 1]?.id {
                editor.place(DocPosition(block: target.id, offset: 0))
            } else if exit == .below {
                let paragraph = demo.newBlockID()
                _ = demo.edit([.insertBlock(block: DocBlock(id: paragraph, kind: .paragraph), after: block)], before: nil, after: nil)
                editor.place(DocPosition(block: paragraph, offset: 0))
            }
        }
    }

    /// Backspace in an empty code or math block: it becomes a paragraph.
    func becomeParagraph(_ block: DocBlockID) {
        guard let current = demo.doc.block(block), current.text.isEmpty else { return }
        view(for: block)?.resignFirstResponder()
        endEditing()
        _ = demo.edit([.setBlock(block: block, kind: .paragraph, indent: current.indent, previousKind: current.kind, previousIndent: current.indent)], before: nil, after: nil)
        editor.place(DocPosition(block: block, offset: 0))
    }
}

struct WeakSourceView {
    weak var view: DocSourceTextView?
}

/// The source's text view: native typing, every change goes to the model.
final class DocSourceTextView: UITextView, UITextViewDelegate {
    var block: DocBlockID?
    weak var controller: DocSourceController?
    /// Where typing left the caret: a selection change there is the typing's, not a move.
    private var typedCaret: NSRange?
    /// Code is coloured like the read code block (Highlightr), a moment after each change.
    var language: String?
    /// The text's font and line attributes (the field's).
    var baseAttributes: [NSAttributedString.Key: Any] = [:]
    /// The font it shows its text in. Optional: made by UITextView's factory, the view never
    /// runs its properties' initial values.
    var sourceFont: UIFont?
    /// The scheme its code is coloured for: the SwiftUI environment's (Markdown drawn in
    /// its own colours sets one its text views' traits don't have). Optional, as `ink`: made
    /// by UITextView's factory, the view never runs its properties' initial values.
    var scheme: ColorScheme?
    /// Its text's colour where no token colours it (nil: the page's).
    var ink: UIColor?
    /// What the Markdown it's in is drawn on, when it has colours of its own: the
    /// highlighting is made to read on it (ReadableCode).
    var ground: UIColor?
    /// A code block's lines (DocCodeBox): set, the lines don't wrap, the text scrolls
    /// sideways, and the caret's line is lit behind the text while it's edited.
    var code: DocCodeMetrics? {
        didSet { if code != oldValue { setNeedsLayout() } }
    }
    private lazy var backdrop: DocCodeBackdrop = {
        let view = DocCodeBackdrop()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.contentMode = .redraw
        insertSubview(view, at: 0)
        return view
    }()

    /// On the Mac a code block whose row doesn't take clicks (DocBlockController.clickSelects)
    /// still scrolls across: its row takes events for that (DocRow.scrollsAcross), and the
    /// text view only the scrolling. A click goes on to the list, which selects the block.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        guard event?.type != .scroll, let block, controller?.editor.blocks.clickSelects(block) == true else { return hit }
        return nil
    }

    /// The caret is a line of text tall: TextKit's own reaches over the line spacing
    /// below the line, into the gap before the next one.
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        if code != nil, let font, rect.height > font.lineHeight + 1 {
            rect.size.height = ceil(font.lineHeight)
        }
        return rect
    }

    /// A selection is TextKit's, contiguous across lines (the spacing between them
    /// selected too), except that it stops at the bottom of its last line's text
    /// instead of running into the spacing below it.
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let rects = super.selectionRects(for: range)
        guard code != nil else { return rects }
        // The bottom of the last line's text: where the caret at the end reaches.
        let bottom = caretRect(for: range.end).maxY
        let lowest = rects.indices.filter { rects[$0].rect.width > 0 && rects[$0].rect.height > 0 }
            .max { rects[$0].rect.maxY < rects[$1].rect.maxY }
        return rects.enumerated().map { index, rect in
            index == lowest && rect.rect.maxY > bottom + 0.5 ? DocLineSelectionRect(rect, bottom: bottom) : rect
        }
    }

    override func layoutSubviews() {
        // Code lines run on: UITextView sets its container back to its width (when its
        // insets are set, for one).
        if code != nil { runsLinesOn() }
        super.layoutSubviews()
        guard let code else { return }
        // As wide as its longest line (UITextView keeps it to its own width), as tall as
        // its lines: it scrolls only sideways.
        // The lines' own widths: the empty line after a final line break is as wide as
        // the container.
        layoutManager.ensureLayout(for: textContainer)
        var right: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) { _, used, _, _, _ in
            right = max(right, used.maxX)
        }
        let width = max(bounds.width, ceil(right + textContainerInset.left + textContainerInset.right))
        if contentSize.width != width || contentSize.height != bounds.height {
            contentSize = CGSize(width: width, height: bounds.height)
        }
        if contentOffset.y != 0 { contentOffset.y = 0 }
        backdrop.frame = CGRect(x: 0, y: 0, width: max(contentSize.width, bounds.width), height: bounds.height)
        sendSubviewToBack(backdrop)
        var lit: Range<CGFloat>?
        if isFirstResponder, let caret = selectedTextRange?.end {
            let top = caretRect(for: caret).minY - code.gap
            lit = top..<(top + code.pitch)
        }
        if backdrop.lit != lit { backdrop.lit = lit }
    }

    /// A container as wide as the code's lines go (they don't wrap).
    func runsLinesOn() {
        textContainer.widthTracksTextView = false
        if textContainer.size.width < 1_000_000 {
            textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    /// The caret moved or the text changed: the code scrolls to show the caret once both
    /// have settled (UIKit moves the caret after it reports the change), and only then:
    /// scrolling it by hand isn't held back.
    private func followCaret() {
        setNeedsLayout()
        DispatchQueue.main.async { [weak self] in
            self?.layoutIfNeeded()
            self?.showCaret()
        }
    }

    /// Scrolls sideways the least that shows the caret, its insets' room beside it.
    private func showCaret() {
        guard isFirstResponder, let end = selectedTextRange?.end else { return }
        let caret = caretRect(for: end)
        var x = contentOffset.x
        if caret.maxX > x + bounds.width - textContainerInset.right {
            x = caret.maxX - bounds.width + textContainerInset.right
        } else if caret.minX < x + textContainerInset.left {
            x = caret.minX - textContainerInset.left
        }
        x = min(max(0, x), max(0, contentSize.width - bounds.width))
        if x != contentOffset.x { contentOffset.x = x }
    }

    /// Shows `text` (coloured at once), the caret where it was or at the end. Code only
    /// shown, not edited (the agent writing it), is coloured a moment later, what was
    /// there before keeping its colours: it grows at the end.
    func show(_ text: String) {
        guard self.text != text || attributedText.length == 0, markedTextRange == nil else { return }
        let caret = selectedRange
        if controller == nil, attributedText.length > 0, text.hasPrefix(self.text) {
            textStorage.append(NSAttributedString(string: String(text.dropFirst(self.text.count)), attributes: baseAttributes))
        } else {
            attributedText = NSAttributedString(string: text, attributes: baseAttributes)
        }
        if isFirstResponder { selectedRange = NSRange(location: min(caret.location, text.utf16.count), length: 0) }
        if controller == nil { scheduleHighlight() } else { highlightNow() }
    }
    private var highlightTask: Task<Void, Never>?
    private static let highlighter = HighlightrCodeHighlighter()

    /// Colours the text at once (from the read block's highlight when it has one): the
    /// editor taking over a code block mustn't show a frame of plain text.
    func highlightNow() {
        highlightTask?.cancel()
        guard let language else { return }
        guard let runs = Self.highlighter.foregroundColorsNow(code: text ?? "", language: language, colorScheme: scheme ?? .light) else { return }
        apply(runs)
    }

    /// Colours the text again for new colours (the scheme's, the text's own): at once when
    /// the highlight for them is at hand, else plain until it is.
    func recolor() {
        if let language, let runs = Self.highlighter.foregroundColorsNow(code: text ?? "", language: language, colorScheme: scheme ?? .light) {
            apply(runs)
        } else {
            apply([])
            scheduleHighlight()
        }
    }

    private func apply(_ runs: [(NSRange, UIColor)]) {
        let runs = ground.map { ReadableCode.recolored(runs, scheme: scheme ?? .light, on: SRGBColor($0)) } ?? runs
        let storage = textStorage
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: ink ?? DocTokens.UIKitColor.primary, range: NSRange(location: 0, length: storage.length))
        for (range, color) in runs where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        storage.endEditing()
    }

    func scheduleHighlight() {
        highlightTask?.cancel()
        guard let language else { return }
        let code = text ?? ""
        let scheme = self.scheme ?? .light
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let runs = await Self.highlighter.foregroundColors(code: code, language: language, colorScheme: scheme),
                  let self, !Task.isCancelled, self.text == code, self.markedTextRange == nil
            else { return }
            self.apply(runs)
        }
    }

    override var undoManager: UndoManager? { controller?.editor.undoManager }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent)),
            UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(leaveBelow)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(leave)),
        ]
        if let caret = selectedTextRange?.start, markedTextRange == nil {
            let line = caretRect(for: caret)
            if line.minY <= caretRect(for: beginningOfDocument).minY + 1 {
                commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(leaveUp)))
            }
            if line.minY >= caretRect(for: endOfDocument).minY - 1 {
                commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(leaveDown)))
            }
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func leave() {
        resignFirstResponder()
        controller?.endEditing()
        if let block { controller?.editor.blocks.selectAfterEditing(block) }
    }
    @objc private func leaveUp() { if let block { controller?.leave(block, .up) } }
    @objc private func leaveDown() { if let block { controller?.leave(block, .down) } }
    @objc private func leaveBelow() { if let block { controller?.leave(block, .below) } }

    /// The current line: its range in the text and its leading spaces.
    private func currentLine() -> (range: NSRange, indent: String) {
        let text = self.text as NSString
        let range = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let line = text.substring(with: range)
        return (range, String(line.prefix { $0 == " " || $0 == "\t" }))
    }

    @objc func outdent() {
        let (range, indent) = currentLine()
        let count = min(4, indent.count)
        guard count > 0, let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: count), let span = textRange(from: start, to: end)
        else { return }
        let caret = selectedRange
        replace(span, withText: "")
        selectedRange = NSRange(location: max(range.location, caret.location - count), length: 0)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard controller?.isEditable == true else { return false }
        guard markedTextRange == nil, let block else { return true }
        if text == "\n" {
            // The new line starts where this one does.
            insertText("\n" + currentLine().indent)
            return false
        }
        if text == "\t" {
            insertText("    ")
            return false
        }
        if text.isEmpty, range.length == 0, self.text.isEmpty {
            controller?.becomeParagraph(block)
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard markedTextRange == nil, let block else { return }
        typedCaret = selectedRange
        controller?.changed(block, to: text)
        scheduleHighlight()
        if code != nil { followCaret() }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard markedTextRange == nil, selectedRange != typedCaret else { return }
        // Typing moves the caret before the change is reported: one character on.
        if let typed = typedCaret, selectedRange.length == 0, abs(selectedRange.location - typed.location) <= 1, isFirstResponder, typingNow { return }
        controller?.caretMoved()
        // The caret's line is lit, and kept in view.
        if code != nil { followCaret() }
    }

    /// Set while UIKit applies a keystroke (between shouldChange and didChange).
    private var typingNow = false

    override func insertText(_ text: String) {
        typingNow = true
        super.insertText(text)
        typingNow = false
        typedCaret = selectedRange
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if let block { controller?.began(block) }
        if code != nil { setNeedsLayout() }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if let block { controller?.ended(block) }
        if code != nil { setNeedsLayout() }
    }

    #if targetEnvironment(macCatalyst)
    /// Right-click in code: its menu (the language, Copy Code) above the text's.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let block, let rows = controller?.codeMenu(block), !rows.isEmpty else { return nil }
        return UIMenu(children: rows.systemElements() + suggestedActions)
    }
    #endif
}

/// A source's text view. Without a block and controller it only shows the code (a code
/// block the agent is writing).
struct DocSourceField: UIViewRepresentable {
    var block: DocBlockID?
    let text: String
    var controller: DocSourceController?
    let font: UIFont
    var insets = UIEdgeInsets(top: 5, left: 10, bottom: 10, right: 10)
    /// Highlights the code in this language (nil: plain text).
    var language: String?
    /// A code block's lines (DocCodeBox), the insets theirs.
    var code: DocCodeMetrics?

    func makeUIView(context: Context) -> DocSourceTextView {
        DocSourceTextView.make(code: code != nil)
    }

    func updateUIView(_ view: DocSourceTextView, context: Context) {
        let colors = context.environment.markdownColors
        view.configure(block: block, text: text, controller: controller, font: font, insets: insets, language: language, code: code,
                       ink: colors.map { UIColor($0.primary) }, ground: colors?.background.map { UIColor($0) },
                       scheme: context.environment.colorScheme)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DocSourceTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        return CGSize(width: width, height: uiView.fittingHeight(width: width))
    }
}

extension DocSourceTextView {
    /// A source's text view; `code`: a code block's, its lines running on and scrolling sideways.
    static func make(code: Bool) -> DocSourceTextView {
        // TextKit 1: a code block's lines are as tall as its layout manager makes them.
        let view = DocSourceTextView(usingTextLayoutManager: false)
        view.delegate = view
        view.isScrollEnabled = false
        if code {
            // Code lines run on: the text scrolls sideways (its own scrolling, which
            // keeps the caret in view), never up or down.
            view.isScrollEnabled = true
            view.runsLinesOn()
            view.alwaysBounceVertical = false
            view.showsVerticalScrollIndicator = false
            view.contentInsetAdjustmentBehavior = .never
        }
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    /// Shows `text` of `block` in `font`, coloured for `language` in `scheme`; `ink`: its
    /// text's colour where no token colours it (nil: the page's), `ground`: what the Markdown
    /// it's in is drawn on, when it has colours of its own.
    func configure(block: DocBlockID?, text: String, controller: DocSourceController?, font: UIFont, insets: UIEdgeInsets,
                   language: String?, code: DocCodeMetrics?, ink: UIColor? = nil, ground: UIColor? = nil, scheme: ColorScheme) {
        self.block = block
        self.controller = controller
        isEditable = controller?.isEditable ?? false
        sourceFont = font
        textContainerInset = code?.insets ?? insets
        self.code = code
        if code != nil { runsLinesOn() }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink ?? DocTokens.UIKitColor.primary]
        if let code {
            let style = NSMutableParagraphStyle()
            // Every line the pitch from the next: TextKit adds the spacing after a
            // paragraph's last line too.
            style.lineSpacing = code.gap * 2
            attributes[.paragraphStyle] = style
        }
        let recolors = self.scheme != scheme || !(self.ink?.isEqual(ink) ?? false)
            || self.ground.map { !$0.isEqual(ground) } ?? (ground != nil)
        self.scheme = scheme
        self.ink = ink
        self.ground = ground
        // Typed text takes the colour of the token it's typed into until the next
        // highlight, not plain.
        var typing = attributes
        if language != nil, let color = typingAttributes[.foregroundColor] { typing[.foregroundColor] = color }
        typingAttributes = typing
        let languageChanged = self.language != language
        self.language = language
        baseAttributes = attributes
        if (self.text != text || attributedText.length == 0) && markedTextRange == nil {
            show(text)
        } else if languageChanged {
            highlightNow()
        } else if recolors {
            recolor()
        }
        if let block, let controller { controller.register(self, for: block) }
    }

    /// Its height at `width`: a code block's to its last line's text, else the text's.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let insets = textContainerInset
        let font = sourceFont ?? docCodeFont
        var height: CGFloat
        if let code {
            // To the last line's text, not past the spacing after it: the bottom inset
            // has the space below it. Its lines run on (the text view's own measuring
            // would wrap them at the width).
            runsLinesOn()
            layoutManager.ensureLayout(for: textContainer)
            let glyphs = layoutManager.numberOfGlyphs
            let last = !layoutManager.extraLineFragmentUsedRect.isEmpty || glyphs == 0 ? layoutManager.extraLineFragmentUsedRect
                : layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs - 1, effectiveRange: nil)
            height = insets.top + last.minY + code.lineHeight + insets.bottom
        } else {
            height = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        return max(ceil(height), ceil(font.lineHeight + insets.top + insets.bottom))
    }
}

/// The document's code font: Craft's, monospaced at 0.86 of the body text.
let docCodeFont = UIFont.monospacedSystemFont(ofSize: (UIFont.preferredFont(forTextStyle: .body).pointSize * 0.86).rounded(),
                                              weight: .regular)

/// Craft's code block, measured on its Mac app (code at 13 points), scaled with the font.
struct DocCodeMetrics: Equatable {
    let font: UIFont

    private var scale: CGFloat { font.pointSize / 13 }
    /// A line's height as TextKit lays it out (the gutter's numbers keep to its lines):
    /// measured once for a font, on a line of its own.
    var lineHeight: CGFloat {
        if let height = Self.lineHeights[font.pointSize] { return height }
        let storage = NSTextStorage(string: "0", attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1000, height: 1000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let height = manager.usedRect(for: container).height
        Self.lineHeights[font.pointSize] = height
        return height
    }
    /// Only ever used on the main thread (the views').
    nonisolated(unsafe) private static var lineHeights: [CGFloat: CGFloat] = [:]
    /// From one line's text to the next's: 20 points.
    var pitch: CGFloat { (20 * scale).rounded() }
    /// Above and below a line's text: the pitch's room past it, halved.
    var gap: CGFloat { (pitch - lineHeight) / 2 }
    /// From the border to the first line's space, and from the last number's to the border.
    var edge: CGFloat { (9 * scale).rounded() }
    /// From the numbers' right to the gutter's line, and from the line to the code.
    var numberTrailing: CGFloat { 10.5 * scale }
    var codeLeading: CGFloat { 14 * scale }

    static let radius: CGFloat = 6
    static let border: CGFloat = 1
    static let separator: CGFloat = 0.5
    /// The ring while it's edited: this far out from the box.
    static let ringOffset: CGFloat = 2
    /// The label colour's opacities, measured on Craft's dark page: the box, the gutter
    /// over it, the border and the gutter's line, the caret's line, the ring.
    static let fillOpacity = 0.014
    static let gutterOpacity = 0.014
    static let lineOpacity = 0.09
    static let litOpacity = 0.045
    static let ringOpacity = 0.37

    /// The gutter: two digits' room (Craft's 36 points, a single digit on its right),
    /// wider only from a hundred lines.
    func gutterWidth(lines: Int) -> CGFloat {
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        return (9.5 * scale + CGFloat(max(2, String(lines).count)) * digit + numberTrailing).rounded()
    }

    /// The text's insets beside the gutter, inside the border.
    var insets: UIEdgeInsets {
        UIEdgeInsets(top: edge + gap, left: codeLeading, bottom: gap + edge, right: codeLeading)
    }
}

/// What a code block's text view draws behind its text while it's edited: the caret's
/// line lit, across the whole width the text scrolls through.
final class DocCodeBackdrop: UIView {
    var lit: Range<CGFloat>? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.setNeedsDisplay() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let lit else { return }
        DocTokens.UIKitColor.primary.resolvedColor(with: traitCollection).withAlphaComponent(DocCodeMetrics.litOpacity).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: lit.lowerBound, width: bounds.width, height: lit.upperBound - lit.lowerBound)).fill()
    }
}

/// A code block's gutter: its lines' numbers, right-aligned on
/// the lines' pitch, on a fill a little lighter than the box's. It stays where it is
/// while the code scrolls sideways.
struct DocCodeGutter: View {
    let lines: Int
    let code: DocCodeMetrics
    @Environment(\.markdownColors) private var colors

    var body: some View {
        let corner = DocCodeMetrics.radius - DocCodeMetrics.border
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(1...max(1, lines), id: \.self) { number in
                Text(verbatim: "\(number)")
                    .font(Font(code.font))
                    .foregroundStyle(colors?.tertiary ?? DocTokens.ColorRole.Content.tertiary)
                    .frame(height: code.pitch)
            }
        }
        .padding(.top, code.edge)
        .padding(.trailing, code.numberTrailing)
        .frame(width: code.gutterWidth(lines: lines), alignment: .trailing)
        .frame(maxHeight: .infinity, alignment: .top)
        .background((colors?.primary ?? .primary).opacity(DocCodeMetrics.gutterOpacity),
                    in: UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A code block as Craft draws it, read and edited alike: the gutter, its line, and the
/// code's text view (scrolling sideways, its caret's line lit) in a box with a thin
/// border; while it's edited, a faint ring around the box.
struct DocCodeBox: View {
    var block: DocBlockID?
    let text: String
    let language: String?
    var controller: DocSourceController?
    var isEditing = false
    /// In Markdown drawn in its own colours (a chat bubble's), the box is in them.
    @Environment(\.markdownColors) private var colors

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DocCodeMetrics.radius, style: .continuous)
        let code = DocCodeMetrics(font: docCodeFont)
        let ink = colors?.primary ?? .primary
        HStack(spacing: 0) {
            DocCodeGutter(lines: text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }, code: code)
            Rectangle()
                .fill(ink.opacity(DocCodeMetrics.lineOpacity))
                .frame(width: DocCodeMetrics.separator)
            DocSourceField(block: block, text: text, controller: controller, font: docCodeFont, language: language, code: code)
        }
        .padding(DocCodeMetrics.border)
        .background(shape.fill(ink.opacity(DocCodeMetrics.fillOpacity)))
        .overlay {
            shape.strokeBorder(ink.opacity(DocCodeMetrics.lineOpacity), lineWidth: DocCodeMetrics.border)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DocCodeMetrics.radius + DocCodeMetrics.ringOffset, style: .continuous)
                .strokeBorder(DocTokens.ColorRole.Accent.primary.opacity(DocCodeMetrics.ringOpacity), lineWidth: DocCodeMetrics.border)
                .padding(-DocCodeMetrics.ringOffset)
                .opacity(isEditing ? 1 : 0)
                .animation(DocTokens.Motion.reveal, value: isEditing)
                .allowsHitTesting(false)
        }
    }
}

/// The code blocks MarkdownView draws in the document (the agent writing them): Craft's box.
struct DocCodeBlockStyle: CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        // The fence's code ends in the newline before its closing fence: not a line of its own.
        let code = configuration.code.hasSuffix("\n") ? String(configuration.code.dropLast()) : configuration.code
        DocCodeBox(text: code, language: configuration.language)
    }
}

/// A selection rect ending at the bottom of its last line's text (TextKit's covers the
/// paragraph spacing below it too).
final class DocLineSelectionRect: UITextSelectionRect {
    private let base: UITextSelectionRect
    private let bottom: CGFloat

    init(_ base: UITextSelectionRect, bottom: CGFloat) {
        self.base = base
        self.bottom = bottom
    }

    override var rect: CGRect {
        var rect = base.rect
        rect.size.height = max(0, bottom - rect.minY)
        return rect
    }
    override var writingDirection: NSWritingDirection { base.writingDirection }
    override var containsStart: Bool { base.containsStart }
    override var containsEnd: Bool { base.containsEnd }
    override var isVertical: Bool { base.isVertical }
}

/// Reports the row's new height to TiledView: entering or leaving an editor changes
/// it without the row's item changing. On the whole row (its padding included).
struct DocRowHeightReporter: ViewModifier {
    var isOn = true
    @Environment(\.updateSelfSizing) private var updateSelfSizing

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOn { reporting(content) } else { content }
    }

    private func reporting(_ content: Content) -> some View {
        // Its own height, not the cell's (which is what changes late), passed on: the cell
        // otherwise keeps the height SwiftUI last reported for it.
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                updateSelfSizing(measuredHeight: height)
            }
    }
}

/// The phone's math panel: glass on the keyboard bar while a math block is edited, the
/// page scrolled to show the block above it.
struct DocMathKeyboardPanel: View {
    let controller: DocSourceController
    let demo: DocDemo

    var body: some View {
        let block = controller.editing.flatMap { demo.doc.block($0) }.flatMap { $0.kind == .math ? $0.id : nil }
        ZStack(alignment: .bottom) {
            if let block {
                DocMathPanel(block: block, text: controller.text(block), controller: controller)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [controller] height in
                        controller.revealMath(block, over: height)
                    }
                    .transition(.opacity.combined(with: .scale(scale: DocTokens.Motion.revealStartScale, anchor: .bottom)))
                    .onDisappear { DocScrolling.keyboardPanel = 0 }
            }
        }
        .padding(.bottom, controller.keyboardBarHeight)
        .animation(DocTokens.Motion.reveal, value: block)
    }
}

/// The panel's content: the LaTeX, and the keys under it. In the anchored panel's
/// surface beside the block (the Mac), on glass over the keyboard (a phone).
struct DocMathPanel: View {
    let block: DocBlockID
    let text: String
    let controller: DocSourceController

    private typealias Tokens = DocTokens

    /// As wide as a formula line wants, within the window.
    private var width: CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.width ?? 480
        return min(460, window - 48)
    }

    var body: some View {
        if DocDevice.isMac {
            DocPanelSurface { content }
                .docPanelWidth(width)
        } else {
            content
                .padding(Tokens.Space.sm)
                .flooGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.xxl, style: .continuous))
                .padding(.horizontal, Tokens.Space.md)
                .padding(.bottom, Tokens.Space.sm)
        }
    }

    /// The LaTeX's font: the body text's size, monospaced.
    private static let latexFont = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)

    private var content: some View {
        VStack(spacing: Tokens.Space.sm) {
            DocSourceField(block: block, text: text, controller: controller, font: Self.latexFont,
                           insets: UIEdgeInsets(top: Tokens.Space.sm, left: Tokens.Space.sm, bottom: Tokens.Space.sm, right: Tokens.Space.sm))
                .background(Tokens.ColorRole.Surface.control, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            // Keys sharing the row's width: a titled button's least width and padding would run
            // past the panel with this many.
            HStack(spacing: Tokens.Space.sm) {
                ForEach(DocMathKey.keys) { key in
                    Button { controller.insert(key.snippet, caret: key.caret, in: block) } label: {
                        keyLabel(Text(verbatim: key.title).lineLimit(1).minimumScaleFactor(0.7))
                    }
                    .buttonStyle(keyStyle)
                    .accessibilityLabel(key.name)
                }
                Menu {
                    ForEach(DocMathKey.symbols, id: \.self) { section in
                        Section {
                            ForEach(section) { key in
                                Button("\(key.title)   \(key.snippet)") { controller.insert(key.snippet, in: block) }
                            }
                        }
                    }
                } label: {
                    keyLabel(Image(systemName: "ellipsis"))
                }
                .menuStyle(.button)
                .buttonStyle(keyStyle)
                .accessibilityLabel("More Symbols")
            }
        }
    }

    private static let keyMetrics = FlooButtonMetrics.of(.medium)

    private var keyStyle: FlooContentButtonStyle<RoundedRectangle> {
        .flooContent(in: RoundedRectangle(cornerRadius: Self.keyMetrics.cornerRadius, style: .continuous), surface: .control)
    }

    private func keyLabel(_ content: some View) -> some View {
        content
            .font(.system(size: Self.keyMetrics.fontSize, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: Self.keyMetrics.height)
    }
}

/// A key of the math panel: what it shows, and the LaTeX it puts in (the caret `caret`
/// units into it, in its first braces).
struct DocMathKey: Identifiable, Hashable {
    let title: String
    let name: String
    let snippet: String
    var caret: Int?

    var id: String { snippet }

    /// What's long to type: a fraction, a root, a power, an index, a sum, an integral.
    static let keys = [
        DocMathKey(title: "a⁄b", name: "Fraction", snippet: "\\frac{}{}", caret: 6),
        DocMathKey(title: "√x", name: "Square Root", snippet: "\\sqrt{}", caret: 6),
        DocMathKey(title: "xⁿ", name: "Power", snippet: "^{}", caret: 2),
        DocMathKey(title: "xₙ", name: "Index", snippet: "_{}", caret: 2),
        DocMathKey(title: "∑", name: "Sum", snippet: "\\sum_{}^{}", caret: 6),
        DocMathKey(title: "∫", name: "Integral", snippet: "\\int_{}^{}", caret: 6),
    ]

    /// The symbols in the menu: Greek letters, then relations and operators.
    static let symbols: [[DocMathKey]] = [
        [("α", "alpha"), ("β", "beta"), ("γ", "gamma"), ("δ", "delta"), ("θ", "theta"), ("λ", "lambda"),
         ("μ", "mu"), ("π", "pi"), ("σ", "sigma"), ("φ", "phi"), ("ω", "omega")],
        [("≤", "leq"), ("≥", "geq"), ("≠", "neq"), ("≈", "approx"), ("±", "pm"), ("×", "times"),
         ("·", "cdot"), ("∞", "infty"), ("∂", "partial"), ("→", "to")],
    ].map { $0.map { DocMathKey(title: $0.0, name: $0.1, snippet: "\\" + $0.1) } }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
