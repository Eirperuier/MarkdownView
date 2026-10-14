#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif
import Markdown

/// What a piece of markdown becomes: blocks with fresh ids, plus the
/// databases its tables turned into. Paste, agent `insert`/`replace` and
/// whole-document import all go through it.
public struct DocFragment: Hashable, Sendable {
    public var blocks: [DocBlock]
    public var databases: [DatabaseID: Database]

    public init(blocks: [DocBlock] = [], databases: [DatabaseID: Database] = [:]) {
        self.blocks = blocks
        self.databases = databases
    }

    public init(markdown: String, at time: Timestamp = .now) {
        var generator = SystemRandomNumberGenerator()
        self.init(markdown: markdown, at: time, using: &generator)
    }

    /// Parses with the same swift-markdown fork MarkdownView uses, after the
    /// same math pre-extraction, so a formula is a formula exactly when the
    /// renderer draws one. Ids come from `generator`: seed it (e.g. from an
    /// operation id) to get the same ids on every device.
    public init<Generator: RandomNumberGenerator>(markdown: String, at time: Timestamp, using generator: inout Generator) {
        let math = MathExtraction(markdown)
        var importer = MarkdownImporter(math: math, time: time, generator: generator)
        for child in Document(parsing: math.source).children {
            importer.visit(child, indent: 0)
        }
        generator = importer.generator
        self.init(blocks: importer.blocks, databases: importer.databases)
    }
}

extension Doc {
    /// A new document holding `markdown`.
    public init(id: DocID, markdown: String, at time: Timestamp = .now) {
        let fragment = DocFragment(markdown: markdown, at: time)
        self.init(id: id, blocks: fragment.blocks, databases: fragment.databases)
    }
}

private struct MarkdownImporter<Generator: RandomNumberGenerator> {
    let math: MathExtraction
    let time: Timestamp
    var generator: Generator
    var blocks: [DocBlock] = []
    var databases: [DatabaseID: Database] = [:]

    init(math: MathExtraction, time: Timestamp, generator: Generator) {
        self.math = math
        self.time = time
        self.generator = generator
    }

    private mutating func newID<Tag>() -> Identifier<Tag> {
        Identifier<Tag>.generate(at: time, using: &generator)
    }

    private mutating func append(_ kind: BlockKind, indent: Int, text: DocText = DocText()) {
        blocks.append(DocBlock(id: newID(), kind: kind, indent: min(indent, 6), text: text))
    }

    private func inline(_ markup: any Markup) -> DocText {
        var builder = InlineBuilder(inlineMath: math.inline)
        for child in markup.children { builder.walk(child, marks: []) }
        return builder.finish()
    }

    mutating func visit(_ markup: any Markup, indent: Int) {
        switch markup {
        case let paragraph as Paragraph:
            visitParagraph(paragraph, indent: indent)
        case let heading as Heading:
            append(.heading(level: min(max(heading.level, 1), 6)), indent: indent, text: inline(heading))
        case let list as UnorderedList:
            for case let item as ListItem in list.children { visitItem(item, ordered: false, indent: indent) }
        case let list as OrderedList:
            for case let item as ListItem in list.children { visitItem(item, ordered: true, indent: indent) }
        case let quote as BlockQuote:
            for child in quote.children {
                if let paragraph = child as? Paragraph {
                    append(.quote, indent: indent, text: inline(paragraph))
                } else {
                    visit(child, indent: indent)
                }
            }
        case let code as CodeBlock:
            visitCode(code, indent: indent)
        case is ThematicBreak:
            append(.divider, indent: indent)
        case let table as Table:
            visitTable(table, indent: indent)
        case let html as HTMLBlock:
            let raw = html.rawHTML.hasSuffix("\n") ? String(html.rawHTML.dropLast()) : html.rawHTML
            append(.paragraph, indent: indent, text: DocText(string: InlineBuilder.cleaned(raw)))
        default:
            for child in markup.children { visit(child, indent: indent) }
        }
    }

