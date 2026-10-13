/// Blocks as an agent reads and writes them (`doc_read`, `doc_edit`): JSON objects in the
/// model's own words, and nothing of the document lost on the way — a block's kind, its
/// indent and box, its text with every style, a link's layout, an image's fit, a card's
/// size and data, a table's columns. Markdown can't carry these; this can.
///
/// Text is a string, or runs of text each with its styles:
/// `[{"text": "steps up "}, {"text": "12%", "bold": true, "color": "green"}]` — no
/// offsets for a model to count. A block's id is the last 8 characters of its own
/// (the random part), matched as a suffix.
public enum AgentBlocks {
    /// What a model may name: the kinds of block and the values of their fields.
    public static let colors = ["gray", "slate", "purple", "blue", "cyan", "mint", "green", "lemon", "yellow", "red", "orange", "brown"]

    /// A block's id as an agent sees it.
    public static func shortID(_ id: DocBlockID) -> String {
        String(id.description.suffix(8))
    }
}

/// What's wrong with what an agent wrote, in words it can act on.
public struct AgentFormatError: Error, Hashable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

// MARK: - Reading

extension AgentBlocks {
    /// A block as an agent reads it. A card or a view shows its size and a sketch of its
    /// data unless `full`, which adds its source and data whole.
    public static func json(_ block: DocBlock, in doc: Doc, full: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(shortID(block.id))]
        if block.indent > 0 { object["indent"] = .int(Int64(block.indent)) }
        if block.decoration == .block { object["boxed"] = .bool(true) }
        func text() { object["text"] = json(block.text) }
        switch block.kind {
        case .paragraph:
            object["type"] = "paragraph"
            text()
        case .heading(let level):
            object["type"] = "heading"
            object["level"] = .int(Int64(level))
            text()
        case .listItem(let style):
            object["type"] = "list"
            switch style {
            case .bullet: object["style"] = "bullet"
            case .numbered: object["style"] = "numbered"
            case .task(let done):
                object["style"] = "task"
                object["done"] = .bool(done)
            case .toggle(let open):
                object["style"] = "toggle"
                object["open"] = .bool(open)
            }
            text()
        case .quote:
            object["type"] = "quote"
            text()
        case .caption:
            object["type"] = "caption"
            text()
        case .code(let language):
            object["type"] = "code"
            if let language { object["language"] = .string(language) }
            object["code"] = .string(block.text.string)
        case .math:
            object["type"] = "math"
            object["latex"] = .string(block.text.string)
        case .divider:
            object["type"] = "divider"
        case .image(let image):
            object["type"] = "image"
            object["url"] = .string(image.source)
            if !image.alt.isEmpty { object["alt"] = .string(image.alt) }
            object["fit"] = .string(image.fit.rawValue)
            object["size"] = .string(image.size.rawValue)
        case .link(let link):
            object["type"] = "link"
            object["url"] = .string(link.url)
            if !link.title.isEmpty { object["title"] = .string(link.title) }
            if !link.summary.isEmpty { object["summary"] = .string(link.summary) }
            if let image = link.image { object["image"] = .string(image) }
            object["layout"] = .string(link.layout.rawValue)
        case .file(let file):
            object["type"] = "file"
            object["url"] = .string(file.source)
            object["name"] = .string(file.name)
            if let size = file.size { object["bytes"] = .int(Int64(size)) }
            object["layout"] = .string(file.layout.rawValue)
        case .card(let card):
            object["type"] = "card"
            object["size"] = .string(card.size)
            drawn(source: card.source ?? "", data: card.data, full: full, into: &object)
        case .view(let view):
            object["type"] = "view"
            drawn(source: view.source, data: view.data, full: full, into: &object)
        case .database(let id, let view):
            object["type"] = "table"
            guard let database = doc.databases[id] else { break }
            let names = Dictionary(uniqueKeysWithValues: database.columns.map { ($0.id, $0.name) })
            object["columns"] = .array(database.columns.map(json))
            object["rows"] = .array(database.rows.map { row in
                .object(Dictionary(uniqueKeysWithValues: database.columns.compactMap { column in
                    row.cells[column.id].map { (column.name, json($0, in: column)) }
                }))
            })
            switch view {
            case .table(let hidden, let sort):
                object["view"] = "table"
                details(hidden: hidden, sort: sort, names: names, into: &object)
            case .kanban(let group, let hidden, let sort):
                object["view"] = "kanban"
                object["group_by"] = names[group].map(JSONValue.string) ?? .null
                details(hidden: hidden, sort: sort, names: names, into: &object)
            }
        }
        return .object(object)
    }

    /// A card's or a view's source and data: whole, or how long it is and what its data holds.
    private static func drawn(source: String, data: JSONValue?, full: Bool, into object: inout [String: JSONValue]) {
        if full {
            object["source"] = .string(source)
            object["data"] = data ?? .object([:])
        } else {
            object["source_lines"] = .int(Int64(source.split(separator: "\n", omittingEmptySubsequences: false).count))
            object["data_outline"] = data.map(outline) ?? .null
        }
    }

    private static func details(hidden: [ColumnID], sort: [DatabaseSort], names: [ColumnID: String], into object: inout [String: JSONValue]) {
        if !hidden.isEmpty { object["hidden"] = .array(hidden.compactMap { names[$0].map(JSONValue.string) }) }
        if !sort.isEmpty {
            object["sort"] = .array(sort.compactMap { sort in
                names[sort.column].map { .object(["column": .string($0), "ascending": .bool(sort.ascending)]) }
            })
        }
    }

    /// What a value holds, short: keys and their shapes, how many in a list, the start of
    /// a long string.
    static func outline(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object): .object(object.mapValues(outline))
        case .array(let array):
            .string("\(array.count) item\(array.count == 1 ? "" : "s")" + (array.first.map { " like " + describe(outline($0)) } ?? ""))
        case .string(let string) where string.count > 40: .string(String(string.prefix(40)) + "…")
        default: value
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .object(let object): "{" + object.keys.sorted().joined(separator: ", ") + "}"
        case .string(let string): "\"\(string)\""
        case .int(let value): "\(value)"
        case .double(let value): "\(value)"
        case .bool(let value): "\(value)"
        case .array: "[…]"
        case .null: "null"
        }
    }

    private static func json(_ column: Column) -> JSONValue {
        var object: [String: JSONValue] = ["name": .string(column.name)]
        switch column.type {
        case .text: object["type"] = "text"
        case .number: object["type"] = "number"
        case .select(let options):
            object["type"] = "select"
            object["options"] = .array(options.map { .string($0.name) })
        case .multiSelect(let options):
            object["type"] = "multi_select"
            object["options"] = .array(options.map { .string($0.name) })
        case .date: object["type"] = "date"
        case .checkbox: object["type"] = "checkbox"
        case .url: object["type"] = "url"
        case .person: object["type"] = "person"
        }
        return .object(object)
    }

    private static func json(_ cell: CellValue, in column: Column) -> JSONValue {
        let options: [SelectOption] = switch column.type {
        case .select(let options), .multiSelect(let options): options
        default: []
        }
        func name(_ id: OptionID) -> JSONValue { options.first { $0.id == id }.map { .string($0.name) } ?? .null }
        return switch cell {
        case .text(let value), .url(let value), .person(let value): .string(value)
        case .number(let value): .double(value)
        case .select(let option): name(option)
        case .multiSelect(let ids): .array(ids.map(name))
        case .date(let value): .string(ISODay.string(value))
        case .checkbox(let value): .bool(value)
        }
    }

    /// Text as an agent reads it: the string when it has no styles, else its runs.
    public static func json(_ text: DocText) -> JSONValue {
        guard !text.marks.isEmpty else { return .string(text.string) }
        let units = Array(text.string.utf16)
        var cuts = Set([0, units.count])
        for span in text.marks {
            cuts.insert(span.range.lowerBound)
            cuts.insert(span.range.upperBound)
        }
        let bounds = cuts.filter { $0 >= 0 && $0 <= units.count }.sorted()
        var runs: [[String: JSONValue]] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) where start < end {
            let marks = text.marks.filter { $0.range.lowerBound <= start && end <= $0.range.upperBound }.map(\.mark)
            var run: [String: JSONValue] = [:]
            var atom = false
            for mark in marks {
                switch mark {
                case .bold: run["bold"] = .bool(true)
                case .italic: run["italic"] = .bool(true)
                case .strike: run["strike"] = .bool(true)
                case .code: run["code"] = .bool(true)
                case .link(let url): run["link"] = .string(url)
                case .highlight(let color): run["highlight"] = color.map(JSONValue.string) ?? .bool(true)
                case .color(let color): run["color"] = .string(color)
                case .pen(let kind, let color):
                    run["pen"] = color.map { .object(["kind": .string(kind), "color": .string($0)]) } ?? .string(kind)
                case .mention(let kind, let id, let label):
                    run["mention"] = .object(["kind": .string(kind), "id": .string(id), "label": .string(label)])
                    atom = true
                case .inlineMath(let latex):
                    run["math"] = .string(latex)
                    atom = true
                case .cite(let url, let label):
                    run["cite"] = .object(["url": .string(url), "label": .string(label)])
                    atom = true
                }
            }
            if !atom { run["text"] = .string(String(decoding: units[start..<end], as: UTF16.self)) }
            // Plain text after plain text is one run.
            if Array(run.keys) == ["text"], let last = runs.last, Array(last.keys) == ["text"],
                case .string(let before)? = last["text"], case .string(let after)? = run["text"]
            {
                runs[runs.count - 1]["text"] = .string(before + after)
            } else {
                runs.append(run)
            }
        }
        return .array(runs.map { Array($0.keys) == ["text"] ? $0["text"]! : .object($0) })
    }
}

