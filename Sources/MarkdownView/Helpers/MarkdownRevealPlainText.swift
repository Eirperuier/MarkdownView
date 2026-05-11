//
//  MarkdownRevealPlainText.swift
//  MarkdownView
//

@preconcurrency import Markdown

enum MarkdownRevealPlainText {
    static func extract(from node: any Markup) -> String {
        switch node {
        case let text as Markdown.Text:
            return text.plainText
        case let code as InlineCode:
            return code.code
        case let codeBlock as CodeBlock:
            return codeBlock.code
        case let html as HTMLBlock:
            return html.rawHTML
        case let inlineHTML as InlineHTML:
            return inlineHTML.rawHTML
        case let table as Markdown.Table:
            return extractTablePlainText(table)
        case let tableHead as Markdown.Table.Head:
            return tableHead.cells.map { extract(from: $0) }.joined()
        case let tableBody as Markdown.Table.Body:
            return tableBody.rows.map { extract(from: $0) }.joined()
        case let tableRow as Markdown.Table.Row:
            return tableRow.cells.map { extract(from: $0) }.joined()
        case let tableCell as Markdown.Table.Cell:
            return tableCell.children.map { extract(from: $0) }.joined()
        case let link as Markdown.Link:
            return link.children.map { extract(from: $0) }.joined()
        case let ordered as OrderedList:
            return ordered.listItems.map { extract(from: $0) }.joined()
        case let unordered as UnorderedList:
            return unordered.listItems.map { extract(from: $0) }.joined()
        case _ as ThematicBreak:
            return ""
        case _ as SoftBreak, _ as LineBreak:
            return "\n"
        default:
            let childText = node.children.map { extract(from: $0) }.joined()
            if !childText.isEmpty || node.childCount > 0 {
                return childText
            }
            return node.format().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

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
}

extension Markup {
    var markdownRevealPlainText: String {
        MarkdownRevealPlainText.extract(from: self)
    }
}
