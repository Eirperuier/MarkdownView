//
//  DocKeyboardBar.swift
//  DemoApp
//
//  The bar over a phone's keyboard, laid out as Craft's: a white strip with a hairline
//  on top, the keyboard's own width.
//
//  - Text selected: highlight, bold, italic, strikethrough, code, link and the keyboard
//    key, spread evenly; a mark all of the selection has sits on a light tint.
//  - A cursor: lists, text styles and more (indent, undo, redo) on the left; insert and
//    the keyboard key on the right. On an empty line a divider key comes in between.
//
//  Each action has one place. Menus open from their keys. The Mac has no on-screen
//  keyboard and no bar.
//

import UIKit
import DocKit

@MainActor
final class DocKeyboardBar: UIInputView {
    private weak var editor: DocEditor?
    private let keys = UIStackView()
    /// What the keys show now; they're rebuilt only when it changes.
    private var shown: Shown?
    /// Keys shown on: marks all of the selection has, the list style in use.
    private var onKeys: Set<String> = []

    private enum Shown: Equatable {
        case selection(block: DocBlockID, range: Range<Int>, marks: Set<MarkKind>)
        case cursor(block: DocBlockID, kind: BlockKind, indent: Int, isEmpty: Bool, canUndo: Bool, canRedo: Bool)
    }

