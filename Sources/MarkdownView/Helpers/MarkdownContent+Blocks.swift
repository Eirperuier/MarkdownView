//
//  MarkdownContent+Blocks.swift
//  MarkdownView
//

@preconcurrency import Markdown

extension MarkdownContent {
    /// Returns descriptors for each top-level AST child.
    /// The underlying Document is cached by ParsedDocumentStore,
    /// so repeated calls with the same options are cheap.
    ///
    /// When `expandListItems` is `true`, each list item in an ordered/unordered
    /// list is emitted as a separate descriptor with a populated `listItemContext`,
    /// rather than one descriptor for the whole list.
    public func topLevelBlocks(
        parseBlockDirectives: Bool = false,
        expandListItems: Bool = false
    ) -> [MarkdownBlockDescriptor] {
        var options = ParseOptions()
        if parseBlockDirectives {
            options.insert(.parseBlockDirectives)
        }
        let document = parse(options: options)

        var result: [MarkdownBlockDescriptor] = []
        for (index, child) in document.children.enumerated() {
            if expandListItems, let items = Self.expandList(child, topLevelIndex: index) {
                result.append(contentsOf: items)
            } else {
                let plain = Self.extractPlainText(child)
                result.append(MarkdownBlockDescriptor(
                    kind: Self.classifyNode(child),
                    topLevelIndex: index,
                    stableHash: child.stableContentHash,
                    sourceText: child.format()
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    plainText: plain,
                    childPlainTexts: Self.extractChildPlainTexts(child, fallback: plain),
                    listItemContext: nil
                ))
            }
        }
        return result
    }

    // MARK: - List Item Expansion

    private static func expandList(_ node: any Markup, topLevelIndex: Int) -> [MarkdownBlockDescriptor]? {
        let listType: MarkdownBlockDescriptor.ListItemContext.ListType
        let kind: MarkdownBlockDescriptor.Kind
        let items: [ListItem]

        if let ol = node as? OrderedList {
            listType = .ordered
            kind = .orderedList
            items = Array(ol.listItems)
        } else if let ul = node as? UnorderedList {
            listType = .unordered
            kind = .unorderedList
            items = Array(ul.listItems)
        } else {
            return nil
        }

        let depth = (node as! (any ListItemContainer)).listDepth
        var result: [MarkdownBlockDescriptor] = []
        for (itemIndex, item) in items.enumerated() {
            expandListItemRecursive(
                item, itemIndex: itemIndex,
                listType: listType, kind: kind,
                depth: depth, parentPath: [],
                topLevelIndex: topLevelIndex,
                into: &result
            )
        }
        return result.isEmpty ? nil : result
    }

    private static func expandListItemRecursive(
        _ item: ListItem, itemIndex: Int,
        listType: MarkdownBlockDescriptor.ListItemContext.ListType,
        kind: MarkdownBlockDescriptor.Kind,
        depth: Int, parentPath: [Int],
        topLevelIndex: Int,
        into result: inout [MarkdownBlockDescriptor]
    ) {
        let currentPath = parentPath + [itemIndex]
        let plain = extractListItemPlainText(item)
        let ctx = MarkdownBlockDescriptor.ListItemContext(
            listType: listType,
            itemIndex: itemIndex,
            depth: depth,
            checkbox: item.checkbox,
            parentTopLevelIndex: topLevelIndex,
            indexPath: currentPath
        )
        result.append(MarkdownBlockDescriptor(
            kind: kind,
            topLevelIndex: topLevelIndex,
            stableHash: item.stableContentHash,
            sourceText: item.format()
                .trimmingCharacters(in: .whitespacesAndNewlines),
            plainText: plain,
            childPlainTexts: [plain],
            listItemContext: ctx
        ))

        for child in item.children {
            let nestedType: MarkdownBlockDescriptor.ListItemContext.ListType
            let nestedKind: MarkdownBlockDescriptor.Kind
            let nestedItems: [ListItem]

            if let ol = child as? OrderedList {
                nestedType = .ordered
                nestedKind = .orderedList
                nestedItems = Array(ol.listItems)
            } else if let ul = child as? UnorderedList {
                nestedType = .unordered
                nestedKind = .unorderedList
                nestedItems = Array(ul.listItems)
            } else {
                continue
            }

            let nestedDepth = (child as! (any ListItemContainer)).listDepth
            for (nestedIndex, nestedItem) in nestedItems.enumerated() {
                expandListItemRecursive(
                    nestedItem, itemIndex: nestedIndex,
                    listType: nestedType, kind: nestedKind,
                    depth: nestedDepth, parentPath: currentPath,
                    topLevelIndex: topLevelIndex,
                    into: &result
                )
            }
        }
    }

    // MARK: - Plain Text Extraction

    private static func extractPlainText(_ node: any Markup) -> String {
        switch node {
        case let h as Heading:    return h.plainText
        case let p as Paragraph:  return p.plainText
        case let cb as CodeBlock: return cb.code
        case let html as HTMLBlock: return html.rawHTML
        default:
            return node.format().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func extractChildPlainTexts(_ node: any Markup, fallback: String) -> [String] {
        switch node {
        case let ol as OrderedList:
            return ol.listItems.map { extractListItemPlainText($0) }
        case let ul as UnorderedList:
            return ul.listItems.map { extractListItemPlainText($0) }
        default:
            return [fallback]
        }
    }

    private static func extractListItemPlainText(_ item: ListItem) -> String {
        item.children.compactMap { child -> String? in
            if let p = child as? Paragraph { return p.plainText }
            if let h = child as? Heading { return h.plainText }
            return nil
        }.joined()
    }

    // MARK: - Node Classification

    private static func classifyNode(_ node: any Markup) -> MarkdownBlockDescriptor.Kind {
        switch node {
        case let h as Heading:         return .heading(level: h.level)
        case _ as Paragraph:           return .paragraph
        case let cb as CodeBlock:      return .codeBlock(language: cb.language)
        case _ as BlockQuote:          return .blockQuote
        case _ as OrderedList:         return .orderedList
        case _ as UnorderedList:       return .unorderedList
        case _ as Markdown.Table:      return .table
        case _ as ThematicBreak:       return .thematicBreak
        case _ as HTMLBlock:           return .htmlBlock
        case let bd as BlockDirective: return .blockDirective(name: bd.name)
        default:                       return .unknown
        }
    }
}
