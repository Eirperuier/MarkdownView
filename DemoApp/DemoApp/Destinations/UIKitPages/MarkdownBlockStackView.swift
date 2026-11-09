//
//  MarkdownBlockStackView.swift
//  DemoApp
//
//  Blocks one under another in UIKit, as a chat's rows are: MarkdownUIKit's block views at the
//  chat's width and spacing. A block that grows replaces only what changed at its end.
//

import MarkdownUIKit
import MarkdownView
import UIKit

@MainActor
final class MarkdownBlockStackView: UIScrollView {
    var style = ChatUIKitBlock.style
    /// Kept at the end as blocks grow, unless scrolled away from it.
    var followsEnd = false

    private var views: [UUID: MarkdownUIKit.MarkdownBlockView] = [:]
    private var sources: [UUID: String] = [:]
    private var order: [UUID] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        alwaysBounceVertical = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ blocks: [MarkdownStreamBlock], reveal: (MarkdownStreamBlock) -> MarkdownReveal? = { _ in nil }) {
        let atEnd = isAtEnd
        var shown = Set<UUID>()
        for block in blocks {
            shown.insert(block.id)
            let blockReveal = reveal(block)
            if let view = views[block.id] {
                if sources[block.id] == block.source {
                    view.setReveal(blockReveal)
                } else {
                    view.configure(block, style: style, reveal: blockReveal)
                    sources[block.id] = block.source
                }
            } else {
                let view = MarkdownUIKit.MarkdownBlockView()
                view.onHeightChange = { [weak self] in self?.setNeedsLayout() }
                view.configure(block, style: style, reveal: blockReveal)
                addSubview(view)
                views[block.id] = view
                sources[block.id] = block.source
            }
        }
        for (id, view) in views where !shown.contains(id) {
            view.prepareForReuse()
            view.removeFromSuperview()
            views[id] = nil
            sources[id] = nil
        }
        order = blocks.map(\.id)
        setNeedsLayout()
        layoutIfNeeded()
        if followsEnd, atEnd { scrollToEnd() }
    }

    private var isAtEnd: Bool {
        contentOffset.y + bounds.height >= contentSize.height + adjustedContentInset.bottom - 40
    }

    private func scrollToEnd() {
        let end = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
        if contentOffset.y != end { contentOffset.y = end }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = ChatUIKitRowLayout.textWidth(in: bounds.width)
        let x = ChatUIKitRowLayout.horizontalPadding
        var y: CGFloat = ChatUIKitRowLayout.verticalPadding * 2
        for id in order {
            guard let view = views[id] else { continue }
            let height = view.height(forWidth: width)
            let frame = CGRect(x: x, y: y + ChatUIKitRowLayout.verticalPadding, width: width, height: height)
            if view.frame != frame { view.frame = frame }
            y = frame.maxY + ChatUIKitRowLayout.verticalPadding
        }
        let size = CGSize(width: bounds.width, height: y + ChatUIKitRowLayout.verticalPadding * 2)
        if contentSize != size { contentSize = size }
    }
}

extension UIViewController {
    /// A bar of controls along the top that scrolls sideways where it's too wide (a phone).
    func addControlBar(_ bar: UIStackView) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(bar)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.heightAnchor.constraint(equalTo: bar.heightAnchor),
            bar.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            bar.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
        ])
        return scroll
    }
}
