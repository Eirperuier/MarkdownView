//
//  CatalogFixture.swift
//  DemoApp
//
//  One style MarkdownView can draw: its markdown, how it's drawn and the settings on it.
//  A fixture is data, not a view, so another renderer can draw the same list and be
//  compared pixel by pixel: a new renderer switches over `CatalogKnob` and misses none.
//

import MarkdownView
import SwiftUI

struct CatalogFixture: Identifiable {
    /// How a fixture reaches the screen.
    enum Path {
        /// As chat: the block splitter, then a `MarkdownStreamBlockView` per block. This is
        /// what the rest is compared against.
        case stream
        /// `MarkdownSelectableText` on the whole text, as a Doc text block is.
        case selectableText
        /// `MarkdownView`: styles only it draws (GitHub quotes, font groups).
        case document
    }

    let id: String
    let title: String
    let markdown: String
    var path: Path = .stream
    var knobs: [CatalogKnob] = []
    /// Settles only when the catalogue's image server answers, or never (a loading state).
    var waitsForImages = false

    init(
        _ id: String,
        _ title: String,
        path: Path = .stream,
        knobs: [CatalogKnob] = [],
        waitsForImages: Bool = false,
        _ markdown: String
    ) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.path = path
        self.knobs = knobs
        self.waitsForImages = waitsForImages
    }
}

struct CatalogGroup: Identifiable {
    let id: String
    let title: String
    let fixtures: [CatalogFixture]
}

/// Every public setting that changes how Markdown looks.
enum CatalogKnob {
    // Type
    case fontGroup
    case fontBody, fontHeading, fontCode, fontQuote, fontTable, fontMath
    case typographyDoc, typographyInlineCode, typographyLeadingOff, typographySerif, typographyStrong, typographyCentered
    case headingStyleGroup, headingStyleOne
    case headingPadding
    case dynamicType(DynamicTypeSize)
    // Colour
    case tintLink, tintQuote, tintInlineCode
    case preferredColor
    case baseTextColor
    case colors
    case search
    // Layout
    case listIndent, componentSpacing, noEdgeInsets, lineSpacing
    case dashMarker, letterMarker
    case rtl
    // Blocks
    case quoteGithub, quoteDecoration
    case codeScrollable, codeFull, codeRenderer, codeRendererBare, codeRendererDisabled, codeHighlighter, codeFloo
    case tableGithub, tableGrid
    case tableScrollable, tableHeaderColumn, tableNoHeaderRow, tableNoStripe, tableStripeColor, tableSerif, tableCellLooks
    case tableDimsParentheticals, tableCellsSelectable
    case tableCellPadding, tableCellOverlay, tableRowBackground, tableImage, tableCellReplacement, tableDecoration
    case imageRenderer, baseURL
    case directive
    case editorStyle
    // Text features
    case autolinkOff, siteIcons
    case footnotes
    case rangeDecoration, inlineAnchor
}

