import Foundation
import Testing

@testable import DocKit

private func block(_ n: UInt64, _ kind: BlockKind, indent: Int = 0, _ string: String = "", marks: [MarkSpan] = []) -> DocBlock {
    DocBlock(id: fixedID(n), kind: kind, indent: indent, text: DocText(string: string, marks: marks))
}

private func span(_ lower: Int, _ upper: Int, _ mark: Mark) -> MarkSpan {
    MarkSpan(range: lower..<upper, mark: mark)
}

private func parse(_ markdown: String) -> DocFragment {
    var rng = SplitMix64(seed: 7)
    return DocFragment(markdown: markdown, at: fixedTime(0), using: &rng)
}

/// Markdown → fragment → markdown, for checking canonical forms.
private func normalized(_ markdown: String) -> String {
    let fragment = parse(markdown)
    return Doc(id: fixedID(0), blocks: fragment.blocks, databases: fragment.databases).markdown
}

@Suite
struct MarkdownExportTests {
    @Test
    func blocksAndLists() {
        let doc = Doc(id: fixedID(0), blocks: [
            block(1, .heading(level: 2), "Plan"),
            block(2, .paragraph, "Ship the model\nthen the view", marks: [span(9, 14, .bold)]),
            block(3, .listItem(style: .bullet), "one"),
            block(4, .listItem(style: .numbered), indent: 1, "first"),
            block(5, .listItem(style: .numbered), indent: 1, "second"),
            block(6, .listItem(style: .task(done: true)), indent: 2, "done"),
            block(7, .listItem(style: .bullet), "two"),
            block(8, .quote, "said\nonce"),
            block(9, .code(language: "swift"), "let a = `b`"),
            block(10, .math, "x^2"),
            block(11, .divider),
        ])
        #expect(doc.markdown == """
            ## Plan

            Ship the **model**
            then the view

            - one
              1. first
              2. second
                 - [x] done
            - two

            > said
            > once

            ```swift
            let a = `b`
            ```

            $$
            x^2
            $$

            ---
            """)
        #expect(doc.markdown(of: fixedID(5)) == "2. second")
    }

    @Test
    func inlineMarksAndAtoms() {
        let text = DocText(string: "a bold\u{FFFC} code [x] $5 link", marks: [
            span(2, 6, .bold), span(6, 7, .inlineMath(latex: "\\alpha")), span(8, 12, .code),
            span(20, 24, .link(url: "https://e.com/a b")),
        ])
        #expect(text.markdown() == "a **bold**$\\alpha$ `code` [x\\] \\$5 [link](<https://e.com/a b>)")
    }

    @Test
    func overlappingMarksReopenAtWords() {
        // bold "a b", italic "b c": the italic reopens after the space.
        let text = DocText(string: "a b c", marks: [span(0, 3, .bold), span(2, 5, .italic)])
        #expect(text.markdown() == "**a *b*** *c*")
        let trailing = DocText(string: "bold next", marks: [span(0, 5, .bold)])
        #expect(trailing.markdown() == "**bold** next")
    }

    @Test
    func lineStartEscapes() {
        #expect(DocText(string: "# not a heading\n- not a list\n1. not numbered").markdown()
            == "\\# not a heading\n\\- not a list\n1\\. not numbered")
    }

    @Test
    func cardsAndTables() {
        let column = Column(id: fixedID(20), name: "Name", type: .text)
        let done = Column(id: fixedID(21), name: "Done", type: .checkbox)
        let database = Database(id: fixedID(30), columns: [column, done], rows: [
            Row(id: fixedID(40), cells: [column.id: .text(value: "b|c"), done.id: .checkbox(value: true)]),
            Row(id: fixedID(41), cells: [column.id: .text(value: "a")]),
        ])
        let doc = Doc(id: fixedID(0), blocks: [
            block(1, .card(card: DocCard(size: "m", source: "<b/>", data: ["n": 1]))),
            block(2, .database(id: database.id, view: .table(hidden: [], sort: [DatabaseSort(column: column.id)]))),
        ], databases: [database.id: database])
        #expect(doc.markdown == """
            ```floo.card
            {"data":{"n":1},"size":"m","source":"<b/>"}
            ```

            | Name | Done |
            | --- | --- |
            | a |  |
            | b\\|c | ✓ |
            """)
    }

    @Test
    func isoDates() {
        #expect(Column.isoDate(fixedTime(0)) == "1970-01-01")
        #expect(Column.isoDate(fixedTime(1_791_158_400_000)) == "2026-10-05")
        #expect(Column.isoDate(fixedTime(-86_400_000)) == "1969-12-31")
    }
}

@Suite
struct MarkdownImportTests {
    @Test
    func blockKinds() {
        let fragment = parse("""
            # Title

            Para with **bold** and ==mark== and `code`.

            - a
              - [ ] b
            1. c

            > q

            ```js
            x()
            ```

            $$
            E = mc^2
            $$

            ***

            ![alt](img.png)
            """)
        let kinds = fragment.blocks.map(\.kind)
        #expect(kinds == [
            .heading(level: 1), .paragraph, .listItem(style: .bullet), .listItem(style: .task(done: false)),
            .listItem(style: .numbered), .quote, .code(language: "js"), .math, .divider,
            .image(image: DocImage(source: "img.png", alt: "alt")),
        ])
        #expect(fragment.blocks.map(\.indent) == [0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        let para = fragment.blocks[1].text
        #expect(para.string == "Para with bold and mark and code.")
        #expect(para.marks == [span(10, 14, .bold), span(19, 23, .highlight(color: nil)), span(28, 32, .code)])
        #expect(fragment.blocks[7].text.string == "E = mc^2")
        #expect(fragment.blocks[6].text.string == "x()")
    }

    @Test
    func mathLikeMarkdownView() {
        let text = parse("Cost $10/$50, area $\\pi r_1^2$ and \\(x_2\\) but `$code$`.").blocks[0].text
        #expect(text.string == "Cost $10/$50, area \u{FFFC} and \u{FFFC} but $code$.")
        #expect(text.marks.map(\.mark) == [.inlineMath(latex: "\\pi r_1^2"), .inlineMath(latex: "x_2"), .code])
    }

    @Test
    func citeLinksAndCards() {
        let fragment = parse("""
            See [Apple](https://apple.com "cite") and [docs](https://d.com).

            ```floo.card
            {"size":"s","data":{"k":[1,2]}}
            ```

            ```floo.card
            not json
            ```
            """)
        #expect(fragment.blocks[0].text.marks.map(\.mark) == [.cite(url: "https://apple.com", label: "Apple"), .link(url: "https://d.com")])
        #expect(fragment.blocks[1].kind == .card(card: DocCard(size: "s", data: ["k": [1, 2]])))
        #expect(fragment.blocks[2].kind == .code(language: "floo.card"))
    }

    @Test
    func bookmarksAndFilesAreTitledLinks() {
        let fragment = parse("""
            [Craft](https://www.craft.do "bookmark")

            [https://example.com/a](https://example.com/a "bookmark")

            [路线.pdf](blob:7f3a "file")

            [Craft](https://www.craft.do)
            """)
        #expect(fragment.blocks.map(\.kind) == [
            .link(link: DocLink(url: "https://www.craft.do", title: "Craft")),
            .link(link: DocLink(url: "https://example.com/a")),
            .file(file: DocFile(source: "blob:7f3a", name: "路线.pdf")),
            .paragraph,
        ])
    }

    @Test
    func bookmarksAndFilesExportAsTitledLinks() {
        let doc = Doc(id: fixedID(0), blocks: [
            block(1, .link(link: DocLink(url: "https://a.com/x", title: "A", summary: "s", image: "https://a.com/i.png", layout: .card))),
            block(2, .link(link: DocLink(url: "https://a.com/y"))),
            block(3, .file(file: DocFile(source: "blob:1", name: "plan.docx", size: 9216, layout: .small))),
        ])
        #expect(doc.markdown == """
            [A](https://a.com/x "bookmark")

            [https://a.com/y](https://a.com/y "bookmark")

            [plan.docx](blob:1 "file")
            """)
    }

    @Test
    func imagesWrittenBeforeFitAndSizeRead() throws {
        let image = try JSONDecoder().decode(DocImage.self, from: Data(#"{"source":"a.png","alt":""}"#.utf8))
        #expect(image == DocImage(source: "a.png"))
        #expect(image.fit == .fit && image.size == .auto)
    }

    @Test
    func tablesBecomeDatabases() throws {
        let fragment = parse("| A | B |\n| - | - |\n| 1 | x\\|y |\n|  | z |")
        guard case .database(let id, _) = fragment.blocks.first?.kind else {
            Issue.record("expected a database block")
            return
        }
        let database = try #require(fragment.databases[id])
        #expect(database.columns.map(\.name) == ["A", "B"])
        let a = database.columns[0].id
        let b = database.columns[1].id
        #expect(database.rows.map { $0.cells } == [[a: .text(value: "1"), b: .text(value: "x|y")], [b: .text(value: "z")]])
    }

    @Test
    func importedTextIsValid() throws {
        for markdown in Self.corpus {
            let fragment = parse(markdown)
            let doc = Doc(id: fixedID(0), blocks: fragment.blocks, databases: fragment.databases)
            do {
                try doc.validate()
            } catch {
                Issue.record("invalid import of \(markdown.debugDescription): \(error)")
            }
        }
    }

    /// Export of an import is a fixed point: importing it again and
    /// exporting gives the same markdown.
    @Test
    func exportIsAFixedPoint() {
        for markdown in Self.corpus {
            let once = normalized(markdown)
            #expect(normalized(once) == once, "not stable: \(markdown.debugDescription) → \(once.debugDescription)")
        }
    }

    static let corpus = [
        "Hello *world* and **bold *nested*** text",
        "a**b**c and _under_ and ~~gone~~ and ==hi== there",
        "**bold $x$ around** math",
        "line one\nline two\\\nhard",
        "1. a\n2. b\n   1. c\n10. d",
        "- [x] done\n- [ ] todo\n  more text\n\n  second para",
        "> quote **b**\n>\n> second",
        "```\ncode with ``` inside\n```",
        "Text with <span>html</span> & entity &amp; done",
        "<div>\nblock html\n</div>",
        "$$x$$ inline display? and \\[y\\]",
        "\\begin{equation}\na=b\n\\end{equation}",
        "Escapes: \\* \\_ \\` \\[ \\] \\$ \\\\ \\# \\>",
        "# H1 with `code` and [link](u)\n## H2",
        "| a | b |\n|---|---|\n| `c` | **d** |",
        "中文**粗体**和*斜体*，还有==高亮==。",
        "emoji 👨‍👩‍👧 **🇫🇷** done",
        "[a](x \"cite\")[b](y \"cite\") chips",
        "- a\n\n- loose\n\n- list",
        "Setext\n===\n\nAnd\n---",
        "    indented code",
        "![img](a.png) inline image",
        "trailing two spaces  \nnext",
        "a == b and c === d",
    ]
}

@Suite
struct MarkdownEditingStyleTests {
    /// What an editor renders must read back as exactly the model's text,
    /// spaces at line edges included; an empty block keeps a line.
    @Test
    func whitespaceSurvives() {
        let texts = ["a ", "  b", "c  \n d", "x\t", "  ", "# not heading  ", "**", "a  b   c", "don't", "\"q\" 'r'", "a--b", "x...", "a-b. c."]
        for string in texts {
            let doc = Doc(id: fixedID(0), blocks: [block(1, .paragraph, string)])
            let markdown = doc.markdown(of: fixedID(1), style: .editing) ?? ""
            let back = parse(markdown).blocks.first?.text.string
            #expect(back == string, "\(string.debugDescription) → \(markdown.debugDescription) → \(String(describing: back?.debugDescription))")
        }
    }

    @Test
    func emptyBlocksKeepALine() {
        let doc = Doc(id: fixedID(0), blocks: [
            block(1, .paragraph), block(2, .heading(level: 2)), block(3, .listItem(style: .bullet)), block(4, .quote),
        ])
        #expect(doc.markdown(of: fixedID(1), style: .editing) == "&#8203;")
        #expect(doc.markdown(of: fixedID(2), style: .editing) == "## &#8203;")
        #expect(doc.markdown(of: fixedID(3), style: .editing) == "- &#8203;")
        #expect(doc.markdown(of: fixedID(4), style: .editing) == "> &#8203;")
        #expect(parse("- &#8203;").blocks.first?.text.string == "\u{200B}")
    }

    /// A line break inside a block shows as one (a soft break could render as a
    /// space); an empty last line keeps its line like an empty block.
    @Test
    func lineBreaksShow() {
        let doc = Doc(id: fixedID(0), blocks: [
            block(1, .paragraph, "a\nb"), block(2, .quote, "a\nb"), block(3, .quote, "a\n"), block(4, .paragraph, "a\n\nb"),
        ])
        #expect(doc.markdown(of: fixedID(1), style: .editing) == "a\\\nb")
        #expect(doc.markdown(of: fixedID(2), style: .editing) == "> a\\\n> b")
        #expect(doc.markdown(of: fixedID(3), style: .editing) == "> a\\\n> &#8203;")
        #expect(doc.markdown(of: fixedID(1), style: .exchange) == "a\nb")
        for id: UInt64 in [1, 2, 4] {
            let markdown = doc.markdown(of: fixedID(id), style: .editing) ?? ""
            let back = parse(markdown).blocks.first?.text.string
            #expect(back == doc.block(fixedID(id))?.text.string, "\(markdown.debugDescription) → \(String(describing: back?.debugDescription))")
        }
    }
}
