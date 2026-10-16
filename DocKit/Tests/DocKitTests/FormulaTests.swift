import Testing
@testable import DocKit

@Suite
struct FormulaTests {
    /// | Item | Qty | Price | Total |, three body rows, then a totals row.
    func database(_ body: [[String]]) -> Database {
        let columns = (0..<4).map { Column(id: fixedID(UInt64(100 + $0)), name: ["Item", "Qty", "Price", "Total"][$0], type: .text) }
        let rows = body.enumerated().map { index, cells in
            Row(id: fixedID(UInt64(200 + index)), cells: Dictionary(uniqueKeysWithValues: zip(columns, cells).compactMap { column, text in
                text.isEmpty ? nil : (column.id, CellValue.text(value: text))
            }))
        }
        return Database(id: fixedID(1), columns: columns, rows: rows)
    }

    func shown(_ db: Database, _ row: Int, _ column: Int) -> String {
        let text = column < db.columns.count && row <= db.rows.count
            ? (row == 0 ? db.columns[column].name : db.columns[column].display(db.rows[row - 1].cells[db.columns[column].id]))
            : ""
        return DatabaseFormula.displayed(text, in: db, row: row, column: column)
    }

    @Test
    func arithmeticAndReferences() {
        let db = database([
            ["Apples", "3", "1.5", "=B2*C2"],
            ["Pears", "2", "2", "=B3*C3"],
            ["Plums", "10", "0.1", "=ROUND(B4*C4 + 0.2, 1)"],
            ["Total", "=SUM(ABOVE)", "", "=SUM(D2:D4)"],
        ])
        #expect(shown(db, 1, 3) == "4.5")
        #expect(shown(db, 2, 3) == "4")
        #expect(shown(db, 3, 3) == "1.2")
        #expect(shown(db, 4, 1) == "15")
        #expect(shown(db, 4, 3) == "9.7")
        #expect(shown(db, 1, 0) == "Apples")
    }

    @Test
    func functions() {
        let db = database([
            ["a", "1", "", "=AVERAGE(B2:B5)"],
            ["b", "2", "", "=MEDIAN(B2:B5)"],
            ["c", "2", "", "=MODE(B2:B5)"],
            ["d", "7", "", "=COUNT(B2:B5) + COUNTA(A2:A5) * 10"],
            ["e", "=MAX(B2:B5) - MIN(B2:B5)", "=PRODUCT(B2:B4)", "=ABS(-2) + INT(2.7) + SIGN(-5) + 2^3"],
        ])
        #expect(shown(db, 1, 3) == "3")
        #expect(shown(db, 2, 3) == "2")
        #expect(shown(db, 3, 3) == "2")
        #expect(shown(db, 4, 3) == "44")
        #expect(shown(db, 5, 1) == "6")
        #expect(shown(db, 5, 2) == "4")
        #expect(shown(db, 5, 3) == "11")
    }

    @Test
    func numbersInCells() {
        let db = database([
            ["x", "1,200", "50%", "=B2*C2"],
            ["y", "$3", "¥4", "=B3+C3"],
        ])
        #expect(shown(db, 1, 3) == "600")
        #expect(shown(db, 2, 3) == "7")
    }

    @Test
    func errors() {
        let db = database([
            ["a", "=B3", "=1/0", "=SUM("],
            ["b", "=B2", "=Z9", "=FOO(1)"],
        ])
        #expect(shown(db, 1, 1) == "#CYCLE!")
        #expect(shown(db, 1, 2) == "#DIV/0!")
        #expect(shown(db, 1, 3) == "#ERROR")
        #expect(shown(db, 2, 2) == "#REF!")
        #expect(shown(db, 2, 3) == "#ERROR")
    }

    @Test
    func directions() {
        let db = database([
            ["1", "2", "3", "=SUM(LEFT)"],
            ["4", "5", "6", "=SUM(LEFT)"],
            ["=SUM(BELOW)", "=SUM(RIGHT)", "1", "2"],
            ["7", "", "", ""],
        ])
        #expect(shown(db, 1, 3) == "6")
        #expect(shown(db, 2, 3) == "15")
        #expect(shown(db, 3, 0) == "7")
        #expect(shown(db, 3, 1) == "3")
    }

    @Test
    func exportShowsResults() {
        let db = database([["a", "2", "3", "=B2*C2"]])
        let doc = Doc(id: fixedID(0), blocks: [DocBlock(id: fixedID(9), kind: .database(id: db.id, view: .table(hidden: [], sort: [])))], databases: [db.id: db])
        #expect(doc.markdown(of: fixedID(9))?.contains("| a | 2 | 3 | 6 |") == true)
    }

    /// What a Chinese input method types: ＝, full-width parentheses and commas.
    @Test
    func fullWidthForms() {
        let db = database([
            ["a", "2", "3", "＝SUM （B2：C2）"],
            ["b", "=ROUND（B2／3，2）", "", ""],
        ])
        #expect(shown(db, 1, 3) == "5")
        #expect(shown(db, 2, 1) == "0.67")
    }

    /// Craft's keys: AVG and CNT.
    @Test
    func craftNames() {
        let db = database([["a", "2", "4", "=AVG(B2:C2)+CNT(B2:C2)"]])
        #expect(shown(db, 1, 3) == "5")
    }

    @Test
    func references() {
        // A function's name isn't one; letters are read as capitals.
        #expect(DatabaseFormula.references(in: "SUM(a3:B4)+C2*2-AB10") == [
            .init(range: 4..<9, rows: 2...3, columns: 0...1),
            .init(range: 11..<13, rows: 1...1, columns: 2...2),
            .init(range: 16..<20, rows: 9...9, columns: 27...27),
        ])
        // A range typed backwards names the same cells; a half-typed one is its first cell.
        #expect(DatabaseFormula.references(in: "B4:A3") == [.init(range: 0..<5, rows: 2...3, columns: 0...1)])
        #expect(DatabaseFormula.references(in: "A3:") == [.init(range: 0..<2, rows: 2...2, columns: 0...0)])
        // Full-width, as a Chinese input method types it.
        #expect(DatabaseFormula.references(in: "Ａ３＋Ｂ１") == [.init(range: 0..<2, rows: 2...2, columns: 0...0), .init(range: 3..<5, rows: 0...0, columns: 1...1)])
        #expect(DatabaseFormula.reference(row: 2, column: 0) == "A3")
    }

    @Test
    func columnNames() {
        #expect(DatabaseFormula.columnName(0) == "A")
        #expect(DatabaseFormula.columnName(25) == "Z")
        #expect(DatabaseFormula.columnName(26) == "AA")
    }
}