// MARK: - Writing

extension AgentBlocks {
    /// The block an agent wrote, with `id`. A table's database goes into `databases`;
    /// a card's or a view's `from` names a result in `results`, its data.
    public static func block(
        _ json: JSONValue, id: DocBlockID, databases: inout [DatabaseID: Database], results: [String: JSONValue]
    ) throws(AgentFormatError) -> DocBlock {
        // A bare string is a paragraph of it.
        if case .string = json { return try block(.object(["text": json]), id: id, databases: &databases, results: results) }
        guard case .object(let object) = json else { throw AgentFormatError("a block is an object with a \"type\"") }
        let type = (object["type"]?.stringValue ?? "paragraph").lowercased()
        var indent = Int(object["indent"]?.intValue ?? 0)
        guard (0...6).contains(indent) else { throw AgentFormatError("indent is 0 to 6, not \(indent)") }
        let boxed = object["boxed"]?.boolValue ?? false
        func text() throws(AgentFormatError) -> DocText {
            try AgentBlocks.text(object["text"] ?? object["content"] ?? .string(""))
        }
        func plain(_ keys: String...) -> String {
            for key in keys { if let value = object[key]?.stringValue { return value } }
            return ""
        }
        let kind: BlockKind
        var content = DocText()
        switch type {
        case "paragraph", "text", "p":
            kind = .paragraph
            content = try text()
        case "heading", "h1", "h2", "h3", "h4", "h5", "h6":
            let level = type.count == 2 ? Int(String(type.last!))! : Int(object["level"]?.intValue ?? 1)
            guard (1...6).contains(level) else { throw AgentFormatError("a heading's level is 1 to 6, not \(level)") }
            kind = .heading(level: level)
            content = try text()
        case "list", "bullet", "numbered", "task", "todo", "toggle":
            let style = type == "list" ? (object["style"]?.stringValue ?? "bullet").lowercased() : type
            switch style {
            case "bullet": kind = .listItem(style: .bullet)
            case "numbered": kind = .listItem(style: .numbered)
            case "task", "todo": kind = .listItem(style: .task(done: object["done"]?.boolValue ?? false))
            case "toggle": kind = .listItem(style: .toggle(open: object["open"]?.boolValue ?? true))
            default: throw AgentFormatError("a list's style is bullet, numbered, task or toggle, not \(style)")
            }
            content = try text()
        case "quote":
            kind = .quote
            content = try text()
        case "caption":
            kind = .caption
            content = try text()
        case "code":
            kind = .code(language: object["language"]?.stringValue)
            content = DocText(string: plain("code", "text"))
        case "math":
            kind = .math
            content = DocText(string: plain("latex", "text"))
        case "divider":
            kind = .divider
        case "image":
            let source = plain("url", "source")
            guard !source.isEmpty else { throw AgentFormatError("an image needs its \"url\"") }
            kind = .image(image: DocImage(
                source: source, alt: plain("alt"),
                fit: try choice(object["fit"], DocImage.Fit.self, default: .fit, field: "an image's fit"),
                size: try choice(object["size"], DocImage.Size.self, default: .auto, field: "an image's size")))
        case "link", "bookmark":
            let url = plain("url")
            guard !url.isEmpty else { throw AgentFormatError("a link needs its \"url\"") }
            kind = .link(link: DocLink(
                url: url, title: plain("title"), summary: plain("summary"), image: object["image"]?.stringValue,
                layout: try choice(object["layout"], DocLayout.self, default: .regular, field: "a link's layout")))
        case "file":
            let source = plain("url", "source")
            guard !source.isEmpty else { throw AgentFormatError("a file needs its \"url\"") }
            kind = .file(file: DocFile(
                source: source, name: plain("name"), size: object["bytes"]?.intValue.map(Int.init),
                layout: try choice(object["layout"], DocLayout.self, default: .regular, field: "a file's layout")))
        case "card":
            let size = (object["size"]?.stringValue ?? "summary").lowercased()
            guard ["glance", "summary", "detail", "collection"].contains(size) else {
                throw AgentFormatError("a card's size is glance, summary, detail or collection, not \(size)")
            }
            let source = plain("source")
            guard !source.isEmpty else { throw AgentFormatError("a card needs its \"source\"") }
            kind = .card(card: DocCard(size: size, source: source, data: try data(object, results: results)))
        case "view":
            let source = plain("source")
            guard !source.isEmpty else { throw AgentFormatError("a view needs its \"source\"") }
            kind = .view(view: DocView(source: source, data: try data(object, results: results)))
        case "table", "database", "kanban":
            let database = try table(object, generating: id)
            databases[database.id] = database
            kind = .database(id: database.id, view: try view(object, of: database, kanban: type == "kanban"))
        default:
            throw AgentFormatError(
                "unknown block type \"\(type)\": use paragraph, heading, list, quote, caption, code, math, divider, image, link, file, card, view or table")
        }
        if case .listItem = kind {} else if indent > 0, !kind.carriesText { indent = 0 }
        return DocBlock(id: id, kind: kind, indent: indent, text: content, decoration: boxed ? .block : nil)
    }

