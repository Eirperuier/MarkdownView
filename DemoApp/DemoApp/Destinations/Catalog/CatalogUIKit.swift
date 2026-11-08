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
    var onHeightChange: (() -> Void)?

    init(fixture: CatalogFixture, scale: CGFloat, revealed: CatalogRevealed? = nil) {
        self.scale = scale
        var settings = CatalogUIKitSettings()
        for knob in fixture.knobs { settings.apply(knob) }
        let style = settings.style

        switch fixture.path {
        case .stream where revealed != nil:
            let revealed = revealed!
            blocks = revealed.blocks.map { block in
                let view = MarkdownUIKit.MarkdownBlockView()
                view.configure(block, style: style, reveal: MarkdownReveal(manager: revealed.managers[block.id]!, style: ChatUIKitBlock.revealStyle))
                return view
            }
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
        // `-catalogRevealTheme from|switch`: a theme set before the frame, or changed mid-reveal
        // after it has drawn. The two pictures must be the same.
        if let revealed, revealed.blocks.isEmpty == false, let mode = UserDefaults.standard.string(forKey: "catalogRevealTheme") {
            let changed = settings.theme.setting([.label: .systemPurple, .accent: .systemOrange])
            if mode == "from" {
                traitOverrides.flooTheme = changed
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.traitOverrides.flooTheme = changed
                }
            }
        }
        if let appearance = settings.appearance { traitOverrides.userInterfaceStyle = appearance }
        backgroundColor = settings.background
        blocks.forEach(addSubview)
        // An image comes in late: the fixture grows with it, as a list's row does.
        for block in blocks {
            block.onHeightChange = { [weak self] in
                self?.setNeedsLayout()
                self?.onHeightChange?()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static let tableTextViews = UserDefaults.standard.bool(forKey: "catalogTableTextViews")

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
            // `-catalogTableTextViews YES`: nothing may move when a cell takes a text view.
            if Self.tableTextViews, window != nil {
                block.layoutIfNeeded()
                block.tableView?.showAllCellsInTextViews()
            }
        }
    }
}

/// The image renderer for table cells in CatalogFixture: its description in caption, on a faint tile.
@MainActor
final class CatalogUIKitTableImage: UIView {
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        backgroundColor = .quaternaryLabel
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption1)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = label.sizeThatFits(size)
        let scale = max(1, traitCollection.displayScale)
        return CGSize(width: (fit.width * scale).rounded(.up) / scale + 8, height: (fit.height * scale).rounded(.up) / scale + 8)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 4, dy: 4)
    }
}

/// The decoration in CatalogFixture: a line round the table, half on each side of its edges.
@MainActor
final class CatalogUIKitTableFrame: UIView {
    private let line = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        line.fillColor = nil
        line.lineWidth = 1
        line.strokeColor = UIColor(Color.blue.opacity(0.5)).cgColor
        layer.addSublayer(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = bounds
        line.path = UIBezierPath(rect: bounds).cgPath
    }
}

/// The directive's renderer in CatalogFixture: text in 20 pt of room on half-strength yellow.
@MainActor
final class CatalogUIKitNote: UIView {
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.systemYellow.withAlphaComponent(0.5)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = label.sizeThatFits(CGSize(width: size.width - 40, height: .greatestFiniteMagnitude))
        return CGSize(width: fit.width + 40, height: fit.height + 40)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 20, dy: 20)
    }
}

/// The image renderer in CatalogFixture: its description on a teal tile.
@MainActor
final class CatalogUIKitImageTile: UIView {
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        backgroundColor = .systemTeal
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        label.text = text
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: 120, height: 60) }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }
}

/// What the knobs set: a style, and what a host sets around it.
@MainActor
struct CatalogUIKitSettings {
    var style = {
        var style = MarkdownStyle()
        style.drawsTextUntilTouched = UserDefaults.standard.bool(forKey: "chatDrawsText")
        // The catalogue's baseline is MarkdownView's: its header, plain unless a knob colours it.
        style.codeBlock.look = .header
        style.codeBlock.highlighter = nil
        return style
    }()
    /// The app's accent: SwiftUI takes it from the asset catalog, a theme names it.
    var theme = FlooTheme.system.setting(.accent, to: UIColor(named: "AccentColor") ?? .systemBlue)
    var appearance: UIUserInterfaceStyle?
    var background: UIColor?
    var isQuoteDecorated = false

