//
//  DocFormatSheet.swift
//  DemoApp
//
//  The phone's format sheet, Craft's: over the selected blocks (from the selection
//  bar's Style), or in the keyboard's place (from the keyboard bar's Aa), where a caret
//  stands for its block. Pages in place:
//
//  - main: a few styles and More…; lists and indent; the quote and the box, the colour,
//    and … ;
//  - styles: the six text styles (More…);
//  - colours: the text's own colour, the palette, and any colour (the system's picker);
//  - more (…): bold, italic, strikethrough, code; Copy Format and Paste Format.
//
//  A choice on a page takes it back to the main one; the grabber goes back a page, or
//  closes the sheet. What DocKit can't carry yet (alignment, fonts, pages) isn't offered.
//
//  The colours over the keyboard bar's highlight key, Craft's: none, the text colours
//  and any; the highlights and any.
//

import SwiftUI
import UIKit
import DocKit

private typealias Tokens = FlooDesignTokens
private typealias Metrics = FlooDesignTokens.Component.FormatSheet

enum DocFormatSheetPage: Hashable, Identifiable {
    case main, styles, colors, more

    var id: Self { self }
}

struct DocFormatSheet: View {
    let editor: DocEditor
    /// In a sheet of its own: another page opens in a sheet over it (Craft's), not in
    /// its place.
    var stacksPages = false
    /// Back from the main page: the sheet goes.
    let onClose: () -> Void

    private var formatting: DocFormatting { DocFormatting(editor: editor, caretTakesBlock: true) }
    private var page: DocFormatSheetPage { editor.panels.sheetPage ?? .main }

    var body: some View {
        if stacksPages {
            sheet(.main)
                .sheet(item: Binding(get: { page == .main ? nil : page }, set: { if $0 == nil { go(.main) } })) { page in
                    sheet(page).docSizedSheet()
                }
        } else {
            sheet(page)
                .animation(Tokens.Motion.feedback, value: page)
        }
    }

    private func sheet(_ shown: DocFormatSheetPage) -> some View {
        VStack(spacing: Metrics.rowSpacing) {
            grabber(shown)
            Group {
                switch shown {
                case .main: main
                case .styles: styles
                case .colors: colors
                case .more: more
                }
            }
            .frame(height: Metrics.page, alignment: .top)
            .transition(.opacity)
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, Metrics.inset)
        .buttonStyle(.plain)
        .gesture(DragGesture(minimumDistance: 12).onEnded { if $0.translation.height > 30 { back(from: shown) } })
    }

    private func grabber(_ shown: DocFormatSheetPage) -> some View {
        Capsule()
            .fill(Tokens.ColorRole.Content.tertiary)
            .frame(width: Metrics.grabber.width, height: Metrics.grabber.height)
            .frame(maxWidth: .infinity, minHeight: Metrics.grabberArea)
            .contentShape(Rectangle())
            .onTapGesture { back(from: shown) }
            .accessibilityLabel(shown == .main ? Text("Close") : Text("Back"))
            .accessibilityAddTraits(.isButton)
    }

    private func back(from shown: DocFormatSheetPage) {
        if shown == .main { onClose() } else { go(.main) }
    }

    private func go(_ page: DocFormatSheetPage) {
        editor.panels.sheetPage = page
    }

    // MARK: Main

