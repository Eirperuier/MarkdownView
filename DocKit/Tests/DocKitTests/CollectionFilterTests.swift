import Foundation
import Testing

@testable import DocKit

@Suite
struct CollectionFilterTests {
    private let title = Column(id: .generate(), name: "Title", type: .text)
    private let hours = Column(id: .generate(), name: "Hours", type: .number)
    private let due = Column(id: .generate(), name: "Due", type: .date)
    private let done = Column(id: .generate(), name: "Done", type: .checkbox)
    private let a = SelectOption(id: .generate(), name: "A"), b = SelectOption(id: .generate(), name: "B")

    private func day(_ n: Int64) -> CellValue { .date(value: Timestamp(millisecondsSince1970: n * 86_400_000 + 3_600_000)) }

    private func database() -> (Database, Column) {
        let tags = Column(id: .generate(), name: "Tags", type: .multiSelect(options: [a, b]))
        let rows = [
            Row(id: .generate(), cells: [title.id: .text(value: "Walk the dog"), hours.id: .number(value: 2), due.id: day(10), tags.id: .multiSelect(options: [a.id, b.id]), done.id: .checkbox(value: true)]),
            Row(id: .generate(), cells: [title.id: .text(value: "Sleep"), hours.id: .number(value: 8), due.id: day(12), tags.id: .multiSelect(options: [b.id])]),
            Row(id: .generate(), cells: [title.id: .text(value: "")]),
        ]
        return (Database(id: .generate(), columns: [title, hours, due, tags, done], rows: rows), tags)
    }

    private func kept(_ filter: CollectionFilter, _ database: Database) -> [Int] {
        database.rows.indices.filter { filter.matches(database.rows[$0], in: database) }
    }

    /// Each condition on each kind of value: an empty text is empty, a day is a day, and a
    /// filter still being set up lets everything through.
    @Test
    func conditionsTestTheirValues() {
        let (database, tags) = database()
        #expect(kept(CollectionFilter(column: title.id, condition: .contains, value: .text(value: "DOG")), database) == [0])
        #expect(kept(CollectionFilter(column: title.id, condition: .doesNotContain, value: .text(value: "dog")), database) == [1, 2])
        #expect(kept(CollectionFilter(column: title.id, condition: .isEmpty), database) == [2])
        #expect(kept(CollectionFilter(column: hours.id, condition: .greaterThan, value: .number(value: 2)), database) == [1])
        #expect(kept(CollectionFilter(column: hours.id, condition: .isNot, value: .number(value: 2)), database) == [1, 2])
        #expect(kept(CollectionFilter(column: due.id, condition: .is, value: .date(value: Timestamp(millisecondsSince1970: 12 * 86_400_000))), database) == [1])
        #expect(kept(CollectionFilter(column: due.id, condition: .lessThan, value: day(12)), database) == [0])
        #expect(kept(CollectionFilter(column: tags.id, condition: .contains, value: .select(option: a.id)), database) == [0])
        #expect(kept(CollectionFilter(column: tags.id, condition: .isNotEmpty), database) == [0, 1])
        #expect(kept(CollectionFilter(column: done.id, condition: .is, value: .checkbox(value: false)), database) == [1, 2])
        #expect(kept(CollectionFilter(column: hours.id, condition: .is), database) == [0, 1, 2])
    }

    /// A view shows what all its filters keep, sorted, empties last and ties as they were.
    @Test
    func aViewFiltersThenSorts() {
        let (database, _) = database()
        var view = CollectionView(name: "V", layout: .table(hidden: [], sort: [DatabaseSort(column: hours.id, ascending: false)]))
        #expect(view.records(of: database).map(\.id) == [database.rows[1].id, database.rows[0].id, database.rows[2].id])
        view.filters = [CollectionFilter(column: title.id, condition: .isNotEmpty)]
        view.layout.sort = [DatabaseSort(column: title.id)]
        #expect(view.records(of: database).map(\.id) == [database.rows[1].id, database.rows[0].id])
    }

    /// A view written before filters and the fields' order reads with none.
    @Test
    func anOlderViewDecodes() throws {
        let view = CollectionView(name: "Old", layout: .table(hidden: [], sort: []))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as! [String: Any]
        object["filters"] = nil
        object["order"] = nil
        let decoded = try JSONDecoder().decode(CollectionView.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == view)
        #expect(view.ordered([title, hours]).map(\.id) == [title.id, hours.id])
        var ordered = view
        ordered.order = [hours.id]
        #expect(ordered.ordered([title, hours]).map(\.id) == [hours.id, title.id])
    }
}
