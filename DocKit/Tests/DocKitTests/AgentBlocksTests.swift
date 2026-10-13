import Foundation
import Testing

@testable import DocKit

private func block(_ n: UInt64, _ kind: BlockKind, indent: Int = 0, _ string: String = "", marks: [MarkSpan] = [], boxed: Bool = false) -> DocBlock {
    DocBlock(id: fixedID(n), kind: kind, indent: indent, text: DocText(string: string, marks: marks), decoration: boxed ? .block : nil)
}

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite
struct AgentBlocksTests {
    /// Every kind reads as JSON and writes back as the same block: nothing lost.
    @Test
    func everyKindRoundTrips() throws {
        let card = DocCard(size: "detail", source: "Text(name)", data: ["name": "Ada"])
        let blocks = [
            block(1, .heading(level: 3), "Plan", boxed: true),
            block(2, .paragraph, "Steps up 12%, sleep down", marks: [
                MarkSpan(range: 9..<12, mark: .bold), MarkSpan(range: 9..<12, mark: .color("green")),
                MarkSpan(range: 14..<24, mark: .highlight(color: "yellow")), MarkSpan(range: 20..<24, mark: .pen(kind: "wavy", color: "blue")),
            ]),
            block(3, .listItem(style: .task(done: true)), indent: 2, "Sleep early"),
            block(4, .listItem(style: .toggle(open: false)), "More"),
            block(5, .quote, "A quote"),
            block(6, .caption, "Small print"),
            block(7, .code(language: "swift"), "let x = 1\nlet y = 2"),
            block(8, .math, "e^{i\\pi} + 1 = 0"),
            block(9, .divider),
            block(10, .image(image: DocImage(source: "https://a.b/c.png", alt: "Chart", fit: .fill, size: .large))),
            block(11, .link(link: DocLink(url: "https://a.b", title: "A", summary: "B", image: "https://a.b/i.png", layout: .card))),
            block(12, .file(file: DocFile(source: "blob:1", name: "plan.pdf", size: 2048, layout: .small))),
            block(13, .card(card: card)),
            block(14, .view(view: DocView(source: "VStack {}", data: ["n": 2]))),
        ]
        let doc = Doc(id: fixedID(0), blocks: blocks)
        for original in blocks {
            var databases = doc.databases
            let read = AgentBlocks.json(original, in: doc, full: true)
            let written = try AgentBlocks.block(read, id: original.id, databases: &databases, results: [:])
            #expect(written == original, "\(read)")
        }
    }

