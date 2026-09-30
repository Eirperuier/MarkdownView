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
        UserDefaults.standard.string(forKey: "flooScenario").flatMap(Int.init).flatMap(FlooScenario.init(rawValue:))
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
            if let ask = demo.ask {
                FlooAskBar(ask: ask) { demo.respond($0) }
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
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .animation(.snappy, value: demo.ask)
        .animation(.snappy, value: demo.queued.map(\.id))
        .animation(.snappy, value: demo.showsErrands)
        .animation(.snappy, value: demo.presence.isEmpty)
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
                    + Text(entry.agent.rawValue).foregroundStyle(entry.agent.tint).fontWeight(.semibold)
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

/// A question an agent is waiting on you for; stays until you answer.
private struct FlooAskBar: View {
    let ask: FlooAsk
    let respond: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                Text("\(ask.agent.rawValue) 在等你")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(ask.agent.tint)
            Text(ask.question).font(.subheadline)
            HStack(spacing: 8) {
                ForEach(ask.options, id: \.self) { option in
                    Button(option) { respond(option) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ask.agent.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    var body: some View {
        content
            .frame(maxWidth: 720)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
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
        }
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
                Text(String(agent.rawValue.prefix(1)))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(agent.tint, in: Circle())
                Text(agent.rawValue).font(.subheadline.weight(.semibold))
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
        let view = MarkdownStreamBlockView(block)
            .markdownDisplayMathRendersSynchronously()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
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
            let size = card.flatMap { FlooDemoCards.all[$0]?.size } ?? .medium
            if let card, let session = demo.sessions[card], !session.tree.roots.isEmpty {
                FlooCardFrame(size: size) { CardView(tree: session.tree) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FlooPendingDraw(request: request, size: size)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case "floo.card":
            HStack(alignment: .top, spacing: 12) {
                ForEach(lines, id: \.self) { name in
                    if let session = demo.card(name) {
                        FlooCardFrame(size: FlooDemoCards.all[name]?.size ?? .medium) { CardView(tree: session.tree) }
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

/// A card in the chat: on the chat's own white, edged with a hairline.
private struct FlooCardFrame<Content: View>: View {
    let size: FlooDemoCards.Size
    @ViewBuilder var content: Content

    var body: some View {
        let width = size == .small ? 172.0 : 360.0
        let padding = size == .small ? 12.0 : 16.0
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

/// Where a card will be while it's drawn: what it will show.
private struct FlooPendingDraw: View {
    let request: String
    let size: FlooDemoCards.Size

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
            Text(request).font(.footnote).lineLimit(3)
        }
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(width: size == .small ? 172 : 360, height: size == .small ? 120 : 180, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
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
        case .block(let block, _): return prose(block.source) + 10
        case .fence(let language, _, _): return language == "floo.mention" ? 90 : 220
        }
    }
}