    private var main: some View {
        let formatting = formatting
        return VStack(spacing: Metrics.rowSpacing) {
            HStack(spacing: Metrics.tileSpacing) {
                ForEach(shortStyles, id: \.key) { style in
                    chip(isOn: formatting.kindIsOn(style.kind), identifier: "sheet-style-\(style.key)") {
                        formatting.setStyle(style.kind)
                    } label: {
                        styleLabel(style)
                    }
                }
                Rectangle()
                    .fill(Tokens.Border.separator)
                    .frame(width: Tokens.Border.hairline, height: Metrics.row - 20)
                Button { go(.styles) } label: {
                    Text("More…")
                        .font(Metrics.label)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Metrics.row)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("sheet-more-styles")
            }
            .disabled(formatting.targets.isEmpty)
            HStack(spacing: Metrics.tileSpacing) {
                ForEach(DocFormatting.lists, id: \.id) { item in
                    tile(isOn: formatting.kindIsOn(item.kind), identifier: "sheet-\(item.id)") {
                        formatting.toggleList(item.kind)
                    } label: {
                        Image(systemName: item.symbol).font(.system(size: Tokens.Icon.toolbar))
                    }
                    .disabled(formatting.targets.isEmpty)
                    .accessibilityLabel(item.title)
                }
                Spacer().frame(width: Metrics.groupGap - Metrics.tileSpacing * 2)
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
            HStack(spacing: Metrics.tileSpacing) {
                tile(isOn: formatting.kindIsOn(.quote), identifier: "sheet-quote") { formatting.toggleQuote() } label: {
                    HStack(spacing: Tokens.Space.md) {
                        Capsule().frame(width: 3, height: 22)
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
                        .padding(6)
                }
                .disabled(formatting.decorated.isEmpty)
                .frame(maxWidth: .infinity)
                Button { go(.colors) } label: {
                    ZStack {
                        Circle().strokeBorder(DocColors.rainbow, lineWidth: 3.5)
                        Circle()
                            .fill(formatting.color.flatMap(Self.token).map(DocColors.swatch) ?? Tokens.ColorRole.Content.primary)
                            .padding(6)
                    }
                    .frame(width: Metrics.colorRing, height: Metrics.colorRing)
                    .frame(width: Metrics.row + 10, height: Metrics.row)
                    .contentShape(Rectangle())
                }
                .disabled(formatting.markRanges.isEmpty)
                .accessibilityLabel(Text("Text Color"))
                .accessibilityIdentifier("sheet-colors")
                tile(isOn: false, identifier: "sheet-more") { go(.more) } label: {
                    Image(systemName: "ellipsis").font(.system(size: Tokens.Icon.toolbar, weight: .semibold))
                }
                .frame(width: Metrics.row + 6)
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
                if index > 0 { Rectangle().fill(Tokens.Border.separator).frame(height: Tokens.Border.hairline) }
                HStack(spacing: Metrics.tileSpacing) {
                    ForEach(rows[index], id: \.key) { style in
                        chip(isOn: formatting.kindIsOn(style.kind), identifier: "sheet-style-\(style.key)") {
                            formatting.setStyle(style.kind)
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
        case .heading(level: 1): large ? 21 : 17
        case .heading(level: 2): large ? 19 : 17
        case .caption: 15
        default: 17
        }
        return Text(style.title)
            .font(.system(size: size, weight: style.weight))
            .foregroundStyle(style.kind == .caption ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
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
                RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous)
                    .strokeBorder(DocColors.rainbow, lineWidth: Metrics.chosenRing)
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.swatchRadius - 5, style: .continuous)
                            .fill(picked.map(DocColors.swatch) ?? Tokens.ColorRole.Content.primary)
                            .padding(5)
                    }
                    .overlay {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.25), in: .circle)
                    }
                    .frame(height: Metrics.swatchHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Other Color"))
            .accessibilityIdentifier("sheet-color-custom")
        }
        .disabled(formatting.markRanges.isEmpty)
    }

    private func swatch(fill: Color, title: String, isOn: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous)
                .fill(fill)
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.swatchRadius, style: .continuous)
                        .strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard)
                }
                .padding(isOn ? Metrics.chosenRing + 2 : 0)
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: Metrics.swatchRadius + 2, style: .continuous)
                            .strokeBorder(fill, lineWidth: Metrics.chosenRing)
                    }
                }
                .frame(height: Metrics.swatchHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: More

    private var more: some View {
        let formatting = formatting
        let copied = editor.panels.copiedFormat
        return VStack(spacing: Metrics.rowSpacing) {
            HStack(spacing: Metrics.tileSpacing) {
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
            HStack(spacing: Metrics.tileSpacing) {
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
            label()
                .frame(maxWidth: .infinity, minHeight: Metrics.row)
                .background(isOn ? Tokens.ColorRole.Accent.subtle : .clear, in: .rect(cornerRadius: Metrics.tileRadius, style: .continuous))
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
                            .strokeBorder(Tokens.ColorRole.Accent.primary.opacity(0.8), lineWidth: Metrics.outline)
                    }
                }
                .contentShape(.rect(cornerRadius: Metrics.tileRadius, style: .continuous))
        }
        .foregroundStyle(Tokens.ColorRole.Content.primary)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// A choice on a soft tile: tinted and outlined when it's on.
    private func tile(isOn: Bool, identifier: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row)
                .background(isOn ? Tokens.ColorRole.Accent.subtle : Tokens.ColorRole.Surface.control, in: .rect(cornerRadius: Metrics.tileRadius, style: .continuous))
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
                            .strokeBorder(Tokens.ColorRole.Accent.primary.opacity(0.8), lineWidth: Metrics.outline)
                    }
                }
                .contentShape(.rect(cornerRadius: Metrics.tileRadius, style: .continuous))
        }
        .foregroundStyle(Tokens.ColorRole.Content.primary)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
                    Circle()
                        .strokeBorder(Tokens.Border.separator, lineWidth: Tokens.Border.standard)
                        .overlay { Rectangle().fill(Tokens.Border.separator).frame(width: Tokens.Border.standard, height: Popover.swatch * 0.5).rotationEffect(.degrees(35)) }
                        .frame(width: Popover.swatch, height: Popover.swatch)
                }
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
            Rectangle().fill(Tokens.Border.separator).frame(height: Tokens.Border.hairline).padding(.horizontal, Tokens.Space.xs)
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
        .buttonStyle(.plain)
        .background(.regularMaterial, in: .rect(cornerRadius: Popover.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Popover.cornerRadius, style: .continuous)
                .strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.hairline)
        }
        .shadow(color: Tokens.Elevation.high.color, radius: Tokens.Elevation.high.radius, y: Tokens.Elevation.high.y)
    }

    private func swatch(_ shape: some InsettableShape, fill: Color, title: String, isOn: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            shape.fill(fill)
                .overlay { shape.strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard) }
                .overlay {
                    if isOn { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: Popover.swatch, height: Popover.swatch)
                .contentShape(shape)
        }
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
            shape.strokeBorder(DocColors.rainbow, lineWidth: 3)
                .overlay {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: Popover.swatch, height: Popover.swatch)
                .contentShape(shape)
        }
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