extension View {
    @ViewBuilder
    func catalogKnob(_ knob: CatalogKnob) -> some View {
        switch knob {
        case .fontGroup: fontGroup(CatalogFonts())
        case .fontBody: font(.system(.title3, design: .rounded), for: .body)
        case .fontHeading: font(.system(.largeTitle, design: .serif).bold(), for: .h1)
        case .fontCode: font(.system(.body, design: .monospaced), for: .codeBlock)
        case .fontQuote: font(.system(.body, design: .rounded), for: .blockQuote)
        case .fontTable:
            font(.system(.callout, design: .rounded).bold(), for: .tableHeader)
                .font(.system(.footnote, design: .monospaced), for: .tableBody)
        case .fontMath: font(.title2, for: .displayMath).font(.title3, for: .inlineMath)
        case .typographyDoc: markdownPlatformTypography(CatalogTypography.doc)
        case .typographyInlineCode: markdownPlatformTypography(CatalogTypography.inlineCode)
        case .typographyLeadingOff: markdownPlatformTypography(CatalogTypography.leadingOff)
        case .typographySerif: markdownPlatformTypography(CatalogTypography.serif)
        case .typographyStrong: markdownPlatformTypography(CatalogTypography.strong)
        case .typographyCentered: markdownPlatformTypography(CatalogTypography.centered)
        case .headingStyleGroup: headingStyleGroup(CatalogHeadingColors())
        case .headingStyleOne: headingStyle(Color.orange, for: .h2)
        case .headingPadding:
            padding(.top, 40, for: .h1)
                .padding(EdgeInsets(top: 4, leading: 0, bottom: 20, trailing: 0), for: .h2)
        case .dynamicType(let size): dynamicTypeSize(size)
        case .tintLink: tint(.green, for: .link)
        case .tintQuote: tint(.orange, for: .blockQuote)
        case .tintInlineCode: tint(.pink, for: .inlineCodeBlock)
        case .preferredColor: preferredColor(.purple)
        case .baseTextColor: markdownBaseTextColor(.indigo)
        case .colors:
            // These are colours for a light page of their own, whatever the system's appearance.
            markdownColors(CatalogColors.plum)
                .environment(\.colorScheme, CatalogColors.plum.scheme)
                .background(CatalogColors.plum.background)
        case .search: search(["needle"], foreground: .white, background: .blue)
        case .listIndent: markdownListIndent(32)
        case .componentSpacing: markdownComponentSpacing(24)
        case .noEdgeInsets: markdownStreamBlockEdgeInsets(false)
        case .lineSpacing: lineSpacing(6)
        case .dashMarker: markdownUnorderedListMarker(.dash)
        case .letterMarker: markdownOrderedListMarker(.increasingLetters)
        case .rtl: environment(\.layoutDirection, .rightToLeft)
        case .quoteGithub: blockQuoteStyle(.github)
        case .quoteDecoration: markdownBlockQuote(true)
        case .codeScrollable: markdownCodeBlockScrollable()
        case .codeFull: showFullCodeBlock(true)
        case .codeRenderer:
            codeBlockRenderer(forLanguage: "catalog") { code, _ in CatalogCodePreview(code: code) }
        case .codeRendererBare:
            codeBlockRenderer(forLanguage: "catalog", bare: true) { code, _ in CatalogCodePreview(code: code) }
        case .codeRendererDisabled:
            codeBlockRenderer(forLanguage: "catalog") { code, _ in CatalogCodePreview(code: code) }
                .codeBlockRendererDisabled(forLanguages: ["catalog"])
        case .codeHighlighter: codeHighlighter(HighlightrCodeHighlighter())
        case .codeFloo:
            codeBlockStyle(DocCodeBlockStyle())
        case .tableGithub: markdownTableStyle(.github)
        case .tableGrid: markdownTableStyle(.grid)
        case .tableScrollable: markdownTableScrollable()
        case .tableHeaderColumn:
            markdownTableScrollable().markdownTableAppearance(MarkdownTableAppearance(headerColumn: true))
        case .tableNoHeaderRow:
            markdownTableScrollable().markdownTableAppearance(MarkdownTableAppearance(headerRow: false))
        case .tableNoStripe:
            markdownTableScrollable().markdownTableAppearance(MarkdownTableAppearance(stripe: .none))
        case .tableStripeColor:
            markdownTableScrollable().markdownTableAppearance(MarkdownTableAppearance(stripe: .color(.mint.opacity(0.2))))
        case .tableSerif:
            markdownTableScrollable().markdownTableAppearance(MarkdownTableAppearance(fontDesign: .serif))
        case .tableCellLooks:
            markdownTableScrollable().markdownTableAppearance(MarkdownTableAppearance(cells: CatalogTable.cellLooks))
        case .tableDimsParentheticals: markdownTableScrollable().markdownTableHeaderDimsParentheticals()
        case .tableCellsSelectable: markdownTableScrollable().markdownTableCellsSelectable()
        case .tableCellPadding: markdownTableCellPadding(.all, 12)
        case .tableCellOverlay:
            markdownTableCellOverlay { Rectangle().stroke(.red.opacity(0.4)) }
        case .tableRowBackground: markdownTableRowBackgroundStyle(Color.yellow.opacity(0.15))
        case .tableImage:
            markdownTableImageRenderer { configuration in
                Text(configuration.alternativeText ?? "image")
                    .font(.caption)
                    .padding(4)
                    .background(.quaternary, in: .rect(cornerRadius: 4))
            }
        case .tableCellReplacement:
            markdownTableScrollable().markdownTableCellReplacement([MarkdownTableCellPosition(row: 1, column: 1)]) { _ in
                AnyView(Text("Replaced").foregroundStyle(.red))
            }
        case .tableDecoration:
            markdownTableScrollable().markdownTableDecoration { _ in
                AnyView(Rectangle().stroke(.blue.opacity(0.5)))
            }
        case .imageRenderer: markdownImageRenderer(CatalogImageRenderer(), forURLScheme: "catalog")
        case .baseURL: markdownBaseURL("https://\(CatalogImages.host)/")
        case .directive: blockDirectiveRenderer(CatalogNoteDirective(), for: "note")
        case .editorStyle: markdownViewStyle(.editor)
        case .autolinkOff: markdownAutolinkDetectionEnabled(false)
        case .siteIcons: markdownLinkSiteIcons()
        case .footnotes: markdownFootnotes(CatalogNotes.footnotes)
        case .rangeDecoration: environment(\.markdownTextRangeDecorations, CatalogNotes.decorations)
        case .inlineAnchor: environment(\.markdownTextInlineAnchors, CatalogNotes.anchors)
        }
    }

