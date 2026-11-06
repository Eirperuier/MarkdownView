//
//  FlooAgentWork.swift
//  DemoApp
//
//  An agent's work in its bubble (floo docs/prototypes/agent-process.html). A message is one
//  bubble with two states, a tap apart. By default it shows where the work is: three dots
//  while the agent thinks, the calls it's making while it makes them (their icons and what
//  each does), then its words. In detail it shows how the work went: how long it thought and
//  what, the calls it made one after another or together, then the words. The detail has a
//  ceiling and scrolls inside the bubble, on a TiledView of its own: only the lines in sight
//  are drawn.
//

import CardUI
import SwiftUI
import MarkdownView
import MessagingUI
import FlooUIKit

// MARK: - Model

/// One step of an agent's work in its message, in the order it went: a stretch of thinking,
/// or the calls one of its replies made together.
struct FlooStep: Hashable, Identifiable {
    enum Kind: Hashable {
        /// Its thinking; the words are the message's ``FlooThought`` under the step's id.
        case thinking
        /// The calls one reply made, side by side when there are several.
        case calls([FlooCall])
    }

    let id: String
    var kind: Kind
    /// Still going: thinking still being written, a call still running.
    var going: Bool
    var started: Date?
    var ended: Date?

    /// How long it took, in whole seconds, at least one; nil when it isn't known.
    var seconds: Int? {
        guard let started, let ended else { return nil }
        return max(1, Int(ended.timeIntervalSince(started).rounded()))
    }
}

/// A call, as people are shown it: what it does in the agent's words, under its service's
/// icon, or the site it's on.
struct FlooCall: Hashable, Identifiable {
    enum State: Hashable { case running, done, failed }

    enum Icon: Hashable {
        /// A site's own icon, by its host.
        case site(String)
        /// Its service's icon, an image.
        case image(URL)
        /// An SF Symbol, when the service has no image.
        case symbol(String)
    }

    let id: String
    /// What it does: the agent's words for it, else its operation's title.
    var says: String
    /// Its operation's title, else the tool's name.
    var title: String
    var icon: Icon
    /// Shown while a site's icon loads, or if it doesn't: the service's icon or symbol.
    var fallback: Icon?
    /// Where it went and what it came back with, when known: "huggingface.co".
    var detail: String?
    var state: State
    var started: Date?
    var ended: Date?
}

/// A stretch of an agent's thinking, as markdown streamed into blocks with their own reveal,
/// quicker than the words'.
@MainActor
final class FlooThought {
    private(set) var text = ""
    private var split: [MarkdownStreamBlock] = []
    /// `text` changed since it was split: split again when it's shown, not before (a folded
    /// thought in the history is never split).
    private var stale = false
    private var splits = 0
    private var splitter = MarkdownBlockSplitter()
    let coordinator = StreamingRevealCoordinator<UUID>(rate: .thinkingBlock)
    private var generation = 0
    /// It came in while shown: its words come out with their reveal. Thinking that was there
    /// before (history) shows whole.
    private(set) var streamed = false

    private var going = true

    /// Its words as blocks, split when first asked for after a change.
    var blocks: [MarkdownStreamBlock] {
        if stale { resplit() }
        return split
    }

    /// Sets what it has said so far; `going`: more is coming.
    func update(_ text: String, going: Bool) {
        if going { streamed = true }
        guard text != self.text || going != self.going else { return }
        self.text = text
        self.going = going
        stale = true
    }

    private func resplit() {
        let first = splits == 0
        stale = false
        splits += 1
        split = splitter.split(text, isStreaming: going)
        generation += 1
        coordinator.syncBlocks(split.map { ($0.id, $0.revealPlainTextCount) }, generation: generation)
        if !streamed {
            coordinator.revealAll()
        } else if !going, !first {
            coordinator.finishQuickly()
        }
    }
}

/// What an agent's work row shows: where the work is, or how it went (opened), words after it.
enum FlooWorkShown: Equatable {
    case status(FlooWorkStatus)
    case detail([FlooWorkLine], divided: Bool)
}