    /// A card's or a view's data: what it gives, or the result it names (several: by name).
    static func data(_ object: [String: JSONValue], results: [String: JSONValue]) throws(AgentFormatError) -> JSONValue? {
        if let data = object["data"], data != .null { return data }
        let names: [String] = switch object["from"] {
        case .string(let name)?: [name]
        case .array(let names)?: names.compactMap(\.stringValue)
        default: []
        }
        guard !names.isEmpty else { return nil }
        var found: [String: JSONValue] = [:]
        for name in names {
            guard let result = results[name] else {
                throw AgentFormatError("no result \"\(name)\"; the results are: \(results.keys.sorted().joined(separator: ", "))")
            }
            found[name] = result
        }
        return names.count == 1 ? found[names[0]] : .object(found)
    }

    private static func choice<Value: RawRepresentable<String>>(
        _ value: JSONValue?, _ type: Value.Type, default fallback: Value, field: String
    ) throws(AgentFormatError) -> Value where Value: CaseIterable {
        guard let name = value?.stringValue else { return fallback }
        guard let chosen = Value(rawValue: name.lowercased()) else {
            throw AgentFormatError("\(field) is \(Value.allCases.map(\.rawValue).joined(separator: " or ")), not \(name)")
        }
        return chosen
    }

    /// Text an agent wrote: a string, or runs (strings or objects with `text` and styles).
    public static func text(_ json: JSONValue) throws(AgentFormatError) -> DocText {
        switch json {
        case .string(let string): return DocText(string: string)
        case .null: return DocText()
        case .array(let runs):
            var string = ""
            var length = 0
            var marks: [MarkSpan] = []
            for run in runs {
                if case .string(let plain) = run {
                    string += plain
                    length += plain.utf16.count
                    continue
                }
                guard case .object(let object) = run else { throw AgentFormatError("a run is a string or an object with \"text\"") }
                if let atom = try atom(object) {
                    string.append(DocText.atomCharacter)
                    marks.append(MarkSpan(range: length..<(length + 1), mark: atom))
                    length += 1
                    continue
                }
                let piece = object["text"]?.stringValue ?? object["t"]?.stringValue ?? ""
                let range = length..<(length + piece.utf16.count)
                string += piece
                length = range.upperBound
                guard !range.isEmpty else { continue }
                for mark in try styles(object) { marks.append(MarkSpan(range: range, mark: mark)) }
            }
            var text = DocText(string: string, marks: marks)
            text.normalize()
            return text
        default:
            throw AgentFormatError("text is a string or a list of runs")
        }
    }

