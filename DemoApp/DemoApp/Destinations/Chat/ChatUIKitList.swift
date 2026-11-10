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
    let selection: MarkdownBlockSelectionController
    let heightCache: ChatHeightCache
    let renderedHeights: ChatRenderedHeights
    let benchmark: ChatBenchmark

    func makeUIView(context: Context) -> TiledListView<ChatRow> {
        let list = TiledListView<ChatRow> { [conversation, selection, renderedHeights] row in
            Self.content(for: row, conversation: conversation, selection: selection, renderedHeights: renderedHeights)
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
        list.onContentLayoutChange = { [selection, reader, benchmark] in
            selection.install(layout: reader)
            benchmark.contentLayoutChanged()
        }
        list.show(conversation.list)
        return list
    }

    /// Read here, so SwiftUI calls again when they change: the loader with older exchanges to
    /// load, and the reader told of scrolls while selecting.
    func updateUIView(_ list: TiledListView<ChatRow>, context: Context) {
        list.readerInvalidatesOnScroll = selection.state.isActive
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
        selection: MarkdownBlockSelectionController,
        renderedHeights: ChatRenderedHeights
    ) -> any TiledUIKitCellContent {
        switch row.kind {
        case .prompt(let text):
            return ChatUIKitPrompt(id: row.id, text: text, renderedHeights: renderedHeights)
        case .block(let block):
            if case .customFence = block.kind {
                return ChatHostedRow(row: row, conversation: conversation, selection: selection, renderedHeights: renderedHeights)
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
/// list draws it. Its height is the content's, measured once per width and told when it changes.
@MainActor
struct ChatHostedRow: TiledUIKitCellContent {
    let row: ChatRow
    let conversation: ChatConversation
    let selection: MarkdownBlockSelectionController
    let renderedHeights: ChatRenderedHeights

    static func makeRowView() -> ChatHostedRowView { ChatHostedRowView() }

    func configure(_ view: ChatHostedRowView, context: TiledUIKitCellContext) {
        view.show(content, id: row.id, context: context, renderedHeights: renderedHeights)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        ChatHostedRowView.height(of: content, id: row.id, width: width)
    }

    static func prepareForReuse(_ view: ChatHostedRowView) {
        view.reset()
    }

    private var content: ChatRowView {
        ChatRowView(row: row, conversation: conversation, selection: selection)
    }
}

@MainActor
final class ChatHostedRowView: UIView {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var id: String?
    private var context: TiledUIKitCellContext?
    private weak var renderedHeights: ChatRenderedHeights?

    /// Heights the content reported, by row and width.
    private static var heights: [String: [CGFloat: CGFloat]] = [:]
    private static let sizingHost: UIHostingController<AnyView> = {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        return host
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func height(of content: ChatRowView, id: String, width: CGFloat) -> CGFloat {
        if let known = heights[id]?[width] { return known }
        sizingHost.rootView = AnyView(content)
        let height = sizingHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        heights[id, default: [:]][width] = height
        return height
    }

    func show(_ content: ChatRowView, id: String, context: TiledUIKitCellContext, renderedHeights: ChatRenderedHeights) {
        self.id = id
        self.context = context
        self.renderedHeights = renderedHeights
        // At its own height, top first: a change in it (a card prepared) is told to the list.
        host.rootView = AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    MainActor.assumeIsolated { self?.contentSizeChanged(size) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
        )
        setNeedsLayout()
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard let id, size.width > 0, size.height > 0 else { return }
        // The height the row renders at, for the benchmark to hold the list's layout against.
        renderedHeights?.sizes[id] = size
        let known = Self.heights[id]?[size.width]
        guard known.map({ abs($0 - size.height) > 0.5 }) ?? true else { return }
        Self.heights[id, default: [:]][size.width] = size.height
        context?.heightDidChange(to: size.height)
    }

    func reset() {
        id = nil
        context = nil
        host.rootView = AnyView(EmptyView())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }
}