    /// Styled text reads as runs, atoms included, and writes back the same; plain text
    /// is a string.
    @Test
    func textRunsRoundTrip() throws {
        var text = DocText(string: "Ask \u{FFFC} about x \u{FFFC} now", marks: [
            MarkSpan(range: 4..<5, mark: .mention(kind: "person", id: "u1", label: "Ada")),
            MarkSpan(range: 0..<3, mark: .italic),
            MarkSpan(range: 14..<15, mark: .inlineMath(latex: "x^2")),
            MarkSpan(range: 16..<19, mark: .link(url: "https://a.b")),
        ])
        text.normalize()
        let runs = AgentBlocks.json(text)
        #expect(try AgentBlocks.text(runs) == text)
        #expect(AgentBlocks.json(DocText(string: "plain")) == .string("plain"))
        // Written runs: styles over each run's text.
        let written = try AgentBlocks.text(json(#"["Up ", {"text": "12%", "bold": true, "color": "green"}, " this week"]"#))
        #expect(written.string == "Up 12% this week")
        #expect(Set(written.marks) == [MarkSpan(range: 3..<6, mark: .bold), MarkSpan(range: 3..<6, mark: .color("green"))])
    }

    /// A table is its database: columns typed, rows by column name, a select's options
    /// gathered from its cells; a kanban groups by a select.
    @Test
    func tablesBecomeDatabases() throws {
        var databases: [DatabaseID: Database] = [:]
        let written = try AgentBlocks.block(json(#"""
            {"type": "kanban", "group_by": "Status",
             "columns": [{"name": "Task"}, {"name": "Status", "type": "select"}, {"name": "Due", "type": "date"}, {"name": "Hours", "type": "number"}],
             "rows": [{"Task": "Draft", "Status": "Doing", "Due": "2026-10-14", "Hours": 3}, ["Review", "Todo", null, 1.5]]}
            """#), id: fixedID(1), databases: &databases, results: [:])
        guard case .database(let id, .kanban(let group, _, _)) = written.kind, let database = databases[id] else {
            Issue.record("not a kanban: \(written.kind)")
            return
        }
        #expect(database.columns.first { $0.id == group }?.name == "Status")
        #expect(database.rows.count == 2)
        let doc = Doc(id: fixedID(0), blocks: [written], databases: databases)
        let read = AgentBlocks.json(written, in: doc)
        #expect(read["rows"]?[0]?["Due"] == "2026-10-14")
        #expect(read["rows"]?[1]?["Status"] == "Todo")
        #expect(read["columns"]?[1]?["options"] == ["Doing", "Todo"])
    }

    /// What an agent gets wrong comes back as words it can act on.
    @Test
    func mistakesAreExplained() {
        var databases: [DatabaseID: Database] = [:]
        func error(_ text: String) -> String? {
            do {
                _ = try AgentBlocks.block(json(text), id: fixedID(1), databases: &databases, results: ["week_1": [1]])
                return nil
            } catch {
                return error.message
            }
        }
        #expect(error(#"{"type": "chart"}"#)?.contains("unknown block type") == true)
        #expect(error(#"{"type": "paragraph", "text": [{"text": "x", "color": "pink"}]}"#)?.contains("a colour is one of") == true)
        #expect(error(#"{"type": "card", "size": "huge", "source": "Text(\"x\")"}"#)?.contains("glance, summary") == true)
        #expect(error(#"{"type": "view", "source": "Text(\"x\")", "from": "week_2"}"#)?.contains("week_1") == true)
    }
}

@Suite
struct AgentEditTests {
    private func doc() -> Doc {
        Doc(id: fixedID(0), blocks: [
            block(1, .heading(level: 1), "Week"),
            block(2, .paragraph, "Steps went up and sleep went down."),
            block(3, .listItem(style: .task(done: false)), "Walk more"),
            block(4, .listItem(style: .task(done: false)), "Sleep early"),
        ])
    }

    private func short(_ n: UInt64) -> String { AgentBlocks.shortID(fixedID(n)) }

    /// New blocks go after a block, before one, or at the end, in the order written.
    @Test
    func insertPlacesBlocks() {
        var doc = doc()
        let results = doc.agentEdit([
            json(#"{"op": "insert", "after": "\#(short(1))", "blocks": [{"type": "caption", "text": "Oct 5 – 11"}]}"#),
            json(#"{"op": "insert", "before": "\#(short(3))", "blocks": [{"type": "heading", "level": 2, "text": "Next"}, "plain"]}"#),
            json(#"{"op": "insert", "blocks": [{"type": "divider"}]}"#),
        ])
        #expect(results.allSatisfy { $0.error == nil }, "\(results.map(\.json))")
        #expect(doc.blocks.map(\.text.string) == ["Week", "Oct 5 – 11", "Steps went up and sleep went down.", "Next", "plain", "Walk more", "Sleep early", ""])
    }

    /// An edit changes words inside a block, styled as written, leaving the rest; set
    /// changes a block's fields; delete and move do what they say.
    @Test
    func editSetDeleteMove() throws {
        var doc = doc()
        let results = doc.agentEdit([
            json(#"{"op": "edit", "id": "\#(short(2))", "find": "went up", "replace": [{"text": "rose 12%", "bold": true}]}"#),
            json(#"{"op": "set", "id": "\#(short(3))", "done": true}"#),
            json(#"{"op": "set", "id": "\#(short(1))", "level": 2, "boxed": true}"#),
            json(#"{"op": "move", "id": "\#(short(4))", "after": "\#(short(1))"}"#),
            json(#"{"op": "delete", "id": "\#(short(3))"}"#),
        ])
        #expect(results.allSatisfy { $0.error == nil }, "\(results.map(\.json))")
        #expect(doc.blocks.map(\.id) == [fixedID(1), fixedID(4), fixedID(2)])
        let paragraph = try #require(doc.block(fixedID(2)))
        #expect(paragraph.text.string == "Steps rose 12% and sleep went down.")
        #expect(paragraph.text.marks == [MarkSpan(range: 6..<14, mark: .bold)])
        #expect(doc.block(fixedID(1))?.kind == .heading(level: 2) && doc.block(fixedID(1))?.decoration == .block)
    }

    /// One operation that fails leaves the document as it was for it, and the others go on.
    @Test
    func aFailedOperationStandsAlone() {
        var doc = doc()
        let before = doc
        let results = doc.agentEdit([
            json(#"{"op": "edit", "id": "\#(short(2))", "find": "went", "replace": "was"}"#),
            json(#"{"op": "insert", "blocks": [{"type": "paragraph", "text": "ok"}, {"type": "nope"}]}"#),
            json(#"{"op": "delete", "id": "zzzzzzzz"}"#),
            json(#"{"op": "set", "id": "\#(short(4))", "done": true}"#),
        ])
        #expect(results[0].error?.contains("2 times") == true)
        #expect(results[1].error?.contains("block 1: unknown block type") == true)
        #expect(results[2].error?.contains("no block zzzzzzzz") == true)
        #expect(results[3].error == nil)
        #expect(doc.blocks.count == before.blocks.count)
        #expect(doc.block(fixedID(4))?.kind == .listItem(style: .task(done: true)))
    }

    /// A card's or a view's data can come from a result by name; read shows its outline
    /// unless asked for whole, and a set swaps its source keeping its data.
    @Test
    func drawnBlocksTakeResults() throws {
        var doc = doc()
        let week: JSONValue = ["days": [["date": "2026-10-05", "steps": 6210], ["date": "2026-10-06", "steps": 9830]]]
        let results = doc.agentEdit([
            json(#"{"op": "insert", "blocks": [{"type": "view", "source": "Text(\"\\(days.count)\")", "from": "health_week"}]}"#),
        ], results: ["health_week": week])
        let id = try #require(results[0].written.first)
        guard case .view(let view)? = doc.block(id)?.kind else {
            Issue.record("no view: \(results.map(\.json))")
            return
        }
        #expect(view.data == week)
        let outline = doc.agentRead()["blocks"]?[4]
        #expect(outline?["data_outline"]?["days"] == "2 items like {date, steps}" && outline?["source"] == nil)
        #expect(doc.agentRead(full: [id])["blocks"]?[4]?["source"] == .string(view.source))
        _ = doc.agentEdit([json(#"{"op": "set", "id": "\#(AgentBlocks.shortID(id))", "source": "Text(\"new\")"}"#)])
        guard case .view(let updated)? = doc.block(id)?.kind else { return }
        #expect(updated.source == "Text(\"new\")" && updated.data == week)
    }
}
