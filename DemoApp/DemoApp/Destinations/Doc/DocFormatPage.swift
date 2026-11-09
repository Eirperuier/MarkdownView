//
//  DocFormatPage.swift
//  DemoApp
//
//  A page of a panel (DocPanelPage), drawn the same whatever it's for, in floo's self-drawn panel at
//  the window's foot, which moves as a sheet. A declaration says what's in it; here is how it
//  stands: how tall a row is from what its keys show, lines touching, keys a little apart,
//  sections clearly apart, a line between rows of names. It follows the document and the
//  selection; what's pressed stays where it is unless the rows themselves change.
//

import FlooUIKit
import SwiftUI
import UIKit

@MainActor
final class DocFormatPage: UIViewController {
    /// The Mac's are floo's there: a tile's, a large button's, its inset and text.
    private enum Metrics {
        private static let isMac = FlooFormMetrics.isMacIdiom
        static let inset: CGFloat = isMac ? 8 : 12
        /// Keys with one line of words or a symbol.
        static let keys: CGFloat = isMac ? 36 : 50
        /// A symbol over its name.
        static let tile: CGFloat = isMac ? 44 : 58
        /// A picture over its name, or a name in a large size.
        static let tallKey: CGFloat = isMac ? 48 : 64
        static let keySpacing: CGFloat = isMac ? 4 : 5
        static let quoteBar = CGSize(width: isMac ? 2 : 3, height: isMac ? 16 : 22)
        static let colorRing: CGFloat = isMac ? 28 : 40
        static let labelRing: CGFloat = isMac ? 16 : 22
        static let boxInset: CGFloat = isMac ? 3 : 4
        static let boxCorner: CGFloat = isMac ? 6 : 8
        /// As wide as a phone lets it, and no wider beyond one.
        static let width: CGFloat = isMac ? 320 : 440
        static let text: CGFloat = DocPanelRhythm.text
        static let smallText: CGFloat = isMac ? 12 : 15
    }

    private let stack = UIStackView()
    private var page: DocPanelPage
    private var shape: [String] = []
    private var keyViews: [String: UIControl] = [:]
    private var rings: [String: FlooRainbowSwatch] = [:]
    /// What a key says that can change: its name, its count.
    private var names: [String: UILabel] = [:]
    private var counts: [String: DocCountKey] = [:]
    /// Tiles standing alone: their name in the label's colour, the accent's when on.
    private var tiles: [String: FlooActionTile] = [:]
    private var lineViews: [String: DocLineView] = [:]
    private var rowViews: [String: DocSettingRowView] = [:]
    /// As long as what's been added to it asks: scrolling where the window's too short.
    private var scroll: UIScrollView?
    private var foot: NSLayoutConstraint?
    private let opens: (DocPageID) -> Void

    /// What its panel opens with: no bar over it.
    private let isFirst: Bool

    var id: DocPageID { page.id }

