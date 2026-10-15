/// `doc_read` and `doc_edit` over a document (Docs/doc.md §9): the blocks as an agent
/// reads them (AgentBlocks), and its operations turned into steps. Each operation stands
/// alone — all its steps or none — so one that fails leaves the others done.
extension Doc {
    /// The document as an agent reads it: its blocks in order. The cards and views in
    /// `full` come whole (source and data); the rest show their size and data's outline.
    public func agentRead(full: Set<DocBlockID> = []) -> JSONValue {
        .object(["blocks": .array(blocks.map { AgentBlocks.json($0, in: self, full: full.contains($0.id)) })])
    }

    /// The block an agent names: by the end of its id (`AgentBlocks.shortID`), or all of it.
    public func agentBlock(_ name: String) throws(AgentFormatError) -> DocBlockID {
        let name = name.lowercased()
        let found = blocks.filter { $0.id.description == name || (name.count >= 4 && $0.id.description.hasSuffix(name)) }
        guard found.count == 1 else {
            let nearby = blocks.prefix(40).map { block in
                "\(AgentBlocks.shortID(block.id)) \(String(block.text.string.prefix(30)))"
            }
            throw AgentFormatError((found.isEmpty ? "no block \(name)" : "\(name) names several blocks") + "; the blocks are:\n" + nearby.joined(separator: "\n"))
        }
        return found[0].id
    }

    /// Applies an agent's operations in order; each answers on its own (`ok` and the ids of
    /// the blocks it wrote, or `error`). `results` are the data a card or a view may take
    /// `from`.
    public mutating func agentEdit(_ operations: [JSONValue], results: [String: JSONValue] = [:]) -> [AgentEditResult] {
        operations.enumerated().map { index, operation in
            var copy = self
            var steps: [DocStep] = []
            do {
                let written = try copy.agentApply(operation, results: results, steps: &steps)
                self = copy
                return AgentEditResult(index: index, written: written, steps: steps, error: nil)
            } catch let error as AgentFormatError {
                return AgentEditResult(index: index, written: [], steps: [], error: error.message)
            } catch {
                return AgentEditResult(index: index, written: [], steps: [], error: "\(error)")
            }
        }
    }

