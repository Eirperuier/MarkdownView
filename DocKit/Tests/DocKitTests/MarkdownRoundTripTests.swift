import Foundation
import Testing
import Markdown

@testable import DocKit

/// Random documents in the canonical form markdown can carry exactly —
/// marks on whole words and properly nested, no mentions, text without
/// edge whitespace — must survive export then import unchanged, ids aside.
@Suite
struct MarkdownRoundTripTests {
    @Test
    func docSurvivesMarkdown() {
        for iteration in 0..<400 {
            let seed = UInt64(iteration) &+ 0x3D00_0000
            var rng = SplitMix64(seed: seed)
            let doc = CanonicalDoc.doc(using: &rng)
            let markdown = doc.markdown
            let fragment = DocFragment(markdown: markdown, at: fixedTime(0), using: &rng)
            let back = Doc(id: doc.id, blocks: fragment.blocks, databases: fragment.databases)
            #expect(Shape.of(back) == Shape.of(doc), "seed \(seed)\n\(markdown)")
            #expect(back.markdown == markdown, "seed \(seed)")
            #expect((try? back.validate()) != nil, "seed \(seed) invalid import")
        }
    }
}

/// A text block's tree is what its editing markdown parses into, built without writing
/// or parsing it. (Inline maths is a node in the tree, text in markdown: those blocks
/// aside; a default highlight is `==…==` text in markdown, compared as such.)
@Suite
struct MarkupTreeTests {
    @Test
    func treesAreTheirEditingMarkdownParsed() {
        var compared = 0
        for iteration in 0..<400 {
            let seed = UInt64(iteration) &+ 0x7E00_0000
            var rng = SplitMix64(seed: seed)
            let doc = Self.trimmingMarks(CanonicalDoc.doc(using: &rng))
            for block in doc.blocks {
                // Maths is a node markdown has none for (its `$` delimiters are MarkdownView's).
                guard block.kind != .math, let tree = doc.markupTree(of: block.id),
                    !block.text.marks.contains(where: { $0.mark.kind == .inlineMath }),
                    let markdown = doc.markdown(of: block.id, style: .editing)
                else { continue }
                var parsed = Document(parsing: markdown)
                // A caption's `<small>` tags hold its text; the tree is the text.
                if block.kind == .caption, let paragraph = parsed.child(at: 0) as? Paragraph {
                    parsed = Document(Paragraph(Array(paragraph.inlineChildren.dropFirst().dropLast())))
                }
                #expect(TreeDump.of(tree.document) == TreeDump.of(parsed), "seed \(seed)\n\(markdown)")
                compared += 1
            }
        }
        #expect(compared > 500)
    }

    /// Marks without the whitespace at their edges, and none over whitespace alone: markdown
    /// puts delimiters inside the spaces (`**a** b`), so only such marks read back the same.
    static func trimmingMarks(_ doc: Doc) -> Doc {
        var doc = doc
        for index in doc.blocks.indices {
            let units = Array(doc.blocks[index].text.string.utf16)
            func blank(_ offset: Int) -> Bool { [0x20, 0x09, 0x0A].contains(units[offset]) }
            var text = doc.blocks[index].text
            text.marks = text.marks.compactMap { span in
                guard !span.mark.kind.isAtom, span.mark != .code else { return span }
                var lower = span.range.lowerBound, upper = span.range.upperBound
                while lower < upper, blank(lower) { lower += 1 }
                while upper > lower, blank(upper - 1) { upper -= 1 }
                return lower < upper ? MarkSpan(range: lower..<upper, mark: span.mark) : nil
            }
            text.normalize()
            doc.blocks[index].text = text
        }
        return doc
    }

