//
//  DocCollectionCellUIKit.swift
//  DemoApp
//
//  One field of one record, in UIKit: in the table, and in a record's fields (`compact`,
//  where a select picks from a menu, as the record's panel can't open another). What
//  DocCollectionCell drew:
//  - text, a number, a link, a person: the whole text in as many lines as the width makes
//    it, typed in place, outlined while it is; what the field doesn't take shows faint;
//    Return ends the editing;
//  - the title: a written page's mark before it, the arrow that opens the record at its end;
//  - a select or multi-select: its chips; a click opens its options (a menu when compact);
//  - a date: as it shows; a click opens its calendar; a checkbox: its box.
//

import DocKit
import FlooUIKit
import UIKit

private typealias Metrics = DocCollectionMetrics

@MainActor
final class DocCollectionCellView: UIView, UITextViewDelegate {
    struct Shown {
        let snapshot: DocCollectionSnapshot
        let row: Row
        let column: Column
        let controller: DocCollectionController
        var isTitle = false
        var rowHovered = false
        /// The field as a place (its menu; the keyboard bar's keys), in the table.
        var place: DocFieldPlace?
    }

    let compact: Bool
    private(set) var shown: Shown?
    private var kind: Kind?

    private enum Kind: Equatable { case options, checkbox, date, text }

    // Text
    private let text = DocFieldTextView()
    private let pageMark = DocPageSheetView()
    private lazy var openButton = docSymbolButton("arrow.right.circle", size: DocTokens.Icon.standard, weight: .regular,
                                                  side: Metrics.openButton, shape: .capsule, title: String(localized: "Open")) { [weak self] in
        guard let self, let shown = self.shown else { return }
        shown.controller.openRecord?(shown.row.id, shown.snapshot.block)
    }
    private let ring = UIView()
    // Options, a date, a box
    private let chips = UIView()
    private let chipsButton = FlooContentButton(content: UIView(), shape: .corner(0))
    private let date = UILabel()
    private let dateButton = FlooContentButton(content: UIView(), shape: .corner(0))
    private let box = UIImageView()
    private let boxButton = FlooContentButton(content: UIView(), shape: .corner(0))
    private var spot: FlooPanelAnchorView?
    private var spotKind: DocCollectionPanel.Kind?

    init(compact: Bool) {
        self.compact = compact
        super.init(frame: .zero)
        text.delegate = self
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = DocTokens.Radius.xs
        ring.layer.cornerCurve = .continuous
        ring.layer.borderWidth = Metrics.focusWidth
        ring.isHidden = true
        pageMark.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        chips.isUserInteractionEnabled = false
        date.font = .systemFont(ofSize: 14)
        date.textColor = .floo(.label)
        date.isUserInteractionEnabled = false
        box.contentMode = .center
        box.isUserInteractionEnabled = false
        chipsButton.addAction(UIAction { [weak self] _ in self?.openOptions() }, for: .primaryActionTriggered)
        dateButton.addAction(UIAction { [weak self] _ in self?.openDate() }, for: .primaryActionTriggered)
        boxButton.addAction(UIAction { [weak self] _ in self?.toggleBox() }, for: .primaryActionTriggered)
        [text, pageMark, openButton, chipsButton, chips, dateButton, date, boxButton, box, ring].forEach(addSubview)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateColors() {
        ring.layer.borderColor = UIColor.floo(.accent).resolvedColor(with: traitCollection).cgColor
    }

    private var block: DocBlockID? { shown?.snapshot.block }
    private var value: CellValue? { shown.flatMap { $0.row.cells[$0.column.id] } }

    private static func kind(of column: Column) -> Kind {
        switch column.type {
        case .select, .multiSelect: .options
        case .checkbox: .checkbox
        case .date: .date
        default: .text
        }
    }

    // MARK: Showing

    func show(_ new: Shown) {
        let sameCell = shown.map { $0.row.id == new.row.id && $0.column.id == new.column.id && $0.snapshot.block == new.snapshot.block } ?? false
        shown = new
        let kind = Self.kind(of: new.column)
        self.kind = kind
        let editable = new.controller.isEditable
        text.isHidden = kind != .text
        pageMark.isHidden = !(kind == .text && new.isTitle && !compact && new.controller.hasPage?(new.row.id) == true)
        openButton.isHidden = !(kind == .text && new.isTitle && !compact && (new.rowHovered || !DocTokens.Platform.isPointer))
        chipsButton.isHidden = kind != .options
        chips.isHidden = kind != .options
        dateButton.isHidden = kind != .date
        date.isHidden = kind != .date
        boxButton.isHidden = kind != .checkbox
        box.isHidden = kind != .checkbox
        [chipsButton, dateButton, boxButton].forEach { $0.isEnabled = editable }
        switch kind {
        case .text:
            text.isEditable = editable
            text.textAlignment = new.column.type == .number && !compact ? .right : .left
            // What's typed stays as typed while it reads as the cell's value ("1,5" is 1.5,
            // "example.com" is its https link); a change from elsewhere replaces it.
            let shownText = DocFieldText.text(value, in: new.column)
            if !text.isFirstResponder || !sameCell || DocFieldText.value(typed: text.text, in: new.column) != value {
                if text.text != shownText { text.text = shownText }
            }
            colorText()
            if new.isTitle, !compact, new.controller.editingTitle == new.row.id {
                new.controller.editingTitle = nil
                DispatchQueue.main.async { [weak self] in self?.text.becomeFirstResponder() }
            }
        case .options:
            showChips()
            if compact { chipsButton.docMenu { [weak self] in self?.optionsMenu() ?? [] } }
        case .date:
            date.text = DocFieldText.text(value, in: new.column)
        case .checkbox:
            let on = value == .checkbox(value: true)
            box.image = UIImage(systemName: on ? "checkmark.square.fill" : "square",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.standard))
            box.tintColor = on ? .floo(.label) : .floo(.disabledLabel)
        }
        followPanel()
        setNeedsLayout()
    }