    init() {
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
            style.codeBlock.font = .init(.footnote)
            style.table.headerFont = .init(.headline, weight: .semibold)
            style.table.bodyFont = .init(.subheadline)
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
        case .fontCode:
            style.codeBlock.font = .init(.body)
        case .fontTable:
            // A font's `bold()` is its bold trait: semibold on the system's.
            var header = MarkdownTypography.Style(.callout, weight: .semibold)
            header.design = .rounded
            var body = MarkdownTypography.Style(.footnote)
            body.design = .monospaced
            style.table.headerFont = header
            style.table.bodyFont = body
        case .fontQuote:
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
        case .codeScrollable: style.codeBlock.scrollsSideways = true
        case .codeFull: style.codeBlock.showsAllLines = true
        case .codeRenderer:
            style.codeBlock.renderers["catalog"] = MarkdownCodeRenderer(underHeader: CatalogCodePreviewView.ground) { code, _ in CatalogCodePreviewView(code: code) }
        case .codeRendererBare:
            style.codeBlock.renderers["catalog"] = MarkdownCodeRenderer(bare: true) { code, _ in CatalogCodePreviewView(code: code) }
        case .codeRendererDisabled:
            style.codeBlock.renderers["catalog"] = MarkdownCodeRenderer { code, _ in CatalogCodePreviewView(code: code) }
            style.codeBlock.disabledRenderers = ["catalog"]
        case .codeHighlighter: style.codeBlock.highlighter = MarkdownHighlightrHighlighter()
        case .codeFloo: style.codeBlock.look = .box
        case .tableGithub: style.table.look = .github
        case .tableGrid: style.table.look = .grid
        case .tableScrollable: style.table.scrollsSideways = true
        case .tableHeaderColumn:
            style.table.scrollsSideways = true
            style.table.appearance.headerColumn = true
        case .tableNoHeaderRow:
            style.table.scrollsSideways = true
            style.table.appearance.headerRow = false
        case .tableNoStripe:
            style.table.scrollsSideways = true
            style.table.appearance.stripe = .none
        case .tableStripeColor:
            style.table.scrollsSideways = true
            style.table.appearance.stripe = .color(UIColor(Color.mint.opacity(0.2)))
        case .tableSerif:
            style.table.scrollsSideways = true
            style.table.appearance.fontDesign = .serif
        case .tableCellLooks:
            style.table.scrollsSideways = true
            style.table.appearance.cells = [
                MarkdownTableCellPosition(row: 1, column: 0): .init(fill: UIColor(MarkdownColorToken.fill("blue", strength: 1)!)),
                MarkdownTableCellPosition(row: 1, column: 1): .init(fill: UIColor(MarkdownColorToken.fill("blue", strength: 2)!)),
                MarkdownTableCellPosition(row: 1, column: 2): .init(fill: UIColor(MarkdownColorToken.fill("blue", strength: 3)!)),
                MarkdownTableCellPosition(row: 2, column: 0): .init(alignment: .leading, tag: UIColor(Color.green)),
                MarkdownTableCellPosition(row: 2, column: 1): .init(alignment: .center, fontDesign: .monospaced),
                MarkdownTableCellPosition(row: 2, column: 2): .init(alignment: .trailing, fontDesign: .serif),
                MarkdownTableCellPosition(row: 3, column: 0): .init(alignment: .justified),
            ]
        case .tableDimsParentheticals:
            style.table.scrollsSideways = true
            style.table.dimsHeaderParentheticals = true
        case .tableCellsSelectable:
            style.table.scrollsSideways = true
        case .tableCellPadding:
            break  // The default look sets its own padding over a host's, in the baseline too.
        case .tableCellOverlay:
            style.table.cellOverlay = { cell in
                UIColor(Color.red.opacity(0.4)).setStroke()
                UIBezierPath(rect: cell).stroke()
            }
        case .tableRowBackground:
            style.table.rowBackground = UIColor(Color.yellow.opacity(0.15))
        case .tableImage:
            style.table.imageRenderer = { CatalogUIKitTableImage(text: $0.alternativeText ?? "image") }
        case .tableCellReplacement:
            style.table.scrollsSideways = true
            style.table.replacedCells = [MarkdownTableCellPosition(row: 1, column: 1)]
            style.table.replacement = { _ in
                let label = UILabel()
                label.text = "Replaced"
                label.textColor = .systemRed
                label.font = .preferredFont(forTextStyle: .body)
                return label
            }
        case .tableDecoration:
            style.table.scrollsSideways = true
            style.table.decoration = { _ in CatalogUIKitTableFrame() }
        case .imageRenderer:
            style.imageRenderers["catalog"] = { CatalogUIKitImageTile(text: $0.alternativeText ?? "") }
        case .baseURL:
            style.baseURL = URL(string: "https://\(CatalogImages.host)/")
        case .directive:
            style.blockDirectives["note"] = { CatalogUIKitNote(text: $0.wrappedString) }
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

/// `CatalogCodePreview` in UIKit: the code in caption, padded by 12, on a faint mint ground.
final class CatalogCodePreviewView: UIView {
    static let ground = UIColor(Color.mint.opacity(0.2))
    private let label = UILabel()

    init(code: String) {
        super.init(frame: .zero)
        backgroundColor = Self.ground
        label.text = code
        label.font = .preferredFont(forTextStyle: .caption1)
        label.numberOfLines = 0
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = label.sizeThatFits(CGSize(width: size.width - 24, height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: fitted.height.rounded(.up) + 24)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 12, dy: 12)
    }
}
