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
            block(15, .page(page: DocPage(doc: fixedID(70), title: "Trip notes", preview: "Flights · Hotel"))),
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
    /// gathered from its cells.
    @Test
    func tablesBecomeDatabases() throws {
        var databases: [DatabaseID: Database] = [:]
        let written = try AgentBlocks.block(json(#"""
            {"type": "table", "sort": [{"column": "Hours", "ascending": false}],
             "columns": [{"name": "Task"}, {"name": "Status", "type": "select"}, {"name": "Due", "type": "date"}, {"name": "Hours", "type": "number"}],
             "rows": [{"Task": "Draft", "Status": "Doing", "Due": "2026-10-14", "Hours": 3}, ["Review", "Todo", null, 1.5]]}
            """#), id: fixedID(1), databases: &databases, results: [:])
        guard case .database(let id, .table(_, let sort)) = written.kind, let database = databases[id] else {
            Issue.record("not a table: \(written.kind)")
            return
        }
        #expect(sort.map(\.column) == [database.columns[3].id] && sort.first?.ascending == false)
        #expect(database.rows.count == 2)
        let doc = Doc(id: fixedID(0), blocks: [written], databases: databases)
        let read = AgentBlocks.json(written, in: doc)
        #expect(read["rows"]?[0]?["Due"] == "2026-10-14")
        #expect(read["rows"]?[1]?["Status"] == "Todo")
        #expect(read["columns"]?[1]?["options"] == ["Doing", "Todo"])
    }

    /// A collection is its records and the views of them: read back, it writes the same
    /// views over the same columns; a kanban alone also gets a table of its records.
    @Test
    func collectionsKeepTheirViews() throws {
        var databases: [DatabaseID: Database] = [:]
        let written = try AgentBlocks.block(json(#"""
            {"type": "collection", "name": "Sprint",
             "columns": [{"name": "Task"}, {"name": "Status", "type": "select", "options": [{"name": "Doing", "color": "blue"}, "Done"]}],
             "rows": [{"Task": "Draft", "Status": "Doing"}, {"Task": "Ship", "Status": "Done"}],
             "views": [{"name": "Board", "layout": "kanban", "group_by": "Status"}, {"name": "All", "layout": "table", "hidden": ["Status"]}],
             "current": "All"}
            """#), id: fixedID(1), databases: &databases, results: [:])
        guard case .collection(let collection) = written.kind, let database = databases[collection.database] else {
            Issue.record("not a collection: \(written.kind)")
            return
        }
        let status = try #require(database.columns.first { $0.name == "Status" })
        #expect(collection.name == "Sprint" && collection.currentView?.name == "All")
        #expect(collection.views.map(\.layout) == [.kanban(groupBy: status.id, hidden: [], sort: []), .table(hidden: [status.id], sort: [])])
        #expect(status.type == .select(options: [SelectOption(id: optionID(status, "Doing"), name: "Doing", color: "blue"), SelectOption(id: optionID(status, "Done"), name: "Done")]))
        let doc = Doc(id: fixedID(0), blocks: [written], databases: databases)
        let read = AgentBlocks.json(written, in: doc)
        #expect(read["views"]?[0]?["group_by"] == "Status" && read["current"] == "All")
        #expect(read["columns"]?[1]?["options"]?[0]?["color"] == "blue")
        var again = databases
        guard case .collection(let rewritten) = try AgentBlocks.block(read, id: written.id, databases: &again, results: [:]).kind else { return }
        #expect(rewritten.views.map(\.name) == ["Board", "All"] && rewritten.currentView?.name == "All")

        var kanban: [DatabaseID: Database] = [:]
        let board = try AgentBlocks.block(json(#"{"type": "kanban", "columns": [{"name": "T"}, {"name": "S", "type": "select"}], "rows": [["a", "x"]]}"#),
                                          id: fixedID(2), databases: &kanban, results: [:])
        guard case .collection(let boardCollection) = board.kind else { return }
        #expect(boardCollection.views.map(\.name) == ["Kanban", "Table"])
    }

    /// A table's cells are taken as their columns hold them, or explained: a bare domain is
    /// a link, the same option twice is once, and a value of the wrong kind or for a column
    /// that isn't there is an error naming what fits.
    @Test
    func cellsAreWhatTheirColumnsHold() throws {
        var databases: [DatabaseID: Database] = [:]
        func table(_ row: String) throws(AgentFormatError) -> Database? {
            let written = try AgentBlocks.block(json(#"{"type": "table", "columns": [{"name": "Link", "type": "url"}, {"name": "Done", "type": "checkbox"}, {"name": "Tags", "type": "multi_select"}, {"name": "Who", "type": "person"}], "rows": ["# + row + #"]}"#),
                                                id: fixedID(1), databases: &databases, results: [:])
            guard case .database(let id, _) = written.kind else { return nil }
            return databases[id]
        }
        func error(_ row: String) -> String? {
            do { _ = try table(row); return nil } catch { return error.message }
        }
        let database = try #require(try table(#"{"Link": "example.com/a", "Done": true, "Tags": ["x", "x", "y"], "Who": ""}"#))
        let row = try #require(database.rows.first)
        #expect(row.cells[database.columns[0].id] == .url(value: "https://example.com/a"))
        #expect(row.cells[database.columns[2].id].map { if case .multiSelect(let ids) = $0 { ids.count } else { 0 } } == 2)
        #expect(row.cells[database.columns[3].id] == nil)
        #expect(error(#"{"Link": "not a link"}"#)?.contains("holds links") == true)
        #expect(error(#"{"Done": "yes"}"#)?.contains("true or false") == true)
        #expect(error(#"{"Tags": [1]}"#)?.contains("option names") == true)
        #expect(error(#"{"Who": 3}"#)?.contains("names") == true)
        #expect(error(#"{"Owner": "Sam"}"#)?.contains("the columns are Link, Done, Tags, Who") == true)
        #expect(error(#"["a", true, [], "b", "extra"]"#)?.contains("5 values for 4 columns") == true)
    }

    private func optionID(_ column: Column, _ name: String) -> OptionID {
        switch column.type {
        case .select(let options), .multiSelect(let options): options.first { $0.name == name }!.id
        default: OptionID.generate()
        }
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

    /// A set changes a collection's views and which one shows, over the database it keeps:
    /// the columns its views name are the database's own.
    @Test
    func aSetKeepsACollectionsRecords() throws {
        var doc = doc()
        let results = doc.agentEdit([json(#"""
            {"op": "insert", "blocks": [{"type": "kanban", "name": "Tasks", "group_by": "Owner",
             "columns": [{"name": "Task"}, {"name": "Owner", "type": "select"}], "rows": [["Walk", "Ada"], ["Sleep", "Bo"]]}]}
            """#)])
        let id = try #require(results[0].written.first)
        guard case .collection(let before)? = doc.block(id)?.kind, let database = doc.databases[before.database] else { return }
        let owner = try #require(database.columns.first { $0.name == "Owner" })
        let set = doc.agentEdit([json(#"{"op": "set", "id": "\#(AgentBlocks.shortID(id))", "current": "Table", "name": "Chores"}"#)])
        #expect(set[0].error == nil, "\(set.map(\.json))")
        guard case .collection(let after)? = doc.block(id)?.kind else { return }
        #expect(after.database == before.database && after.name == "Chores")
        #expect(after.currentView?.id == before.views[1].id)
        #expect(after.views[0].layout == .kanban(groupBy: owner.id, hidden: [], sort: []))
        #expect(doc.databases.count == 1)
    }

    /// A view's filters are read and written by column and option names; a set keeps them
    /// on the records it keeps, and the fields' order the document gave the view.
    @Test
    func collectionFiltersRoundTrip() throws {
        var doc = doc()
        let results = doc.agentEdit([json(#"""
            {"op": "insert", "blocks": [{"type": "collection", "name": "Tasks",
             "columns": [{"name": "Task"}, {"name": "Owner", "type": "select"}, {"name": "Hours", "type": "number"}],
             "rows": [["Walk", "Ada", 2], ["Sleep", "Bo", 8], ["Read", "Ada", 1]],
             "views": [{"name": "Ada's", "layout": "table", "filter": [{"column": "Owner", "condition": "is", "value": "Ada"},
                                                                       {"column": "Hours", "condition": "greater_than", "value": 1}]}]}]}
            """#)])
        #expect(results[0].error == nil, "\(results.map(\.json))")
        let id = try #require(results[0].written.first)
        guard case .collection(var collection)? = doc.block(id)?.kind, let database = doc.databases[collection.database] else { return }
        #expect(collection.views[0].records(of: database).map { $0.cells[database.columns[0].id] } == [.text(value: "Walk")])
        let read = AgentBlocks.json(doc.block(id)!, in: doc)
        #expect(read["views"]?[0]?["filter"]?[0]?["value"] == "Ada" && read["views"]?[0]?["filter"]?[1]?["condition"] == "greater_than")

        // The person's own order of the fields stays through a set.
        collection.views[0].order = [database.columns[2].id]
        doc.blocks[doc.blocks.firstIndex { $0.id == id }!].kind = .collection(collection: collection)
        let set = doc.agentEdit([json(#"""
            {"op": "set", "id": "\#(AgentBlocks.shortID(id))", "views": [{"name": "Ada's", "layout": "table", "filter": {"column": "Owner", "condition": "is", "value": "Bo"}}]}
            """#)])
        #expect(set[0].error == nil, "\(set.map(\.json))")
        guard case .collection(let after)? = doc.block(id)?.kind else { return }
        #expect(after.views[0].order == [database.columns[2].id])
        #expect(after.views[0].records(of: database).map { $0.cells[database.columns[0].id] } == [.text(value: "Sleep")])

        let wrong = doc.agentEdit([json(#"""
            {"op": "set", "id": "\#(AgentBlocks.shortID(id))", "views": [{"name": "x", "filter": {"column": "Owner", "condition": "is", "value": "Cy"}}]}
            """#)])
        #expect(wrong[0].error?.contains("no option") == true)
    }

    /// Data from several results is bound by their tools' names; two of one tool keep their ids.
    @Test
    func severalResultsAreBoundByTool() throws {
        let results: [String: JSONValue] = ["weather_a1b2c3": 1, "calendar_d4e5f6": 2, "calendar_0a0b0c": 3]
        let two = try AgentBlocks.data(["from": ["weather_a1b2c3", "calendar_d4e5f6"]], results: results)
        #expect(two == ["weather": 1, "calendar": 2])
        let same = try AgentBlocks.data(["from": ["calendar_d4e5f6", "calendar_0a0b0c"]], results: results)
        #expect(same == ["calendar_d4e5f6": 2, "calendar_0a0b0c": 3])
    }
}
