//
//  DocSlashMenu.swift
//  DemoApp
//
//  The command menu (Craft's): what can be done to the caret's block, in groups. See
//  DocSlashMenu for how it opens and closes. Choosing removes the "/query" typed, then
//  acts: the block turns into the chosen kind (its text stays), takes a colour or a
//  decoration, is copied, duplicated or deleted, or a divider or table goes in.
//

import SwiftUI
import DocKit
import FlooDesign

/// A command in the menu: one that acts on the caret's block, or a group whose commands
/// take the menu's place (Craft's).
struct DocCommand: Identifiable, Equatable, Sendable {
    enum Action: Equatable {
        /// The block becomes this kind (a text style, a list, code, math).
        case kind(BlockKind)
        case indent(Int)
        case box
        /// The text's colour (nil: its own).
        case color(String?)
        case copy
        case duplicate
        case divider
        /// `rows` counts the header row.
        case table(rows: Int, columns: Int)
        /// The block becomes a page, its words the title, and the window goes into it.
        case page
        /// Marks, colour and box off; the kind stays.
        case clearFormat
        case delete

        var kind: BlockKind? { if case .kind(let kind) = self { kind } else { nil } }
    }

    let id: String
    let title: String
    let symbol: String
    /// A colour's token: its swatch is the icon.
    var swatch: String? = nil
    var keywords: [String] = []
    var action: Action? = nil
    var children: [DocCommand] = []

    var isGroup: Bool { !children.isEmpty }

    private static func group(_ id: String, _ title: String, _ symbol: String, _ children: [DocCommand]) -> DocCommand {
        DocCommand(id: id, title: title, symbol: symbol, children: children)
    }

    /// Craft's command menu, what DocKit can do of it, in its order.
    static let all: [DocCommand] = [
        group("list", String(localized: "List"), "list.bullet", [
            .init(id: "task", title: String(localized: "Todo List"), symbol: "checkmark.square", keywords: ["todo", "task", "check", "daiban"], action: .kind(.listItem(style: .task(done: false)))),
            .init(id: "toggle", title: String(localized: "Toggle List"), symbol: "play.fill", keywords: ["toggle", "collapse", "zhedie"], action: .kind(.listItem(style: .toggle(open: true)))),
            .init(id: "bullet", title: String(localized: "Bullet List"), symbol: "list.bullet", keywords: ["ul", "bullet", "list", "liebiao"], action: .kind(.listItem(style: .bullet))),
            .init(id: "numbered", title: String(localized: "Numbered List"), symbol: "list.number", keywords: ["ol", "number", "list", "liebiao"], action: .kind(.listItem(style: .numbered))),
        ]),
        group("indentation", String(localized: "Indentation"), "increase.indent", [
            .init(id: "indent", title: String(localized: "Indent"), symbol: "increase.indent", keywords: ["indent", "suojin"], action: .indent(1)),
            .init(id: "outdent", title: String(localized: "Outdent"), symbol: "decrease.indent", keywords: ["outdent", "suojin"], action: .indent(-1)),
        ]),
        group("style", String(localized: "Text Style"), "textformat", [
            .init(id: "h1", title: String(localized: "Title"), symbol: "textformat.size.larger", keywords: ["h1", "heading", "title", "biaoti"], action: .kind(.heading(level: 1))),
            .init(id: "h2", title: String(localized: "Subtitle"), symbol: "textformat.size", keywords: ["h2", "heading", "subtitle", "biaoti"], action: .kind(.heading(level: 2))),
            .init(id: "h3", title: String(localized: "Heading"), symbol: "textformat.size.smaller", keywords: ["h3", "heading", "biaoti"], action: .kind(.heading(level: 3))),
            .init(id: "h4", title: String(localized: "Strong"), symbol: "bold", keywords: ["h4", "strong", "qiangdiao"], action: .kind(.heading(level: 4))),
            .init(id: "paragraph", title: String(localized: "Body"), symbol: "text.alignleft", keywords: ["text", "paragraph", "body", "zhengwen"], action: .kind(.paragraph)),
            .init(id: "caption", title: String(localized: "Caption"), symbol: "textformat.subscript", keywords: ["caption", "small", "shuoming"], action: .kind(.caption)),
        ]),
        group("actions", String(localized: "Actions"), "command", [
            .init(id: "copy", title: String(localized: "Copy"), symbol: "doc.on.doc", keywords: ["copy", "fuzhi"], action: .copy),
            .init(id: "duplicate", title: String(localized: "Duplicate"), symbol: "plus.square.on.square", keywords: ["duplicate", "fuben"], action: .duplicate),
        ]),
        group("decorations", String(localized: "Decorations"), "square.dashed", [
            .init(id: "quote", title: String(localized: "Quote"), symbol: "text.quote", keywords: ["quote", "blockquote", "focus", "yinyong"], action: .kind(.quote)),
            .init(id: "box", title: String(localized: "Block"), symbol: "square", keywords: ["block", "box", "card", "kuai"], action: .box),
        ]),
        group("color", String(localized: "Color"), "paintpalette", [
            .init(id: "color-none", title: String(localized: "Default"), symbol: "circle.slash", keywords: ["color", "default", "yanse"], action: .color(nil)),
        ] + DocColors.palette.map { color in
            .init(id: "color-\(color.token)", title: color.title, symbol: "circle.fill", swatch: color.token, keywords: ["color", "yanse"], action: .color(color.token))
        }),
        group("table", String(localized: "Insert Table"), "tablecells", [2, 3, 4].map { size in
            .init(id: "table-\(size)x\(size)", title: String(localized: "\(size) × \(size) Table"), symbol: "tablecells", keywords: ["table", "grid", "biaoge"], action: .table(rows: size, columns: size))
        }),
        .init(id: "code", title: String(localized: "Code Block"), symbol: "chevron.left.forwardslash.chevron.right", keywords: ["code", "snippet", "daima"], action: .kind(.code(language: nil))),
        .init(id: "math", title: String(localized: "Math Block"), symbol: "function", keywords: ["math", "latex", "equation", "gongshi"], action: .kind(.math)),
        .init(id: "divider", title: String(localized: "Divider"), symbol: "minus", keywords: ["divider", "line", "hr", "fengexian"], action: .divider),
        .init(id: "page", title: String(localized: "Page"), symbol: "doc.text", keywords: ["page", "subpage", "yemian"], action: .page),
        .init(id: "clear", title: String(localized: "Clear Format"), symbol: "xmark.square", keywords: ["clear", "format", "qingchu"], action: .clearFormat),
        .init(id: "delete", title: String(localized: "Delete Block"), symbol: "trash", keywords: ["delete", "remove", "shanchu"], action: .delete),
    ]

