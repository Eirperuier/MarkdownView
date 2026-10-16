//
//  DocTableFormula.swift
//  DemoApp
//
//  A cell's formula written on a phone, Craft's way. Insert Formula (the cell's f(x) key
//  on the keyboard bar, its menu's), or a tap on a formula's cell, takes the table off
//  the page onto one of its own: it flies from its place to the top, the columns'
//  letters over it and the rows' numbers beside it (what a reference names), the cell
//  ringed and reading "Edit Formula". Above the keyboard, the formula in a field after
//  its "=" and a row of keys: the usual functions while it's empty (the rest in the
//  system's menu), the operators once it isn't. A tap on a cell puts its reference at
//  the caret, or in place of the reference just before the caret (a tap on another cell
//  moves it there); each reference has a colour, the text's and its cells' ring. Done
//  writes the formula into the cell, one undo step, and the table flies back; the cell,
//  still ringed, shows what it computes.
//
//  The Mac writes a formula in the cell as its text, what it computes under it.
//

import SwiftUI
import UIKit
import DocKit
import FlooDesign
import MarkdownView

/// A formula being written: its cell, its text (without its "=") and the caret.
@MainActor
@Observable
final class DocFormulaEditing: Identifiable {
    let key: DocCellKey
    /// The cell in its table (row 0 the header): where it's ringed, and what a reference to
    /// it would be (none: it can't name itself).
    let cell: MarkdownTableCellPosition
    private(set) var text: String
    /// In UTF-16 units, as the field counts.
    @ObservationIgnored private(set) var selection: NSRange
    @ObservationIgnored weak var field: DocFormulaTextField?
    /// What's the formula's page's own is in: its keys, the letters and numbers, the
    /// rings. They come once the table has landed, and go as it flies back.
    var isShown = false

    init(key: DocCellKey, cell: MarkdownTableCellPosition, text: String) {
        self.key = key
        self.cell = cell
        self.text = text
        selection = NSRange(location: text.utf16.count, length: 0)
    }

    var references: [DatabaseFormula.Reference] { DatabaseFormula.references(in: text) }

    /// The functions on the keys (Craft's), and those in the menu after them.
    static let functions = ["SUM", "MIN", "MAX", "AVG", "CNT"]
    static let moreFunctions = ["COUNTA", "MEDIAN", "MODE", "PRODUCT", "ROUND", "ABS", "INT", "SIGN"]
    static let operators = ["+", "-", "*", "/", "(", ")", ":"]

    /// A reference's colour, by its place among them.
    static func color(_ index: Int) -> Color {
        let tokens = ["purple", "green", "blue", "orange", "red", "cyan", "brown"]
        return MarkdownColorToken.text(tokens[index % tokens.count]) ?? FlooDesignTokens.ColorRole.Content.secondary
    }

    /// The field's typing.
    func typed(_ text: String, selection: NSRange) {
        if self.text != text { self.text = text }
        self.selection = selection
    }

    /// A function's key: its name and parentheses, the caret between them.
    func insert(function name: String) {
        replace(selection, with: name + "()", caret: name.utf16.count + 1)
    }

    /// An operator's key.
    func insert(_ string: String) {
        replace(selection, with: string)
    }

    /// A tap on a cell: its reference at the caret, or in place of the reference that ends
    /// there.
    func point(at position: MarkdownTableCellPosition) {
        guard position != cell else { return }
        var range = selection
        if range.length == 0, let last = references.last(where: { $0.range.upperBound == range.location }) {
            range = NSRange(location: last.range.lowerBound, length: last.range.count)
        }
        replace(range, with: DatabaseFormula.reference(row: position.row, column: position.column))
    }

    private func replace(_ range: NSRange, with string: String, caret: Int? = nil) {
        let length = text.utf16.count
        let location = min(range.location, length)
        let range = NSRange(location: location, length: min(range.length, length - location))
        text = (text as NSString).replacingCharacters(in: range, with: string)
        selection = NSRange(location: range.location + (caret ?? string.utf16.count), length: 0)
        field?.show(text, selection: selection)
    }
}

extension DocTableController {
    /// Insert Formula on a phone: the cell's formula written on the table's own page.
    func editFormula(_ key: DocCellKey) {
        guard let row = key.row, let (_, database) = database(key.block),
              let r = database.rows.firstIndex(where: { $0.id == row }), let c = database.columns.firstIndex(where: { $0.id == key.column })
        else { return }
        let current = text(key)
        let editing = DocFormulaEditing(key: key, cell: MarkdownTableCellPosition(row: r + 1, column: c),
                                        text: DatabaseFormula.isFormula(current) ? String(current.dropFirst()) : "")
        willEdit(key)
        // The cell's menu (a sheet) goes first: one thing presented at a time.
        let waits = menu != nil
        closeMenu()
        Task { @MainActor [weak self] in
            if waits { try? await Task.sleep(for: .milliseconds(450)) }
            guard let self, self.editing == key else { return }
            // Shown at once: the table's flight is the formula page's own (DocFormulaView).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.formula = editing }
        }
    }

