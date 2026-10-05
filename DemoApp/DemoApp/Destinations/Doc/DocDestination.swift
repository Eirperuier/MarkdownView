//
//  DocDestination.swift
//  DemoApp
//
//  The document page: top-anchored, one TiledView row per block. Reading only for now
//  (editing is D3); while the agent writes, the page is a preview and the bar says so.
//

import SwiftUI
import MarkdownView
import MessagingUI

struct DocDestination: View {
    @State private var demo = DocDemo()
    @State private var scrollPosition = TiledScrollPosition()
    @State private var reader = TiledViewReader<String>()

    static var autoruns: Bool { UserDefaults.standard.bool(forKey: "docAgent") }

    var body: some View {
        VStack(spacing: 0) {
            bar
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            TiledView(items: demo.rows, scrollPosition: $scrollPosition) { row in
                DocRowCell(item: row, demo: demo)
            }
            .reader(reader)
            .heightEstimate { row, width in
                row.estimatedHeight(width: width)
            }
        }
        .onChange(of: demo.focus?.serial) {
            if let id = demo.focus?.id { reader.scrollTo(id: id, anchor: .center) }
        }
        .task {
            // Opening a document starts at its top (TiledView's first offset tucks the
            // first row under the bar's edge).
            try? await Task.sleep(for: .milliseconds(150))
            if let first = demo.rows.first?.id { reader.scrollTo(id: first, anchor: .top, animated: false) }
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
                Picker("改写过渡", selection: $demo.replaceStyle) {
                    ForEach(DocReplaceStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Button("重置") { demo.reset() }
                Button("Agent 演示") { demo.runScript() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct DocRowCell: TiledCellContent {
    let item: DocRow
    let demo: DocDemo

    func body(context: CellContext<Void>) -> some View {
        DocRowView(row: item, coordinator: demo.coordinator)
    }
}

private struct DocRowView: View {
    let row: DocRow
    let coordinator: StreamingRevealCoordinator<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(row.blocks) { block in
                blockView(block)
            }
        }
        .padding(.leading, CGFloat(row.indent) * 22)
        .opacity(row.isFading ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.3), value: row.isFading)
        .padding(.vertical, 5)
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownStreamBlock) -> some View {
        let view = MarkdownStreamBlockView(block)
            // Rows are measured off screen before they show; math needs its real height then.
            .markdownDisplayMathRendersSynchronously()
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
