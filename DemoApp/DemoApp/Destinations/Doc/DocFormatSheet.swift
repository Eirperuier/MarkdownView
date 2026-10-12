//
//  DocFormatSheet.swift
//  DemoApp
//
//  The phone's format sheet, Craft's: a system sheet over the selected blocks, from the
//  selection bar's Style or the keyboard bar's Aa (which selects the caret's block).
//  Its pages:
//
//  - main: a few styles and More…; lists and indent; the quote and the box, the colour,
//    and … ;
//  - styles: the six text styles (More…);
//  - colours: the text's own colour, the palette, and any colour (the system's picker);
//  - more (…): bold, italic, strikethrough, code; Copy Format and Paste Format.
//
//  Every page but the main one is a sheet of its own over it; a choice on it takes it
//  back to the main one. The sheets close with their own grabber and pull: no gestures
//  of ours over them. What DocKit can't carry yet (alignment, fonts, pages) isn't offered.
//
//  The colours over the keyboard bar's highlight key, Craft's: none, the text colours
//  and any; the highlights and any.
//

import SwiftUI
import UIKit
import DocKit
import FlooDesign

private typealias Tokens = FlooDesignTokens
private typealias Metrics = FlooDesignTokens.Component.FormatSheet

enum DocFormatSheetPage: Hashable, Identifiable {
    case main, styles, colors, more

    var id: Self { self }
}

struct DocFormatSheet: View {
    let editor: DocEditor

    private var formatting: DocFormatting { DocFormatting(editor: editor, caretTakesBlock: true) }
    private var page: DocFormatSheetPage { editor.panels.sheetPage ?? .main }

    var body: some View {
        sheet(.main)
            .sheet(item: Binding(get: { page == .main ? nil : page }, set: { if $0 == nil { go(.main) } })) { page in
                sheet(page).flooDesignSizedSheet(estimate: Metrics.estimate)
            }
    }

