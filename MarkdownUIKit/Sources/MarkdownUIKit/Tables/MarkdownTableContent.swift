//
//  MarkdownTableContent.swift
//  MarkdownUIKit
//
//  A table's cells as text, from its source. Nothing is drawn or measured at a width here. The
//  same table grown parses and builds only what's new: its last row on. A cell that's plain words
//  skips the text visitor, as it's most of what's in a table.
//

import CoreText
import Markdown
@_spi(MarkdownMath) import MarkdownCore
import RichTextCore
import UIKit

final class MarkdownTableCell {
    enum Alignment { case leading, center, trailing }

    let position: MarkdownTableCellPosition
    /// Where it is in the text a reveal counts.
    let span: MarkdownTableRevealSpan
    let alignment: Alignment
    /// Columns it covers.
    let columnSpan: Int
    let isHeader: Bool
    /// As a text view shows it.
    let string: NSAttributedString
    /// As it's drawn: the same with nothing that would look like a link by itself.
    let drawing: NSAttributedString
    /// Holds what only a text view shows: an image, a mark.
    let needsTextView: Bool
    /// Holds views at a fixed size in its lines (a formula, a site's icon): drawn text shows it,
    /// placing them; string drawing can't.
    let drawsInlineViews: Bool
    /// It shows in a view of its own: a text view, or drawn text placing views.
    var needsHost: Bool { needsTextView || drawsInlineViews }

    /// Its text laid out by TextKit, for a cell drawing views: measured on any thread, shown as
    /// it was measured.
    private(set) lazy var inlineStack: MarkdownTextStack = {
        let stack = MarkdownTextStack()
        stack.narrowsToText = true
        stack.show(string, foregroundColor: style.resolvedTextColor)
        return stack
    }()
    let hasLink: Bool
    let tag: UIColor?
    let fill: UIColor?
    let style: MarkdownStyle
    private let map: [Int]?

    /// Its size with nothing wrapping, once.
    var natural: CGSize?
    /// Its size at the last width it wrapped at.
    var wrapped: (width: CGFloat, size: CGSize)?
    /// Underlines it draws itself, at the last width asked: a string's own are a pixel lower and
    /// reach whole points past the words.
    private(set) var hasUnderlines = false
    private var underlines: (width: CGFloat, bars: [MarkdownTableUnderline])?

    /// Where a text a hair too wide for its box goes: over the far edge, on its line.
    /// Centred, it sits in its box rounded up to a pixel. Nil when it fits, or really doesn't.
    func hairOverFit(width: CGFloat, scale: CGFloat) -> (offset: CGFloat, width: CGFloat)? {
        guard let natural = natural?.width, natural > width, natural < width + 0.1 else { return nil }
        let pixels = max(scale, 1)
        switch alignment {
        case .leading: return (0, natural)
        case .center: return (((natural * pixels).rounded(.up) / pixels - natural) / 2, natural)
        case .trailing: return (width - natural, natural)
        }
    }

    init(position: MarkdownTableCellPosition, span: MarkdownTableRevealSpan, alignment: Alignment, columnSpan: Int, isHeader: Bool, string: NSAttributedString, map: [Int]?, tag: UIColor?, fill: UIColor?, style: MarkdownStyle) {
        self.position = position
        self.span = span
        self.alignment = alignment
        self.columnSpan = columnSpan
        self.isHeader = isHeader
        self.string = string
        self.map = map
        self.tag = tag
        self.fill = fill
        self.style = style
        needsTextView = !MarkdownTextHost.isDrawable(string, allowingInlineViews: true)
        drawsInlineViews = !needsTextView && !MarkdownTextHost.isDrawable(string)
        let range = NSRange(location: 0, length: string.length)
        var linked = false
        string.enumerateAttribute(.link, in: range) { value, _, stop in
            if value != nil {
                linked = true
                stop.pointee = true
            }
        }
        hasLink = linked
        if needsTextView || drawsInlineViews {
            drawing = string
        } else {
            let copy = NSMutableAttributedString(attributedString: string)
            if linked { copy.removeAttribute(.link, range: range) }
            MarkdownTextStack.applyIntentsAsTextViewDoes(copy, in: range)
            var underlined = false
            copy.enumerateAttribute(.underlineStyle, in: range) { value, _, stop in
                if value != nil {
                    underlined = true
                    stop.pointee = true
                }
            }
            if underlined { copy.removeAttribute(.underlineStyle, range: range) }
            hasUnderlines = underlined
            drawing = copy
        }
    }