    private mutating func agentApply(_ operation: JSONValue, results: [String: JSONValue], steps: inout [DocStep]) throws -> [DocBlockID] {
        guard case .object(let object) = operation, let op = object["op"]?.stringValue?.lowercased() else {
            throw AgentFormatError("an operation is an object with \"op\"")
        }
        func step(_ step: DocStep) throws { steps.append(try apply(step)) }
        func target() throws -> DocBlockID {
            guard let name = object["id"]?.stringValue else { throw AgentFormatError("\(op) needs the block's \"id\"") }
            return try agentBlock(name)
        }
        /// The blocks it names: `id`, or `ids` (in the document's order).
        func targets() throws -> [DocBlockID] {
            if case .array(let names)? = object["ids"] {
                let ids = try names.map { name throws -> DocBlockID in
                    guard let name = name.stringValue else { throw AgentFormatError("ids are strings") }
                    return try agentBlock(name)
                }
                return blocks.map(\.id).filter(ids.contains)
            }
            return [try target()]
        }
        /// The block new ones go after: `after` or `before` a block, or `start` or `end`.
        func anchor() throws -> DocBlockID? {
            if let after = object["after"]?.stringValue {
                switch after.lowercased() {
                case "start": return nil
                case "end": return blocks.last?.id
                default: return try agentBlock(after)
                }
            }
            if let before = object["before"]?.stringValue {
                let id = before.lowercased() == "end" ? nil : try agentBlock(before)
                guard let id else { return blocks.last?.id }
                let index = blocks.firstIndex { $0.id == id }!
                return index == 0 ? nil : blocks[index - 1].id
            }
            if object["at"]?.stringValue?.lowercased() == "start" { return nil }
            return blocks.last?.id
        }
        func insert(_ json: JSONValue?, after start: DocBlockID?) throws -> [DocBlockID] {
            guard case .array(let list)? = json, !list.isEmpty else { throw AgentFormatError("\(op) needs \"blocks\": [ … ]") }
            var after = start
            var written: [DocBlockID] = []
            for (index, json) in list.enumerated() {
                var created = databases
                let block: DocBlock
                do {
                    block = try AgentBlocks.block(json, id: .generate(), databases: &created, results: results)
                } catch {
                    throw AgentFormatError("block \(index): \(error.message)")
                }
                for (id, database) in created where databases[id] == nil { try step(.createDatabase(database: database)) }
                try step(.insertBlock(block: block, after: after))
                after = block.id
                written.append(block.id)
            }
            return written
        }

        switch op {
        case "insert":
            return try insert(object["blocks"], after: try anchor())
        case "replace":
            let old = try targets()
            let index = blocks.firstIndex { $0.id == old[0] }!
            let after = index == 0 ? nil : blocks[index - 1].id
            for id in old { try step(.deleteBlock(block: block(id)!, after: nil)) }
            return try insert(object["blocks"], after: after)
        case "delete":
            for id in try targets() { try step(.deleteBlock(block: block(id)!, after: nil)) }
            return []
        case "move":
            let moving = try targets()
            var after = try anchor()
            guard after.map({ !moving.contains($0) }) ?? true else { throw AgentFormatError("blocks can't move after themselves") }
            for id in moving {
                try step(.moveBlock(block: id, after: after, from: nil))
                after = id
            }
            return moving
        case "edit":
            // Words in a block's text for others: `find` (as it reads) and `replace`
            // (a string, or runs with their styles).
            let id = try target()
            guard let find = object["find"]?.stringValue, !find.isEmpty else { throw AgentFormatError("edit needs \"find\": the words as they read") }
            let current = block(id)!.text
            let units = Array(current.string.utf16)
            let needle = Array(find.utf16)
            let matches = (0...max(0, units.count - needle.count)).filter { start in
                start + needle.count <= units.count && Array(units[start..<(start + needle.count)]) == needle
            }
            guard !matches.isEmpty else {
                throw AgentFormatError("\"\(find)\" isn't in the block, which reads: \(current.string.prefix(300))")
            }
            guard matches.count == 1 || object["all"]?.boolValue == true else {
                throw AgentFormatError("\"\(find)\" is in the block \(matches.count) times: give more words, or \"all\": true")
            }
            let replacement = try AgentBlocks.text(object["replace"] ?? .string(""))
            for start in matches.reversed() {
                let range = start..<(start + needle.count)
                try step(.deleteText(block: id, range: range, removed: current.slice(range)))
                if !replacement.isEmpty { try step(.insertText(block: id, at: start, text: replacement)) }
            }
            return [id]
        case "set":
            // A block's kind and fields, as they read in doc_read: given ones change.
            let id = try target()
            let existing = block(id)!
            var json = AgentBlocks.json(existing, in: self, full: true)
            guard case .object(var fields) = json else { return [] }
            // What describes an image's picture goes with it: another URL, not given them, has none.
            if case .image(let image) = existing.kind, let url = object["url"]?.stringValue, url != image.source {
                for key in ["width", "height", "blurhash"] { fields[key] = nil }
            }
            for (key, value) in object where !["op", "id"].contains(key) { fields[key] = value }
            json = .object(fields)
            var created = databases
            let updated = try AgentBlocks.block(json, id: id, databases: &created, results: results)
            // Text goes before a kind that carries none, and comes after one that does.
            if !updated.kind.carriesText, !existing.text.isEmpty {
                try step(.deleteText(block: id, range: 0..<existing.text.length, removed: existing.text))
            }
            if updated.kind != existing.kind || updated.indent != existing.indent {
                // A table's own fields are its database's: a set keeps the database it shows.
                // Its views name columns of the database read back, which a set rebuilt: they
                // go to the columns of the same names in the one it keeps.
                var kind = updated.kind
                func kept(_ view: DatabaseView, from rebuilt: DatabaseID?, to current: DatabaseID) -> DatabaseView {
                    guard let rebuilt = rebuilt.flatMap({ created[$0] }), let current = databases[current] else { return view }
                    return view.mapped(from: rebuilt, to: current)
                }
                if case .database(let rebuilt, let view) = updated.kind, case .database(let current, _) = existing.kind {
                    kind = .database(id: current, view: kept(view, from: rebuilt, to: current))
                }
                // So does a collection's: its name and views change.
                if case .collection(var collection) = updated.kind, case .collection(let current) = existing.kind {
                    let rebuilt = collection.database
                    let showing = collection.currentView?.name
                    collection.database = current.database
                    for index in collection.views.indices {
                        collection.views[index].layout = kept(collection.views[index].layout, from: rebuilt, to: current.database)
                        if let from = created[rebuilt], let to = databases[current.database] {
                            collection.views[index].filters = collection.views[index].filters.compactMap { $0.mapped(from: from, to: to) }
                        }
                        // A view of the same name keeps what's only in the document (its id, its
                        // sums, its fields' order).
                        if let same = current.views.first(where: { $0.name == collection.views[index].name }) {
                            collection.views[index].id = same.id
                            collection.views[index].showsCalculations = same.showsCalculations
                            collection.views[index].calculations = same.calculations
                            collection.views[index].order = same.order
                        }
                    }
                    collection.current = collection.views.first { $0.name == showing }?.id ?? current.current
                    kind = .collection(collection: collection)
                }
                try step(.setBlock(block: id, kind: kind, indent: updated.indent, previousKind: existing.kind, previousIndent: existing.indent))
            }
            // A table's look is its database's too: what the set changed of it, cell by cell.
            if case .database(let rebuilt, _) = updated.kind, case .database(let current, _) = existing.kind,
               let from = created[rebuilt], let to = databases[current] {
                for change in AgentBlocks.styleSteps(from: from, to: to) { try step(.database(id: current, step: change)) }
            }
            if updated.decoration != existing.decoration {
                try step(.setDecoration(block: id, decoration: updated.decoration, previous: existing.decoration))
            }
            if updated.font != existing.font {
                try step(.setFont(block: id, font: updated.font, previous: existing.font))
            }
            let now = block(id)!.text
            if updated.kind.carriesText, updated.text != now {
                if !now.isEmpty { try step(.deleteText(block: id, range: 0..<now.length, removed: now)) }
                if !updated.text.isEmpty { try step(.insertText(block: id, at: 0, text: updated.text)) }
            }
            return [id]
        default:
            throw AgentFormatError("unknown op \"\(op)\": use insert, replace, edit, set, delete or move")
        }
    }
}