    /// Every command that acts, groups opened, in order.
    static let leaves: [DocCommand] = {
        func flatten(_ commands: [DocCommand]) -> [DocCommand] { commands.flatMap { $0.isGroup ? flatten($0.children) : [$0] } }
        return flatten(all)
    }()

    /// "/3x4" (or 3*4, 3×4): a table that size, rows first, up to 9 by 9. A size on its
    /// way ("3x", the columns not typed yet) is the square one until they come.
    static func sized(_ query: String) -> DocCommand? {
        guard let match = query.wholeMatch(of: /([1-9])\s*[xX×*]\s*([1-9])?/), let rows = Int(match.1) else { return nil }
        let columns = match.2.flatMap { Int($0) } ?? rows
        return .init(id: "table-\(rows)x\(columns)", title: String(localized: "\(rows) × \(columns) Table"), symbol: "tablecells", action: .table(rows: rows, columns: columns))
    }

    /// The commands whose title or a keyword contains the query (case-insensitive), out
    /// of their groups: those it starts first ("biao": 标题 before 列表), each in order.
    /// None typed: the menu's top.
    static func matching(_ query: String) -> [DocCommand] {
        if let sized = sized(query) { return [sized] }
        let query = query.lowercased()
        guard !query.isEmpty else { return all }
        let words = { (command: DocCommand) in [command.title.lowercased()] + command.keywords }
        let starts = leaves.filter { words($0).contains { $0.hasPrefix(query) } }
        let contains = leaves.filter { command in !starts.contains(command) && words(command).contains { $0.contains(query) } }
        return starts + contains
    }
}

