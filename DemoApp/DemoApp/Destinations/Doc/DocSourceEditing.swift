//
//  DocSourceEditing.swift
//  DemoApp
//
//  Code and math blocks are edited as their source. A code block keeps MarkdownView's
//  chrome (header, language, copy, background): its lines are replaced by an editor
//  (MarkdownView's code block replacement). A math block shows its LaTeX in an editor
//  above the rendered formula, which follows as you type. Read, both are MarkdownView's.
//
//  Keys: Return keeps the line's indentation, Tab / Shift-Tab indent and outdent the
//  line by four spaces, ↑ on the first line and ↓ on the last go to the block above and
//  below, ⌘Return leaves to the block below (a new paragraph at the end), Esc leaves,
//  Backspace in an empty block turns it into a paragraph. Typing is one undo step until
//  the caret moves elsewhere.
//

import SwiftUI
import UIKit
import DocKit
import MarkdownView
import MessagingUI
import FlooDesign

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
    @ObservationIgnored private var pendingFocus: (block: DocBlockID, offset: Int?)?
    @ObservationIgnored private var session: UInt64 = 0

    static let languages = ["swift", "python", "javascript", "typescript", "json", "bash", "sql", "go", "rust", "kotlin", "java", "c", "cpp", "html", "css", "yaml", "markdown"]

    init(demo: DocDemo, editor: DocEditor) {
        self.demo = demo
        self.editor = editor
    }

    var isEditable: Bool { editor.isEditable }

    func text(_ block: DocBlockID) -> String { demo.doc.block(block)?.text.string ?? "" }

    func register(_ view: DocSourceTextView, for block: DocBlockID) {
        views[block, default: []].removeAll { $0.view == nil || $0.view === view }
        views[block, default: []].append(WeakSourceView(view: view))
        if let pending = pendingFocus, pending.block == block { focusSoon(block, at: pending.offset) }
    }

    func view(for block: DocBlockID) -> DocSourceTextView? {
        views[block]?.compactMap(\.view).first { $0.window?.isKeyWindow == true }
    }

    /// Edits the block with the caret at `offset` (nil: where a click put it, or the end).
    func focus(_ block: DocBlockID, at offset: Int? = nil) {
        guard isEditable, demo.doc.block(block).flatMap({ DocSourceKind($0.kind) }) != nil else { return }
        if editing != block { session &+= 1 }
        editing = block
        editor.tables.endEditing()
        guard let view = view(for: block) else { return focusSoon(block, at: offset) }
        pendingFocus = nil
        if !view.isFirstResponder { view.becomeFirstResponder() }
        if let offset {
            view.selectedRange = NSRange(location: min(offset, view.text.utf16.count), length: 0)
        } else if !view.isFirstResponder {
            view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        }
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

    private func focusSoon(_ block: DocBlockID, at offset: Int?) {
        pendingFocus = (block, offset)
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                guard let self, let pending = self.pendingFocus, pending.block == block else { return }
                if self.view(for: block) != nil { return self.focus(block, at: offset) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func syncEditedText() {
        guard let editing, let view = view(for: editing) else { return }
        view.show(text(editing))
    }

    /// The panel's 完成, or a touch outside it: the source closes.
    func dismiss(_ block: DocBlockID) {
        view(for: block)?.resignFirstResponder()
        if editing == block { endEditing() }
    }

    /// The focus went elsewhere in the document.
    func endEditing() {
        // The read block draws from the highlight of the code as it is now: made here,
        // before it shows, if the last keystroke's hadn't come back yet.
        if let editing { view(for: editing)?.highlightNow() }
        pendingFocus = nil
        editing = nil
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
    /// The space above and below each code line; set, alternate lines are striped as in
    /// MarkdownView's code block, from where the lines actually are.
    var stripeGap: CGFloat? {
        didSet { if stripeGap != oldValue { setNeedsLayout() } }
    }
    private lazy var stripes: DocStripeView = {
        let view = DocStripeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        insertSubview(view, at: 0)
        return view
    }()

    /// The caret is a line of text tall: TextKit's own reaches over the paragraph
    /// spacing below the line, into the gap before the next one.
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        if stripeGap != nil, let font, rect.height > font.lineHeight + 1 {
            rect.size.height = ceil(font.lineHeight)
        }
        return rect
    }

    /// A selection is TextKit's, contiguous across lines (the spacing between them
    /// selected too), except that it stops at the bottom of its last line's text
    /// instead of running into the spacing below it.
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let rects = super.selectionRects(for: range)
        guard stripeGap != nil else { return rects }
        // The bottom of the last line's text: where the caret at the end reaches.
        let bottom = caretRect(for: range.end).maxY
        let lowest = rects.indices.filter { rects[$0].rect.width > 0 && rects[$0].rect.height > 0 }
            .max { rects[$0].rect.maxY < rects[$1].rect.maxY }
        return rects.enumerated().map { index, rect in
            index == lowest && rect.rect.maxY > bottom + 0.5 ? DocLineSelectionRect(rect, bottom: bottom) : rect
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let gap = stripeGap else { return }
        stripes.frame = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: max(contentSize.height, bounds.height)))
        sendSubviewToBack(stripes)
        var rects: [CGRect] = []
        let text = self.text as NSString
        let manager = layoutManager
        manager.ensureLayout(for: textContainer)
        var location = 0
        var index = 0
        while location <= text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            if index % 2 == 1 {
                let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: paragraph.location, length: max(0, paragraph.length - (text.substring(with: paragraph).hasSuffix("\n") ? 1 : 0))), actualCharacterRange: nil)
                let first = glyphs.length > 0 ? manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                    : (paragraph.location < text.length ? manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: paragraph.location), effectiveRange: nil) : manager.extraLineFragmentUsedRect)
                let last = glyphs.length > 0 ? manager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil) : first
                // A line's used rect carries the line spacing below it, but for the
                // text's very last line.
                let spacing = NSMaxRange(paragraph) < text.length ? ((baseAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing ?? 0) : 0
                rects.append(CGRect(x: 0, y: textContainerInset.top + first.minY - gap, width: bounds.width, height: last.maxY - spacing - first.minY + gap * 2))
            }
            index += 1
            if NSMaxRange(paragraph) >= text.length {
                // A final empty line after a line break is a line too.
                if text.length > 0, text.hasSuffix("\n"), index % 2 == 1 {
                    let extra = manager.extraLineFragmentUsedRect
                    rects.append(CGRect(x: 0, y: textContainerInset.top + extra.minY - gap, width: bounds.width, height: extra.height + gap * 2))
                }
                break
            }
            location = NSMaxRange(paragraph)
        }
        if stripes.rects != rects { stripes.rects = rects }
    }

    /// Shows `text` (coloured at once), the caret where it was or at the end.
    func show(_ text: String) {
        guard self.text != text || attributedText.length == 0, markedTextRange == nil else { return }
        let caret = selectedRange
        attributedText = NSAttributedString(string: text, attributes: baseAttributes)
        if isFirstResponder { selectedRange = NSRange(location: min(caret.location, text.utf16.count), length: 0) }
        highlightNow()
    }
    private var highlightTask: Task<Void, Never>?
    private static let highlighter = HighlightrCodeHighlighter()

    /// Colours the text at once (from the read block's highlight when it has one): the
    /// editor taking over a code block mustn't show a frame of plain text.
    func highlightNow() {
        highlightTask?.cancel()
        guard let language else { return }
        let scheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        guard let runs = Self.highlighter.foregroundColorsNow(code: text ?? "", language: language, colorScheme: scheme) else { return }
        apply(runs)
    }

    private func apply(_ runs: [(NSRange, UIColor)]) {
        let storage = textStorage
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: FlooDesignTokens.UIKitColor.primary, range: NSRange(location: 0, length: storage.length))
        for (range, color) in runs where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        storage.endEditing()
    }

    func scheduleHighlight() {
        highlightTask?.cancel()
        guard let language else { return }
        let code = text ?? ""
        let scheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
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
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard markedTextRange == nil, selectedRange != typedCaret else { return }
        // Typing moves the caret before the change is reported: one character on.
        if let typed = typedCaret, selectedRange.length == 0, abs(selectedRange.location - typed.location) <= 1, isFirstResponder, typingNow { return }
        controller?.caretMoved()
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
    }
}