    @Test
    func textIsTakenAsItIs() throws {
        let text = "a ==not highlight== costs $5 and $6, :circle[x] **y** ^[z](color: red) <b>"
        let doc = Doc(id: fixedID(0), blocks: [DocBlock(id: fixedID(1), kind: .paragraph, text: DocText(string: text))])
        let tree = try #require(doc.markupTree(of: fixedID(1)))
        #expect(TreeDump.of(tree.document) == "Document[Paragraph[Text(\(text))]]")
    }

    @Test
    func mathsIsADirectiveAndCellsAreTakenAsTheyAre() throws {
        let column = Column(id: fixedID(10), name: "a|b *c*", type: .text)
        let database = Database(id: fixedID(11), columns: [column], rows: [
            Row(id: fixedID(12), cells: [column.id: .text(value: "a ==x== $5 and $6\nnext")]),
            Row(id: fixedID(13), cells: [:]),
        ])
        let doc = Doc(id: fixedID(0), blocks: [
            DocBlock(id: fixedID(1), kind: .math, text: DocText(string: "\\frac{1}{2}\n+ x")),
            DocBlock(id: fixedID(2), kind: .database(id: database.id, view: .table(hidden: [], sort: []))),
        ], databases: [database.id: database])
        let math = try #require(doc.markupTree(of: fixedID(1)))
        #expect(TreeDump.of(math.document) == "Document[Directive(math)[Paragraph[Text(\\frac{1}{2}\n+ x)]]]")
        let table = try #require(doc.markupTree(of: fixedID(2)))
        #expect(TreeDump.of(table.document) == "Document[Table[\"-\"][Head[Cell[Text(a|b *c*)]], Body[Row[Cell[Text(a ==x== $5 and $6 next)]], Row[Cell]]]]")
    }
}

/// A tree as a string: node kinds, what they carry, children, adjacent text joined
/// (cmark splits text at escapes and entities); a default highlight as `==` text.
enum TreeDump {
    static func of(_ markup: any Markup) -> String {
        var children: [String] = []
        var text = ""
        func flush() {
            if !text.isEmpty { children.append("Text(\(text))") }
            text = ""
        }
        func add(_ nodes: some Sequence<any Markup>) {
            for child in nodes {
                if let piece = child as? Text {
                    text += piece.string
                } else if let attributes = child as? InlineAttributes, attributes.attributes == "highlight" {
                    // `==…==` around what it holds, at its level.
                    text += "=="
                    add(attributes.children)
                    text += "=="
                } else {
                    flush()
                    children.append(of(child))
                }
            }
        }
        add(markup.children)
        flush()
        let name: String = switch markup {
        case let heading as Heading: "Heading\(heading.level)"
        case let list as OrderedList: "OrderedList\(list.startIndex)"
        case let item as ListItem: "ListItem\(item.checkbox.map { "\($0)" } ?? "")"
        case let link as Link: "Link(\(link.destination ?? "") \(link.title ?? ""))"
        case let attributes as InlineAttributes: "Attributes(\(attributes.attributes))"
        case let code as InlineCode: "Code(\(code.code))"
        case let code as CodeBlock: "CodeBlock(\(code.language ?? "") \(code.code.debugDescription))"
        case let directive as BlockDirective: "Directive(\(directive.name))"
        case let table as Table: "Table\(table.columnAlignments.map { $0.map { "\($0)" } ?? "-" })"
        default: String(describing: type(of: markup))
        }
        return children.isEmpty ? name : "\(name)[\(children.joined(separator: ", "))]"
    }
}

/// A doc with ids and database ids stripped, for comparing round trips.
private struct Shape: Equatable {
    var kind: BlockKind
    var indent: Int
    var text: DocText
    var table: [[String]]?

    static func of(_ doc: Doc) -> [Shape] {
        doc.blocks.map { block in
            guard case .database(let id, _) = block.kind, let database = doc.databases[id] else {
                return Shape(kind: block.kind, indent: block.indent, text: block.text)
            }
            var table = [database.columns.map(\.name)]
            for row in database.rows {
                table.append(database.columns.map { column in
                    if case .text(let value) = row.cells[column.id] { value } else { "" }
                })
            }
            return Shape(kind: .database(id: fixedID(0), view: .table(hidden: [], sort: [])), indent: block.indent, text: DocText(), table: table)
        }
    }
}