/// The command menu: "/" typed (at a block's start or after a space; "、" too, the slash
/// key's character with a Chinese input method; the keyboard bar's key types one
/// anywhere) opens it over the caret's line. Text typed after it filters the commands,
/// ↑↓ move, Return or a tap chooses. A group opens as the action menu's levels do (→ or
/// Return on it too): its commands take the menu's place under its title, which goes
/// back, as Backspace, Esc and ← do. Esc at the top, a space or a tap anywhere else
/// closes it.
@MainActor
@Observable
final class DocSlashMenu {
    private(set) var isOpen = false
    private(set) var query = ""
    private(set) var items: [DocCommand] = []
    /// The group shown, if one was opened.
    private(set) var group: DocCommand?
    var highlighted = 0
    /// The caret's rectangle where the menu opened, in the list's coordinates (the
    /// list's frame, not its scrolled content: where it is on screen, over the list).
    private(set) var anchor: CGRect = .zero
    /// Where the menu may go, in the same coordinates: the list on screen, down to the
    /// keyboard (over its bar).
    private(set) var room: CGRect = .infinite
    /// Where it shows (FlooDesignMenuOverlay.frame): on the side of the caret's line
    /// chosen as it opens, as tall as what it shows. Closed, it keeps its place and its
    /// rows while it goes.
    private(set) var frame: CGRect = .null
    /// The side it opened on: a group's commands and a query's grow and shrink from it.
    private var opensAbove = true
    /// Called with the chosen command.
    @ObservationIgnored var choose: (DocCommand) -> Void = { _ in }
    /// A tap anywhere but the menu: it closes.
    @ObservationIgnored var dismiss: () -> Void = {}

    var highlightedItem: DocCommand? { items.indices.contains(highlighted) ? items[highlighted] : nil }

    /// - Parameter place: the caret and the room for the menu, once its row has
    ///   rendered; the first one known is where the menu stays.
    func show(query: String, place: (anchor: CGRect, room: CGRect)?) {
        let opens = !isOpen
        if opens {
            group = nil
            frame = .null
        }
        if query != self.query || opens {
            if !query.isEmpty { group = nil }
            items = group?.children ?? DocCommand.matching(query)
            highlighted = 0
        }
        self.query = query
        isOpen = true
        if !frame.isNull {
            resize()
        } else if let place {
            self.place(anchor: place.anchor, room: place.room)
        }
    }

    /// Where it opened, or the room for it changed (the keyboard came or went): the side
    /// is chosen for the tallest it gets.
    func place(anchor: CGRect, room: CGRect) {
        self.anchor = anchor
        self.room = room
        opensAbove = FlooDesignMenuOverlay.opensAbove(over: anchor, in: room)
        resize()
    }

    /// As tall as what it shows now, on its side.
    private func resize() {
        guard isOpen, anchor != .zero else { return }
        frame = FlooDesignMenuOverlay.frame(over: anchor, in: room, rows: items.count, titled: group != nil, above: opensAbove)
    }

    /// A group's commands in the menu's place, under its title.
    func open(_ group: DocCommand) {
        guard group.isGroup else { return }
        self.group = group
        items = group.children
        highlighted = 0
        resize()
    }

    /// Back from a group (its title, Backspace, Esc, ←): the menu's top again, the group
    /// highlighted.
    func back() {
        guard let group else { return }
        self.group = nil
        items = DocCommand.matching(query)
        highlighted = items.firstIndex(of: group) ?? 0
        resize()
    }

    /// Closed: it goes where it is, as it is (its rows and place stay until it opens again).
    func close() {
        guard isOpen else { return }
        isOpen = false
        query = ""
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
    }
}

extension DocEditor {
    /// The slash key's characters: "/", and "、" with a Chinese input method.
    static let slashes: Set<String> = ["/", "、"]

    /// A "/" just typed at `offset` opens the menu.
    func slashTyped(in block: DocBlock, at offset: Int) {
        slashOrigin = DocPosition(block: block.id, offset: offset)
        updateSlash()
    }

    /// The keyboard bar's key: a "/" typed, the menu open.
    func typeSlash() {
        guard let selection, let view = textView(for: selection.head.block) else { return }
        let origin = DocPosition(block: selection.head.block, offset: min(selection.anchor.offset, selection.head.offset))
        replace(view.selectedRange, with: "/", in: view, block: origin.block)
        guard slashOrigin == nil, demo.doc.block(origin.block).map({ $0.text.string.utf16.dropFirst(origin.offset).first == 0x2F }) == true else { return }
        slashOrigin = origin
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
        // A space, or a query nothing matches (a path, a fraction typed on): it closes.
        guard query.count <= 24, !query.contains(where: \.isWhitespace), query.isEmpty || !DocCommand.matching(query).isEmpty
        else { return dismissSlash() }
        slash.show(query: query, place: slashPlace(origin))
        holdScrolling(in: textView(for: origin.block).flatMap(DocScrolling.list))
    }

