import Foundation
import Testing

@testable import DocKit

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// Keys of `value` the guide's `fields` don't have, by where they are.
private func uncovered(_ value: JSONValue, _ fields: [AgentField], at path: String) -> [String] {
    guard case .object(let object) = value else { return [] }
    var missing: [String] = []
    for (key, child) in object {
        let place = path + "." + key
        guard let field = fields.first(where: { $0.key == key }) else {
            missing.append(place)
            continue
        }
        switch field.shape {
        case .value: break
        case .text:
            if case .array(let runs) = child { missing += runs.flatMap { uncovered($0, DocText.agentFields, at: place) } }
        case .object(let inner): missing += uncovered(child, inner, at: place)
        case .list(let inner):
            if case .array(let items) = child { missing += items.flatMap { uncovered($0, inner, at: place) } }
        }
    }
    return missing
}

@Suite
struct AgentGuideTests {
    /// A document with every kind of block, text with every style, and a table with every
    /// style: what doc_edit wrote.
    private func everything() throws -> Doc {
        var doc = Doc(id: fixedID(0), blocks: [
            DocBlock(id: fixedID(1), kind: .heading(level: 2), indent: 1, text: DocText(string: "Plan"), decoration: .block),
            DocBlock(id: fixedID(2), kind: .card(card: DocCard(size: "glance", source: "Text(name)", data: ["name": "Ada"]))),
            DocBlock(id: fixedID(3), kind: .view(view: DocView(source: "VStack {}", data: ["n": 2]))),
            DocBlock(id: fixedID(4), kind: .page(page: DocPage(doc: fixedID(70), title: "Trip", preview: "Flights"))),
        ])
        let results = doc.agentEdit([json(#"""
            {"op": "insert", "blocks": [
              ["Up ", {"text": "12%", "bold": true, "italic": true, "strike": true, "code": true, "link": "https://a.b",
                       "highlight": "yellow", "color": "green", "pen": {"kind": "wavy", "color": "blue"}},
               {"math": "x^2"}, {"mention": {"kind": "person", "id": "u1", "label": "Ada"}}, {"cite": {"url": "https://a.b", "label": "A"}}],
              {"type": "quote", "text": "q"}, {"type": "caption", "text": "c"},
              {"type": "list", "style": "task", "done": true, "text": "t"}, {"type": "list", "style": "toggle", "open": false, "text": "o"},
              {"type": "code", "language": "swift", "code": "let x = 1"}, {"type": "math", "latex": "e"}, {"type": "divider"},
              {"type": "image", "url": "https://a.b/c.png", "alt": "Chart", "fit": "fill", "size": "large"},
              {"type": "link", "url": "https://a.b", "title": "A", "summary": "B", "image": "https://a.b/i.png", "layout": "card"},
              {"type": "file", "url": "blob:1", "name": "plan.pdf", "bytes": 2048, "layout": "small"},
              {"type": "table", "view": "kanban", "group_by": "State", "hidden": ["Note"], "sort": [{"column": "Cost", "ascending": false}],
               "columns": [{"name": "Item"}, {"name": "State", "type": "select", "options": [{"name": "Open", "color": "red"}]},
                           {"name": "Cost", "type": "number", "align": "right", "format": "USD"}, {"name": "Note"}],
               "rows": [["Tea", "Open", 3, "x"], ["Cake", "Open", 1.5, "y"]],
               "style": {"header_row": false, "header_column": true, "stripe": "mint-2"},
               "cells": [{"column": "Item", "header": true, "font": "serif"}, {"column": "Item", "row": 1, "fill": "yellow-2"}]},
              {"type": "collection", "name": "Tasks", "columns": [{"name": "Task"}, {"name": "Owner", "type": "select"}],
               "rows": [["Walk", "Ada"]], "current": "Board",
               "views": [{"name": "All", "layout": "table", "sort": [{"column": "Task"}], "hidden": ["Owner"],
                          "filter": [{"column": "Task", "condition": "contains", "value": "W"}]},
                         {"name": "Board", "layout": "kanban", "group_by": "Owner"}]}
            ]}
            """#)])
        #expect(results.allSatisfy { $0.error == nil }, "\(results.map(\.json))")
        return doc
    }

    /// Every key doc_read shows, of every kind of block, of text and of a table's styles,
    /// is in the guide, where the guide says it goes.
    @Test
    func theGuideCoversEveryKeyRead() throws {
        let doc = try everything()
        let ids = Set(doc.blocks.map(\.id))
        var types = Set<String>()
        for read in [doc.agentRead(), doc.agentRead(full: ids)] {
            guard case .array(let blocks)? = read["blocks"] else { Issue.record("no blocks"); return }
            for block in blocks {
                let type = try #require(block["type"]?.stringValue)
                types.insert(type)
                let usage = try #require(AgentGuide.usages.first { $0.names.contains(type) }, "no usage for \(type)")
                let missing = uncovered(block, DocBlock.agentFields + usage.fields, at: type)
                #expect(missing.isEmpty, "not in the guide: \(missing)")
            }
        }
        #expect(types == Set(AgentGuide.usages.flatMap(\.names)))
        #expect(AgentBlocks.colors == CellStyle.fillColors)
        #expect(AgentGuide.blocks.contains("\"indent\" (0 to \(DocBlock.maxIndent)"))
    }

    /// A table's styles read as written: the table's, a column's all its cells share, a
    /// cell's own; and they write back the same.
    @Test
    func tableStylesRoundTrip() throws {
        let doc = try everything()
        let table = try #require(doc.blocks.first { if case .database = $0.kind { true } else { false } })
        guard case .database(let id, _) = table.kind else { Issue.record("not a table"); return }
        let database = try #require(doc.databases[id])
        let read = AgentBlocks.json(table, in: doc)
        #expect(read["style"] == json(#"{"header_row": false, "header_column": true, "stripe": "mint-2"}"#))
        #expect(read["columns"]?[2]?["align"] == "right" && read["columns"]?[2]?["format"] == "USD")
        #expect(read["cells"] == json(#"[{"column": "Item", "header": true, "font": "serif"}, {"column": "Item", "row": 1, "fill": "yellow-2"}]"#))

        var databases: [DatabaseID: Database] = [:]
        let written = try AgentBlocks.block(read, id: table.id, databases: &databases, results: [:])
        guard case .database(let back, _) = written.kind else { Issue.record("not a table"); return }
        let rebuilt = try #require(databases[back])
        #expect(rebuilt.style == database.style)
        for (column, other) in zip(database.columns, rebuilt.columns) {
            #expect(column.style(row: nil) == other.style(row: nil))
            for (row, same) in zip(database.rows, rebuilt.rows) { #expect(column.style(row: row.id) == other.style(row: same.id)) }
        }
        #expect(AgentBlocks.styleSteps(from: rebuilt, to: database).isEmpty)
    }

    /// A set changes a table's styles on the database it keeps, cell by cell, each one a
    /// step undone with the rest; a value a cell can't take says what it can.
    @Test
    func aSetRestylesATable() throws {
        var doc = try everything()
        let table = try #require(doc.blocks.first { if case .database = $0.kind { true } else { false } })
        guard case .database(let id, _) = table.kind else { return }
        let before = doc
        let short = AgentBlocks.shortID(table.id)
        let results = doc.agentEdit([json(#"""
            {"op": "set", "id": "\#(short)", "style": {"stripe": "blue"}, "cells": [{"column": "Cost", "row": 0, "fill": "red"}]}
            """#)])
        #expect(results[0].error == nil, "\(results.map(\.json))")
        let database = try #require(doc.databases[id])
        #expect(database.style == TableStyle(stripe: "blue"))
        _ = doc.agentEdit([json(#"{"op": "set", "id": "\#(short)", "style": {"stripe": "None"}}"#)])
        #expect(doc.databases[id]?.style == TableStyle(stripe: TableStyle.noStripe))
        let item = database.columns[0], cost = database.columns[2]
        #expect(item.headerStyle == nil && item.cellStyles == nil)
        #expect(cost.style(row: database.rows[0].id) == CellStyle(alignment: .right, number: .currency(code: "USD"), fill: "red"))
        #expect(cost.style(row: database.rows[1].id) == CellStyle(alignment: .right, number: .currency(code: "USD")))

        for step in results[0].steps.reversed() { try doc.apply(step.inverted) }
        #expect(doc.databases[id] == before.databases[id])

        let refused = doc.agentEdit([json(#"{"op": "set", "id": "\#(short)", "cells": [{"column": "Cost", "row": 0, "align": "middle"}]}"#)])
        #expect(refused[0].error?.contains("left, center, right, justify") == true)
    }
}