    /// The bars under its underlined runs, from its text's origin, at `width`.
    func underlineBars(width: CGFloat) -> [MarkdownTableUnderline] {
        if let underlines, underlines.width == width { return underlines.bars }
        let bars = MarkdownTableUnderline.bars(in: string, width: width)
        underlines = (width, bars)
        return bars
    }

    /// What a text view's host takes.
    var text: MarkdownText { text(of: string) }

    /// The same for a text view over the table's own underlines, which stay as they're drawn.
    var textWithoutUnderlines: MarkdownText {
        guard hasUnderlines else { return text }
        let copy = NSMutableAttributedString(attributedString: string)
        copy.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: copy.length))
        return text(of: copy)
    }

    private func text(of attributed: NSAttributedString) -> MarkdownText {
        MarkdownText(
            attributed: attributed,
            revealTotal: span.end,
            storageToPlain: map ?? Array(span.offset..<(span.offset + string.string.count)),
            topEdgeInset: 0,
            bottomEdgeInset: 0
        )
    }
}

/// A table's cells, kept up to date with its source.
final class MarkdownTableContent {
    /// Made off the main thread: whether a cell had what only that thread can make.
    let gate = MarkdownBuildGate()
    private(set) var rows: [[MarkdownTableCell]] = []
    private(set) var flat: [MarkdownTableCell] = []
    private(set) var columnCount = 0
    /// The first row whose cells changed in the last update; nil if none did.
    private(set) var firstChangedRow: Int?

    private(set) var source = ""
    private var key: MarkdownTableOptions.TextKey?
    private var headLines = ""
    private var category: UIContentSizeCategory?
    private var looks: [LookKey: MarkdownStyle] = [:]
    private var plainAttributes: [LookKey: [NSAttributedString.Key: Any]] = [:]

    private(set) var spans: [MarkdownTableRevealSpan] = []

    /// The same cells in a content of its own: the cells don't change, a content does as its
    /// source grows.
    func copy() -> MarkdownTableContent {
        let copy = MarkdownTableContent()
        copy.rows = rows
        copy.flat = flat
        copy.columnCount = columnCount
        copy.firstChangedRow = firstChangedRow
        copy.source = source
        copy.key = key
        copy.headLines = headLines
        copy.category = category
        copy.looks = looks
        copy.plainAttributes = plainAttributes
        copy.spans = spans
        return copy
    }

    /// Shows `source`. False if it isn't a table.
    func update(source new: String, style: MarkdownStyle, inlineMath: [String: String]?, displayMath: [UUID: String]?) -> Bool {
        let newKey = style.table.textKey
        let sameLook = key == newKey && category == style.contentSizeCategory
        if !sameLook {
            looks.removeAll()
            plainAttributes.removeAll()
        }
        if sameLook, new == source {
            firstChangedRow = nil
            return true
        }
        let built: Bool
        if sameLook, let grown = grownRows(to: new) {
            built = apply(parsing: grown.text, keeping: grown.keep, style: style, inlineMath: inlineMath, displayMath: displayMath)
                || apply(parsing: new, keeping: 0, style: style, inlineMath: inlineMath, displayMath: displayMath)
        } else {
            built = apply(parsing: new, keeping: 0, style: style, inlineMath: inlineMath, displayMath: displayMath)
        }
        guard built else { return false }
        source = new
        key = newKey
        category = style.contentSizeCategory
        return true
    }