    /// The query while an input method composes it (the model doesn't have it yet).
    /// Pinyin shows syllable breaks ("bi'ao", or a space): they aren't part of it.
    func slashComposing(_ query: String) {
        slash.show(query: query.filter { $0 != "'" && !$0.isWhitespace }, place: nil)
    }

    /// Only the menu's place, its query as it is (an input method may be composing it).
    func placeSlash() {
        guard slash.isOpen, let origin = slashOrigin, let place = slashPlace(origin) else { return }
        slash.place(anchor: place.anchor, room: place.room)
    }

    func dismissSlash() {
        slashOrigin = nil
        slash.close()
        holdScrolling(in: nil)
    }

    /// The page doesn't scroll while the menu is open (the menu stays by its slash).
    private func holdScrolling(in list: UIScrollView?) {
        guard heldList !== list else { return }
        heldList?.isScrollEnabled = true
        list?.isScrollEnabled = false
        heldList = list
    }

    /// Return (or a tap) on the menu: a group's commands take its place; a command
    /// removes "/query", then acts.
    func chooseSlash(_ item: DocCommand? = nil) {
        guard let origin = slashOrigin, let item = item ?? slash.highlightedItem,
            let selection, let block = demo.doc.block(origin.block)
        else { return dismissSlash() }
        if item.isGroup { return slash.open(item) }
        dismissSlash()
        guard let action = item.action else { return }
        perform(action, in: block, replacing: origin.offset..<selection.head.offset, from: selection.head)
    }

    /// Applies a command to a block: what `typed` covers (the "/query") goes, then the
    /// block becomes the command's kind (its text stays), or a divider or table goes in,
    /// in one step; the other commands act on the block as the format sheet's do. The
    /// command menu and the keyboard bar both come here.
    func perform(_ action: DocCommand.Action, in block: DocBlock, replacing typed: Range<Int>, from head: DocPosition) {
        let here = DocPosition(block: block.id, offset: typed.lowerBound)
        switch action {
        case .kind, .divider, .table, .page: break
        default:
            if !typed.isEmpty {
                commitSlash([.deleteText(block: block.id, range: typed, removed: DocText())],
                            from: DocSelection(anchor: head, head: head), to: DocSelection(anchor: here, head: here))
            }
            return act(action, on: block.id)
        }
        var steps: [DocStep] = typed.isEmpty ? [] : [.deleteText(block: block.id, range: typed, removed: DocText())]
        var caret = here
        switch action {
        case .kind(let kind):
            if kind != block.kind {
                steps.append(.setBlock(block: block.id, kind: kind, indent: block.indent, previousKind: block.kind, previousIndent: block.indent))
            }
        case .divider:
            let next = demo.newBlockID()
            if block.text.length == typed.count {
                // Only the slash was in the block (or nothing): it becomes the divider.
                steps.append(.setBlock(block: block.id, kind: .divider, indent: block.indent, previousKind: block.kind, previousIndent: block.indent))
                steps.append(.insertBlock(block: DocBlock(id: next, kind: .paragraph, indent: block.indent), after: block.id))
            } else {
                let divider = demo.newBlockID()
                steps.append(.insertBlock(block: DocBlock(id: divider, kind: .divider, indent: block.indent), after: block.id))
                steps.append(.insertBlock(block: DocBlock(id: next, kind: .paragraph, indent: block.indent), after: divider))
            }
            caret = DocPosition(block: next, offset: 0)
        case .page:
            // The words left (the "/query" gone) are the title; a line follows to write on.
            var title = block.text.string.utf16.map { $0 }
            title.removeSubrange(typed)
            let page = DocPage(doc: .generate(), title: String(decoding: title, as: UTF16.self).trimmingCharacters(in: .whitespaces))
            let next = demo.newBlockID()
            steps = block.text.isEmpty ? [] : [.deleteText(block: block.id, range: 0..<block.text.length, removed: block.text)]
            steps.append(.setBlock(block: block.id, kind: .page(page: page), indent: block.indent, previousKind: block.kind, previousIndent: block.indent))
            steps.append(.insertBlock(block: DocBlock(id: next, kind: .paragraph, indent: block.indent), after: block.id))
            commitSlash(steps, from: DocSelection(anchor: head, head: head), to: DocSelection(anchor: .init(block: next, offset: 0), head: .init(block: next, offset: 0)))
            dismissKeyboard()
            blocks.openPage?(block.id)
            return
        case .table(let rows, let columns):
            let keep = block.text.length > typed.count
            steps += tables.insertTable(rows: rows, columns: columns, replacing: block, keep: keep)
            return commitLeavingText(steps, from: DocSelection(anchor: head, head: head))
        default:
            return
        }
        guard !steps.isEmpty else { return }
        commitSlash(steps, from: DocSelection(anchor: head, head: head), to: DocSelection(anchor: caret, head: caret))
    }