    private mutating func visitParagraph(_ paragraph: Paragraph, indent: Int) {
        let children = Array(paragraph.children)
        if children.count == 1, let image = children[0] as? Image {
            let alt = image.plainText
            append(.image(image: DocImage(source: image.source ?? "", alt: alt)), indent: indent)
            return
        }
        // A link titled "bookmark" or "file", on a line of its own.
        if children.count == 1, let link = children[0] as? Link, let destination = link.destination,
           link.title == "bookmark" || link.title == "file" {
            let text = link.plainText
            if link.title == "file" {
                append(.file(file: DocFile(source: destination, name: text)), indent: indent)
            } else {
                append(.link(link: DocLink(url: destination, title: text == destination ? "" : text)), indent: indent)
            }
            return
        }
        // `<small>…</small>`: a caption, what's between the tags its text.
        if children.count >= 2, let open = children.first as? InlineHTML, let close = children.last as? InlineHTML,
           open.rawHTML.lowercased() == "<small>", close.rawHTML.lowercased() == "</small>" {
            var builder = InlineBuilder(inlineMath: math.inline)
            for child in children.dropFirst().dropLast() { builder.walk(child, marks: []) }
            append(.caption, indent: indent, text: builder.finish())
            return
        }
        if let latex = math.displayLatex(paragraph.plainText) {
            append(.math, indent: indent, text: DocText(string: latex))
            return
        }
        append(.paragraph, indent: indent, text: inline(paragraph))
    }

    /// A list item's first paragraph is its text; whatever follows (nested
    /// lists, more paragraphs) becomes blocks one level deeper.
    private mutating func visitItem(_ item: ListItem, ordered: Bool, indent: Int) {
        let style: ListStyle = switch item.checkbox {
        case .checked: .task(done: true)
        case .unchecked: .task(done: false)
        case nil: ordered ? .numbered : .bullet
        }
        var children = Array(item.children)
        if let first = children.first as? Paragraph {
            append(.listItem(style: style), indent: indent, text: inline(first))
            children.removeFirst()
        } else {
            append(.listItem(style: style), indent: indent)
        }
        for child in children { visit(child, indent: indent + 1) }
    }

    private mutating func visitCode(_ code: CodeBlock, indent: Int) {
        let body = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
        let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
        if language == "floo.card", let card = try? JSONDecoder().decode(DocCard.self, from: Data(body.utf8)) {
            append(.card(card: card), indent: indent)
            return
        }
        if language == "floo.view", let view = try? JSONDecoder().decode(DocView.self, from: Data(body.utf8)) {
            append(.view(view: view), indent: indent)
            return
        }
        if language == "floo.collection", var fence = try? JSONDecoder().decode(CollectionFence.self, from: Data(body.utf8)) {
            // Its database is new where it lands: the same records under an id of its own.
            fence.database.id = newID()
            fence.collection.database = fence.database.id
            databases[fence.database.id] = fence.database
            append(.collection(collection: fence.collection), indent: indent)
            return
        }
        if language == "floo.page", let page = try? JSONDecoder().decode(DocPage.self, from: Data(body.utf8)) {
            append(.page(page: page), indent: indent)
            return
        }
        append(.code(language: language), indent: indent, text: DocText(string: InlineBuilder.cleaned(body)))
    }

    /// A GFM table becomes a database of text columns shown as a table.
    private mutating func visitTable(_ table: Table, indent: Int) {
        let columns: [Column] = table.head.cells.map { cell in
            Column(id: newID(), name: cellText(cell), type: .text)
        }
        var rows: [Row] = []
        for row in table.body.rows {
            var cells: [ColumnID: CellValue] = [:]
            for (column, cell) in zip(columns, row.cells) {
                let text = inline(cell)
                if !text.isEmpty { cells[column.id] = .text(text) }
            }
            rows.append(Row(id: newID(), cells: cells))
        }
        let database = Database(id: newID(), columns: columns, rows: rows)
        databases[database.id] = database
        append(.database(id: database.id, view: .table(hidden: [], sort: [])), indent: indent)
    }

    /// A header cell's plain text (a column's name); atoms read back as their source.
    private func cellText(_ cell: Table.Cell) -> String {
        let text = inline(cell)
        var atoms: [Int: Mark] = [:]
        for span in text.marks where span.mark.kind.isAtom { atoms[span.range.lowerBound] = span.mark }
        guard !atoms.isEmpty else { return text.string }
        var result = ""
        var offset = 0
        for scalar in text.string.unicodeScalars {
            if let mark = atoms[offset] {
                switch mark {
                case .inlineMath(let latex): result += "$\(latex)$"
                case .cite(_, let label), .mention(_, _, let label): result += label
                default: break
                }
            } else {
                result.unicodeScalars.append(scalar)
            }
            offset += scalar.utf16.count
        }
        return result
    }
}