    private static func atom(_ run: [String: JSONValue]) throws(AgentFormatError) -> Mark? {
        if case .object(let mention)? = run["mention"] {
            guard let id = mention["id"]?.stringValue else { throw AgentFormatError("a mention needs its \"id\"") }
            return .mention(kind: mention["kind"]?.stringValue ?? "person", id: id, label: mention["label"]?.stringValue ?? id)
        }
        if let latex = run["math"]?.stringValue { return .inlineMath(latex: latex) }
        if case .object(let cite)? = run["cite"] {
            guard let url = cite["url"]?.stringValue else { throw AgentFormatError("a citation needs its \"url\"") }
            return .cite(url: url, label: cite["label"]?.stringValue ?? url)
        }
        return nil
    }

    private static func styles(_ run: [String: JSONValue]) throws(AgentFormatError) -> [Mark] {
        var marks: [Mark] = []
        if run["bold"]?.boolValue == true { marks.append(.bold) }
        if run["italic"]?.boolValue == true { marks.append(.italic) }
        if run["strike"]?.boolValue == true { marks.append(.strike) }
        if run["code"]?.boolValue == true { marks.append(.code) }
        if let url = run["link"]?.stringValue { marks.append(.link(url: url)) }
        switch run["highlight"] {
        case .bool(true)?: marks.append(.highlight(color: nil))
        case .string(let color)?: marks.append(.highlight(color: try colorName(color)))
        default: break
        }
        if let color = run["color"]?.stringValue { marks.append(.color(try colorName(color))) }
        switch run["pen"] {
        case .string(let kind)?: marks.append(.pen(kind: try penKind(kind), color: nil))
        case .object(let pen)?:
            marks.append(.pen(kind: try penKind(pen["kind"]?.stringValue ?? "circle"), color: try pen["color"]?.stringValue.map(colorName)))
        default: break
        }
        return marks
    }

