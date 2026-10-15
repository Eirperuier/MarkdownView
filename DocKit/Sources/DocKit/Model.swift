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
    /// `0...maxIndent`, on any kind of block, whatever the blocks around it are (a
    /// block may sit three levels under the one before it). A list item's is its
    /// level in the list; the blocks after a block that sit deeper are nested in it.
    public var indent: Int
    /// Empty on the kinds that carry no text.
    public var text: DocText
    /// Drawn around the block, whatever its kind; neighbours with the same one share it.
    public var decoration: BlockDecoration?
    /// Its text's typeface (a table's, its cells' unless they have their own).
    public var font: Typeface?

    /// The deepest a block indents (Craft's five levels).
    public static let maxIndent = 5

    public init(id: DocBlockID, kind: BlockKind, indent: Int = 0, text: DocText = DocText(), decoration: BlockDecoration? = nil,
                font: Typeface? = nil) {
        self.id = id
        self.kind = kind
        self.indent = indent
        self.text = text
        self.decoration = decoration
        self.font = font
    }
}

/// A block's or a table cell's typeface (Craft's four); none set, the document's (a
/// cell's: its table block's).
public enum Typeface: String, Hashable, Sendable, Codable, CaseIterable {
    case system, mono, serif, rounded
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
    /// A collection (Craft's): a database with a name, shown through views the reader
    /// switches between (a table, a kanban), the same records in each.
    case collection(collection: DocCollection)
    /// A page of its own (Craft's): another document, opened from here. The block keeps
    /// its title as the page last had it.
    case page(page: DocPage)

    /// The kinds whose `text` holds content; the rest must be empty.
    public var carriesText: Bool {
        switch self {
        case .paragraph, .heading, .listItem, .quote, .caption, .code, .math: true
        case .divider, .image, .link, .file, .card, .view, .database, .collection, .page: false
        }
    }

    /// Code and math text never carries marks.
    public var allowsMarks: Bool {
        switch self {
        case .paragraph, .heading, .listItem, .quote, .caption: true
        case .code, .math, .divider, .image, .link, .file, .card, .view, .database, .collection, .page: false
        }
    }

    /// The database a `.database` or `.collection` block displays; nil on other kinds.
    public var databaseID: DatabaseID? {
        switch self {
        case .database(let id, _): id
        case .collection(let collection): collection.database
        default: nil
        }
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

    public enum Fit: String, Hashable, Sendable, Codable, CaseIterable { case fit, fill }
    public enum Size: String, Hashable, Sendable, Codable, CaseIterable { case auto, large }

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
    /// The sizes a card is drawn at.
    public static let sizes = ["glance", "summary", "detail", "collection"]

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

/// A collection block: its database, its name, and the views of it, one of them showing.
public struct DocCollection: Hashable, Sendable, Codable {
    public var database: DatabaseID
    public var name: String
    public var views: [CollectionView]
    public var current: CollectionViewID

    public init(database: DatabaseID, name: String = "", views: [CollectionView], current: CollectionViewID? = nil) {
        self.database = database
        self.name = name
        self.views = views
        self.current = current ?? views.first?.id ?? CollectionViewID.generate()
    }

    /// The view showing: the current one, or the first if that's gone.
    public var currentView: CollectionView? {
        views.first { $0.id == current } ?? views.first
    }
}

/// A page block's page: the document it opens, its title (the page's first heading) and
/// a preview of what's under it, both as they were when the page was last left.
public struct DocPage: Hashable, Sendable, Codable {
    public var doc: DocID
    public var title: String
    /// The words of the page's first blocks after its title, one after another (Craft's
    /// page block shows them under the title).
    public var preview: String

    public init(doc: DocID, title: String = "", preview: String = "") {
        self.doc = doc
        self.title = title
        self.preview = preview
    }

    /// What a page block keeps of `page`: its first heading, and the words of the first
    /// few blocks with words after it.
    public static func summary(of page: Doc) -> (title: String, preview: String) {
        let heading = page.blocks.firstIndex { if case .heading = $0.kind { true } else { false } }
        let title = heading.map { page.blocks[$0].text.string } ?? ""
        let rest = page.blocks.indices.filter { $0 != heading }.lazy
            .map { page.blocks[$0].text.string.split(separator: "\n").first.map(String.init) ?? "" }
            .filter { !$0.isEmpty }
        return (title, rest.prefix(4).joined(separator: " · "))
    }

    private enum CodingKeys: String, CodingKey { case doc, title, preview }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        doc = try container.decode(DocID.self, forKey: .doc)
        title = try container.decode(String.self, forKey: .title)
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
    }
}

/// One view of a collection: a table or a kanban of its records, named in its tab.
public struct CollectionView: Hashable, Sendable, Codable, Identifiable {
    public var id: CollectionViewID
    public var name: String
    public var layout: DatabaseView
    /// A table's calculation row, and what each column's cell in it computes.
    public var showsCalculations: Bool
    public var calculations: [ColumnID: CollectionCalculation]
    /// The records it shows: those every filter lets through.
    public var filters: [CollectionFilter]
    /// The order of its fields; columns it doesn't name follow in the database's order.
    public var order: [ColumnID]

    public init(id: CollectionViewID = .generate(), name: String, layout: DatabaseView,
                showsCalculations: Bool = true, calculations: [ColumnID: CollectionCalculation] = [:],
                filters: [CollectionFilter] = [], order: [ColumnID] = []) {
        self.id = id
        self.name = name
        self.layout = layout
        self.showsCalculations = showsCalculations
        self.calculations = calculations
        self.filters = filters
        self.order = order
    }

    /// The database's columns in the view's order.
    public func ordered(_ columns: [Column]) -> [Column] {
        let named = order.compactMap { id in columns.first { $0.id == id } }
        return named + columns.filter { !order.contains($0.id) }
    }

    private enum CodingKeys: String, CodingKey { case id, name, layout, showsCalculations, calculations, filters, order }

    // What a later version added reads as its default from a document written before it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CollectionViewID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        layout = try container.decode(DatabaseView.self, forKey: .layout)
        showsCalculations = try container.decodeIfPresent(Bool.self, forKey: .showsCalculations) ?? true
        calculations = try container.decodeIfPresent([ColumnID: CollectionCalculation].self, forKey: .calculations) ?? [:]
        filters = try container.decodeIfPresent([CollectionFilter].self, forKey: .filters) ?? []
        order = try container.decodeIfPresent([ColumnID].self, forKey: .order) ?? []
    }
}

/// What a column's cell in a table's calculation row computes (Craft's).
public enum CollectionCalculation: String, Hashable, Sendable, Codable, CaseIterable {
    case count, countEmpty, countFilled, sum, average, median, min, max, range
}
