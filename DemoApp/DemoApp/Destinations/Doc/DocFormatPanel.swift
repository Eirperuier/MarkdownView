//
//  DocFormatPanel.swift
//  DemoApp
//
//  The Mac's format panel: Craft's sections (the text styles as tiles, marks, lists
//  and indent as segments, the quote and the box as decorations, the colours) in the
//  anchored panel the math editor uses, opened from the bar's Aa. It acts on the selected
//  blocks, or the block the cursor is in; marks on the selected text, or on the selected
//  blocks' text, and so does the colour. What the blocks take (DocFormattable) decides:
//  the shared sections stay, greyed where none of them takes one, and a kind's own come
//  after (a link's layout, an image's size and fit). The cursor in a table's cell, the
//  panel is the cell's (DocCellStylePanel).
//

import SwiftUI
import DocKit
import FlooDesign

private typealias Tokens = FlooDesignTokens
private typealias Metrics = FlooDesignTokens.Component.FormatPanel

/// The editor's selection, observable.
@MainActor
@Observable
final class DocCursor {
    var selection: DocSelection?
}

/// The format panels' state.
@MainActor
@Observable
final class DocPanels {
    /// The Mac's format panel (-docFormat YES opens with it).
    var showsFormat = UserDefaults.standard.bool(forKey: "docFormat")
    /// The phone's format sheet and its page, over the selected blocks.
    var sheetPage: DocFormatSheetPage?
    /// What Copy Format took, for Paste Format.
    var copiedFormat: DocCopiedFormat?
}

struct DocFormatPanel: View {
    let editor: DocEditor
    let demo: DocDemo

