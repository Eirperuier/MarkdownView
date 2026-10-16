/// A kind of thing in a document as an agent writes it: the fields `AgentBlocks` reads and
/// writes for it, and the values each takes, from the code that checks them. `AgentGuide`
/// puts them together for a model's tools, so what a model is told is what DocKit takes.
public protocol AgentDescribed {
    static var agentUsage: [AgentUsage] { get }
}

extension AgentDescribed {
    /// Its fields, all its usages'.
    public static var agentFields: [AgentField] { agentUsage.flatMap(\.fields) }
}

/// One way of writing it: a block's `type`s, or a part's name; its fields.
public struct AgentUsage: Hashable, Sendable {
    public var names: [String]
    /// What it is, in a few words.
    public var summary: String
    public var fields: [AgentField]

    public init(_ names: [String], _ summary: String = "", fields: [AgentField]) {
        self.names = names
        self.summary = summary
        self.fields = fields
    }
}

/// A field: its key, the values it takes, what it holds, and its own fields.
public struct AgentField: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        case value
        /// Text: a string or runs (`DocText`'s usage).
        case text
        case object([AgentField])
        case list([AgentField])
    }

    public var key: String
    public var values: [String]
    public var about: String
    public var shape: Shape
    /// doc_read shows it; an agent doesn't write it.
    public var readOnly: Bool

    public init(_ key: String, _ values: [String] = [], about: String = "", shape: Shape = .value, readOnly: Bool = false) {
        self.key = key
        self.values = values
        self.about = about
        self.shape = shape
        self.readOnly = readOnly
    }

    public static func text(_ key: String = "text", about: String = "") -> AgentField {
        AgentField(key, about: about, shape: .text)
    }

    /// Only its key, its values and its meaning said elsewhere.
    public var brief: AgentField {
        AgentField(key, shape: shape, readOnly: readOnly)
    }

    /// The fields it holds, an object's or a list's.
    public var fields: [AgentField] {
        switch shape {
        case .object(let fields), .list(let fields): fields
        case .value, .text: []
        }
    }

    /// `"key": a|b (about)`, `"key" [{…}]`.
    var description: String {
        var text = "\"\(key)\""
        if !values.isEmpty { text += ": " + values.joined(separator: "|") }
        switch shape {
        case .object(let fields):
            text += (values.isEmpty ? " {" : ", or {") + fields.map(\.description).joined(separator: ", ") + "}"
        case .list(let fields): text += " [{" + fields.map(\.description).joined(separator: ", ") + "}]"
        case .value, .text: break
        }
        if !about.isEmpty { text += " (\(about))" }
        return text
    }
}

/// What a model's document tools say of blocks and text, from their types' usages.
public enum AgentGuide {
    /// The kinds of block, in the order the guide lists them.
    public static let blockTypes: [any AgentDescribed.Type] = [
        BlockKind.self, DocImage.self, DocLink.self, DocFile.self, DocCard.self, DocView.self,
        Database.self, DocCollection.self, DocPage.self,
    ]

    /// Every block's usage, the fields any block has with it.
    public static var usages: [AgentUsage] { blockTypes.flatMap { $0.agentUsage } }

    /// The blocks a model reads and writes.
    public static var blocks: String {
        var lines = ["A block is an object with a \"type\":"]
        for usage in usages {
            let written = usage.fields.filter { !$0.readOnly }
            var line = "- " + usage.names.map { "\"\($0)\"" }.joined(separator: ", ")
            if !usage.summary.isEmpty { line += " " + usage.summary }
            if !written.isEmpty { line += ": " + written.map(\.description).joined(separator: ", ") }
            lines.append(line)
        }
        let common = DocBlock.agentFields.filter { !$0.readOnly && $0.key != "type" }
        let described = common.map(\.description)
        lines.append("Any block may have " + described.dropLast().joined(separator: ", ") + " and " + described.last! + ".")
        let shown = (DocBlock.agentFields + usages.flatMap(\.fields)).filter(\.readOnly)
        var seen = Set<String>()
        let unique = shown.filter { seen.insert($0.key).inserted }
        lines.append("doc_read also shows " + unique.map(\.description).joined(separator: ", ") + "; they aren't written.")
        return lines.joined(separator: "\n")
    }