    /// What's new when `new` only adds to what's there: the head again, and the last row on.
    private func grownRows(to new: String) -> (text: String, keep: Int)? {
        guard !source.isEmpty, new.hasPrefix(source), rows.count >= 2, !headLines.isEmpty else { return nil }
        let oldLines = source.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        guard oldLines == rows.count + 1, let lastLine = source.lastIndex(of: "\n") else { return nil }
        let start = new.index(after: new.index(new.startIndex, offsetBy: source.distance(from: source.startIndex, to: lastLine)))
        return (headLines + "\n" + new[start...], rows.count - 1)
    }

    private func apply(parsing text: String, keeping keep: Int, style: MarkdownStyle, inlineMath: [String: String]?, displayMath: [UUID: String]?) -> Bool {
        var inlineStorage = inlineMath ?? [:]
        var displayStorage = displayMath ?? [:]
        let processed = MarkdownMathPreprocessor.preprocess(
            text,
            appendDisplayMath: { math in
                let id = MarkdownMathPreprocessor.displayID(for: math)
                displayStorage[id] = String(math)
                return id
            },
            appendInlineMath: { math in
                let id = MarkdownMathPreprocessor.inlineID(for: math)
                inlineStorage[id] = String(math)
                return id
            }
        )
        var prepared = processed
        var tokens: [Int: MarkdownFootnoteSyntax.InlineToken] = [:]
        if let footnotes = style.footnotes, !footnotes.inlineNotes.isEmpty {
            let notes = MarkdownFootnoteSyntax.preprocessInlineNotes(processed)
            prepared = notes.text
            tokens = notes.tokens
        }
        let content = MarkdownContent(prepared)
        let document = content.parse(options: content.parseOptions(allowingBlockDirectives: false))
        guard let table = document.child(at: 0) as? Markdown.Table else { return false }

        let columns = table.head.childCount
        var parsedRows: [(cells: [Markdown.Table.Cell], row: Int)] = []
        if keep == 0 {
            parsedRows.append((Array(table.head.cells), 0))
        }
        for (index, row) in table.body.rows.enumerated() {
            parsedRows.append((Array(row.cells), keep == 0 ? index + 1 : keep + index))
        }
        // A grown table has its last row, at least. If it hasn't, the source wasn't what it seemed.
        if keep > 0, parsedRows.first?.row != keep { return false }

        let previous = rows
        var kept = Array(rows.prefix(keep))
        var cursor = kept.last?.last?.span.end ?? 0
        firstChangedRow = nil
        for (cells, row) in parsedRows {
            var built: [MarkdownTableCell] = []
            built.reserveCapacity(cells.count)
            for (column, cell) in cells.enumerated() {
                let made = makeCell(cell, table: table, position: MarkdownTableCellPosition(row: row, column: column), offset: cursor, style: style, inlineMath: inlineStorage, displayMath: displayStorage, tokens: tokens)
                cursor = made.span.end
                // The same as it was keeps what's measured.
                if row < previous.count, column < previous[row].count, previous[row][column].span == made.span, previous[row][column].string.isEqual(to: made.string) {
                    built.append(previous[row][column])
                } else {
                    built.append(made)
                    if firstChangedRow == nil { firstChangedRow = row }
                }
            }
            kept.append(built)
        }
        if previous.count != kept.count, firstChangedRow == nil { firstChangedRow = min(previous.count, kept.count) }
        rows = kept
        flat = kept.flatMap { $0 }
        spans = flat.map(\.span)
        columnCount = columns
        if keep == 0 {
            let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            headLines = lines.count >= 2 ? lines[0] + "\n" + lines[1] : ""
        }
        return true
    }

    // MARK: A cell

    private struct LookKey: Hashable {
        var isHeader: Bool
        var isHeaderColumn: Bool
        var design: UIFontDescriptor.SystemDesign?
        var alignment: NSTextAlignment
    }