    init(page: DocPanelPage, isFirst: Bool = false, opens: @escaping (DocPageID) -> Void) {
        self.page = page
        self.isFirst = isFirst
        self.opens = opens
        super.init(nibName: nil, bundle: nil)
        title = page.id.title
        preferredContentSize = CGSize(width: Metrics.width, height: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        // Lines and lists are as many as there are; keys are few, and fit.
        if page.sections.contains(where: { $0.rows.contains { $0.keys.isEmpty } }) { return addScroll() }
        NSLayoutConstraint.activate([
            (isFirst ? stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.inset)
                : stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.inset),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.inset),
        ])
        // What sizes the panel, and gives way as the panel grows around it for a level in.
        let foot = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -footInset)
        foot.priority = .defaultHigh
        foot.isActive = true
        self.foot = foot
        rebuild()
    }

    /// Above the home indicator, or as far from the panel's edge as from its sides: one or the
    /// other, not both added up.
    private var footInset: CGFloat { max(Metrics.inset, view.safeAreaInsets.bottom) }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        foot?.constant = -footInset
        scroll?.contentInset.bottom = footInset - Metrics.inset
    }

    private func addScroll() {
        stack.removeFromSuperview()
        let scroll = FlooPanelScrollView()
        self.scroll = scroll
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset.bottom = footInset - Metrics.inset
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            (isFirst ? scroll.topAnchor.constraint(equalTo: view.topAnchor) : scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: isFirst ? Metrics.inset : 0),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Metrics.inset),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Metrics.inset),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Metrics.inset),
        ])
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        flooSetNavigationBarHidden(isFirst, animated: animated)
    }

    func update(page new: DocPanelPage) {
        page = new
        guard isViewLoaded else { return }
        if currentShape == shape {
            applyStates()
        } else {
            flooUpdateSheetContent { [self] in rebuild() }
        }
    }

    private var sections: [DocPageSection] { page.sections.filter { !$0.rows.isEmpty } }

    private var currentShape: [String] {
        sections.flatMap { ["section"] + $0.rows.flatMap(\.shape) }
    }

    /// What it does in words under its symbol, or what it chooses in its own type.
    private func key(_ key: DocKey, height: CGFloat) -> UIControl {
        guard case .symbol(let name) = key.look, key.showsTitle else { return button(key) }
        let tile = FlooActionTile(title: key.title, image: UIImage(systemName: name), color: key.isDestructive ? nil : .floo(.label), role: key.isDestructive ? .destructive : .normal) { [weak self] in self?.press(key.id) }
        if #unavailable(iOS 26.0) { tile.fillColor = .floo(.controlFill) }
        tile.accessibilityLabel = key.title
        tile.preferredHeight = height
        tile.onLook = .soft()
        keyViews[key.id] = tile
        tiles[key.id] = tile
        return tile
    }

    private func group(_ keys: [DocKey], height: CGFloat) -> FlooControlGroup {
        let group = FlooControlGroup(keys.map { groupedTile($0, height: height) })
        if #unavailable(iOS 26.0) { group.usesControlFill = true }
        return group
    }

    private func rebuild() {
        shape = currentShape
        keyViews = [:]
        rings = [:]
        names = [:]
        counts = [:]
        tiles = [:]
        lineViews = [:]
        rowViews = [:]
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var last: DocPanelRow?
        for section in sections {
            for (index, row) in section.rows.enumerated() {
                separate(row, from: index == 0 ? nil : last)
                switch row {
                case .keys(let groups):
                    stack.addArrangedSubview(rowView(groups, height: height(of: row, in: section)))
                case .line(let line):
                    let view = DocLineView(line)
                    lineViews[line.id] = view
                    stack.addArrangedSubview(view)
                case .list(let list):
                    for listRow in list.rows {
                        let view = DocSettingRowView(listRow)
                        view.handle?.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
                        rowViews[listRow.id] = view
                        stack.addArrangedSubview(view)
                    }
                }
                last = row
            }
        }
        applyStates()
    }

    /// What stands between a row and the one before it in its section; none before it, a new
    /// section. Lines and a list's rows touch, each its row's height.
    private func separate(_ row: DocPanelRow, from last: DocPanelRow?) {
        guard let above = stack.arrangedSubviews.last else { return }
        guard let last else { return stack.setCustomSpacing(DocPanelRhythm.section, after: above) }
        guard !row.keys.isEmpty || !last.keys.isEmpty else { return }
        stack.setCustomSpacing(DocPanelRhythm.tiles, after: above)
        guard Self.isNames(row), Self.isNames(last) else { return }
        let line = FlooDivider()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: FlooFormMetrics.hairline(for: traitCollection)).isActive = true
        stack.addArrangedSubview(line)
        stack.setCustomSpacing(DocPanelRhythm.tiles, after: line)
    }

    /// Names to choose among, each in what it chooses.
    private static func isNames(_ row: DocPanelRow) -> Bool {
        !row.keys.isEmpty && row.keys.allSatisfy { if case .type = $0.look { true } else { false } }
    }

    /// Rows of names as tall as each other, the tallest's.
    private func height(of row: DocPanelRow, in section: DocPageSection) -> CGFloat {
        let keys = Self.isNames(row) ? section.rows.filter(Self.isNames).flatMap(\.keys) : row.keys
        return keys.map(height).max() ?? Metrics.keys
    }

    private func height(of key: DocKey) -> CGFloat {
        switch key.look {
        case .symbol where key.showsTitle: Metrics.tile
        case .picture: Metrics.tallKey
        case .type(let font, _): (usesSpecimen ? key.specimen ?? font : font).pointSize > Metrics.text ? Metrics.tallKey : Metrics.keys
        default: Metrics.keys
        }
    }

    /// The first page is short; a level in has the room for a name in what it chooses.
    private var usesSpecimen: Bool { !isFirst }

    private func rowView(_ groups: [DocKeyGroup], height: CGFloat) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = Metrics.keySpacing
        row.alignment = .center
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        var firstShared: (view: UIView, share: CGFloat)?
        for group in groups {
            // What opens more stands apart from what it's more of.
            if case .label? = group.keys.first?.look {
                let line = FlooDivider()
                line.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(line)
                NSLayoutConstraint.activate([
                    line.widthAnchor.constraint(equalToConstant: FlooFormMetrics.hairline(for: traitCollection)),
                    line.heightAnchor.constraint(equalToConstant: height / 2),
                ])
            }
            let view = groupView(group, height: height)
            row.addArrangedSubview(view)
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
            switch group.width {
            case .fixed(let width):
                view.widthAnchor.constraint(equalToConstant: width).isActive = true
            case .share(let share):
                if let first = firstShared {
                    view.widthAnchor.constraint(equalTo: first.view.widthAnchor, multiplier: share / first.share).isActive = true
                } else {
                    firstShared = (view, share)
                }
            }
        }
        return row
    }

    private func groupView(_ group: DocKeyGroup, height: CGFloat) -> UIView {
        if group.isJoined { return self.group(group.keys, height: height) }
        if group.keys.count == 1, let key = group.keys.first { return self.key(key, height: height) }
        let row = UIStackView(arrangedSubviews: group.keys.map { self.key($0, height: height) })
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Metrics.keySpacing
        return row
    }

    private func groupedTile(_ key: DocKey, height: CGFloat) -> FlooActionTile {
        var image: UIImage?
        switch key.look {
        case .symbol(let name): image = UIImage(systemName: name)
        case .picture(let picture): image = picture
        default: break
        }
        let tile = FlooActionTile(title: key.showsTitle ? key.title : "", image: image, role: key.isDestructive ? .destructive : .normal) { [weak self] in self?.press(key.id) }
        tile.accessibilityLabel = key.title
        tile.preferredHeight = height
        tile.color = key.tint
        keyViews[key.id] = tile
        return tile
    }

    private func button(_ key: DocKey) -> UIControl {
        var surface = FlooContentSurface.none
        let content: UIView
        switch key.look {
        case .type(let font, let isQuiet):
            content = label(key.title, font: usesSpecimen ? key.specimen ?? font : font, color: isQuiet ? .floo(.secondaryLabel) : .floo(.label))
        case .label:
            content = label(key.title, font: .systemFont(ofSize: Metrics.text), color: .floo(.secondaryLabel))
        case .symbol(let name):
            let image = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.text, weight: .semibold)))
            image.contentMode = .center
            content = image
            surface = .control
        case .picture(let picture):
            let image = UIImageView(image: picture)
            image.contentMode = .center
            content = image
            surface = .control
        case .quote:
            content = quoteContent(key.title)
            surface = .control
        case .box:
            content = boxContent(key.title)
            surface = .control
        case .value:
            let name = label(key.title, font: .systemFont(ofSize: Metrics.text), color: .floo(.label))
            names[key.id] = name
            content = name
            surface = .control
        case .labeled(let symbol):
            let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.smallText)))
            content = inline(image, key.title)
            surface = .control
        case .count(let value, let range, _):
            let count = DocCountKey(title: key.title, value: value, range: range) { [weak self] new in
                if case .count(_, _, let set)? = self?.key(key.id)?.look { set(new) }
            }
            counts[key.id] = count
            keyViews[key.id] = count
            return count
        case .colorRing(let picked) where key.showsTitle:
            let ring = FlooRainbowSwatch(picked: picked)
            ring.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                ring.widthAnchor.constraint(equalToConstant: Metrics.labelRing),
                ring.heightAnchor.constraint(equalToConstant: Metrics.labelRing),
            ])
            rings[key.id] = ring
            content = inline(ring, key.title)
            surface = .control
        case .colorRing(let picked):
            let ring = FlooRainbowSwatch(picked: picked)
            ring.translatesAutoresizingMaskIntoConstraints = false
            let holder = UIView()
            holder.addSubview(ring)
            NSLayoutConstraint.activate([
                ring.widthAnchor.constraint(equalToConstant: Metrics.colorRing),
                ring.heightAnchor.constraint(equalToConstant: Metrics.colorRing),
                ring.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                ring.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            ])
            rings[key.id] = ring
            content = holder
        }
        let button = FlooContentButton(content: content, surface: surface, accessibilityLabel: key.title) { [weak self] in self?.press(key.id) }
        keyViews[key.id] = button
        return button
    }

    private func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        return label
    }

    /// Something small beside a name, together in the middle.
    private func inline(_ leading: UIView, _ title: String) -> UIView {
        let line = UIStackView(arrangedSubviews: [leading, label(title, font: .systemFont(ofSize: Metrics.smallText), color: .floo(.label))])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = 6
        line.translatesAutoresizingMaskIntoConstraints = false
        let holder = UIView()
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            line.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor, constant: 4),
            line.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -4),
        ])
        return holder
    }

    private func quoteContent(_ title: String) -> UIView {
        let bar = UIView()
        bar.backgroundColor = .floo(.label)
        bar.layer.cornerRadius = Metrics.quoteBar.width / 2
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: Metrics.quoteBar.width),
            bar.heightAnchor.constraint(equalToConstant: Metrics.quoteBar.height),
        ])
        let row = UIStackView(arrangedSubviews: [bar, label(title, font: .systemFont(ofSize: Metrics.text), color: .floo(.label))])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let holder = UIView()
        holder.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    private func boxContent(_ title: String) -> UIView {
        let box = label(title, font: .systemFont(ofSize: Metrics.text), color: .floo(.label))
        box.backgroundColor = .floo(.controlFill)
        box.layer.cornerRadius = Metrics.boxCorner
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false
        let holder = UIView()
        holder.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: holder.topAnchor, constant: Metrics.boxInset),
            box.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Metrics.boxInset),
            box.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Metrics.boxInset),
            box.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Metrics.boxInset),
        ])
        return holder
    }

    private func applyStates() {
        for row in sections.flatMap(\.rows) {
            switch row {
            case .keys: row.keys.forEach(apply)
            case .line(let line): lineViews[line.id]?.update(line)
            case .list(let list): list.rows.forEach { rowViews[$0.id]?.show($0) }
            }
        }
    }

    private func apply(_ key: DocKey) {
        guard let view = keyViews[key.id] else { return }
        view.isSelected = key.isOn && !key.isMomentary
        view.isEnabled = key.isEnabled
        if case .colorRing(let picked) = key.look { rings[key.id]?.picked = picked }
        if case .count(let value, _, _) = key.look { counts[key.id]?.value = value }
        names[key.id]?.text = key.title
        view.accessibilityLabel = key.title
        if !key.isDestructive { tiles[key.id]?.color = key.isOn && !key.isMomentary ? key.tint : .floo(.label) }
    }

    private func key(_ id: String) -> DocKey? {
        sections.flatMap(\.rows).flatMap(\.keys).first { $0.id == id }
    }

    private func press(_ id: String) {
        guard let key = key(id) else { return }
        switch key.action {
        case .perform(let perform):
            perform()
            if !isFirst, page.returnsOnChoice { navigationController?.popViewController(animated: true) }
        case .open(let page): opens(page)
        }
    }

    // MARK: Dragging a list's rows

    /// Where the dragged row's centre was as it was taken.
    private var dragStart: CGFloat = 0

    private var lists: [DocSettingList] {
        sections.flatMap(\.rows).compactMap { if case .list(let list) = $0 { list } else { nil } }
    }

    /// The others make way as it passes them; the order changes when it's let go.
    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        var view = pan.view
        while let current = view, !(current is DocSettingRowView) { view = current.superview }
        guard let row = view as? DocSettingRowView, let list = lists.first(where: { $0.rows.contains { $0.id == row.id } }) else { return }
        let movable = stack.arrangedSubviews.compactMap { $0 as? DocSettingRowView }.filter(\.canMove)
        switch pan.state {
        case .began:
            dragStart = row.center.y
            stack.bringSubviewToFront(row)
            row.isLifted = true
            scroll?.isScrollEnabled = false
        case .changed:
            let y = dragStart + pan.translation(in: stack).y
            row.transform = CGAffineTransform(translationX: 0, y: y - row.center.y)
            guard let at = movable.firstIndex(of: row) else { return }
            let passed: (neighbour: DocSettingRowView, after: Bool)? =
                at + 1 < movable.count && y > movable[at + 1].center.y ? (movable[at + 1], true)
                : at > 0 && y < movable[at - 1].center.y ? (movable[at - 1], false) : nil
            guard let passed else { return }
            FlooMotion.listLayout.animate(options: [.allowUserInteraction, .beginFromCurrentState]) { [self] in
                stack.removeArrangedSubview(row)
                let index = (stack.arrangedSubviews.firstIndex(of: passed.neighbour) ?? 0) + (passed.after ? 1 : 0)
                stack.insertArrangedSubview(row, at: index)
                stack.layoutIfNeeded()
                row.transform = CGAffineTransform(translationX: 0, y: y - row.center.y)
            }
        case .ended:
            finish(row)
            guard let at = movable.firstIndex(of: row) else { return }
            // The order it's being given: nothing to rebuild when it comes back.
            var order = stack.arrangedSubviews.compactMap { ($0 as? DocSettingRowView)?.id }.makeIterator()
            shape = shape.map { $0.hasPrefix(DocPanelRow.listRow) ? DocPanelRow.listRow + (order.next() ?? "") : $0 }
            list.move?(row.id, at + 1 < movable.count ? movable[at + 1].id : nil)
        case .cancelled, .failed:
            finish(row)
            rebuild()
        default: break
        }
    }

    private func finish(_ row: DocSettingRowView) {
        scroll?.isScrollEnabled = true
        row.isLifted = false
        FlooMotion.listLayout.animate(options: [.allowUserInteraction, .beginFromCurrentState]) { row.transform = .identity }
    }
}

