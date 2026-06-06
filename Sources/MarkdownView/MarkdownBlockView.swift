//
//  MarkdownBlockView.swift
//  MarkdownView
//

import SwiftUI
@preconcurrency import Markdown

/// Renders a single top-level block from a shared MarkdownContent.
/// Reuses the same cached Document and NodeViewCache as MarkdownView.
///
/// When the descriptor has a `listItemContext`, navigates into the parent list
/// to render a single list item with the appropriate marker and indentation.
public struct MarkdownBlockView: View {
    private let content: MarkdownContent
    private let descriptor: MarkdownBlockDescriptor

    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownFontGroup.body) private var bodyFont
    @Environment(\.markdownTextOffsetBase) private var offsetBase

    public init(_ content: MarkdownContent, block: MarkdownBlockDescriptor) {
        self.content = content
        self.descriptor = block
    }

    public var body: some View {
        _renderedBlock.font(bodyFont)
    }

    @ViewBuilder
    private var _renderedBlock: some View {
        let children = content.topLevelChildren(options: parseOptions)

        if let ctx = descriptor.listItemContext {
            _listItemBlock(children: children, ctx: ctx)
                .environment(\.markdownRendererConfiguration, configuration)
        } else if let child = _resolveChild(children: children) {
            // 单一分支 + 单次 _renderChild。原来「topLevelIndex 命中」与「按 hash 查找」是两个独立
            // 的 @ViewBuilder 分支,流式时在两者间切换同样会生成 _ConditionalContent、触发整块重挂。
            _renderChild(child)
                .environment(\.markdownRendererConfiguration, configuration)
        }
    }

    /// 先按 topLevelIndex 命中,失败再按 stableHash 查找。合并成一次解析,避免分支切换重挂。
    private func _resolveChild(children: [any Markup]) -> (any Markup)? {
        if descriptor.topLevelIndex < children.count,
           children[descriptor.topLevelIndex].stableContentHash == descriptor.stableHash {
            return children[descriptor.topLevelIndex]
        }
        return children.first(where: { $0.stableContentHash == descriptor.stableHash })
    }

    // MARK: - List Item Rendering

    @ViewBuilder
    private func _listItemBlock(children: [any Markup], ctx: MarkdownBlockDescriptor.ListItemContext) -> some View {
        let listItem = _findListItem(children: children, ctx: ctx)
        if let listItem {
            let baseIndent = configuration.listConfiguration.leadingIndentation
            let perLevel: CGFloat = 20
            HStack(alignment: .firstTextBaseline) {
                _markerView(ctx: ctx, checkbox: listItem.checkbox)
                    .font(bodyFont)
                    .padding(.leading, baseIndent + CGFloat(ctx.depth) * perLevel)
                _listItemContent(listItem: listItem)
            }
        }
    }

    /// Renders only the non-list children of a ListItem, since nested lists
    /// are expanded into their own independent blocks.
    @ViewBuilder
    private func _listItemContent(listItem: ListItem) -> some View {
        let inlineChildren = listItem.children.filter { !($0 is OrderedList) && !($0 is UnorderedList) }
        let childOffsets = Self.offsets(for: inlineChildren)
        VStack(alignment: .leading, spacing: configuration.componentSpacing) {
            ForEach(Array(inlineChildren.enumerated()), id: \.offset) { index, child in
                if child is Heading {
                    CmarkNodeVisitor(configuration: configuration)
                        .makeBody(for: child)
                        .environment(\.markdownTextOffsetBase, offsetBase + childOffsets[index])
                } else {
                    CmarkNodeVisitor(configuration: configuration)
                        .makeBody(for: child)
                        .font(bodyFont)
                        .environment(\.markdownTextOffsetBase, offsetBase + childOffsets[index])
                }
            }
        }
    }

    private static func offsets(for children: [any Markup]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(children.count)
        var runningOffset = 0
        for child in children {
            result.append(runningOffset)
            runningOffset += child.markdownRevealPlainText.count
        }
        return result
    }

    /// Navigate the AST using the full `indexPath` to locate the target ListItem,
    /// supporting arbitrarily nested sub-lists.
    private func _findListItem(children: [any Markup], ctx: MarkdownBlockDescriptor.ListItemContext) -> ListItem? {
        guard ctx.parentTopLevelIndex < children.count else { return nil }
        let topNode = children[ctx.parentTopLevelIndex]
        guard !ctx.indexPath.isEmpty else { return nil }

        var currentItems: [ListItem]
        if let ol = topNode as? OrderedList {
            currentItems = Array(ol.listItems)
        } else if let ul = topNode as? UnorderedList {
            currentItems = Array(ul.listItems)
        } else {
            return nil
        }

        for (step, idx) in ctx.indexPath.enumerated() {
            guard idx < currentItems.count else { return nil }
            let item = currentItems[idx]

            if step == ctx.indexPath.count - 1 {
                if item.stableContentHash == descriptor.stableHash {
                    return item
                }
                return currentItems.first(where: { $0.stableContentHash == descriptor.stableHash })
            }

            var found = false
            for child in item.children {
                if let ol = child as? OrderedList {
                    currentItems = Array(ol.listItems)
                    found = true
                    break
                } else if let ul = child as? UnorderedList {
                    currentItems = Array(ul.listItems)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }
        return nil
    }

    @ViewBuilder
    private func _markerView(ctx: MarkdownBlockDescriptor.ListItemContext, checkbox: Checkbox?) -> some View {
        StreamingRevealMarker {
            if let checkbox {
                switch checkbox {
                case .checked:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                case .unchecked:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                switch ctx.listType {
                case .unordered:
                    let marker = configuration.listConfiguration.unorderedListMarker
                    SwiftUI.Text(marker.marker(listDepth: ctx.depth))
                        .monospaced(marker.monospaced)
                        .foregroundStyle(.secondary)
                case .ordered:
                    let marker = configuration.listConfiguration.orderedListMarker
                    SwiftUI.Text(marker.marker(at: ctx.itemIndex, listDepth: ctx.depth))
                        .monospaced(marker.monospaced)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Standard Block Rendering

    // 注意:必须返回具体类型 `MarkdownNodeView` 并用 early-return,**不能**用 @ViewBuilder 的
    // if/else。否则缓存命中(cached)/未命中(rendered)会生成 `_ConditionalContent` 的两个分支,
    // 流式时在两分支间来回切 = SwiftUI 判定身份变化 = 整棵表格子树重新挂载(makeCache 触发、
    // TableInfoCache/布局缓存全丢)→ 整表全量重测高 → 主线程 200ms hang。两分支同为 MarkdownNodeView、
    // 同一位置返回,身份才稳定、只做增量更新。
    private func _renderChild(_ child: any Markup) -> MarkdownNodeView {
        let hash = child.stableContentHash
        let configFP = configuration.stableFingerprint
        let cacheKey = NodeCacheKey(contentHash: hash, configurationHash: configFP)
        let nodeCache = NodeViewCache.shared

        if let cached = nodeCache.get(cacheKey) {
            return cached
        }
        let rendered = _visitChild(child)
        nodeCache.set(cacheKey, view: rendered)
        return rendered
    }

    private func _visitChild(_ child: any Markup) -> MarkdownNodeView {
        var visitor = CmarkNodeVisitor(configuration: configuration)
        return visitor.visit(child)
    }

    private var parseOptions: ParseOptions {
        content.parseOptions(
            allowingBlockDirectives: !configuration.allowedBlockDirectiveRenderers.isEmpty
        )
    }
}