struct DocSourceField: UIViewRepresentable {
    let block: DocBlockID
    let text: String
    let controller: DocSourceController
    let font: UIFont
    var insets = UIEdgeInsets(top: 5, left: 10, bottom: 10, right: 10)
    /// Highlights the code in this language (nil: plain text).
    var language: String?
    /// Code lines as MarkdownView lays them out: each line (a paragraph, wrapping inside
    /// it) with this much above and below, alternate lines striped behind. The space
    /// is the paragraph spacing between lines, and half of it the insets at the ends.
    var lineGap: CGFloat?

    private var attributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: FlooDesignTokens.UIKitColor.primary]
        if let lineGap {
            let style = NSMutableParagraphStyle()
            // Between the lines a long line wraps into, as MarkdownView spaces them.
            // TextKit adds it after a paragraph's last line too: the paragraph spacing
            // makes up the rest of the gap to the next code line.
            style.lineSpacing = markdownCodeWrappedLineSpacing
            style.paragraphSpacing = lineGap * 2 - markdownCodeWrappedLineSpacing
            // SwiftUI's Text wraps with the standard strategy (it pushes a word down
            // rather than leave one short word alone on a line): the same breaks.
            style.lineBreakStrategy = .standard
            attributes[.paragraphStyle] = style
        }
        return attributes
    }

    func makeUIView(context: Context) -> DocSourceTextView {
        // TextKit 1: the stripes are drawn from its line fragments.
        let view = DocSourceTextView(usingTextLayoutManager: false)
        view.delegate = view
        view.isScrollEnabled = false
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

    func updateUIView(_ view: DocSourceTextView, context: Context) {
        view.block = block
        view.controller = controller
        view.isEditable = controller.isEditable
        view.textContainerInset = insets
        view.stripeGap = lineGap
        // Typed text takes the colour of the token it's typed into until the next
        // highlight, not plain.
        var typing = attributes
        if language != nil, let color = view.typingAttributes[.foregroundColor] { typing[.foregroundColor] = color }
        view.typingAttributes = typing
        let languageChanged = view.language != language
        view.language = language
        view.baseAttributes = attributes
        if (view.text != text || view.attributedText.length == 0) && view.markedTextRange == nil {
            view.show(text)
        } else if languageChanged {
            view.highlightNow()
        }
        controller.register(view, for: block)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DocSourceTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        var height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if lineGap != nil {
            // To the last line's text, not past the spacing after it (a code block's last
            // line has only its own gap below, the bottom inset).
            let container = uiView.textContainer
            container.size = CGSize(width: width - insets.left - insets.right, height: .greatestFiniteMagnitude)
            uiView.layoutManager.ensureLayout(for: container)
            height = uiView.layoutManager.usedRect(for: container).maxY + insets.top + insets.bottom
        }
        return CGSize(width: width, height: max(ceil(height), ceil(font.lineHeight + insets.top + insets.bottom)))
    }
}

