#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What the markdown is for. `exchange` is the canonical form agents read and
/// export writes. `editing` is what an editor renders a block from: it must
/// show exactly the model's text, so whitespace markdown would drop (at a
/// line's edges) is written as entities, line breaks are hard breaks, and an
/// empty block or empty last line gets a zero-width space to keep its line.
public enum DocMarkdownStyle: Sendable {
    case exchange
    case editing
}

extension Doc {
    /// The whole document as markdown — what agents read, export writes and
    /// search indexes. Consecutive list items stay one tight list; every
    /// other boundary is a blank line.
    public var markdown: String { markdown(style: .exchange) }

    public func markdown(style: DocMarkdownStyle) -> String {
        var layout = ListLayout()
        var output = ""
        var previousWasListItem = false
        for block in blocks {
            let placement = layout.place(block)
            let text = markdown(of: block, placement: placement, style: style)
            guard !text.isEmpty else { continue }
            let isListItem = placement != nil
            if !output.isEmpty { output += previousWasListItem && isListItem ? "\n" : "\n\n" }
            output += text
            previousWasListItem = isListItem
        }
        return output
    }

    /// One block's markdown on its own, as the renderer and `doc_read` see
    /// it: a list item without its nesting indentation, but with its number
    /// in the list. Nil when the block doesn't exist.
    public func markdown(of id: DocBlockID, style: DocMarkdownStyle = .exchange) -> String? {
        var layout = ListLayout()
        for block in blocks {
            let placement = layout.place(block)
            guard block.id == id else { continue }
            return markdown(of: block, placement: placement.map { ListPlacement(leading: 0, marker: $0.marker) }, style: style)
        }
        return nil
    }

    private func markdown(of block: DocBlock, placement: ListPlacement?, style: DocMarkdownStyle) -> String {
        let editing = style == .editing
        func inline(singleLine: Bool = false) -> String {
            if editing, block.text.isEmpty { return "&#8203;" }
            let markdown = block.text.markdown(singleLine: singleLine, preservingWhitespace: editing)
            // An empty last line (text ending in a line break) keeps its line the same way.
            return editing && !singleLine && block.text.string.hasSuffix("\n") ? markdown + "&#8203;" : markdown
        }
        switch block.kind {
        case .paragraph:
            return inline()
        case .heading(let level):
            return String(repeating: "#", count: level) + " " + inline(singleLine: true)
        case .listItem(let style):
            guard let placement else { return "" }
            var marker = placement.marker
            if case .task(let done) = style { marker += done ? "[x] " : "[ ] " }
            let continuation = String(repeating: " ", count: placement.leading + placement.marker.count)
            return prefixed(
                inline(),
                first: String(repeating: " ", count: placement.leading) + marker,
                rest: continuation
            )
        case .quote:
            return prefixed(inline(), first: "> ", rest: "> ")
        case .caption:
            // Markdown has no smaller text; HTML's small is what it reads as.
            return "<small>" + inline() + "</small>"
        case .code(let language):
            let fence = Self.fence(for: block.text.string)
            return "\(fence)\(language ?? "")\n\(block.text.string)\(block.text.isEmpty ? "" : "\n")\(fence)"
        case .math:
            let latex = block.text.string
            return latex.hasPrefix("\\begin{") ? latex : "$$\n\(latex)\n$$"
        case .divider:
            return "---"
        case .image(let image):
            return "![\(InlineEscaping.escaped(image.alt, inLink: true))](\(InlineEscaping.destination(image.source)))"
        case .link(let link):
            // A bookmark is a link titled "bookmark" (a paragraph that is only a link
            // stays a paragraph); with no title, the URL is its text.
            let text = link.title.isEmpty ? link.url : link.title
            return "[\(InlineEscaping.escaped(text, inLink: true))](\(InlineEscaping.destination(link.url)) \"bookmark\")"
        case .file(let file):
            return "[\(InlineEscaping.escaped(file.name, inLink: true))](\(InlineEscaping.destination(file.source)) \"file\")"
        case .card(let card):
            guard let json = Self.json(of: card) else { return "" }
            let fence = Self.fence(for: json)
            return "\(fence)floo.card\n\(json)\n\(fence)"
        case .view(let view):
            guard let json = Self.json(of: view) else { return "" }
            let fence = Self.fence(for: json)
            return "\(fence)floo.view\n\(json)\n\(fence)"
        case .database(let id, let view):
            return databases[id].map { $0.markdownTable(view: view) } ?? ""
        }
    }