private enum CanonicalDoc {
    static let words = [
        "alpha", "beta", "x1", "snake_case", "a*b", "[ref]", "<tag>", "`tick`", "$5", "~tilde~",
        "back\\slash", "pipe|bar", "AT&T", "&amp;", "#hash", "-dash", "+plus", ">gt", "1.", "2)", "(paren)",
        "!bang", "中文", "测试", "日本語", "，", "😀", "👨‍👩‍👧", "🇫🇷", "^[sup]", "a^b",
    ]
    static let latex = ["x^2", "\\alpha", "a_{1}", "\\frac{1}{2}"]
    static let marks: [Mark] = [.bold, .italic, .strike, .code, .highlight(color: nil), .link(url: "https://e.com/p1"), .link(url: "https://e.com/a b"),
                                .color("red"), .color("#3366ff"), .highlight(color: "yellow"), .pen(kind: "circle", color: "blue"), .pen(kind: "wavy", color: nil)]

    static func pick<T>(_ items: [T], _ rng: inout SplitMix64) -> T {
        items[Int(rng.next() % UInt64(items.count))]
    }

    static func doc(using rng: inout SplitMix64) -> Doc {
        var blocks: [DocBlock] = []
        var databases: [DatabaseID: Database] = [:]
        for _ in 0..<(1 + rng.next() % 8) {
            let id: DocBlockID = Identifier.generate(at: fixedTime(0), using: &rng)
            let previousList = blocks.last.flatMap { block -> Int? in
                if case .listItem = block.kind { block.indent } else { nil }
            }
            switch rng.next() % 12 {
            case 0, 1, 2:
                blocks.append(DocBlock(id: id, kind: .paragraph, text: text(lines: 3, &rng)))
            case 3:
                blocks.append(DocBlock(id: id, kind: .heading(level: 1 + Int(rng.next() % 6)), text: text(lines: 1, &rng)))
            case 4, 5:
                let style = pick([ListStyle.bullet, .numbered, .task(done: true), .task(done: false)], &rng)
                let indent = previousList.map { Int(rng.next() % UInt64(min($0 + 2, 7))) } ?? 0
                blocks.append(DocBlock(id: id, kind: .listItem(style: style), indent: indent, text: text(lines: 2, &rng)))
            case 6:
                blocks.append(DocBlock(id: id, kind: pick([.quote, .caption], &rng), text: text(lines: 2, &rng)))
            case 7:
                let body = (0..<(rng.next() % 3)).map { _ in pick(["let a = 1", "```", "  indented", "$x$", "a == b"], &rng) }
                blocks.append(DocBlock(id: id, kind: .code(language: pick([nil, "swift"], &rng)), text: DocText(string: body.joined(separator: "\n"))))
            case 8:
                blocks.append(DocBlock(id: id, kind: .math, text: DocText(string: pick(latex, &rng))))
            case 9:
                blocks.append(DocBlock(id: id, kind: pick([
                    .divider, .image(image: DocImage(source: "a b.png", alt: "pic [1]")),
                    .link(link: DocLink(url: "https://a.com/p?q=1", title: pick(["", "Page [1]", "标题"], &rng))),
                    .file(file: DocFile(source: "blob:9", name: "a (1).docx")),
                ], &rng)))
            case 10:
                let card = DocCard(size: "m", view: pick([nil, "chart"], &rng), source: pick([nil, "<svg/>"], &rng), data: ["n": 1, "s": "x"])
                let view = DocView(source: pick(["VStack {}", "Text(\"```\")"], &rng), data: pick([nil, ["n": 1]], &rng))
                blocks.append(DocBlock(id: id, kind: pick([.card(card: card), .view(view: view)], &rng)))
            default:
                let database = table(&rng)
                databases[database.id] = database
                blocks.append(DocBlock(id: id, kind: .database(id: database.id, view: .table(hidden: [], sort: []))))
            }
        }
        return Doc(id: fixedID(0), blocks: blocks, databases: databases)
    }

