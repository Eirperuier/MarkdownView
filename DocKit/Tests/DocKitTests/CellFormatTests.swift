import Foundation
import Testing

@testable import DocKit

@Suite
struct CellFormatTests {
    /// A number reads with the writer's separators and nothing else; a link gets https://
    /// when it has none and needs a host that is a domain.
    @Test
    func typedTextIsReadOrRefused() {
        #expect(CellFormat.number(" 1,234.5 ") == 1234.5)
        #expect(CellFormat.number("1.234,5", grouping: ".", decimal: ",") == 1234.5)
        #expect(CellFormat.number("-2e3") == -2000)
        #expect(CellFormat.number("12abc") == nil)
        #expect(CellFormat.number("inf") == nil)
        #expect(CellFormat.number("") == nil)
        #expect(CellFormat.link("example.com/a?b=1") == "https://example.com/a?b=1")
        #expect(CellFormat.link("http://localhost:8080/x") == "http://localhost:8080/x")
        #expect(CellFormat.link("ftp://files.example.org") == "ftp://files.example.org")
        #expect(CellFormat.link("mailto:a@b.co") == "mailto:a@b.co")
        #expect(CellFormat.link("not a link") == nil)
        #expect(CellFormat.link("word") == nil)
        #expect(CellFormat.link("https://") == nil)
        #expect(CellFormat.link("1http://x.y") == nil)
    }

    private let title = Column(id: fixedID(11), name: "Title", type: .text)
    private let hours = Column(id: fixedID(12), name: "Hours", type: .number)
    private let a = SelectOption(id: fixedID(20), name: "A")

    private func doc() -> Doc {
        let status = Column(id: fixedID(13), name: "Status", type: .select(options: [a]))
        let database = Database(id: fixedID(10), columns: [title, hours, status], rows: [
            Row(id: fixedID(14), cells: [title.id: .text(value: "Walk"), hours.id: .number(value: 2)]),
        ])
        return Doc(id: fixedID(1), blocks: [DocBlock(id: fixedID(2), kind: .database(id: database.id, view: .table(hidden: [], sort: [])))],
                   databases: [database.id: database])
    }

    private func tx(_ steps: [DatabaseStep]) -> DocTransaction {
        DocTransaction(steps: steps.map { .database(id: fixedID(10), step: $0) }, author: .person(client: fixedID(1)), time: fixedTime(0))
    }

    /// A transaction's cells must be what their columns hold at its end: a word in a number
    /// column, an option the select hasn't, a new database with either, are refused and
    /// leave the doc as it was; a field changing type passes through values of the old type.
    @Test
    func transactionsWriteOnlyWhatColumnsHold() throws {
        var doc = doc()
        let before = doc
        let row: RowID = fixedID(14)
        #expect(throws: DocError.cellNotOfColumn(row, hours.id)) {
            try doc.apply(tx([.setCell(row: row, column: hours.id, value: .text(value: "two"), previous: nil)]))
        }
        #expect(throws: DocError.cellNotOfColumn(row, fixedID(13))) {
            try doc.apply(tx([.setCell(row: row, column: fixedID(13), value: .select(option: fixedID(21)), previous: nil)]))
        }
        #expect(throws: DocError.cellNotOfColumn(fixedID(15), hours.id)) {
            try doc.apply(tx([.insertRow(row: Row(id: fixedID(15), cells: [hours.id: .number(value: .nan)]), after: nil)]))
        }
        #expect(doc == before)
        let bad = Database(id: fixedID(30), columns: [hours], rows: [Row(id: fixedID(31), cells: [hours.id: .text(value: "x")])])
        #expect(throws: DocError.cellNotOfColumn(fixedID(31), hours.id)) {
            try doc.apply(DocTransaction(steps: [.createDatabase(database: bad)], author: .person(client: fixedID(1)), time: fixedTime(0)))
        }

        // Hours becomes text: its column first, then its values.
        var text = hours
        text.type = .text
        try doc.apply(tx([.updateColumn(column: text, previous: hours),
                          .setCell(row: row, column: hours.id, value: .text(value: "2"), previous: nil)]))
        // Becoming a number again without its values is refused.
        #expect(throws: DocError.cellNotOfColumn(row, hours.id)) {
            try doc.apply(tx([.updateColumn(column: hours, previous: text)]))
        }
    }

    /// A cell left of a column a collaborator deleted stops nothing: the next edit of the
    /// database goes through.
    @Test
    func leftoverCellsDontBlockEdits() throws {
        var doc = doc()
        doc.databases[fixedID(10)]?.rows[0].cells[fixedID(99)] = .number(value: 1)
        try doc.apply(tx([.setCell(row: fixedID(14), column: title.id, value: .text(value: "Run"), previous: nil)]))
        #expect(doc.databases[fixedID(10)]?.rows[0].cells[title.id] == .text(value: "Run"))
    }
}
