import Foundation
import Testing

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
        "!bang", "中文", "测试", "日本語", "，", "😀", "👨‍👩‍👧", "🇫🇷",
    ]
    static let latex = ["x^2", "\\alpha", "a_{1}", "\\frac{1}{2}"]
    static let marks: [Mark] = [.bold, .italic, .strike, .code, .highlight(color: nil), .link(url: "https://e.com/p1"), .link(url: "https://e.com/a b")]

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
                blocks.append(DocBlock(id: id, kind: .quote, text: text(lines: 2, &rng)))
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
                blocks.append(DocBlock(id: id, kind: .card(card: card)))
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
