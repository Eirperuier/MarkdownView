//
//  DocCollectionPages.swift
//  DemoApp
//
//  A collection's small panels, in UIKit from floo-uikit's parts: a select's options, a date's
//  calendar, a record's value typed apart, and the forms (a field, a new view, an option). Opened
//  from what they're about (`docPanel(page:)`); what they do is the controller's. A view's
//  settings are the settings' pages (DocSelectedView).
//

import DocKit
import FlooUIKit
import UIKit

/// A panel's page: what's in `stack` from its margins, scrolling past the room there is,
/// as a menu's panel is. Esc closes it, a field having the keys or not.
class DocStackPage: UIViewController {
    let stack = UIStackView()
    private let width: CGFloat?
    private weak var scroll: UIScrollView?
    private var scrollBottom: NSLayoutConstraint?

    static var margin: CGFloat { FlooFormMetrics.isMacIdiom ? 8 : 12 }
    /// On the Mac and a large screen a page opens ready to type; a phone's stays on what's in it.
    var typesAtOnce: Bool { FlooFormMetrics.isMacIdiom || traitCollection.horizontalSizeClass == .regular }

    init(width: CGFloat?) {
        self.width = width
        super.init(nibName: nil, bundle: nil)
        if let width { preferredContentSize = CGSize(width: width, height: 0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.axis = .vertical
        stack.spacing = Self.margin
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Its cards go by the panel's corners.
        let scroll = FlooPanelScrollView()
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        self.scroll = scroll
        scroll.addSubview(stack)
        view.addSubview(scroll)
        let margin = Self.margin
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: margin),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -margin),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -margin),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * margin),
        ])
        endScroll(at: view.bottomAnchor)
    }

    /// What scrolls ends over the sheet actions' foot: the Mac's row. On iOS they're in the bar
    /// and it goes on to the panel's foot (the home indicator's room its inset, above).
    func endAboveSheetFoot() {
        guard FlooFormMetrics.isMacIdiom else { return }
        endScroll(at: flooSheetFootTop)
    }

    private func endScroll(at anchor: NSLayoutYAxisAnchor) {
        guard let scroll else { return }
        scrollBottom?.isActive = false
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: anchor)
        scrollBottom?.isActive = true
    }

    /// The panel's foot, as the settings' pages have it: the home indicator's room in place of
    /// its margin, not on top of it.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The system's (the home indicator), not the room kept for the sheet actions' foot,
        // which what scrolls already ends over.
        scroll?.contentInset.bottom = max(view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom - Self.margin, 0)
    }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape] + (super.keyCommands ?? [])
    }

    @objc private func escapePressed() { closePage() }

    /// Closes the panel, as what holds it says it's open.
    func closePage() {}
}

// MARK: - Options

/// A select's or multi-select's options for one record (Craft's Set …): type to find one, or a
/// new one, which Return adds; a press ticks one, a select's closing the panel; a long press
/// or right-click deletes one.
final class DocOptionsPage: DocStackPage, UITextFieldDelegate {
    private var row: Row
    private var column: Column
    private let block: DocBlockID
    private let controller: DocCollectionController
    private let field = FlooTextField(appearance: .plain)
    private lazy var fieldRow = FlooRowView(FlooControlConfiguration(field, shape: .text))
    /// One card: the field, then the options, so its four corners are the panel's.
    private lazy var section: FlooSectionView = {
        let section = FlooSectionView(rows: [fieldRow])
        section.followsContainerCorners = true
        return section
    }()
    private var shownSignature: [String] = []

