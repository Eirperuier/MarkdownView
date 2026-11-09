//
//  DocSettingLines.swift
//  DemoApp
//
//  A setting that's more than keys, right there on its page: a line of what it is now, each
//  part changing it (a field to choose, an order, a value, removing it), so that opening a
//  level isn't what it takes to see or change it.
//

import FlooUIKit
import UIKit

struct DocLine {
    enum Part {
        /// What's chosen, opening the system's menu of the rest. `name`: what it's called, where
        /// that isn't what it says.
        case menu(id: String, title: String, name: String? = nil, sections: [FlooMenuSection])
        case text(id: String, placeholder: String, value: String, set: @MainActor (String) -> Void)
        case date(id: String, value: Date?, set: @MainActor (Date) -> Void)
        case remove(id: String, action: @MainActor () -> Void)
        /// A level in, for what's more than a line.
        case opens(id: String, title: String, action: @MainActor () -> Void)
        /// Keys to turn on and off, as many as there are, scrolled sideways.
        case chips(id: String, keys: [DocKey])
        /// All of the line, a level in.
        case row(id: String, title: String, action: @MainActor () -> Void)
        /// Words, what's after them at the line's end.
        case label(id: String, title: String)
        case toggle(id: String, title: String, isOn: Bool, set: @MainActor (Bool) -> Void)
        case stepper(id: String, title: String, value: Int, range: ClosedRange<Int>, set: @MainActor (Int) -> Void)
        case swatches(id: String, swatches: [DocLineSwatch])
    }

    let id: String
    var isEnabled = true
    let parts: [Part]

    /// What decides the views it takes.
    var shape: [String] {
        [id] + parts.flatMap { part -> [String] in
            switch part {
            case .menu(let id, _, _, _), .text(let id, _, _, _), .date(let id, _, _), .remove(let id, _), .opens(let id, _, _),
                 .row(let id, _, _), .label(let id, _), .toggle(let id, _, _, _), .stepper(let id, _, _, _, _): [id]
            case .chips(let id, let keys): [id] + keys.map(\.id)
            case .swatches(let id, let swatches): [id] + swatches.map(\.id)
            }
        }
    }
}

/// How a panel's rows stand, on every page: all as tall as each other, close within a section,
/// clearly apart between sections.
enum DocPanelRhythm {
    private static let isMac = FlooFormMetrics.isMacIdiom
    /// A row with a name and what it sets, or a row of a list.
    static let row: CGFloat = isMac ? 30 : 44
    /// Between rows of keys.
    static let tiles: CGFloat = isMac ? 4 : 6
    static let section: CGFloat = isMac ? 16 : 24
    /// Keys that are only a symbol or a colour, beside others.
    static let iconKey: CGFloat = isMac ? 44 : 58
    static let colorKey: CGFloat = isMac ? 48 : 62
    /// A row's words, and a key's that isn't showing its own type.
    static let text: CGFloat = isMac ? 13 : 17
}

/// A colour to pick; none, a colour for each of what there is.
struct DocLineSwatch {
    let id: String
    let title: String
    var color: UIColor?
    let isOn: Bool
    let pick: @MainActor () -> Void
}

@MainActor
final class DocLineView: UIView {
    private enum Metrics {
        private static let isMac = FlooFormMetrics.isMacIdiom
        /// A small button's.
        static let height: CGFloat = isMac ? 24 : 36
        static let dot: CGFloat = isMac ? 14 : 20
        static let rowOutset: CGFloat = isMac ? 6 : 8
        /// A row's, on every page of a panel.
        static let labelFont = UIFont.systemFont(ofSize: DocPanelRhythm.text)
        static let fieldWidth: CGFloat = isMac ? 96 : 120
        static let chipFont = UIFont.systemFont(ofSize: isMac ? 12 : 15)
        static let chipPadding: CGFloat = isMac ? 8 : 12
    }

    private var line: DocLine
    private var menus: [String: FlooMenuButton] = [:]
    private var fields: [String: UITextField] = [:]
    private var dates: [String: FlooDatePicker] = [:]
    private var chips: [String: (button: FlooContentButton, label: UILabel)] = [:]
    private var labels: [String: UILabel] = [:]
    private var toggles: [String: FlooSwitch] = [:]
    private var steppers: [String: FlooStepper] = [:]
    private var dots: [String: DocLineDot] = [:]

    /// Whether what sets it can be pressed, its words saying so.
    var isEnabled = true {
        didSet {
            toggles.values.forEach { $0.isEnabled = isEnabled }
            steppers.values.forEach { $0.isEnabled = isEnabled }
            labels.values.forEach { $0.textColor = .floo(isEnabled ? .label : .secondaryLabel) }
        }
    }

