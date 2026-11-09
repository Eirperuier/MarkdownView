//
//  DocMathRowUIKit.swift
//  DemoApp
//
//  A math block as a UIKit row: MarkdownUIKit's formula; while it's edited, ringed (a cell's
//  formula's way), its LaTeX in a panel: on the Mac under it (the anchored panel), on a phone
//  over the keyboard (DocMathKeyboardPanel, the page's). Empty, it says to enter LaTeX.
//

import DocKit
import FlooUIKit
import MarkdownUIKit
import MessagingUI
import Observation
import UIKit

/// A math row's content: its block, its LaTeX, and who edits it.
@MainActor
struct DocMathRowContent: TiledUIKitCellContent {
    /// Its row runs a reshape's animation and the rows round it move in its frames.
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let block: DocBlockID
    let latex: String
    let sources: DocSourceController

    static func makeRowView() -> DocMathRowView { DocMathRowView() }

    func configure(_ view: DocMathRowView, context: TiledUIKitCellContext) {
        view.show(row, block: block, latex: latex, sources: sources, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocMathRowView.height(of: row, latex: latex, width: width)
    }

    static func prepareForReuse(_ view: DocMathRowView) {
        view.reset()
    }
}

@MainActor
final class DocMathRowView: DocRowUIKitView {
    private let math = DocMathView()
    private lazy var panel: FlooPanelAnchorView = {
        let anchor = FlooPanelAnchorView { [weak self] _, _ in
            guard let self, let block = self.block, let sources = self.sources else { return UIViewController() }
            return DocMathPage(block: block, controller: sources)
        }
        anchor.options.selfDrawn = true
        anchor.update = { [weak self] page, _, _ in
            guard let self, let block = self.block, let sources = self.sources else { return }
            (page as? DocMathPage)?.show(sources.text(block))
        }
        anchor.onDismiss = { [weak self] in
            guard let self, let block = self.block else { return }
            self.sources?.dismiss(block)
        }
        math.addSubview(anchor)
        return anchor
    }()
    private var block: DocBlockID?
    private weak var sources: DocSourceController?

    init() {
        super.init(content: math)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        math.addGestureRecognizer(tap)
    }

    func show(_ row: DocRow, block: DocBlockID, latex: String, sources: DocSourceController, context: TiledUIKitCellContext) {
        if self.block != block { panel.close() }
        self.block = block
        self.sources = sources
        take(row, blocks: sources.editor.blocks, context: context)
        math.show(latex)
        sources.mathRows[block] = .init(view: math)
        followEditing()
        panel.refresh()
        layOutShown()
    }

    override func reset() {
        super.reset()
        panel.close()
        block = nil
        math.setEditing(false, animated: false)
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        math.height(forWidth: width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        panel.frame = math.bounds
    }

    /// A click or tap on it edits it.
    @objc private func tapped() {
        guard let block, let sources, sources.editing != block else { return }
        sources.focus(block)
    }

    /// Ringed while it's edited, its panel under it on the Mac.
    private func followEditing() {
        guard let block, let sources else { return }
        withObservationTracking {
            let editing = sources.editing == block
            math.setEditing(editing, animated: true)
            panel.setPresented(editing && DocDevice.isMac)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.block == block else { return }
                self.followEditing()
            }
        }
    }

    private static var heights = DocRowHeights<String>()
    private static let sizing = DocMathView()

    static func height(of row: DocRow, latex: String, width: CGFloat) -> CGFloat {
        heights.height(of: row, showing: latex, width: width) { width in
            sizing.show(latex)
            return sizing.height(forWidth: width)
        }
    }
}

/// The formula, or the empty one's line; the ring while it's edited.
@MainActor
final class DocMathView: UIView {
    private let formula = MarkdownUIKit.MarkdownBlockView()
    private let empty = UILabel()
    private let ring = UIView()
    private var latex: String?

    private static var ringInset: CGFloat { DocTokens.Space.sm - 2 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        empty.text = String(localized: "Empty formula. Enter LaTeX.")
        empty.font = .preferredFont(forTextStyle: .subheadline)
        empty.textColor = .floo(.disabledLabel)
        empty.textAlignment = .center
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = DocTokens.Radius.md
        ring.layer.cornerCurve = .continuous
        ring.layer.borderWidth = DocTokens.Border.focus
        ring.alpha = 0
        addSubview(formula)
        addSubview(empty)
        addSubview(ring)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ latex: String) {
        guard latex != self.latex else { return }
        self.latex = latex
        let isEmpty = latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        formula.isHidden = isEmpty
        empty.isHidden = !isEmpty
        if !isEmpty { formula.configure(displayMath: latex, style: Self.style) }
        setNeedsLayout()
    }