    private func makeCell(_ cell: Markdown.Table.Cell, table: Markdown.Table, position: MarkdownTableCellPosition, offset: Int, style: MarkdownStyle, inlineMath: [String: String], displayMath: [UUID: String], tokens: [Int: MarkdownFootnoteSyntax.InlineToken]) -> MarkdownTableCell {
        let options = style.table
        let scrolls = options.scrollsSideways
        let appearance = scrolls ? options.appearance : MarkdownTableOptions.Appearance()
        let look = appearance.cells[position]
        let isHeader = position.row == 0 && appearance.headerRow
        let isHeaderColumn = position.row > 0 && position.column == 0 && appearance.headerColumn
        let written = position.column < table.columnAlignments.count ? table.columnAlignments[position.column] : nil
        var alignment: MarkdownTableCell.Alignment
        switch written {
        case .center?: alignment = .center
        case .right?: alignment = .trailing
        default: alignment = .leading
        }
        var paragraph: NSTextAlignment = alignment == .center ? .center : alignment == .trailing ? .right : .left
        switch look?.alignment {
        case .leading?:
            alignment = .leading
            paragraph = .left
        case .center?:
            alignment = .center
            paragraph = .center
        case .trailing?:
            alignment = .trailing
            paragraph = .right
        case .justified?:
            alignment = .leading
            paragraph = .justified
        case nil: break
        }
        let key = LookKey(isHeader: isHeader, isHeaderColumn: isHeaderColumn, design: look?.fontDesign ?? appearance.fontDesign, alignment: paragraph)
        let cellStyle = lookStyle(key, style: style)
        let count = cell.markdownRevealPlainText.count
        let span = MarkdownTableRevealSpan(offset: offset, count: count)
        let upper = isHeader && scrolls
        let isTagged = position.row > 0 && !isHeader && look?.tag != nil

        var string: NSAttributedString
        var map: [Int]?
        if !isTagged, let plain = Self.plainWords(of: cell, style: style) {
            let attributes = attributesForPlain(key, style: cellStyle)
            string = NSAttributedString(string: upper ? plain.uppercased() : plain, attributes: attributes)
        } else {
            var tagged = cellStyle
            if isTagged, let tag = look?.tag {
                tagged.defaultFont = .systemFont(ofSize: 13, weight: .medium)
                tagged.typography.body = MarkdownTypography.Style(.body, weight: .medium)
                tagged.textColor = MarkdownTableInk.tagText(tag)
            }
            let text = MarkdownTextBuilder.build(
                document: Document(Paragraph(cell.inlineChildren)),
                style: tagged,
                listDepthOffset: 0,
                plainOffsetBase: offset,
                inlineMath: inlineMath,
                displayMath: displayMath,
                inlineFootnoteTokens: tokens,
                gate: gate
            )
            map = text.storageToPlain
            let result = NSMutableAttributedString(attributedString: text.attributed)
            let full = NSRange(location: 0, length: result.length)
            result.addAttribute(.paragraphStyle, value: Self.paragraphStyle(paragraph, style: style), range: full)
            if upper { Self.uppercase(result) }
            string = result
        }
        if isHeader, options.dimsHeaderParentheticals {
            string = Self.dimmingParentheticals(string, style: style)
        }
        return MarkdownTableCell(
            position: position,
            span: span,
            alignment: alignment,
            columnSpan: max(1, Int(cell.colspan)),
            isHeader: isHeader,
            string: string,
            map: map,
            tag: isTagged ? look?.tag : nil,
            fill: look?.fill,
            style: cellStyle
        )
    }

