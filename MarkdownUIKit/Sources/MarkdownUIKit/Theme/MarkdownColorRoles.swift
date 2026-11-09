//
//  MarkdownColorRoles.swift
//  MarkdownUIKit
//
//  What each colour Markdown draws is for, as floo-uikit's roles: the same theme that colours
//  a form colours the text in it. Everything drawn here is a role's dynamic colour, so setting
//  the theme (`view.traitOverrides.flooTheme`) changes the picture with nothing parsed or laid
//  out again.
//
//  Every role falls back to a form role or to what MarkdownView draws: under `.system` the
//  picture is the same as MarkdownView's.
//

import FlooColor
import FlooUIKit
import MarkdownCore
import os
import UIKit

public extension FlooColorRole {
    // Text
    /// Body text and headings.
    static let markdownText = FlooColorRole("markdown.text") { $0[.label] }
    /// Table of contents, a code block's language, what's quieter than the text.
    static let markdownSecondaryText = FlooColorRole("markdown.secondaryText") { $0[.secondaryLabel] }
    /// Bullets and other marks quieter than the text beside them.
    static let markdownTertiaryText = FlooColorRole("markdown.tertiaryText") { $0.sets(.placeholder) ? $0[.placeholder] : .tertiaryLabel }
    /// Links.
    static let markdownLink = FlooColorRole("markdown.link") { $0[.accent] }
    /// Bold text.
    static let markdownStrong = FlooColorRole("markdown.strong") { $0[.accent] }
    /// The second line of an extended heading.
    static let markdownSubtitle = FlooColorRole("markdown.subtitle") { $0[.markdownSecondaryText] }
    /// Footnote definitions.
    static let markdownFootnoteText = FlooColorRole("markdown.footnoteText") { $0[.markdownSecondaryText] }

    /// Formulas: the glyphs a formula names no colour for.
    static let markdownMath = FlooColorRole("markdown.math") { $0[.markdownText] }

    // Inline code and highlights
    /// Inline code's text: grey, or a theme's secondary text.
    static let markdownInlineCode = FlooColorRole("markdown.inlineCode") { $0.sets(.secondaryLabel) ? $0[.secondaryLabel] : .systemGray }
    /// The ground behind inline code.
    static let markdownInlineCodeFill = FlooColorRole("markdown.inlineCodeFill") { $0[.markdownInlineCode].markdownOpacity(0.1) }
    /// The ground behind `==highlighted==` text: the document palette's yellow.
    static let markdownHighlight = FlooColorRole("markdown.highlight") { $0[.markdownHighlight(.yellow)] }

    // Lists
    /// Bullets and numbers.
    static let markdownListMarker = FlooColorRole("markdown.listMarker") { $0[.markdownSecondaryText] }
    /// A done task's mark.
    static let markdownTaskDone = FlooColorRole("markdown.taskDone") { $0[.accent] }
    /// A task to do's mark.
    static let markdownTaskOpen = FlooColorRole("markdown.taskOpen") { $0[.markdownSecondaryText] }
    /// The disc behind a symbol bullet.
    static let markdownSymbolBullet = FlooColorRole("markdown.symbolBullet") { $0[.accent] }
    /// The symbol on that disc: whichever of white and black shows on it. MarkdownView's is
    /// always white, which a white accent hides in dark.
    static let markdownOnSymbolBullet = FlooColorRole("markdown.onSymbolBullet") { theme in
        let disc = theme[.markdownSymbolBullet]
        return UIColor { traits in
            var white: CGFloat = 0
            disc.resolvedColor(with: traits).getWhite(&white, alpha: nil)
            return white > 0.7 ? .black : .white
        }
    }

    // Quotes
    /// A quote's bar.
    static let markdownQuote = FlooColorRole("markdown.quote") { $0[.accent] }
    /// A quote's ground.
    static let markdownQuoteFill = FlooColorRole("markdown.quoteFill") { $0[.markdownQuote].markdownOpacity(0.1) }
    /// Bold text and links inside a quote: black and white, so the bar stays the one colour.
    static let markdownQuoteEmphasis = FlooColorRole("markdown.quoteEmphasis") { $0[.markdownText] }

    // Blocks
    /// A thematic break's line: faint grey, or a theme's secondary text.
    static let markdownRule = FlooColorRole("markdown.rule") { ($0.sets(.secondaryLabel) ? $0[.secondaryLabel] : .systemGray).markdownOpacity(0.1) }
    /// The mark where an image didn't load.
    static let markdownImagePlaceholder = FlooColorRole("markdown.imagePlaceholder") { $0[.markdownSecondaryText] }