// MARK: - Default state

/// What a bubble shows by default before its words: where the work is.
struct FlooWorkStatus: Equatable {
    enum Kind: Equatable {
        case thinking
        /// The calls of the step it's at: those still running, else the last.
        case calls([FlooCall])
    }

    let kind: Kind

    init(_ steps: [FlooStep]) {
        guard let last = steps.last else {
            kind = .thinking
            return
        }
        switch last.kind {
        case .thinking:
            kind = .thinking
        case .calls(let calls):
            let running = calls.filter { $0.state == .running }
            kind = .calls(running.isEmpty ? Array(calls.suffix(1)) : running)
        }
    }

    /// Whether it shows what `other` does, its calls' words aside: thinking, or the same calls.
    func shows(as other: FlooWorkStatus) -> Bool {
        switch (kind, other.kind) {
        case (.thinking, .thinking): true
        case (.calls(let calls), .calls(let others)): calls.map(\.id) == others.map(\.id)
        default: false
        }
    }
}

struct FlooWorkStatusView: View {
    let status: FlooWorkStatus
    /// Each face's own size (by whether it's the thinking one), as last laid out.
    @State private var sizes: [Bool: CGSize] = [:]
    /// The bubble's size around it: the face that's on, going there with the layout spring.
    @State private var size: CGSize?

    private var thinking: Bool { status.kind == .thinking }

    var body: some View {
        // One face fades out as the other fades in, the bubble going from the one's size to
        // the other's; what of them is past its edge as it goes doesn't show.
        FlooStatusFrame(size: size) {
            ZStack(alignment: .topLeading) {
                switch status.kind {
                case .thinking:
                    FlooTypingDots()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { sizes[true] = $0 }
                        .transition(.opacity)
                case .calls(let calls):
                    FlooCallsLine(calls: calls)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { sizes[false] = $0 }
                        .transition(.opacity)
                }
            }
            .animation(AppMotion.step, value: thinking)
        }
        .mask {
            // The bubble: its padding around the face.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .padding(.horizontal, -14)
                .padding(.vertical, -10)
        }
        .onChange(of: sizes[thinking], initial: true) { _, new in
            guard let new, new != size else { return }
            guard size != nil else {
                size = new
                return
            }
            withAnimation(AppMotion.layout) { size = new }
        }
    }
}

/// As big as it's told, the face in it laid out at its own size from the top leading corner;
/// as big as the face until told.
private struct FlooStatusFrame: Layout {
    var size: CGSize?

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size?.width ?? 0, size?.height ?? 0) }
        set { if size != nil { size = CGSize(width: newValue.first, height: newValue.second) } }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let size else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        return CGSize(width: min(size.width, proposal.width ?? .infinity), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: proposal)
    }
}

/// iMessage's typing indicator: three dots rising and brightening in turn.
struct FlooTypingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(uiColor: .systemGray))
                    .frame(width: 8, height: 8)
                    .opacity(on ? 1 : 0.35)
                    .offset(y: on ? -1.5 : 0)
                    // Each a third of the pulse after the one before.
                    .animation(
                        AppMotion.pulse?.delay(Double(index) * 0.68 / 3),
                        value: on
                    )
            }
        }
        .frame(height: 18)
        .padding(.horizontal, 1)
        .onAppear { on = true }
        .accessibilityLabel("正在思考")
    }
}

/// The calls being made: their icons overlapping, each leaving as it's done, and what one of
/// them does at a time, turning over every two seconds.
struct FlooCallsLine: View {
    let calls: [FlooCall]

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: -7) {
                ForEach(calls) { call in
                    FlooCallIconView(icon: call.icon, fallback: call.fallback, size: 20)
                        .background(Color.flooReceived, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous).inset(by: -1.5))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(AppMotion.layout, value: calls.map(\.id))
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let says = calls.isEmpty ? "" : calls[Int(context.date.timeIntervalSinceReferenceDate / 2) % calls.count].says
                // The words turn over in place: the old go up, the new come from below.
                ZStack(alignment: .leading) {
                    Text(says)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .flooShimmer(calls.contains { $0.state == .running })
                        .id(says)
                        .transition(.push(from: .bottom).combined(with: .opacity))
                }
                .animation(AppMotion.layout, value: says)
            }
        }
        .frame(height: 20)
        .clipped()
    }
}

