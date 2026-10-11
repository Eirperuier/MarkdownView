//
//  DocKeyboardBar.swift
//  DemoApp
//
//  The bar over a phone's keyboard, laid out as Craft's: a white strip with a hairline
//  on top, the keyboard's own width.
//
//  - Text selected: highlight, bold, italic, strikethrough, code, link and the keyboard
//    key, spread evenly; a mark all of the selection has sits on a light tint. The
//    highlight key opens the colours over it (text colours, highlights).
//  - A cursor: the slash (the slash menu, as "/" typed), Aa (the format sheet in the
//    keyboard's place, again for the keyboard) and more (indent, undo, redo) on the
//    left; the keyboard key on the right. On an empty line a divider key comes in between.
//
//  Each action has one place. Menus open from their keys. The Mac has no on-screen
//  keyboard and no bar.
//

import SwiftUI
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
        case cursor(block: DocBlockID, kind: BlockKind, indent: Int, isEmpty: Bool, canUndo: Bool, canRedo: Bool, formatting: Bool)
    }

    /// The colours over the highlight key, in the document's window.
    private let colors = DocAnchoredPanelPresenter()
    private let colorsAnchor = UIView()
    private(set) var showsColors = false

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
                           canUndo: editor.demo.canUndo, canRedo: editor.demo.canRedo, formatting: editor.showsFormatInput)
        }
        guard next != shown else { return }
        hideColors()
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
            let highlight = key("highlight", UIImage(systemName: "highlighter"), String(localized: "Highlight"), isOn: marks.contains(.highlight)) {}
            highlight.addAction(UIAction { [weak self, weak highlight] _ in
                guard let self, let highlight else { return }
                if self.showsColors { return self.hideColors() }
                self.showColors(from: highlight, block: block.id, range: range)
            }, for: .touchUpInside)
            add(highlight)
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
        case .cursor(_, _, _, let isEmpty, let canUndo, let canRedo, let formatting):
            keys.distribution = .fill
            add(key("slash", Self.slashGlyph, String(localized: "Insert")) { [weak self] in
                self?.editor?.typeSlash()
            })
            add(key("format", Self.formatGlyph, String(localized: "Format"), isOn: formatting) { [weak self] in
                self?.editor?.toggleFormatInput()
            })
            add(menuKey("more", Self.verticalEllipsis, String(localized: "More"), menu: moreMenu(block, canUndo: canUndo, canRedo: canRedo)))
            add(UIView())
            if isEmpty {
                add(key("divider", Self.dividerGlyph, String(localized: "Divider")) { [weak self] in
                    self?.editor?.perform(.divider, in: block, replacing: 0..<0, from: DocPosition(block: block.id, offset: 0))
                    self?.refresh()
                })
            }
            add(dismissKey())
        }
    }

    // MARK: Menus

    private static let marks: [(id: String, symbol: String, title: String, mark: Mark)] = [
        ("bold", "bold", String(localized: "Bold"), .bold),
        ("italic", "italic", String(localized: "Italic"), .italic),
        ("strike", "strikethrough", String(localized: "Strikethrough"), .strike),
        ("code", "chevron.left.forwardslash.chevron.right", String(localized: "Code"), .code),
    ]

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

    // MARK: Colours

    /// The colours over the highlight key. The bar is in the keyboard's window; they go
    /// in the document's, over the key.
    private func showColors(from key: UIButton, block: DocBlockID, range: Range<Int>) {
        guard let editor, let window = editor.textView(for: block)?.window else { return }
        colorsAnchor.isUserInteractionEnabled = false
        colorsAnchor.frame = window.convert(key.bounds, from: key)
        window.addSubview(colorsAnchor)
        colors.anchorView = colorsAnchor
        colors.show(
            configuration: .init(preferredEdge: .above, horizontalAlignment: .leading, windowMargin: FlooDesignTokens.Space.sm),
            content: AnyView(DocColorsPopover(editor: editor, block: block, range: range) { [weak self] in
                self?.hideColors()
                self?.refresh()
            }),
            onRequestDismiss: { [weak self] in self?.hideColors() }
        )
        showsColors = true
        setOn(key, true)
    }

    private func hideColors() {
        guard showsColors else { return }
        showsColors = false
        colors.hide()
        colorsAnchor.removeFromSuperview()
        if let key = keys.arrangedSubviews.compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "highlight" }) {
            setOn(key, onKeys.contains("highlight"))
        }
    }

    private func setOn(_ button: UIButton, _ isOn: Bool) {
        button.configuration?.baseForegroundColor = isOn ? .tintColor : Self.ink
        button.configuration?.background.backgroundColor = isOn ? UIColor.tintColor.withAlphaComponent(0.12) : .clear
    }

    // MARK: Glyphs

    /// Craft's: a slash before a page of lines.
    private static let slashGlyph: UIImage? = {
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular, scale: .medium)
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
    private static let formatGlyph: UIImage = {
        let text = NSAttributedString(string: "Aa", attributes: [.font: UIFont.systemFont(ofSize: 21, weight: .regular)])
        let size = text.size()
        return UIGraphicsImageRenderer(size: size).image { _ in text.draw(at: .zero) }.withRenderingMode(.alwaysTemplate)
    }()

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