    /// Text and its styles.
    public static var text: String {
        let usages = DocText.agentUsage
        var parts = ["Text is a string, or a list of runs: [\"Up \", {\"text\": \"12%\", \"bold\": true}, \" on last week\"]."]
        for usage in usages.dropFirst() {
            parts.append(usage.summary + ": " + usage.fields.map(\.description).joined(separator: ", ") + ".")
        }
        parts.append("Colors: \(AgentBlocks.colors.joined(separator: ", ")), or #RRGGBB.")
        return parts.joined(separator: " ")
    }

    /// Both, as `doclab guide` prints them.
    public static var json: JSONValue {
        .object(["blocks": .string(blocks), "text": .string(text)])
    }
}

// MARK: - The usages

extension DocBlock: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["block"], fields: [
            AgentField("id", about: "the block's, for doc_edit", readOnly: true),
            AgentField("type"),
            AgentField("indent", about: "0 to \(DocBlock.maxIndent); a list item's children are the blocks after it indented deeper"),
            AgentField("boxed", ["true"], about: "on a gray panel"),
            AgentField("font", Typeface.allCases.map(\.rawValue), about: "its text's typeface; a table's, its cells' unless they have their own"),
        ])]
    }
}

extension BlockKind: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        let levels = AgentBlocks.headingLevels
        return [
            AgentUsage(["paragraph", "quote", "caption"], "(caption: small print)", fields: [.text()]),
            AgentUsage(["heading"], fields: [
                AgentField("level", about: "\(levels.lowerBound) to \(levels.upperBound): 1 title, 2 subtitle, 3 heading, 4 strong"),
                .text(),
            ]),
            AgentUsage(["list"], fields: [
                AgentField("style", AgentBlocks.listStyles),
                AgentField("done", ["true", "false"], about: "a task's"),
                AgentField("open", ["true", "false"], about: "a toggle's"),
                .text(),
            ]),
            AgentUsage(["code"], fields: [AgentField("language"), AgentField("code")]),
            AgentUsage(["math"], fields: [AgentField("latex")]),
            AgentUsage(["divider"], fields: []),
        ]
    }
}

extension DocImage: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["image"], fields: [
            AgentField("url"), AgentField("alt"),
            AgentField("fit", Fit.allCases.map(\.rawValue), about: "whole inside its box, or filling it cropped"),
            AgentField("size", Size.allCases.map(\.rawValue), about: "its own size up to the page's width, or the page's width"),
            AgentField("width", about: "its own size in points, when known", readOnly: true),
            AgentField("height", readOnly: true),
            AgentField("blurhash", about: "the picture blurred, when doc_read was asked for it full", readOnly: true),
        ])]
    }
}

extension DocLink: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["link"], fields: [
            AgentField("url"), AgentField("title"), AgentField("summary"), AgentField("image", about: "a preview image's URL"),
            AgentField("layout", DocLayout.allCases.map(\.rawValue)),
        ])]
    }
}

extension DocFile: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["file"], fields: [
            AgentField("url"), AgentField("name"), AgentField("bytes"),
            AgentField("layout", DocLayout.allCases.map(\.rawValue)),
        ])]
    }
}

/// A card's or a view's source and data: given, or a result's.
private let drawnFields = [
    AgentField("source"),
    AgentField("from", about: "a result id, or several"),
    AgentField("data", about: "instead of from"),
    AgentField("source_lines", about: "how long its source is, unless doc_read was asked for it full", readOnly: true),
    AgentField("data_outline", about: "its data's keys and shapes, unless full", readOnly: true),
]

extension DocCard: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["card"], fields: [AgentField("size", sizes)] + drawnFields)]
    }
}

extension DocView: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["view"], "(across the page, as tall as it draws)", fields: drawnFields)]
    }
}

extension DocPage: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["page"], "(a page of its own, opened from here)", fields: [
            AgentField("title"), AgentField("preview"), AgentField("page", about: "its document's id; a new page gets one"),
        ])]
    }
}