// MARK: - Detail

/// A line of the detail's list: a step's header, its thinking, one of its calls.
struct FlooWorkLine: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Thinking: still going, how long it took, whether its words are open.
        case thinking(going: Bool, seconds: Int?, open: Bool)
        /// The words being thought, their last lines.
        case thoughtTail([MarkdownStreamBlock])
        /// A block of thinking that's done, opened.
        case thoughtBlock(MarkdownStreamBlock)
        /// A call made alone, or one of several made together (`nested`).
        case call(FlooCall, nested: Bool)
        /// Calls made together: how many, whether any still runs, how long they took.
        case together(count: Int, going: Bool, seconds: Int?)
    }

    let id: String
    /// The message and step it's of: where its thinking's reveal is.
    let message: Int
    let step: String
    let kind: Kind
    /// Nothing follows it: the work's line stops at it.
    var last = false

    /// A rough height until it's measured.
    var estimate: CGFloat {
        switch kind {
        case .thinking, .together: 26
        case .thoughtTail: 96
        case .thoughtBlock(let block): CGFloat(max(1, block.source.count / 22)) * 18 + 6
        case .call(_, let nested): nested ? 40 : 46
        }
    }

    /// A message's work as lines: each step's header, then what's in it. A thought shows its
    /// last lines while it's written, and folds when done unless it's open.
    @MainActor static func lines(of steps: [FlooStep], message: Int, thoughts: [String: FlooThought], open: Set<String>) -> [FlooWorkLine] {
        var lines: [FlooWorkLine] = []
        for step in steps {
            switch step.kind {
            case .thinking:
                let opened = !step.going && open.contains(step.id)
                // Split only where it shows.
                let blocks = step.going || opened ? thoughts[step.id]?.blocks ?? [] : []
                lines.append(FlooWorkLine(
                    id: step.id, message: message, step: step.id,
                    kind: .thinking(going: step.going, seconds: step.seconds, open: opened)
                ))
                if step.going, !blocks.isEmpty {
                    lines.append(FlooWorkLine(
                        id: "\(step.id)/tail", message: message, step: step.id, kind: .thoughtTail(FlooThoughtTail.shown(blocks))
                    ))
                } else if opened {
                    lines += blocks.map {
                        FlooWorkLine(id: "\(step.id)/\($0.id)", message: message, step: step.id, kind: .thoughtBlock($0))
                    }
                }
            case .calls(let calls):
                if calls.count == 1, let call = calls.first {
                    lines.append(FlooWorkLine(id: call.id, message: message, step: step.id, kind: .call(call, nested: false)))
                } else {
                    lines.append(FlooWorkLine(
                        id: step.id, message: message, step: step.id,
                        kind: .together(count: calls.count, going: step.going, seconds: step.seconds)
                    ))
                    lines += calls.map {
                        FlooWorkLine(id: $0.id, message: message, step: step.id, kind: .call($0, nested: true))
                    }
                }
            }
        }
        if !lines.isEmpty { lines[lines.count - 1].last = true }
        return lines
    }
}

/// How the work went, in the bubble: a list of its own with a ceiling, scrolling inside it.
/// It follows the newest line while you're at its end; scrolled up, it stays where you are.
struct FlooWorkDetail: View {
    let lines: [FlooWorkLine]
    let demo: FlooDemo

    /// The tallest it gets before it scrolls.
    static let ceiling: CGFloat = 300

    @State private var scroll = TiledScrollPosition(autoScrollsToBottomOnAppend: true, scrollsToBottomOnReplace: true)
    @State private var above = false
    @State private var below = false