    init(row: Row, column: Column, block: DocBlockID, controller: DocCollectionController) {
        self.row = row
        self.column = column
        self.block = block
        self.controller = controller
        super.init(width: 280)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var options: [SelectOption] { DocFieldText.options(column) }
    private var isMulti: Bool { if case .multiSelect = column.type { true } else { false } }
    private var query: String { (field.text ?? "").trimmingCharacters(in: .whitespaces) }

    private func isChosen(_ option: SelectOption) -> Bool {
        switch row.cells[column.id] {
        case .select(let id)?: id == option.id
        case .multiSelect(let ids)?: ids.contains(option.id)
        default: false
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        field.placeholder = String(localized: "Set \(column.name)")
        field.returnKeyType = .done
        field.delegate = self
        field.addAction(UIAction { [unowned self] _ in showOptions() }, for: .editingChanged)
        stack.addArrangedSubview(section)
        showOptions(animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if typesAtOnce { field.becomeFirstResponder() }
    }

    /// As what it reads changes under it.
    func update(row: Row, column: Column) {
        self.row = row
        self.column = column
        if isViewLoaded { showOptions() }
    }

    private func showOptions(animated: Bool = true) {
        let query = query
        let all = options
        let shown = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let creates = !query.isEmpty && !all.contains { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        let signature = shown.map { "\($0.id)|\($0.name)|\(DocOptionColor.token($0, in: all))|\(isChosen($0))" } + (creates ? ["+" + query] : [])
        guard signature != shownSignature else { return }
        shownSignature = signature
        let change = { [self] in
            var rows = shown.map { optionRow($0, in: all) }
            if creates {
                rows.append(FlooRowView(FlooRowConfiguration(title: String(localized: "Create “\(query)”"), icon: .symbol("plus"), role: .action)) { [weak self] in self?.submit() })
            }
            section.rows = [fieldRow] + rows
        }
        if animated { flooUpdateSheetContent(change) } else { change() }
    }

    private func optionRow(_ option: SelectOption, in all: [SelectOption]) -> FlooRowView {
        var configuration = FlooRowConfiguration(title: option.name, trailing: isChosen(option) ? .checkmark : .none)
        configuration.titleBadge = FlooBadgeStyle.tinted.tone(.color(UIColor(DocOptionColor.color(DocOptionColor.token(option, in: all)))))
            .size(FlooFormMetrics.isMacIdiom ? .medium : .large)
        let row = FlooRowView(configuration) { [weak self] in self?.pick(option.id) }
        row.accessibilityLabel = option.name
        row.flooAddContextMenu { [weak self] in
            guard let self else { return [] }
            return [.init([.action(String(localized: "Delete Option"), symbol: "trash", role: .destructive) { [weak self] in
                guard let self else { return }
                controller.deleteOption(option.id, in: column.id, of: block)
            }])]
        }
        return row
    }

    private var kind: DocCollectionPanel.Kind { .options(row: row.id, column: column.id) }

    override func closePage() { controller.close(kind, in: block) }

    private func pick(_ option: OptionID) {
        controller.toggle(option, row: row.id, column: column.id, in: block)
        field.text = ""
        if isMulti { showOptions() } else { closePage() }
    }

    /// Return: the option typed (an existing one by its name, else a new one).
    private func submit() {
        guard !query.isEmpty else { return }
        if let found = options.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            pick(found.id)
        } else if let added = controller.addOption(query, to: column.id, in: block) {
            pick(added)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }

    /// Tests: the rows there are, by their names; a press on one; typing.
    var testRowTitles: [String] { section.rows.compactMap { ($0.configuration as? FlooRowConfiguration)?.title } }
    func testPress(_ title: String) { section.rows.first { ($0.configuration as? FlooRowConfiguration)?.title == title }?.action?() }
    func testType(_ text: String) {
        field.text = text
        showOptions()
    }
}

// MARK: - A date

/// A date cell's calendar, floo's: a day pressed is the record's and closes it; on the Mac a field
/// over it, Return closing; Clear if it has one.
final class DocDatePage: DocStackPage {
    private let row: Row
    private let column: Column
    private let block: DocBlockID
    private let controller: DocCollectionController
    private let picker = FlooDatePicker(mode: .date, style: .inline, drawn: true)

    init(row: Row, column: Column, block: DocBlockID, controller: DocCollectionController) {
        self.row = row
        self.column = column
        self.block = block
        self.controller = controller
        super.init(width: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var chosen: Date? {
        if case .date(let day)? = row.cells[column.id] { DocFieldText.date(of: day) } else { nil }
    }

    private var kind: DocCollectionPanel.Kind { .date(row: row.id, column: column.id) }

    override func closePage() { controller.close(kind, in: block) }

    override func viewDidLoad() {
        super.viewDidLoad()
        picker.date = chosen ?? .now
        picker.hasNoDate = chosen == nil
        picker.addAction(UIAction { [unowned self] _ in
            controller.set(.date(value: .day(DocFieldText.day(of: picker.date))), row: row.id, column: column.id, in: block)
        }, for: .valueChanged)
        picker.onDayPressed = { [unowned self] in closePage() }
        picker.onFinish = { [unowned self] in closePage() }
        stack.addArrangedSubview(picker)
        if chosen != nil {
            stack.addArrangedSubview(FlooButton(.tertiary, title: String(localized: "Clear")) { [unowned self] in
                controller.set(nil, row: row.id, column: column.id, in: block)
                closePage()
            })
        }
        let width = picker.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        preferredContentSize = CGSize(width: width + 2 * Self.margin, height: 0)
    }

    /// Tests: the picker.
    var testPicker: FlooDatePicker { picker }
}

// MARK: - Forms

/// A form: a bar with its title, its cancel and its confirm (floo's sheet actions), a name and
/// what its kind adds. In a navigation controller, for its bar (`inNavigation`).
class DocFormPage: DocStackPage, UITextFieldDelegate {
    let nameField = FlooTextField(appearance: .plain)
    private let formTitle: String
    private let saveTitle: String
    private let initialName: String?
    private let placeholder: String

    init(title: String, save: String, name: String?, placeholder: String, width: CGFloat = 300) {
        formTitle = title
        saveTitle = save
        initialName = name
        self.placeholder = placeholder
        super.init(width: width)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func inNavigation() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.preferredContentSize = preferredContentSize
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = formTitle
        nameField.placeholder = placeholder
        nameField.text = initialName
        nameField.returnKeyType = .done
        nameField.delegate = self
        nameField.addAction(UIAction { [unowned self] _ in updateSave() }, for: .editingChanged)
        addContent()
        updateSave()
        endAboveSheetFoot()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if focusesName { nameField.becomeFirstResponder() }
    }

    /// What's on it. Its name alone, unless it says otherwise.
    func addContent() { addCard([]) }

    /// A card of the name and `rows`, its corners the panel's.
    func addCard(_ rows: [FlooRowView]) {
        let card = FlooSectionView(rows: [FlooRowView(FlooControlConfiguration(nameField, shape: .text))] + rows)
        card.followsContainerCorners = true
        stack.addArrangedSubview(card)
    }

    /// A row choosing from a menu: its name, what's chosen.
    func menuRow(_ title: String, value: String, symbol: String?, _ sections: [FlooMenuSection]) -> FlooRowConfiguration {
        FlooRowConfiguration(title: title, value: value, icon: symbol.map { .symbol($0) },
                             trailing: .menu(UIMenu(children: sections.systemElements(traits: traitCollection))))
    }

    var focusesName: Bool { true }
    var canSave: Bool { !name.isEmpty }
    func save() {}

    var name: String { (nameField.text ?? "").trimmingCharacters(in: .whitespaces) }

    func updateSave() {
        flooSheetActions = FlooSheetActions(
            cancel: .init(String(localized: "Cancel")) { [unowned self] in closePage() },
            confirm: .init(saveTitle, isEnabled: canSave) { [unowned self] in submit() })
    }

    private func submit() {
        guard canSave else { return }
        save()
        closePage()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }

    /// Tests.
    var testCanSave: Bool { flooSheetActions?.confirm?.isEnabled == true }
    func testSave() { submit() }
}

/// Add Field, or Edit Field for one there is: its name and its type.
final class DocFieldPage: DocFormPage {
    private let column: Column?
    private let block: DocBlockID
    private let controller: DocCollectionController
    private let kind: DocCollectionPanel.Kind
    private var type: ColumnType
    private var typeRow: FlooRowView?

    /// `panel`: the one it shows as, if not the table's (a kanban card's Add Field).
    init(column: Column?, block: DocBlockID, controller: DocCollectionController, panel: DocCollectionPanel.Kind? = nil) {
        self.column = column
        self.block = block
        self.controller = controller
        kind = panel ?? column.map { .editField($0.id) } ?? .addField
        type = column?.type ?? .text
        super.init(title: column == nil ? String(localized: "Add Field") : String(localized: "Edit Field"),
                   save: column == nil ? String(localized: "Add") : String(localized: "Save"),
                   name: column?.name, placeholder: String(localized: "Field Name"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func addContent() {
        let typeRow = FlooRowView(typeConfiguration())
        self.typeRow = typeRow
        addCard([typeRow])
    }

    private func typeConfiguration() -> FlooRowConfiguration {
        let types = DocFieldText.types
        func item(_ type: ColumnType) -> FlooMenuItem {
            .action(DocFieldText.name(type), symbol: DocFieldText.symbol(type), isOn: DocFieldText.name(type) == DocFieldText.name(self.type)) { [weak self] in
                self?.choose(type)
            }
        }
        return menuRow(String(localized: "Type"), value: DocFieldText.name(type), symbol: DocFieldText.symbol(type),
                       [FlooMenuSection(types.prefix(6).map(item)), FlooMenuSection(types.dropFirst(6).map(item))])
    }

    private func choose(_ type: ColumnType) {
        self.type = type
        typeRow?.configuration = typeConfiguration()
    }

    override func closePage() { controller.close(kind, in: block) }

    override func save() {
        if let column {
            controller.editField(column.id, name: name, type: type, in: block)
        } else {
            _ = controller.addField(name, type: type, to: block)
        }
    }

    /// Tests.
    func testFill(name: String, type: ColumnType) {
        nameField.text = name
        updateSave()
        choose(type)
    }
}

/// Name View, for a view just added.
final class DocNameViewPage: DocFormPage {
    private let block: DocBlockID
    private let view_: CollectionView
    private let controller: DocCollectionController

    init(block: DocBlockID, view: CollectionView, controller: DocCollectionController) {
        self.block = block
        view_ = view
        self.controller = controller
        super.init(title: String(localized: "Name View"), save: String(localized: "Save"), name: view.name, placeholder: String(localized: "Name"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func closePage() { controller.close(.nameView(view_.id), in: block) }
    override func save() { controller.rename(view_.id, in: block, to: name) }
}

/// Create Kanban: its name and the field it groups by.
final class DocCreateKanbanPage: DocFormPage {
    private let snapshot: DocCollectionSnapshot
    private let controller: DocCollectionController
    private var group: ColumnID?
    private var groupRow: FlooRowView?

    init(snapshot: DocCollectionSnapshot, controller: DocCollectionController) {
        self.snapshot = snapshot
        self.controller = controller
        super.init(title: String(localized: "Create Kanban"), save: String(localized: "Save"), name: String(localized: "New Kanban"), placeholder: String(localized: "Name"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var groupable: [Column] { DocCollectionController.groupable(in: snapshot.database) }
    private var chosen: Column? { groupable.first { $0.id == group } ?? groupable.first }

    override var focusesName: Bool { typesAtOnce }
    override var canSave: Bool { chosen != nil }

    override func addContent() {
        let row = FlooRowView(groupConfiguration())
        groupRow = row
        addCard([row])
    }

    private func groupConfiguration() -> FlooRowConfiguration {
        menuRow(String(localized: "Group By"), value: chosen?.name ?? "", symbol: chosen.map(DocFieldText.symbol), [.init(groupable.map { column in
            .action(column.name, symbol: DocFieldText.symbol(column), isOn: column.id == chosen?.id) { [weak self] in
                guard let self else { return }
                group = column.id
                groupRow?.configuration = groupConfiguration()
            }
        })])
    }

    override func closePage() { controller.close(.createKanban, in: snapshot.block) }

    override func save() {
        guard let chosen else { return }
        controller.addView(to: snapshot.block, name: name.isEmpty ? String(localized: "New Kanban") : name, layout: .kanban(groupBy: chosen.id, hidden: [], sort: []))
    }
}

/// Create Chart: its name, its kind, what it's along and what it measures.
final class DocCreateChartPage: DocFormPage {
    private let snapshot: DocCollectionSnapshot
    private let controller: DocCollectionController
    private var kind = CollectionChart.Kind.bar
    private var axis: ColumnID?
    /// The number measured; none, the records counted.
    private var value: ColumnID??
    private var axisRow: FlooRowView?
    private var valueRow: FlooRowView?
    private var kindTiles: [CollectionChart.Kind: FlooActionTile] = [:]

    init(snapshot: DocCollectionSnapshot, controller: DocCollectionController) {
        self.snapshot = snapshot
        self.controller = controller
        super.init(title: String(localized: "Create Chart"), save: String(localized: "Save"), name: String(localized: "New Chart"), placeholder: String(localized: "Name"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var database: Database { snapshot.database }
    private var defaults: CollectionChart? { DocCollectionController.chart(kind, in: database) }
    private var chosenAxis: Column? { database.columns.first { $0.id == axis ?? defaults?.groupBy } }
    private var chosenValue: ColumnID? { value ?? defaults?.values.first }

    override var focusesName: Bool { typesAtOnce }
    override var canSave: Bool { chosenAxis != nil }

    override func addContent() {
        let axisRow = FlooRowView(axisConfiguration())
        let valueRow = FlooRowView(valueConfiguration())
        self.axisRow = axisRow
        self.valueRow = valueRow
        addCard([axisRow, valueRow])
        let tiles = CollectionChart.Kind.allCases.map { kind in
            let tile = FlooActionTile(title: DocCollectionNames.name(kind), image: UIImage(systemName: DocCollectionNames.symbol(kind))) { [weak self] in self?.choose(kind) }
            tile.onLook = .soft()
            tile.isSelected = kind == self.kind
            kindTiles[kind] = tile
            return tile
        }
        stack.addArrangedSubview(FlooActionTiles(tiles))
    }

    private func choose(_ kind: CollectionChart.Kind) {
        self.kind = kind
        kindTiles.forEach { $0.value.isSelected = $0.key == kind }
        axisRow?.configuration = axisConfiguration()
        valueRow?.configuration = valueConfiguration()
        updateSave()
    }

    private func axisConfiguration() -> FlooRowConfiguration {
        menuRow(String(localized: "X Axis"), value: chosenAxis?.name ?? "", symbol: chosenAxis.map(DocFieldText.symbol), [.init(database.columns.map { column in
            .action(column.name, symbol: DocFieldText.symbol(column), isOn: column.id == chosenAxis?.id) { [weak self] in
                guard let self else { return }
                axis = column.id
                axisRow?.configuration = axisConfiguration()
                updateSave()
            }
        })])
    }

    private func valueConfiguration() -> FlooRowConfiguration {
        let numbers = database.columns.filter { $0.type == .number }
        let chosen = numbers.first { $0.id == chosenValue }
        let pick = { [weak self] (id: ColumnID?) in
            guard let self else { return }
            value = .some(id)
            valueRow?.configuration = valueConfiguration()
        }
        let count = FlooMenuItem.action(String(localized: "Count"), symbol: "number.circle", isOn: chosen == nil) { pick(nil) }
        return menuRow(String(localized: "Y Axis"), value: chosen?.name ?? String(localized: "Count"), symbol: chosen.map(DocFieldText.symbol) ?? "number.circle", [.init([count] + numbers.map { column in
            .action(column.name, symbol: DocFieldText.symbol(column), isOn: column.id == chosen?.id) { pick(column.id) }
        })])
    }

    override func closePage() { controller.close(.createChart, in: snapshot.block) }

    override func save() {
        guard let axis = chosenAxis else { return }
        let values = chosenValue.map { [$0] } ?? []
        let title = DocCollectionController.titleColumn(of: database)?.id
        let chart = CollectionChart(kind: kind, groupBy: axis.id, values: values, calculation: values.isEmpty ? .count : .sum,
                                    order: kind == .bar && axis.id == title && !values.isEmpty ? .valueDescending : .groups)
        controller.addView(to: snapshot.block, name: name.isEmpty ? String(localized: "New Chart") : name, layout: .chart(chart: chart))
    }
}

/// Add Option (a kanban's new column), or one to rename and recolour.
final class DocOptionPage: DocFormPage {
    private let block: DocBlockID
    private let column: ColumnID
    private let option: SelectOption?
    private let controller: DocCollectionController
    private var color: String

    init(snapshot: DocCollectionSnapshot, column: ColumnID, option: SelectOption?, controller: DocCollectionController) {
        block = snapshot.block
        self.column = column
        self.option = option
        self.controller = controller
        let field = snapshot.database.columns.first { $0.id == column }
        let options = field.map(DocFieldText.options) ?? []
        if let option {
            color = DocOptionColor.token(option, in: options)
        } else {
            let used = Set(options.map { DocOptionColor.token($0, in: options) })
            color = DocOptionColor.offered.first { !used.contains($0) } ?? DocOptionColor.offered[0]
        }
        super.init(title: option == nil ? String(localized: "Add Option to \(field?.name ?? "")") : String(localized: "Edit Option"),
                   save: option == nil ? String(localized: "Add") : String(localized: "Save"),
                   name: option?.name, placeholder: String(localized: "Name"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var kind: DocCollectionPanel.Kind { option.map { .editOption($0.id) } ?? .addOption(column) }

    override func addContent() {
        addCard([])
        stack.addArrangedSubview(FlooSwatches(DocOptionColor.offered.map { token in
            FlooSwatch(id: token, title: token, color: UIColor(DocOptionColor.color(token)), isOn: token == color)
        }) { [weak self] in self?.color = $0.id })
    }

    override func closePage() { controller.close(kind, in: block) }

    override func save() {
        if let option {
            controller.updateOption(option.id, name: name, color: color, in: column, of: block)
        } else {
            controller.addOption(name, color: color, to: column, in: block)
        }
    }
}

// MARK: - A value typed apart

/// A record's text, number or link typed in a field of its own (Craft's, from a kanban card's
/// Edit Properties): what's typed is the record's as it's typed; Return or Esc closes.
final class DocPropertyPage: DocStackPage, UITextFieldDelegate {
    private let row: Row
    private let column: Column
    private let block: DocBlockID
    private let controller: DocCollectionController
    private let field = FlooTextField(appearance: .plain)

    init(row: Row, column: Column, block: DocBlockID, controller: DocCollectionController) {
        self.row = row
        self.column = column
        self.block = block
        self.controller = controller
        super.init(width: 280)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var value: CellValue? { row.cells[column.id] }

    override func closePage() { controller.close(.property(row: row.id, column: column.id), in: block) }

    override func viewDidLoad() {
        super.viewDidLoad()
        field.placeholder = column.name
        field.text = DocFieldText.text(value, in: column)
        field.returnKeyType = .done
        field.delegate = self
        field.addAction(UIAction { [unowned self] _ in
            let text = field.text ?? ""
            field.isInvalid = !DocFieldText.takes(text, in: column)
            controller.setText(text, row: row.id, column: column.id, in: block)
        }, for: .editingChanged)
        let card = FlooSectionView(rows: [FlooRowView(FlooControlConfiguration(field, shape: .text))])
        card.followsContainerCorners = true
        stack.addArrangedSubview(card)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        closePage()
        return false
    }
}
