//
//  DocTokens.swift
//  DemoApp
//
//  The document's own values. Its text colours and its animations are floo-uikit's
//  (`FlooColorRole`, `FlooMotion`); its spaces, sizes and corners are its layouts',
//  until the UIKit-first dockit has them in its views.
//

import FlooUIKit
import MarkdownUIKit
import MarkdownView
import SwiftUI
import UIKit

enum DocTokens {
    enum Platform {
        static let isPointer: Bool = {
            #if targetEnvironment(macCatalyst)
            true
            #else
            false
            #endif
        }()

        static func value<T>(pointer: T, finger: T) -> T { isPointer ? pointer : finger }
    }

    enum State {
        static let selectedOpacity: Double = 0.12
        static let pressedOpacity: Double = 0.12
    }

    enum Opacity {
        static let faint: Double = 0.06
        static let strong: Double = 0.72
    }

    enum ColorRole {
        enum Content {
            static let primary = Color(uiColor: .floo(.label))
            static let secondary = Color(uiColor: .floo(.secondaryLabel))
            static let tertiary = Color(uiColor: .floo(.disabledLabel))
            static let onAccent = Color(uiColor: .floo(.markdownPage))
        }

        enum Surface {
            static let canvas = Color(uiColor: .floo(.markdownPage))
            static let raised = Color(uiColor: .floo(.markdownPageRaised))
            static let control = Color(uiColor: .floo(.markdownBlockControl))
            static let selected = Color(uiColor: .floo(.markdownBlockSelected))
            static let pressed = Color(uiColor: .floo(.markdownBlockPressed))
            static let decoration = Color(uiColor: .floo(.markdownBlockDecoration))
        }

        enum Action {
            static let format = Color(uiColor: .floo(.markdownFormatAction))
            static let neutral = Color(uiColor: .floo(.markdownNeutralAction))
            static let destructive = Color(uiColor: .floo(.destructive))
        }

        /// The document's selection and focus are the text's colour.
        enum Accent {
            static let primary = Color(uiColor: .floo(.label))
            static let subtle = Color(uiColor: .floo(.markdownBlockSelected))
        }
    }

    enum UIKitColor {
        static var canvas: UIColor { .floo(.markdownPage) }
        static var primary: UIColor { .floo(.label) }
        static var separator: UIColor { .floo(.separator) }
        static var accent: UIColor { .floo(.label) }
        static var dimmed: UIColor { UIColor { UIColor.floo(.markdownPage).resolvedColor(with: $0).withAlphaComponent(0.65) } }

        static func elevated(in traits: UITraitCollection) -> UIColor {
            UIColor.floo(.markdownPage).resolvedColor(with: traits.modifyingTraits { $0.userInterfaceLevel = .elevated })
        }
    }

    enum Typography {
        struct Role {
            let style: Font.TextStyle
            let weight: Font.Weight
            var font: Font { .system(style, weight: weight) }
        }

        static let panelTitle = Role(style: .headline, weight: .bold)
        static let sectionLabel = Role(style: .caption, weight: .semibold)
        static let body = Role(style: .subheadline, weight: .regular)
        static let metadata = Role(style: .caption, weight: .regular)
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Control {
        static let compactHeight: CGFloat = 32
        static let standardHeight: CGFloat = 36
        static let prominentHeight: CGFloat = 44
        static let minimumHitTarget: CGFloat = Platform.value(pointer: 28, finger: 44)
    }

    enum Icon {
        static let inline: CGFloat = 11
        static let compact: CGFloat = 13
        static let standard: CGFloat = 15
        static let toolbar: CGFloat = 17
        static let prominent: CGFloat = 22
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        static let xxl: CGFloat = 26
    }

    enum Border {
        static let hairline: CGFloat = 0.5
        static let standard: CGFloat = 1
        static let focus: CGFloat = 2
        static let subtle = Color.primary.opacity(0.08)
        static let separator = Color(uiColor: .floo(.separator))
    }

    enum Motion {
        static var feedbackCurve: Animation { FlooMotion.press.swiftUI ?? .linear(duration: 0) }
        static let layoutSpring = AppMotion.layoutSpring
        /// The app's list scroll (`TiledMotion`), which what follows a scroll waits out.
        static let scrollSpring = AppMotion.scrollSpring
        static var revealDuration: TimeInterval { FlooMotion.appear.duration }
        @MainActor static var layout: Animation? { AppMotion.layout }
        @MainActor static var step: Animation? { FlooMotion.floatingResize.swiftUI }
        static var reveal: Animation? { FlooMotion.appear.swiftUI }
        static var dismiss: Animation? { FlooMotion.disappear.swiftUI }
        @MainActor static var revealStartScale: CGFloat { UIAccessibility.isReduceMotionEnabled ? 1 : 0.975 }

        static var markdown: MarkdownMotion { AppMotion.markdown }
    }

    enum Component {
        enum FloatingPanel {
            static let roomyInset = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        }

        enum ActionMenu {
            enum Controls {
                static let label = Font.system(size: 15)
                static let tallTile: CGFloat = 40
            }
        }

        enum Menu {
            static let iconSize: CGFloat = Platform.value(pointer: 14, finger: 16)
            static let gap: CGFloat = 6
        }

        enum Tile {
            static let cornerRadius = Radius.md
            static let minHeight: CGFloat = Platform.value(pointer: Control.standardHeight, finger: 50)
            static let spacing: CGFloat = Platform.value(pointer: 6, finger: 5)
        }

        enum Sheet {
            static let inset = Space.md
        }

        enum Option {
            static let sectionGap: CGFloat = 6
            static let sectionSpacing: CGFloat = 10
        }

        enum TextField {
            static let minHeight = Control.compactHeight
            static let cornerRadius = Radius.md
        }

        enum DropIndicator {
            static let thickness = Border.focus
            static let overhang: CGFloat = 6
        }

        enum DragPreview {
            static let cornerRadius: CGFloat = 8
        }

        enum MediaCard {
            static let cornerRadius: CGFloat = 8
            static let panel = ColorRole.Surface.raised
            static let cardHeight: CGFloat = 222
            static let smallLinkHeight: CGFloat = 36
            static let regularLinkHeight: CGFloat = 88
            static let smallFileHeight: CGFloat = 42
            static let regularFileHeight: CGFloat = 92
        }

        enum KeyboardBar {
            static let height: CGFloat = 46
            static let keySize = CGSize(width: 50, height: 40)
            static let keyRadius: CGFloat = 12
            static let symbolSize: CGFloat = 19
            static let inset: CGFloat = 6
        }
    }
}

extension DocTokens.Component {
    private typealias Tokens = DocTokens

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
        static let target: CGFloat = Tokens.Platform.value(pointer: 14, finger: 24)
        /// The edited cell's ⋮: what it answers to is what its press fills.
        static let menuButton = CGSize(width: 16, height: 24)
        /// Its glyph out over the cell's padding, where it has always stood.
        static let menuButtonOffset: CGFloat = 6
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