/// A sheet as tall as its content (Craft's): it floats over the bottom, and the document
/// behind it still takes touches. No system grabber: the content's own goes back a page
/// before it closes the sheet.
private struct DocSizedSheet: ViewModifier {
    @State private var height = DocFormatInputView.sheetHeight

    func body(content: Content) -> some View {
        content
            .padding(.top, Metrics.rowSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            .presentationDetents([.height(height)])
            .presentationDragIndicator(.hidden)
            .presentationBackgroundInteraction(.enabled)
    }
}

extension View {
    func docSizedSheet() -> some View { modifier(DocSizedSheet()) }
}

/// The sheet where the keyboard was, on the keyboard's own background; the keyboard
/// bar stays over it.
final class DocFormatInputView: UIInputView {
    private typealias Metrics = FlooDesignTokens.Component.FormatSheet

    /// A grabber, a page, the inset below.
    static let sheetHeight = Metrics.grabberArea + Metrics.rowSpacing + Metrics.page + Metrics.inset

    init(editor: DocEditor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.sheetHeight), inputViewStyle: .default)
        allowsSelfSizing = true
        // Opaque, as the bar over it: the document mustn't show through the tiles.
        backgroundColor = .systemBackground
        let host = UIHostingController(rootView: DocFormatSheet(editor: editor) { [weak editor] in editor?.hideFormatInput() })
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        hosting = host
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.rowSpacing),
            host.view.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: Self.sheetHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var hosting: UIHostingController<DocFormatSheet>?
}