/// A row of a list: a line as on any page, and the handle it's dragged by beside it
/// (what's dragged, and how, is the page's: FlooDragHandle).
@MainActor
private final class DocSettingRowView: UIView {
    let id: String
    let canMove: Bool
    private(set) var handle: FlooDragHandle?
    private let content: DocLineView

    var isLifted = false {
        didSet {
            FlooMotion.appear.animate(options: [.allowUserInteraction, .beginFromCurrentState]) { [self] in
                alpha = isLifted ? 0.8 : 1
            }
        }
    }

    init(_ row: DocSettingRow) {
        id = row.id
        canMove = row.canMove
        content = DocLineView(Self.line(row))
        super.init(frame: .zero)
        var parts: [UIView] = []
        if row.canMove {
            let handle = FlooDragHandle()
            handle.accessibilityLabel = row.title
            handle.setContentHuggingPriority(.required, for: .horizontal)
            self.handle = handle
            parts.append(handle)
        }
        parts.append(content)
        let line = UIStackView(arrangedSubviews: parts)
        line.alignment = .center
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        show(row)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func line(_ row: DocSettingRow) -> DocLine {
        DocLine(id: row.id, isEnabled: row.isEnabled, parts: [
            .label(id: "\(row.id)-name", title: row.title),
            .toggle(id: "\(row.id)-shown", title: row.title, isOn: row.isOn, set: row.set),
        ])
    }

    func show(_ row: DocSettingRow) {
        content.update(Self.line(row))
    }
}

/// A count between − and +, what it counts under it.
private final class DocCountKey: UIControl {
    var value: Int { didSet { show() } }
    private let range: ClosedRange<Int>
    private let changed: (Int) -> Void
    private let number = UILabel()
    private var less: FlooContentButton?
    private var more: FlooContentButton?

