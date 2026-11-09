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
final class DocCollectionCellView: UIView, UITextViewDelegate, UIPointerInteractionDelegate {
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

    // A table has a cell for each field of each record: each makes only what its kind shows,
    // when it first shows it. Text is drawn in a label; the text view comes as it's edited.

    // Text
    private var label: UILabel?
    private var field: DocFieldTextView?
    private var pageMark: DocPageSheetView?
    private var openButton: FlooContentButton?
    private var ring: UIView?
    private var tap: UITapGestureRecognizer?
    private var beam: UIPointerInteraction?
    // Options, a date, a box
    private var chips: UIView?
    private var chipsButton: FlooContentButton?
    private var date: UILabel?
    private var dateButton: FlooContentButton?
    private var box: UIImageView?
    private var boxButton: FlooContentButton?
    private var spot: FlooPanelAnchorView?
    private var spotKind: DocCollectionPanel.Kind?

    init(compact: Bool) {
        self.compact = compact
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    // MARK: Parts, made as they're first shown

    private func made<V: UIView>(_ part: ReferenceWritableKeyPath<DocCollectionCellView, V?>, _ make: () -> V) -> V {
        if let view = self[keyPath: part] { return view }
        let view = make()
        self[keyPath: part] = view
        addSubview(view)
        return view
    }

    private func textLabel() -> UILabel {
        made(\.label) {
            let label = UILabel()
            label.font = DocFieldTextView.fieldFont
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isUserInteractionEnabled = false
            return label
        }
    }

    private func titleOpenButton() -> FlooContentButton {
        made(\.openButton) {
            docSymbolButton("arrow.right.circle", size: DocTokens.Icon.standard, weight: .regular,
                            side: Metrics.openButton, shape: .capsule, title: String(localized: "Open")) { [weak self] in
                guard let self, let shown = self.shown else { return }
                shown.controller.openRecord?(shown.row.id, shown.snapshot.block)
            }
        }
    }

    private func pressable(_ part: ReferenceWritableKeyPath<DocCollectionCellView, FlooContentButton?>, _ action: @escaping (DocCollectionCellView) -> Void) -> FlooContentButton {
        let button = made(part) {
            let button = FlooContentButton(content: UIView(), shape: .corner(0))
            button.addAction(UIAction { [weak self] _ in self.map(action) }, for: .primaryActionTriggered)
            return button
        }
        return button
    }

    // MARK: Showing

    func show(_ new: Shown) {
        let sameCell = shown.map { $0.row.id == new.row.id && $0.column.id == new.column.id && $0.snapshot.block == new.snapshot.block } ?? false
        if !sameCell { endField() }
        shown = new
        let kind = Self.kind(of: new.column)
        self.kind = kind
        let editable = new.controller.isEditable
        let isText = kind == .text
        let hasMark = isText && new.isTitle && !compact && new.controller.hasPage?(new.row.id) == true
        if hasMark { _ = made(\.pageMark) { let mark = DocPageSheetView(); mark.transform = CGAffineTransform(scaleX: 0.5, y: 0.5); return mark } }
        pageMark?.isHidden = !hasMark
        let showsOpen = isText && new.isTitle && !compact && (new.rowHovered || !DocTokens.Platform.isPointer)
        if showsOpen { _ = titleOpenButton() }
        openButton?.isHidden = !showsOpen
        label?.isHidden = !isText || field != nil
        field?.isHidden = !isText
        tap?.isEnabled = isText && editable
        for view in [chipsButton, chips] as [UIView?] { view?.isHidden = kind != .options }
        for view in [dateButton, date] as [UIView?] { view?.isHidden = kind != .date }
        for view in [boxButton, box] as [UIView?] { view?.isHidden = kind != .checkbox }
        switch kind {
        case .text:
            showText(new, sameCell: sameCell, editable: editable)
        case .options:
            pressable(\.chipsButton) { $0.openOptions() }.isEnabled = editable
            showChips()
            if compact { chipsButton?.docMenu { [weak self] in self?.optionsMenu() ?? [] } }
        case .date:
            pressable(\.dateButton) { $0.openDate() }.isEnabled = editable
            made(\.date) {
                let date = UILabel()
                date.font = .systemFont(ofSize: 14)
                date.textColor = .floo(.label)
                date.isUserInteractionEnabled = false
                return date
            }.text = DocFieldText.text(value, in: new.column)
        case .checkbox:
            pressable(\.boxButton) { $0.toggleBox() }.isEnabled = editable
            let box = made(\.box) {
                let box = UIImageView()
                box.contentMode = .center
                box.isUserInteractionEnabled = false
                return box
            }
            let on = value == .checkbox(value: true)
            box.image = UIImage(systemName: on ? "checkmark.square.fill" : "square",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.standard))
            box.tintColor = on ? .floo(.label) : .floo(.disabledLabel)
        }
        followPanel()
        setNeedsLayout()
    }

