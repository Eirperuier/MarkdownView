import Foundation

@testable import DocKit

/// The authored inputs of the golden cases: fixed ids, fixed times, together
/// covering every `DocStep` and `DatabaseStep` case. Recording writes each
/// input's resolved steps and final doc into the JSON next to it.
enum GoldenSeed {
    static func make() -> [String: GoldenTests.Case] {
        [
            "text-edits": GoldenTests.Case(
                doc: Doc(id: fixedID(1), blocks: [
                    DocBlock(id: fixedID(2), kind: .paragraph, text: DocText(string: "hello world")),
                    DocBlock(id: fixedID(3), kind: .quote, text: DocText(string: "quoted")),
                ]),
                steps: [
                    .insertText(block: fixedID(2), at: 5, text: DocText(string: " brave")),
                    .deleteText(block: fixedID(2), range: 0..<6, removed: DocText()),
                    .insertText(block: fixedID(3), at: 6, text: DocText(string: " text", marks: [
                        MarkSpan(range: 0..<5, mark: .italic),
                    ])),
                ]
            ),
            "marks": GoldenTests.Case(
                doc: Doc(id: fixedID(1), blocks: [
                    DocBlock(id: fixedID(2), kind: .paragraph, text: DocText(
                        string: "abcdefgh",
                        marks: [MarkSpan(range: 0..<4, mark: .bold)]
                    )),
                ]),
                steps: [
                    .setMarks(
                        block: fixedID(2), range: 2..<6, kind: .bold,
                        spans: [MarkSpan(range: 2..<6, mark: .bold)], previous: []
                    ),
                    .setMarks(block: fixedID(2), range: 1..<3, kind: .bold, spans: [], previous: []),
                    .setMarks(
                        block: fixedID(2), range: 4..<8, kind: .link,
                        spans: [MarkSpan(range: 4..<8, mark: .link(url: "https://example.com"))], previous: []
                    ),
                ]
            ),
            "split-join": GoldenTests.Case(
                doc: Doc(id: fixedID(1), blocks: [
                    DocBlock(id: fixedID(2), kind: .paragraph, text: DocText(
                        string: "hello world",
                        marks: [MarkSpan(range: 3..<9, mark: .bold)]
                    )),
                    DocBlock(id: fixedID(3), kind: .paragraph, text: DocText(string: "tail")),
                ]),
                steps: [
                    .splitBlock(block: fixedID(2), at: 6, newID: fixedID(4), newKind: .heading(level: 2), newIndent: 1),
                    .joinBlock(block: fixedID(4), into: fixedID(2), at: 0, kind: .paragraph, indent: 0),
                    .splitBlock(block: fixedID(2), at: 3, newID: fixedID(5), newKind: .paragraph, newIndent: 0),
                ]
            ),
            "block-ops": GoldenTests.Case(
                doc: Doc(id: fixedID(1), blocks: [
                    DocBlock(id: fixedID(2), kind: .paragraph, text: DocText(string: "one")),
                    DocBlock(id: fixedID(3), kind: .paragraph, text: DocText(string: "two")),
                    DocBlock(id: fixedID(4), kind: .paragraph, text: DocText(string: "three")),
                ]),
                steps: [
                    .insertBlock(
                        block: DocBlock(id: fixedID(5), kind: .listItem(style: .task(done: false)), indent: 1, text: DocText(string: "item")),
                        after: fixedID(2)
                    ),
                    .moveBlock(block: fixedID(4), after: nil, from: nil),
                    .setBlock(block: fixedID(2), kind: .heading(level: 3), indent: 0, previousKind: .paragraph, previousIndent: 0),
                    .deleteBlock(block: DocBlock(id: fixedID(3), kind: .paragraph), after: nil),
                ]
            ),
            "block-ops-2": GoldenTests.Case(
                doc: Doc(id: fixedID(1), blocks: [
                    DocBlock(id: fixedID(2), kind: .paragraph, text: DocText(string: "para")),
                    DocBlock(id: fixedID(3), kind: .divider),
                    DocBlock(id: fixedID(4), kind: .image(image: DocImage(source: "https://img/x", alt: "alt"))),
                ]),
                steps: [
                    .insertBlock(
                        block: DocBlock(id: fixedID(5), kind: .card(card: DocCard(size: "large", view: "chart", source: "floo.chart", data: ["n": 1]))),
                        after: nil
                    ),
                    .moveBlock(block: fixedID(3), after: fixedID(4), from: nil),
                    .setBlock(block: fixedID(2), kind: .quote, indent: 2, previousKind: .paragraph, previousIndent: 0),
                    .deleteBlock(block: DocBlock(id: fixedID(4), kind: .paragraph), after: nil),
                ]
            ),
            "databases": GoldenTests.Case(
                doc: Doc(id: fixedID(1), blocks: [
                    DocBlock(id: fixedID(2), kind: .paragraph, text: DocText(string: "intro")),
                    DocBlock(id: fixedID(3), kind: .database(id: fixedID(10), view: .table(hidden: [], sort: []))),
                ], databases: [
                    fixedID(10): Database(id: fixedID(10), columns: [
                        Column(id: fixedID(11), name: "name", type: .text),
                        Column(id: fixedID(12), name: "done", type: .checkbox),
                    ], rows: [
                        Row(id: fixedID(13), cells: [fixedID(11): .text(value: "a"), fixedID(12): .checkbox(value: false)]),
                        Row(id: fixedID(14), cells: [fixedID(11): .text(value: "b")]),
                    ]),
                ]),
                steps: [
                    .createDatabase(database: Database(id: fixedID(20), columns: [
                        Column(id: fixedID(21), name: "c", type: .number),
                    ])),
                    .database(id: fixedID(10), step: .setCell(row: fixedID(14), column: fixedID(12), value: .checkbox(value: true), previous: nil)),
                    .database(id: fixedID(10), step: .insertRow(row: Row(id: fixedID(15), cells: [fixedID(11): .text(value: "c")]), after: fixedID(13))),
                    .database(id: fixedID(10), step: .deleteRow(row: Row(id: fixedID(14)), after: nil)),
                    .database(id: fixedID(10), step: .moveRow(row: fixedID(13), after: nil, from: nil)),
                    .database(id: fixedID(10), step: .insertColumn(column: Column(id: fixedID(16), name: "due", type: .date), after: fixedID(11), cells: [:])),
                    .database(id: fixedID(10), step: .deleteColumn(column: Column(id: fixedID(12), name: "x", type: .text), after: nil, cells: [:])),
                    .database(id: fixedID(10), step: .updateColumn(column: Column(id: fixedID(11), name: "title", type: .text), previous: Column(id: fixedID(11), name: "x", type: .text))),
                    .deleteDatabase(database: Database(id: fixedID(20))),
                ]
            ),
        ]
    }
}

extension GoldenTests.Case {
    init(doc: Doc, steps: [DocStep]) {
        self.init(doc: doc, steps: steps, resolved: [], final: doc)
    }
}