    init(title: String, value: Int, range: ClosedRange<Int>, changed: @escaping (Int) -> Void) {
        self.value = value
        self.range = range
        self.changed = changed
        super.init(frame: .zero)
        // The look of the keys beside it, the same fill and corners.
        let surface = FlooContentButton(content: UIView(), surface: .control, accessibilityLabel: "") {}
        surface.isUserInteractionEnabled = false
        surface.isAccessibilityElement = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        number.font = .monospacedDigitSystemFont(ofSize: DocPanelRhythm.text, weight: .regular)
        number.textColor = .floo(.label)
        number.textAlignment = .center
        let name = UILabel()
        name.text = title
        name.font = FlooFormMetrics.isMacIdiom ? .systemFont(ofSize: 10) : .preferredFont(forTextStyle: .caption1)
        name.textColor = .floo(.secondaryLabel)
        name.textAlignment = .center
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.8
        // Together in the middle, level with − and +, not pushed to the key's top and foot.
        let words = UIStackView(arrangedSubviews: [number, name])
        words.axis = .vertical
        words.translatesAutoresizingMaskIntoConstraints = false
        let middle = UIView()
        middle.addSubview(words)
        let step = { [unowned self] (symbol: String, label: String, by: Int) -> FlooContentButton in
            let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: FlooFormMetrics.isMacIdiom ? 11 : 15, weight: .medium)))
            image.contentMode = .center
            let button = FlooContentButton(content: image, surface: .none, accessibilityLabel: label) { [unowned self] in changed(self.value + by) }
            button.widthAnchor.constraint(equalToConstant: FlooFormMetrics.isMacIdiom ? 32 : 44).isActive = true
            return button
        }
        let less = step("minus", String(localized: "Remove \(title)"), -1)
        let more = step("plus", String(localized: "Add \(title)"), 1)
        self.less = less
        self.more = more
        let line = UIStackView(arrangedSubviews: [less, middle, more])
        line.alignment = .fill
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            words.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
            words.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            words.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
        ])
        show()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool { didSet { show() } }

    private func show() {
        number.text = value.formatted()
        less?.isEnabled = isEnabled && value > range.lowerBound
        more?.isEnabled = isEnabled && value < range.upperBound
    }
}
