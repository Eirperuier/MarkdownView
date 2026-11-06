//
//  CatalogUIKit.swift
//  DemoApp
//
//  The same fixtures and knobs, drawn by MarkdownUIKit: `-catalogRenderer uikit`. A knob this
//  renderer doesn't have yet changes nothing here, and shows up as a difference in the diff.
//

import FlooUIKit
import MarkdownUIKit
import MarkdownView
import SwiftUI
import UIKit

/// A fixture's blocks stacked at a width, against each other as chat's rows are. Blocks sit on
/// the pixel grid as a layout puts them.
@MainActor
final class CatalogUIKitFixtureView: UIView {
    private let blocks: [MarkdownUIKit.MarkdownBlockView]
    private let scale: CGFloat

    init(fixture: CatalogFixture, scale: CGFloat) {
        self.scale = scale
        var settings = CatalogUIKitSettings()
        for knob in fixture.knobs { settings.apply(knob) }
        let style = settings.style

        switch fixture.path {
        case .stream:
            var splitter = MarkdownBlockSplitter()
            blocks = splitter.split(fixture.markdown).map { block in
                let view = MarkdownUIKit.MarkdownBlockView()
                view.configure(block, style: style)
                return view
            }
        case .selectableText, .document:
            let view = MarkdownUIKit.MarkdownBlockView()
            if settings.isQuoteDecorated {
                view.configureAsQuote(markdown: fixture.markdown, style: style)
            } else {
                view.configure(markdown: fixture.markdown, style: style)
            }
            blocks = [view]
        }
        super.init(frame: .zero)
        traitOverrides.flooTheme = settings.theme
        if let appearance = settings.appearance { traitOverrides.userInterfaceStyle = appearance }
        backgroundColor = settings.background
        blocks.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        blocks.reduce(0) { $0 + $1.height(forWidth: width) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        for block in blocks {
            let height = block.height(forWidth: bounds.width)
            let top = (y * scale).rounded() / scale
            let bottom = ((y + height) * scale).rounded() / scale
            block.frame = CGRect(x: 0, y: top, width: bounds.width, height: bottom - top)
            y += height
        }
    }
}

/// What the knobs set: a style, and what a host sets around it.
@MainActor
struct CatalogUIKitSettings {
    var style = MarkdownStyle()
    /// The app's accent: SwiftUI takes it from the asset catalog, a theme names it.
    var theme = FlooTheme.system.setting(.accent, to: UIColor(named: "AccentColor") ?? .systemBlue)
    var appearance: UIUserInterfaceStyle?
    var background: UIColor?
    var isQuoteDecorated = false

