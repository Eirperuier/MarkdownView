//
//  FlooDesignTokens.swift
//  DemoApp
//
//  The app's visual decisions in one place, after Matrix HQ's `MatrixDesignTokens`: a
//  token file, not a component library. Views own composition and behaviour; this file
//  owns the numbers and colours they share, by family (state, colour roles, opacity,
//  type, space, controls, radius, border, elevation, motion), then per component, each
//  component's values read from the families.
//
//  Unlike Matrix's (macOS only, AppKit colours), it serves iOS and the Mac (Catalyst)
//  alike: colours are UIKit's semantic ones, so they follow light and dark; type is
//  text styles, so it follows Dynamic Type; the few values that differ between a
//  pointer and a finger say so (`Platform`). Sizes are in iOS points: the Mac's idiom
//  scales them by 0.77, which lands on Matrix's Mac sizes (17 → 13).
//
//  Content type (the document's own fonts and rhythm) stays with the content
//  (DocTypography): this file is the chrome around it.
//

import SwiftUI
import UIKit
import MarkdownView
import MessagingUI

enum FlooDesignTokens {
    enum Platform {
        /// A pointer (the Mac): hover states, smaller targets, tooltips.
        static let isPointer: Bool = {
            #if targetEnvironment(macCatalyst)
            true
            #else
            false
            #endif
        }()
    }

    enum Accessibility {
        @MainActor static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    }

    // MARK: State

    enum State {
        static let disabledOpacity: Double = 0.42
        static let pressedOpacity: Double = 0.12
        static let hoverOpacity: Double = 0.06
        static let selectedOpacity: Double = 0.12
        static let focusOpacity: Double = 0.55
    }

    // MARK: Colour

    enum ColorRole {
        enum Content {
            static let primary = Color.primary
            static let secondary = Color.secondary
            static let tertiary = Color(uiColor: .tertiaryLabel)
            static let disabled = Color.secondary.opacity(State.disabledOpacity)
            /// On the accent's fill (a key that's on).
            static let onAccent = Color.white
        }

        enum Surface {
            static let canvas = Color(uiColor: .systemBackground)
            static let raised = Color(uiColor: .secondarySystemBackground)
            /// A control's resting fill (a tile, a segment group).
            static let control = Color.primary.opacity(Opacity.faint)
            static let selected = Color.accentColor.opacity(State.selectedOpacity)
            static let hover = Color.primary.opacity(State.hoverOpacity)
            static let pressed = Color.primary.opacity(State.pressedOpacity)
            /// A block's grey box in the document (Craft's Block decoration).
            static let decoration = Color.primary.opacity(0.04)
        }

        enum Accent {
            static let primary = Color.accentColor
            static let subtle = Color.accentColor.opacity(State.selectedOpacity)
            /// The outline of a chosen tile.
            static let outline = Color.accentColor.opacity(State.focusOpacity)
        }
    }

    // MARK: Opacity, layers

    enum Opacity {
        static let faint: Double = 0.06
        static let subtle: Double = 0.1
        static let muted: Double = 0.38
        static let strong: Double = 0.72
    }

    // MARK: Type (chrome)

    enum Typography {
        struct Role: Sendable {
            let style: Font.TextStyle
            let weight: Font.Weight

            var font: Font { .system(style, weight: weight) }
        }

        static let panelTitle = Role(style: .headline, weight: .bold)
        static let sectionLabel = Role(style: .caption, weight: .semibold)
        static let controlLabel = Role(style: .subheadline, weight: .medium)
        static let body = Role(style: .subheadline, weight: .regular)
        static let metadata = Role(style: .caption, weight: .regular)
        static let tooltip = Role(style: .caption, weight: .medium)
    }

    // MARK: Space, layout

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    enum Control {
        static let compactHeight: CGFloat = 32
        static let standardHeight: CGFloat = 36
        static let prominentHeight: CGFloat = 44
        /// The least a target may be: a finger's 44, a pointer's 28.
        static let minimumHitTarget: CGFloat = Platform.isPointer ? 28 : 44
    }

    enum Icon {
        static let inline: CGFloat = 11
        static let standard: CGFloat = 15
        static let toolbar: CGFloat = 17
    }

    // MARK: Shape

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Border {
        static let hairline: CGFloat = 0.5
        static let standard: CGFloat = 1
        static let subtle = Color.primary.opacity(0.08)
        static let separator = Color(uiColor: .separator)
    }

    enum Elevation {
        struct Shadow: Sendable {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }

        /// A toolbar resting on the page.
        static let low = Shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        /// A panel over the page.
        static let high = Shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

    // MARK: Motion

    /// Every animation is one of these roles; the packages get theirs from here
    /// (`markdown`, `tiled`, applied at the app's root). Reduce Motion drops what moves
    /// things (feedback, layout); fades stay.
    enum Motion {
        /// A control answering: a key, a mode switch, a selection's marks.
        static let feedbackCurve: Animation = .snappy(duration: 0.18)
        /// Something taking a new size or place, and what it moves: a block's layout,
        /// the rows after it, a block dropped. Craft's: about a third of a second, most
        /// of the way early.
        static let layoutSpring = Spring(duration: 0.34, bounce: 0)
        /// A list scrolling itself (to a block, to the caret).
        static let scrollSpring = Spring(duration: 0.5, bounce: 0)
        /// Something appearing (a panel, streamed text), and going.
        static let revealDuration: TimeInterval = 0.20
        static let dismissDuration: TimeInterval = 0.13
        /// A floating surface grows from this scale toward its trigger.
        static let revealScale: CGFloat = 0.975