    init(_ line: DocLine) {
        self.line = line
        super.init(frame: .zero)
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        var fills = false
        var hasChips = false
        for part in line.parts {
            row.addArrangedSubview(make(part))
            switch part {
            case .chips: fills = true; hasChips = true
            case .text, .label, .swatches, .row: fills = true
            default: break
            }
        }
        // Words take the rest of the line, putting what they're about at its end; chips take it themselves.
        if hasChips { labels.values.forEach { $0.setContentHuggingPriority(.required, for: .horizontal) } }
        heightAnchor.constraint(equalToConstant: DocPanelRhythm.row).isActive = true
        // Parts as wide as they say, the rest of the line left empty.
        if !fills {
            let rest = UIView()
            rest.setContentHuggingPriority(.init(1), for: .horizontal)
            rest.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            row.insertArrangedSubview(rest, at: row.arrangedSubviews.count - trailingCount)
        }
        update(line)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Removing and going a level in stay at the end.
    private var trailingCount: Int {
        line.parts.reversed().prefix { part in
            switch part {
            case .remove, .opens: true
            default: false
            }
        }.count
    }

    private func make(_ part: DocLine.Part) -> UIView {
        switch part {
        case .menu(let id, _, _, _):
            let button = FlooMenuButton(.tertiary.size(.small).shape(.rounded), title: "", menu: UIMenu())
            menus[id] = button
            return button
        case .text(let id, let placeholder, _, _):
            let field = FlooTextField(placeholder: placeholder, size: .small)
            field.addAction(UIAction { [weak self, unowned field] _ in
                for case .text(id, _, _, let set) in self?.line.parts ?? [] { set(field.text ?? "") }
            }, for: .editingChanged)
            fields[id] = field
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.fieldWidth).isActive = true
            return field
        case .date(let id, _, _):
            let picker = FlooDatePicker(mode: .date)
            picker.addAction(UIAction { [weak self, unowned picker] _ in
                for case .date(id, _, let set) in self?.line.parts ?? [] { set(picker.date) }
            }, for: .valueChanged)
            dates[id] = picker
            return picker
        case .remove(let id, _):
            return small("trash", String(localized: "Remove")) { [weak self] in
                for case .remove(id, let action) in self?.line.parts ?? [] { action() }
            }
        case .opens(let id, let title, _):
            return small("chevron.right", title) { [weak self] in
                for case .opens(id, _, let action) in self?.line.parts ?? [] { action() }
            }
        case .chips(_, let keys):
            return chipRow(keys)
        case .row(let id, let title, _):
            let name = UILabel()
            name.text = title
            name.font = Metrics.labelFont
            name.textColor = .floo(.label)
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)))
            chevron.tintColor = .floo(.secondaryLabel)
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            let content = UIStackView(arrangedSubviews: [name, chevron])
            content.alignment = .center
            content.isUserInteractionEnabled = false
            let button = FlooContentButton(content: content, surface: .none, padding: NSDirectionalEdgeInsets(top: 0, leading: Metrics.rowOutset, bottom: 0, trailing: Metrics.rowOutset), accessibilityLabel: title) { [weak self] in
                for case .row(id, _, let action) in self?.line.parts ?? [] { action() }
            }
            // Its words where the others' are; what it clips and lights a little past them.
            let holder = UIView()
            button.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: holder.topAnchor),
                button.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                button.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: -Metrics.rowOutset),
                button.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: Metrics.rowOutset),
            ])
            return holder
        case .label(let id, _):
            let label = UILabel()
            label.font = Metrics.labelFont
            label.textColor = .floo(.label)
            label.setContentHuggingPriority(.init(1), for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labels[id] = label
            return label
        case .toggle(let id, let title, _, _):
            let toggle = FlooSwitch()
            toggle.accessibilityLabel = title
            toggle.setContentHuggingPriority(.required, for: .horizontal)
            toggle.addAction(UIAction { [weak self, unowned toggle] _ in
                for case .toggle(id, _, _, let set) in self?.line.parts ?? [] { set(toggle.isOn) }
            }, for: .valueChanged)
            toggles[id] = toggle
            return toggle
        case .stepper(let id, let title, _, let range, _):
            let stepper = FlooStepper()
            stepper.accessibilityLabel = title
            stepper.minimumValue = Double(range.lowerBound)
            stepper.maximumValue = Double(range.upperBound)
            stepper.setContentHuggingPriority(.required, for: .horizontal)
            stepper.addAction(UIAction { [weak self, unowned stepper] _ in
                for case .stepper(id, _, _, _, let set) in self?.line.parts ?? [] { set(Int(stepper.value)) }
            }, for: .valueChanged)
            steppers[id] = stepper
            return stepper
        case .swatches(let id, let swatches):
            let row = UIStackView()
            row.alignment = .center
            row.setContentHuggingPriority(.required, for: .horizontal)
            for swatch in swatches {
                let dot = DocLineDot(color: swatch.color, size: Metrics.dot)
                dots[swatch.id] = dot
                let swatchID = swatch.id
                row.addArrangedSubview(FlooContentButton(content: dot, accessibilityLabel: swatch.title) { [weak self] in
                    for case .swatches(id, let current) in self?.line.parts ?? [] { current.first { $0.id == swatchID }?.pick() }
                })
            }
            return row
        }
    }

    private func small(_ symbol: String, _ label: String, action: @escaping @MainActor () -> Void) -> UIView {
        let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)))
        image.tintColor = .floo(.secondaryLabel)
        image.contentMode = .center
        let button = FlooContentButton(content: image, accessibilityLabel: label) { action() }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.height),
            button.heightAnchor.constraint(equalToConstant: Metrics.height),
        ])
        return button
    }

    private func chipRow(_ keys: [DocKey]) -> UIView {
        let scroll = DocChipScroll()
        scroll.showsHorizontalScrollIndicator = false
        scroll.heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = UIStackView()
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        for key in keys {
            let label = UILabel()
            label.text = key.title
            label.font = Metrics.chipFont
            let button = FlooContentButton(content: label, surface: .control, padding: NSDirectionalEdgeInsets(top: 0, leading: Metrics.chipPadding, bottom: 0, trailing: Metrics.chipPadding), accessibilityLabel: key.title) { [weak self] in
                self?.pressChip(key.id)
            }
            chips[key.id] = (button, label)
            stack.addArrangedSubview(button)
        }
        return scroll
    }

    private func pressChip(_ id: String) {
        for case .chips(_, let keys) in line.parts {
            keys.first { $0.id == id }?.press()
        }
    }

    func update(_ new: DocLine) {
        line = new
        if isEnabled != new.isEnabled { isEnabled = new.isEnabled }
        for part in new.parts {
            switch part {
            case .menu(let id, let title, let name, let sections):
                guard let button = menus[id] else { continue }
                button.title = title
                button.accessibilityLabel = name ?? title
                button.menu = UIMenu(children: sections.systemElements())
            case .text(let id, _, let value, _):
                if let field = fields[id], !field.isFirstResponder, field.text != value { field.text = value }
            case .date(let id, let value, _):
                if let value, let picker = dates[id], picker.date != value { picker.date = value }
            case .chips(_, let keys):
                for key in keys {
                    guard let chip = chips[key.id] else { continue }
                    // What shows has the controls' fill, what doesn't has none: no colour to say it.
                    chip.button.surface = key.isOn ? .control : .none
                    chip.button.isEnabled = key.isEnabled
                    chip.label.textColor = key.isOn ? .floo(.label) : .floo(.secondaryLabel)
                }
            case .label(let id, let title):
                labels[id]?.text = title
            case .toggle(let id, _, let isOn, _):
                if toggles[id]?.isOn != isOn { toggles[id]?.isOn = isOn }
            case .stepper(let id, _, let value, _, _):
                if steppers[id]?.value != Double(value) { steppers[id]?.value = Double(value) }
            case .swatches(_, let swatches):
                for swatch in swatches { dots[swatch.id]?.isOn = swatch.isOn }
            case .remove, .opens, .row: break
            }
        }
    }
}