    private func sheet(_ shown: DocFormatSheetPage) -> some View {
        Group {
            switch shown {
            case .main: main
            case .styles: styles
            case .colors: colors
            case .more: more
            }
        }
        .frame(height: Metrics.page, alignment: .top)
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, Metrics.inset)
    }

    private func go(_ page: DocFormatSheetPage) {
        editor.panels.sheetPage = page
    }

    // MARK: Main

    private var main: some View {
        let formatting = formatting
        return VStack(spacing: Metrics.rowSpacing) {
            HStack(spacing: Tokens.Component.Tile.spacing) {
                ForEach(shortStyles, id: \.key) { style in
                    chip(isOn: formatting.kindIsOn(style.kind), identifier: "sheet-style-\(style.key)") {
                        formatting.setTextStyle(style.kind)
                    } label: {
                        styleLabel(style)
                    }
                }
                FlooDesignDivider(.vertical, length: Metrics.row - Tokens.Space.xl)
                Button { go(.styles) } label: {
                    Text("More…")
                        .font(Metrics.label)
                        .foregroundStyle(Tokens.ColorRole.Content.secondary)
                        .frame(maxWidth: .infinity, minHeight: Metrics.row)
                }
                .buttonStyle(FlooDesignPlainButtonStyle())
                .accessibilityIdentifier("sheet-more-styles")
            }
            .disabled(formatting.targets.isEmpty)
            HStack(spacing: Tokens.Component.Tile.spacing) {
                ForEach(DocFormatting.lists, id: \.id) { item in
                    tile(isOn: formatting.kindIsOn(item.kind), identifier: "sheet-\(item.id)") {
                        formatting.toggleList(item.kind)
                    } label: {
                        Image(systemName: item.symbol).font(.system(size: Tokens.Icon.toolbar))
                    }
                    .disabled(formatting.targets.isEmpty)
                    .accessibilityLabel(item.title)
                }
                Spacer().frame(width: Metrics.groupGap - Tokens.Component.Tile.spacing * 2)
                tile(isOn: false, identifier: "sheet-outdent") { formatting.indent(by: -1) } label: {
                    Image(systemName: "decrease.indent").font(.system(size: Tokens.Icon.toolbar))
                }
                .disabled(!formatting.canIndent(-1))
                .accessibilityLabel(Text("Outdent"))
                tile(isOn: false, identifier: "sheet-indent") { formatting.indent(by: 1) } label: {
                    Image(systemName: "increase.indent").font(.system(size: Tokens.Icon.toolbar))
                }
                .disabled(!formatting.canIndent(1))
                .accessibilityLabel(Text("Indent"))
            }
            HStack(spacing: Tokens.Component.Tile.spacing) {
                tile(isOn: formatting.kindIsOn(.quote), identifier: "sheet-quote") { formatting.toggleQuote() } label: {
                    HStack(spacing: Tokens.Space.md) {
                        Capsule().frame(width: Metrics.quoteBar.width, height: Metrics.quoteBar.height)
                        Text("Quote").font(Metrics.label)
                    }
                }
                .disabled(formatting.targets.isEmpty)
                .frame(maxWidth: .infinity)
                tile(isOn: formatting.isBoxed, identifier: "sheet-block") { formatting.toggleBox() } label: {
                    Text("Block")
                        .font(Metrics.label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Tokens.ColorRole.Surface.pressed, in: .rect(cornerRadius: Tokens.Radius.sm, style: .continuous))
                        .padding(Tokens.Space.sm - 2)
                }
                .disabled(formatting.decorated.isEmpty)
                .frame(maxWidth: .infinity)
                Button { go(.colors) } label: {
                    FlooDesignRainbowSwatch(Circle(),
                                            picked: formatting.color.flatMap(Self.token).map(DocColors.swatch) ?? Tokens.ColorRole.Content.primary)
                        .frame(width: Metrics.colorRing, height: Metrics.colorRing)
                        .frame(width: Metrics.row + Tokens.Space.md, height: Metrics.row)
                }
                .buttonStyle(FlooDesignPlainButtonStyle())
                .disabled(formatting.markRanges.isEmpty)
                .accessibilityLabel(Text("Text Color"))
                .accessibilityIdentifier("sheet-colors")
                tile(isOn: false, identifier: "sheet-more") { go(.more) } label: {
                    Image(systemName: "ellipsis").font(.system(size: Tokens.Icon.toolbar, weight: .semibold))
                }
                .frame(width: Metrics.row + Tokens.Space.sm)
                .accessibilityLabel(Text("More"))
            }
        }
    }

    /// The main page's styles: the two most used, and the one the blocks have if it's
    /// another (Craft's).
    private var shortStyles: [(key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind)] {
        let styles = DocFormatting.styles
        let common = styles.filter { $0.kind == .heading(level: 3) || $0.kind == .paragraph }
        guard let current = styles.first(where: { formatting.kindIsOn($0.kind) }), !common.contains(where: { $0.key == current.key }) else { return common }
        return [current] + common
    }

    // MARK: Styles

    private var styles: some View {
        let formatting = formatting
        let rows = [Array(DocFormatting.styles.prefix(3)), Array(DocFormatting.styles.suffix(3))]
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { FlooDesignDivider() }
                HStack(spacing: Tokens.Component.Tile.spacing) {
                    ForEach(rows[index], id: \.key) { style in
                        chip(isOn: formatting.kindIsOn(style.kind), identifier: "sheet-style-\(style.key)") {
                            formatting.setTextStyle(style.kind)
                            go(.main)
                        } label: {
                            styleLabel(style, large: true)
                        }
                    }
                }
                .frame(height: (Metrics.page - Tokens.Border.hairline) / 2)
            }
        }
        .disabled(formatting.targets.isEmpty)
    }

    /// A style's name in its own type (Craft's: titles bigger and bolder, the caption smaller and quieter).
    private func styleLabel(_ style: (key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind), large: Bool = false) -> some View {
        let size: CGFloat = switch style.kind {
        case .heading(level: 1): large ? Metrics.titleLabelLarge : Metrics.styleLabel
        case .heading(level: 2): large ? Metrics.headingLabelLarge : Metrics.styleLabel
        case .caption: Metrics.captionLabel
        default: Metrics.styleLabel
        }
        return Text(style.title)
            .font(.system(size: size, weight: style.weight))
            .foregroundStyle(style.kind == .caption ? Tokens.ColorRole.Content.secondary : Tokens.ColorRole.Content.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: Colours

    private var colors: some View {
        let formatting = formatting
        let current = formatting.color
        let picked: String? = if case .color(let token)? = current, token.hasPrefix("#") { token } else { nil }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.swatchSpacing), count: Metrics.swatchColumns),
                         spacing: Metrics.swatchSpacing) {
            swatch(fill: Tokens.ColorRole.Content.primary, title: String(localized: "Default"), isOn: current == nil, identifier: "sheet-color-none") {
                formatting.setColor(nil)
                go(.main)
            }
            ForEach(DocColors.palette, id: \.token) { item in
                swatch(fill: DocColors.swatch(item.token), title: item.title, isOn: current == .color(item.token), identifier: "sheet-color-\(item.token)") {
                    formatting.setColor(item.token)
                    go(.main)
                }
            }
            Button {
                DocColorPicking.present(from: editor, initial: picked.map(DocColors.swatch) ?? .primary) { color in
                    formatting.pickColor(color)
                }
            } label: {
                FlooDesignRainbowSwatch(RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous),
                                        picked: picked.map(DocColors.swatch) ?? Tokens.ColorRole.Content.primary)
                    .frame(height: Metrics.swatchHeight)
            }
            .buttonStyle(FlooDesignPlainButtonStyle(in: RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous)))
            .accessibilityLabel(Text("Other Color"))
            .accessibilityIdentifier("sheet-color-custom")
        }
        .disabled(formatting.markRanges.isEmpty)
    }

    private func swatch(fill: Color, title: String, isOn: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous)
        return Button(action: action) {
            FlooDesignSwatch(shape, fill: fill, isOn: isOn, chosen: .ring(fill))
                .frame(height: Metrics.swatchHeight)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: More

    private var more: some View {
        let formatting = formatting
        let copied = editor.panels.copiedFormat
        return VStack(spacing: Metrics.rowSpacing) {
            HStack(spacing: Tokens.Component.Tile.spacing) {
                ForEach(DocFormatting.marks, id: \.id) { item in
                    chip(isOn: formatting.markIsOn(item.mark), identifier: "sheet-\(item.id)") {
                        formatting.toggle(item.mark)
                    } label: {
                        Image(systemName: item.symbol).font(.system(size: Tokens.Icon.toolbar, weight: .medium))
                    }
                    .accessibilityLabel(item.title)
                }
            }
            .disabled(formatting.markRanges.isEmpty)
            HStack(spacing: Tokens.Component.Tile.spacing) {
                tile(isOn: false, identifier: "sheet-copy-format") {
                    editor.panels.copiedFormat = formatting.format
                } label: {
                    Label("Copy Format", systemImage: "doc.on.clipboard").font(Metrics.label)
                }
                .disabled(formatting.decorated.isEmpty)
                tile(isOn: false, identifier: "sheet-paste-format") {
                    if let copied { formatting.paste(copied) }
                } label: {
                    Label("Paste Format", systemImage: "doc.on.clipboard.fill").font(Metrics.label)
                }
                .disabled(copied == nil || formatting.decorated.isEmpty)
            }
        }
    }

    // MARK: Pieces

    /// A choice standing free (a style, a mark): outlined in the tint when it's on.
    private func chip(isOn: Bool, identifier: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, minHeight: Metrics.row)
        }
        .buttonStyle(FlooDesignTileButtonStyle(isOn: isOn, surface: .chip))
        .accessibilityIdentifier(identifier)
    }

    /// A choice on a soft tile: tinted and outlined when it's on.
    private func tile(isOn: Bool, identifier: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row)
        }
        .buttonStyle(FlooDesignTileButtonStyle(isOn: isOn))
        .accessibilityIdentifier(identifier)
    }

    private static func token(_ mark: Mark) -> String? {
        if case .color(let token) = mark { token } else { nil }
    }
}

