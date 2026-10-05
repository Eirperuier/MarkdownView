//
//  DocSlashMenu.swift
//  DemoApp
//
//  The slash menu: "/" typed at a block's start or after a space opens it ("、" too:
//  the slash key's character with a Chinese input method), the text
//  typed after the slash filters it, ↑↓ move, Return or a click chooses, Esc or a
//  space closes it. Choosing removes "/query" and turns the block into the chosen
//  kind (its text stays), or puts a divider in.
//

import SwiftUI
import DocKit

struct DocSlashItem: Identifiable, Equatable {
    enum Action: Equatable {
        case kind(BlockKind)
        case divider

        var kind: BlockKind? { if case .kind(let kind) = self { kind } else { nil } }
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let action: Action

    static let all: [DocSlashItem] = [
        .init(id: "paragraph", title: "正文", subtitle: "普通段落", symbol: "text.alignleft", keywords: ["text", "paragraph", "zhengwen"], action: .kind(.paragraph)),
        .init(id: "h1", title: "一级标题", subtitle: "大标题", symbol: "textformat.size.larger", keywords: ["h1", "heading", "title", "biaoti"], action: .kind(.heading(level: 1))),
        .init(id: "h2", title: "二级标题", subtitle: "中标题", symbol: "textformat.size", keywords: ["h2", "heading", "biaoti"], action: .kind(.heading(level: 2))),
        .init(id: "h3", title: "三级标题", subtitle: "小标题", symbol: "textformat.size.smaller", keywords: ["h3", "heading", "biaoti"], action: .kind(.heading(level: 3))),
        .init(id: "bullet", title: "无序列表", subtitle: "圆点列表", symbol: "list.bullet", keywords: ["ul", "bullet", "list", "liebiao"], action: .kind(.listItem(style: .bullet))),
        .init(id: "numbered", title: "有序列表", subtitle: "编号列表", symbol: "list.number", keywords: ["ol", "number", "list", "liebiao"], action: .kind(.listItem(style: .numbered))),
        .init(id: "task", title: "待办", subtitle: "可勾选的事项", symbol: "checklist", keywords: ["todo", "task", "check", "daiban"], action: .kind(.listItem(style: .task(done: false)))),
        .init(id: "toggle", title: "折叠列表", subtitle: "可以收起的内容", symbol: "chevron.right", keywords: ["toggle", "collapse", "zhedie"], action: .kind(.listItem(style: .toggle(open: true)))),
        .init(id: "quote", title: "引用", subtitle: "引用一段话", symbol: "text.quote", keywords: ["quote", "blockquote", "yinyong"], action: .kind(.quote)),
        .init(id: "divider", title: "分割线", subtitle: "分开上下内容", symbol: "minus", keywords: ["divider", "line", "hr", "fengexian"], action: .divider),
    ]

    /// Items whose title or a keyword contains the query (case-insensitive), in order.
    static func matching(_ query: String) -> [DocSlashItem] {
        let query = query.lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { item in
            item.title.contains(query) || item.keywords.contains { $0.contains(query) }
        }
    }
}

/// What the menu shows; the editor drives it.
@MainActor
@Observable
final class DocSlashMenu {
    private(set) var isOpen = false
    private(set) var query = ""
    private(set) var items: [DocSlashItem] = []
    var highlighted = 0
    /// The slash's caret rectangle, in the list's coordinates (the list's frame, not
    /// its scrolled content: where it is on screen, over the list).
    private(set) var anchor: CGRect = .zero
    /// Called with the chosen item.
    @ObservationIgnored var choose: (DocSlashItem) -> Void = { _ in }

    var highlightedItem: DocSlashItem? { items.indices.contains(highlighted) ? items[highlighted] : nil }

    func show(query: String, anchor: CGRect) {
        if query != self.query || !isOpen {
            items = DocSlashItem.matching(query)
            highlighted = 0
        }
        self.query = query
        self.anchor = anchor
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        query = ""
        items = []
        highlighted = 0
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
    }
}

extension DocEditor {
    /// The slash key's characters: "/", and "、" with a Chinese input method.
    static let slashes: Set<String> = ["/", "、"]

    /// A "/" just typed at `offset` (the block's start or after whitespace) opens the menu.
    func slashTyped(in block: DocBlock, at offset: Int) {
        let before = offset == 0 ? nil : block.text.string.utf16.dropFirst(offset - 1).first
        guard before == nil || before.map({ Character(UnicodeScalar($0) ?? " ").isWhitespace }) == true else { return }
        slashOrigin = DocPosition(block: block.id, offset: offset)
        updateSlash()
    }