    /// Its panel (options, a calendar) while the controller shows it.
    func followPanel() {
        guard let shown, let block, !compact else { return }
        let kind: DocCollectionPanel.Kind? = switch self.kind {
        case .options: .options(row: shown.row.id, column: shown.column.id)
        case .date: .date(row: shown.row.id, column: shown.column.id)
        default: nil
        }
        if spotKind != kind {
            spot?.close()
            spot?.removeFromSuperview()
            spot = nil
            spotKind = kind
            if let kind {
                spot = docPanelSpot(page: { [weak self] in self?.page(for: kind) ?? UIViewController() }, follow: { [weak self] page in
                    guard let self, let shown = self.shown else { return }
                    (page as? DocOptionsPage)?.update(row: shown.row, column: shown.column)
                }, onDismiss: { [weak self] in
                    guard let self, let shown = self.shown else { return }
                    shown.controller.close(kind, in: shown.snapshot.block)
                })
            }
        }
        if let spot, let kind { spot.show(shown.controller.isShowing(kind, in: block), over: self) }
    }

    private func page(for kind: DocCollectionPanel.Kind) -> UIViewController {
        guard let shown else { return UIViewController() }
        switch kind {
        case .options: return DocOptionsPage(row: shown.row, column: shown.column, block: shown.snapshot.block, controller: shown.controller)
        case .date: return DocDatePage(row: shown.row, column: shown.column, block: shown.snapshot.block, controller: shown.controller)
        default: return UIViewController()
        }
    }

    func reset() {
        spot?.close()
        if text.isFirstResponder { text.resignFirstResponder() }
    }

    // MARK: Options

    private var chosen: [SelectOption] {
        guard let shown else { return [] }
        let options = DocFieldText.options(shown.column)
        return switch value {
        case .select(let id)?: options.filter { $0.id == id }
        case .multiSelect(let ids)?: ids.compactMap { id in options.first { $0.id == id } }
        default: []
        }
    }

    private func showChips() {
        guard let shown else { return }
        let options = DocFieldText.options(shown.column)
        chips.subviews.forEach { $0.removeFromSuperview() }
        for option in chosen { chips.addSubview(DocChips.chip(option, in: options)) }
    }

    private func optionsMenu() -> [FlooMenuSection] {
        guard let shown else { return [] }
        let options = DocFieldText.options(shown.column)
        let isMulti = if case .multiSelect = shown.column.type { true } else { false }
        let chosen = chosen
        return [.init(options.map { option in
            .docOption(option.name, color: DocOptionColor.color(DocOptionColor.token(option, in: options)), isOn: chosen.contains(option), keepsOpen: isMulti) {
                shown.controller.toggle(option.id, row: shown.row.id, column: shown.column.id, in: shown.snapshot.block)
            }
        })]
    }

    private func openOptions() {
        guard let shown, !compact else { return }
        shown.controller.show(.options(row: shown.row.id, column: shown.column.id), in: shown.snapshot.block)
    }

    private func openDate() {
        guard let shown else { return }
        shown.controller.show(.date(row: shown.row.id, column: shown.column.id), in: shown.snapshot.block)
    }

    private func toggleBox() {
        guard let shown else { return }
        let on = value == .checkbox(value: true)
        shown.controller.set(on ? nil : .checkbox(value: true), row: shown.row.id, column: shown.column.id, in: shown.snapshot.block)
    }

    // MARK: Text

