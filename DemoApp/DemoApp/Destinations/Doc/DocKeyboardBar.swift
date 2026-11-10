//
//  DocKeyboardBar.swift
//  DemoApp
//
//  The bar over a phone's keyboard, laid out as Craft's: a white strip with a hairline
//  on top, the page's width. As Craft's, it is the page's, not the keyboard's (no input
//  accessory): over the page's bottom, on the keyboard's top, up and down with it, and
//  under what the page shows over itself (the command menu).
//
//  It is up wherever the keyboard is for the page, and its keys are the place's the
//  keyboard is for (DocEditingPlace): its leading keys, a gap, its trailing ones, the
//  keyboard's key last.
//  - A block's text: the slash (a "/" typed and the command menu open, even after a
//    word), Aa (the caret's block selected, the format sheet over it) and ⋮ (the caret's
//    block selected), editing going on at the caret once the sheet closes or selecting
//    ends; + (the system's menu of what goes in at the caret, DocInsertMenu), and before
//    it, on an empty line, a divider. Text selected: no slash and no + (they'd type over
//    the text); what selected text takes is the system's text menu's Format.
//  - A table's cell (Craft's): Aa, the cell's menu, f(x), ⋮; a column's name: its menu
//    and ⋮. A code or math block's source: Aa and ⋮. A collection's field: its menu
//    (the right-click's rows) and ⋮.
//
//  Each action has one place. Menus open from their keys. The Mac has no on-screen
//  keyboard and no bar.
//

import FlooUIKit
import SwiftUI
import UIKit
import DocKit

private typealias Metrics = DocTokens.Component.KeyboardBar

@MainActor
final class DocKeyboardBar: UIView {
    private weak var editor: DocEditor?
    private let keys = UIStackView()
    /// The place the keys are for, and which they are; they're made again only when it
    /// changes.
    private var shown: Shown?
    /// Keys shown on.
    private var onKeys: Set<String> = []

    private struct Shown: Equatable {
        var place: AnyHashable
        var keys: [String]
    }