/// The document's code block font: the page's body size, monospaced (the rows set
/// MarkdownView's code block font to the same).
let docCodeFont = UIFont.monospacedSystemFont(ofSize: MarkdownTextScale.size(of: .body),
                                              weight: .regular)
private var codeFont: UIFont { docCodeFont }

/// A code block: MarkdownView's, its lines replaced by the editor while it's edited.
struct DocCodeRowView: View {
    let block: DocBlockID
    let language: String?
    let tree: MarkdownTree
    let controller: DocSourceController

    var body: some View {
        let editing = controller.editing == block
        MarkdownBlockView(tree: tree)
            .markdownCodeBlockReplacement { [block, controller] in
                guard controller.editing == block else { return nil }
                return AnyView(DocCodeEditor(block: block, text: controller.text(block), language: language, controller: controller))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if editing { DocCodeLanguageMenu(block: block, language: language, controller: controller) }
            }
            .simultaneousGesture(TapGesture().onEnded { [block, controller] in
                if controller.editing != block { controller.focus(block) }
            })
    }
}

/// The code lines as an editor, laid out as MarkdownView's: 10 across (and the 8 its
/// line's stack keeps before the spacer on the right, where the text wraps), 5 above
/// and below each line, stripes on alternate lines (drawn by the text view from its lines).
struct DocCodeEditor: View {
    let block: DocBlockID
    let text: String
    let language: String?
    let controller: DocSourceController