    /// An image's panel until its picture is here.
    static let markdownImageFill = FlooColorRole("markdown.imageFill") { theme in
        theme.sets(.label) ? theme[.markdownText].markdownOpacity(0.1) : .secondarySystemBackground
    }

    // Code box. Under `.system` the text colour's opacities DocKit measured on Craft's dark page;
    // a theme's colours are stronger, as those vanish on a coloured surface.
    /// The box's ground.
    static let markdownCodeBoxFill = FlooColorRole("markdown.codeBox.fill") { codeBoxInk($0, 0.014, themed: 0.06) }
    /// The gutter's ground, over the box's.
    static let markdownCodeBoxGutter = FlooColorRole("markdown.codeBox.gutter") { codeBoxInk($0, 0.014, themed: 0.05) }
    /// The box's outline.
    static let markdownCodeBoxBorder = FlooColorRole("markdown.codeBox.border") { codeBoxInk($0, 0.09, themed: 0.2) }
    /// The line between the gutter and the code.
    static let markdownCodeBoxSeparator = FlooColorRole("markdown.codeBox.separator") { codeBoxInk($0, 0.09, themed: 0.2) }
    /// The line numbers.
    static let markdownCodeBoxLineNumber = FlooColorRole("markdown.codeBox.lineNumber") { $0[.markdownTertiaryText] }

    private static func codeBoxInk(_ theme: FlooTheme, _ system: CGFloat, themed: CGFloat) -> UIColor {
        theme[.markdownText].markdownOpacity(theme.sets(.label) ? themed : system)
    }

    // Tables
    /// A cell's text.
    static let markdownTableText = FlooColorRole("markdown.tableText") { $0[.markdownText] }
    /// A header cell's text.
    static let markdownTableHeaderText = FlooColorRole("markdown.tableHeaderText") { $0[.markdownTableText] }
    /// What's in brackets in a header that dims them.
    static let markdownTableHeaderDimmed = FlooColorRole("markdown.tableHeaderDimmed") { $0[.markdownSecondaryText] }
    /// The line between rows.
    static let markdownTableSeparator = FlooColorRole("markdown.tableSeparator") { theme in
        // A divider's colour on every platform; the Mac's `separator` is fainter.
        theme.sets(.separator) ? theme[.separator] : UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 84 / 255, green: 84 / 255, blue: 88 / 255, alpha: 0.6)
                : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.29)
        }
    }
    /// Every other row's stripe, in a table that scrolls.
    static let markdownTableStripe = FlooColorRole("markdown.tableStripe") { $0[.markdownTertiaryText].markdownOpacity(0.08) }
    /// GitHub's look: the lines round its cells, GitHub's colours, half strength.
    static let markdownTableGitHubBorder = FlooColorRole("markdown.tableGitHubBorder") { _ in
        Self.gitHubColor(light: (209, 217, 224), dark: (61, 68, 67)).markdownOpacity(0.5)
    }
    /// GitHub's look: odd rows' ground, under the header too.
    static let markdownTableGitHubRow = FlooColorRole("markdown.tableGitHubRow") { theme in
        theme.sets(.background) ? theme[.background] : Self.gitHubColor(light: (255, 255, 255), dark: (14, 17, 22))
    }
    /// GitHub's look: even rows' ground.
    static let markdownTableGitHubAlternateRow = FlooColorRole("markdown.tableGitHubAlternateRow") { theme in
        theme.sets(.background) ? theme[.markdownTableStripe] : Self.gitHubColor(light: (246, 248, 250), dark: (21, 27, 35))
    }
    /// The grid look's lines round its cells.
    static let markdownTableGridBorder = FlooColorRole("markdown.tableGridBorder") { $0[.markdownTableText] }

    private static func gitHubColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0 / 255, green: value.1 / 255, blue: value.2 / 255, alpha: 1)
        }
    }

    // Chips
    /// A chip's capsule.
    static let markdownChipFill = FlooColorRole("markdown.chipFill") { $0[.markdownInlineCode].markdownOpacity(0.1) }
    /// A chip's label and placeholder icon.
    static let markdownChipText = FlooColorRole("markdown.chipText") { $0[.markdownSecondaryText] }
    /// A chip's "+2".
    static let markdownChipCount = FlooColorRole("markdown.chipCount") { $0[.markdownChipText].markdownOpacity(0.7) }

    // Bubbles
    /// A topic bubble's capsule.
    static let markdownBubbleFill = FlooColorRole("markdown.bubbleFill") { $0[.markdownInlineCode].markdownOpacity(0.12) }
    /// A topic bubble's icon.
    static let markdownBubbleIcon = FlooColorRole("markdown.bubbleIcon") { $0[.markdownSecondaryText] }

    // Marks named in the text
    /// A pen in the `accent` ink.
    static let markdownPenAccent = FlooColorRole("markdown.penAccent") { $0[.accent] }
    /// Text in the `accent` colour.
    static let markdownAccentText = FlooColorRole("markdown.accentText") { $0[.accent] }

    // Named colours
    /// The colour a name stands for wherever the text names it: `{red}`, a pen's `red`, a
    /// callout's. One per name, so a word, a mark and a callout in red agree. Made to read on the
    /// surface where it's drawn.
    static func markdownInk(_ name: MarkdownInkName) -> FlooColorRole { MarkdownInkRoles.inks[name.rawValue]! }
    /// The ground of a highlight in that colour (`==x=={red}`, a marker's): faint, so the text
    /// on it reads, and the text is made to read on it besides.
    static func markdownHighlight(_ name: MarkdownInkName) -> FlooColorRole { MarkdownInkRoles.grounds[name.rawValue]! }

    // Callouts
    /// FlooUIKit has no info role yet: the system's blue, as a note always was.
    static let markdownCalloutNote = FlooColorRole("markdown.callout.note") { _ in .systemBlue }
    static let markdownCalloutTip = FlooColorRole("markdown.callout.tip") { $0[.success] }
    static let markdownCalloutImportant = FlooColorRole("markdown.callout.important") { $0[.markdownInk(.purple)] }
    static let markdownCalloutWarning = FlooColorRole("markdown.callout.warning") { $0[.warning] }
    static let markdownCalloutCaution = FlooColorRole("markdown.callout.caution") { $0[.destructive] }

    /// A callout's tint, by kind.
    static func markdownCallout(_ kind: MarkdownCallout.Kind) -> FlooColorRole {
        switch kind {
        case .note: .markdownCalloutNote
        case .tip: .markdownCalloutTip
        case .important: .markdownCalloutImportant
        case .warning: .markdownCalloutWarning
        case .caution: .markdownCalloutCaution
        }
    }
}