    init(editor: DocEditor) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.height))
        backgroundColor = DocTokens.UIKitColor.canvas
        let hairline = UIView()
        hairline.backgroundColor = DocTokens.UIKitColor.separator
        keys.axis = .horizontal
        keys.alignment = .center
        for view in [hairline, keys] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: DocTokens.Border.hairline),
            keys.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Metrics.inset),
            keys.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Metrics.inset),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let height = Metrics.height

    // MARK: State

    /// Whether the stage shows the bar. While it doesn't (the keyboard is down, or on
    /// the Mac, which has no bar), the keys aren't rebuilt; they catch up when it shows.
    var isOnScreen = false {
        didSet { if isOnScreen, !oldValue { update() } }
    }

    /// Follows the cursor: called when the selection or the place changes, and after a
    /// key's action.
    func update() {
        guard isOnScreen else { return }
        follow()
    }

    private func follow() {
        guard let editor, let place = editor.editingPlace else { return }
        let (leading, trailing) = place.keys(editor)
        let next = Shown(place: place.id, keys: leading.map(\.id) + ["|"] + trailing.map(\.id))
        guard next != shown else { return }
        shown = next
        rebuild(leading: leading, trailing: trailing)
    }

    private func refresh() {
        shown = nil
        follow()
    }

    private func rebuild(leading: [DocBarKey], trailing: [DocBarKey]) {
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        onKeys = []
        keys.distribution = .fill
        leading.forEach { add(button($0)) }
        add(UIView())
        trailing.forEach { add(button($0)) }
        add(dismissKey())
    }

    /// A place's key: its action (the keys follow what it did), or its menu.
    private func button(_ key: DocBarKey) -> UIButton {
        switch key.action {
        case .perform(let perform):
            return self.key(key.id, key.image, key.title) { [weak self] in
                perform()
                self?.refresh()
            }
        case .menu(let menu):
            let button = styled(key.id, key.image, key.title, isOn: false)
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
            // Top to bottom as written, wherever the menu opens.
            button.preferredMenuElementOrder = .fixed
            return button
        }
    }

    // MARK: Keys

    private func add(_ view: UIView) {
        keys.addArrangedSubview(view)
    }

    private func key(_ id: String, _ image: UIImage?, _ title: String, isOn: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = styled(id, image, title, isOn: isOn)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func dismissKey() -> UIButton {
        key("dismiss", UIImage(systemName: "keyboard.chevron.compact.down"), String(localized: "Hide Keyboard")) { [weak self] in
            self?.editor?.dismissKeyboard()
        }
    }

    /// A key (FlooDesign's bar key): the symbol in the bar's ink; on, tinted.
    private func styled(_ id: String, _ image: UIImage?, _ title: String, isOn: Bool) -> UIButton {
        if isOn { onKeys.insert(id) }
        let button = FlooButton(.plain, image: image)
        button.isSelected = isOn
        button.accessibilityLabel = title
        button.accessibilityIdentifier = id
        return button
    }

    // MARK: Glyphs

    /// Craft's: a slash before a page of lines.
    static let slashGlyph: UIImage? = {
        let config = UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.standard, weight: .regular, scale: .medium)
        guard let page = UIImage(systemName: "doc.plaintext", withConfiguration: config) else { return nil }
        let size = CGSize(width: page.size.width + 7, height: page.size.height + 2)
        return UIGraphicsImageRenderer(size: size).image { _ in
            page.draw(at: CGPoint(x: 7, y: 1))
            let slash = UIBezierPath()
            slash.move(to: CGPoint(x: 1, y: size.height - 2))
            slash.addLine(to: CGPoint(x: 11, y: 2))
            slash.lineWidth = 1.6
            slash.lineCapStyle = .round
            slash.stroke()
        }.withRenderingMode(.alwaysTemplate)
    }()

    /// "Aa", as Craft's key has it.
    static let formatGlyph: UIImage = {
        let text = NSAttributedString(string: "Aa", attributes: [.font: UIFont.systemFont(ofSize: 21, weight: .regular)])
        let size = text.size()
        return UIGraphicsImageRenderer(size: size).image { _ in text.draw(at: .zero) }.withRenderingMode(.alwaysTemplate)
    }()

    /// Three dots stacked (the symbol set has them only side by side).
    static let verticalEllipsis: UIImage? = {
        let small = UIImage.SymbolConfiguration(pointSize: DocTokens.Icon.toolbar, weight: .medium, scale: .medium)
        guard let dots = UIImage(systemName: "ellipsis", withConfiguration: small) else { return nil }
        let size = CGSize(width: dots.size.height, height: dots.size.width)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: .pi / 2)
            dots.draw(at: CGPoint(x: -dots.size.width / 2, y: -dots.size.height / 2))
        }.withRenderingMode(.alwaysTemplate)
    }()

    /// "f(x)", as Craft's key in a cell has it: a formula goes in.
    static let formulaGlyph: UIImage = {
        let italic = UIFont.systemFont(ofSize: 19, weight: .regular).fontDescriptor.withSymbolicTraits(.traitItalic)
        let text = NSMutableAttributedString(string: "f", attributes: [.font: italic.map { UIFont(descriptor: $0, size: 19) } ?? UIFont.systemFont(ofSize: 19)])
        text.append(NSAttributedString(string: "(x)", attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .regular)]))
        let size = text.size()
        return UIGraphicsImageRenderer(size: size).image { _ in text.draw(at: .zero) }.withRenderingMode(.alwaysTemplate)
    }()

    /// A long thin rule, as the divider it puts in.
    static let dividerGlyph: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 52, height: 18)).image { _ in
        UIBezierPath(roundedRect: CGRect(x: 0, y: 8.5, width: 52, height: 1), cornerRadius: 0.5).fill()
    }.withRenderingMode(.alwaysTemplate)

    // MARK: Tests

    /// The keys shown, by identifier, and which are on.
    var testItems: [(id: String, isOn: Bool)] {
        follow()
        return keys.arrangedSubviews.compactMap { $0 as? UIButton }.map { ($0.accessibilityIdentifier ?? "", onKeys.contains($0.accessibilityIdentifier ?? "")) }
    }

    /// Taps a key; for a menu key, chooses the item with this title.
    func testTap(_ id: String, choosing title: String? = nil) {
        follow()
        guard let button = keys.arrangedSubviews.compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == id }) else { return }
        guard let title else { return button.sendActions(for: .touchUpInside) }
        func actions(_ menu: UIMenu?) -> [UIAction] {
            (menu?.children ?? []).flatMap { ($0 as? UIAction).map { [$0] } ?? actions($0 as? UIMenu) }
        }
        actions(button.menu).first { $0.title == title }?.performWithSender(nil, target: nil)
    }
}