    static func table(_ rng: inout SplitMix64) -> Database {
        let columns = (0..<(1 + rng.next() % 3)).map { _ in
            Column(id: Identifier.generate(at: fixedTime(0), using: &rng), name: pick(words, &rng), type: .text)
        }
        let rows = (0..<(rng.next() % 4)).map { _ in
            var cells: [ColumnID: CellValue] = [:]
            for column in columns where rng.next() % 3 != 0 {
                cells[column.id] = .text(value: pick(words, &rng) + " " + pick(words, &rng))
            }
            return Row(id: Identifier.generate(at: fixedTime(0), using: &rng), cells: cells)
        }
        return Database(id: Identifier.generate(at: fixedTime(0), using: &rng), columns: columns, rows: rows)
    }

    /// Lines of space-separated tokens; atoms are tokens of their own.
    /// Marks cover whole tokens within a line, nest properly, never cover
    /// atoms, and nothing nests inside code.
    static func text(lines: Int, _ rng: inout SplitMix64) -> DocText {
        var string = ""
        var length = 0
        var tokens: [(range: Range<Int>, line: Int, atom: Bool)] = []
        var spans: [MarkSpan] = []
        for line in 0..<(1 + Int(rng.next() % UInt64(lines))) {
            if line > 0 {
                string += "\n"
                length += 1
            }
            for index in 0..<(1 + rng.next() % 5) {
                if index > 0 {
                    string += " "
                    length += 1
                }
                let start = length
                switch rng.next() % 10 {
                case 0:
                    string.append(DocText.atomCharacter)
                    length += 1
                    spans.append(MarkSpan(range: start..<length, mark: .inlineMath(latex: pick(latex, &rng))))
                    tokens.append((start..<length, line, true))
                case 1:
                    string.append(DocText.atomCharacter)
                    length += 1
                    spans.append(MarkSpan(range: start..<length, mark: .cite(url: "https://c.com/1", label: pick(["Apple", "维基", "ref 1"], &rng))))
                    tokens.append((start..<length, line, true))
                default:
                    let word = pick(words, &rng)
                    string += word
                    length += word.utf16.count
                    tokens.append((start..<length, line, false))
                }
            }
        }
        for _ in 0..<(rng.next() % 4) {
            let first = Int(rng.next() % UInt64(tokens.count))
            let last = first + Int(rng.next() % 3)
            guard last < tokens.count, tokens[first].line == tokens[last].line,
                !tokens[first...last].contains(where: \.atom)
            else { continue }
            let range = tokens[first].range.lowerBound..<tokens[last].range.upperBound
            let mark = pick(marks, &rng)
            if fits(MarkSpan(range: range, mark: mark), among: spans) {
                spans.append(MarkSpan(range: range, mark: mark))
            }
        }
        var text = DocText(string: string, marks: spans)
        text.normalize()
        return text
    }

    private static func fits(_ span: MarkSpan, among spans: [MarkSpan]) -> Bool {
        for other in spans where !other.mark.kind.isAtom {
            let disjoint = span.range.upperBound <= other.range.lowerBound || other.range.upperBound <= span.range.lowerBound
            if disjoint { continue }
            if other.mark.kind == span.mark.kind { return false }
            let inside = other.range.lowerBound <= span.range.lowerBound && span.range.upperBound <= other.range.upperBound
            let around = span.range.lowerBound <= other.range.lowerBound && other.range.upperBound <= span.range.upperBound
            if !(inside || around) { return false }
            if (inside && other.mark == .code) || (around && span.mark == .code) { return false }
        }
        return true
    }
}
