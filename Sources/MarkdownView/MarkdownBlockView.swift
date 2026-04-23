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

    public init(_ content: MarkdownContent, block: MarkdownBlockDescriptor) {
        self.content = content
        self.descriptor = block
    }

    public var body: some View {
        _renderedBlock.font(bodyFont)
    }

    @ViewBuilder
    private var _renderedBlock: some View {
        let document = content.parse(options: parseOptions)
        let children = Array(document.children)

        if let ctx = descriptor.listItemContext {
            _listItemBlock(children: children, ctx: ctx)
                .environment(\.markdownRendererConfiguration, configuration)
        } else if descriptor.topLevelIndex < children.count,
                  children[descriptor.topLevelIndex].stableContentHash == descriptor.stableHash {
            let child = children[descriptor.topLevelIndex]
            _renderChild(child)
                .environment(\.markdownRendererConfiguration, configuration)
        } else if let child = children.first(where: { $0.stableContentHash == descriptor.stableHash }) {
            _renderChild(child)
                .environment(\.markdownRendererConfiguration, configuration)
        }
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
        VStack(alignment: .leading, spacing: configuration.componentSpacing) {
            ForEach(Array(inlineChildren.enumerated()), id: \.offset) { (_, child) in
                CmarkNodeVisitor(configuration: configuration)
                    .makeBody(for: child)
            }
        }
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

    @ViewBuilder
    private func _renderChild(_ child: any Markup) -> some View {
        let hash = child.stableContentHash
        let configFP = configuration.stableFingerprint
        let cacheKey = NodeCacheKey(contentHash: hash, configurationHash: configFP)
        let nodeCache = NodeViewCache.shared

        if let cached = nodeCache.get(cacheKey) {
            cached
        } else {
            let rendered = _visitChild(child)
            let _ = nodeCache.set(cacheKey, view: rendered)
            rendered
        }
    }

    private func _visitChild(_ child: any Markup) -> MarkdownNodeView {
        var visitor = CmarkNodeVisitor(configuration: configuration)
        return visitor.visit(child)
    }

    private var parseOptions: ParseOptions {
        var opts = ParseOptions()
        if !configuration.allowedBlockDirectiveRenderers.isEmpty {
            opts.insert(.parseBlockDirectives)
        }
        return opts
    }
}
