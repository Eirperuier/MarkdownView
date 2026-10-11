//
//  DocFormatPanel.swift
//  DemoApp
//
//  The Mac's format panel: Craft's sections (the text styles as tiles, marks, lists
//  and indent as segments, the quote and the box as decorations) in the anchored panel the math
//  editor uses, opened from the bar's Aa. It acts on the selected blocks, or the block the
//  cursor is in; marks on the selected text, or on the selected blocks' text, and so does
//  the colour; the box any blocks. What DocKit can't carry yet (alignment) isn't offered.
//

import SwiftUI
import DocKit

private typealias Tokens = FlooDesignTokens
private typealias Metrics = FlooDesignTokens.Component.FormatPanel

/// The editor's selection, observable.
@MainActor
@Observable
final class DocCursor {
    var selection: DocSelection?
}

/// The Mac's panels that are up.
@MainActor
@Observable
final class DocPanels {
    /// The format panel (-docFormat YES opens with it).
    var showsFormat = UserDefaults.standard.bool(forKey: "docFormat")
}

struct DocFormatPanel: View {
    let editor: DocEditor
    let demo: DocDemo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Format")
                .font(Metrics.title)
                .padding(.bottom, Metrics.titleGap)
            // Text first offers its kinds; a link, file or image its layout, after the
            // segments (as Craft orders them).
            // Text styles: how big a block's text is (Craft's six, ⌃1–⌃6).
            if !targets.isEmpty {
                section(String(localized: "Titles")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        ForEach(Self.styles.prefix(3), id: \.key) { tile($0) }
                    }
                }
                section(String(localized: "Content")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        ForEach(Self.styles.suffix(3), id: \.key) { tile($0) }
                    }
                }
            }
            segments
            if !editor.blocks.selectedLayouts.isEmpty {
                section(String(localized: "Layout")) {
                    HStack(spacing: Tokens.Component.Tile.spacing) {
                        ForEach(DocLayout.allCases, id: \.self) { layout in
                            choice(isOn: editor.blocks.selectedLayouts == [layout], help: layout.title) {
                                editor.blocks.setLayout(layout)
                            } label: {
                                DocLayoutIllustration(layout: layout)
                                    .frame(maxWidth: .infinity, minHeight: Metrics.tallTile)
                            }
                        }
                    }
                }
                .padding(.top, Metrics.sectionLead)
            }
            if !editor.blocks.selectedImageSizes.isEmpty {
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
                            let kind: BlockKind = kindIsOn(.quote) ? .paragraph : .quote
                            editor.blocks.transition { editor.setKind(kind, of: targets.map(\.id)) }
                        } label: {
                            HStack(spacing: Tokens.Space.md) {
                                Capsule().frame(width: Metrics.quoteBar.width, height: Metrics.quoteBar.height)
                                Text("Quote").font(Metrics.label)
                            }
                            .frame(maxWidth: .infinity, minHeight: Metrics.tallTile)
                        }
                        .disabled(targets.isEmpty)
                        .accessibilityIdentifier("format-quote")
                        let boxed = decorated.allSatisfy { $0.decoration == .block }
                        choice(isOn: boxed, help: String(localized: "Block")) {
                            editor.blocks.transition { editor.setDecoration(boxed ? nil : .block, of: decorated.map(\.id)) }
                        } label: {
                            Text("Block")
                                .font(Metrics.label)
                                .frame(maxWidth: .infinity, minHeight: Metrics.tallTile - 12)
                                .background(Tokens.ColorRole.Surface.pressed.opacity(0.7), in: .rect(cornerRadius: Tokens.Radius.sm, style: .continuous))
                                .padding(6)
                        }
                        .accessibilityIdentifier("format-block")
                    }
                }
                .padding(.top, Metrics.sectionLead)
            }
            if !markRanges.isEmpty {
                section(String(localized: "Color")) { colors }
                    .padding(.top, decorated.isEmpty ? Metrics.sectionLead : 0)
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

    /// Any colour: Craft's rainbow ring, the colour inside it once one is picked. The
    /// system's picker lies over it, clear, and takes the click.
    private func custom(_ current: Mark?, ranges: [(block: DocBlockID, range: Range<Int>)]) -> some View {
        let picked: String? = if case .color(let token)? = current, token.hasPrefix("#") { token } else { nil }
        return ZStack {
            Circle()
                .strokeBorder(DocColors.rainbow, lineWidth: Metrics.rainbowWidth)
            Circle()
                .fill(picked.map(DocColors.swatch) ?? Color(.systemBackground))
                .padding(6)
            ColorPicker("Other Color", selection: Binding {
                picked.map(DocColors.swatch) ?? .primary
            } set: { color in
                editor.set(.color, to: .color(DocColors.hex(color)), over: ranges, merge: editor.colorMergeKey(over: ranges))
            }, supportsOpacity: false)
            .labelsHidden()
            .opacity(0.02)
        }
        .frame(width: Metrics.swatch, height: Metrics.swatch)
        .clipShape(Circle())
        .help("Other Color")
        .accessibilityIdentifier("color-custom")
    }

    private func swatch(_ token: String?, title: String, isOn: Bool, ranges: [(block: DocBlockID, range: Range<Int>)]) -> some View {
        Button {
            editor.endColorChanges()
            editor.set(.color, to: token.map(Mark.color), over: ranges)
        } label: {
            Circle()
                .fill(token.map(DocColors.swatch) ?? Color(.systemBackground))
                .overlay { Circle().strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.standard) }
                .padding(isOn ? 4 : 0)
                .overlay { if isOn { Circle().strokeBorder(Tokens.ColorRole.Content.primary, lineWidth: Metrics.chosenRing) } }
                .frame(width: Metrics.swatch, height: Metrics.swatch)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("color-\(token ?? "none")")
    }

    private var segments: some View {
        VStack(spacing: Metrics.segmentGap) {
            DocSegments(items: Self.marks.map { item in
                .init(id: item.id, symbol: item.symbol, title: item.title, isOn: markIsOn(item.mark), isEnabled: !markRanges.isEmpty) {
                    editor.toggle(item.mark, over: markRanges)
                }
            })
            DocSegments(items: Self.lists.map { item in
                .init(id: item.id, symbol: item.symbol, title: item.title, isOn: kindIsOn(item.kind), isEnabled: !targets.isEmpty) {
                    // Pressed again, the list goes back to text (Craft's); items already in
                    // the style keep their state (a done task stays done).
                    if kindIsOn(item.kind) {
                        editor.blocks.transition { editor.setKind(.paragraph, of: targets.map(\.id)) }
                    } else {
                        let ids = targets.filter { !Self.same($0.kind, item.kind) }.map(\.id)
                        editor.blocks.transition { editor.setKind(item.kind, of: ids) }
                    }
                }
            })
            DocSegments(items: [
                .init(id: "outdent", symbol: "decrease.indent", title: String(localized: "Outdent"), isOn: false, isEnabled: canIndent(-1)) {
                    editor.blocks.transition { editor.indent(targets.map(\.id), by: -1) }
                },
                .init(id: "indent", symbol: "increase.indent", title: String(localized: "Indent"), isOn: false, isEnabled: canIndent(1)) {
                    editor.blocks.transition { editor.indent(targets.map(\.id), by: 1) }
                },
            ])
        }
    }

    // MARK: What it acts on

    /// The selected blocks of text, else the one the cursor is in.
    private var targets: [DocBlock] {
        let selected = Set(editor.blocks.selected)
        if !selected.isEmpty {
            return demo.doc.blocks.filter { selected.contains($0.id) && $0.kind.carriesText }
        }
        guard let id = editor.cursor.selection?.head.block, let block = demo.doc.block(id), block.kind.carriesText else { return [] }
        return [block]
    }

    /// The selected blocks of any kind, else the one the cursor is in: what a box goes around.
    private var decorated: [DocBlock] {
        let selected = Set(editor.blocks.selected)
        if !selected.isEmpty { return demo.doc.blocks.filter { selected.contains($0.id) } }
        guard let id = editor.cursor.selection?.head.block, let block = demo.doc.block(id) else { return [] }
        return [block]
    }

    /// The selected text, else all the text of the selected blocks.
    private var markRanges: [(block: DocBlockID, range: Range<Int>)] {
        if editor.blocks.selected.isEmpty, let selection = editor.cursor.selection, selection.anchor.block == selection.head.block {
            let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
            return range.isEmpty ? [] : [(selection.head.block, range)]
        }
        return targets.filter { $0.kind.allowsMarks && !$0.text.isEmpty }.map { ($0.id, 0..<$0.text.length) }
    }

    private func markIsOn(_ mark: Mark) -> Bool {
        let ranges = markRanges
        return !ranges.isEmpty && ranges.allSatisfy { range in
            demo.doc.block(range.block).map { DocEditor.covers($0.text, range.range, with: mark.kind) } ?? false
        }
    }

    private func kindIsOn(_ kind: BlockKind) -> Bool {
        let blocks = targets
        return !blocks.isEmpty && blocks.allSatisfy { Self.same($0.kind, kind) }
    }

    private func canIndent(_ delta: Int) -> Bool {
        targets.contains { block in
            guard case .listItem = block.kind else { return false }
            return delta < 0 ? block.indent > 0 : true
        }
    }

    /// The same kind, a task's or toggle's state aside.
    private static func same(_ a: BlockKind, _ b: BlockKind) -> Bool {
        switch (a, b) {
        case (.listItem(let x), .listItem(let y)):
            switch (x, y) {
            case (.bullet, .bullet), (.numbered, .numbered), (.task, .task), (.toggle, .toggle): true
            default: false
            }
        default: a == b
        }
    }

    // MARK: Pieces

    private static let marks: [(id: String, symbol: String, title: String, mark: Mark)] = [
        ("bold", "bold", String(localized: "Bold"), .bold),
        ("italic", "italic", String(localized: "Italic"), .italic),
        ("strike", "strikethrough", String(localized: "Strikethrough"), .strike),
        ("code", "chevron.left.forwardslash.chevron.right", String(localized: "Code"), .code),
    ]

    /// The text styles, Craft's: titles, then content; each its ⌃ key.
    static let styles: [(key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind)] = [
        ("1", String(localized: "Title"), 15, .bold, .heading(level: 1)),
        ("2", String(localized: "Subtitle"), 15, .bold, .heading(level: 2)),
        ("3", String(localized: "Heading"), 15, .semibold, .heading(level: 3)),
        ("4", String(localized: "Strong"), 15, .semibold, .heading(level: 4)),
        ("5", String(localized: "Body"), 15, .regular, .paragraph),
        ("6", String(localized: "Caption"), 13.5, .regular, .caption),
    ]

    private static let lists: [(id: String, symbol: String, title: String, kind: BlockKind)] = [
        ("task", "checkmark.square", String(localized: "To-do"), .listItem(style: .task(done: false))),
        ("toggle", "arrowtriangle.right.fill", String(localized: "Toggle List"), .listItem(style: .toggle(open: true))),
        ("bullet", "list.bullet", String(localized: "Bulleted List"), .listItem(style: .bullet)),
        ("numbered", "list.number", String(localized: "Numbered List"), .listItem(style: .numbered)),
    ]

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionLabelGap) {
            Text(title)
                .font(Metrics.sectionLabel)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.bottom, Metrics.sectionGap)
    }

    /// A choice on a soft tile, outlined in the tint when it's in use.
    private func choice(isOn: Bool, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .background(isOn ? Tokens.ColorRole.Accent.subtle : Tokens.ColorRole.Surface.control, in: .rect(cornerRadius: Tokens.Component.Tile.cornerRadius, style: .continuous))
                .overlay {
                    if isOn { RoundedRectangle(cornerRadius: Tokens.Component.Tile.cornerRadius, style: .continuous).strokeBorder(Tokens.ColorRole.Accent.outline, lineWidth: Tokens.Component.Tile.outline) }
                }
                .contentShape(.rect(cornerRadius: Tokens.Component.Tile.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// An image's size or fit: its name, and its symbol at the right (Craft's).
    private func imageChoice(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        choice(isOn: isOn, help: title, action: action) {
            HStack {
                Text(title).font(Metrics.label)
                Spacer(minLength: 4)
                Image(systemName: symbol).font(Metrics.label)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Metrics.tallTile)
        }
    }

    private func tile(_ style: (key: String, title: String, size: CGFloat, weight: Font.Weight, kind: BlockKind)) -> some View {
        let isOn = kindIsOn(style.kind)
        return Button {
            editor.blocks.transition { editor.setKind(style.kind, of: targets.map(\.id)) }
        } label: {
            Text(style.title)
                .font(.system(size: style.size, weight: style.weight))
                .frame(maxWidth: .infinity, minHeight: Tokens.Component.Tile.minHeight)
                .background(isOn ? Tokens.ColorRole.Accent.subtle : Tokens.ColorRole.Surface.control, in: .rect(cornerRadius: Tokens.Component.Tile.cornerRadius, style: .continuous))
                .overlay {
                    if isOn { RoundedRectangle(cornerRadius: Tokens.Component.Tile.cornerRadius, style: .continuous).strokeBorder(Tokens.ColorRole.Accent.outline, lineWidth: Tokens.Component.Tile.outline) }
                }
                .contentShape(.rect(cornerRadius: Tokens.Component.Tile.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(targets.isEmpty)
        .help("⌃\(style.key)")
        .accessibilityIdentifier("format-style-\(style.key)")
    }
}

/// Keys joined in one rounded group with hairlines between them (Craft's segments).
private struct DocSegments: View {
    struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let isOn: Bool
        let isEnabled: Bool
        let action: () -> Void
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(Tokens.Border.separator.opacity(0.5)).frame(width: Tokens.Border.standard, height: Tokens.Component.Segments.dividerHeight)
                }
                Button(action: item.action) {
                    Image(systemName: item.symbol)
                        .font(.system(size: Tokens.Icon.standard, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: Tokens.Component.Segments.height)
                        .background(item.isOn ? Tokens.ColorRole.Accent.subtle : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.isOn ? Tokens.ColorRole.Accent.primary : Tokens.ColorRole.Content.primary)
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.title)
            }
        }
        .background(Tokens.ColorRole.Surface.control)
        .clipShape(.rect(cornerRadius: Tokens.Component.Segments.cornerRadius, style: .continuous))
    }
}
