//
//  DocDestination.swift
//  DemoApp
//
//  The document page: top-anchored, one TiledView row per block, edited in place.
//  While the agent writes, the page is a read-only preview and the bar says so.
//

import SwiftUI
import MarkdownView
import MessagingUI

struct DocDestination: View {
    /// Code blocks are coloured by Highlightr, read and edited alike.
    static let highlighter = HighlightrCodeHighlighter()

    @State private var demo: DocDemo
    @State private var editor: DocEditor
    @State private var scrollPosition = TiledScrollPosition()
    @State private var reader = TiledViewReader<String>()

    static var autoruns: Bool { UserDefaults.standard.bool(forKey: "docAgent") }

    init() {
        let demo = DocDemo()
        _demo = State(initialValue: demo)
        _editor = State(initialValue: DocEditor(demo: demo))
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            TiledView(items: demo.rows, scrollPosition: $scrollPosition) { row in
                DocRowCell(item: row, demo: demo, editor: editor)
            }
            .reader(reader)
            .heightEstimate { row, width in
                row.estimatedHeight(width: width)
            }
            .overlay { DocSlashMenuView(menu: editor.slash) }
            .overlay(alignment: .bottom) { DocBlockSelectionBar(blocks: editor.blocks) }
        }
        .modifier(DocBlockOverlays(reader: reader, blocks: editor.blocks))
        .onChange(of: demo.focus?.serial) {
            if let id = demo.focus?.id { reader.scrollTo(id: id, anchor: .center) }
        }
        // The agent writing makes the whole page a preview (§6.3).
        .onChange(of: demo.isAgentWriting) {
            editor.blocks.clear()
            editor.isEditable = !demo.isAgentWriting
        }
        .task {
            // Opening a document starts at its top (TiledView's first offset tucks the
            // first row under the bar's edge).
            try? await Task.sleep(for: .milliseconds(150))
            if let first = demo.rows.first?.id { reader.scrollTo(id: first, anchor: .top, animated: false) }
            demo.rowFrame = { [reader] id in reader.frame(forItem: id) }
            editor.blocks.attach(reader)
            // -docShow code|math: open at the first code or math block; -docEdit YES edits it.
            if let kind = UserDefaults.standard.string(forKey: "docShow"),
               let row = demo.rows.first(where: { kind == "code" ? { if case .code = $0.sourceKind { true } else { false } }($0) : $0.sourceKind == .math }),
               let block = row.block {
                reader.scrollTo(id: row.id, anchor: .center, animated: false)
                if UserDefaults.standard.bool(forKey: "docEdit") {
                    try? await Task.sleep(for: .milliseconds(400))
                    editor.sources.focus(block)
                }
            }
            // -docShowTable YES: open at the first table (screenshots, trying tables out).
            if UserDefaults.standard.bool(forKey: "docShowTable"), let table = demo.rows.first(where: { $0.table != nil }) {
                reader.scrollTo(id: table.id, anchor: .center, animated: false)
                // -docEditCell YES: and edit a cell of it.
                if UserDefaults.standard.bool(forKey: "docEditCell"), let snapshot = table.table {
                    try? await Task.sleep(for: .milliseconds(400))
                    editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: 2, column: 1))
                }
            }
            // -docShowHandle YES: a list item's handle under the pointer and the item after
            // it selected (on a phone, selecting).
            if UserDefaults.standard.bool(forKey: "docShowHandle"),
               let index = demo.doc.blocks.firstIndex(where: { $0.text.string.hasPrefix("嵌套列表") }) {
                let blocks = demo.doc.blocks
                // A phone has no handle: its selection mode instead.
                if DocBlockController.usesHandles {
                    editor.blocks.click(blocks[index + 3].id)
                } else {
                    editor.blocks.beginSelecting(blocks[index + 3].id)
                }
                editor.blocks.testHover(blocks[index].id)
            }
            // -docShot <path>: what the options above show, drawn to a PNG there
            // (screenshots without screen recording).
            if let path = UserDefaults.standard.string(forKey: "docShot") {
                try? await Task.sleep(for: .milliseconds(800))
                if let hovered = editor.blocks.hovered { editor.blocks.testHover(hovered) }
                DocBlockController.drawWindow(to: path)
            }
            if UserDefaults.standard.bool(forKey: "docEditTest") {
                await DocEditTests(demo: demo, editor: editor).run()
            }
            if Self.autoruns {
                try? await Task.sleep(for: .seconds(1))
                demo.runScript()
            }
        }
    }

    @ViewBuilder
    private var bar: some View {
        HStack {
            if let status = demo.agentStatus {
                ProgressView()
                    .controlSize(.small)
                Text("Agent · \(status)")
                    .font(.subheadline)
                Text("只读预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("停止") { demo.stop() }
                    .buttonStyle(.bordered)
            } else {
                Button("撤销", systemImage: "arrow.uturn.backward") { editor.requestUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!demo.canUndo)
                Button("重做", systemImage: "arrow.uturn.forward") { editor.requestRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!demo.canRedo)
                Spacer()
                Button("重置") {
                    demo.reset()
                    editor.resetHistory()
                }
                Button("Agent 演示") { demo.runScript() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .labelStyle(.iconOnly)
    }
}

struct DocRowCell: TiledCellContent {
    let item: DocRow
    let demo: DocDemo
    let editor: DocEditor

    func body(context: CellContext<Void>) -> some View {
        let hooks = MainActor.assumeIsolated { [item, editor] in item.block.map { editor.hooks(for: $0) } }
        let (tables, sources) = MainActor.assumeIsolated { (editor.tables, editor.sources) }
        DocRowView(row: item, coordinator: demo.coordinator, hooks: hooks, tables: tables, sources: sources) { [item, editor] point in
            MainActor.assumeIsolated {
                if let block = item.block { editor.click(block, at: point) }
            }
        }
    }
}

private struct DocRowView: View {
    let row: DocRow
    let coordinator: StreamingRevealCoordinator<UUID>
    let hooks: MarkdownSelectableTextHooks?
    let tables: DocTableController
    let sources: DocSourceController
    /// A click in the row, in window coordinates.
    let onClick: (CGPoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // By position, not by the rendered block's id: an edit re-renders the block
            // with a new id, and the text view being typed in must stay the same view.
            if let table = row.table, !row.isStreaming {
                DocTableRowView(table: table, blocks: row.blocks, controller: tables)
            } else if let block = row.block, case .code(let language) = row.sourceKind, !row.isStreaming {
                DocCodeRowView(block: block, language: language, blocks: row.blocks, controller: sources)
            } else if let block = row.block, row.sourceKind == .math, !row.isStreaming {
                DocMathRowView(block: block, blocks: row.blocks, isEmpty: row.sourceIsEmpty, controller: sources)
            } else {
                ForEach(Array(row.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, DocBlockController.gutter)
        .frame(maxWidth: .infinity)
        // Tables and code change height when an editor comes or goes.
        .modifier(DocRowHeightReporter(isOn: row.table != nil || row.sourceKind != nil))
        .codeHighlighter(DocDestination.highlighter)
        // Wide tables scroll sideways instead of squeezing their columns.
        .markdownTableScrollable()
        // Code at the text's size, monospaced (the editor uses the same font).
        .font(Font(docCodeFont), for: .codeBlock)
        // The whole row takes the caret, not only its text: beside a short line, the
        // space around a list item, the row's padding. Behind the text view, so only
        // clicks that miss it land here.
        .background {
            if hooks != nil { RowClickArea(onClick: onClick) }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownStreamBlock) -> some View {
        let view = MarkdownStreamBlockView(block)
            // Rows are measured off screen before they show; math needs its real height then.
            .markdownDisplayMathRendersSynchronously()
            .environment(\.markdownSelectableTextHooks, hooks)
            .frame(maxWidth: .infinity, alignment: .leading)
        if row.isStreaming {
            view
                .markdownStreaming(coordinator.ensureManager(for: block.id))
                .markdownFadeReveal(
                    duration: 0.5,
                    startHue: MarkdownFadeRevealConfig.legacyHighlightStartHue,
                    endHue: MarkdownFadeRevealConfig.legacyHighlightEndHue
                )
        } else {
            view
        }
    }
}

/// A click in a row, in window coordinates (SwiftUI's global space is the cell's host).
private struct RowClickArea: UIViewRepresentable {
    let onClick: (CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:))))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onClick = onClick
    }

    func makeCoordinator() -> Coordinator { Coordinator(onClick: onClick) }

    final class Coordinator: NSObject {
        var onClick: (CGPoint) -> Void
        init(onClick: @escaping (CGPoint) -> Void) { self.onClick = onClick }
        @objc func click(_ recognizer: UITapGestureRecognizer) {
            onClick(recognizer.location(in: nil))
        }
    }
}

/// Rows changed (an edit, a measured height): the handle and the selection follow.
private struct DocBlockOverlays: ViewModifier {
    let reader: TiledViewReader<String>
    let blocks: DocBlockController

    func body(content: Content) -> some View {
        content.onChange(of: reader.version) {
            blocks.attach(reader)
            blocks.layoutOverlays()
        }
    }
}
