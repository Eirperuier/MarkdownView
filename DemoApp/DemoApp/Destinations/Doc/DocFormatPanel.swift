//
//  DocFormatPanel.swift
//  DemoApp
//
//  The Mac's format panel: Craft's sections (titles and content as tiles, marks,
//  lists and indent as segments) in the anchored panel the math editor uses, opened
//  from the bar's Aa. It acts on the selected blocks, or the block the cursor is in; marks
//  on the selected text, or on the selected blocks' text, and so does the colour. What
//  DocKit can't carry yet (alignment, fonts, decorations) isn't offered.
//

import SwiftUI
import DocKit

/// The editor's selection, observable.
@MainActor
@Observable
final class DocCursor {
    var selection: DocSelection?
}

struct DocFormatPanel: View {
    let editor: DocEditor
    let demo: DocDemo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("格式")
                .font(.system(size: 17, weight: .bold))
                .padding(.bottom, 14)
            // Text first offers its kinds; a link, file or image its layout, after the
            // segments (as Craft orders them).
            if !targets.isEmpty {
                section("标题") {
                    HStack(spacing: 6) {
                        tile("标题", weight: .bold, kind: .heading(level: 1))
                        tile("副标题", weight: .bold, kind: .heading(level: 2))
                        tile("小标题", weight: .bold, kind: .heading(level: 3))
                    }
                }
                section("正文") {
                    HStack(spacing: 6) {
                        tile("强调", weight: .semibold, kind: .heading(level: 4))
                        tile("正文", weight: .regular, kind: .paragraph)
                        tile("引用", weight: .regular, kind: .quote)
                    }
                }
            }
            segments
            if !editor.blocks.selectedLayouts.isEmpty {
                section("布局") {
                    HStack(spacing: 6) {
                        ForEach(DocLayout.allCases, id: \.self) { layout in
                            choice(isOn: editor.blocks.selectedLayouts == [layout], help: layout.title) {
                                editor.blocks.setLayout(layout)
                            } label: {
                                DocLayoutIllustration(layout: layout)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                            }
                        }
                    }
                }
                .padding(.top, 18)
            }
            if !editor.blocks.selectedImageSizes.isEmpty {
                section("图片大小") {
                    HStack(spacing: 6) {
                        imageChoice("自动", symbol: "rectangle.center.inset.filled", isOn: editor.blocks.selectedImageSizes == [.auto]) { editor.blocks.setImage(size: .auto) }
                        imageChoice("大图", symbol: "rectangle", isOn: editor.blocks.selectedImageSizes == [.large]) { editor.blocks.setImage(size: .large) }
                    }
                }
                .padding(.top, 18)
                section("图片显示") {
                    HStack(spacing: 6) {
                        imageChoice("填充", symbol: "square.arrowtriangle.4.outward", isOn: editor.blocks.selectedImageFits == [.fill]) { editor.blocks.setImage(fit: .fill) }
                        imageChoice("适应", symbol: "arrow.down.and.line.horizontal.and.arrow.up", isOn: editor.blocks.selectedImageFits == [.fit]) { editor.blocks.setImage(fit: .fit) }
                    }
                }
            }
            if !markRanges.isEmpty {
                section("颜色") { colors }
                    .padding(.top, 18)
            }
        }
        .frame(width: 246)
    }

    // MARK: Colour

    /// Craft's colours: none, the palette, and any colour (the system's picker); the
    /// one the text has is ringed.
    private var colors: some View {
        let ranges = markRanges
        let current = editor.common(.color, over: ranges)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            swatch(nil, title: "默认", isOn: current == nil, ranges: ranges)
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
                .strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center), lineWidth: 3.5)
            Circle()
                .fill(picked.map(DocColors.swatch) ?? Color(.systemBackground))
                .padding(6)
            ColorPicker("其他颜色", selection: Binding {
                picked.map(DocColors.swatch) ?? .primary
            } set: { color in
                editor.set(.color, to: .color(DocColors.hex(color)), over: ranges, merge: editor.colorMergeKey(over: ranges))
            }, supportsOpacity: false)
            .labelsHidden()
            .opacity(0.02)
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .help("其他颜色")
        .accessibilityIdentifier("color-custom")
    }

    private func swatch(_ token: String?, title: String, isOn: Bool, ranges: [(block: DocBlockID, range: Range<Int>)]) -> some View {
        Button {
            editor.endColorChanges()
            editor.set(.color, to: token.map(Mark.color), over: ranges)
        } label: {
            Circle()
                .fill(token.map(DocColors.swatch) ?? Color(.systemBackground))
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
                .padding(isOn ? 4 : 0)
                .overlay { if isOn { Circle().strokeBorder(Color.primary, lineWidth: 2.5) } }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("color-\(token ?? "none")")
    }

    private var segments: some View {
        VStack(spacing: 8) {
            DocSegments(items: Self.marks.map { item in
                .init(id: item.id, symbol: item.symbol, title: item.title, isOn: markIsOn(item.mark), isEnabled: !markRanges.isEmpty) {
                    editor.toggle(item.mark, over: markRanges)
                }
            })
            DocSegments(items: Self.lists.map { item in
                .init(id: item.id, symbol: item.symbol, title: item.title, isOn: kindIsOn(item.kind), isEnabled: !targets.isEmpty) {
                    editor.blocks.transition { editor.setKind(item.kind, of: targets.map(\.id)) }
                }
            })
            DocSegments(items: [
                .init(id: "outdent", symbol: "decrease.indent", title: "减少缩进", isOn: false, isEnabled: canIndent(-1)) {
                    editor.blocks.transition { editor.indent(targets.map(\.id), by: -1) }
                },
                .init(id: "indent", symbol: "increase.indent", title: "增加缩进", isOn: false, isEnabled: canIndent(1)) {
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
        ("bold", "bold", "加粗", .bold),
        ("italic", "italic", "斜体", .italic),
        ("strike", "strikethrough", "删除线", .strike),
        ("code", "chevron.left.forwardslash.chevron.right", "代码", .code),
    ]

    private static let lists: [(id: String, symbol: String, title: String, kind: BlockKind)] = [
        ("task", "checkmark.square", "待办", .listItem(style: .task(done: false))),
        ("toggle", "arrowtriangle.right.fill", "折叠列表", .listItem(style: .toggle(open: true))),
        ("bullet", "list.bullet", "无序列表", .listItem(style: .bullet)),
        ("numbered", "list.number", "有序列表", .listItem(style: .numbered)),
    ]

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.bottom, 16)
    }

    /// A choice on a soft tile, outlined in the tint when it's in use.
    private func choice(isOn: Bool, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .background(isOn ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    if isOn { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1) }
                }
                .contentShape(.rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// An image's size or fit: its name, and its symbol at the right (Craft's).
    private func imageChoice(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        choice(isOn: isOn, help: title, action: action) {
            HStack {
                Text(title).font(.system(size: 15))
                Spacer(minLength: 4)
                Image(systemName: symbol).font(.system(size: 15))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    private func tile(_ title: String, weight: Font.Weight, kind: BlockKind) -> some View {
        let isOn = kindIsOn(kind)
        return Button {
            editor.blocks.transition { editor.setKind(kind, of: targets.map(\.id)) }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: weight))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(isOn ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    if isOn { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1) }
                }
                .contentShape(.rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(targets.isEmpty)
        .accessibilityIdentifier("format-\(title)")
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
                    Rectangle().fill(.separator.opacity(0.5)).frame(width: 1, height: 18)
                }
                Button(action: item.action) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(item.isOn ? Color.accentColor.opacity(0.14) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.isOn ? Color.accentColor : .primary)
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.title)
            }
        }
        .background(Color.primary.opacity(0.06))
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }
}