    /// Done: the formula written into its cell (an empty one clears a formula there, and
    /// leaves other text as it was), one undo step.
    func writeFormula() {
        guard let formula else { return }
        let written = formula.text.trimmingCharacters(in: .whitespaces)
        let current = text(formula.key)
        let text = written.isEmpty ? (DatabaseFormula.isFormula(current) ? "" : current) : "=" + written
        bumpSession()
        changed(formula.key, to: text)
        bumpSession()
    }

    /// The formula's page is gone (the table back on the page).
    func closeFormula() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { formula = nil }
    }
}

// MARK: The formula's page

/// The table on a page of its own, the formula's field and keys above the keyboard.
struct DocFormulaView: View {
    let formula: DocFormulaEditing
    let controller: DocTableController
    /// The page's colour over the document: it comes as the table leaves the page, and
    /// goes once it's back there (the page's table under it, where it landed).
    @State private var covers = false
    /// Where the cell is here and was on the page (the window's space): the table flies
    /// between them.
    @State private var landing: CGRect?
    @State private var flight: CGSize = .zero

    private typealias Tokens = FlooDesignTokens

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(String(localized: "Done"), action: done)
                    .buttonStyle(FlooDesignButtonStyle(.primary))
            }
            .padding(.horizontal, Tokens.Space.lg)
            .padding(.vertical, Tokens.Space.sm)
            .opacity(formula.isShown ? 1 : 0)
            ScrollView(.vertical) {
                table
                    .padding(.leading, Tokens.Space.lg + DocFormulaDecoration.gutterWidth + DocFormulaDecoration.gap + MarkdownTableAppearance.rowOutset.leading)
                    .padding(.trailing, Tokens.Space.lg)
                    .padding(.top, Tokens.Space.lg + DocFormulaDecoration.gutterHeight + DocFormulaDecoration.gap)
                    .padding(.bottom, Tokens.Space.lg)
                    .offset(flight)
                    .opacity(landing == nil ? 0 : 1)
            }
            .scrollDismissesKeyboard(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.ColorRole.Surface.canvas.opacity(covers ? 1 : 0).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            DocFormulaPanel(formula: formula, done: done)
                .opacity(formula.isShown ? 1 : 0)
                .scaleEffect(formula.isShown ? 1 : Tokens.Motion.revealStartScale, anchor: .bottom)
        }
        .presentationBackground(.clear)
    }

    @ViewBuilder
    private var table: some View {
        if let row = controller.demo.rows.first(where: { $0.table?.block == formula.key.block }), let table = row.table, let tree = row.tree {
            let cell = formula.cell
            MarkdownBlockView(tree: tree)
                .markdownDisplayMathRendersSynchronously()
                .markdownTableAppearance(controller.appearance(of: table))
                .markdownTableCellsSelectable()
                .markdownTableCellTap { [formula] position in formula.point(at: position) }
                .markdownTableCellReplacement([cell]) { [key = formula.key, controller] position in
                    position == cell ? AnyView(DocFormulaPlaceholder(look: controller.look(key))) : nil
                }
                .markdownTableDecoration { [formula] frames in
                    AnyView(DocFormulaDecoration(frames: frames, formula: formula, landed: landed))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(DocBlockType())
        }
    }

    /// The cell is laid out here: the table flies from the cell's place on the page.
    private func landed(_ frame: CGRect) {
        guard landing == nil else { return }
        landing = frame
        if let origin = controller.editedCellFrame {
            flight = CGSize(width: origin.minX - frame.minX, height: origin.minY - frame.minY)
        }
        withAnimation(Tokens.Motion.layout) { flight = .zero }
        withAnimation(Tokens.Motion.reveal) {
            covers = true
            formula.isShown = true
        }
    }

    /// The formula written, the table flies back to its place on the page.
    private func done() {
        controller.writeFormula()
        formula.field?.resignFirstResponder()
        // Where the cell is on the page after this render (the table's text has changed).
        Task { @MainActor in
            withAnimation(Tokens.Motion.dismiss) { formula.isShown = false }
            withAnimation(Tokens.Motion.layout) {
                if let landing, let origin = controller.editedCellFrame {
                    flight = CGSize(width: origin.minX - landing.minX, height: origin.minY - landing.minY)
                }
            } completion: {
                controller.closeFormula()
            }
        }
    }
}