/// The keyboard bar on the page: on the keyboard's top, its white on down under the
/// keyboard, while it's up; else below the window's bottom. It is placed in the
/// keyboard's own animation (its duration and curve), so it rises and falls with the
/// keyboard, from behind it. Over the whole page, under the command menu; only the bar
/// takes touches.
final class DocKeyboardBarStage: UIView {
    let bar: DocKeyboardBar
    /// The bar's white under the keyboard.
    private let under = UIView()
    private(set) var isShown = false
    /// The keyboard's frame in the window.
    private var keyboard: CGRect = .null

    init(bar: DocKeyboardBar) {
        self.bar = bar
        super.init(frame: .zero)
        under.backgroundColor = DocTokens.UIKitColor.canvas
        addSubview(under)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Follows the keyboard, in its animation when it has one.
    func place(shows: Bool, keyboard: CGRect, duration: Double?, curve: UInt?) {
        isShown = shows
        self.keyboard = keyboard
        bar.isOnScreen = shows
        bar.accessibilityElementsHidden = !shows
        guard let duration, duration > 0, window != nil else { return setNeedsLayout() }
        layoutIfNeeded()
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: (curve ?? 7) << 16), .beginFromCurrentState]) {
            self.placeBar()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeBar()
    }

    private func placeBar() {
        guard let window else { return }
        let height = DocKeyboardBar.height
        let top = isShown && !keyboard.isNull ? convert(keyboard, from: window).minY - height
            : convert(CGPoint(x: 0, y: window.bounds.maxY), from: window).y
        bar.frame = CGRect(x: 0, y: top, width: bounds.width, height: height)
        under.frame = CGRect(x: 0, y: top + height, width: bounds.width, height: window.bounds.height)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isShown, let hit = super.hitTest(point, with: event), hit !== self, hit !== under else { return nil }
        return hit
    }
}

struct DocKeyboardBarHost: UIViewRepresentable {
    let stage: DocKeyboardBarStage
    func makeUIView(context: Context) -> DocKeyboardBarStage { stage }
    func updateUIView(_ view: DocKeyboardBarStage, context: Context) {}
}

extension DocEditor {
    /// The bar's insert: an empty line becomes the block; otherwise a new block goes
    /// after this one, the cursor in it.
    func insert(_ action: DocCommand.Action, at block: DocBlock) {
        guard case .kind(let kind) = action, !block.text.isEmpty else {
            let head = selection?.head ?? DocPosition(block: block.id, offset: block.text.length)
            return perform(action, in: block, replacing: head.offset..<head.offset, from: head)
        }
        let id = demo.newBlockID()
        let caret = DocPosition(block: id, offset: 0)
        let here = selection ?? DocSelection(anchor: caret, head: caret)
        commitSlash([.insertBlock(block: DocBlock(id: id, kind: kind, indent: block.indent), after: block.id)], from: here, to: DocSelection(anchor: caret, head: caret))
    }
}
