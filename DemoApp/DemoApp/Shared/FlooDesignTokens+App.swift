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

    /// The Mac's menu over selected text (DocSelectionToolbar): where and when it comes.
    enum SelectionToolbar {
        /// Between the selection's first line and the menu.
        static let gap: CGFloat = 10
        /// How far it starts before the text.
        static let leadingOverhang: CGFloat = 14
        /// How long the selection rests before it comes.
        static let settleDelay: Duration = .milliseconds(220)
    }

    /// The Mac's format panel's own tiles (FlooDesign's menu draws the rest): the quote's
    /// bar, a typeface's tile (Craft's Font: its sample over its name).
    enum FormatPanel {
        static let quoteBar = CGSize(width: 3.5, height: 18)
        static let fontTile: CGFloat = 52
        static let fontSample: CGFloat = 17
        static let fontName = Font.system(size: 11)
    }

    /// The phone's format sheet (Craft's): pages of rows the same height, so it doesn't jump.
    enum FormatSheet {
        static let inset = Tokens.Component.Sheet.inset
        static let rowSpacing: CGFloat = 6
        /// A row of tiles (lists, indent, decorations) and the style chips.
        static let row = Tokens.Component.Tile.minHeight
        /// Every page's height (the main page's three rows), so the sheet doesn't jump.
        static let page: CGFloat = row * 3 + rowSpacing * 2
        /// A table cell's main page: its marks, its alignment, its typeface and format,
        /// its colours and its table.
        static let cellPage: CGFloat = row * 4 + rowSpacing * 3
        /// The fills' page (Craft's six rows of six).
        static let fillHeight: CGFloat = 36
        static let fillSpacing: CGFloat = 6
        static let fillRadius = Tokens.Radius.sm
        static let fillPage: CGFloat = fillHeight * 6 + fillSpacing * 5
        /// The sheet's height before it's measured.
        static let estimate = inset + page + inset
        /// Between the list tiles and the indent tiles.
        static let groupGap: CGFloat = 11
        static let colorRing: CGFloat = 40
        static let quoteBar = CGSize(width: 3, height: 22)
        static let swatchHeight: CGFloat = 76
        static let swatchRadius = Tokens.Radius.lg
        static let swatchSpacing = Tokens.Space.md
        static let swatchColumns = 6
        static let label = Font.system(size: styleLabel)
        /// A style's name in its own type: a title's and a heading's bigger on the styles page.
        static let styleLabel: CGFloat = 17
        static let titleLabelLarge: CGFloat = 21
        static let headingLabelLarge: CGFloat = 19
        static let captionLabel: CGFloat = 15
    }

    /// An edited table cell's handles (Craft's): its ring, and on the table's edges the
    /// bars that pick its column and row and the dots that add one.
    enum TableHandles {
        /// The ring is the cell as MarkdownView draws its fill and its row's stripe: out over
        /// its padding to the middle of the space to the next column, and to its row's edges.
        static let ringOutset = MarkdownTableAppearance.cellOutset
        static let ringRadius = MarkdownTableAppearance.cellCornerRadius
        /// How far a row's cells reach past the table's edges.
        static let rowOutset = MarkdownTableAppearance.rowOutset
        static let columnGrip = CGSize(width: 18, height: 3)
        static let rowGrip = CGSize(width: 3, height: 12)
        static let gripOpacity: Double = 0.45
        /// What a bar or a dot answers to a click or a tap.
        static let target: CGFloat = Tokens.Platform.value(pointer: 20, finger: 32)
        static let dot: CGFloat = Tokens.Platform.value(pointer: 6, finger: 8)
        static let dotHoverScale: CGFloat = 1.6
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

    /// A block's indent in the document (Craft's): a level, any kind of block.
    enum Indent {
        static let step: CGFloat = 26
    }
}