    /// A command that isn't a kind, on the caret's block.
    private func act(_ action: DocCommand.Action, on id: DocBlockID) {
        let formatting = DocFormatting(editor: self, caretTakesBlock: true)
        switch action {
        case .indent(let delta): formatting.indent(by: delta)
        case .box: formatting.toggleBox()
        case .color(let token): formatting.setColor(token)
        case .copy: blocks.copy([id])
        case .duplicate: blocks.duplicate([id])
        case .clearFormat: clearFormat(of: [id])
        case .delete: blocks.delete([id])
        case .kind, .divider, .table, .page: break
        }
    }

    /// The slash's caret rectangle, and where the menu may go: the list on screen, less
    /// the bars over it and the keyboard (it may cover the keyboard's bar), in the
    /// overlay's coordinates (the list's frame's).
    private func slashPlace(_ origin: DocPosition) -> (anchor: CGRect, room: CGRect)? {
        guard let textView = textView(for: origin.block), let block = demo.doc.block(origin.block),
            let start = textStart(in: textView, block: block),
            let position = textView.position(from: textView.beginningOfDocument, offset: start + origin.offset),
            let list = DocScrolling.list(of: textView), let frame = list.superview
        else { return nil }
        let toOverlay = { (rect: CGRect) in rect.offsetBy(dx: -list.frame.minX, dy: -list.frame.minY) }
        let anchor = toOverlay(textView.convert(textView.caretRect(for: position), to: frame))
        var room = CGRect(origin: .zero, size: list.frame.size).inset(by: UIEdgeInsets(top: list.safeAreaInsets.top, left: 0, bottom: list.safeAreaInsets.bottom, right: 0))
        if !DocScrolling.keyboard.isNull, let window = list.window {
            let keyboard = toOverlay(frame.convert(window.convert(DocScrolling.keyboard, from: nil), from: window))
            // Down to the keyboard bar's middle, as Craft's (the room's edge is a gap
            // inside it).
            let floor = keyboard.minY - DocScrolling.keyboardBar / 2 + FlooDesignTokens.Component.Menu.gap
            if floor < room.maxY { room.size.height = max(0, floor - room.minY) }
        }
        return (anchor, room)
    }
}

/// The command menu on the page (FlooDesign's menu): over the caret's line, under it
/// when there's no room above, where it opened. It comes and goes with the reveal's
/// motion.
struct DocSlashMenuView: View {
    let menu: DocSlashMenu

    var body: some View {
        FlooDesignMenuOverlay(
            isPresented: menu.isOpen, frame: menu.frame, opensBelow: menu.frame.minY >= menu.anchor.maxY,
            entries: menu.items.map(\.entry), highlighted: menu.highlighted, page: menu.group?.id, title: menu.group?.title,
            onHighlight: { menu.highlighted = $0 },
            onChoose: { entry in
                if let item = menu.items.first(where: { $0.id == entry.id }) { menu.choose(item) }
            },
            onBack: { menu.back() },
            onDismiss: { menu.dismiss() }
        )
    }
}

extension DocCommand {
    /// The menu's row for it.
    var entry: FlooDesignMenuEntry {
        FlooDesignMenuEntry(id: id, title: title, symbol: symbol, swatch: swatch.map(DocColors.swatch), hasChildren: isGroup)
    }
}
