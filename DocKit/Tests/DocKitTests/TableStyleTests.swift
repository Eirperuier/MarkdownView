import Foundation
import Testing

@testable import DocKit

@Suite
struct TableStyleTests {
    private let name = Column(id: fixedID(11), name: "Name", type: .text)
    private let price = Column(id: fixedID(12), name: "Price", type: .number)

    private func doc() -> Doc {
        let database = Database(id: fixedID(30), columns: [name, price], rows: [
            Row(id: fixedID(40), cells: [name.id: .text(value: "Tea"), price.id: .number(value: 1234.5)]),
            Row(id: fixedID(41), cells: [name.id: .text(value: "0.19"), price.id: .number(value: 2)]),
        ])
        return Doc(id: fixedID(0), blocks: [
            DocBlock(id: fixedID(1), kind: .database(id: database.id, view: .table(hidden: [], sort: []))),
        ], databases: [database.id: database])
    }

    private func step(_ step: DatabaseStep) -> DocStep { .database(id: fixedID(30), step: step) }

    /// A cell's style is set, read back, and undone to what it was; a header cell's is its
    /// own; a plain style is stored as none.
    @Test
    func cellStylesApplyAndUndo() throws {
        var doc = doc()
        let style = CellStyle(alignment: .right, font: .mono, number: .currency(code: "CNY"), fill: "blue-2")
        let applied = try doc.apply(step(.setCellStyle(row: fixedID(40), column: price.id, style: style, previous: nil)))
        let header = try doc.apply(step(.setCellStyle(row: nil, column: price.id, style: CellStyle(alignment: .center), previous: nil)))
        var database = try #require(doc.databases[fixedID(30)])
        #expect(database.cellStyle(row: fixedID(40), column: price.id) == style)
        #expect(database.cellStyle(row: nil, column: price.id) == CellStyle(alignment: .center))
        #expect(database.cellStyle(row: fixedID(41), column: price.id).isPlain)
        try doc.validate()

        try doc.apply(header.inverted)
        try doc.apply(applied.inverted)
        database = try #require(doc.databases[fixedID(30)])
        #expect(database.columns[1].headerStyle == nil && database.columns[1].cellStyles == nil)

        try doc.apply(step(.setCellStyle(row: fixedID(40), column: price.id, style: CellStyle(), previous: nil)))
        #expect(doc.databases[fixedID(30)]?.columns[1].cellStyles == nil)
    }

    /// The table's style: header row off, header column on, a stripe; the defaults are none.
    @Test
    func tableStyleAppliesAndUndoes() throws {
        var doc = doc()
        let style = TableStyle(headerRow: false, headerColumn: true, stripe: "mint-2")
        let applied = try doc.apply(step(.setTableStyle(style: style, previous: nil)))
        #expect(doc.databases[fixedID(30)]?.tableStyle == style)
        try doc.validate()
        try doc.apply(applied.inverted)
        #expect(doc.databases[fixedID(30)]?.style == nil)
        try doc.apply(step(.setTableStyle(style: TableStyle(headerRow: true), previous: nil)))
        #expect(doc.databases[fixedID(30)]?.style == nil)
        #expect(TableStyle().hasHeaderRow && !TableStyle().hasHeaderColumn)
    }

    /// Renaming a column keeps its cells' styles; deleting it and undoing brings them back,
    /// and so does undoing a row's deletion.
    @Test
    func stylesLiveWithTheirColumnAndRow() throws {
        var doc = doc()
        try doc.apply(step(.setCellStyle(row: fixedID(40), column: price.id, style: CellStyle(fill: "red"), previous: nil)))
        var renamed = price
        renamed.name = "Cost"
        try doc.apply(step(.updateColumn(column: renamed, previous: price)))
        #expect(doc.databases[fixedID(30)]?.cellStyle(row: fixedID(40), column: price.id).fill == "red")

        let column = try #require(doc.databases[fixedID(30)]?.columns[1])
        let deleted = try doc.apply(step(.deleteColumn(column: column, after: nil, cells: [:])))
        try doc.apply(deleted.inverted)
        #expect(doc.databases[fixedID(30)]?.cellStyle(row: fixedID(40), column: price.id).fill == "red")

        let row = try #require(doc.databases[fixedID(30)]?.rows[0])
        let removed = try doc.apply(step(.deleteRow(row: row, after: nil)))
        try doc.apply(removed.inverted)
        #expect(doc.databases[fixedID(30)]?.cellStyle(row: fixedID(40), column: price.id).fill == "red")
    }