/// What one operation did: the blocks it wrote (new, replaced or changed), the steps it
/// took, or why it didn't.
public struct AgentEditResult: Sendable {
    public var index: Int
    public var written: [DocBlockID]
    public var steps: [DocStep]
    public var error: String?

    public var json: JSONValue {
        if let error { return .object(["op": .int(Int64(index)), "error": .string(error)]) }
        return .object(["op": .int(Int64(index)), "ok": true, "ids": .array(written.map { .string(AgentBlocks.shortID($0)) })])
    }
}

extension DatabaseView {
    /// The view with the columns it names in `from` named by their namesakes in `to`; a
    /// column `to` doesn't have is dropped.
    func mapped(from: Database, to: Database) -> DatabaseView {
        let ids = Dictionary(from.columns.compactMap { column in
            to.columns.first { $0.name == column.name }.map { (column.id, $0.id) }
        }, uniquingKeysWith: { first, _ in first })
        let hidden: ([ColumnID]) -> [ColumnID] = { $0.compactMap { ids[$0] } }
        let sorted: ([DatabaseSort]) -> [DatabaseSort] = { $0.compactMap { sort in ids[sort.column].map { DatabaseSort(column: $0, ascending: sort.ascending) } } }
        switch self {
        case .table(let hiddenColumns, let sort, let group):
            return .table(hidden: hidden(hiddenColumns), sort: sorted(sort), groupBy: group.flatMap { ids[$0] })
        case .kanban(let group, let hiddenColumns, let sort):
            return .kanban(groupBy: ids[group] ?? group, hidden: hidden(hiddenColumns), sort: sorted(sort))
        }
    }
}

extension CollectionFilter {
    /// The filter on `to`'s column of the same name, a select's option by its name; nil
    /// when `to` has no such column or option.
    func mapped(from: Database, to: Database) -> CollectionFilter? {
        guard let old = from.columns.first(where: { $0.id == column }),
              let new = to.columns.first(where: { $0.name == old.name }) else { return nil }
        var filter = self
        filter.column = new.id
        func options(_ type: ColumnType) -> [SelectOption] {
            switch type {
            case .select(let options), .multiSelect(let options): options
            default: []
            }
        }
        if case .select(let option)? = value {
            guard let name = options(old.type).first(where: { $0.id == option })?.name,
                  let found = options(new.type).first(where: { $0.name == name }) else { return nil }
            filter.value = .select(option: found.id)
        }
        return filter
    }
}
