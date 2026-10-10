//
//  DocFormatPanel.swift
//  DemoApp
//
//  The Mac's format panel: Craft's sections (titles and content as tiles, marks,
//  lists and indent as segments) in the anchored panel the math editor uses, opened
//  from the bar's Aa. It acts on the selected blocks, or the block the cursor is in; marks
//  on the selected text, or on the selected blocks' text. What DocKit can't carry yet
//  (alignment, colour, fonts, decorations) isn't offered.
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
            VStack(spacing: 8) {
                DocSegments(items: Self.marks.map { item in
                    .init(id: item.id, symbol: item.symbol, title: item.title, isOn: markIsOn(item.mark), isEnabled: !markRanges.isEmpty) {
                        editor.toggle(item.mark, over: markRanges)
                    }
                })
                DocSegments(items: Self.lists.map { item in
                    .init(id: item.id, symbol: item.symbol, title: item.title, isOn: kindIsOn(item.kind), isEnabled: !targets.isEmpty) {
                        editor.setKind(item.kind, of: targets.map(\.id))
                    }
                })
                DocSegments(items: [
                    .init(id: "outdent", symbol: "decrease.indent", title: "减少缩进", isOn: false, isEnabled: canIndent(-1)) {
                        editor.indent(targets.map(\.id), by: -1)
                    },
                    .init(id: "indent", symbol: "increase.indent", title: "增加缩进", isOn: false, isEnabled: canIndent(1)) {
                        editor.indent(targets.map(\.id), by: 1)
                    },
                ])
            }
        }
        .frame(width: 246)
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

    private func tile(_ title: String, weight: Font.Weight, kind: BlockKind) -> some View {
        let isOn = kindIsOn(kind)
        return Button {
            editor.setKind(kind, of: targets.map(\.id))
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
