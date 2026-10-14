//
//  DocKeyboardBar.swift
//  DemoApp
//
//  The bar over a phone's keyboard, laid out as Craft's: a white strip with a hairline
//  on top, the page's width. As Craft's, it is the page's, not the keyboard's (no input
//  accessory): over the page's bottom, on the keyboard's top, up and down with it, and
//  under what the page shows over itself (the command menu).
//
//  - Text selected: highlight, bold, italic, strikethrough, code, link and the keyboard
//    key, spread evenly; a mark all of the selection has sits on a light tint. The
//    highlight key opens the colours over it (text colours, highlights).
//  - A cursor: the slash (a "/" typed and the command menu open, even after a word), Aa (the caret's block selected,
//    the format sheet over it) and ⋮ (the caret's block selected) on the left, editing
//    going on at the caret once the sheet closes or selecting ends; the keyboard key on
//    the right. On an empty line a divider key comes in between.
//
//  Each action has one place. Menus open from their keys. The Mac has no on-screen
//  keyboard and no bar.
//

import SwiftUI
import UIKit
import DocKit
import FlooDesign

private typealias Metrics = FlooDesignTokens.Component.KeyboardBar

@MainActor
final class DocKeyboardBar: UIView {
    private weak var editor: DocEditor?
    private let keys = UIStackView()
    /// What the keys show now; they're rebuilt only when it changes.
    private var shown: Shown?
    /// Keys shown on: marks all of the selection has, the list style in use.
    private var onKeys: Set<String> = []

    private enum Shown: Equatable {
        case selection(block: DocBlockID, range: Range<Int>, marks: Set<MarkKind>)
        case cursor(block: DocBlockID, kind: BlockKind, indent: Int, isEmpty: Bool)
    }

    /// The colours over the highlight key, in the document's window.
    private let colors = FlooDesignAnchoredPanelPresenter()
    private let colorsAnchor = UIView()
    private(set) var showsColors = false

    init(editor: DocEditor) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.height))
        backgroundColor = FlooDesignTokens.UIKitColor.canvas
        let hairline = UIView()
        hairline.backgroundColor = FlooDesignTokens.UIKitColor.separator
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
            hairline.heightAnchor.constraint(equalToConstant: FlooDesignTokens.Border.hairline),
            keys.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Metrics.inset),
            keys.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Metrics.inset),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let height = Metrics.height

    // MARK: State

    /// Follows the cursor: called when the selection changes, and after a key's action.
    func update() {
        guard let editor, let selection = editor.selection, let block = editor.textBlock(selection.head.block) else { return }
        let next: Shown
        if selection.anchor.block == selection.head.block, selection.anchor.offset != selection.head.offset, block.kind.allowsMarks {
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            let marks = Set(Self.marks.map(\.mark.kind) + [.link]).filter { DocEditor.covers(block.text, range, with: $0) }
            next = .selection(block: block.id, range: range, marks: marks)
        } else {
            next = .cursor(block: block.id, kind: block.kind, indent: block.indent, isEmpty: block.text.isEmpty)
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
        case .cursor(_, _, _, let isEmpty):
            keys.distribution = .fill
            add(key("slash", Self.slashGlyph, String(localized: "Commands")) { [weak self] in
                self?.editor?.typeSlash()
            })
            add(key("format", Self.formatGlyph, String(localized: "Format")) { [weak self] in
                self?.editor?.blocks.formatCaretBlock()
            })
            add(key("more", Self.verticalEllipsis, String(localized: "Select Block")) { [weak self] in
                self?.editor?.blocks.selectCaretBlock()
            })
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
        let button = FlooDesignBarKey.button(image, isOn: isOn)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = id
        return button
    }

    // MARK: Colours

    /// The colours over the highlight key, in the document's window.
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
        FlooDesignBarKey.setOn(button, isOn)
    }

    // MARK: Glyphs

    /// Craft's: a slash before a page of lines.
    private static let slashGlyph: UIImage? = {
        let config = UIImage.SymbolConfiguration(pointSize: FlooDesignTokens.Icon.standard, weight: .regular, scale: .medium)
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
        let small = UIImage.SymbolConfiguration(pointSize: FlooDesignTokens.Icon.toolbar, weight: .medium, scale: .medium)
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
        under.backgroundColor = FlooDesignTokens.UIKitColor.canvas
        addSubview(under)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Follows the keyboard, in its animation when it has one.
    func place(shows: Bool, keyboard: CGRect, duration: Double?, curve: UInt?) {
        isShown = shows
        self.keyboard = keyboard
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
        commitSlash([.insertBlock(block: DocBlock(id: id, kind: kind), after: block.id)], from: here, to: DocSelection(anchor: caret, head: caret))
    }
}