/// The colours text can name: the document palette in Craft's order, then the rest a pen knows.
public enum MarkdownInkName: String, CaseIterable, Sendable {
    case gray, slate, purple, blue, cyan, mint, green, lemon, yellow, red, orange, brown, teal, indigo, pink

    /// A token's name: `grey` is `gray`; nil for one that isn't a name.
    public init?(token: String) {
        self.init(rawValue: token == "grey" ? "gray" : token)
    }
}

/// The named colours' roles, made once: a role's fallback is the palette's shade, or the
/// system's colour for a name the palette hasn't.
private enum MarkdownInkRoles {
    static let inks: [String: FlooColorRole] = Dictionary(uniqueKeysWithValues: MarkdownInkName.allCases.map { name in
        (name.rawValue, FlooColorRole("markdown.ink.\(name.rawValue)") { _ in MarkdownInk.paletteInk(name) })
    })
    static let grounds: [String: FlooColorRole] = Dictionary(uniqueKeysWithValues: MarkdownInkName.allCases.map { name in
        (name.rawValue, FlooColorRole("markdown.highlight.\(name.rawValue)") { _ in MarkdownInk.paletteGround(name) })
    })
}

public extension UIColor {
    /// A colour Markdown names (`{blue}`, a pen's ink) made to read on the theme's surface.
    /// As it is under a theme that leaves the surface the system's.
    static func markdown(named color: UIColor) -> UIColor {
        .floo(readable: color)
    }

    /// This colour at `opacity`, as it resolves: what's dynamic stays so.
    func markdownOpacity(_ opacity: CGFloat) -> UIColor {
        UIColor { traits in
            let resolved = self.resolvedColor(with: traits)
            var alpha: CGFloat = 0
            resolved.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            return resolved.withAlphaComponent(alpha * opacity)
        }
    }
}

public enum MarkdownColorTraits {
    /// The traits a colour here reads: to redraw what holds a resolved colour.
    public static let all: [UITrait] = UITraitCollection.systemTraitsAffectingColorAppearance + [
        FlooThemeTrait.self, FlooAppearanceTrait.self, FlooOverGlassTrait.self, FlooSurfaceTrait.self,
    ]