extension Column: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["column"], fields: [
            AgentField("name"),
            AgentField("type", AgentBlocks.columnTypes),
            AgentField("options", about: "a select's: names, or {\"name\", \"color\"}", shape: .list([AgentField("name"), AgentField("color")])),
        ])]
    }
}

extension CellStyle: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["cell style"], fields: [
            AgentField("align", AgentBlocks.alignments),
            AgentField("font", AgentBlocks.fonts),
            AgentField("format", AgentBlocks.formats + ["a currency's code"], about: "how a number reads: 0.19 as percent is 19%"),
            AgentField("fill", about: AgentBlocks.fillGuide),
        ])]
    }
}

extension TableStyle: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        [AgentUsage(["table style"], fields: [
            AgentField("header_row", ["true", "false"], about: "the column names' row reads as a header; true unless given"),
            AgentField("header_column", ["true", "false"], about: "the first column reads as one too; false unless given"),
            AgentField("stripe", about: "every other row's fill, as a cell's, or \"\(TableStyle.noStripe)\"; a light gray unless given"),
        ])]
    }
}

/// How a table or a collection's view shows its records.
private let layoutFields = [
    AgentField("group_by", about: "a select column, for a kanban"),
    AgentField("hidden", about: "columns by name"),
    AgentField("sort", shape: .list([AgentField("column"), AgentField("ascending")])),
]

/// The records of a table or a collection.
private let recordFields = [
    AgentField("columns", shape: .list(Column.agentFields)),
    AgentField("rows", about: "{column name: value}, or the values in the columns' order; a text column's values are text, a string or runs"),
]

extension Database: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        let place = [AgentField("column"), AgentField("row", about: "its place in rows, from 0"), AgentField("header", ["true"], about: "instead of row")]
        return [AgentUsage(["table"], "(a plain table)", fields: [
            AgentField("columns", about: "a column's cell style fields style all its cells",
                       shape: .list(Column.agentFields + CellStyle.agentFields)),
            recordFields[1],
            AgentField("style", shape: .object(TableStyle.agentFields)),
            AgentField("cells", about: "a cell's own style, its fields as a column's", shape: .list(place + CellStyle.agentFields.map(\.brief))),
            AgentField("view", AgentBlocks.viewLayouts),
        ] + layoutFields)]
    }
}

extension DocCollection: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        let conditions = CollectionFilter.Condition.allCases.compactMap { AgentBlocks.conditionNames[$0] }
        let filter = AgentField("filter", about: "the records it shows pass every filter", shape: .list([
            AgentField("column"), AgentField("condition", conditions), AgentField("value"),
        ]))
        return [AgentUsage(["collection"], "(records the reader keeps up, shown through views they switch between)", fields: [
            AgentField("name"),
        ] + recordFields + [
            AgentField("views", shape: .list([AgentField("name"), AgentField("layout", AgentBlocks.viewLayouts)] + layoutFields + [filter])),
            AgentField("current", about: "the view showing, by name"),
        ])]
    }
}

extension DocText: AgentDescribed {
    public static var agentUsage: [AgentUsage] {
        let colors = "a color"
        return [
            AgentUsage(["run"], fields: [AgentField("text")]),
            AgentUsage(["styles"], "A run's styles", fields: [
                AgentField("bold"), AgentField("italic"), AgentField("strike"), AgentField("code"),
                AgentField("link", about: "a URL"),
                AgentField("highlight", about: "true, or \(colors)"),
                AgentField("color", about: colors),
                AgentField("pen", AgentBlocks.pens, about: "a hand-drawn mark around or under the words",
                           shape: .object([AgentField("kind"), AgentField("color")])),
            ]),
            AgentUsage(["atoms"], "Atoms in a list of runs", fields: [
                AgentField("math", about: "LaTeX"),
                AgentField("mention", shape: .object([AgentField("kind"), AgentField("id"), AgentField("label")])),
                AgentField("cite", shape: .object([AgentField("url"), AgentField("label")])),
            ]),
        ]
    }
}