    private func showText(_ new: Shown, sameCell: Bool, editable: Bool) {
        let alignment: NSTextAlignment = new.column.type == .number && !compact ? .right : .left
        // What's typed stays as typed while it reads as the cell's value ("1,5" is 1.5,
        // "example.com" is its https link); a change from elsewhere replaces it.
        let shownText = DocFieldText.text(value, in: new.column)
        if let field {
            field.isEditable = editable
            field.textAlignment = alignment
            if !field.isFirstResponder || !sameCell || DocFieldText.value(typed: field.text, in: new.column) != value {
                if field.text != shownText { field.text = shownText }
            }
        } else {
            let label = textLabel()
            label.textAlignment = alignment
            if label.text != shownText { label.text = shownText }
        }
        colorText()
        if editable, tap == nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            addGestureRecognizer(tap)
            self.tap = tap
            let beam = UIPointerInteraction(delegate: self)
            addInteraction(beam)
            self.beam = beam
        }
        if new.isTitle, !compact, new.controller.editingTitle == new.row.id {
            new.controller.editingTitle = nil
            DispatchQueue.main.async { [weak self] in self?.beginField(at: nil) }
        }
    }

    /// Its panel (options, a calendar) while the controller shows it; made when it's first shown.
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
        }
        guard let kind else { return }
        let showing = shown.controller.isShowing(kind, in: block)
        if spot == nil, showing {
            spot = docPanelSpot(page: { [weak self] in self?.page(for: kind) ?? UIViewController() }, follow: { [weak self] page in
                guard let self, let shown = self.shown else { return }
                (page as? DocOptionsPage)?.update(row: shown.row, column: shown.column)
            }, onDismiss: { [weak self] in
                guard let self, let shown = self.shown else { return }
                shown.controller.close(kind, in: shown.snapshot.block)
            })
            setNeedsLayout()
        }
        spot?.show(showing, over: self)
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
        endField()
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
        let chips = made(\.chips) {
            let chips = UIView()
            chips.isUserInteractionEnabled = false
            return chips
        }
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

    /// The text shown: the text view's while there's one, else the label's.
    private var currentText: String { field?.text ?? label?.text ?? "" }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        beginField(at: tap.location(in: self))
    }

    /// Its text view in the label's place, taking typing, the caret where it was clicked.
    private func beginField(at point: CGPoint?) {
        guard let shown, kind == .text, shown.controller.isEditable else { return }
        let field = field ?? {
            let field = DocFieldTextView()
            field.delegate = self
            field.text = label?.text ?? DocFieldText.text(value, in: shown.column)
            field.textAlignment = label?.textAlignment ?? .left
            field.textColor = label?.textColor
            insertSubview(field, aboveSubview: label ?? self)
            self.field = field
            return field
        }()
        label?.isHidden = true
        setNeedsLayout()
        layoutIfNeeded()
        guard field.becomeFirstResponder() else { return }
        if let point, let position = field.closestPosition(to: convert(point, to: field)) {
            field.selectedTextRange = field.textRange(from: position, to: position)
        }
    }

    /// Back to the label: the text view lets go of its typing and goes.
    private func endField() {
        guard let field else { return }
        self.field = nil
        if field.isFirstResponder { field.resignFirstResponder() }
        field.delegate = nil
        field.removeFromSuperview()
        label?.isHidden = kind != .text
        ring?.isHidden = true
        if let shown, kind == .text {
            textLabel().text = DocFieldText.text(value, in: shown.column)
            colorText()
        }
        setNeedsLayout()
    }

    /// Text the field doesn't take (a word in a number, a link without a host) shows faint
    /// while it's typed; it goes when the editing ends (Craft's).
    private func colorText() {
        guard let shown else { return }
        let color: UIColor = DocFieldText.takes(currentText, in: shown.column) ? .floo(.label) : .floo(.disabledLabel)
        field?.textColor = color
        label?.textColor = color
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        let ring = made(\.ring) {
            let ring = UIView()
            ring.isUserInteractionEnabled = false
            ring.layer.cornerRadius = DocTokens.Radius.xs
            ring.layer.cornerCurve = .continuous
            ring.layer.borderWidth = Metrics.focusWidth
            return ring
        }
        ring.layer.borderColor = UIColor.floo(.accent).resolvedColor(with: traitCollection).cgColor
        bringSubviewToFront(ring)
        ring.isHidden = false
        setNeedsLayout()
        if let shown, let place = shown.place { shown.controller.editor.field(place, isFocused: true) }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        ring?.isHidden = true
        guard let shown else { return }
        if let place = shown.place { shown.controller.editor.field(place, isFocused: false) }
        // The label again, once UIKit's done with the text view.
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, textView === self.field, !textView.isFirstResponder else { return }
            self.endField()
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let shown, let field else { return }
        // Return ends the editing, as on one line: the field wraps, its value doesn't break.
        if field.text.contains("\n") {
            field.text = field.text.replacingOccurrences(of: "\n", with: "")
            field.resignFirstResponder()
            return
        }
        colorText()
        if field.text != DocFieldText.text(value, in: shown.column) {
            shown.controller.setText(field.text, row: shown.row.id, column: shown.column.id, in: shown.snapshot.block)
        }
        // A new line of it: the row grows.
        onTextHeightChange?()
    }

    /// The typed text took another line count.
    var onTextHeightChange: (() -> Void)?

    /// Over text to edit, the pointer is the text's beam, as over a text view.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard kind == .text, shown?.controller.isEditable == true, field == nil else { return nil }
        return UIPointerStyle(shape: .verticalBeam(length: DocFieldTextView.fieldFont.lineHeight), constrainedAxes: [])
    }

    // MARK: Layout

    /// Room at the title's start for a written page's mark, at its end for the arrow.
    private static var markWidth: CGFloat { DocPageMetrics.sheet.width / 2 + DocTokens.Space.sm }
    private static var arrowRoom: CGFloat { Metrics.openButton + DocTokens.Space.xs }

    /// In the table it takes its column's whole width, its press and the pointer's fill with
    /// it; what it shows is in from the column's lines.
    private var contentInset: CGFloat { compact ? 0 : Metrics.cellInset }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let shown, let kind else { return }
        let content = bounds.insetBy(dx: contentInset, dy: 0)
        switch kind {
        case .text:
            let hasMark = pageMark?.isHidden == false
            let isTitleRoom = shown.isTitle && !compact
            let left = hasMark ? Self.markWidth : 0
            let right = isTitleRoom ? Self.arrowRoom : 0
            // As tall as its lines, centred in a row's height when that's more (a field in a
            // cell of the row's least height); at the top of a taller row.
            let width = max(0, content.width - left - right)
            let textHeight = DocTextMeasure.height(currentText, font: DocFieldTextView.fieldFont, width: width)
            let lines = textHeight + 2 * Metrics.cellLinePadding
            let top = max(0, ((Metrics.rowHeight - lines) / 2).rounded())
            field?.frame = CGRect(x: content.minX + left, y: top, width: width, height: max(lines, bounds.height - top))
            // The label's lines where the text view's are: in from its padding, from the top.
            label?.frame = CGRect(x: content.minX + left, y: top + Metrics.cellLinePadding, width: width, height: textHeight)
            pageMark?.frame = CGRect(x: content.minX, y: Metrics.cellLinePadding + 1, width: DocPageMetrics.sheet.width / 2, height: DocPageMetrics.sheet.height / 2)
            openButton?.frame = CGRect(x: content.maxX - Metrics.openButton, y: ((Metrics.rowHeight - Metrics.openButton) / 2).rounded(),
                                       width: Metrics.openButton, height: Metrics.openButton)
        case .options:
            chipsButton?.frame = bounds
            chips?.frame = content
            var x: CGFloat = 0
            for chip in chips?.subviews ?? [] {
                let size = chip.intrinsicContentSize
                chip.frame = CGRect(x: x, y: ((Metrics.rowHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
                x += size.width + DocTokens.Space.xs
            }
        case .date:
            dateButton?.frame = bounds
            date?.frame = CGRect(x: content.minX, y: 0, width: content.width, height: Metrics.rowHeight)
        case .checkbox:
            boxButton?.frame = compact ? CGRect(x: 0, y: 0, width: Metrics.rowHeight, height: Metrics.rowHeight) : bounds
            box?.frame = compact ? CGRect(x: 0, y: 0, width: DocTokens.Icon.standard + 4, height: Metrics.rowHeight)
                                 : CGRect(x: content.minX, y: 0, width: content.width, height: Metrics.rowHeight)
        }
        // The cell taking typing, outlined (Craft's): in from the column's lines.
        ring?.frame = compact ? content.insetBy(dx: -Metrics.cellInset / 2, dy: 1) : bounds.insetBy(dx: 1, dy: 1)
        spot?.frame = content
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
        let width = field?.bounds.width ?? label?.bounds.width ?? 0
        let lines = DocTextMeasure.height(currentText, font: DocFieldTextView.fieldFont, width: width)
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
