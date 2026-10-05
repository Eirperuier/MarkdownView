/// A document: a flat list of blocks plus the databases its database blocks
/// point at. Flat like Craft's model; nesting is expressed through `indent`.
public struct Doc: Hashable, Sendable, Codable {
    public var id: DocID
    public var blocks: [DocBlock]
    public var databases: [DatabaseID: Database]

    public init(id: DocID, blocks: [DocBlock] = [], databases: [DatabaseID: Database] = [:]) {
        self.id = id
        self.blocks = blocks
        self.databases = databases
    }

    public func block(_ id: DocBlockID) -> DocBlock? {
        blocks.first { $0.id == id }
    }
}

public struct DocBlock: Hashable, Sendable, Codable, Identifiable {
    public var id: DocBlockID
    public var kind: BlockKind
    /// `0...6`; list nesting and toggle children both use it.
    public var indent: Int
    /// Empty on the kinds that carry no text.
    public var text: DocText

    public init(id: DocBlockID, kind: BlockKind, indent: Int = 0, text: DocText = DocText()) {
        self.id = id
        self.kind = kind
        self.indent = indent
        self.text = text
    }
}

public enum BlockKind: Hashable, Sendable, Codable {
    case paragraph
    case heading(level: Int)  // 1...6
    case listItem(style: ListStyle)
    case quote
    case code(language: String?)
    case math
    case divider
    case image(image: DocImage)
    case card(card: DocCard)
    case database(id: DatabaseID, view: DatabaseView)

    /// The kinds whose `text` holds content; the rest must be empty.
    public var carriesText: Bool {
        switch self {
        case .paragraph, .heading, .listItem, .quote, .code, .math: true
        case .divider, .image, .card, .database: false
        }
    }

    /// Code and math text never carries marks.
    public var allowsMarks: Bool {
        switch self {
        case .paragraph, .heading, .listItem, .quote: true
        case .code, .math, .divider, .image, .card, .database: false
        }
    }

    /// The database a `.database` block displays; nil on other kinds.
    public var databaseID: DatabaseID? {
        if case .database(let id, _) = self { id } else { nil }
    }
}

public enum ListStyle: Hashable, Sendable, Codable {
    case bullet
    case numbered
    case task(done: Bool)
    case toggle(open: Bool)
}

public struct DocImage: Hashable, Sendable, Codable {
    /// URL or blob ref.
    public var source: String
    public var alt: String

    public init(source: String, alt: String = "") {
        self.source = source
        self.alt = alt
    }
}

/// Same shape as `Wire.AnswerCard` minus fence/item/failure.
public struct DocCard: Hashable, Sendable, Codable {
    public var size: String
    public var view: String?
    public var source: String?
    public var data: JSONValue?

    public init(size: String, view: String? = nil, source: String? = nil, data: JSONValue? = nil) {
        self.size = size
        self.view = view
        self.source = source
        self.data = data
    }
}