    private func lookStyle(_ key: LookKey, style: MarkdownStyle) -> MarkdownStyle {
        if let known = looks[key] { return known }
        var font = key.isHeader ? style.table.headerFont : style.table.bodyFont
        font.keepsTextStyleLeading = false
        font.design = key.design ?? font.design
        if key.isHeaderColumn { font.weight = .bold }
        var cell = style
        cell.typography.body = font
        cell.typography.paragraphAlignment = key.alignment
        // Bold in a cell is the font's bold trait, as in the rest of the cell's run of text.
        cell.typography.strongWeight = .semibold
        cell.defaultFont = font.font(at: style.contentSizeCategory)
        cell.drawsTextUntilTouched = false
        cell.addsEdgeInsets = false
        cell.rangeDecorations = []
        cell.inlineAnchors = []
        cell.lineSpacing = 0
        // The base text colour stops at the table: cells have their own roles.
        cell.textColor = .floo(key.isHeader ? .markdownTableHeaderText : .markdownTableText)
        if let renderer = style.table.imageRenderer {
            cell.inlineImage = { image, _ in
                guard let url = image.source.flatMap({ URL(string: $0) }) else { return nil }
                let view = renderer(MarkdownImageRequest(url: url, alternativeText: MarkdownImageSource.alternativeText(of: image)))
                return MarkdownCustomViewAttachment(id: UUID(), view: view, source: image.format())
            }
        }
        looks[key] = cell
        return cell
    }

    private func attributesForPlain(_ key: LookKey, style: MarkdownStyle) -> [NSAttributedString.Key: Any] {
        if let known = plainAttributes[key] { return known }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.resolvedDefaultFont,
            .foregroundColor: style.resolvedTextColor,
            .paragraphStyle: Self.paragraphStyle(key.alignment, style: style),
        ]
        plainAttributes[key] = attributes
        return attributes
    }

    private static func paragraphStyle(_ alignment: NSTextAlignment, style: MarkdownStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let isRTL = style.layoutDirection == .rightToLeft
        paragraph.alignment = !isRTL ? alignment : alignment == .left ? .right : alignment == .right ? .left : alignment
        paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
        paragraph.lineBreakMode = .byWordWrapping
        // A SwiftUI Text's lines on a phone: one line is the font's own box, and from line to line
        // the text style's leading comes in between (17 pt body text on 22 pt lines). On a Mac
        // its lines have none (measured against the catalogue).
        #if !targetEnvironment(macCatalyst)
        let traits = style.contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) }
        paragraph.lineSpacing = max(0, UIFont.preferredFont(forTextStyle: style.typography.body.textStyle, compatibleWith: traits).leading)
        #endif
        return paragraph
    }

    /// The cell's words if it's one piece of text with nothing in it to read: a number, a name.
    /// Anything that might be a link, a formula or a mark goes the long way.
    private static func plainWords(of cell: Markdown.Table.Cell, style: MarkdownStyle) -> String? {
        guard cell.childCount == 1, let text = cell.child(at: 0) as? Markdown.Text else { return cell.childCount == 0 ? "" : nil }
        let plain = text.string
        for scalar in plain.unicodeScalars {
            switch scalar {
            case "$", "\\", ":", "=", "@", "[", "]", "^", "{", "}", "<", "~", "/", "|", "：", "\u{FFFC}": return nil
            default: continue
            }
        }
        // Dots in a word may make it an address. In a number they don't.
        if style.autolinks, plain.contains(".") {
            let dotted = plain.split(separator: " ").contains { word in
                word.contains(".") && word.contains(where: \.isLetter)
            }
            if dotted { return nil }
        }
        if plain.contains(MarkdownInlineMathPlaceholder.prefix) { return nil }
        return plain
    }

    private static func uppercase(_ text: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: text.length)
        var runs: [NSRange] = []
        text.enumerateAttribute(.attachment, in: full) { value, range, _ in
            if value == nil { runs.append(range) }
        }
        for run in runs.reversed() {
            let piece = text.attributedSubstring(from: run)
            var replaced = NSMutableAttributedString()
            piece.enumerateAttributes(in: NSRange(location: 0, length: piece.length)) { attributes, range, _ in
                replaced.append(NSAttributedString(string: (piece.string as NSString).substring(with: range).uppercased(), attributes: attributes))
            }
            if replaced.length == 0 { replaced = NSMutableAttributedString(attributedString: piece) }
            text.replaceCharacters(in: run, with: replaced)
        }
    }

    private static func dimmingParentheticals(_ string: NSAttributedString, style: MarkdownStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: string)
        let plain = string.string
        let font = MarkdownTypography.Style(.caption1).font(at: style.contentSizeCategory)
        for range in MarkdownTableParentheticals.ranges(in: plain) {
            result.addAttributes([.font: font, .foregroundColor: UIColor.floo(.markdownTableHeaderDimmed)], range: NSRange(range, in: plain))
        }
        return result
    }
}