    /// Text the field doesn't take (a word in a number, a link without a host) shows faint
    /// while it's typed; it goes when the editing ends (Craft's).
    private func colorText() {
        guard let shown else { return }
        text.textColor = DocFieldText.takes(text.text, in: shown.column) ? .floo(.label) : .floo(.disabledLabel)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        ring.isHidden = false
        if let shown, let place = shown.place { shown.controller.editor.field(place, isFocused: true) }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        ring.isHidden = true
        guard let shown else { return }
        if let place = shown.place { shown.controller.editor.field(place, isFocused: false) }
        let shownText = DocFieldText.text(value, in: shown.column)
        if text.text != shownText { text.text = shownText }
        colorText()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let shown else { return }
        // Return ends the editing, as on one line: the field wraps, its value doesn't break.
        if text.text.contains("\n") {
            text.text = text.text.replacingOccurrences(of: "\n", with: "")
            text.resignFirstResponder()
            return
        }
        colorText()
        if text.text != DocFieldText.text(value, in: shown.column) {
            shown.controller.setText(text.text, row: shown.row.id, column: shown.column.id, in: shown.snapshot.block)
        }
        // A new line of it: the row grows.
        onTextHeightChange?()
    }

    /// The typed text took another line count.
    var onTextHeightChange: (() -> Void)?

    // MARK: Layout

    /// Room at the title's start for a written page's mark, at its end for the arrow.
    private static var markWidth: CGFloat { DocPageMetrics.sheet.width / 2 + DocTokens.Space.sm }
    private static var arrowRoom: CGFloat { Metrics.openButton + DocTokens.Space.xs }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let shown, let kind else { return }
        let bounds = bounds
        switch kind {
        case .text:
            let hasMark = !pageMark.isHidden
            let isTitleRoom = shown.isTitle && !compact
            let left = hasMark ? Self.markWidth : 0
            let right = isTitleRoom ? Self.arrowRoom : 0
            // As tall as its lines, centred in a row's height when that's more (a field in a
            // cell of the row's least height); at the top of a taller row.
            let width = max(0, bounds.width - left - right)
            let lines = DocTextMeasure.height(text.text, font: DocFieldTextView.fieldFont, width: width) + 2 * Metrics.cellLinePadding
            text.frame = CGRect(x: left, y: max(0, ((Metrics.rowHeight - lines) / 2).rounded()), width: width, height: max(lines, bounds.height - max(0, ((Metrics.rowHeight - lines) / 2).rounded())))
            pageMark.frame = CGRect(x: 0, y: Metrics.cellLinePadding + 1, width: DocPageMetrics.sheet.width / 2, height: DocPageMetrics.sheet.height / 2)
            openButton.frame = CGRect(x: bounds.width - Metrics.openButton, y: ((Metrics.rowHeight - Metrics.openButton) / 2).rounded(),
                                      width: Metrics.openButton, height: Metrics.openButton)
        case .options:
            chipsButton.frame = bounds
            chips.frame = bounds
            var x: CGFloat = 0
            for chip in chips.subviews {
                let size = chip.intrinsicContentSize
                chip.frame = CGRect(x: x, y: ((Metrics.rowHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
                x += size.width + DocTokens.Space.xs
            }
        case .date:
            dateButton.frame = bounds
            date.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.rowHeight)
        case .checkbox:
            boxButton.frame = compact ? CGRect(x: 0, y: 0, width: Metrics.rowHeight, height: Metrics.rowHeight) : bounds
            box.frame = compact ? CGRect(x: 0, y: 0, width: DocTokens.Icon.standard + 4, height: Metrics.rowHeight)
                                : CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.rowHeight)
        }
        // The cell taking typing, outlined (Craft's), out over its insets.
        let out = compact ? Metrics.cellInset / 2 : Metrics.cellInset - 1
        ring.frame = bounds.insetBy(dx: -out, dy: 1)
        spot?.frame = bounds
    }

    /// Its height at a width: text as many lines as it wraps to, the rest a row's.
    static func height(of row: Row, column: Column, isTitle: Bool, compact: Bool, hasPage: Bool, width: CGFloat) -> CGFloat {
        guard kind(of: column) == .text else { return Metrics.rowHeight }
        let left = isTitle && !compact && hasPage ? markWidth : 0
        let right = isTitle && !compact ? arrowRoom : 0
        let text = DocFieldText.text(row.cells[column.id], in: column)
        let lines = DocTextMeasure.height(text, font: DocFieldTextView.fieldFont, width: width - left - right)
        return max(Metrics.rowHeight, lines + 2 * Metrics.cellLinePadding)
    }

    /// Its height now, as typed.
    var typedHeight: CGFloat {
        guard kind == .text else { return Metrics.rowHeight }
        let lines = DocTextMeasure.height(text.text, font: DocFieldTextView.fieldFont, width: text.bounds.width)
        return max(Metrics.rowHeight, lines + 2 * Metrics.cellLinePadding)
    }
}

/// A cell's text: the field's font, wrapping, no scrolling, its lines padded as a row's.
final class DocFieldTextView: UITextView {
    static let fieldFont = UIFont.systemFont(ofSize: 14)

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = Self.fieldFont
        backgroundColor = .clear
        isScrollEnabled = false
        textContainerInset = UIEdgeInsets(top: Metrics.cellLinePadding, left: 0, bottom: Metrics.cellLinePadding, right: 0)
        textContainer.lineFragmentPadding = 0
        returnKeyType = .done
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
