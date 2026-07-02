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
        let options = parseOptions(allowingBlockDirectives: parseBlockDirectives)
        let children = topLevelChildren(options: options)
        let parserText = MarkdownParseSanitizer.sanitizedForCmark(raw.text)

        var result: [MarkdownBlockDescriptor] = []
        var index = 0
        while index < children.count {
            let child = children[index]
            if expandListItems, let items = Self.expandList(child, topLevelIndex: index, parserText: parserText) {
                result.append(contentsOf: items)
                index += 1
                continue
            }
            // Extended Heading:同级相邻标题合并成一个 descriptor,渲染为
            // title + secondary subtitle(中间无间距)。topLevelIndex 取 title 的
            // 真实 child 下标,流式中 subtitle 出现时同 index 的块 key 不变。
            if let title = child as? Heading,
               index + 1 < children.count,
               let subtitle = children[index + 1] as? Heading,
               subtitle.level == title.level {
                let titlePlain = Self.extractPlainText(title)
                let subtitlePlain = Self.extractPlainText(subtitle)
                result.append(MarkdownBlockDescriptor(
                    kind: .heading(level: title.level),
                    topLevelIndex: index,
                    stableHash: Self.combinedStableHash(title, subtitle),
                    sourceText: [
                        Self.sourceText(for: title, in: parserText),
                        Self.sourceText(for: subtitle, in: parserText),
                    ].joined(separator: "\n"),
                    plainText: titlePlain + "\n" + subtitlePlain,
                    childPlainTexts: [titlePlain, subtitlePlain],
                    listItemContext: nil,
                    extendedHeadingContext: .init(level: title.level)
                ))
                index += 2
                continue
            }
            let plain = Self.extractPlainText(child)
            result.append(MarkdownBlockDescriptor(
                kind: Self.classifyNode(child),
                topLevelIndex: index,
                stableHash: child.stableContentHash,
                sourceText: Self.sourceText(for: child, in: parserText),
                plainText: plain,
                childPlainTexts: Self.extractChildPlainTexts(child, fallback: plain),
                listItemContext: nil
            ))
            index += 1
        }
        return result
    }

    /// Deterministic hash for an Extended Heading pair — must not use `Hasher`
    /// (per-process random seed) because `MarkdownBlockView` re-derives it to
    /// resolve the pair against the descriptor.
    static func combinedStableHash(_ first: any Markup, _ second: any Markup) -> Int {
        first.stableContentHash ^ (second.stableContentHash &* 31)
    }

    private static func sourceText(for node: any Markup, in parserText: String) -> String {
        // 一律优先原文 range 切片(与 sourceTextForListItem 同理):`format()` 往返会丢语法细节 ——
        // 最典型的是 Strikethrough 被 format 成单波浪线 `~x~`,再解析时被 MarkdownParseSanitizer
        // 转义成字面 `\~` → 删除线消失。原文切片保留用户的确切写法,round-trip 无损。
        if let source = sourceTextFromRange(for: node, in: parserText) {
            // 缩进式代码块例外:切片是四空格缩进源码,消费方(编辑器/复制)期待围栏形式 → 落 format()。
            if !(node is CodeBlock) || isFencedCodeSource(source) {
                return source.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return node.format().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sourceTextFromRange(for node: any Markup, in text: String) -> String? {
        guard let range = node.range,
              let lower = stringIndex(for: range.lowerBound, in: text),
              let upper = stringIndex(for: range.upperBound, in: text),
              lower <= upper else {
            return nil
        }
        return String(text[lower..<upper])
    }

    /// Source slice for a single `ListItem`, truncated at the first nested
    /// list child so sub-lists (which are expanded into their own descriptors)
    /// don't get duplicated into the parent's `sourceText`.
    private static func sourceTextForListItem(_ item: ListItem, in text: String) -> String? {
        guard let range = item.range else { return nil }
        let cutAt = item.children
            .first(where: { $0 is OrderedList || $0 is UnorderedList })?
            .range?.lowerBound
        let effectiveUpper = cutAt ?? range.upperBound
        guard let lower = stringIndex(for: range.lowerBound, in: text),
              let upper = stringIndex(for: effectiveUpper, in: text),
              lower <= upper else {
            return nil
        }
        return String(text[lower..<upper])
    }

    private static func stringIndex(for location: SourceLocation, in text: String) -> String.Index? {
        guard location.line >= 1, location.column >= 1 else { return nil }

        var line = 1
        var lineStart = text.startIndex
        while line < location.line {
            guard let newline = text[lineStart...].firstIndex(of: "\n") else { return nil }
            lineStart = text.index(after: newline)
            line += 1
        }

        guard let utf8LineStart = lineStart.samePosition(in: text.utf8),
              let utf8Index = text.utf8.index(
                utf8LineStart,
                offsetBy: location.column - 1,
                limitedBy: text.utf8.endIndex
              ) else {
            return nil
        }
        return utf8Index.samePosition(in: text)
    }

    private static func isFencedCodeSource(_ source: String) -> Bool {
        guard let firstLine = source.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first else {
            return false
        }

        let trimmed = firstLine.drop(while: { $0 == " " })
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    // MARK: - List Item Expansion

    private static func expandList(_ node: any Markup, topLevelIndex: Int, parserText: String) -> [MarkdownBlockDescriptor]? {
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
                parserText: parserText,
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
        parserText: String,
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
        // Prefer the original source slice (truncated at the first nested
        // list, since sub-lists are emitted as their own descriptors) over
        // `item.format()`, which loses the parent OrderedList's start index
        // and indentation. The source slice preserves the user's exact
        // marker (`1.`, `*`, `[x]`, etc.) and round-trips back to the AST.
        let source = (sourceTextForListItem(item, in: parserText) ?? item.format())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result.append(MarkdownBlockDescriptor(
            kind: kind,
            topLevelIndex: topLevelIndex,
            stableHash: item.stableContentHash,
            sourceText: source,
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
                    parserText: parserText,
                    into: &result
                )
            }
        }
    }

    // MARK: - Plain Text Extraction

    private static func extractPlainText(_ node: any Markup) -> String {
        node.markdownRevealPlainText
    }

    /// Concatenated plain text in canonical reveal order:
    /// header row L→R, then each body row L→R. The reveal coordinator drives
    /// per-cell `blockTextOffset` against this order; any change to the order
    /// here must match the offset computation in `MarkdownTable`.
    private static func extractTablePlainText(_ table: Markdown.Table) -> String {
        var result = ""
        for cell in table.head.cells {
            result += cell.markdownRevealPlainText
        }
        for child in table.body.children {
            guard let row = child as? Markdown.Table.Row else { continue }
            for cell in row.cells {
                result += cell.markdownRevealPlainText
            }
        }
        return result
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
        item.children
            .filter { !($0 is OrderedList) && !($0 is UnorderedList) }
            .map(\.markdownRevealPlainText)
            .joined()
    }

    // MARK: - Node Classification

    private static func classifyNode(_ node: any Markup) -> MarkdownBlockDescriptor.Kind {
        switch node {
        case let h as Heading:         return .heading(level: h.level)
        case let p as Paragraph:
            if Self.standaloneDisplayMath(in: p) != nil {
                return .mathBlock
            }
            return .paragraph
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

    private static func standaloneDisplayMath(in paragraph: Paragraph) -> String? {
        for (candidate, unescapeCommonMarkEscapes) in [
            (paragraph.plainText, false),
            (paragraph.format(), true),
        ] {
            if let latexMath = MathParser.standaloneDisplayMath(
                in: candidate,
                unescapingCommonMarkEscapes: unescapeCommonMarkEscapes
            ) {
                return latexMath
            }
        }
        return nil
    }
}
