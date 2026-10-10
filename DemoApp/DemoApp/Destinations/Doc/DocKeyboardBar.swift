//
//  DocKeyboardBar.swift
//  DemoApp
//
//  The bar over a phone's keyboard, as Craft has it: what can be done where the cursor
//  is. With text selected: highlight, bold, italic, strikethrough, code, link (on when
//  all of the selection has it). With a cursor: turn the block into another kind,
//  indent a list item, insert a block, undo; on an empty line inserting comes first.
//  Menus open from their buttons. The Mac has no on-screen keyboard: its menus and
//  keys do all this.
//

import UIKit
import DocKit

@MainActor
final class DocKeyboardBar: UIInputView {
    private weak var editor: DocEditor?
    private let items = UIStackView()
    /// A glass capsule the buttons sit on, clear of the text behind it.
    private let plate: UIVisualEffectView = {
        if #available(iOS 26.0, *) {
            // Tinted toward the page: text scrolling behind it doesn't show through.
            let glass = UIGlassEffect()
            glass.tintColor = UIColor.systemBackground.withAlphaComponent(0.75)
            let plate = UIVisualEffectView(effect: glass)
            plate.cornerConfiguration = .capsule()
            return plate
        }
        let plate = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        plate.layer.cornerRadius = 22
        plate.layer.cornerCurve = .continuous
        plate.clipsToBounds = true
        return plate
    }()
    private let dismiss = UIButton(type: .system)
    /// What the buttons show now; they're rebuilt only when it changes.
    private var shown: Shown?
    /// The buttons shown on (marks the whole selection has, the empty line's insert).
    private var onIDs: Set<String> = []

    private enum Shown: Equatable {
        /// Text selected in a block: the marks all of it has.
        case marks(block: DocBlockID, range: Range<Int>, on: Set<MarkKind>)
        /// A cursor in a block of this kind (empty or not), and what undo can do.
        case cursor(block: DocBlockID, kind: BlockKind, indent: Int, isEmpty: Bool, canUndo: Bool)
    }

    init(editor: DocEditor) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 56), inputViewStyle: .default)
        backgroundColor = .clear
        allowsSelfSizing = true
        items.axis = .horizontal
        items.spacing = 2
        items.alignment = .center
        items.translatesAutoresizingMaskIntoConstraints = false
        dismiss.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismiss.tintColor = .label
        dismiss.accessibilityLabel = "收起键盘"
        dismiss.accessibilityIdentifier = "dismiss"
        dismiss.addAction(UIAction { [weak self] _ in self?.window?.endEditing(true) }, for: .touchUpInside)
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)
        plate.contentView.addSubview(items)
        plate.contentView.addSubview(dismiss)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            plate.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 10),
            plate.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10),
            plate.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            items.leadingAnchor.constraint(equalTo: plate.contentView.leadingAnchor, constant: 8),
            items.centerYAnchor.constraint(equalTo: plate.contentView.centerYAnchor),
            items.trailingAnchor.constraint(lessThanOrEqualTo: dismiss.leadingAnchor, constant: -4),
            dismiss.trailingAnchor.constraint(equalTo: plate.contentView.trailingAnchor, constant: -6),
            dismiss.centerYAnchor.constraint(equalTo: plate.contentView.centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 44),
            dismiss.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: State

    /// Follows the cursor: called when the selection or the document changes.
    func update() {
        guard let editor, let selection = editor.selection, let block = editor.demo.doc.block(selection.head.block) else { return }
        let next: Shown
        if selection.anchor.block == selection.head.block, selection.anchor.offset != selection.head.offset, block.kind.allowsMarks {
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            let on = Set([MarkKind.highlight, .bold, .italic, .strike, .code, .link].filter { DocEditor.covers(block.text, range, with: $0) })
            next = .marks(block: block.id, range: range, on: on)
        } else {
            next = .cursor(block: block.id, kind: block.kind, indent: block.indent, isEmpty: block.text.isEmpty, canUndo: editor.demo.canUndo)
        }
        guard next != shown else { return }
        shown = next
        rebuild(next, block: block)
    }

    private func rebuild(_ shown: Shown, block: DocBlock) {
        items.arrangedSubviews.forEach { $0.removeFromSuperview() }
        onIDs = []
        switch shown {
        case .marks(_, let range, let on):
            for (id, symbol, title, mark) in Self.marks {
                items.addArrangedSubview(button(id: id, symbol: symbol, title: title, isOn: on.contains(mark.kind)) { [weak self] in
                    self?.editor?.toggle(mark, over: range, in: block.id)
                    self?.refresh()
                })
            }
            items.addArrangedSubview(button(id: "link", symbol: "link", title: "链接", isOn: on.contains(.link)) { [weak self] in
                guard let self, let editor = self.editor, let view = editor.textView(for: block.id) else { return }
                editor.promptLink(over: range, in: block.id, from: view)
            })
        case .cursor(_, let kind, _, let isEmpty, let canUndo):
            let insert = menuButton(id: "insert", symbol: "plus", title: "插入", prominent: isEmpty, menu: insertMenu(after: block))
            if isEmpty { items.addArrangedSubview(insert) }
            items.addArrangedSubview(menuButton(id: "turn", symbol: Self.symbol(for: kind), title: "转换", menu: turnMenu(block)))
            if case .listItem = kind {
                items.addArrangedSubview(button(id: "outdent", symbol: "decrease.indent", title: "减少缩进", isEnabled: block.indent > 0) { [weak self] in
                    self?.editor?.indent(block, by: -1)
                    self?.refresh()
                })
                items.addArrangedSubview(button(id: "indent", symbol: "increase.indent", title: "增加缩进") { [weak self] in
                    self?.editor?.indent(block, by: 1)
                    self?.refresh()
                })
            }
            if !isEmpty { items.addArrangedSubview(insert) }
            items.addArrangedSubview(button(id: "undo", symbol: "arrow.uturn.backward", title: "撤销", isEnabled: canUndo) { [weak self] in
                self?.editor?.requestUndo()
                self?.refresh()
            })
        }
    }

    /// The model changed under the same selection (a mark, an indent): show it.
    private func refresh() {
        shown = nil
        update()
    }

    // MARK: Menus

    private static let marks: [(String, String, String, Mark)] = [
        ("highlight", "highlighter", "高亮", .highlight(color: nil)),
        ("bold", "bold", "加粗", .bold),
        ("italic", "italic", "斜体", .italic),
        ("strike", "strikethrough", "删除线", .strike),
        ("code", "chevron.left.forwardslash.chevron.right", "代码", .code),
    ]

    /// The kinds a text block can become, as the slash menu lists them.
    private static var kinds: [DocSlashItem] {
        DocSlashItem.all.filter { $0.action.kind?.carriesText == true }
    }

    private static func symbol(for kind: BlockKind) -> String {
        let same = kinds.first { item in
            guard let other = item.action.kind else { return false }
            switch (other, kind) {
            case (.listItem(let a), .listItem(let b)):
                switch (a, b) {
                case (.bullet, .bullet), (.numbered, .numbered), (.task, .task), (.toggle, .toggle): return true
                default: return false
                }
            case (.code, .code): return true
            default: return other == kind
            }
        }
        return same?.symbol ?? "text.alignleft"
    }

    /// Turn the block into another kind; its text stays.
    private func turnMenu(_ block: DocBlock) -> UIMenu {
        let current = Self.symbol(for: block.kind)
        let actions = Self.kinds.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol), state: item.symbol == current ? .on : .off) { [weak self] _ in
                guard let self, let editor = self.editor, let action = item.action.kind, let block = editor.demo.doc.block(block.id) else { return }
                let caret = editor.selection?.head ?? DocPosition(block: block.id, offset: block.text.length)
                editor.perform(.kind(action), in: block, replacing: caret.offset..<caret.offset, from: caret)
                self.refresh()
            }
        }
        return UIMenu(title: "转换为", children: actions)
    }

    /// A new block after this one (or this empty line becomes it); a divider or table.
    private func insertMenu(after block: DocBlock) -> UIMenu {
        let blocks: [DocSlashItem] = ["table", "divider", "code", "math", "task", "quote", "h2"].compactMap { id in
            DocSlashItem.all.first { $0.id == id }
        }
        let actions = blocks.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol)) { [weak self] _ in
                guard let self, let editor = self.editor, let block = editor.demo.doc.block(block.id) else { return }
                editor.insert(item.action, at: block)
                self.refresh()
            }
        }
        return UIMenu(title: "插入", children: actions)
    }

    // MARK: Buttons

    private func button(id: String, symbol: String, title: String, isOn: Bool = false, isEnabled: Bool = true,
                        action: @escaping () -> Void) -> UIButton {
        let button = styled(id: id, symbol: symbol, title: title, filled: isOn)
        button.isEnabled = isEnabled
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func menuButton(id: String, symbol: String, title: String, prominent: Bool = false, menu: UIMenu) -> UIButton {
        let button = styled(id: id, symbol: symbol, title: title, filled: prominent)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func styled(id: String, symbol: String, title: String, filled: Bool) -> UIButton {
        if filled { onIDs.insert(id) }
        var configuration = filled ? UIButton.Configuration.tinted() : .plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        configuration.baseForegroundColor = filled ? .tintColor : .label
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = id
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return button
    }

    // MARK: Tests

    /// The buttons shown, by identifier, and which are on.
    var testItems: [(id: String, isOn: Bool)] {
        items.arrangedSubviews.compactMap { $0 as? UIButton }.map {
            let id = $0.accessibilityIdentifier ?? ""
            return (id, onIDs.contains(id))
        }
    }

    /// Taps a button; for a menu, chooses the item with this title.
    func testTap(_ id: String, choosing title: String? = nil) {
        guard let button = items.arrangedSubviews.compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == id }) else { return }
        if let title, let action = button.menu?.children.compactMap({ $0 as? UIAction }).first(where: { $0.title == title }) {
            action.performWithSender(nil, target: nil)
        } else {
            button.sendActions(for: .touchUpInside)
        }
    }
}

extension DocEditor {
    /// The keyboard bar's insert: on an empty line it becomes the block; otherwise a new
    /// block goes after this one (a list item keeps the list's level), the cursor in it.
    func insert(_ action: DocSlashItem.Action, at block: DocBlock) {
        guard case .kind(let kind) = action, !block.text.isEmpty else {
            let head = selection?.head ?? DocPosition(block: block.id, offset: block.text.length)
            return perform(action, in: block, replacing: head.offset..<head.offset, from: head)
        }
        let id = demo.newBlockID()
        let indent = if case .listItem = kind, case .listItem = block.kind { block.indent } else { 0 }
        let caret = DocPosition(block: id, offset: 0)
        let here = selection ?? DocSelection(anchor: caret, head: caret)
        commitSlash([.insertBlock(block: DocBlock(id: id, kind: kind, indent: indent), after: block.id)],
                    from: here, to: DocSelection(anchor: caret, head: caret))
    }
}
