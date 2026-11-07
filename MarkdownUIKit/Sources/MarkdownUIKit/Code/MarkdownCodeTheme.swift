//
//  MarkdownCodeTheme.swift
//  MarkdownUIKit
//
//  What each colour and motion in a code block is for. Under `.system` every role is what
//  MarkdownView's block draws. A token's colour keeps a light and a dark value from the
//  highlighter's palettes and is made to read on a themed surface, so neither a theme nor light
//  and dark highlight anything again.
//

import FlooUIKit
import MarkdownCore
import UIKit

public extension FlooColorRole {
    /// Code with no token colour.
    static let markdownCodeText = FlooColorRole("markdown.code.text") { $0[.markdownText] }
    /// The box's ground, and the header's over it: white in light, grey in dark. A theme's text
    /// may be light on any colour, where white would hide it: a veil of the text's own colour.
    static let markdownCodeFill = FlooColorRole("markdown.code.fill") { theme in
        guard !theme.sets(.label) else { return theme[.markdownText].markdownOpacity(0.06) }
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemGray.withAlphaComponent(0.1) : UIColor.white.withAlphaComponent(0.5) }
    }
    /// The box's outline.
    static let markdownCodeBorder = FlooColorRole("markdown.code.border") { $0[.markdownInlineCode].markdownOpacity(0.2) }
    /// The lines under the header and over "Show the Remaining".
    static let markdownCodeSeparator = FlooColorRole("markdown.code.separator") { $0[.markdownInlineCode].markdownOpacity(0.2) }
    /// Every other line's ground.
    static let markdownCodeStripe = FlooColorRole("markdown.code.stripe") { $0[.markdownTertiaryText].markdownOpacity(0.1) }
    /// The language's name.
    static let markdownCodeLanguage = FlooColorRole("markdown.code.language") { $0[.markdownSecondaryText] }
    /// A language's letters' tile.
    static let markdownCodeBadgeFill = FlooColorRole("markdown.code.badgeFill") { $0[.markdownSecondaryText].markdownOpacity(0.3) }
    /// A language's letters.
    static let markdownCodeBadgeText = FlooColorRole("markdown.code.badgeText") { _ in .white }
    /// Copy's symbol and label.
    static let markdownCodeAction = FlooColorRole("markdown.code.action") { $0[.markdownText] }
    /// The expand symbol and "Show the Remaining".
    static let markdownCodeSecondaryAction = FlooColorRole("markdown.code.secondaryAction") { theme in
        let secondary = theme[.markdownSecondaryText]
        let halfText = theme[.markdownText].markdownOpacity(0.5)
        // A plain button's own secondary on a phone is half its text, with no blue in it.
        return UIColor { $0.userInterfaceIdiom == .mac ? secondary : halfText }
    }
    /// A bordered button's ground on the Mac.
    static let markdownCodeButtonFill = FlooColorRole("markdown.code.buttonFill") { theme in
        guard !theme.sets(.label) else { return theme[.markdownText].markdownOpacity(0.1) }
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.0757) : UIColor.black.withAlphaComponent(0.075) }
    }
    /// The Preview/Code switch's track.
    static let markdownCodePickerTrack = FlooColorRole("markdown.code.pickerTrack") { $0[.markdownInlineCode].markdownOpacity(0.1) }
    /// Its chosen segment.
    static let markdownCodePickerThumb = FlooColorRole("markdown.code.pickerThumb") { theme in
        guard !theme.sets(.label) else { return theme[.markdownText].markdownOpacity(0.15) }
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.15) : .white }
    }
    /// Its chosen segment's title.
    static let markdownCodePickerText = FlooColorRole("markdown.code.pickerText") { $0[.markdownText] }
    /// The other's.
    static let markdownCodePickerOtherText = FlooColorRole("markdown.code.pickerOtherText") { $0[.markdownSecondaryText] }
}

public extension FlooMotion {
    /// A control answering: a mode switch, the copied mark. MarkdownMotion's `feedback`.
    static let markdownFeedback = FlooMotion(duration: 0.2, curve: .spring(bounce: 0), reduced: .same)
    /// A block taking a new height as a reveal reaches its lines. MarkdownMotion's `layout`.
    static let markdownLayout = FlooMotion(duration: 0.25, curve: .spring(bounce: 0), reduced: .instant)
    /// A whole block arriving in a stream. MarkdownMotion's `reveal`.
    static let markdownBlockReveal = FlooMotion(duration: 0.2, curve: .easeOut, reduced: .same)
    /// Code's characters: they come as they're typed, with no fade.
    static let markdownCodeReveal = FlooMotion(duration: 0, curve: .linear, reduced: .same)
}

/// One colour per token colour pair: a block has a dozen, however many tokens it has.
@MainActor
enum MarkdownCodeTokenColors {
    private struct Pair: Hashable {
        let light: MarkdownCodeColor
        let dark: MarkdownCodeColor
    }

    private static var colors: [Pair: UIColor] = [:]

    static func color(light: MarkdownCodeColor, dark: MarkdownCodeColor) -> UIColor {
        let pair = Pair(light: light, dark: dark)
        if let color = colors[pair] { return color }
        let lightColor = uiColor(light), darkColor = uiColor(dark)
        let color = UIColor.floo(readable: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
        colors[pair] = color
        return color
    }

    private static func uiColor(_ color: MarkdownCodeColor) -> UIColor {
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// Both palettes over the same text, by the runs where neither changes.
    static func runs(_ tokens: MarkdownCodeTokens, upTo length: Int) -> [(range: NSRange, color: UIColor)] {
        var result: [(range: NSRange, color: UIColor)] = []
        var i = 0, j = 0
        let light = tokens.light, dark = tokens.dark
        while i < light.count, j < dark.count {
            let start = max(light[i].range.location, dark[j].range.location)
            let end = min(NSMaxRange(light[i].range), NSMaxRange(dark[j].range), length)
            if end > start {
                result.append((NSRange(location: start, length: end - start), color(light: light[i].color, dark: dark[j].color)))
            }
            if NSMaxRange(light[i].range) <= NSMaxRange(dark[j].range) { i += 1 } else { j += 1 }
        }
        return result
    }
}