/// The colours over the keyboard bar's highlight key: none (both off), the text
/// colours and any; the highlights and any. A choice applies and closes it.
struct DocColorsPopover: View {
    private typealias Popover = FlooDesignTokens.Component.ColorsPopover

    let editor: DocEditor
    let block: DocBlockID
    let range: Range<Int>
    let onClose: () -> Void

    private var ranges: [(block: DocBlockID, range: Range<Int>)] { [(block, range)] }

    var body: some View {
        let color = editor.common(.color, over: ranges)
        let highlight = editor.common(.highlight, over: ranges)
        VStack(spacing: Popover.spacing) {
            HStack(spacing: Popover.spacing) {
                Button {
                    editor.clearColors(over: ranges)
                    onClose()
                } label: {
                    FlooDesignNoColorSwatch()
                        .frame(width: Popover.swatch, height: Popover.swatch)
                }
                .buttonStyle(FlooDesignPlainButtonStyle(in: Circle()))
                .accessibilityLabel(Text("No Color"))
                .accessibilityIdentifier("popover-none")
                ForEach(DocColors.texts, id: \.token) { item in
                    let isOn = color == .color(item.token)
                    swatch(Circle(), fill: DocColors.swatch(item.token), title: item.title, isOn: isOn, identifier: "popover-color-\(item.token)") {
                        editor.endColorChanges()
                        editor.set(.color, to: isOn ? nil : .color(item.token), over: ranges)
                        onClose()
                    }
                }
                custom(Circle(), title: String(localized: "Other Text Color"), identifier: "popover-color-custom") { picked in
                    editor.set(.color, to: .color(DocColors.hex(picked)), over: ranges, merge: editor.colorMergeKey(over: ranges))
                }
            }
            FlooDesignDivider().padding(.horizontal, Tokens.Space.xs)
            HStack(spacing: Popover.spacing) {
                ForEach(DocColors.highlights, id: \.token) { item in
                    let isOn = highlight == .highlight(color: item.token)
                    swatch(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous), fill: DocColors.highlightSwatch(item.token),
                           title: item.title, isOn: isOn, identifier: "popover-highlight-\(item.token)") {
                        editor.endColorChanges()
                        editor.set(.highlight, to: isOn ? nil : .highlight(color: item.token), over: ranges)
                        onClose()
                    }
                }
                custom(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous), title: String(localized: "Other Highlight Color"),
                       identifier: "popover-highlight-custom") { picked in
                    editor.set(.highlight, to: .highlight(color: DocColors.hex(picked)), over: ranges, merge: editor.colorMergeKey(over: ranges))
                }
            }
        }
        .padding(Popover.inset)
        .flooDesignGlass(.regular, in: RoundedRectangle(cornerRadius: Popover.cornerRadius, style: .continuous))
    }

    private func swatch(_ shape: some InsettableShape, fill: Color, title: String, isOn: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FlooDesignSwatch(shape, fill: fill, isOn: isOn)
                .frame(width: Popover.swatch, height: Popover.swatch)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// Any colour: a rainbow edge round a ▾; the system's picker.
    private func custom(_ shape: some InsettableShape, title: String, identifier: String, picked: @escaping (Color) -> Void) -> some View {
        Button {
            onClose()
            DocColorPicking.present(from: editor, initial: .primary, picked: picked)
        } label: {
            FlooDesignRainbowSwatch(shape, picked: nil)
                .frame(width: Popover.swatch, height: Popover.swatch)
        }
        .buttonStyle(FlooDesignPlainButtonStyle(in: shape))
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The system's colour picker, as a sheet, reporting each colour as it's chosen; a
/// run of them is one undo step (the caller's merge key), ended when it closes.
@MainActor
final class DocColorPicking: NSObject, UIColorPickerViewControllerDelegate {
    private static var current: DocColorPicking?
    private let editor: DocEditor
    private let picked: (Color) -> Void

    private init(editor: DocEditor, picked: @escaping (Color) -> Void) {
        self.editor = editor
        self.picked = picked
    }

    static func present(from editor: DocEditor, initial: Color, picked: @escaping (Color) -> Void) {
        guard let presenter = editor.presentingController() else { return }
        let picking = DocColorPicking(editor: editor, picked: picked)
        let controller = UIColorPickerViewController()
        controller.selectedColor = UIColor(initial)
        controller.supportsAlpha = false
        controller.delegate = picking
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        current = picking
        editor.endColorChanges()
        presenter.present(controller, animated: true)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        picked(Color(uiColor: color))
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        editor.endColorChanges()
        Self.current = nil
    }
}