/// The formula's cell while it's written: Craft's "Edit Formula".
private struct DocFormulaPlaceholder: View {
    let look: DocCellLook

    var body: some View {
        Text("Edit Formula")
            .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: look.frameAlignment)
    }
}

/// Over the table: the columns' letters and the rows' numbers, each reference's cells in
/// its colour, the formula's cell ringed.
struct DocFormulaDecoration: View {
    let frames: MarkdownTableCellFrames
    let formula: DocFormulaEditing
    let landed: (CGRect) -> Void

    static let gutterWidth: CGFloat = 24
    static let gutterHeight: CGFloat = 24
    static let gap: CGFloat = FlooDesignTokens.Space.xs

    private typealias Tokens = FlooDesignTokens

    var body: some View {
        let columns = Self.line(frames) { MarkdownTableCellPosition(row: 0, column: $0) }
        let rows = Self.line(frames) { MarkdownTableCellPosition(row: $0, column: 0) }
        ZStack(alignment: .topLeading) {
            if let first = columns.first, let last = columns.last {
                let strip = CGRect(x: first.minX, y: first.minY - Self.gap - Self.gutterHeight, width: last.maxX - first.minX, height: Self.gutterHeight)
                gutter(strip, cuts: columns.dropFirst().map { $0.minX - strip.minX }, vertical: true)
                ForEach(Array(columns.enumerated()), id: \.offset) { index, frame in
                    label(DatabaseFormula.columnName(index), in: CGRect(x: frame.minX, y: strip.minY, width: frame.width, height: strip.height))
                }
            }
            if let first = rows.first, let last = rows.last {
                let strip = CGRect(x: first.minX - Self.gap - Self.gutterWidth, y: first.minY, width: Self.gutterWidth, height: last.maxY - first.minY)
                gutter(strip, cuts: rows.dropFirst().map { $0.minY - strip.minY }, vertical: false)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, frame in
                    label(String(index + 1), in: CGRect(x: strip.minX, y: frame.minY, width: strip.width, height: frame.height))
                }
            }
            ForEach(Array(formula.references.enumerated()), id: \.offset) { index, reference in
                if let frame = frame(of: reference) {
                    let color = DocFormulaEditing.color(index)
                    let shape = RoundedRectangle(cornerRadius: MarkdownTableAppearance.cellCornerRadius, style: .continuous)
                    shape.fill(color.opacity(Tokens.Opacity.faint))
                        .overlay(shape.strokeBorder(color.opacity(Tokens.Opacity.strong), lineWidth: Tokens.Border.focus))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            if let frame = frames[formula.cell] {
                RoundedRectangle(cornerRadius: MarkdownTableAppearance.cellCornerRadius, style: .continuous)
                    .strokeBorder(Tokens.ColorRole.Accent.primary, lineWidth: Tokens.Border.focus)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(formula.isShown ? 1 : 0)
        .onGeometryChange(for: CGRect?.self) { [cell = formula.cell, frames] proxy in
            let origin = proxy.frame(in: .global).origin
            return frames[cell]?.offsetBy(dx: origin.x, dy: origin.y)
        } action: { frame in
            if let frame { landed(frame) }
        }
    }

    /// The first row's cells, or the first column's, in order.
    private static func line(_ frames: MarkdownTableCellFrames, _ position: (Int) -> MarkdownTableCellPosition) -> [CGRect] {
        var line: [CGRect] = []
        while let frame = frames[position(line.count)] { line.append(frame) }
        return line
    }

    /// The cells a reference names, together (those there are).
    private func frame(of reference: DatabaseFormula.Reference) -> CGRect? {
        var union: CGRect?
        for row in reference.rows {
            for column in reference.columns {
                guard let frame = frames[MarkdownTableCellPosition(row: row, column: column)] else { continue }
                union = union?.union(frame) ?? frame
            }
        }
        return union
    }

    /// A strip of letters or numbers: a rounded frame, lines between its parts.
    private func gutter(_ strip: CGRect, cuts: [CGFloat], vertical: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.xs, style: .continuous)
        return shape.fill(Tokens.ColorRole.Surface.canvas)
            .overlay {
                Path { path in
                    for cut in cuts {
                        path.move(to: vertical ? CGPoint(x: cut, y: 0) : CGPoint(x: 0, y: cut))
                        path.addLine(to: vertical ? CGPoint(x: cut, y: strip.height) : CGPoint(x: strip.width, y: cut))
                    }
                }
                .stroke(Tokens.Border.subtle, lineWidth: Tokens.Border.standard)
            }
            .overlay(shape.strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard))
            .frame(width: strip.width, height: strip.height)
            .offset(x: strip.minX, y: strip.minY)
    }

    private func label(_ text: String, in frame: CGRect) -> some View {
        Text(text)
            .font(Tokens.Typography.metadata.font)
            .foregroundStyle(Tokens.ColorRole.Content.secondary)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }
}

// MARK: The field and its keys

/// Above the keyboard: the formula after its "=", and the keys.
private struct DocFormulaPanel: View {
    let formula: DocFormulaEditing
    let done: () -> Void