    var body: some View {
        let formatting = formatting
        if let cell = formatting.cell {
            DocCellStylePanel(cell: cell, formatting: formatting, editor: editor)
        } else {
            blocks
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Format")
                .font(Metrics.title)
                .padding(.bottom, Metrics.titleGap)
            // Text first offers its kinds; a link, file or image its layout, after the
            // segments (as Craft orders them).
            // Text styles: how big a block's text is (Craft's six, ⌃1–⌃6).
            if !decorated.isEmpty {
                section(String(localized: "Titles")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        ForEach(DocFormatting.styles.prefix(3), id: \.key) { tile($0) }
                    }
                }
                section(String(localized: "Content")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        ForEach(DocFormatting.styles.suffix(3), id: \.key) { tile($0) }
                    }
                }
            }
            segments
            if formatting.takes(.layout) {
                section(String(localized: "Layout")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        ForEach(DocLayout.allCases, id: \.self) { layout in
                            choice(isOn: editor.blocks.selectedLayouts == [layout], help: layout.title) {
                                editor.blocks.setLayout(layout)
                            } label: {
                                FlooDesignMediaStyleGlyph(layout.style)
                                    .frame(maxWidth: .infinity, minHeight: Metrics.tallTile)
                            }
                        }
                    }
                }
                .padding(.top, Metrics.sectionLead)
            }
            if formatting.takes(.image) {
                section(String(localized: "Image Size")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        imageChoice(String(localized: "Auto"), symbol: "rectangle.center.inset.filled", isOn: editor.blocks.selectedImageSizes == [.auto]) { editor.blocks.setImage(size: .auto) }
                        imageChoice(String(localized: "Large"), symbol: "rectangle", isOn: editor.blocks.selectedImageSizes == [.large]) { editor.blocks.setImage(size: .large) }
                    }
                }
                .padding(.top, Metrics.sectionLead)
                section(String(localized: "Image Display")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        imageChoice(String(localized: "Fill"), symbol: "square.arrowtriangle.4.outward", isOn: editor.blocks.selectedImageFits == [.fill]) { editor.blocks.setImage(fit: .fill) }
                        imageChoice(String(localized: "Fit"), symbol: "arrow.down.and.line.horizontal.and.arrow.up", isOn: editor.blocks.selectedImageFits == [.fit]) { editor.blocks.setImage(fit: .fit) }
                    }
                }
            }
            // Decorations (Craft's): the quote, its bar at the left (Craft's Focus; a kind
            // of text block here), and the grey box any blocks can sit in.
            if !decorated.isEmpty {
                section(String(localized: "Decorations")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        choice(isOn: kindIsOn(.quote), help: String(localized: "Quote")) {
                            formatting.toggleQuote()
                        } label: {
                            HStack(spacing: Tokens.Space.md) {
                                Capsule().frame(width: Metrics.quoteBar.width, height: Metrics.quoteBar.height)
                                Text("Quote").font(Metrics.label)
                            }
                            .frame(maxWidth: .infinity, minHeight: Metrics.tallTile)
                        }
                        .disabled(!formatting.takes(.quote))
                        .accessibilityIdentifier("format-quote")
                        choice(isOn: formatting.isBoxed, help: String(localized: "Block")) {
                            formatting.toggleBox()
                        } label: {
                            Text("Block")
                                .font(Metrics.label)
                                .frame(maxWidth: .infinity, minHeight: Metrics.tallTile - 12)
                                .background(Tokens.ColorRole.Surface.pressed, in: .rect(cornerRadius: Tokens.Radius.sm, style: .continuous))
                                .padding(Tokens.Space.sm - 2)
                        }
                        .disabled(!formatting.takes(.box))
                        .accessibilityIdentifier("format-block")
                    }
                }
                .padding(.top, Metrics.sectionLead)
            }
            if !decorated.isEmpty || formatting.takes(.color) {
                section(String(localized: "Color")) {
                    colors
                        .disabled(markRanges.isEmpty)
                        .opacity(markRanges.isEmpty ? Tokens.State.disabledOpacity : 1)
                }
                .padding(.top, decorated.isEmpty ? Metrics.sectionLead : 0)
            }
            // The blocks' typeface (Craft's Font): pressed again, the document's.
            if !decorated.isEmpty {
                section(String(localized: "Font")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        ForEach(Typeface.blockOrder, id: \.self) { font in
                            choice(isOn: formatting.font == font, help: font.title) {
                                formatting.setFont(font)
                            } label: {
                                VStack(spacing: Tokens.Space.xs) {
                                    Text(font.sample)
                                        .font(.system(size: Metrics.fontSample, design: DocCellLook.design(font)))
                                    Text(font.title)
                                        .font(Metrics.fontName)
                                        .foregroundStyle(Tokens.ColorRole.Content.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: Metrics.fontTile)
                            }
                            .accessibilityIdentifier("format-font-\(font.rawValue)")
                        }
                    }
                    .disabled(!formatting.takes(.typeface))
                }
            }
        }
        .frame(width: Metrics.width)
    }

    // MARK: Colour

    /// Craft's colours: none, the palette, and any colour (the system's picker); the
    /// one the text has is ringed.
    private var colors: some View {
        let ranges = markRanges
        let current = editor.common(.color, over: ranges)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.swatchSpacing), count: Metrics.swatchColumns),
                         spacing: Metrics.swatchSpacing) {
            swatch(nil, title: String(localized: "Default"), isOn: current == nil, ranges: ranges)
            ForEach(DocColors.palette, id: \.token) { item in
                swatch(item.token, title: item.title, isOn: current == .color(item.token), ranges: ranges)
            }
            custom(current, ranges: ranges)
        }
    }

    /// Any colour: Craft's rainbow ring, the colour inside it once one is picked
    /// (FlooDesign's colour well, the system's picker).
    private func custom(_ current: Mark?, ranges: [(block: DocBlockID, range: Range<Int>)]) -> some View {
        let picked: String? = if case .color(let token)? = current, token.hasPrefix("#") { token } else { nil }
        return FlooDesignColorWell(Circle(), title: String(localized: "Other Color"), picked: picked.map(DocColors.swatch) ?? Tokens.ColorRole.Surface.canvas,
                                   selection: Binding {
            picked.map(DocColors.swatch) ?? .primary
        } set: { color in
            editor.set(.color, to: .color(DocColors.hex(color)), over: ranges, merge: editor.colorMergeKey(over: ranges))
        })
        .frame(width: Metrics.swatch, height: Metrics.swatch)
        .accessibilityIdentifier("color-custom")
    }

    private func swatch(_ token: String?, title: String, isOn: Bool, ranges: [(block: DocBlockID, range: Range<Int>)]) -> some View {
        Button {
            editor.endColorChanges()
            editor.set(.color, to: token.map(Mark.color), over: ranges)
        } label: {
            FlooDesignSwatch(Circle(), fill: token.map(DocColors.swatch) ?? Tokens.ColorRole.Surface.canvas, isOn: isOn,
                             chosen: .ring(Tokens.ColorRole.Content.primary))
                .frame(width: Metrics.swatch, height: Metrics.swatch)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: Circle()))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("color-\(token ?? "none")")
    }

    private var segments: some View {
        VStack(spacing: Metrics.segmentGap) {
            FlooDesignSegments(items: DocFormatting.marks.map { item in
                .init(id: item.id, symbol: item.symbol, title: item.title, isOn: markIsOn(item.mark), isEnabled: !markRanges.isEmpty) {
                    formatting.toggle(item.mark)
                }
            })
            FlooDesignSegments(items: DocFormatting.lists.map { item in
                .init(id: item.id, symbol: item.symbol, title: item.title, isOn: kindIsOn(item.kind), isEnabled: formatting.takes(.list)) {
                    formatting.toggleList(item.kind)
                }
            })
            FlooDesignSegments(items: [
                .init(id: "outdent", symbol: "decrease.indent", title: String(localized: "Outdent"), isOn: false, isEnabled: canIndent(-1)) {
                    formatting.indent(by: -1)
                },
                .init(id: "indent", symbol: "increase.indent", title: String(localized: "Indent"), isOn: false, isEnabled: canIndent(1)) {
                    formatting.indent(by: 1)
                },
            ])
        }
    }

    // MARK: What it acts on

    private var formatting: DocFormatting { DocFormatting(editor: editor) }
    private var decorated: [DocBlock] { formatting.decorated }
    private var markRanges: [(block: DocBlockID, range: Range<Int>)] { formatting.markRanges }
    private func markIsOn(_ mark: Mark) -> Bool { formatting.markIsOn(mark) }
    private func kindIsOn(_ kind: BlockKind) -> Bool { formatting.kindIsOn(kind) }
    private func canIndent(_ delta: Int) -> Bool { formatting.canIndent(delta) }

    // MARK: Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionLabelGap) {
            Text(title)
                .font(Metrics.sectionLabel)
                .foregroundStyle(Tokens.ColorRole.Content.secondary)
            content()
        }
        .padding(.bottom, Metrics.sectionGap)
    }

    /// A choice on a soft tile, outlined in the tint when it's in use.
    private func choice(isOn: Bool, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action, label: label)
            .buttonStyle(FlooDesignTileButtonStyle(isOn: isOn))
            .help(help)
    }

    /// An image's size or fit: its name, and its symbol at the right (Craft's).
    private func imageChoice(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        choice(isOn: isOn, help: title, action: action) {
            HStack {
                Text(title).font(Metrics.label)
                Spacer(minLength: Tokens.Space.xs)
                Image(systemName: symbol).font(Metrics.label)
            }
            .padding(.horizontal, Tokens.Space.md)
            .frame(maxWidth: .infinity, minHeight: Metrics.tallTile)
        }
    }

    private func tile(_ style: (key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind)) -> some View {
        let isOn = kindIsOn(style.kind)
        return Button {
            formatting.setTextStyle(style.kind)
        } label: {
            Text(style.title)
                .font(.system(size: style.size, weight: style.weight))
                .frame(maxWidth: .infinity, minHeight: Tokens.Component.Tile.minHeight)
        }
        .buttonStyle(FlooDesignTileButtonStyle(isOn: isOn))
        .disabled(!formatting.takes(.textStyle))
        .help("⌃\(style.key)")
        .accessibilityIdentifier("format-style-\(style.key)")
    }
}
