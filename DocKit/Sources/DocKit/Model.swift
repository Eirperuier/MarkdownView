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
    /// Drawn around the block, whatever its kind; neighbours with the same one share it.
    public var decoration: BlockDecoration?

    public init(id: DocBlockID, kind: BlockKind, indent: Int = 0, text: DocText = DocText(), decoration: BlockDecoration? = nil) {
        self.id = id
        self.kind = kind
        self.indent = indent
        self.text = text
        self.decoration = decoration
    }
}

/// What's drawn around a block (Craft's decorations; its Focus is the quote kind).
public enum BlockDecoration: String, Hashable, Sendable, Codable {
    /// A grey box with room inside.
    case block
}

public enum BlockKind: Hashable, Sendable, Codable {
    case paragraph
    case heading(level: Int)  // 1...6
    case listItem(style: ListStyle)
    case quote
    /// Text set smaller and quieter than the body (Craft's Caption).
    case caption
    case code(language: String?)
    case math
    case divider
    case image(image: DocImage)
    /// A web page, shown with its title, summary and preview (a bookmark).
    case link(link: DocLink)
    /// A file attached to the document.
    case file(file: DocFile)
    case card(card: DocCard)
    /// A view the page's width, as tall as it draws (not a card: no frame, no size).
    case view(view: DocView)
    case database(id: DatabaseID, view: DatabaseView)

    /// The kinds whose `text` holds content; the rest must be empty.
    public var carriesText: Bool {
        switch self {
        case .paragraph, .heading, .listItem, .quote, .caption, .code, .math: true
        case .divider, .image, .link, .file, .card, .view, .database: false
        }
    }

    /// Code and math text never carries marks.
    public var allowsMarks: Bool {
        switch self {
        case .paragraph, .heading, .listItem, .quote, .caption: true
        case .code, .math, .divider, .image, .link, .file, .card, .view, .database: false
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
    /// Inside its box the image fits whole, or fills it (cropped).
    public var fit: Fit
    /// Its natural size up to the page's width, or the page's width.
    public var size: Size

    public enum Fit: String, Hashable, Sendable, Codable { case fit, fill }
    public enum Size: String, Hashable, Sendable, Codable { case auto, large }

    public init(source: String, alt: String = "", fit: Fit = .fit, size: Size = .auto) {
        self.source = source
        self.alt = alt
        self.fit = fit
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case source, alt, fit, size }

    /// Images written before fit and size existed read as fit, auto.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        alt = try container.decode(String.self, forKey: .alt)
        fit = try container.decodeIfPresent(Fit.self, forKey: .fit) ?? .fit
        size = try container.decodeIfPresent(Size.self, forKey: .size) ?? .auto
    }
}

/// How a link or a file sits on the page (Craft's): a pill as wide as its name, a row
/// with a thumbnail, or a card with its preview on top.
public enum DocLayout: String, Hashable, Sendable, Codable, CaseIterable {
    case small, regular, card
}

public struct DocLink: Hashable, Sendable, Codable {
    public var url: String
    /// The page's title; empty shows the URL.
    public var title: String
    public var summary: String
    /// The page's preview image (URL), if it has one.
    public var image: String?
    public var layout: DocLayout

    public init(url: String, title: String = "", summary: String = "", image: String? = nil, layout: DocLayout = .regular) {
        self.url = url
        self.title = title
        self.summary = summary
        self.image = image
        self.layout = layout
    }
}

public struct DocFile: Hashable, Sendable, Codable {
    /// A blob ref (`blob:…`).
    public var source: String
    public var name: String
    /// In bytes, when known.
    public var size: Int?
    public var layout: DocLayout

    public init(source: String, name: String, size: Int? = nil, layout: DocLayout = .regular) {
        self.source = source
        self.name = name
        self.size = size
        self.layout = layout
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

/// A view drawn from source in the cards' language with its data, across the page and as
/// tall as it draws: a dashboard, a comparison, a form (not a card, which has a size).
public struct DocView: Hashable, Sendable, Codable {
    public var source: String
    public var data: JSONValue?

    public init(source: String, data: JSONValue? = nil) {
        self.source = source
        self.data = data
    }
}