    /// Indents every line after the first, and empties whitespace-only
    /// prefixes on blank lines so they stay blank.
    private func prefixed(_ text: String, first: String, rest: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            let prefix = index == 0 ? first : rest
            return line.isEmpty ? String(prefix.reversed().drop { $0 == " " }.reversed()) : prefix + line
        }.joined(separator: "\n")
    }

    /// A card or a view as its fence holds it: JSON, keys sorted.
    static func json(of value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A backtick fence longer than any backtick run inside `content`.
    static func fence(for content: String) -> String {
        var longest = 0
        var run = 0
        for character in content {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

/// Where a list item sits: spaces before its marker, and the marker
/// (`- `, `3. `). Nested items indent to their parent's content column.
struct ListPlacement: Equatable {
    var leading: Int
    var marker: String
}

/// Walks the blocks in order and lays out list items the way CommonMark
/// reads them back: depth clamped to one below the deepest open level,
/// numbering counted per level.
struct ListLayout {
    private var levels: [(numbered: Bool, ordinal: Int, column: Int)] = []

    /// The depth the last placed item reads at (its indent, clamped).
    private(set) var depth = 0
    /// Its number in its list (1 for a bullet).
    var ordinal: Int { levels.last?.ordinal ?? 1 }

    mutating func place(_ block: DocBlock) -> ListPlacement? {
        guard case .listItem(let style) = block.kind else {
            levels = []
            return nil
        }
        let depth = min(block.indent, levels.count)
        self.depth = depth
        let leading = depth == 0 ? 0 : levels[depth - 1].column
        let numbered = style == .numbered
        let ordinal = depth < levels.count && numbered && levels[depth].numbered ? levels[depth].ordinal + 1 : 1
        let marker = numbered ? "\(ordinal). " : "- "
        levels = Array(levels.prefix(depth)) + [(numbered, ordinal, leading + marker.count)]
        return ListPlacement(leading: leading, marker: marker)
    }
}

extension Database {
    /// A GFM table of the view's visible columns, rows in the view's order.
    /// Kanban views export the same table; grouping is a view concern.
    func markdownTable(view: DatabaseView) -> String {
        guard let table = cells(view: view) else { return "" }
        func line(_ cells: [String]) -> String { "| " + cells.map(Self.cellMarkdown).joined(separator: " | ") + " |" }
        let rule = "| " + table.header.map { _ in "---" }.joined(separator: " | ") + " |"
        return ([line(table.header), rule] + table.rows.map(line)).joined(separator: "\n")
    }

    /// What the view shows: its visible columns' names, and each row's cells as they
    /// read (formulas as what they compute), rows in the view's order. Nil when no
    /// column is visible.
    func cells(view: DatabaseView) -> (header: [String], rows: [[String]])? {
        let (hidden, sort): ([ColumnID], [DatabaseSort]) = switch view {
        case .table(let hidden, let sort): (hidden, sort)
        case .kanban(_, let hidden, let sort): (hidden, sort)
        }
        let visible = columns.filter { !hidden.contains($0.id) }
        guard !visible.isEmpty else { return nil }
        let ordered = rows.enumerated().sorted { lhs, rhs in
            for key in sort {
                guard let column = columns.first(where: { $0.id == key.column }) else { continue }
                let order = column.compare(lhs.element.cells[column.id], rhs.element.cells[column.id])
                if order != 0 { return key.ascending ? order < 0 : order > 0 }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        // Formulas show what they compute, in the database's own order (their references).
        let rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0 + 1) })
        let columnIndex = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1.id, $0) })
        return (visible.map(\.name), ordered.map { row in
            visible.map { column in
                let text = column.display(row.cells[column.id])
                return DatabaseFormula.isFormula(text)
                    ? DatabaseFormula.displayed(text, in: self, row: rowIndex[row.id] ?? 0, column: columnIndex[column.id] ?? 0)
                    : text
            }
        })
    }

    static func cellMarkdown(_ text: String) -> String {
        DocText(string: text).markdown(singleLine: true, escapingPipes: true)
    }
}

extension Column {
    /// How a cell reads as plain text: option names, ISO dates, ✓.
    func display(_ value: CellValue?) -> String {
        switch value {
        case nil: return ""
        case .text(let value), .url(let value), .person(let value): return value
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .select(let option): return optionName(option)
        case .multiSelect(let options): return options.map(optionName).joined(separator: ", ")
        case .date(let value): return Self.isoDate(value)
        case .checkbox(let value): return value ? "✓" : ""
        }
    }

    private func optionName(_ id: OptionID) -> String {
        switch type {
        case .select(let options), .multiSelect(let options): options.first { $0.id == id }?.name ?? ""
        default: ""
        }
    }

    /// Three-way comparison for sorting; empty cells sort last.
    func compare(_ lhs: CellValue?, _ rhs: CellValue?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case (.number(let a)?, .number(let b)?): return a < b ? -1 : a > b ? 1 : 0
        case (.date(let a)?, .date(let b)?): return a < b ? -1 : a > b ? 1 : 0
        default:
            let a = display(lhs)
            let b = display(rhs)
            return a < b ? -1 : a > b ? 1 : 0
        }
    }

    /// `yyyy-MM-dd` in UTC, from the civil-from-days algorithm (no calendar
    /// dependency, so it reads the same on every platform).
    static func isoDate(_ time: Timestamp) -> String {
        let days = Int64((Double(time.millisecondsSince1970) / 86_400_000).rounded(.down))
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        func pad(_ value: Int64, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }
}