    /// A fill, a stripe or a currency a cell can't take is refused, and so is a missing cell.
    @Test
    func stylesACellCantTakeAreRefused() {
        var doc = doc()
        for style in [CellStyle(fill: "pink"), CellStyle(fill: "blue-4"), CellStyle(fill: "#12345"), CellStyle(number: .currency(code: "usd"))] {
            #expect(throws: DocError.invalidStyle) {
                try doc.apply(step(.setCellStyle(row: fixedID(40), column: price.id, style: style, previous: nil)))
            }
        }
        #expect(throws: DocError.invalidStyle) {
            try doc.apply(step(.setTableStyle(style: TableStyle(stripe: "blue-1"), previous: nil)))
        }
        #expect(throws: DocError.rowNotFound(fixedID(99))) {
            try doc.apply(step(.setCellStyle(row: fixedID(99), column: price.id, style: CellStyle(fill: "red"), previous: nil)))
        }
        #expect(CellStyle(fill: "#3366ff").isValid && CellStyle(fill: "gray-3").isValid)
        #expect(CellStyle.fillColors.count * CellStyle.fillStrengths.count == 36)
    }

    /// A cell's style goes with its row or column when a collaborator deletes either.
    @Test
    func cellStylesDropWithTheirRowOrColumn() {
        let set = step(.setCellStyle(row: fixedID(40), column: price.id, style: CellStyle(fill: "red"), previous: nil))
        #expect(set.mapped(through: step(.deleteRow(row: Row(id: fixedID(40)), after: nil))) == [])
        #expect(set.mapped(through: step(.deleteColumn(column: price, after: nil, cells: [:]))) == [])
        #expect(set.mapped(through: step(.deleteRow(row: Row(id: fixedID(41)), after: nil))) == [set])
        let header = step(.setCellStyle(row: nil, column: price.id, style: CellStyle(fill: "red"), previous: nil))
        #expect(header.mapped(through: step(.deleteRow(row: Row(id: fixedID(40)), after: nil))) == [header])
    }

    /// A database stored before styles existed reads as it was, with none.
    @Test
    func databasesWithoutStylesStillDecode() throws {
        let database = try #require(doc().databases[fixedID(30)])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(database)) as? [String: Any])
        #expect(json["style"] == nil)
        json.removeValue(forKey: "style")
        let back = try JSONDecoder().decode(Database.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back == database)
    }

    /// Numbers read in their cell's format, a text cell's number too; a column every cell of
    /// which sits one way says so in markdown, and comes back that way.
    @Test
    func markdownCarriesNumbersAndAlignment() throws {
        var doc = doc()
        try doc.apply(step(.setCellStyle(row: fixedID(40), column: price.id, style: CellStyle(alignment: .right, number: .currency(code: "USD")), previous: nil)))
        try doc.apply(step(.setCellStyle(row: fixedID(41), column: price.id, style: CellStyle(alignment: .right, number: .number), previous: nil)))
        try doc.apply(step(.setCellStyle(row: nil, column: price.id, style: CellStyle(alignment: .right), previous: nil)))
        try doc.apply(step(.setCellStyle(row: fixedID(41), column: name.id, style: CellStyle(number: .percent), previous: nil)))
        #expect(doc.markdown == """
            | Name | Price |
            | --- | ---: |
            | Tea | \\$1,234.50 |
            | 19% | 2 |
            """)

        var rng = SplitMix64(seed: 7)
        let fragment = DocFragment(markdown: "| A | B | C |\n| :-: | --- | :-- |\n| 1 | 2 | 3 |", at: fixedTime(0), using: &rng)
        let database = try #require(fragment.databases.values.first)
        let row = try #require(database.rows.first?.id)
        #expect(database.columns[0].style(row: row).alignment == .center)
        #expect(database.columns[0].style(row: nil).alignment == .center)
        #expect(database.columns[1].cellStyles == nil)
        #expect(database.columns[2].style(row: row).alignment == .left)
        let back = Doc(id: fixedID(0), blocks: fragment.blocks, databases: fragment.databases).markdown
        #expect(back == "| A | B | C |\n| :---: | --- | :--- |\n| 1 | 2 | 3 |")
    }
}