    /// Whether a colour here comes out the same under both.
    static func resolveAlike(_ first: UITraitCollection, _ second: UITraitCollection) -> Bool {
        !first.hasDifferentColorAppearance(comparedTo: second)
            && first[FlooThemeTrait.self] == second[FlooThemeTrait.self]
            && first[FlooAppearanceTrait.self] == second[FlooAppearanceTrait.self]
            && first[FlooOverGlassTrait.self] == second[FlooOverGlassTrait.self]
            && first[FlooSurfaceTrait.self] == second[FlooSurfaceTrait.self]
    }
}

/// The colours text names, all from roles: the named colours, the status roles for what a name
/// means (`error`, `success`), `#hex` as written; then made to read where they're drawn.
enum MarkdownInk {
    /// The role a token names: a colour's name, or what it means.
    static func role(_ token: String) -> FlooColorRole? {
        switch token {
        case "negative", "error", "danger": .destructive
        case "warning": .warning
        case "positive", "success": .success
        case "info": .markdownCalloutNote
        default: MarkdownInkName(token: token).map { .markdownInk($0) }
        }
    }

    /// Text in a named colour, a meaning or `#hex`; nil for a token it doesn't know (the text
    /// keeps its colour).
    static func text(_ token: String) -> UIColor? {
        if token == "accent" { return .floo(.markdownAccentText) }
        if let hex = MarkdownColorToken.hexValue(token) { return .markdown(named: rgb(hex)) }
        return role(token).map { .markdown(named: .floo($0)) }
    }

    /// A highlight's ground in a named colour, a meaning or `#hex`.
    static func highlightFill(_ token: String) -> UIColor? {
        if token == "accent" { return .markdown(ground: UIColor.floo(.markdownAccentText).markdownOpacity(0.22)) }
        if let hex = MarkdownColorToken.hexValue(token) { return .markdown(ground: rgb(hex).markdownOpacity(0.3)) }
        if let name = MarkdownInkName(token: token) { return .markdown(ground: .floo(.markdownHighlight(name))) }
        return role(token).map { .markdown(ground: faint(.floo($0))) }
    }

    /// `:color[…]`'s text: only a token it knows takes a colour; any other stays ordinary text.
    static func markedText(_ token: String?) -> UIColor? {
        token.flatMap(text)
    }

    /// A pen's ink by name, meaning or `#hex`, as text in that colour is. `accent` and
    /// `foreground` are the caller's to read.
    static func pen(_ token: String) -> UIColor? {
        switch token {
        case "secondary": .floo(.markdownSecondaryText)
        case "primary": .floo(.markdownText)
        default: text(token)
        }
    }

    /// A marker's band: a highlight's ground, so `:marker[x]` and `==x==` in one colour agree.
    /// A token it doesn't know draws the marker's yellow.
    static func marker(_ token: String?) -> UIColor {
        token.flatMap(highlightFill) ?? .floo(.markdownHighlight)
    }

    static func callout(_ kind: MarkdownCallout.Kind) -> UIColor {
        .markdown(named: .floo(.markdownCallout(kind)))
    }

    // Fallbacks

    /// A named colour's text: the palette's shade, darker in light so a pale hue reads; the
    /// system's colour for a name the palette hasn't.
    static func paletteInk(_ name: MarkdownInkName) -> UIColor {
        if let shade = MarkdownColorToken.shades[name.rawValue] {
            return adaptive(light: rgb(shade.light), dark: rgb(shade.dark))
        }
        return systemColor(name)
    }

    /// A named colour's highlight: the hue's bright shade, faint (a little stronger in dark).
    static func paletteGround(_ name: MarkdownInkName) -> UIColor {
        if let shade = MarkdownColorToken.shades[name.rawValue] { return faint(rgb(shade.dark)) }
        return faint(systemColor(name))
    }

    private static func systemColor(_ name: MarkdownInkName) -> UIColor {
        switch name {
        case .teal: .systemTeal
        case .indigo: .systemIndigo
        case .pink: .systemPink
        default: .systemGray
        }
    }

    /// A colour as a highlight's ground: 30%, 32% in dark.
    private static func faint(_ color: UIColor) -> UIColor {
        UIColor { traits in color.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.32 : 0.3) }
    }

    private static func rgb(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

public extension UIColor {
    /// A highlight's ground as the theme draws fills: apart from the surface it's on, and as
    /// translucent as it was, so the text on it still shows through to the surface's contrast.
    static func markdown(ground color: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = color.resolvedColor(with: traits)
            var alpha: CGFloat = 1
            resolved.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            return traits.flooTheme.fill(resolved, on: traits.flooSurface, with: traits).withAlphaComponent(alpha)
        }
    }

    /// `text` made to read on a highlight's `ground` as it's drawn over the surface: itself
    /// where it reads (Lc 60, 75 with Increase Contrast), else its hue at the lightness nearest
    /// its own that does.
    static func markdown(text: UIColor, onGround ground: UIColor) -> UIColor {
        UIColor { traits in MarkdownOnGround.color(text.resolvedColor(with: traits), on: ground.resolvedColor(with: traits), traits: traits) }
    }
}

