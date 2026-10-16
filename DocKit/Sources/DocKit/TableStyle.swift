public import Foundation

/// How a table looks as a whole (Craft's Table Style): whether its first row and first
/// column are headers, and the colour every other body row takes.
public struct TableStyle: Hashable, Sendable, Codable {
    /// The column names' row reads as a header (the default); off, as a row like the rest.
    public var headerRow: Bool?
    /// The first column reads as a header too (off by default).
    public var headerColumn: Bool?
    /// Every other body row's fill (`CellStyle.fill`'s tokens), or `noStripe`; nil, the
    /// table's own light stripe.
    public var stripe: String?

    /// The stripe that is none: every row the same.
    public static let noStripe = "none"

    public init(headerRow: Bool? = nil, headerColumn: Bool? = nil, stripe: String? = nil) {
        self.headerRow = headerRow
        self.headerColumn = headerColumn
        self.stripe = stripe
    }

    public var hasHeaderRow: Bool { headerRow ?? true }
    public var hasHeaderColumn: Bool { headerColumn ?? false }
    /// No setting differs from the defaults: stored as none.
    public var isPlain: Bool { hasHeaderRow && !hasHeaderColumn && stripe == nil }

    /// Whether its stripe is one a table takes.
    public var hasValidStripe: Bool {
        stripe.map { $0 == Self.noStripe || CellStyle.parseFill($0) != nil } ?? true
    }
}

/// How one cell looks (Craft's cell style): where its text sits, its typeface, how a
/// number in it reads, and its fill. Nil fields are the table's own; a style with none
/// set is stored as none.
public struct CellStyle: Hashable, Sendable, Codable {
    public var alignment: CellAlignment?
    public var font: Typeface?
    public var number: CellNumberFormat?
    /// A palette colour at one of three strengths (`CellStyle.fills`), or `#rrggbb`.
    public var fill: String?

    public init(alignment: CellAlignment? = nil, font: Typeface? = nil, number: CellNumberFormat? = nil, fill: String? = nil) {
        self.alignment = alignment
        self.font = font
        self.number = number
        self.fill = fill
    }

    public var isPlain: Bool { alignment == nil && font == nil && number == nil && fill == nil }

    /// The fills a cell takes: each palette colour, light (its name), then `-2` and `-3`
    /// stronger (Craft's three rows of each hue).
    public static let fillColors = ["gray", "slate", "purple", "blue", "cyan", "mint", "green", "lemon", "yellow", "red", "orange", "brown"]
    public static let fillStrengths = 1...3

    public static func fill(_ color: String, strength: Int) -> String {
        strength <= 1 ? color : "\(color)-\(strength)"
    }

    /// A fill's colour and strength; nil for a token that isn't one (a `#rrggbb` is
    /// its own colour, at full strength).
    public static func parseFill(_ token: String) -> (color: String, strength: Int)? {
        if token.hasPrefix("#") {
            let digits = token.dropFirst()
            return digits.count == 6 && digits.allSatisfy(\.isHexDigit) ? (token, 0) : nil
        }
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard let color = parts.first.map(String.init), fillColors.contains(color), parts.count <= 2 else { return nil }
        guard parts.count == 2 else { return (color, 1) }
        guard let strength = Int(parts[1]), fillStrengths.contains(strength), strength > 1 else { return nil }
        return (color, strength)
    }

    /// Whether every value it sets is one a cell takes.
    public var isValid: Bool {
        if let fill, Self.parseFill(fill) == nil { return false }
        if case .currency(let code)? = number, !CellNumberFormat.isCurrencyCode(code) { return false }
        return true
    }
}

public enum CellAlignment: String, Hashable, Sendable, Codable, CaseIterable {
    case left, center, right, justify
}


/// How a number in a cell reads (Craft's cell format); none set, as typed. A text cell
/// whose text is a number reads the same way; its text stays as typed.
public enum CellNumberFormat: Hashable, Sendable, Codable {
    /// Grouped, up to two decimals: 1,234.5.
    case number
    /// A fraction as a percentage: 0.19 reads 19%.
    case percent
    /// An amount in a currency (ISO 4217): 12 in CNY reads ¥12.00.
    case currency(code: String)

    static func isCurrencyCode(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    /// The number as this format reads it, in `locale`'s way of writing numbers.
    public func text(_ value: Double, locale: Locale = Locale(identifier: "en_US")) -> String {
        switch self {
        case .number: value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        case .percent: value.formatted(.percent.precision(.fractionLength(0...2)).locale(locale))
        case .currency(let code): value.formatted(.currency(code: code).locale(locale))
        }
    }
}

extension Database {
    /// Its table style, the defaults where it has none.
    public var tableStyle: TableStyle { style ?? TableStyle() }

    /// A cell's style: a body cell's (`row`), else its column's header cell's.
    public func cellStyle(row: RowID?, column: ColumnID) -> CellStyle {
        guard let owner = columns.first(where: { $0.id == column }) else { return CellStyle() }
        return owner.style(row: row)
    }
}

extension Column {
    /// A cell's style in this column: a body cell's (`row`), else the header cell's.
    public func style(row: RowID?) -> CellStyle {
        guard let row else { return headerStyle ?? CellStyle() }
        return cellStyles?[row] ?? CellStyle()
    }

    /// Sets a cell's style; a plain one is stored as none.
    mutating func setStyle(_ style: CellStyle?, row: RowID?) {
        let stored = style.flatMap { $0.isPlain ? nil : $0 }
        guard let row else { return headerStyle = stored }
        var styles = cellStyles ?? [:]
        styles[row] = stored
        cellStyles = styles.isEmpty ? nil : styles
    }
}
