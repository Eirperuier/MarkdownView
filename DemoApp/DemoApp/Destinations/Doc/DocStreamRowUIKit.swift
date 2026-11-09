//
//  DocStreamRowUIKit.swift
//  DemoApp
//
//  What the agent is writing, as a UIKit row: its blocks in MarkdownUIKit's block views one
//  under another, each shown as far as the page's reveal has got (the coordinator's manager for
//  the block, chat's reveal style), in the page's text column and its box.
//

import DocKit
import MarkdownUIKit
import MarkdownView
import MessagingUI
import UIKit

/// A row of the agent's temporary layer.
@MainActor
struct DocStreamRowContent: TiledUIKitCellContent {
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let coordinator: StreamingRevealCoordinator<UUID>
    let blocks: DocBlockController

    static func makeRowView() -> DocStreamRowView { DocStreamRowView() }

    func configure(_ view: DocStreamRowView, context: TiledUIKitCellContext) {
        view.show(row, coordinator: coordinator, blocks: blocks, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocStreamRowView.height(of: row, width: width)
    }

    static func prepareForReuse(_ view: DocStreamRowView) {
        view.reset()
    }
}

@MainActor
final class DocStreamRowView: DocRowUIKitView {
    private let stack = DocStreamBlocksView()

    init() {
        super.init(content: stack)
        stack.onHeightChange = { [weak self] in
            guard let self, let row = self.row else { return }
            Self.heights[row.id] = nil
            self.contentHeightChanged()
        }
    }

    func show(_ row: DocRow, coordinator: StreamingRevealCoordinator<UUID>, blocks: DocBlockController, context: TiledUIKitCellContext) {
        take(row, blocks: blocks, context: context)
        stack.show(row.blocks, style: Self.style(for: row)) { block in
            MarkdownReveal(manager: coordinator.ensureManager(for: block.id), style: ChatUIKitBlock.revealStyle)
        }
        layOutShown()
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        stack.height(forWidth: width)
    }

    // MARK: Heights

    /// By row, what it had written and the width: a reveal moving on doesn't change a height.
    private static var heights: [String: (sources: [String], byWidth: [CGFloat: CGFloat])] = [:]
    private static let sizing = DocStreamBlocksView()

    static func height(of row: DocRow, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        let sources = row.blocks.map(\.source)
        let contentWidth = contentWidth(of: row, width: width)
        let content: CGFloat
        if let known = heights[row.id], known.sources == sources, let height = known.byWidth[contentWidth] {
            content = height
        } else {
            sizing.show(row.blocks, style: style(for: row)) { _ in nil }
            content = sizing.height(forWidth: contentWidth)
            var entry = heights[row.id].flatMap { $0.sources == sources ? $0 : nil } ?? (sources: sources, byWidth: [:])
            entry.byWidth[contentWidth] = content
            heights[row.id] = entry
        }
        return frames(of: row, width: width, contentHeight: content).height
    }

    /// The page's type at the row's role (DocTextRowView's), the agent's text as it writes it.
    private static func style(for row: DocRow) -> MarkdownUIKit.MarkdownStyle {
        var style = MarkdownUIKit.MarkdownStyle()
        style.typography = row.role == .caption ? DocUIKitType.caption(design: nil) : DocUIKitType.body(design: nil)
        style.lineSpacing = row.role.lineSpacing
        style.addsEdgeInsets = false
        if row.role == .caption { style.textColor = .floo(.secondaryLabel) }
        return style
    }
}

/// Block views one under another, by position: a block written further is the same view.
@MainActor
final class DocStreamBlocksView: UIView {
    private var views: [MarkdownUIKit.MarkdownBlockView] = []
    var onHeightChange: (() -> Void)?

    func show(_ blocks: [MarkdownStreamBlock], style: MarkdownUIKit.MarkdownStyle, reveal: (MarkdownStreamBlock) -> MarkdownReveal?) {
        while views.count > blocks.count { views.removeLast().removeFromSuperview() }
        while views.count < blocks.count {
            let view = MarkdownUIKit.MarkdownBlockView()
            view.onHeightChange = { [weak self] in
                self?.setNeedsLayout()
                self?.onHeightChange?()
            }
            addSubview(view)
            views.append(view)
        }
        for (view, block) in zip(views, blocks) {
            view.configure(block, style: style, reveal: reveal(block))
        }
        setNeedsLayout()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        views.reduce(0) { $0 + $1.height(forWidth: width) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        for view in views {
            let height = view.height(forWidth: bounds.width)
            view.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}