/// An underline as a layout of text draws it: by its font's metrics, as long as the words' advance.
struct MarkdownTableUnderline {
    let rect: CGRect
    let color: UIColor

    /// Text kit's own layout, for the rare cell with an underline.
    static func bars(in text: NSAttributedString, width: CGFloat) -> [MarkdownTableUnderline] {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width + 1, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var bars: [MarkdownTableUnderline] = []
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: full) { attributes, run, _ in
            guard attributes[.underlineStyle] != nil, let font = attributes[.font] as? UIFont else { return }
            let color = attributes[.underlineColor] as? UIColor ?? attributes[.foregroundColor] as? UIColor ?? .floo(.markdownTableText)
            let glyphs = manager.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let fragment = manager.lineFragmentRect(forGlyphAt: manager.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: container), effectiveRange: nil)
                // The font's own baseline, and a point short of the words' advance, as Text's is.
                let baseline = fragment.minY + font.ascender
                let thickness = max(CTFontGetUnderlineThickness(font as CTFont), 1 / markdownPixelScale)
                let top = markdownPixelFloor(baseline - CTFontGetUnderlinePosition(font as CTFont) - thickness / 2)
                bars.append(MarkdownTableUnderline(rect: CGRect(x: rect.minX, y: top, width: max(0, rect.width - 1), height: markdownPixelCeil(thickness)), color: color))
            }
        }
        return bars
    }
}

enum MarkdownTableInk {
    /// A tag's words: its colour softened a fifth toward the text's, mixed by how it looks.
    static func tagText(_ color: UIColor) -> UIColor {
        let text = UIColor.floo(.markdownTableText)
        return UIColor { traits in
            mix(color.resolvedColor(with: traits), text.resolvedColor(with: traits), by: 0.2)
        }
    }

    /// In Oklab, as a perceptual mix is.
    private static func mix(_ from: UIColor, _ to: UIColor, by amount: CGFloat) -> UIColor {
        let a = oklab(from), b = oklab(to)
        let alpha = a.alpha + (b.alpha - a.alpha) * amount
        // Mixed as premultiplied, as a colour's alpha would be.
        func channel(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            guard alpha > 0 else { return 0 }
            return (x * a.alpha * (1 - amount) + y * b.alpha * amount) / alpha
        }
        return rgb(l: channel(a.l, b.l), a: channel(a.a, b.a), b: channel(a.b, b.b), alpha: alpha)
    }

    private static func oklab(_ color: UIColor) -> (l: CGFloat, a: CGFloat, b: CGFloat, alpha: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        func linear(_ x: CGFloat) -> CGFloat { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let lc = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let mc = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let sc = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc,
                1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc,
                0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc,
                alpha)
    }

    private static func rgb(l: CGFloat, a: CGFloat, b: CGFloat, alpha: CGFloat) -> UIColor {
        let lc = l + 0.3963377774 * a + 0.2158037573 * b
        let mc = l - 0.1055613458 * a - 0.0638541728 * b
        let sc = l - 0.0894841775 * a - 1.2914855480 * b
        let lr = 4.0767416621 * lc * lc * lc - 3.3077115913 * mc * mc * mc + 0.2309699292 * sc * sc * sc
        let lg = -1.2684380046 * lc * lc * lc + 2.6097574011 * mc * mc * mc - 0.3413193965 * sc * sc * sc
        let lb = -0.0041960863 * lc * lc * lc - 0.7034186147 * mc * mc * mc + 1.7076147010 * sc * sc * sc
        func gamma(_ x: CGFloat) -> CGFloat {
            let clamped = min(max(x, 0), 1)
            return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return UIColor(red: gamma(lr), green: gamma(lg), blue: gamma(lb), alpha: alpha)
    }
}