    func setEditing(_ editing: Bool, animated: Bool) {
        guard (ring.alpha == 1) != editing else { return }
        if animated {
            FlooMotion.appear.animate { self.ring.alpha = editing ? 1 : 0 }
        } else {
            ring.alpha = editing ? 1 : 0
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        empty.isHidden ? formula.height(forWidth: width) : DocTokens.Control.standardHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        formula.frame = CGRect(x: 0, y: 0, width: bounds.width, height: formula.isHidden ? 0 : formula.height(forWidth: bounds.width))
        empty.frame = bounds
        ring.frame = bounds.insetBy(dx: -Self.ringInset, dy: 0)
    }

    private func updateColors() {
        ring.layer.borderColor = UIColor.floo(.label).resolvedColor(with: traitCollection).cgColor
    }

    /// The page's type.
    private static let style: MarkdownUIKit.MarkdownStyle = {
        var style = MarkdownUIKit.MarkdownStyle()
        style.typography = DocUIKitType.body(design: nil)
        style.addsEdgeInsets = false
        return style
    }()
}

/// The Mac's math panel: the LaTeX, and the keys under it.
final class DocMathPage: DocStackPage {
    private let panel: DocMathPanelView

    init(block: DocBlockID, controller: DocSourceController) {
        panel = DocMathPanelView(block: block, controller: controller)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.width ?? 480
        // As wide as a formula line wants, within the window.
        super.init(width: min(460, window - 48))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.addArrangedSubview(panel)
    }

    func show(_ latex: String) {
        panel.show(latex)
    }
}

/// The LaTeX in a field on the controls' fill, and under it a row of keys that put in what's
/// long to type (a fraction, a root, powers and indices, a sum, an integral), the caret in
/// their first braces; the symbols in a menu.
final class DocMathPanelView: UIView {
    private let block: DocBlockID
    private weak var controller: DocSourceController?
    private let field = DocSourceTextView.make(code: false)

    private static let metrics = FlooButtonMetrics.of(.medium)
    /// The LaTeX's font: the body text's size, monospaced.
    private static let latexFont = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)

    init(block: DocBlockID, controller: DocSourceController) {
        self.block = block
        self.controller = controller
        super.init(frame: .zero)
        let box = UIView()
        box.backgroundColor = .floo(.markdownBlockControl)
        box.layer.cornerRadius = DocTokens.Radius.md
        box.layer.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        show(controller.text(block))

        let keys = UIStackView(arrangedSubviews: DocMathKey.keys.map(button) + [moreButton()])
        keys.spacing = DocTokens.Space.sm
        keys.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [box, keys])
        stack.axis = .vertical
        stack.spacing = DocTokens.Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: box.topAnchor),
            field.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ latex: String) {
        let inset = DocTokens.Space.sm
        field.configure(block: block, text: latex, controller: controller, font: Self.latexFont,
                        insets: UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset), language: nil, code: nil,
                        scheme: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
        field.invalidateIntrinsicContentSize()
    }

    private func label(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: Self.metrics.fontSize, weight: .medium)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        return label
    }

    private func button(_ key: DocMathKey) -> UIView {
        let button = FlooContentButton(content: label(key.title), surface: .control, shape: .corner(Self.metrics.cornerRadius),
                                       accessibilityLabel: key.name) { [weak self] in
            guard let self else { return }
            self.controller?.insert(key.snippet, caret: key.caret, in: self.block)
        }
        button.heightAnchor.constraint(equalToConstant: Self.metrics.height).isActive = true
        return button
    }

    /// The symbols: Greek letters, then relations and operators.
    private func moreButton() -> UIView {
        let image = UIImageView(image: UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: Self.metrics.iconSize, weight: .medium)))
        image.contentMode = .center
        let button = FlooContentButton(content: image, surface: .control, shape: .corner(Self.metrics.cornerRadius), accessibilityLabel: "More Symbols")
        button.menu = UIMenu(children: DocMathKey.symbols.map { section in
            UIMenu(options: .displayInline, children: section.map { key in
                UIAction(title: "\(key.title)   \(key.snippet)") { [weak self] _ in
                    guard let self else { return }
                    self.controller?.insert(key.snippet, in: self.block)
                }
            })
        })
        button.showsMenuAsPrimaryAction = true
        button.heightAnchor.constraint(equalToConstant: Self.metrics.height).isActive = true
        return button
    }
}
