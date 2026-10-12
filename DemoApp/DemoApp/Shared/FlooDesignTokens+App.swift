//
//  FlooDesignTokens+App.swift
//  DemoApp
//
//  What the app adds to FlooDesign's tokens: the packages' motion, built from the
//  tokens' roles (`markdown`, `tiled`, applied at the app's root), and the art
//  direction of the document's own surfaces (their layouts, measured from Craft's),
//  read from the tokens' families. The shared components and their values are
//  FlooDesign's.
//

import SwiftUI
import FlooDesign
import MarkdownView
import MessagingUI

extension FlooDesignTokens.Motion {
    static var markdown: MarkdownMotion {
        MarkdownMotion(feedback: feedbackCurve, layout: .spring(layoutSpring), revealCurve: .easeOut, revealDuration: revealDuration)
    }

    static var tiled: TiledMotion {
        TiledMotion(layout: TiledSelfSizingAnimation(.spring(layoutSpring)), scroll: scrollSpring, feedback: feedbackCurve,
                    revealDuration: revealDuration)
    }
}

extension FlooDesignTokens.Component {
    private typealias Tokens = FlooDesignTokens

    /// The capsule over selected text (Craft's): keys in a row, colours in place.
    enum SelectionToolbar {
        static let height = Tokens.Control.prominentHeight
        static let key = Tokens.Component.Key.size
        /// A key's slot: its disc and a little room on each side.
        static let keySlot = Tokens.Control.standardHeight + 6
        static let chevronWidth: CGFloat = 22
        static let horizontalInset: CGFloat = 5
        static let gap: CGFloat = 10
        /// How far it starts before the text.
        static let leadingOverhang: CGFloat = 14
        static let dividerHeight: CGFloat = 20
        static let swatch: CGFloat = 26
        static let swatchSpacing: CGFloat = 7
        static let hueTrackWidth: CGFloat = 240
        static let hueTrackHeight: CGFloat = 14
        static let hueKnob: CGFloat = 22
        static let shadow = Tokens.Elevation.low
        /// How long the selection rests before it comes.
        static let settleDelay: Duration = .milliseconds(220)
    }

    /// The Mac's format panel (Craft's): sections of tiles, segments and swatches.
    enum FormatPanel {
        static let width: CGFloat = 246
        static let title = Font.system(size: 17, weight: .bold)
        static let titleGap: CGFloat = 14
        static let sectionLabel = Font.system(size: 12, weight: .semibold)
        static let sectionLabelGap = Tokens.Space.sm
        /// Below a section, and above one that follows segments or another kind of section.
        static let sectionGap = Tokens.Space.lg
        static let sectionLead: CGFloat = 18
        static let label = Font.system(size: 15)
        static let segmentGap = Tokens.Space.sm
        /// A tall tile (a layout, a decoration, an image choice).
        static let tallTile: CGFloat = 40
        static let swatch: CGFloat = 32
        static let swatchSpacing = Tokens.Space.sm
        static let swatchColumns = 6
        static let quoteBar = CGSize(width: 3.5, height: 18)
    }

    /// The phone's format sheet (Craft's): pages of rows the same height, so it doesn't jump.
    enum FormatSheet {
        static let inset = Tokens.Component.Sheet.inset
        static let rowSpacing: CGFloat = 6
        /// A row of tiles (lists, indent, decorations) and the style chips.
        static let row = Tokens.Component.Tile.minHeight
        /// Every page's height (the main page's three rows), so the sheet doesn't jump.
        static let page: CGFloat = row * 3 + rowSpacing * 2
        /// The sheet's height before it's measured.
        static let estimate = Tokens.Component.Sheet.grabberArea + Tokens.Component.Sheet.contentGap + page + inset
        /// Between the list tiles and the indent tiles.
        static let groupGap: CGFloat = 11
        static let colorRing: CGFloat = 40
        static let quoteBar = CGSize(width: 3, height: 22)
        static let swatchHeight: CGFloat = 76
        static let swatchRadius = Tokens.Radius.lg
        static let swatchSpacing = Tokens.Space.md
        static let swatchColumns = 6
        static let label = Font.system(size: 17)
    }

    /// The colours over the phone's highlight key (Craft's): text colours, then highlights.
    enum ColorsPopover {
        static let swatch: CGFloat = 34
        static let spacing: CGFloat = 10
        static let inset: CGFloat = 14
        static let cornerRadius = Tokens.Radius.xxl
    }

    /// A block's grey box in the document (Craft's Block decoration).
    enum DecorationBox {
        /// Out past the text's edges.
        static let outset: CGFloat = 10
        /// The text inside it, from its edge.
        static let inset: CGFloat = 10
        static let padding: CGFloat = 10
        static let cornerRadius = Tokens.Radius.sm
        static let fill = Tokens.ColorRole.Surface.decoration
    }
}