    var body: some View {
        TiledView(items: lines, scrollPosition: $scroll) { line in
            FlooWorkLineCell(item: line, demo: demo)
        }
        .heightEstimate { line, _ in line.estimate }
        .fitsContent(upTo: Self.ceiling)
        .onTiledScrollGeometryChange { geometry in
            scroll.autoScrollsToBottomOnAppend = geometry.pointsFromBottom < 24
            if above != (geometry.pointsFromTop > 2) { above = geometry.pointsFromTop > 2 }
            if below != (geometry.pointsFromBottom > 2) { below = geometry.pointsFromBottom > 2 }
        }
        .mask(alignment: .top) {
            // Where more is above or below, the edge fades. Both fades are always there: one
            // put in would fade in, hiding the rows under it until it has. The bottom one is
            // at the ceiling, where a list that scrolls ends, not on the rows it passes as it
            // grows there.
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: above ? 24 : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: below ? 24 : 0)
            }
            .frame(height: Self.ceiling)
        }
    }
}

struct FlooWorkLineCell: TiledCellContent {
    let item: FlooWorkLine
    let demo: FlooDemo

    func body(context: CellContext<Void>) -> some View {
        FlooWorkLineView(line: item, demo: demo)
    }
}

/// One line of the work: the timeline's column (a glyph on a step's first line, the line
/// going on down), then what it says.
private struct FlooWorkLineView: View {
    let line: FlooWorkLine
    let demo: FlooDemo

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            column
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, bottomSpace)
    }

    private var bottomSpace: CGFloat {
        switch line.kind {
        case .thinking(let going, _, let open): going || open || line.last ? 2 : 10
        case .thoughtTail, .thoughtBlock: line.last ? 2 : 6
        case .call(_, let nested): line.last ? 2 : nested ? 7 : 10
        case .together: 6
        }
    }

    /// The step's glyph on its header, and the line on to the next step.
    private var column: some View {
        ZStack(alignment: .top) {
            if !line.last {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                    .padding(.top, hasGlyph ? 24 : 0)
                    .padding(.bottom, -bottomSpace)
            }
            glyph
        }
        .frame(width: 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var hasGlyph: Bool {
        switch line.kind {
        case .thinking, .together: true
        case .call(_, let nested): !nested
        case .thoughtTail, .thoughtBlock: false
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch line.kind {
        case .thinking:
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        case .together:
            Image(systemName: "square.stack")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        case .call(let call, let nested) where !nested:
            FlooCallIconView(icon: call.icon, fallback: call.fallback, size: 20)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch line.kind {
        case .thinking(let going, let seconds, let open):
            Button {
                demo.toggleThought(line.message, line.step)
            } label: {
                HStack(spacing: 4) {
                    Text(going ? "正在思考" : seconds.map { "思考了 \($0) 秒" } ?? "思考过程")
                        .font(.subheadline)
                        .foregroundStyle(going ? .secondary : .primary)
                        .flooShimmer(going)
                    if !going {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .frame(minHeight: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(going)
        case .thoughtTail(let blocks):
            FlooThoughtTail(blocks: blocks, thought: demo.thought(line.message, line.step))
        case .thoughtBlock(let block):
            FlooThoughtBlock(block: block, thought: nil)
        case .call(let call, let nested):
            FlooCallRow(call: call, nested: nested)
        case .together(let count, let going, let seconds):
            Text(going ? "同时进行 \(count) 项" : "同时进行了 \(count) 项" + (seconds.map { " · \($0) 秒" } ?? ""))
                .font(.subheadline)
                .foregroundStyle(going ? .secondary : .primary)
                .flooShimmer(going)
                .frame(minHeight: 20)
        }
    }
}

/// A thought being written: its last five lines, the earlier ones fading out above.
struct FlooThoughtTail: View {
    let blocks: [MarkdownStreamBlock]
    let thought: FlooThought?

    static let tallest: CGFloat = 90

    /// Of a thought's blocks, the last ones that can show in it: laid out at all, the rest would
    /// be laid out again on every word that comes, the longer the thought the slower, to be cut
    /// off above. Counted generously — lines as long as a wide bubble's, twice its height — so
    /// what's left out never reaches it. Their reveal goes on without them (its coordinator's).
    static func shown(_ blocks: [MarkdownStreamBlock]) -> [MarkdownStreamBlock] {
        var height: CGFloat = 0
        var first = blocks.endIndex
        while first > blocks.startIndex, height < tallest * 2 {
            first -= 1
            let lines = blocks[first].source.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ($1.count + 59) / 60) }
            height += CGFloat(lines) * 15 + 6
        }
        return Array(blocks[first...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                FlooThoughtBlock(block: block, thought: thought)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: Self.tallest, alignment: .bottom)
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
                Rectangle()
            }
        }
    }
}

/// A block of thinking, in the words' markdown, smaller and quieter; revealed as it comes
/// when its thought is being written.
private struct FlooThoughtBlock: View {
    let block: MarkdownStreamBlock
    let thought: FlooThought?

    var body: some View {
        let view = MarkdownStreamBlockView(block)
            .markdownStreamBlockEdgeInsets(false)
            .markdownPlatformTypography(.thinking)
            .markdownBaseTextColor(.secondary)
            .foregroundStyle(.secondary)
        if let thought, thought.streamed {
            view
                .markdownStreaming(thought.coordinator.ensureManager(for: block.id))
                // As the words of the message are revealed.
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

extension MarkdownPlatformTypography {
    /// Thinking's: the footnote style for its words, its headings a step up and no bigger.
    static let thinking = MarkdownPlatformTypography(
        body: .init(.footnote),
        headings: [.init(.subheadline, weight: .semibold), .init(.footnote, weight: .semibold)]
    )
}

/// A call in the detail: its icon (when it's one of several), what it does, where it went,
/// and whether it's running, done or failed.
private struct FlooCallRow: View {
    let call: FlooCall
    let nested: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if nested {
                FlooCallIconView(icon: call.icon, fallback: call.fallback, size: 16)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(call.says)
                        .font(.subheadline)
                        .foregroundStyle(call.state == .running ? .secondary : .primary)
                        .flooShimmer(call.state == .running)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FlooCallState(state: call.state)
                }
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var meta: String {
        [call.title, call.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct FlooCallState: View {
    let state: FlooCall.State

    var body: some View {
        Group {
            switch state {
            case .running:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 14, height: 14)
        .animation(AppMotion.layout, value: state)
    }
}

// MARK: - Icons

/// A call's icon: a site's own, its service's image, or a symbol on a quiet tile; while a
/// site's icon loads (or if it doesn't), its fallback.
struct FlooCallIconView: View {
    let icon: FlooCall.Icon
    var fallback: FlooCall.Icon?
    var size: CGFloat

    var body: some View {
        Group {
            switch icon {
            case .site(let host):
                if let image = FlooFavicons.shared.icon(host) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(size * 0.16)
                        .frame(width: size, height: size)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                } else if let fallback, fallback != icon {
                    FlooCallIconView(icon: fallback, size: size)
                } else {
                    FlooCallIconView(icon: .symbol("globe"), size: size)
                }
            case .image(let url):
                // Its service's icon as Assets has it: the app's own copy of a device service's.
                AssetImage(url) {
                    RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous).fill(Color.primary.opacity(0.06))
                }
                .frame(width: size, height: size)
                .clipShape(FlooIconShape())
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Sites' icons, as cards get them (SiteIcon: favicon.im first, Google's after it), kept
/// as images for the views that show them, which redraw when one comes.
@MainActor
@Observable
final class FlooFavicons {
    static let shared = FlooFavicons()

    private var icons: [String: UIImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    /// The site's icon if it has come; asks for it if not.
    func icon(_ host: String) -> UIImage? {
        if let icon = icons[host] { return icon }
        guard asked.insert(host).inserted else { return nil }
        Task {
            guard let data = await SiteIcon.data(for: host), let image = UIImage(data: data) else { return }
            icons[host] = image
            MarkdownLinkChips.iconRevision.bump()
        }
        return nil
    }
}