/// A colour, ringed when it's the one; none, a ring of every colour.
@MainActor
private final class DocLineDot: UIView {
    var isOn = false { didSet { ring.isHidden = !isOn } }
    private let ring = UIView()

    init(color: UIColor?, size: CGFloat) {
        super.init(frame: .zero)
        let outer = size + 10
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: outer), heightAnchor.constraint(equalToConstant: outer)])
        isUserInteractionEnabled = false
        ring.frame = CGRect(x: 0, y: 0, width: outer, height: outer)
        ring.layer.cornerRadius = outer / 2
        ring.layer.borderWidth = 2
        ring.layer.borderColor = UIColor.floo(.label).cgColor
        ring.isHidden = true
        addSubview(ring)
        let fill: UIView = color == nil ? FlooRainbowSwatch(cornerRadius: size / 2) : UIView()
        fill.backgroundColor = color
        fill.layer.cornerRadius = size / 2
        fill.frame = CGRect(x: 5, y: 5, width: size, height: size)
        addSubview(fill)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (dot: DocLineDot, _: UITraitCollection) in
            dot.ring.layer.borderColor = UIColor.floo(.label).resolvedColor(with: dot.traitCollection).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Going out of sight at an edge where there's more, rather than being cut there.
@MainActor
private final class DocChipScroll: UIScrollView {
    private static let fade: CGFloat = 20
    private let fading = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        fading.startPoint = CGPoint(x: 0, y: 0.5)
        fading.endPoint = CGPoint(x: 1, y: 0.5)
        fading.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        layer.mask = fading
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let start = min(max(bounds.minX, 0), Self.fade) / bounds.width
        let end = min(max(contentSize.width - bounds.maxX, 0), Self.fade) / bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fading.frame = bounds
        fading.locations = [0, start, 1 - end, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
    }
}
