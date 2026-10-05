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

    /// The focus went elsewhere in the document.
    func endEditing() {
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
    /// Each line this tall, its text in the middle (MarkdownView's code lines: the
    /// font's line and 5 above and below).
    var lineHeight: CGFloat?

    private var attributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        if let lineHeight {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            attributes[.paragraphStyle] = style
            attributes[.baselineOffset] = (lineHeight - font.lineHeight) / 2
        }
        return attributes
    }

    func makeUIView(context: Context) -> DocSourceTextView {
        let view = DocSourceTextView()
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
        view.typingAttributes = attributes
        if (view.text != text || view.attributedText.length == 0) && view.markedTextRange == nil {
            let caret = view.selectedRange
            view.attributedText = NSAttributedString(string: text, attributes: attributes)
            if view.isFirstResponder { view.selectedRange = NSRange(location: min(caret.location, text.utf16.count), length: 0) }
        }
        controller.register(view, for: block)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DocSourceTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(ceil(height), ceil((lineHeight ?? font.lineHeight) + insets.top + insets.bottom)))
    }
}

/// MarkdownView's code block font: caption, monospaced.
private let codeFont = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)

/// A code block: MarkdownView's, its lines replaced by the editor while it's edited.
struct DocCodeRowView: View {
    let block: DocBlockID
    let language: String?
    let blocks: [MarkdownStreamBlock]
    let controller: DocSourceController

    var body: some View {
        let editing = controller.editing == block
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, rendered in
            MarkdownStreamBlockView(rendered)
                .markdownCodeBlockReplacement { [block, controller] in
                    guard controller.editing == block else { return nil }
                    return AnyView(DocCodeEditor(block: block, text: controller.text(block), controller: controller))
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
}

/// The code lines as an editor: MarkdownView's line height, padding and stripes.
struct DocCodeEditor: View {
    let block: DocBlockID
    let text: String
    let controller: DocSourceController

    /// A code line as MarkdownView lays it out: the line's text and 5 above and below
    /// come to its 28-point row (SwiftUI's line of the caption font is taller than
    /// UIKit's).
    private var lineHeight: CGFloat { 28 }

    var body: some View {
        DocSourceField(block: block, text: text, controller: controller, font: codeFont,
                       insets: UIEdgeInsets(top: 0, left: 10, bottom: 10, right: 10), lineHeight: lineHeight)
            .background(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count), id: \.self) { index in
                        Rectangle()
                            .foregroundStyle(.tertiary.opacity(index % 2 != 0 ? 0.1 : 0))
                            .frame(height: lineHeight)
                    }
                }
                .allowsHitTesting(false)
            }
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
    let block: DocBlockID
    let language: String?
    let controller: DocSourceController

    var body: some View {
        Menu {
            Button("无") { controller.setLanguage(nil, of: block) }
            ForEach(DocSourceController.languages, id: \.self) { name in
                Button(name) { controller.setLanguage(name, of: block) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(language ?? "语言")
                Image(systemName: "chevron.up.chevron.down")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.top, 6)
        .padding(.trailing, 64)
    }
}

/// A math block: its LaTeX in an editor while it's edited, the rendered formula (which
/// follows the typing) below.
struct DocMathRowView: View {
    let block: DocBlockID
    let blocks: [MarkdownStreamBlock]
    let isEmpty: Bool
    let controller: DocSourceController

    var body: some View {
        let editing = controller.editing == block
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                VStack(alignment: .leading, spacing: 0) {
                    Text("LaTeX")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                    DocSourceField(block: block, text: controller.text(block), controller: controller, font: codeFont)
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
            }
            if isEmpty {
                Text(editing ? "公式预览" : "空公式，点按输入 LaTeX")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, rendered in
                    MarkdownStreamBlockView(rendered)
                        .markdownDisplayMathRendersSynchronously()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { [block, controller] in
            if controller.editing != block { controller.focus(block) }
        })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
