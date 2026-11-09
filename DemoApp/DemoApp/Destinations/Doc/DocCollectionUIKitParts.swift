//
//  DocCollectionUIKitParts.swift
//  DemoApp
//
//  What a collection's UIKit views share: a panel beside a view while the collection
//  controller shows it, a button that opens a menu of sections, a field's value as a chip,
//  chips in lines, the pointer over a view, a symbol button.
//

import DocKit
import FlooUIKit
import UIKit

private typealias Metrics = DocCollectionMetrics

/// A page in floo's panel beside the view it's laid over (its frame the view's bounds),
/// while it's presented; a touch outside closes it and goes no further (`docPanel(page:)`).
/// `follow`: as the opener changes, for the page to follow what it reads.
@MainActor
func docPanelSpot(edge: FlooFloatingEdge = .below, alignment: FlooFloatingAlignment = .leading,
                  page: @escaping @MainActor () -> UIViewController, follow: (@MainActor (UIViewController) -> Void)? = nil,
                  onDismiss: @escaping @MainActor () -> Void) -> FlooPanelAnchorView {
    let spot = FlooPanelAnchorView { _, _ in page() }
    spot.options.edge = edge
    spot.options.alignment = alignment
    spot.options.isModal = true
    spot.options.selfDrawn = true
    spot.onDismiss = onDismiss
    if let follow { spot.update = { page, _, _ in follow(page) } }
    spot.isUserInteractionEnabled = false
    return spot
}

extension FlooPanelAnchorView {
    /// Laid over `view`, shown while `presented`.
    func show(_ presented: Bool, over view: UIView) {
        if superview !== view { view.addSubview(self) }
        frame = view.bounds
        if presented, isPresented { refresh() }
        setPresented(presented)
    }
}

extension UIButton {
    /// A press opens `sections` as they are then, in the system's menu.
    func docMenu(_ sections: @escaping @MainActor () -> [FlooMenuSection]) {
        showsMenuAsPrimaryAction = true
        menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(sections().systemElements(traits: self?.traitCollection) { item in
                guard let self, let inner = item.sections else { return }
                self.flooPresenter?.flooPresentMenuPanel(title: item.title, sections: inner, from: self)
            })
        }])
    }

    /// What it does said on the pointer over it (the Mac's tooltip) and to VoiceOver.
    func docHelp(_ title: String) {
        accessibilityLabel = title
        addInteraction(UIToolTipInteraction(defaultToolTip: title))
    }
}

/// A symbol in floo's content button, `side` square; `shape` its press's.
@MainActor
func docSymbolButton(_ symbol: String, size: CGFloat = DocTokens.Icon.compact, weight: UIImage.SymbolWeight = .medium,
                     color: UIColor = .floo(.secondaryLabel), side: CGFloat, shape: FlooButtonStyle.Shape = .corner(Metrics.corner),
                     title: String, action: (() -> Void)? = nil) -> FlooContentButton {
    let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight)))
    image.tintColor = color
    image.contentMode = .center
    // In a holder: the button tints its content its own text colour.
    let holder = UIView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    image.frame = holder.bounds
    image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    holder.addSubview(image)
    let button = FlooContentButton(content: holder, shape: shape, accessibilityLabel: title, action: action)
    button.docHelp(title)
    button.frame.size = CGSize(width: side, height: side)
    return button
}

/// floo's small icon button (the toolbar's).
@MainActor
func docToolbarButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> FlooButton {
    let button = FlooButton(.tertiary.size(.small), image: UIImage(systemName: symbol), action: action)
    button.docHelp(title)
    return button
}

/// A field's value as a chip: floo's badge, an option in its colour; the rest quiet (DocChip).
@MainActor
enum DocChips {
    static func chip(_ text: String, color: UIColor? = nil, symbol: String? = nil) -> FlooBadge {
        FlooBadge(text, symbol: symbol, style: .tinted.tone(color.map { .color($0) } ?? .neutral))
    }

    static func chip(_ option: SelectOption, in options: [SelectOption]) -> FlooBadge {
        chip(option.name, color: color(option, in: options))
    }

    static func color(_ option: SelectOption, in options: [SelectOption]) -> UIColor {
        DocColors.ink(DocOptionColor.token(option, in: options)) ?? .floo(.secondaryLabel)
    }

    /// A group's name: its option's chip, its value's words, None for records with none.
    static func group(_ group: CollectionGroup, of column: Column) -> FlooBadge {
        let options = DocFieldText.options(column)
        if let option = options.first(where: { $0.id.description == group.key }) { return chip(option, in: options) }
        return chip(DocGroupLabel.title(group.value, in: column))
    }

    /// Views in lines `width` wide, as many on each as fit, `spacing` apart (DocFlow): their
    /// frames, and the height they take.
    static func flow(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat = 6) -> (frames: [CGRect], height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        var frames: [CGRect] = []
        for size in sizes {
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            line = max(line, size.height)
        }
        return (frames, sizes.isEmpty ? 0 : y + line)
    }
}

/// Tells whether the pointer is over a view, and where.
@MainActor
final class DocHover: NSObject {
    private(set) var location: CGPoint?
    private let changed: @MainActor (CGPoint?) -> Void

    init(on view: UIView, changed: @escaping @MainActor (CGPoint?) -> Void) {
        self.changed = changed
        super.init()
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
    }

    var isOver: Bool { location != nil }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: location = recognizer.location(in: recognizer.view)
        default: location = nil
        }
        changed(location)
    }
}

/// Text that wraps in its width, as a cell's or a card's field (`DocCollectionCellView`).
enum DocTextMeasure {
    static func height(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let shown = text.isEmpty ? " " : text
        let rect = (shown as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        return ceil(rect.height)
    }
}