    init() {
        // The baseline's stream blocks draw their formulas at once too.
        style.rendersDisplayMathSynchronously = true
        style.icons = MarkdownIcons(image: { host in
            // One fixed picture, or none for the host that shows the fallback.
            host == "noicon.test" ? nil : UIImage(systemName: "seal.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 64))
        })
    }

    mutating func apply(_ knob: CatalogKnob) {
        switch knob {
        // Type. The SwiftUI path's font groups reach only what isn't set in the typography.
        case .fontGroup:
            var body = MarkdownTypography.Style(.callout)
            body.design = .serif
            var h1 = MarkdownTypography.Style(.largeTitle, weight: .bold)
            h1.design = .rounded
            var h2 = MarkdownTypography.Style(.title2)
            h2.design = .rounded
            style.typography.body = body
            style.typography.headings = [h1, h2] + style.typography.headings.dropFirst(2)
        case .fontBody:
            var body = MarkdownTypography.Style(.title3)
            body.design = .rounded
            style.typography.body = body
        case .fontHeading:
            var h1 = MarkdownTypography.Style(.largeTitle, weight: .bold)
            h1.design = .serif
            style.typography.headings[0] = h1
        case .fontMath:
            style.inlineMathTextStyle = .title3
            style.displayMathTextStyle = .title2
        case .fontCode, .fontQuote, .fontTable:
            break  // Fonts of blocks that aren't drawn yet, or the SwiftUI path's alone.
        case .typographyDoc:
            style.typography.body = .init(.callout)
            style.typography.inlineCode = .init(.footnote)
        case .typographyInlineCode:
            style.typography.inlineCode = .init(.body)
        case .typographyLeadingOff:
            style.typography.body.keepsTextStyleLeading = false
        case .typographySerif:
            style.typography.body.design = .serif
        case .typographyStrong:
            style.typography.strongWeight = .black
        case .typographyCentered:
            style.typography.paragraphAlignment = .center
        case .headingStyleGroup:
            style.headingColors = [
                1: UIColor(Color.red), 2: UIColor(Color.orange), 3: UIColor(Color.green),
                4: UIColor(Color.teal), 5: UIColor(Color.blue), 6: UIColor(Color.purple),
            ]
        case .headingStyleOne:
            style.headingColors[2] = UIColor(Color.orange)
        case .headingPadding:
            style.headingPaddings.top[0] = 40
            style.headingPaddings.top[1] = 4
            style.headingPaddings.bottom[1] = 20
        case .dynamicType(let size):
            style.contentSizeCategory = UIContentSizeCategory(size)
        // Colour
        case .tintLink: style.linkColor = UIColor(Color.green)
        case .tintQuote: style.quoteColor = UIColor(Color.orange)
        case .tintInlineCode: style.inlineCodeColor = UIColor(Color.pink)
        case .preferredColor: style.strongColor = UIColor(Color.purple)
        case .baseTextColor: style.textColor = UIColor(Color.indigo)
        case .colors:
            // Colours for a light page of their own: a theme, on that page.
            let plum = CatalogColors.plum
            let accent = UIColor(plum.accent)
            let secondary = UIColor(plum.secondary)
            theme = theme.setting([
                .label: UIColor(plum.primary),
                .secondaryLabel: secondary,
                .accent: accent,
                .markdownInlineCode: secondary,
            ])
            appearance = .light
            background = plum.background.map { UIColor($0) }
        case .search:
            break  // The SwiftUI path's own: not ported.
        // Layout
        case .listIndent: style.list.leadingIndentation = 32
        case .componentSpacing: style.componentSpacing = 24
        case .noEdgeInsets: style.addsEdgeInsets = false
        case .lineSpacing: style.lineSpacing = 6
        case .dashMarker: style.list.unorderedMarker = .dash
        case .letterMarker: style.list.orderedMarker = .letters
        case .rtl: style.layoutDirection = .rightToLeft
        // Blocks
        case .quoteGithub:
            break  // The SwiftUI path's own: not ported.
        case .quoteDecoration:
            isQuoteDecorated = true
        case .codeScrollable, .codeFull, .codeRenderer, .codeRendererBare, .codeRendererDisabled, .codeHighlighter, .codeFloo:
            break  // Code isn't drawn yet.
        case .tableGithub, .tableGrid, .tableScrollable, .tableHeaderColumn, .tableNoHeaderRow, .tableNoStripe,
             .tableStripeColor, .tableSerif, .tableCellLooks, .tableDimsParentheticals, .tableCellsSelectable,
             .tableCellPadding, .tableCellOverlay, .tableRowBackground, .tableImage, .tableCellReplacement, .tableDecoration:
            break  // Tables aren't drawn yet.
        case .imageRenderer, .baseURL:
            break  // Images aren't drawn yet.
        case .directive:
            style.registeredDirectives.insert("note")
        case .editorStyle:
            break  // The SwiftUI path's own: not ported.
        // Text features
        case .autolinkOff: style.autolinks = false
        case .siteIcons: style.linkSiteIcons = true
        case .footnotes: style.footnotes = CatalogNotes.footnotes
        case .rangeDecoration:
            style.rangeDecorations = CatalogNotes.decorations.map {
                MarkdownRangeDecoration(id: $0.id, plainStart: $0.plainStart, plainLength: $0.plainLength, underlineColor: UIColor($0.underlineColor), tapURL: $0.tapURL, preservesInnerLinks: $0.preservesInnerLinks)
            }
        case .inlineAnchor:
            style.inlineAnchors = CatalogNotes.anchors.map {
                MarkdownInlineAnchor(id: $0.id, plainOffset: $0.plainOffset, url: $0.url)
            }
        }
    }
}
