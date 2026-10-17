//
//  FlooDestination.swift
//  DemoApp
//
//  The floo demo page: a conversation on TiledView played from a script, with who is doing
//  what above the composer and a question waiting on you pinned there until answered.
//  `-flooScenario N` opens it playing scenario N.
//

import SwiftUI
import MarkdownView
import MessagingUI
import CardUI
import FlooDesign

struct FlooDestination: View {
    @State private var demo = FlooDemo()
    @State private var scenario = FlooDestination.launchScenario ?? .slowWork
    @State private var playing: Task<Void, Never>?
    @State private var scrolling = false
    @State private var fromBottom: CGFloat = 0
    /// Where the content ends: TiledView's own content size is a fixed, far larger space.
    @State private var contentEnd: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    /// The message being written and how far down the list it starts, until its start has
    /// reached the top.
    @State private var head: (id: String, y: CGFloat)?

    static var launchScenario: FlooScenario? {
        // Opened on a stage (`-flooStage`), it's the live conversation.
        if FlooLive.Stage.launched != nil, UserDefaults.standard.string(forKey: "flooScenario") == nil { return .live }
        return UserDefaults.standard.string(forKey: "flooScenario").flatMap(Int.init).flatMap(FlooScenario.init(rawValue:))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TiledView(items: demo.rows, scrollPosition: $demo.scrollPosition) { row in
                FlooRowCell(item: row, demo: demo)
            }
            .heightEstimate { row, width in
                row.estimatedHeight(width: width)
            }
            .itemBackground({ $0.bubble?.run }) { run, geometry in
                FlooBubbleBackground(state: demo.bubbleState(run), geometry: geometry)
            }
            // Following is yours to leave: only scrolling by hand changes it.
            .onTiledScrollGeometryChange { geometry in
                fromBottom = geometry.pointsFromBottom
                contentEnd = geometry.contentOffset.y + geometry.visibleSize.height + geometry.pointsFromBottom
                visibleHeight = geometry.visibleSize.height
                if scrolling { demo.following = geometry.pointsFromBottom < 80 }
            }
            .onTiledScrollPhaseChange { old, phase in
                let byHand = old == .interacting || old == .decelerating
                scrolling = phase == .interacting || phase == .decelerating
                if byHand, !scrolling, fromBottom < 80 { demo.following = true }
            }
            .overlay(alignment: .bottomTrailing) {
                if !demo.following {
                    Button {
                        demo.following = true
                        demo.scrollPosition.scrollTo(edge: .bottom, animated: true)
                    } label: {
                        Label(demo.presence.isEmpty ? "回到最新" : "还在写", systemImage: "arrow.down")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .onChange(of: demo.speaking) {
                head = demo.speaking.map { ($0, contentEnd) }
            }
            // Following the newest, until a message too long for the screen has its start at
            // the top: from there you read it at your pace, and it goes on writing below.
            .onChange(of: demo.rows) {
                guard demo.following else { return }
                if let head, contentEnd - head.y > visibleHeight - 60 {
                    self.head = nil
                    demo.following = false
                    demo.scrollPosition.scrollTo(id: head.id, anchor: .top, animated: true)
                } else {
                    demo.scrollPosition.scrollTo(edge: .bottom, animated: true)
                }
            }
            bottom
                // Something opened over the composer: what was at the bottom stays in sight.
                // Once the list has taken its new height: before, its bottom is where it was.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))  // try?: cancelled, no matter
                        guard demo.following else { return }
                        demo.scrollPosition.scrollTo(edge: .bottom, animated: true)
                    }
                }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { play() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(demo.title).font(.headline)
                Text(scenario.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                ForEach(FlooScenario.allCases) { item in
                    Button(item.name) {
                        scenario = item
                        play()
                    }
                }
            } label: {
                Image(systemName: "list.bullet").font(.body.weight(.medium))
            }
            Button {
                play()
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.body.weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Bottom

    private var bottom: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let approval = demo.approval {
                FlooApprovalBar(approval: approval) { demo.decide($0) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !demo.openAsks.isEmpty {
                if demo.showsAsks {
                    FlooAskList(waiting: demo.openAsks) { demo.jump(toAsk: $0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // What's waiting on you; one jumps to its card, more open the list.
                Button {
                    if demo.openAsks.count > 1 {
                        demo.showsAsks.toggle()
                    } else if let waiting = demo.openAsks.first {
                        demo.jump(toAsk: waiting)
                    }
                } label: {
                    FlooWaiting(count: demo.openAsks.count, tint: demo.openAsks.first?.card.agent.tint ?? .accentColor,
                                opens: demo.openAsks.count > 1, open: demo.showsAsks)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            if let answering = demo.answering {
                FlooAnswering(item: answering)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ForEach(demo.queued, id: \.id) { said in
                FlooQueued(text: said.text)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !demo.presence.isEmpty {
                if demo.showsErrands {
                    FlooErrandList(errands: demo.errands) { demo.jump(to: $0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // What they're at; what they have in hand, when it's more than one thing.
                Button {
                    if demo.errands.count > 1 {
                        demo.showsErrands.toggle()
                    } else if let errand = demo.errands.first {
                        demo.jump(to: errand)
                    }
                } label: {
                    FlooPresence(presence: demo.presence, opens: demo.errands.count > 1, open: demo.showsErrands)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            if demo.isLive {
                // The backend's conversation: what you type is sent.
                HStack(spacing: 10) {
                    TextField("发消息", text: $demo.draft, axis: .vertical)
                        .lineLimit(1...6)
                        .onSubmit { demo.sendDraft() }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    Button {
                        demo.sendDraft()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(demo.draft.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(demo.draft.isEmpty)
                }
            } else {
                HStack(spacing: 10) {
                    Text(demo.composer.isEmpty ? "发消息" : demo.composer)
                        .foregroundStyle(demo.composer.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(demo.composer.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .animation(FlooDesignTokens.Motion.layout, value: demo.openAsks.count)
        .animation(FlooDesignTokens.Motion.layout, value: demo.showsAsks)
        .animation(FlooDesignTokens.Motion.layout, value: demo.approval)
        .animation(FlooDesignTokens.Motion.layout, value: demo.answering)
        .animation(FlooDesignTokens.Motion.layout, value: demo.queued.map(\.id))
        .animation(FlooDesignTokens.Motion.layout, value: demo.showsErrands)
        .animation(FlooDesignTokens.Motion.layout, value: demo.presence.isEmpty)
    }

    private func play() {
        playing?.cancel()
        let demo = demo
        let scenario = scenario
        playing = Task {
            try? await scenario.play(demo)
        }
    }
}

// MARK: - Bottom parts

/// Who is doing what: one line however many are at it.
private struct FlooPresence: View {
    let presence: [(agent: FlooAgent, doing: String)]
    /// Whether it opens the list of what's in hand, and whether that's open.
    var opens = false
    var open = false

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            presence.enumerated().reduce(Text("")) { line, item in
                let (index, entry) = item
                let separator = index == 0 ? Text("") : Text("  ·  ").foregroundStyle(.tertiary)
                return line + separator
                    + Text(entry.agent.name).foregroundStyle(entry.agent.tint).fontWeight(.semibold)
                    + Text(" \(entry.doing)").foregroundStyle(.secondary)
            }
            .lineLimit(1)
            if opens {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// What you said while it was mid-message: sent, waiting for it to finish speaking.
private struct FlooQueued: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Label("它说完这段就看", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

/// What's waiting on you over the composer: one line however many asks are open.
private struct FlooWaiting: View {
    let count: Int
    let tint: Color
    /// Whether it opens the list of open asks, and whether that's open.
    var opens = false
    var open = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
            Text("\(count) 件在等你").fontWeight(.medium)
            if opens {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// The open asks, over the composer when there's more than one to jump to.
private struct FlooAskList: View {
    let waiting: [(message: Int, card: FlooAskCard)]
    let jump: ((message: Int, card: FlooAskCard)) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(waiting.enumerated()), id: \.element.card.id) { index, entry in
                if index > 0 {
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 35)
                }
                Button {
                    jump(entry)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "hourglass")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.card.agent.tint)
                            .frame(width: 15)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.card.agent.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(entry.card.agent.tint)
                            Text(entry.card.items.first { $0.answer == nil }?.question ?? "")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// What you're answering in your own words, over the composer while you write.
private struct FlooAnswering: View {
    let item: FlooAnsweringItem

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(item.agent.tint.opacity(0.6)).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 1) {
                Text("回答\(item.agent.name)").font(.caption.weight(.semibold)).foregroundStyle(item.agent.tint)
                Text(item.question).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
    }
}

/// Buttons in a row, as many as fit.
private struct FlowLayoutRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

/// Something an agent wants to do on one of your devices, as that device will do it; allowed
/// from the one in your hand whichever it runs on. Allowing is for this once; held, it offers
/// more. What can't be undone is only ever allowed once.
private struct FlooApprovalBar: View {
    let approval: FlooApproval
    let decide: (FlooDecision) -> Void
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: approval.device.contains("Mac") ? "laptopcomputer" : "iphone")
                Text("\(approval.agent.name) 要在\(approval.place) 上")
                Spacer(minLength: 8)
                Button {
                    details.toggle()
                } label: {
                    Text(details ? "收起" : "详情").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(approval.agent.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(approval.action).font(.subheadline.weight(.medium))
                ForEach(approval.details, id: \.self) { detail in
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if details {
                Text(approval.call)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("不用了") { decide(.denied) }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                if approval.dangerous || approval.standing.isEmpty {
                    Button(approval.confirm) { decide(.once) }
                        .buttonStyle(.borderedProminent)
                        .tint(approval.dangerous ? .red : approval.agent.tint)
                } else {
                    Menu {
                        Button("仅这一次") { decide(.once) }
                        ForEach(approval.standing, id: \.self) { choice in
                            Button(choice) { decide(.always(choice)) }
                        }
                    } label: {
                        Text(approval.confirm)
                    } primaryAction: {
                        decide(.once)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(approval.agent.tint)
                }
            }
            .controlSize(.small)
            if let hint = approval.dangerous || approval.standing.isEmpty
                ? nil : "长按「\(approval.confirm)」可以以后都允许"
            {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(approval.agent.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(FlooDesignTokens.Motion.layout, value: details)
    }
}

// MARK: - Rows

struct FlooRowCell: TiledCellContent {
    let item: FlooRow
    let demo: FlooDemo

    func body(context: CellContext<Void>) -> some View {
        FlooRowView(row: item, demo: demo)
    }
}

private struct FlooRowView: View {
    let row: FlooRow
    let demo: FlooDemo
    @Environment(\.updateSelfSizing) private var updateSelfSizing

    var body: some View {
        content
            .frame(maxWidth: 720)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(FlooBubbleState.space))
            // A card changes its row's height by itself (put in once drawn): the list takes
            // the height the row is laid out at, not one it measures while the card is going in.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if case .fence = row.kind { updateSelfSizing(measuredHeight: height) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .time(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .padding(.bottom, 4)
        case .unread(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 0.5)
                Text(text).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor).fixedSize()
                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 0.5)
            }
            .padding(.vertical, 12)
        case .catchUp(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.markdown(text)).font(.subheadline)
                Button {
                    demo.jump()
                } label: {
                    Label("跳到在等你的问题", systemImage: "arrow.down")
                }
                .font(.footnote.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 4)
        case .said(let speaker, let text, let receipt, let quote):
            said(speaker, text, receipt, quote)
        case .signature(let agent, let time, let marks):
            signature(agent, time, marks)
        case .process(let process, let expanded, let open):
            FlooWorkView(
                id: row.id,
                process: process,
                expanded: expanded,
                open: open,
                tint: row.message.flatMap(demo.message)?.agent.tint ?? .accentColor,
                demo: demo
            )
        case .block(let block, let streaming):
            markdown(block, streaming: streaming)
        case .fence(let language, let body, _):
            fence(language, body)
                .padding(.vertical, 6)
        case .choice(let choices, let chosen):
            FlooOptions(choices: choices, chosen: chosen, tint: tint, demo: demo) { index, option in
                demo.choose(row.id, index, option)
            }
            .padding(.vertical, 6)
        case .ask(let card):
            FlooAskView(card: card, demo: demo)
                .padding(.vertical, 6)
        case .mention(let mention):
            MentionView(mention)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
    }

    private var tint: Color {
        row.message.flatMap(demo.message)?.agent.tint ?? .accentColor
    }

    // MARK: People

    private func said(_ speaker: FlooSpeaker, _ text: String, _ receipt: FlooReceipt?, _ quote: String?) -> some View {
        Group {
            switch speaker {
            case .me:
                VStack(alignment: .trailing, spacing: 4) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let quote {
                            HStack(spacing: 8) {
                                Capsule().fill(Color.accentColor.opacity(0.5)).frame(width: 2.5)
                                Text(quote).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(text)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if let receipt {
                        FlooReceiptLabel(receipt: receipt)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
            case .person(let name):
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    Text(text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 48)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Agents

    private func signature(_ agent: FlooAgent, _ time: String, _ marks: [FlooMark]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(String(agent.name.prefix(1)))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(agent.tint, in: Circle())
                Text(agent.name).font(.subheadline.weight(.semibold))
                Text(time).font(.caption).foregroundStyle(.secondary)
                if marks.contains(.proactive) {
                    Text("主动")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(agent.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(agent.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                switch mark {
                case .proactive:
                    EmptyView()
                case .continuing(let what):
                    Label(what, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .notified(let why):
                    Label(why, systemImage: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .joined(let errand):
                    Button {
                        demo.jumpToErrand(titled: errand)
                    } label: {
                        Label("并进 \(errand)", systemImage: "arrow.triangle.merge")
                            .font(.caption)
                            .foregroundStyle(agent.tint)
                    }
                    .buttonStyle(.plain)
                case .soFar(let how):
                    Button {
                        demo.jumpToWork(of: agent)
                    } label: {
                        Label(how, systemImage: "circle.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(agent.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func markdown(_ block: MarkdownStreamBlock, streaming: Bool) -> some View {
        if let bubble = row.bubble {
            let message = streaming ? row.message.flatMap(demo.message) : nil
            let tells = Self.reportsReveal(block)
            FlooBubblePiece(
                bubble: bubble,
                row: row.id,
                state: demo.bubbleState(bubble.run),
                heading: Self.isHeading(block),
                reveals: message != nil && tells,
                starts: tells ? nil : message?.coordinator.ensureManager(for: block.id),
                indent: CGFloat(block.descriptor.listItemContext?.depth ?? 0) * 20
            ) {
                revealing(
                    MarkdownStreamBlockView(block)
                        .markdownDisplayMathRendersSynchronously()
                        // The bubble spaces its blocks.
                        .markdownStreamBlockEdgeInsets(false),
                    block,
                    streaming: streaming
                )
            }
        } else {
            revealing(
                MarkdownStreamBlockView(block)
                    .markdownDisplayMathRendersSynchronously()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5),
                block,
                streaming: streaming
            )
        }
    }

    private static func isHeading(_ block: MarkdownStreamBlock) -> Bool {
        if case .heading = block.descriptor.kind { true } else { false }
    }

    /// Whether the block's reveal can say how far it has got: a paragraph, a heading, a list
    /// item without code in it, a table (down to its last row started).
    private static func reportsReveal(_ block: MarkdownStreamBlock) -> Bool {
        switch block.descriptor.kind {
        case .paragraph, .heading, .table:
            return true
        case .orderedList, .unorderedList:
            return !block.source.contains("```") && !block.source.contains("~~~")
        default:
            return false
        }
    }

    @ViewBuilder
    private func revealing(_ view: some View, _ block: MarkdownStreamBlock, streaming: Bool) -> some View {
        if streaming, let message = row.message.flatMap(demo.message) {
            view
                .markdownStreaming(message.coordinator.ensureManager(for: block.id))
                .markdownFadeReveal(
                    duration: 0.5,
                    startHue: MarkdownFadeRevealConfig.legacyHighlightStartHue,
                    endHue: MarkdownFadeRevealConfig.legacyHighlightEndHue
                )
        } else {
            view
        }
    }

    // MARK: Fences

    @ViewBuilder
    private func fence(_ language: String, _ body: String) -> some View {
        let lines = body.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        switch language {
        case "floo.draw":
            let card = FlooDemo.cardName(language, lines)
            let request = lines.first { !$0.hasPrefix("card:") } ?? ""
            let size = card.flatMap { FlooDemoCards.all[$0]?.size ?? demo.cardSizes[$0] } ?? .medium
            FlooDrawnCard(request: request, size: size, session: card.flatMap { demo.sessions[$0] })
                .frame(maxWidth: .infinity, alignment: .leading)
        case "floo.card":
            HStack(alignment: .top, spacing: 12) {
                ForEach(lines, id: \.self) { name in
                    if let session = demo.card(name) {
                        FlooCardFrame(size: FlooDemoCards.all[name]?.size ?? demo.cardSizes[name] ?? .medium) {
                            CardView(tree: session.tree)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case "floo.mention":
            if let mention = lines.first.flatMap({ FlooDemoMentions.all[$0] }) {
                MentionView(mention, now: FlooDemoMentions.date(30, 16, 0))
            }
        default:
            EmptyView()
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

/// Tappable next steps under a sentence or inside an ask: bordered chips, full-width rows
/// when an option has a detail line, or a row of tiles when it carries an image or a small
/// card. An option not yet tappable is dimmed; the one you picked is marked 选了, and picking
/// another later is allowed.
private struct FlooOptions: View {
    let choices: [FlooChoice]
    var chosen: Int? = nil
    let tint: Color
    let demo: FlooDemo
    let pick: (Int, FlooOption) -> Void

    private var tiled: Bool { choices.contains { $0.option.image != nil || $0.option.from != nil } }
    private var detailed: Bool { choices.contains { $0.option.detail != nil } }

    var body: some View {
        if tiled { tiles } else if detailed { rows } else { chips }
    }

    private var chips: some View {
        FlowLayoutRow {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    pick(index, choice.option)
                } label: {
                    // Conditional views inside a Button label don't re-render on
                    // TiledView's reconfigure pass — keep the mark always in the tree.
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .opacity(chosen == index ? 1 : 0)
                            .frame(width: chosen == index ? nil : 0)
                        Text(choice.option.label)
                        Text("选了")
                            .font(.caption.weight(.medium))
                            .opacity(chosen == index ? 1 : 0)
                            .frame(width: chosen == index ? nil : 0)
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(chosen == index ? tint : nil)
                .disabled(!choice.tappable)
                .opacity(choice.tappable ? 1 : 0.45)
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Options that carry a detail line, one tappable row each.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    pick(index, choice.option)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(tint)
                            .opacity(chosen == index ? 1 : 0)
                            .frame(width: chosen == index ? nil : 0)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(choice.option.label).font(.subheadline.weight(.semibold))
                                Text("选了")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(tint)
                                    .opacity(chosen == index ? 1 : 0)
                                    .frame(width: chosen == index ? nil : 0)
                            }
                            if let detail = choice.option.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tint.opacity(chosen == index ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!choice.tappable)
                .opacity(choice.tappable ? 1 : 0.45)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    Button {
                        pick(index, choice.option)
                    } label: {
                        tile(choice, index: index)
                    }
                    .buttonStyle(.plain)
                    .disabled(!choice.tappable)
                    .opacity(choice.tappable ? 1 : 0.45)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ choice: FlooChoice, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = choice.option.image {
                Image(image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 150, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let from = choice.option.from {
                optionFrom(from)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                        .opacity(chosen == index ? 1 : 0)
                        .frame(width: chosen == index ? nil : 0)
                    Text(choice.option.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(chosen == index ? tint : .primary)
                        .lineLimit(2)
                    Text("选了")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                        .opacity(chosen == index ? 1 : 0)
                        .frame(width: chosen == index ? nil : 0)
                }
                if let detail = choice.option.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .frame(width: 172, alignment: .topLeading)
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// What a `from:` option carries: the result's small card, or a compact mention.
    @ViewBuilder
    private func optionFrom(_ from: String) -> some View {
        if let mention = FlooDemoMentions.all[from] {
            MentionView(mention, now: FlooDemoMentions.date(30, 16, 0))
        } else if let session = demo.card(from) {
            FlooCardFrame(size: FlooDemoCards.all[from]?.size ?? .small) { CardView(tree: session.tree) }
        }
    }
}

/// An agent's ask on the message that asked it: its items answered one at a time, the card
/// and the entry over the composer turning answered together.
private struct FlooAskView: View {
    let card: FlooAskCard
    let demo: FlooDemo
    /// Toggled options of a choose(multiple:) item, before "好了" sends them.
    @State private var picked: [Int: Set<Int>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text("\(card.agent.name) \(state)")
                if card.items.count > 1 {
                    Text("· \(card.items.count) 项")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(card.state == .open ? card.agent.tint : .secondary)
            ForEach(Array(card.items.enumerated()), id: \.offset) { index, item in
                self.item(item, at: index)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            card.state == .answered ? Color(uiColor: .secondarySystemBackground) : card.agent.tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var icon: String {
        switch card.state {
        case .open: "hourglass"
        case .answered: "checkmark"
        case .withdrawn: "xmark"
        case .expired: "clock"
        }
    }

    private var state: String {
        switch card.state {
        case .open: "在问你"
        case .answered: "已答"
        case .withdrawn: "已撤回"
        case .expired: "过期了"
        }
    }

    private var dead: Bool { card.state == .withdrawn || card.state == .expired }

    @ViewBuilder
    private func item(_ item: FlooAskItem, at index: Int) -> some View {
        if let answer = item.answer {
            Label("你答了：\(answer)", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.question)
                    .font(.subheadline)
                    .strikethrough(dead)
                    .foregroundStyle(dead ? .secondary : .primary)
                if card.state == .open {
                    form(item, at: index)
                }
            }
        }
    }

    @ViewBuilder
    private func form(_ item: FlooAskItem, at index: Int) -> some View {
        switch item.form {
        case .choose(let options, let multiple, let own):
            if multiple {
                FlowLayoutRow {
                    ForEach(Array(options.enumerated()), id: \.offset) { option, o in
                        let on = picked[index, default: []].contains(option)
                        Button(o.label) {
                            picked[index, default: []] = picked[index, default: []].symmetricDifference([option])
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(on ? card.agent.tint : .secondary)
                    }
                    Button("好了") {
                        demo.answerAsk(card.id, item: index, .options(Array(picked[index, default: []])))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(card.agent.tint)
                    .disabled(picked[index, default: []].isEmpty)
                }
                .controlSize(.small)
            } else {
                FlooOptions(choices: options.map { FlooChoice(option: $0, tappable: true) },
                            tint: card.agent.tint, demo: demo) { option, _ in
                    demo.answerAsk(card.id, item: index, .option(option))
                }
                if own != nil {
                    Button {
                        demo.answerAsk(card.id, item: index, .own)
                    } label: {
                        Label("其他…", systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                }
            }
        case .confirm(let effect, let yes, let no):
            Text(effect).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(yes) { demo.answerAsk(card.id, item: index, .confirm(true)) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(card.agent.tint)
                Button(no) { demo.answerAsk(card.id, item: index, .confirm(false)) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            .controlSize(.small)
        case .fill(let fields):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(fields, id: \.label) { field in
                    HStack(spacing: 8) {
                        Label(field.label, systemImage: Self.fieldIcon(field.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(field.guess)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(card.agent.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            Button("就这样") { demo.answerAsk(card.id, item: index, .fill) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }

    private static func fieldIcon(_ kind: FlooAskItem.Field.Kind) -> String {
        switch kind {
        case .text: "textformat"
        case .number: "number"
        case .date: "calendar"
        case .time: "clock"
        case .place: "mappin"
        case .person: "person"
        }
    }
}

private struct FlooReceiptLabel: View {
    let receipt: FlooReceipt

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(receipt.label)
        }
        .font(.caption2)
        .foregroundStyle(receipt == .unseen ? Color.orange : Color.secondary)
        .contentTransition(.opacity)
    }

    private var icon: String {
        switch receipt {
        case .delivered: "checkmark"
        case .unseen: "clock"
        case .read: "eye"
        case .answered: "checkmark.circle.fill"
        }
    }
}

/// A block of an agent's words in its bubble: the received side of a chat, as a person's
/// bubble is spaced (padding, room left on the far side). The block draws no bubble; it tells
/// its bubble where its words are and how much of them is revealed, and the bubble is drawn
/// once behind all its blocks (`FlooBubbleBackground`).
private struct FlooBubblePiece<Content: View>: View {
    let bubble: FlooBubble
    let row: String
    let state: FlooBubbleState
    /// A heading has more room above it than the blocks between, as on a page.
    var heading = false
    /// Its words are revealed as they stream, and tell how far that has got.
    var reveals = false
    /// The reveal of a block that can't tell how far it has got (code, math): it shows
    /// whole once its reveal starts.
    var starts: StreamingRevealManager? = nil
    /// How far the words start in from the bubble's text edge, past what their reveal measures
    /// (a nested list item's indent).
    var indent: CGFloat = 0
    @ViewBuilder var content: Content

    /// What the words' reveal last told: nil before it has, nil inside once all is revealed.
    @State private var told: CGSize??
    /// The words as laid out whole.
    @State private var whole: CGSize = .zero
    /// Where the words can be in the row.
    @State private var frame: CGRect?
    @State private var started = false
    @State private var listener: UUID?

    /// The revealed words' size: all of them unless they're being revealed; nil until known.
    private var revealed: CGSize? {
        if reveals {
            guard let told else { return nil }
            guard let told else { return whole == .zero ? nil : whole }
            return told.height > 0 ? CGSize(width: told.width + indent, height: told.height) : .zero
        }
        if let starts, !started, starts.revealedCount == 0 { return .zero }
        return whole == .zero ? nil : whole
    }

    /// Told even with no words yet: a row on screen that has none isn't one that finished
    /// out of sight (the bubble draws those whole, from the row's frame).
    private var shown: FlooBubbleState.Shown? {
        guard let frame else { return nil }
        return FlooBubbleState.Shown(
            words: revealed.map { CGRect(origin: frame.origin, size: $0) },
            whole: CGRect(origin: frame.origin, size: whole),
            room: frame.width
        )
    }

    var body: some View {
        FlooBubbleWords {
            content
                .markdownRevealedExtent(tell)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { whole = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FlooBubbleState.space)) } action: { frame = $0 }
        .padding(.horizontal, 14)
        .padding(.top, bubble.top ? 10 : heading ? 14 : 6)
        .padding(.bottom, bubble.last ? 10 : 6)
        .padding(.top, bubble.top ? 4 : 0)
        .padding(.bottom, bubble.last ? 4 : 0)
        .padding(.trailing, 48)
        .onChange(of: shown, initial: true) { _, shown in
            guard var shown else { return }
            let before = state.rows[row]
            // A row comes back into view before its reveal tells again: keep what it told.
            if shown.words == nil { shown.words = before?.words }
            guard shown != before else { return }
            // Only the reveal moving on animates the bubble; where the words are laid out is
            // the list's to move, and the bubble is there at once.
            // While revealing the bubble follows the revealed words, after that the whole words:
            // more words streaming in below the reveal don't move it.
            // Words told for the first time are laid out, not revealed: the bubble is there at once.
            let laidOut = before.map {
                $0.words == nil || $0.whole.origin != shown.whole.origin || $0.room != shown.room
                    || (state.finished.contains(row) && $0.whole != shown.whole)
            } ?? true
            var transaction = Transaction(animation: FlooDesignTokens.Motion.layout)
            if laidOut { transaction.disablesAnimations = true }
            withTransaction(transaction) { state.rows[row] = shown }
        }
        .onAppear { listen() }
        .onDisappear {
            if let listener { starts?.removeListener(listener) }
            listener = nil
        }
    }

    /// Where the words' reveal tells how far it has got.
    private var tell: (@MainActor (CGSize?) -> Void)? {
        guard reveals else { return nil }
        return { told = .some($0) }
    }

    private func listen() {
        guard let starts, listener == nil else { return }
        listener = starts.addListener { count in
            if count > 0, !started { started = true }
        }
    }
}

/// A bubble, drawn once behind the blocks it holds: around what of their words is revealed,
/// as wide as the widest revealed line. While the words stream it grows with the layout spring;
/// words already there have it whole.
private struct FlooBubbleBackground: View {
    let state: FlooBubbleState
    let geometry: TiledItemBackgroundGeometry<String>

    private static var radius: CGFloat { 18 }

    /// The bubble in the run's space, and whether any of it shows.
    private var bubble: (rect: CGRect, shown: Bool) {
        var first: CGRect?
        var last: CGRect?
        var width: CGFloat = 0
        var room: CGFloat = .infinity
        var start: CGRect?
        // Where words start across and how wide they can be, from any row that told.
        let column = geometry.items.lazy.compactMap { state.rows[$0.id] }.first
        for item in geometry.items {
            let done = state.finished.contains(item.id)
            let words: CGRect
            if let told = state.rows[item.id] {
                // A row whose reveal finished, on screen or off, is whole.
                guard let revealed = done ? told.whole : told.words else { continue }
                words = revealed
                room = min(room, told.room)
            } else if done, let column {
                // All revealed but never on screen: its words fill its row.
                words = CGRect(
                    x: column.whole.minX, y: 10,
                    width: column.room, height: max(0, item.frame.height - 20)
                )
            } else {
                continue
            }
            let placed = words.offsetBy(dx: item.frame.minX, dy: item.frame.minY)
            if start == nil { start = placed }
            guard placed.height > 0 else { continue }
            if first == nil { first = placed }
            last = placed
            width = max(width, placed.width)
        }
        guard let first, let last else {
            // Nothing shown yet: no bigger than its padding where the words will start.
            let origin = start?.origin ?? .zero
            return (CGRect(x: origin.x - 14, y: origin.y - 10, width: 28, height: 0), false)
        }
        return (
            CGRect(x: first.minX - 14, y: first.minY - 10, width: min(width, room) + 28, height: last.maxY - first.minY + 20),
            true
        )
    }


    var body: some View {
        let bubble = bubble
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(Color.flooReceived)
            .frame(width: bubble.rect.width, height: bubble.rect.height)
            .offset(x: bubble.rect.minX, y: bubble.rect.minY)
            // It shows up around its first words, fading in there; it doesn't fly in from
            // where it stood before it had any.
            .transaction(value: bubble.shown) { $0.animation = nil }
            .opacity(bubble.shown ? 1 : 0)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
}

/// A block's words as wide as they come out, never wider than there's room for. The words
/// keep the lines they were laid out in at the room there is: laid out again at their own
/// width, text can break its lines differently (a closing comma that hung past the edge).
private struct FlooBubbleWords: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let words = subviews.first else { return .zero }
        let size = words.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: min(proposal.width ?? .infinity, size.width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: proposal.width, height: nil))
    }
}

extension Color {
    /// iMessage's received grey: the system's secondary fill as it shows on the page, opaque.
    static let flooReceived = Color(uiColor: UIColor { traits in
        let fill = UIColor.secondarySystemFill.resolvedColor(with: traits)
        let page = UIColor.systemBackground.resolvedColor(with: traits)
        var f: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) = (0, 0, 0, 0)
        var p: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) = (0, 0, 0, 0)
        fill.getRed(&f.r, green: &f.g, blue: &f.b, alpha: &f.a)
        page.getRed(&p.r, green: &p.g, blue: &p.b, alpha: &p.a)
        return UIColor(red: p.r + (f.r - p.r) * f.a, green: p.g + (f.g - p.g) * f.a, blue: p.b + (f.b - p.b) * f.a, alpha: 1)
    })
}

/// A card in the chat: on the chat's own white, edged with a hairline.
private struct FlooCardFrame<Content: View>: View {
    let size: FlooDemoCards.Size
    @ViewBuilder var content: Content

    var body: some View {
        let width = size.width
        let padding = size.padding
        let radius = size == .small ? 18.0 : 20.0
        CardPanel(padding: padding, cornerRadius: radius) {
            content.frame(width: width - 2 * padding, alignment: .topLeading)
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
}

/// A card a model draws, in its place. While it's drawn, its frame stands at the height
/// cards of its size come out at, with what it will show and a light passing over it.
/// Once drawn whole, the card is laid out out of sight first; with its height known, the
/// frame takes that height in one move as the card fades in, and the rows below move with
/// it (its row tells the list). Nothing in between is shown: a card growing as it streams would push the
/// conversation on every chunk.
private struct FlooDrawnCard: View {
    let request: String
    let size: FlooDemoCards.Size
    let session: CardSession?
    /// The finished card's height, as laid out out of sight; it may take a pass or two.
    @State private var measuring: CGFloat?
    /// The card is in place: from the start for one drawn before the row was built.
    @State private var shown: Bool

    init(request: String, size: FlooDemoCards.Size, session: CardSession?) {
        self.request = request
        self.size = size
        self.session = session
        _shown = State(initialValue: session.map(Self.drawn) ?? false)
    }

    /// Finished with nothing to show, it never is: the request stays, still.
    private static func drawn(_ session: CardSession) -> Bool {
        session.isFinal && !session.tree.roots.isEmpty
    }

    var body: some View {
        FlooCardFrame(size: size) {
            Group {
                if shown, let session {
                    CardView(tree: session.tree)
                        .transition(.opacity)
                } else {
                    Color.clear.frame(height: size.drawingHeight - 2 * size.padding)
                }
            }
            .background {
                if !shown { FlooDrawingSweep(active: !(session?.isFinal ?? false), padding: size.padding) }
            }
            // Over the card's place, not in it: the frame's height is the card's alone.
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(request).lineLimit(size == .small ? 3 : 4)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .flooShimmer(!(session?.isFinal ?? false))
                .opacity(shown ? 0 : 1)
            }
        }
        // Outside the panel, so what the card sets as its background isn't the panel's yet.
        .background(alignment: .topLeading) {
            if !shown, let session, Self.drawn(session) {
                CardView(tree: session.tree)
                    .frame(width: size.width - 2 * size.padding)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuring = $0 }
            }
        }
        .task(id: measuring) {
            guard measuring != nil, !shown else { return }
            // Settled when a few frames pass with no new height.
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
            // Its row tells the list its new height, and the rows after it follow.
            withAnimation(FlooDesignTokens.Motion.layout) { shown = true }
        }
    }
}

/// A light passing across the whole of a card's place while it's drawn, slower than the
/// one over words at work: the card is coming, it isn't stuck.
private struct FlooDrawingSweep: View {
    let active: Bool
    let padding: Double

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            GeometryReader { geometry in
                let band = geometry.size.width * 0.6
                LinearGradient(
                    colors: [.clear, .primary.opacity(0.05), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + phase * (geometry.size.width + band))
            }
            .opacity(active ? 1 : 0)
        }
        // To the panel's edge, not just the content's.
        .padding(-padding)
        .allowsHitTesting(false)
    }
}

extension FlooDemoCards.Size {
    var width: Double { self == .small ? 172 : 360 }
    var padding: Double { self == .small ? 12 : 16 }

    /// The height a card of this size is drawn in until it's there: about what the cards
    /// come out at (the demo's medium ones are 300 to 370 with the frame), so the frame
    /// moves little when the card arrives.
    var drawingHeight: Double { self == .small ? 170 : 320 }
}

extension FlooRow {
    /// A rough height for the list until the row is measured.
    func estimatedHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(100, min(width, 720) - 32)
        func prose(_ text: String) -> CGFloat {
            let perLine = max(1, Int(textWidth / 16))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
            return CGFloat(lines) * 24
        }
        switch kind {
        case .time: return 40
        case .unread: return 36
        case .catchUp(let text): return prose(text) + 70
        case .said(_, let text, _, let quote): return prose(text) + (quote.map { prose($0) * 0.8 + 6 } ?? 0) + 52
        case .signature(_, _, let marks): return 40 + CGFloat(marks.count) * 18
        case .process(let process, let expanded, let open):
            guard expanded else { return 30 }
            guard !process.tasks.isEmpty else { return 40 + CGFloat(process.steps.count) * 21 }
            let steps = process.tasks.filter { open.contains($0.id) }.reduce(0) { $0 + $1.steps.count }
            return 40 + CGFloat(process.tasks.count) * 44 + CGFloat(steps) * 21
        case .block(let block, _): return prose(block.source) + (bubble == nil ? 10 : 20)
        case .fence(let language, let body, _):
            guard language != "floo.mention" else { return 90 }
            let card = FlooDemo.cardName(language, body.split(separator: "\n").map(String.init))
            return (card.flatMap { FlooDemoCards.all[$0]?.size } ?? .medium).drawingHeight + 12
        case .mention: return 90
        case .choice(let choices, _):
            if choices.contains(where: { $0.option.image != nil || $0.option.from != nil }) { return 230 }
            if choices.contains(where: { $0.option.detail != nil }) { return 14 + CGFloat(choices.count) * 56 }
            return 56
        case .ask(let card):
            return 60 + CGFloat(card.items.reduce(0) { sum, item in
                if item.answer != nil { return sum + 24 }
                switch item.form {
                case .choose(let options, _, _):
                    if options.contains(where: { $0.image != nil || $0.from != nil }) { return sum + 250 }
                    if options.contains(where: { $0.detail != nil }) { return sum + 46 + options.count * 56 }
                    return sum + 90
                case .confirm: return sum + 100
                case .fill(let fields): return sum + 40 + fields.count * 30
                }
            })
        }
    }
}