/// Text on a highlight, worked out once per pair: a dynamic colour resolves on every draw.
private enum MarkdownOnGround {
    private struct Key: Hashable {
        let text: SRGBColor
        let textAlpha: Double
        let drawn: SRGBColor
        let target: Double
    }

    private static let made = OSAllocatedUnfairLock(initialState: [Key: UIColor]())

    static func color(_ text: UIColor, on ground: UIColor, traits: UITraitCollection) -> UIColor {
        let drawn = ground.composited(on: surface(traits))
        var alpha: CGFloat = 1
        text.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        let target: Double = traits.accessibilityContrast == .high ? 75 : 60
        let key = Key(text: SRGBColor(text), textAlpha: Double(alpha), drawn: SRGBColor(drawn), target: target)
        if let known = made.withLock({ $0[key] }) { return known }
        let result: UIColor
        if ReadableColor.contrast(SRGBColor(text.composited(on: drawn)), on: key.drawn) >= target {
            result = text
        } else {
            result = UIColor(ReadableColor.keeping(key.text, on: key.drawn, targetLc: target))
        }
        made.withLock {
            if $0.count > 512 { $0.removeAll() }
            $0[key] = result
        }
        return result
    }

    /// What's under the ground, opaque: the page, and the surface where a theme sets one.
    private static func surface(_ traits: UITraitCollection) -> UIColor {
        let theme = traits.flooTheme
        var under = UIColor.systemBackground.resolvedColor(with: traits)
        if theme.sets(.background) { under = theme.resolved(.background, with: traits).composited(on: under) }
        let surface = traits.flooSurface
        if surface != .background, theme.sets(surface) { under = theme.resolved(surface, with: traits).composited(on: under) }
        return under
    }
}

/// Every colour role Markdown draws with, by what it's for: for a page that shows the colour
/// system, or a theme editor that sets them.
public enum MarkdownColorCatalog {
    public struct Group: Sendable {
        public let title: String
        public let roles: [FlooColorRole]
    }

    public static let groups: [Group] = [
        Group(title: "Text", roles: [
            .markdownText, .markdownSecondaryText, .markdownTertiaryText, .markdownLink, .markdownStrong,
            .markdownSubtitle, .markdownFootnoteText, .markdownMath,
        ]),
        Group(title: "Inline Code and Highlights", roles: [.markdownInlineCode, .markdownInlineCodeFill, .markdownHighlight]),
        Group(title: "Lists", roles: [
            .markdownListMarker, .markdownTaskDone, .markdownTaskOpen, .markdownSymbolBullet, .markdownOnSymbolBullet,
        ]),
        Group(title: "Quotes", roles: [.markdownQuote, .markdownQuoteFill, .markdownQuoteEmphasis]),
        Group(title: "Blocks", roles: [.markdownRule, .markdownImagePlaceholder, .markdownImageFill]),
        Group(title: "Code", roles: [
            .markdownCodeBoxFill, .markdownCodeBoxGutter, .markdownCodeBoxBorder, .markdownCodeBoxSeparator,
            .markdownCodeBoxLineNumber,
        ]),
        Group(title: "Tables", roles: [
            .markdownTableText, .markdownTableHeaderText, .markdownTableHeaderDimmed, .markdownTableSeparator,
            .markdownTableStripe, .markdownTableGitHubBorder, .markdownTableGitHubRow, .markdownTableGitHubAlternateRow,
            .markdownTableGridBorder,
        ]),
        Group(title: "Chips", roles: [.markdownChipFill, .markdownChipText, .markdownChipCount]),
        Group(title: "Bubbles", roles: [.markdownBubbleFill, .markdownBubbleIcon]),
        Group(title: "Named Colours", roles: MarkdownInkName.allCases.map { .markdownInk($0) } + [.markdownAccentText, .markdownPenAccent]),
        Group(title: "Highlights", roles: MarkdownInkName.allCases.map { .markdownHighlight($0) }),
        Group(title: "Callouts", roles: MarkdownCallout.Kind.allCases.map { .markdownCallout($0) }),
    ]
}
