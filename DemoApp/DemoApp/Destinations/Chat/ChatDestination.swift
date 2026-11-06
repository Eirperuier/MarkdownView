//
//  ChatDestination.swift
//  DemoApp
//
//  A chat list on MessagingUI's TiledView, one cell per markdown block, with streaming
//  replies, block selection over the list and a benchmark.
//

import SwiftUI
import MarkdownView
import MessagingUI
import FlooUIKit

extension TiledViewReader: MarkdownBlockSelectionLayout where ID == String {
    public var layoutVersion: UInt { version }

    public func scrollToContentOffsetY(_ y: CGFloat) {
        scrollToContentOffsetY(y, animated: false)
    }
}

struct ChatDestination: View {
    @State private var conversation = ChatConversation()
    @State private var scrollPosition = TiledScrollPosition(
        autoScrollsToBottomOnAppend: true,
        scrollsToBottomOnReplace: true
    )
    @State private var reader = TiledViewReader<String>()
    @State private var selection = {
        let selection = MarkdownBlockSelectionController()
        selection.motion = AppMotion.markdown
        return selection
    }()
    @State private var heightCache = ChatHeightCache()
    @State private var renderedHeights = ChatRenderedHeights()
    @State private var benchmark = ChatBenchmark()
    @State private var streamTask: Task<Void, Never>?
    @State private var exchanges = 100
    @State private var paged = false

    /// A paged conversation shows this many exchanges at first and loads this many more
    /// each time the list reaches the top, after `pageLatency` (a fetch).
    static let pageSize = 10
    static let pageLatency = Duration.milliseconds(300)

    var body: some View {
        VStack(spacing: 0) {
            bar
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            list
        }
        .overlay(alignment: .bottom) {
            if !benchmark.results.isEmpty || benchmark.isRunning {
                benchmarkPanel
            }
        }
        .task {
            selection.itemsProvider = { [conversation] in
                conversation.rows.map {
                    switch $0.kind {
                    case .prompt: .init(id: $0.id, group: "\($0.exchange)", role: .groupHeader)
                    case .block: .init(id: $0.id, group: "\($0.exchange)", role: .candidate)
                    }
                }
            }
            if let count = ChatBenchmark.autorunExchanges {
                await runBenchmark(count)
                // Time for a profiler attached to the run to finish its trace (more when
                // profiling a few scenarios, where the recording's end is harder to aim).
                try? await Task.sleep(for: .seconds(ChatBenchmark.onlyScenarios == nil ? 3 : 20))
                exit(0)
            }
            if conversation.rows.isEmpty {
                seed()
            }
            await ChatProbe.run(reader: reader, send: send)
        }
    }

    // MARK: Bar

    @ViewBuilder
    private var bar: some View {
        if selection.state.isActive {
            HStack {
                Text("\(selection.state.selectedItemIDs.count) selected")
                Spacer()
                Button("Done") { selection.exitMode() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            HStack {
                Picker("Exchanges", selection: $exchanges) {
                    ForEach([20, 100, 300], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: exchanges) { seed() }
                Toggle("Paged", isOn: $paged)
                    .fixedSize()
                    .onChange(of: paged) { seed() }
                Button(streamTask == nil ? "Send" : "Stop") {
                    streamTask == nil ? send() : stop()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Benchmark") {
                    Task { await runBenchmark(exchanges) }
                }
                .disabled(benchmark.isRunning || streamTask != nil)
            }
        }
    }

    // MARK: List

    private var list: some View {
        TiledView(items: conversation.rows, scrollPosition: $scrollPosition) { row in
            ChatRowCell(item: row, conversation: conversation, selection: selection, renderedHeights: renderedHeights)
        }
        .itemUIKitCell { [conversation, renderedHeights] row -> (any TiledUIKitCellContent)? in
            guard row.drawsInUIKit, case .block(let block) = row.kind else { return nil }
            return ChatUIKitBlock(id: row.id, block: block, isStreaming: row.isStreaming, conversation: conversation, renderedHeights: renderedHeights)
        }
        .prependLoader(conversation.hasOlder ? .loader(perform: { [conversation] in
            await conversation.loadOlder(Self.pageSize, latency: Self.pageLatency)
        }) {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } : nil)
        .reader(reader, invalidatesOnScroll: selection.state.isActive)
        .heightHint { [heightCache] row, width in
            MainActor.assumeIsolated { heightCache.height(for: row, width: width) }
        }
        .heightEstimate { row, width in
            row.estimatedHeight(width: width)
        }
        .onItemHeightMeasured { [heightCache] row, width, height in
            MainActor.assumeIsolated { heightCache.record(height, for: row, width: width) }
        }
        .onTiledContentLayoutChange {
            selection.install(layout: reader)
            benchmark.contentLayoutChanged()
        }
        .overlay(alignment: .topLeading) {
            // TiledView lays out past the top and bottom safe area but inside the side ones
            // (a Catalyst sidebar); the overlay does the same, to share its origin.
            MarkdownBlockSelectionOverlay(controller: selection)
                .ignoresSafeArea(edges: .vertical)
        }
    }

    private var benchmarkPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(benchmark.isRunning ? "Running… \(benchmark.header)" : benchmark.header)
                .font(.caption.bold())
            ForEach(benchmark.results) { result in
                Text(result.line)
            }
            if !benchmark.isRunning, let budget = benchmark.results.first?.stats.budgetMilliseconds {
                Text(String(format: "frame budget %.1fms · hitch <5 good, 5–10 noticeable, >10 bad", budget))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospaced())
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding()
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func seed() {
        conversation.seed(exchanges, loaded: paged ? Self.pageSize : nil)
    }

    private func send() {
        streamTask = Task {
            await conversation.stream(ChatCorpus.longReply, every: .milliseconds(30))
            streamTask = nil
        }
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func runBenchmark(_ count: Int) async {
        selection.exitMode()
        await benchmark.run(
            exchanges: count,
            conversation: conversation,
            reader: reader,
            heightCache: heightCache,
            renderedHeights: renderedHeights
        )
    }
}

struct ChatRowCell: TiledCellContent {
    let item: ChatRow
    let conversation: ChatConversation
    let selection: MarkdownBlockSelectionController
    let renderedHeights: ChatRenderedHeights

    func body(context: CellContext<Void>) -> some View {
        ChatRowView(row: item, conversation: conversation, selection: selection)
            // The height the row renders at, for the benchmark to hold the list's layout against.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [renderedHeights, id = item.id] size in
                MainActor.assumeIsolated { renderedHeights.sizes[id] = size }
            }
    }
}

private struct ChatRowView: View {
    let row: ChatRow
    let conversation: ChatConversation
    let selection: MarkdownBlockSelectionController

    var body: some View {
        Group {
            switch row.kind {
            case .prompt(let text):
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
            case .block(let block):
                blockView(block)
                    .padding(.vertical, 5)
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownStreamBlock) -> some View {
        let view = MarkdownStreamBlockView(block)
            // Rows are measured off screen before they show; math needs its real height then.
            .markdownDisplayMathRendersSynchronously()
            .environment(\.markdownSelectableTextHooks, selection.hooks(for: row.id))
            .frame(maxWidth: .infinity, alignment: .leading)
        if row.isStreaming {
            view
                .markdownStreaming(conversation.coordinator.ensureManager(for: block.id))
                .markdownFadeReveal(
                    duration: AppMotion.streamReveal.duration,
                    startHue: MarkdownFadeRevealConfig.legacyHighlightStartHue,
                    endHue: MarkdownFadeRevealConfig.legacyHighlightEndHue
                )
        } else {
            view
        }
    }
}