    /// The fixture's settings, the first in the list outermost.
    func catalogKnobs(_ knobs: ArraySlice<CatalogKnob>) -> AnyView {
        guard let first = knobs.first else { return AnyView(self) }
        return AnyView(catalogKnob(first).catalogKnobs(knobs.dropFirst()))
    }
}

// MARK: - What the settings set

private struct CatalogFonts: MarkdownFontGroup {
    var h1: Font { .system(.largeTitle, design: .rounded).bold() }
    var h2: Font { .system(.title2, design: .rounded) }
    var body: Font { .system(.callout, design: .serif) }
    var codeBlock: Font { .system(.footnote, design: .monospaced) }
    var blockQuote: Font { .system(.body, design: .rounded) }
    var tableHeader: Font { .headline }
    var tableBody: Font { .subheadline }
}

private struct CatalogHeadingColors: HeadingStyleGroup {
    var h1: Color { .red }
    var h2: Color { .orange }
    var h3: Color { .green }
    var h4: Color { .teal }
    var h5: Color { .blue }
    var h6: Color { .purple }
}

enum CatalogTypography {
    private static func variant(_ change: (inout MarkdownPlatformTypography) -> Void) -> MarkdownPlatformTypography {
        var typography = MarkdownPlatformTypography.standard
        change(&typography)
        return typography
    }

    /// As a Doc page sets its text.
    static let doc = variant {
        $0.body = .init(.callout)
        $0.inlineCode = .init(.footnote)
        $0.tableBody = .init(.footnote)
    }
    static let inlineCode = variant { $0.inlineCode = .init(.body) }
    static let leadingOff = variant { $0.body.keepsTextStyleLeading = false }
    static let serif = variant { $0.body.design = .serif }
    static let strong = variant { $0.strongWeight = .black }
    static let centered = variant { $0.paragraphAlignment = .center }
}

enum CatalogColors {
    static let plum = MarkdownColors(
        primary: Color(red: 0.26, green: 0.10, blue: 0.32),
        secondary: Color(red: 0.45, green: 0.30, blue: 0.50),
        tertiary: Color(red: 0.62, green: 0.50, blue: 0.65),
        accent: Color(red: 0.70, green: 0.15, blue: 0.45),
        scheme: .light,
        background: Color(red: 0.97, green: 0.93, blue: 0.97)
    )
}

enum CatalogTable {
    static let cellLooks: [MarkdownTableCellPosition: MarkdownTableCellAppearance] = [
        MarkdownTableCellPosition(row: 1, column: 0): .init(fill: MarkdownColorToken.fill("blue", strength: 1)),
        MarkdownTableCellPosition(row: 1, column: 1): .init(fill: MarkdownColorToken.fill("blue", strength: 2)),
        MarkdownTableCellPosition(row: 1, column: 2): .init(fill: MarkdownColorToken.fill("blue", strength: 3)),
        MarkdownTableCellPosition(row: 2, column: 0): .init(alignment: .leading, tag: .green),
        MarkdownTableCellPosition(row: 2, column: 1): .init(alignment: .center, fontDesign: .monospaced),
        MarkdownTableCellPosition(row: 2, column: 2): .init(alignment: .trailing, fontDesign: .serif),
        MarkdownTableCellPosition(row: 3, column: 0): .init(alignment: .justified),
    ]
}

enum CatalogNotes {
    private static let url = URL(string: "catalog://note")
    static let footnotes = MarkdownFootnotes(
        references: [
            "1": .init(number: 1, referenceURL: url, definitionURL: url),
            "named": .init(number: 2, referenceURL: url, definitionURL: url),
        ],
        inlineNotes: [.init(number: 3, url: url)]
    )
    static let decorations = [
        MarkdownTextRangeDecoration(id: "a", plainStart: 4, plainLength: 9, underlineColor: .orange),
        MarkdownTextRangeDecoration(id: "b", plainStart: 20, plainLength: 8, underlineColor: .blue, tapURL: url),
    ]
    static let anchors = [
        MarkdownTextInlineAnchor(id: "a", plainOffset: 13, url: url),
    ]
}

private struct CatalogNoteDirective: BlockDirectiveRenderer {
    func makeBody(configuration: Configuration) -> some View {
        Text(configuration.wrappedString)
            .padding(20)
            .background(.yellow.secondary, in: .rect(cornerRadius: 12))
    }
}

private struct CatalogImageRenderer: MarkdownImageRenderer {
    func makeBody(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.teal)
            .frame(width: 120, height: 60)
            .overlay { Text(configuration.alternativeText ?? "").foregroundStyle(.white) }
    }
}

private struct CatalogCodePreview: View {
    let code: String
    var body: some View {
        Text(code)
            .font(.caption)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.mint.opacity(0.2))
    }
}
