//
//  ChatUIKitList.swift
//  DemoApp
//
//  The chat's list from UIKit (`TiledListView`), under `-chatRenderer uikit`: the same rows,
//  hooks and loader as the SwiftUI `TiledView`, with no SwiftUI in the list. A card is SwiftUI by
//  nature (CardView): its row is a UIKit row that hosts it.
//

import MarkdownView
import MessagingUI
import SwiftUI
import UIKit

/// Which list shows the UIKit rows: `TiledListView` (the default) or, with `-chatList swiftui`,
/// SwiftUI's `TiledView`, to compare on one build.
enum ChatList {
    static let usesUIKit = UserDefaults.standard.string(forKey: "chatList") != "swiftui"
}

struct ChatUIKitList: UIViewRepresentable {
    let conversation: ChatConversation
    let reader: TiledViewReader<String>
    let heightCache: ChatHeightCache
    let renderedHeights: ChatRenderedHeights
    let benchmark: ChatBenchmark

    func makeUIView(context: Context) -> TiledListView<ChatRow> {
        let list = TiledListView<ChatRow> { [conversation, renderedHeights] row in
            Self.content(for: row, conversation: conversation, renderedHeights: renderedHeights)
        }
        list.scrollPosition = TiledScrollPosition(autoScrollsToBottomOnAppend: true, scrollsToBottomOnReplace: true)
        list.prepareAhead = { ChatCards.prepare($0) }
        list.reader = reader
        list.heightHint = { [heightCache] row, width in
            MainActor.assumeIsolated { heightCache.height(for: row, width: width) }
        }
        list.heightEstimate = { row, width in row.estimatedHeight(width: width) }
        list.onItemHeightMeasured = { [heightCache] row, width, height in
            MainActor.assumeIsolated { heightCache.record(height, for: row, width: width) }
        }
        list.onContentLayoutChange = { [benchmark] in
            benchmark.contentLayoutChanged()
        }
        list.show(conversation.list)
        return list
    }

    /// Read here, so SwiftUI calls again when they change: the loader with older exchanges to
    /// load, and the reader told of scrolls while selecting.
    func updateUIView(_ list: TiledListView<ChatRow>, context: Context) {
        let hasOlder = conversation.hasOlder
        if hasOlder != (list.prependLoader != nil) {
            list.prependLoader = hasOlder ? .loader(perform: { [conversation] in
                await conversation.loadOlder(ChatDestination.pageSize, latency: ChatDestination.pageLatency)
            }) {
                ChatLoadingIndicator()
            } : nil
        }
    }

    static func content(
        for row: ChatRow,
        conversation: ChatConversation,
        renderedHeights: ChatRenderedHeights
    ) -> any TiledUIKitCellContent {
        switch row.kind {
        case .prompt(let text):
            return ChatUIKitPrompt(id: row.id, text: text, renderedHeights: renderedHeights)
        case .block(let block):
            if case .customFence = block.kind {
                return ChatHostedRow(row: row, conversation: conversation, renderedHeights: renderedHeights)
            }
            if let control = ChatRowControl.current {
                return ChatControlRow(source: block.source, control: control)
            }
            return ChatUIKitBlock(id: row.id, block: block, isStreaming: row.isStreaming, conversation: conversation, renderedHeights: renderedHeights)
        }
    }
}

/// The loader's spinner, as the SwiftUI list's `ProgressView` with its padding.
private final class ChatLoadingIndicator: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(frame: .zero)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            spinner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A row whose content is SwiftUI (a card): a UIKit row hosting `ChatRowView`, as the SwiftUI
/// list draws it (HostedRowView).
@MainActor
struct ChatHostedRow: TiledUIKitCellContent {
    let row: ChatRow
    let conversation: ChatConversation
    let renderedHeights: ChatRenderedHeights

    static func makeRowView() -> HostedRowView { HostedRowView() }

    func configure(_ view: HostedRowView, context: TiledUIKitCellContext) {
        view.show(content, key: row.id, context: context)
        // The height the row renders at, for the benchmark to hold the list's layout against.
        view.onSize = { [id = row.id, renderedHeights] size in renderedHeights.sizes[id] = size }
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        HostedRowView.height(of: content, key: row.id, width: width)
    }

    static func prepareForReuse(_ view: HostedRowView) {
        view.reset()
    }

    private var content: ChatRowView {
        ChatRowView(row: row, conversation: conversation)
    }
}