    var body: some View {
        DocSourceField(block: block, text: text, controller: controller, font: codeFont,
                       insets: UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 18), language: language, lineGap: 5)
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

/// Alternate code lines' stripes: MarkdownView's (tertiary at a tenth).
final class DocStripeView: UIView {
    var rects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        let tertiary = FlooDesignTokens.UIKitColor.tertiary.resolvedColor(with: traitCollection)
        var alpha: CGFloat = 0
        tertiary.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        tertiary.withAlphaComponent(alpha * 0.1).setFill()
        for stripe in rects where stripe.intersects(rect) { UIRectFill(stripe) }
    }
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

/// While a code block is edited, its language: a menu over the header's copy button's left.
struct DocCodeLanguageMenu: View {
    /// From the header's right edge to the left of its copy button (MarkdownView's).
    private static let copyButtonClearance: CGFloat = 84

    let block: DocBlockID
    let language: String?
    let controller: DocSourceController

    var body: some View {
        FlooDesignMenuButton(language ?? String(localized: "Language")) {
            Button("None") { controller.setLanguage(nil, of: block) }
            ForEach(DocSourceController.languages, id: \.self) { name in
                Button(name) { controller.setLanguage(name, of: block) }
            }
        }
        .padding(.top, FlooDesignTokens.Space.sm - 2)
        .padding(.trailing, Self.copyButtonClearance)
    }
}

/// A math block: MarkdownView's formula; while it's edited, its LaTeX in an anchored
/// panel under it (Matrix's Composer panel), the formula following the typing.
struct DocMathRowView: View {
    let block: DocBlockID
    let tree: MarkdownTree
    let isEmpty: Bool
    let controller: DocSourceController

    var body: some View {
        let editing = controller.editing == block
        Group {
            if isEmpty {
                Text("Empty formula. Enter LaTeX.")
                    .font(FlooDesignTokens.Typography.body.font)
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                    .frame(maxWidth: .infinity, minHeight: FlooDesignTokens.Control.standardHeight)
            } else {
                MarkdownBlockView(tree: tree)
                    .markdownDisplayMathRendersSynchronously()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background {
            // The formula being edited, marked where the panel comes from.
            if editing {
                RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.md, style: .continuous)
                    .fill(FlooDesignTokens.ColorRole.Surface.selected)
                    .padding(.horizontal, -(FlooDesignTokens.Space.sm - 2))
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { [block, controller] in
            if controller.editing != block { controller.focus(block) }
        })
        .flooDesignAnchoredPanel(isPresented: editing, onDismiss: { [block, controller] in controller.dismiss(block) }) {
            DocMathPanel(block: block, text: controller.text(block), controller: controller)
        }
    }
}

/// The panel's content: the LaTeX, and done.
struct DocMathPanel: View {
    let block: DocBlockID
    let text: String
    let controller: DocSourceController

    /// As wide as a formula line wants, within the window.
    private var width: CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.width ?? 480
        return min(460, window - 48)
    }

    var body: some View {
        FlooDesignFloatingPanelSurface {
            VStack(alignment: .leading, spacing: FlooDesignTokens.Space.sm) {
                HStack {
                    Text("LaTeX")
                        .font(FlooDesignTokens.Typography.sectionLabel.font)
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                    Spacer()
                    Button("Done") { controller.dismiss(block) }
                        .font(FlooDesignTokens.Typography.sectionLabel.font)
                        .foregroundStyle(FlooDesignTokens.ColorRole.Accent.primary)
                        .padding(.horizontal, FlooDesignTokens.Space.sm)
                        .padding(.vertical, FlooDesignTokens.Space.xxs)
                        .buttonStyle(FlooDesignPlainButtonStyle(in: Capsule()))
                }
                .padding(.horizontal, FlooDesignTokens.Space.sm)
                DocSourceField(block: block, text: text, controller: controller, font: codeFont,
                               insets: UIEdgeInsets(top: FlooDesignTokens.Space.sm, left: FlooDesignTokens.Space.sm,
                                                    bottom: FlooDesignTokens.Space.sm, right: FlooDesignTokens.Space.sm))
                    .background(FlooDesignTokens.ColorRole.Surface.control, in: RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.md, style: .continuous))
            }
            .flooDesignPanelWidth(width)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
