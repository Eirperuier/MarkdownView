import Foundation
import Testing

@testable import DocKit

@Suite
struct CollectionGroupsTests {
    private let title = Column(id: .generate(), name: "Title", type: .text)
    private let hours = Column(id: .generate(), name: "Hours", type: .number)
    private let a = SelectOption(id: .generate(), name: "A"), b = SelectOption(id: .generate(), name: "B"), c = SelectOption(id: .generate(), name: "C")

    private func database() -> (Database, state: Column, tags: Column) {
        let state = Column(id: .generate(), name: "State", type: .select(options: [a, b, c]))
        let tags = Column(id: .generate(), name: "Tags", type: .multiSelect(options: [a, b]))
        let rows = [
            Row(id: .generate(), cells: [title.id: .text(value: "One"), hours.id: .number(value: 8), state.id: .select(option: b.id), tags.id: .multiSelect(options: [a.id, b.id])]),
            Row(id: .generate(), cells: [title.id: .text(value: "Two"), hours.id: .number(value: 2), state.id: .select(option: a.id)]),
            Row(id: .generate(), cells: [title.id: .text(value: "Three"), hours.id: .number(value: 8), tags.id: .multiSelect(options: [b.id])]),
        ]
        return (Database(id: .generate(), columns: [title, hours, state, tags], rows: rows), state, tags)
    }

    private func keys(_ groups: [CollectionGroup]?) -> [String] { groups?.map(\.key) ?? [] }

    /// An option field's groups go in its options' order, a kanban's with every option, the
    /// group of none first; other fields' by value; a table not grouped has none.
    @Test
    func groupsFollowTheirField() {
        let (database, state, _) = database()
        #expect(CollectionView(name: "T", layout: .table(hidden: [], sort: [])).groups(of: database.rows, in: database) == nil)
        let view = CollectionView(name: "T", layout: .table(hidden: [], sort: [], groupBy: state.id))
        let groups = view.groups(of: database.rows, in: database)
        #expect(keys(groups) == ["", a.id.description, b.id.description])
        #expect(groups?[0].rows.map(\.id) == [database.rows[2].id] && groups?[1].value == .select(option: a.id))
        #expect(keys(view.groups(of: database.rows, in: database, everyOption: true)) == ["", a.id.description, b.id.description, c.id.description])
        let byHours = CollectionView(name: "T", layout: .table(hidden: [], sort: [], groupBy: hours.id))
        #expect(byHours.groups(of: database.rows, in: database)?.map(\.rows.count) == [1, 2])
        #expect(byHours.groups(of: database.rows, in: database)?.first?.value == .number(value: 2))
    }

    /// A record with several options is in each of their groups.
    @Test
    func aMultipleSelectPutsARecordInEachGroup() {
        let (database, _, tags) = database()
        let groups = CollectionView(name: "K", layout: .kanban(groupBy: tags.id, hidden: [], sort: [])).groups(of: database.rows, in: database)
        #expect(keys(groups) == ["", a.id.description, b.id.description])
        #expect(groups?.map(\.rows.count) == [1, 1, 2])
        #expect(groups?[1].value == .multiSelect(options: [a.id]))
    }

    /// Descending turns the groups round, the group of none staying first; a manual order
    /// puts the groups it names first, in its order, none where it was put.
    @Test
    func theGroupingOrdersTheGroups() {
        let (database, state, _) = database()
        var view = CollectionView(name: "K", layout: .kanban(groupBy: state.id, hidden: [], sort: []))
        view.grouping.order = .descending
        #expect(keys(view.groups(of: database.rows, in: database, everyOption: true)) == ["", c.id.description, b.id.description, a.id.description])
        view.grouping = CollectionGrouping(order: .manual, manual: [b.id.description, "", a.id.description])
        #expect(keys(view.groups(of: database.rows, in: database, everyOption: true)) == [b.id.description, "", a.id.description, c.id.description])
    }

    /// A table written before tables grouped, and a view before its grouping, read as they were.
    @Test
    func anOlderViewDecodesUngrouped() throws {
        let view = CollectionView(name: "Old", layout: .table(hidden: [], sort: []))
        let data = try JSONEncoder().encode(view)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(String(data: try JSONSerialization.data(withJSONObject: object["layout"]!), encoding: .utf8)?.contains("groupBy") == false)
        object["grouping"] = nil
        let decoded = try JSONDecoder().decode(CollectionView.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == view && decoded.layout.groupBy == nil && decoded.grouping == CollectionGrouping())
        let grouped = CollectionView(name: "New", layout: .table(hidden: [], sort: [], groupBy: hours.id), grouping: CollectionGrouping(order: .descending))
        #expect(try JSONDecoder().decode(CollectionView.self, from: JSONEncoder().encode(grouped)) == grouped)
    }
}