    private static func colorName(_ name: String) throws(AgentFormatError) -> String {
        let name = name.lowercased()
        guard colors.contains(name) || (name.hasPrefix("#") && name.count == 7) else {
            throw AgentFormatError("a colour is one of \(colors.joined(separator: ", ")) or #RRGGBB, not \(name)")
        }
        return name
    }

    private static func penKind(_ kind: String) throws(AgentFormatError) -> String {
        guard ["circle", "wavy"].contains(kind.lowercased()) else { throw AgentFormatError("a pen is circle or wavy, not \(kind)") }
        return kind.lowercased()
    }

    // MARK: Tables

    private static func table(_ object: [String: JSONValue], generating id: DocBlockID) throws(AgentFormatError) -> Database {
        guard case .array(let columnsJSON)? = object["columns"], !columnsJSON.isEmpty else {
            throw AgentFormatError("a table needs \"columns\": [{\"name\", \"type\"}]")
        }
        var columns: [Column] = []
        for column in columnsJSON {
            let (name, typeName, optionNames): (String, String, [String]) = switch column {
            case .string(let name): (name, "text", [])
            case .object(let column): (
                column["name"]?.stringValue ?? "", (column["type"]?.stringValue ?? "text").lowercased(),
                column["options"].flatMap { if case .array(let names) = $0 { names.compactMap(\.stringValue) } else { nil } } ?? [])
            default: ("", "", [])
            }
            guard !name.isEmpty else { throw AgentFormatError("a column needs its \"name\"") }
            let options = optionNames.map { SelectOption(id: .generate(), name: $0) }
            let type: ColumnType
            switch typeName {
            case "text": type = .text
            case "number": type = .number
            case "select": type = .select(options: options)
            case "multi_select", "multiselect": type = .multiSelect(options: options)
            case "date": type = .date
            case "checkbox": type = .checkbox
            case "url": type = .url
            case "person": type = .person
            default: throw AgentFormatError("a column's type is text, number, select, multi_select, date, checkbox, url or person, not \(typeName)")
            }
            columns.append(Column(id: .generate(), name: name, type: type))
        }
        var rows: [Row] = []
        let rowsJSON: [JSONValue] = if case .array(let rows)? = object["rows"] { rows } else { [] }
        for rowJSON in rowsJSON {
            var cells: [ColumnID: CellValue] = [:]
            for (index, column) in columns.enumerated() {
                let value: JSONValue? = switch rowJSON {
                case .object(let row): row[column.name]
                case .array(let values): values.indices.contains(index) ? values[index] : nil
                default: nil
                }
                guard let value, value != .null else { continue }
                cells[column.id] = try cell(value, in: &columns[index])
            }
            rows.append(Row(id: .generate(), cells: cells))
        }
        return Database(id: .generate(), columns: columns, rows: rows)
    }

