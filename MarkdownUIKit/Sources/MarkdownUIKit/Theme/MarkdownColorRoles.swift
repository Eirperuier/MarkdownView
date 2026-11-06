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

import FlooUIKit
import MarkdownCore
import UIKit

public extension FlooColorRole {
    // Text
    /// Body text and headings.
    static let markdownText = FlooColorRole("markdown.text") { $0[.label] }
    /// Table of contents, a code block's language, what's quieter than the text.
    static let markdownSecondaryText = FlooColorRole("markdown.secondaryText") { $0[.secondaryLabel] }
    /// Bullets and other marks quieter than the text beside them.
    static let markdownTertiaryText = FlooColorRole("markdown.tertiaryText") { _ in .tertiaryLabel }
    /// Links.
    static let markdownLink = FlooColorRole("markdown.link") { $0[.accent] }
    /// Bold text.
    static let markdownStrong = FlooColorRole("markdown.strong") { $0[.accent] }
    /// The second line of an extended heading.
    static let markdownSubtitle = FlooColorRole("markdown.subtitle") { $0[.markdownSecondaryText] }
    /// Footnote definitions.
    static let markdownFootnoteText = FlooColorRole("markdown.footnoteText") { $0[.markdownSecondaryText] }

    // Inline code and highlights
    /// Inline code's text.
    static let markdownInlineCode = FlooColorRole("markdown.inlineCode") { _ in .systemGray }
    /// The ground behind inline code.
    static let markdownInlineCodeFill = FlooColorRole("markdown.inlineCodeFill") { $0[.markdownInlineCode].markdownOpacity(0.1) }
    /// The ground behind `==highlighted==` text: the document palette's yellow.
    static let markdownHighlight = FlooColorRole("markdown.highlight") { _ in MarkdownInk.highlightFill("yellow") ?? .clear }

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

    // Chips
    /// A chip's capsule.
    static let markdownChipFill = FlooColorRole("markdown.chipFill") { _ in UIColor.systemGray.markdownOpacity(0.1) }
    /// A chip's label and placeholder icon.
    static let markdownChipText = FlooColorRole("markdown.chipText") { $0[.markdownSecondaryText] }
    /// A chip's "+2".
    static let markdownChipCount = FlooColorRole("markdown.chipCount") { $0[.markdownChipText].markdownOpacity(0.7) }

    // Bubbles
    /// A topic bubble's capsule.
    static let markdownBubbleFill = FlooColorRole("markdown.bubbleFill") { _ in UIColor.systemGray.markdownOpacity(0.12) }
    /// A topic bubble's icon.
    static let markdownBubbleIcon = FlooColorRole("markdown.bubbleIcon") { $0[.markdownSecondaryText] }

    // Marks named in the text
    /// A pen in the `accent` ink.
    static let markdownPenAccent = FlooColorRole("markdown.penAccent") { $0[.accent] }
    /// Text in the `accent` colour.
    static let markdownAccentText = FlooColorRole("markdown.accentText") { $0[.accent] }
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
    public static var all: [UITrait] {
        UITraitCollection.systemTraitsAffectingColorAppearance + [
            FlooThemeTrait.self, FlooAppearanceTrait.self, FlooOverGlassTrait.self, FlooSurfaceTrait.self,
        ]
    }
}

/// The colours text names: the document palette, a pen's inks and callouts'.
enum MarkdownInk {
    /// Text in a palette name or `#hex`; nil for a token it doesn't know (the text keeps its colour).
    static func text(_ token: String) -> UIColor? {
        if token == "accent" { return .floo(.markdownAccentText) }
        if let hex = MarkdownColorToken.hexValue(token) { return .markdown(named: rgb(hex)) }
        guard let shade = MarkdownColorToken.shades[token] else { return nil }
        return .markdown(named: adaptive(light: shade.light, dark: shade.dark, alpha: 1))
    }

    /// A highlight's ground: the hue, faint (a little stronger in dark).
    static func highlightFill(_ token: String) -> UIColor? {
        if token == "accent" { return .floo(.markdownAccentText).markdownOpacity(0.22) }
        if let hex = MarkdownColorToken.hexValue(token) { return .floo(fill: rgb(hex).markdownOpacity(0.3)) }
        guard let shade = MarkdownColorToken.shades[token] else { return nil }
        return .floo(fill: adaptive(light: shade.dark, dark: shade.dark, alpha: 0.3, darkAlpha: 0.32))
    }

    /// `:color[…]`'s text: only a token it knows takes a colour; any other stays ordinary text.
    static func markedText(_ token: String?) -> UIColor? {
        guard let token else { return nil }
        if token == "accent" { return .floo(.markdownAccentText) }
        return pen(token) ?? text(token)
    }

    /// Named, by meaning, or `#hex`. `accent` and `foreground` are the caller's to read.
    static func pen(_ token: String) -> UIColor? {
        switch token {
        case "red", "negative", "error", "danger": .markdown(named: .systemRed)
        case "orange", "warning": .markdown(named: .systemOrange)
        case "yellow": .markdown(named: .systemYellow)
        case "green", "positive", "success": .markdown(named: .systemGreen)
        case "mint": .markdown(named: .systemMint)
        case "teal": .markdown(named: .systemTeal)
        case "cyan": .markdown(named: .systemCyan)
        case "blue", "info": .markdown(named: .systemBlue)
        case "indigo": .markdown(named: .systemIndigo)
        case "purple": .markdown(named: .systemPurple)
        case "pink": .markdown(named: .systemPink)
        case "brown": .markdown(named: .systemBrown)
        case "gray", "grey": .markdown(named: .systemGray)
        case "secondary": .floo(.markdownSecondaryText)
        case "primary": .floo(.markdownText)
        case let hex where hex.hasPrefix("#"): MarkdownColorToken.hexValue(hex).map { .markdown(named: rgb($0)) }
        default: nil
        }
    }

    /// The ink a mark's own `color` names: the pen's system colours, then the palette, so a
    /// mark and a text in `red` agree. Nil for a token neither knows, which `pen(_:)` may read.
    static func chosenPen(_ token: String) -> UIColor? {
        switch token {
        case "blue": .markdown(named: .systemBlue)
        case "green": .markdown(named: .systemGreen)
        case "orange": .markdown(named: .systemOrange)
        case "purple": .markdown(named: .systemPurple)
        case "gray", "grey": .markdown(named: .systemGray)
        default: text(token)
        }
    }

    static func callout(_ kind: MarkdownCallout.Kind) -> UIColor {
        switch kind {
        case .note: .markdown(named: .systemBlue)
        case .tip: .markdown(named: .systemGreen)
        case .important: .markdown(named: .systemPurple)
        case .warning: .markdown(named: .systemOrange)
        case .caution: .markdown(named: .systemRed)
        }
    }

    private static func rgb(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat, darkAlpha: CGFloat? = nil) -> UIColor {
        let lightColor = rgb(light).withAlphaComponent(alpha)
        let darkColor = rgb(dark).withAlphaComponent(darkAlpha ?? alpha)
        return UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
    }
}