    init(editor: DocEditor) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .systemBackground
        let hairline = UIView()
        hairline.backgroundColor = .separator
        keys.axis = .horizontal
        keys.alignment = .center
        for view in [hairline, keys] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            keys.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            keys.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let height: CGFloat = 46
    private static let keySize = CGSize(width: 50, height: 40)
    /// Craft's: symbols about 19 pt, regular, a dark gray rather than black.
    private static let symbols = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular, scale: .medium)
    private static let ink = UIColor.label.withAlphaComponent(0.82)

    // MARK: State

    /// Follows the cursor: called when the selection changes, and after a key's action.
    func update() {
        guard let editor, let selection = editor.selection, let block = editor.demo.doc.block(selection.head.block) else { return }
        let next: Shown
        if selection.anchor.block == selection.head.block, selection.anchor.offset != selection.head.offset, block.kind.allowsMarks {
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            let marks = Set(Self.marks.map(\.mark.kind) + [.link]).filter { DocEditor.covers(block.text, range, with: $0) }
            next = .selection(block: block.id, range: range, marks: marks)
        } else {
            next = .cursor(block: block.id, kind: block.kind, indent: block.indent, isEmpty: block.text.isEmpty,
                           canUndo: editor.demo.canUndo, canRedo: editor.demo.canRedo)
        }
        guard next != shown else { return }
        shown = next
        rebuild(next, block: block)
    }

    private func refresh() {
        shown = nil
        update()
    }

    private func rebuild(_ shown: Shown, block: DocBlock) {
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        onKeys = []
        switch shown {
        case .selection(_, let range, let marks):
            keys.distribution = .equalSpacing
            for item in Self.marks {
                add(key(item.id, UIImage(systemName: item.symbol), item.title, isOn: marks.contains(item.mark.kind)) { [weak self] in
                    self?.editor?.toggle(item.mark, over: range, in: block.id)
                    self?.refresh()
                })
            }
            add(key("link", UIImage(systemName: "link"), String(localized: "Link"), isOn: marks.contains(.link)) { [weak self] in
                guard let editor = self?.editor, let view = editor.textView(for: block.id) else { return }
                editor.promptLink(over: range, in: block.id, from: view)
            })
            add(dismissKey())
        case .cursor(_, let kind, _, let isEmpty, let canUndo, let canRedo):
            keys.distribution = .fill
            let isList = if case .listItem = kind { true } else { false }
            add(menuKey("lists", UIImage(systemName: "list.bullet"), String(localized: "List"), isOn: isList, menu: kindMenu(Self.listKinds, block: block)))
            add(menuKey("styles", UIImage(systemName: "textformat"), String(localized: "Text Style"), menu: kindMenu(Self.textKinds, block: block)))
            add(menuKey("more", Self.verticalEllipsis, String(localized: "More"), menu: moreMenu(block, canUndo: canUndo, canRedo: canRedo)))
            add(UIView())
            if isEmpty {
                add(key("divider", Self.dividerGlyph, String(localized: "Divider")) { [weak self] in
                    self?.editor?.perform(.divider, in: block, replacing: 0..<0, from: DocPosition(block: block.id, offset: 0))
                    self?.refresh()
                })
            }
            add(menuKey("insert", UIImage(systemName: "plus"), String(localized: "Insert"), menu: insertMenu(block)))
            add(dismissKey())
        }
    }

    // MARK: Menus

    private static let marks: [(id: String, symbol: String, title: String, mark: Mark)] = [
        ("highlight", "highlighter", String(localized: "Highlight"), .highlight(color: nil)),
        ("bold", "bold", String(localized: "Bold"), .bold),
        ("italic", "italic", String(localized: "Italic"), .italic),
        ("strike", "strikethrough", String(localized: "Strikethrough"), .strike),
        ("code", "chevron.left.forwardslash.chevron.right", String(localized: "Code"), .code),
    ]

    private static let listKinds = ["bullet", "numbered", "task", "toggle"]
    private static let textKinds = ["paragraph", "h1", "h2", "h3", "quote", "code", "math"]

    /// The block becomes one of these kinds (the slash menu's), its text kept.
    private func kindMenu(_ ids: [String], block: DocBlock) -> UIMenu {
        UIMenu(children: ids.compactMap { id in DocSlashItem.all.first { $0.id == id } }.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol), state: Self.isKind(item, of: block) ? .on : .off) { [weak self] _ in
                guard let editor = self?.editor, let block = editor.demo.doc.block(block.id) else { return }
                let caret = editor.selection?.head ?? DocPosition(block: block.id, offset: block.text.length)
                editor.perform(item.action, in: block, replacing: caret.offset..<caret.offset, from: caret)
                self?.refresh()
            }
        })
    }

    private func moreMenu(_ block: DocBlock, canUndo: Bool, canRedo: Bool) -> UIMenu {
        var indent: [UIMenuElement] = []
        if case .listItem = block.kind {
            indent = [
                UIAction(title: String(localized: "Indent"), image: UIImage(systemName: "increase.indent")) { [weak self] _ in
                    self?.editor?.indent(block, by: 1)
                    self?.refresh()
                },
                UIAction(title: String(localized: "Outdent"), image: UIImage(systemName: "decrease.indent"), attributes: block.indent > 0 ? [] : .disabled) { [weak self] _ in
                    self?.editor?.indent(block, by: -1)
                    self?.refresh()
                },
            ]
        }
        let history: [UIMenuElement] = [
            UIAction(title: String(localized: "Undo"), image: UIImage(systemName: "arrow.uturn.backward"), attributes: canUndo ? [] : .disabled) { [weak self] _ in
                self?.editor?.requestUndo()
                self?.refresh()
            },
            UIAction(title: String(localized: "Redo"), image: UIImage(systemName: "arrow.uturn.forward"), attributes: canRedo ? [] : .disabled) { [weak self] _ in
                self?.editor?.requestRedo()
                self?.refresh()
            },
        ]
        return UIMenu(children: [UIMenu(options: .displayInline, children: indent), UIMenu(options: .displayInline, children: history)])
    }

    /// Blocks that aren't a kind of text: a table, code, math.
    private func insertMenu(_ block: DocBlock) -> UIMenu {
        UIMenu(children: ["table", "code", "math"].compactMap { id in DocSlashItem.all.first { $0.id == id } }.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol)) { [weak self] _ in
                guard let editor = self?.editor, let block = editor.demo.doc.block(block.id) else { return }
                editor.insert(item.action, at: block)
                self?.refresh()
            }
        })
    }

    private static func isKind(_ item: DocSlashItem, of block: DocBlock) -> Bool {
        switch (item.action.kind, block.kind) {
        case (.listItem(let a)?, .listItem(let b)):
            switch (a, b) {
            case (.bullet, .bullet), (.numbered, .numbered), (.task, .task), (.toggle, .toggle): true
            default: false
            }
        case (.code?, .code): true
        case (let kind?, _): kind == block.kind
        default: false
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

    private func menuKey(_ id: String, _ image: UIImage?, _ title: String, isOn: Bool = false, menu: UIMenu) -> UIButton {
        let button = styled(id, image, title, isOn: isOn)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func dismissKey() -> UIButton {
        key("dismiss", UIImage(systemName: "keyboard.chevron.compact.down"), String(localized: "Hide Keyboard")) { [weak self] in
            self?.window?.endEditing(true)
        }
    }

    /// A key: the symbol in dark gray; on, it's tinted, on a light tint of its own.
    private func styled(_ id: String, _ image: UIImage?, _ title: String, isOn: Bool) -> UIButton {
        if isOn { onKeys.insert(id) }
        var configuration = UIButton.Configuration.plain()
        configuration.image = image
        configuration.preferredSymbolConfigurationForImage = Self.symbols
        configuration.baseForegroundColor = isOn ? .tintColor : Self.ink
        configuration.background.backgroundColor = isOn ? UIColor.tintColor.withAlphaComponent(0.12) : .clear
        configuration.background.cornerRadius = 12
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = id
        NSLayoutConstraint.activate([
            // A glyph wider than a key (the divider's rule) widens its key.
            button.widthAnchor.constraint(equalToConstant: max(Self.keySize.width, (image?.size.width ?? 0) + 12)),
            button.heightAnchor.constraint(equalToConstant: Self.keySize.height),
        ])
        return button
    }

    /// Three dots stacked (the symbol set has them only side by side).
    private static let verticalEllipsis: UIImage? = {
        let small = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium, scale: .medium)
        guard let dots = UIImage(systemName: "ellipsis", withConfiguration: small) else { return nil }
        let size = CGSize(width: dots.size.height, height: dots.size.width)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: .pi / 2)
            dots.draw(at: CGPoint(x: -dots.size.width / 2, y: -dots.size.height / 2))
        }.withRenderingMode(.alwaysTemplate)
    }()

    /// A long thin rule, as the divider it puts in.
    private static let dividerGlyph: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 52, height: 18)).image { _ in
        UIBezierPath(roundedRect: CGRect(x: 0, y: 8.5, width: 52, height: 1), cornerRadius: 0.5).fill()
    }.withRenderingMode(.alwaysTemplate)

    // MARK: Tests

    /// The keys shown, by identifier, and which are on.
    var testItems: [(id: String, isOn: Bool)] {
        keys.arrangedSubviews.compactMap { $0 as? UIButton }.map { ($0.accessibilityIdentifier ?? "", onKeys.contains($0.accessibilityIdentifier ?? "")) }
    }

    /// Taps a key; for a menu key, chooses the item with this title.
    func testTap(_ id: String, choosing title: String? = nil) {
        guard let button = keys.arrangedSubviews.compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == id }) else { return }
        guard let title else { return button.sendActions(for: .touchUpInside) }
        func actions(_ menu: UIMenu?) -> [UIAction] {
            (menu?.children ?? []).flatMap { ($0 as? UIAction).map { [$0] } ?? actions($0 as? UIMenu) }
        }
        actions(button.menu).first { $0.title == title }?.performWithSender(nil, target: nil)
    }
}

extension DocEditor {
    /// The bar's insert: an empty line becomes the block; otherwise a new block goes
    /// after this one, the cursor in it.
    func insert(_ action: DocSlashItem.Action, at block: DocBlock) {
        guard case .kind(let kind) = action, !block.text.isEmpty else {
            let head = selection?.head ?? DocPosition(block: block.id, offset: block.text.length)
            return perform(action, in: block, replacing: head.offset..<head.offset, from: head)
        }
        let id = demo.newBlockID()
        let caret = DocPosition(block: id, offset: 0)
        let here = selection ?? DocSelection(anchor: caret, head: caret)
        commitSlash([.insertBlock(block: DocBlock(id: id, kind: kind), after: block.id)], from: here, to: DocSelection(anchor: caret, head: caret))
    }
}