    /// A cell's value; a select's option it doesn't have yet is added to its column.
    private static func cell(_ value: JSONValue, in column: inout Column) throws(AgentFormatError) -> CellValue? {
        func option(_ name: String, in options: inout [SelectOption]) -> OptionID {
            if let found = options.first(where: { $0.name == name }) { return found.id }
            let added = SelectOption(id: .generate(), name: name)
            options.append(added)
            return added.id
        }
        switch column.type {
        case .text: return .text(value: value.stringValue ?? describe(value))
        case .url: return .url(value: value.stringValue ?? "")
        case .person: return .person(value: value.stringValue ?? "")
        case .number:
            guard let number = value.doubleValue ?? value.stringValue.flatMap(Double.init) else {
                throw AgentFormatError("column \(column.name) holds numbers, not \(describe(value))")
            }
            return .number(value: number)
        case .checkbox: return .checkbox(value: value.boolValue ?? false)
        case .date:
            guard let day = value.stringValue.flatMap(ISODay.timestamp) else {
                throw AgentFormatError("column \(column.name) holds dates as \"yyyy-MM-dd\", not \(describe(value))")
            }
            return .date(value: day)
        case .select(var options):
            guard let name = value.stringValue else { return nil }
            let id = option(name, in: &options)
            column.type = .select(options: options)
            return .select(option: id)
        case .multiSelect(var options):
            let names: [String] = if case .array(let names) = value { names.compactMap(\.stringValue) } else { value.stringValue.map { [$0] } ?? [] }
            let ids = names.map { option($0, in: &options) }
            column.type = .multiSelect(options: options)
            return .multiSelect(options: ids)
        }
    }

    private static func view(_ object: [String: JSONValue], of database: Database, kanban: Bool) throws(AgentFormatError) -> DatabaseView {
        func column(_ name: String) throws(AgentFormatError) -> ColumnID {
            guard let column = database.columns.first(where: { $0.name == name }) else {
                throw AgentFormatError("no column \"\(name)\"; the columns are \(database.columns.map(\.name).joined(separator: ", "))")
            }
            return column.id
        }
        var hidden: [ColumnID] = []
        if case .array(let names)? = object["hidden"] {
            for name in names.compactMap(\.stringValue) { hidden.append(try column(name)) }
        }
        var sort: [DatabaseSort] = []
        if case .array(let sorts)? = object["sort"] {
            for entry in sorts {
                guard let name = entry["column"]?.stringValue else { continue }
                sort.append(DatabaseSort(column: try column(name), ascending: entry["ascending"]?.boolValue ?? true))
            }
        }
        guard kanban || object["view"]?.stringValue == "kanban" else { return .table(hidden: hidden, sort: sort) }
        let group: ColumnID
        if let name = object["group_by"]?.stringValue {
            group = try column(name)
        } else if let select = database.columns.first(where: { if case .select = $0.type { true } else { false } }) {
            group = select.id
        } else {
            throw AgentFormatError("a kanban groups by a select column: give \"group_by\"")
        }
        return .kanban(groupBy: group, hidden: hidden, sort: sort)
    }
}

/// Days as `yyyy-MM-dd`, at midnight UTC.
enum ISODay {
    static func string(_ timestamp: Timestamp) -> String {
        let days = Int(floorDivide(timestamp.millisecondsSince1970, 86_400_000))
        let (year, month, day) = civil(fromDays: days)
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return "\(year)-\(two(month))-\(two(day))"
    }

    static func timestamp(_ string: String) -> Timestamp? {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return Timestamp(millisecondsSince1970: Int64(days(year: parts[0], month: parts[1], day: parts[2])) * 86_400_000)
    }

    private static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    /// Howard Hinnant's days-from-civil and its inverse.
    private static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays z: Int) -> (Int, Int, Int) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
