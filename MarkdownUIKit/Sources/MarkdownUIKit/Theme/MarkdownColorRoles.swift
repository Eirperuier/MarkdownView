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
import UIKit

public extension FlooColorRole {
    // Text
    /// Body text and headings.
    static let markdownText = FlooColorRole("markdown.text") { $0[.label] }
    /// Task and ordered list markers, table of contents, a code block's language.
    static let markdownSecondaryText = FlooColorRole("markdown.secondaryText") { $0[.secondaryLabel] }
    /// Bullets and other marks quieter than the text beside them.
    static let markdownTertiaryText = FlooColorRole("markdown.tertiaryText") { _ in .tertiaryLabel }
    /// Links, and what's drawn in the tint: a quote's bar, a checked box.
    static let markdownLink = FlooColorRole("markdown.link") { $0[.accent] }
}

public extension UIColor {
    /// A colour Markdown names (`{blue}`, a pen's ink) made to read on the theme's surface.
    /// As it is under a theme that leaves the surface the system's.
    static func markdown(named color: UIColor) -> UIColor {
        .floo(readable: color)
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