    /// Keeps the menu in step with the text: the query is what follows the slash up to
    /// the caret; it closes when the caret leaves, the slash goes, or a space is typed.
    func updateSlash() {
        guard let origin = slashOrigin else { return slash.close() }
        guard isEditable, let selection, selection.anchor == selection.head, selection.head.block == origin.block,
            let block = demo.doc.block(origin.block), selection.head.offset > origin.offset,
            selection.head.offset <= block.text.length
        else { return dismissSlash() }
        let units = Array(block.text.string.utf16)
        guard Self.slashes.contains(String(decoding: [units[origin.offset]], as: UTF16.self)) else { return dismissSlash() }
        let query = String(decoding: units[(origin.offset + 1)..<selection.head.offset], as: UTF16.self)
        guard query.count <= 24, !query.contains(where: \.isWhitespace) else { return dismissSlash() }
        slash.show(query: query, anchor: slashAnchor(origin) ?? slash.anchor)
    }

    /// The query while an input method composes it (the model doesn't have it yet).
    /// Pinyin shows syllable breaks ("bi'ao", or a space): they aren't part of it.
    func slashComposing(_ query: String) {
        slash.show(query: query.filter { $0 != "'" && !$0.isWhitespace }, anchor: slash.anchor)
    }

    func dismissSlash() {
        slashOrigin = nil
        slash.close()
    }

    /// Return (or a click) on the menu: removes "/query", then applies the item.
    func chooseSlash(_ item: DocSlashItem? = nil) {
        guard let origin = slashOrigin, let item = item ?? slash.highlightedItem,
            let selection, let block = demo.doc.block(origin.block)
        else { return dismissSlash() }
        dismissSlash()
        let typed = origin.offset..<selection.head.offset
        let here = DocPosition(block: block.id, offset: origin.offset)
        var steps: [DocStep] = [.deleteText(block: block.id, range: typed, removed: DocText())]
        var caret = here
        switch item.action {
        case .kind(let kind):
            if kind != block.kind {
                let indent = if case .listItem = kind, case .listItem = block.kind { block.indent } else { 0 }
                steps.append(.setBlock(block: block.id, kind: kind, indent: indent, previousKind: block.kind, previousIndent: block.indent))
            }
        case .divider:
            let next = demo.newBlockID()
            if block.text.length == typed.count {
                // Only the slash was in the block: it becomes the divider.
                steps.append(.setBlock(block: block.id, kind: .divider, indent: 0, previousKind: block.kind, previousIndent: block.indent))
                steps.append(.insertBlock(block: DocBlock(id: next, kind: .paragraph), after: block.id))
            } else {
                let divider = demo.newBlockID()
                steps.append(.insertBlock(block: DocBlock(id: divider, kind: .divider), after: block.id))
                steps.append(.insertBlock(block: DocBlock(id: next, kind: .paragraph), after: divider))
            }
            caret = DocPosition(block: next, offset: 0)
        }
        commitSlash(steps, from: DocSelection(anchor: selection.head, head: selection.head), to: DocSelection(anchor: caret, head: caret))
    }

    private func slashAnchor(_ origin: DocPosition) -> CGRect? {
        guard let textView = textView(for: origin.block), let block = demo.doc.block(origin.block),
            let start = textStart(in: textView, block: block),
            let position = textView.position(from: textView.beginningOfDocument, offset: start + origin.offset)
        else { return nil }
        var list: UIView? = textView.superview
        while let view = list, !(view is UICollectionView) { list = view.superview }
        guard let list, let frame = list.superview else { return nil }
        // The overlay covers the list's frame: its coordinates are the list's frame's.
        return textView.convert(textView.caretRect(for: position), to: frame).offsetBy(dx: -list.frame.minX, dy: -list.frame.minY)
    }
}

/// The menu, below the slash (above it when there's no room). It goes over the list,
/// whose frame its anchor is in.
struct DocSlashMenuView: View {
    let menu: DocSlashMenu

    var body: some View {
        GeometryReader { proxy in
            if menu.isOpen {
                let anchor = menu.anchor
                let height = min(CGFloat(max(menu.items.count, 1)) * 44 + 12, 320)
                let below = anchor.maxY + 6 + height <= proxy.size.height
                let x = min(max(8, anchor.minX - 8), max(8, proxy.size.width - 268))
                list
                    .frame(width: 260, height: height)
                    .offset(x: x, y: below ? anchor.maxY + 6 : max(8, anchor.minY - 6 - height))
            }
        }
    }

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 0) {
                    if menu.items.isEmpty {
                        Text("没有匹配的块")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                        row(item, highlighted: index == menu.highlighted)
                            .id(item.id)
                            .onTapGesture { menu.choose(item) }
                    }
                }
                .padding(6)
            }
            .onChange(of: menu.highlighted) {
                if let item = menu.highlightedItem { scroller.scrollTo(item.id) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func row(_ item: DocSlashItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 28, height: 28)
                .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .contentShape(Rectangle())
        .background(highlighted ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