    private typealias Tokens = FlooDesignTokens

    var body: some View {
        VStack(spacing: Tokens.Space.sm) {
            HStack(spacing: Tokens.Space.xs) {
                Text(verbatim: "=")
                    .font(.body)
                    .foregroundStyle(Tokens.ColorRole.Content.tertiary)
                DocFormulaField(formula: formula, done: done)
            }
            .padding(.horizontal, Tokens.Space.md)
            .frame(height: Tokens.Control.prominentHeight)
            .background(Tokens.ColorRole.Surface.control, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            HStack(spacing: Tokens.Space.sm) {
                if formula.text.isEmpty {
                    ForEach(DocFormulaEditing.functions, id: \.self) { name in
                        key(name) { formula.insert(function: name) }
                    }
                    Menu {
                        ForEach(DocFormulaEditing.moreFunctions, id: \.self) { name in
                            Button(name) { formula.insert(function: name) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.button)
                    .buttonStyle(FlooDesignButtonStyle(.secondary))
                    .accessibilityLabel("More Functions")
                } else {
                    ForEach(DocFormulaEditing.operators, id: \.self) { op in
                        key(op) { formula.insert(op) }
                    }
                }
            }
        }
        .padding(Tokens.Space.sm)
        .flooDesignGlass(.regular, in: RoundedRectangle(cornerRadius: Tokens.Radius.xxl, style: .continuous))
        .padding(.horizontal, Tokens.Space.md)
        .padding(.bottom, Tokens.Space.sm)
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(FlooDesignButtonStyle(.secondary))
    }
}

/// The formula's text: one line, its references in their colours; Return is Done.
private struct DocFormulaField: UIViewRepresentable {
    let formula: DocFormulaEditing
    let done: () -> Void

    func makeUIView(context: Context) -> DocFormulaTextField {
        let field = DocFormulaTextField()
        field.formula = formula
        field.done = done
        formula.field = field
        field.show(formula.text, selection: formula.selection)
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: DocFormulaTextField, context: Context) {
        field.done = done
    }
}

final class DocFormulaTextField: UITextField, UITextFieldDelegate {
    weak var formula: DocFormulaEditing?
    var done: (() -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        autocapitalizationType = .allCharacters
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .done
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addTarget(self, action: #selector(edited), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Its text being set: where the caret passes on the way isn't the person's.
    private var showing = false

    /// The model's text and caret (a key or a tap changed them).
    func show(_ text: String, selection: NSRange) {
        unmarkText()
        recolor(text, caret: selection)
    }

    @objc private func edited() {
        let text = text ?? ""
        formula?.typed(text, selection: selection)
        // Coloured once the input method has put its words in.
        guard markedTextRange == nil else { return }
        recolor(text, caret: selection)
    }

    private func recolor(_ text: String, caret: NSRange) {
        showing = true
        attributedText = colored(text)
        select(caret)
        showing = false
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        guard !showing else { return }
        formula?.typed(text ?? "", selection: selection)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        done?()
        return false
    }

    private var selection: NSRange {
        guard let range = selectedTextRange else { return NSRange(location: (text ?? "").utf16.count, length: 0) }
        return NSRange(location: offset(from: beginningOfDocument, to: range.start), length: offset(from: range.start, to: range.end))
    }

    private func select(_ range: NSRange) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length)
        else { return }
        selectedTextRange = textRange(from: start, to: end)
    }

    private func colored(_ text: String) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: [.font: font ?? .preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
        for (index, reference) in DatabaseFormula.references(in: text).enumerated() {
            string.addAttribute(.foregroundColor, value: UIColor(DocFormulaEditing.color(index)),
                                range: NSRange(location: reference.range.lowerBound, length: reference.range.count))
        }
        typingAttributes = [.font: font ?? .preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        return string
    }
}