        @MainActor static var feedback: Animation? { Accessibility.reduceMotion ? nil : feedbackCurve }
        @MainActor static var layout: Animation? { Accessibility.reduceMotion ? nil : .spring(layoutSpring) }
        static var reveal: Animation { .easeOut(duration: revealDuration) }
        static var dismiss: Animation { .easeIn(duration: dismissDuration) }

        static var markdown: MarkdownMotion {
            MarkdownMotion(feedback: feedbackCurve, layout: .spring(layoutSpring), revealCurve: .easeOut, revealDuration: revealDuration)
        }

        static var tiled: TiledMotion {
            TiledMotion(layout: TiledSelfSizingAnimation(.spring(layoutSpring)), scroll: scrollSpring, feedback: feedbackCurve,
                        revealDuration: revealDuration)
        }
    }

    // MARK: Components

    enum Component {
        /// A panel anchored to its trigger (the format panel, the math editor).
        enum FloatingPanel {
            static let anchorGap = Space.sm
            static let windowMargin = Space.md
            static let cornerRadius = Radius.lg
            static let contentInset = EdgeInsets(top: Space.md, leading: Space.sm, bottom: Space.md, trailing: Space.sm)
            static let roomyInset = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
            static let border = Border.hairline
            static let shadow = Elevation.high
        }

        /// The capsule over selected text (Craft's): keys in a row, colours in place.
        enum SelectionToolbar {
            static let height = Control.prominentHeight
            static let key = Control.standardHeight
            /// A key's slot: its disc and a little room on each side.
            static let keySlot = Control.standardHeight + 6
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
            static let shadow = Elevation.low
            /// How long the selection rests before it comes.
            static let settleDelay: Duration = .milliseconds(220)
        }

        /// A colour to pick: a square for a highlight, a circle for text.
        enum Swatch {
            static let cornerRadius = Radius.sm
            static let border = Border.hairline
            static let rainbowWidth: CGFloat = 2.5
            static let rainbowInset: CGFloat = 3
        }

        /// A choice on a soft tile (the format panel's styles, layouts).
        enum Tile {
            static let cornerRadius = Radius.md
            static let minHeight = Control.standardHeight
            static let spacing: CGFloat = 6
            static let outline = Border.standard
        }

        /// Keys joined in one rounded group with hairlines between them.
        enum Segments {
            static let height = Control.compactHeight
            static let cornerRadius = Radius.md
            static let dividerHeight: CGFloat = 18
        }

        /// The Mac's format panel (Craft's): sections of tiles, segments and swatches.
        enum FormatPanel {
            static let width: CGFloat = 246
            static let title = Font.system(size: 17, weight: .bold)
            static let titleGap: CGFloat = 14
            static let sectionLabel = Font.system(size: 12, weight: .semibold)
            static let sectionLabelGap = Space.sm
            /// Below a section, and above one that follows segments or another kind of section.
            static let sectionGap = Space.lg
            static let sectionLead: CGFloat = 18
            static let label = Font.system(size: 15)
            static let segmentGap = Space.sm
            /// A tall tile (a layout, a decoration, an image choice).
            static let tallTile: CGFloat = 40
            static let swatch: CGFloat = 32
            static let swatchSpacing = Space.sm
            static let swatchColumns = 6
            static let chosenRing: CGFloat = 2.5
            static let rainbowWidth: CGFloat = 3.5
            static let quoteBar = CGSize(width: 3.5, height: 18)
        }

        /// The phone's format sheet (Craft's): over the selected blocks, or in the
        /// keyboard's place. Pages of rows the same height, so it doesn't jump.
        enum FormatSheet {
            static let cornerRadius: CGFloat = 28
            static let margin = Space.sm
            static let inset = Space.md
            static let grabber = CGSize(width: 36, height: 5)
            static let grabberArea: CGFloat = 18
            static let rowSpacing: CGFloat = 6
            /// A row of tiles (lists, indent, decorations) and the style chips.
            static let row: CGFloat = 50
            /// Every page's height (the main page's three rows), so the sheet doesn't jump.
            static let page: CGFloat = row * 3 + rowSpacing * 2
            static let tileSpacing: CGFloat = 5
            /// Between the list tiles and the indent tiles.
            static let groupGap: CGFloat = 11
            static let tileRadius = Radius.md
            static let outline: CGFloat = 1.5
            static let colorRing: CGFloat = 40
            static let swatchHeight: CGFloat = 76
            static let swatchRadius = Radius.lg
            static let swatchSpacing = Space.md
            static let swatchColumns = 6
            static let chosenRing: CGFloat = 3
            static let label = Font.system(size: 17)
            static let shadow = Elevation.high
        }

        /// The colours over the phone's highlight key (Craft's): text colours, then highlights.
        enum ColorsPopover {
            static let swatch: CGFloat = 34
            static let spacing: CGFloat = 10
            static let inset: CGFloat = 14
            static let cornerRadius: CGFloat = 26
        }

        /// A block's grey box in the document (Craft's Block decoration).
        enum DecorationBox {
            /// Out past the text's edges.
            static let outset: CGFloat = 10
            /// The text inside it, from its edge.
            static let inset: CGFloat = 10
            static let padding: CGFloat = 10
            static let cornerRadius = Radius.sm
            static let fill = ColorRole.Surface.decoration
        }
    }
}
