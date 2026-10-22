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
import CardModel
import CardUI
import DocKit
import FlooDesign
import Wire
import ChatBackgrounds

/// A subtitle under the window's or the bar's title, where the system has one: the Mac, and
/// iOS from 26.
private struct Subtitle: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
            content.navigationSubtitle(text)
        #elseif os(iOS)
            if #available(iOS 26, *) { content.navigationSubtitle(text) } else { content }
        #else
            content
        #endif
    }
}

struct FlooDestination: View {
    @State private var demo = FlooDemo()
    // Opened as it is, it's the real conversation: the floo server, once you're signed in.
    @State private var scenario = FlooDestination.launchScenario ?? .live
    @State private var playing: Task<Void, Never>?
    @State private var scrolling = false
    @State private var fromBottom: CGFloat = 0
    /// Where the content ends: TiledView's own content size is a fixed, far larger space.
    @State private var contentEnd: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    /// The message being written and how far down the list it starts, until its start has
    /// reached the top.
    @State private var head: (id: String, y: CGFloat)?
    #if DEBUG
    /// The list's offsets, for `-flooScrollSweep` (FlooScrollSweep).
    @State private var sweepReader = TiledViewReader<String>()
    #endif
    /// The chat's background, by its names (ChatBackground's "Aurora" "Green"); "plain": the page's own.
    @AppStorage("flooChatBackground") private var backgroundName = "plain"
    /// A topic's name as you type it.
    @State private var topicTitle = ""
    /// The zones to pick the person's from, from the account menu.
    @State private var picksZone = false
    @FocusState private var composerFocused: Bool
    /// The window's inspector, where the person's mini programs open.
    @Environment(WindowInspector.self) private var inspector
    @Environment(\.colorScheme) private var colorScheme

    /// The widest a row gets, its margins with it.
    static let rowsWidth: CGFloat = 720 + 2 * 16

    static var launchScenario: FlooScenario? {
        // Opened on a stage (`-flooStage`), it's the live conversation.
        if FlooLive.Stage.launched != nil, UserDefaults.standard.string(forKey: "flooScenario") == nil { return .live }
        return UserDefaults.standard.string(forKey: "flooScenario").flatMap(Int.init).flatMap(FlooScenario.init(rawValue:))
    }

    var body: some View {
        VStack(spacing: 0) {
            TiledView(list: demo.list, scrollPosition: $demo.scrollPosition) { row in
                FlooRowCell(item: row, demo: demo)
            }
            // Older messages a page at a time as you reach the top (the device's store first).
            .prependLoader(demo.hasOlder ? .loader(perform: { [demo] in await demo.loadOlder() }) {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            } : nil)
            .heightEstimate { row, width in
                row.estimatedHeight(width: width)
            }
            #if DEBUG
            .reader(FlooScrollSweep.speed == nil ? nil : sweepReader)
            #endif
            .itemBackground({ $0.bubble?.run }) { run, geometry in
                FlooBubbleBackground(run: run, state: demo.bubbleState(run), geometry: geometry, demo: demo)
            }
            .itemContextMenu { [demo] row in FlooMessageMenu.menu(for: row, demo: demo) }
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
            #if DEBUG
            .task { if let speed = FlooScrollSweep.speed { await FlooScrollSweep.run(sweepReader, speed: speed) } }
            #endif
            .onChange(of: demo.speaking) {
                head = demo.speaking.map { ($0, contentEnd) }
            }
            // Following the newest, until a message too long for the screen has its start at
            // the top: from there you read it at your pace, and it goes on writing below.
            // The newest is at the end: something opened or closed above it isn't followed.
            .onChange(of: demo.lastRow) {
                guard demo.following else { return }
                if let head, contentEnd - head.y > visibleHeight - 60 {
                    self.head = nil
                    demo.following = false
                    demo.scrollPosition.scrollTo(id: head.id, anchor: .top, animated: true)
                } else {
                    demo.scrollPosition.scrollTo(edge: .bottom, animated: true)
                }
            }
            // Signing in to the floo server, then the zone they go by when the account has none:
            // the form until you're in, and nothing to type into.
            .overlay {
                if let signIn = demo.signIn {
                    FlooSignInView(model: signIn)
                } else if let choice = demo.zoneChoice {
                    FlooZoneChoiceView(model: choice)
                }
            }
            if demo.signIn == nil, demo.zoneChoice == nil {
                // Something opening over the composer shortens the list, which keeps its bottom.
                bottom
            }
        }
        // The rows' width at most: the list keeps it as the conversation gets narrower or wider
        // (an inspector coming in), moving along rather than laying its rows out again.
        .tiledMaxContentWidth(Self.rowsWidth)
        // Over a picked background, dark throughout: white words on material bubbles, and cards
        // that ask for no background of their own on the same. Plain, as the system shows.
        .cardPanelStyle(background == nil ? AnyShapeStyle(.background) : AnyShapeStyle(.ultraThinMaterial))
        .background { FlooChatBackground(background: background) }
        .environment(\.colorScheme, background == nil ? colorScheme : .dark)
        .environment(\.flooOnBackground, background != nil)
        .navigationTitle(demo.title)
        .modifier(Subtitle(text: demo.isLive && demo.origin != nil ? "话题 · 在\(demo.origin?.title ?? "")" : scenario.name))
        .toolbar { toolbar }
        .sheet(isPresented: $picksZone) {
            FlooZonePicker(selected: demo.usualZone) { zone in
                Task {
                    do { try await demo.live?.setUsualZone(zone) } catch { demo.catchUp("时区没改成：\(error)") }
                }
            }
        }
        .sheet(isPresented: $demo.startsGroup) {
            if let live = demo.live { FlooNewGroupView(live: live) }
        }
        .sheet(isPresented: $demo.showsServices) {
            if let live = demo.live { FlooContactsDestination(live: live) }
        }
        // Beside the conversation, as the Mac app's inspector: what the rows can spare of
        // their width before they get narrower, measured while it's away.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if !inspector.isPresented { inspector.spare = width - Self.rowsWidth }
        }
        .onDisappear { inspector.close("floo") }
        .alert("开话题", isPresented: Binding(get: { demo.naming != nil }, set: { if !$0 { demo.naming = nil } })) {
            TextField("话题名", text: $topicTitle)
            Button("开") {
                if let message = demo.naming {
                    let title = topicTitle.trimmingCharacters(in: .whitespaces)
                    demo.openTopic(on: message, title: title.isEmpty ? "话题" : title)
                }
                topicTitle = ""
            }
            Button("取消", role: .cancel) { topicTitle = "" }
        } message: {
            Text("话题会进对话列表，管家在里面接着这条消息聊。")
        }
        // A page the agent wrote, read only: what's on the backend is the agent's to change.
        .sheet(item: $demo.openPage) { page in
            DocDestination(doc: page.doc)
        }
        .sheet(item: $demo.openThing) { thing in
            FlooThingView(thing: thing)
        }
        .alert("无法打开", isPresented: $demo.cannotOpen) {
            Button("好", role: .cancel) {}
        } message: {
            Text("这台设备上找不到它。")
        }
        .task { play() }
    }

    // MARK: Toolbar

    /// The conversation's bar: where it hangs, then where to go, then how the demo runs, then who's in.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // In a topic: back to where it hangs.
        if demo.isLive, let origin = demo.origin {
            ToolbarItem(placement: .navigation) {
                Button("回到\(origin.title)", systemImage: "chevron.left") { demo.go(to: origin) }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if demo.isLive, demo.signedIn != nil || !demo.places.isEmpty {
                placesMenu
            }
            if demo.isLive, demo.live?.server != nil {
                Button("小程序", systemImage: "square.grid.2x2") {
                    if let server = demo.live?.server {
                        inspector.toggle("floo", width: 400) { FlooProgramsView(programs: FlooPrograms(server: server)) }
                    }
                }
            }
        }
        if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItemGroup(placement: .primaryAction) {
            if let cards = demo.cardModel {
                cardModelMenu(cards)
            }
            backgroundMenu
            Menu("场景", systemImage: "list.bullet") {
                ForEach(FlooScenario.allCases) { item in
                    Button(item.name) {
                        scenario = item
                        play()
                    }
                }
            }
            Button("重来", systemImage: "arrow.counterclockwise") { play() }
        }
        if let account = demo.signedIn {
            if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            ToolbarItem(placement: .primaryAction) {
                Menu("账号", systemImage: "person.crop.circle") {
                    if let email = account.email { Text(email) }
                    Button {
                        picksZone = true
                    } label: {
                        Label {
                            Text("时区")
                            if let zone = demo.usualZone { Text(FlooZones.name(of: zone)) }
                        } icon: {
                            Image(systemName: "globe")
                        }
                    }
                    Button("退出登录", role: .destructive) {
                        Task {
                            try? await account.auth.signOut()  // try?: the kept session may be gone already
                            #if targetEnvironment(macCatalyst)
                            await FlooHelper.stop()
                            #endif
                            play()
                        }
                    }
                }
            }
        }
    }

    /// The backend's conversations to go to, and starting a group or connecting a service.
    private var placesMenu: some View {
        Menu {
            Picker("对话", selection: Binding(
                get: { demo.place?.id ?? "" },
                set: { id in if let place = demo.places.first(where: { $0.id == id }) { demo.go(to: place) } }
            )) {
                ForEach(demo.places) { place in
                    Label(place.unread > 0 ? "\(place.title)（\(place.unread)）" : place.title, systemImage: Self.symbol(place))
                        .tag(place.id)
                }
            }
            .pickerStyle(.inline)
            // The list comes a page at a time; the next one is added here.
            if demo.hasMorePlaces {
                Button("显示更多", systemImage: "ellipsis") { demo.morePlaces() }
            }
            Divider()
            Button("新建群聊…", systemImage: "person.2") { demo.startsGroup = true }
            Button("连接服务…", systemImage: "link") { demo.showsServices = true }
        } label: {
            Label("对话", systemImage: "bubble.left.and.bubble.right")
        }
    }

    private static func symbol(_ place: FlooPlace) -> String {
        switch place.kind {
        case .main: "house"
        case .group: "person.2"
        case .topic: "bubble.left.and.text.bubble.right"
        case .service: "app"
        }
    }

    /// Nil: plain.
    private var background: ChatBackground? {
        let names = backgroundName.split(separator: "/").map(String.init)
        return names.first.flatMap { ChatBackground(name: $0, variant: names.dropFirst().first) }
    }

    private var backgroundMenu: some View {
        Menu {
            Picker("背景", selection: $backgroundName) {
                Text("普通").tag("plain")
                ForEach(ChatBackground.allCases, id: \.self) { item in
                    Text("\(item.name) · \(item.variantName)").tag("\(item.name)/\(item.variantName)")
                }
            }
        } label: {
            Label("背景", systemImage: "photo")
        }
    }

    /// The live stage's card model and reasoning: the next card is drawn with what's picked.
    private func cardModelMenu(_ cards: FlooCardModel) -> some View {
        Menu {
            Section("画卡模型") {
                Picker("画卡模型", selection: Binding(
                    get: { cards.model },
                    set: { demo.chooseCards(FlooCardModel(model: $0, reasoning: cards.reasoning)) }
                )) {
                    ForEach(FlooCardModel.models(with: cards.model), id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Section("推理") {
                Picker("推理", selection: Binding(
                    get: { cards.reasoning },
                    set: { demo.chooseCards(FlooCardModel(model: cards.model, reasoning: $0)) }
                )) {
                    ForEach(FlooCardModel.reasonings, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        } label: {
            Label("画卡模型", systemImage: "slider.horizontal.3")
        }
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
            if let replying = demo.replying {
                FlooReplying(draft: replying) { demo.replying = nil }
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
                        .focused($composerFocused)
                        .onChange(of: demo.composing) { composerFocused = true }
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
        .animation(FlooDesignTokens.Motion.layout, value: demo.replying)
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

/// The message you're replying to, over the composer while you write; ✕ lets it go.
private struct FlooReplying: View {
    let draft: FlooReplyDraft
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.who == "你" ? "回复你自己" : "回复\(draft.who)").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                Text(draft.begins).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
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
    @Environment(\.flooOnBackground) private var onBackground
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .environment(\.markdownSelectableTextHooks, Self.textHooks)
            // A citation chip opens what it names (§20.2).
            .environment(\.openURL, OpenURLAction { FlooSiteIcons.open($0) })
            .frame(maxWidth: 720)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(FlooBubbleState.space))
            // A card changes its row's height by itself (put in once drawn), as does a table
            // that scrolls (laid out again once it knows the width it has): the list takes
            // the height the row is laid out at, not one it measures while the card is going in.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                switch row.kind {
                case .fence, .cards, .work(.detail): updateSelfSizing(measuredHeight: height)
                case .block(let block, _) where block.descriptor.kind == .table:
                    updateSelfSizing(measuredHeight: height)
                default: break
                }
            }
    }

    /// On a phone a long press is for the message's menu: its words are picked by a double
    /// tap. (A text view puts its long presses back as it changes how it's selected.)
    private static let textHooks: MarkdownSelectableTextHooks? = FlooDesignTokens.Platform.isPointer ? nil : {
        let noLongPress = { @MainActor (textView: UITextView) in
            for gesture in textView.gestureRecognizers ?? [] where gesture is UILongPressGestureRecognizer {
                gesture.isEnabled = false
            }
        }
        return MarkdownSelectableTextHooks(onTextViewReady: noLongPress, onSelectionChanged: noLongPress)
    }()

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
        case .said(let speaker, let text, let receipt, let reply):
            said(speaker, text, receipt, reply)
                // Didn't go: a tap sends it again.
                .onTapGesture { if receipt == .failed { demo.retry(row.id) } }
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
        case .block(let block, let reveals):
            // The bubble its work is in opens to it; another of the message's (after a card) doesn't.
            if let message = row.message, row.bubble?.run == FlooDemo.leadRun(message) {
                markdown(block, reveals: reveals)
                    .contentShape(Rectangle())
                    // At once: alongside the words' own clicks, not after a double click has
                    // had its time.
                    .simultaneousGesture(TapGesture().onEnded { demo.toggleDetail(message) })
            } else {
                markdown(block, reveals: reveals)
            }
        case .work(let shown):
            if let bubble = row.bubble {
                switch shown {
                case .status(let status):
                    FlooBubblePiece(bubble: bubble, row: row.id, state: demo.bubbleState(bubble.run)) {
                        FlooWorkStatusView(status: status)
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { if let message = row.message { demo.toggleDetail(message) } })
                    // Its words taking its place: gone at once, as the bubble goes to their size
                    // (fading out, it would stand past the bubble's edge).
                    .transition(.identity)
                case .detail(let lines, let divided):
                    // Its own clicks only (a thought opening): the bubble closes from its words.
                    FlooBubblePiece(bubble: bubble, row: row.id, state: demo.bubbleState(bubble.run)) {
                        VStack(spacing: 0) {
                            FlooWorkDetail(lines: lines, demo: demo)
                            if divided {
                                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5).padding(.top, 4)
                            }
                        }
                    }
                }
            }
        case .fence(let language, let body, _, let layout):
            Group {
                if let layout { liveFence(language, body, layout) } else { fence(language, body) }
            }
            .padding(.vertical, 6)
        case .cards(let cards):
            FlooCardRun(spans: cards.map { $0.layout.size == .glance ? 1 : 2 }) {
                ForEach(cards.indices, id: \.self) { index in liveCard(cards[index]) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        case .choice(let choices, let chosen):
            FlooOptions(choices: choices, chosen: chosen, tint: tint, demo: demo) { index, option in
                demo.choose(row.id, index, option)
            }
            .padding(.vertical, 6)
        case .ask(let card):
            FlooAskView(card: card, demo: demo)
                .padding(.vertical, 6)
        case .topics(let topics):
            FlooTopicLinks(topics: topics, demo: demo)
                .padding(.vertical, 4)
        case .mentions(let mentions):
            if let bubble = row.bubble {
                FlooBubblePiece(bubble: bubble, row: row.id, state: demo.bubbleState(bubble.run)) {
                    mentionCard(mentions)
                }
            } else {
                mentionCard(mentions).padding(.vertical, 6)
            }
        case .images(let images):
            FlooImagesView(images: images)
                .padding(.vertical, 6)
        case .reactions(let reactions, let trailing):
            FlooReactionsView(reactions: reactions) { reaction in
                if let number = demo.number(of: row) { demo.react(number, reaction.mine ? nil : reaction.emoji) }
            }
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        case .page(let path, let page):
            // Docs' page block; a tap opens the page.
            DocPageRowView(page: page)
                .contentShape(Rectangle())
                .onTapGesture { demo.open(page: path) }
                .padding(.vertical, 6)
        }
    }

    private var tint: Color {
        row.message.flatMap(demo.message)?.agent.tint ?? .accentColor
    }

    // MARK: People

    private func said(_ speaker: FlooSpeaker, _ text: String, _ receipt: FlooReceipt?, _ reply: FlooReply?) -> some View {
        Group {
            switch speaker {
            case .me:
                VStack(alignment: .trailing, spacing: 4) {
                    if let reply {
                        FlooReplyTag(reply: reply, trailing: true, reach: 6) { demo.jump(to: reply) }
                    }
                    Text(text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(onBackground ? 0.35 : 0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .background(onBackground ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { FlooLit(demo: demo, key: row.id) }
                        .tiledLiftShape(row.id, cornerRadius: 18)
                    if let receipt {
                        FlooReceiptLabel(receipt: receipt)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
            case .person(let name):
                VStack(alignment: .leading, spacing: 4) {
                    if let reply {
                        FlooReplyTag(reply: reply, trailing: false, reach: 5) { demo.jump(to: reply) }
                    }
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    Text(text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(onBackground ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(uiColor: .secondarySystemFill)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { FlooLit(demo: demo, key: row.id) }
                        .tiledLiftShape(row.id, cornerRadius: 18)
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
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                if case .replying(let reply) = mark {
                    FlooReplyTag(reply: reply, trailing: false, reach: 6) { demo.jump(to: reply) }
                }
            }
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
                case .joined(let errand, let label):
                    Button {
                        demo.jumpToErrand(titled: errand)
                    } label: {
                        Label(label ?? "并进 \(errand)", systemImage: "arrow.triangle.merge")
                            .font(.caption)
                            .foregroundStyle(agent.tint)
                    }
                    .buttonStyle(.plain)
                case .replying:
                    // Over its name (above).
                    EmptyView()
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

    /// Mentions as one card in the bubble (agent-kernel.md §20.2, ⓪): a page the agent wrote as
    /// Docs' page block, opening it; a topic or a group going there; the rest one after
    /// another, hairlines between, each opening its link.
    @ViewBuilder
    private func mentionCard(_ mentions: [Mention]) -> some View {
        if mentions.count == 1, let mention = mentions.first, let doc = mention.doc {
            DocPageRowView(page: DocPage(doc: DocID(doc.page) ?? DocID(rawValue: UUID()), title: mention.title ?? "",
                                         preview: doc.preview))
                .contentShape(Rectangle())
                .onTapGesture { demo.open(page: doc.path) }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(mentions.enumerated()), id: \.offset) { index, mention in
                    if index > 0 { Divider() }
                    MentionRow(mention)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { open(mention) }
                }
            }
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }

    /// A mention tapped: a topic or a group goes there; the rest open their link, if they have one.
    private func open(_ mention: Mention) {
        if let place = mention.conversation {
            demo.go(to: FlooPlace(id: place.id, title: mention.title ?? "", kind: place.kind == .group ? .group : .topic(listed: true)))
        } else if let url = mention.url, url.scheme == "floo" {
            demo.open(link: url.absoluteString)
        } else if let url = mention.url, url.scheme != nil {
            // A path in floo (/drive/…) waits for its opener.
            openURL(url)
        }
    }

    @ViewBuilder
    private func markdown(_ block: MarkdownStreamBlock, reveals: Bool) -> some View {
        if let bubble = row.bubble {
            let message = reveals ? row.message.flatMap(demo.message) : nil
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
                        // Wide tables scroll sideways instead of squeezing their columns.
                        .markdownTableScrollable()
                        // Code in DocKit's box, as on a page.
                        .codeBlockStyle(DocCodeBlockStyle())
                        .markdownLinkSiteIcons()
                        // The bubble spaces its blocks.
                        .markdownStreamBlockEdgeInsets(false),
                    block,
                    reveals: reveals
                )
            }
        } else {
            revealing(
                MarkdownStreamBlockView(block)
                    .markdownDisplayMathRendersSynchronously()
                    .markdownTableScrollable()
                    .codeBlockStyle(DocCodeBlockStyle())
                    .markdownLinkSiteIcons()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5),
                block,
                reveals: reveals
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
    private func revealing(_ view: some View, _ block: MarkdownStreamBlock, reveals: Bool) -> some View {
        if reveals, let message = row.message.flatMap(demo.message) {
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
            FlooDrawnCard(request: request, size: size, session: card.flatMap { demo.sessions[$0] })
                .frame(maxWidth: .infinity, alignment: .leading)
        case "floo.card":
            HStack(alignment: .top, spacing: 12) {
                ForEach(lines, id: \.self) { name in
                    if let session = demo.card(name) {
                        FlooCardFrame(size: FlooDemoCards.all[name]?.size ?? .medium) {
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

    /// The backend's cards, each in its frame (CardFrame: the size its fence names, as
    /// CardLab and the App draw them): a drawing in its place, or a tool's cards side by side.
    @ViewBuilder
    private func liveFence(_ language: String, _ body: String, _ layout: CardLayout) -> some View {
        let lines = body.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        switch language {
        case "floo.draw":
            FlooLiveCard(
                request: lines.first { !$0.hasPrefix("card:") } ?? "",
                layout: layout,
                session: FlooDemo.cardName(language, lines).flatMap { demo.sessions[$0] }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case "floo.card":
            HStack(alignment: .top, spacing: CardSize.gutter()) {
                ForEach(lines, id: \.self) { name in
                    if let session = demo.card(name) {
                        CardFrame(layout: layout, widens: true) { CardView(tree: session.tree) }
                            .overlay { FlooCardEdge(size: layout.size) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    /// One card of a run, at its size.
    @ViewBuilder
    private func liveCard(_ card: FlooCard) -> some View {
        let name = FlooDemo.cardName(card.language, card.lines)
        if card.language == "floo.draw" {
            FlooLiveCard(
                request: card.lines.first { !$0.hasPrefix("card:") } ?? "",
                layout: card.layout,
                session: name.flatMap { demo.sessions[$0] }
            )
        } else if let session = name.flatMap({ demo.card($0) }) {
            CardFrame(layout: card.layout, widens: true) { CardView(tree: session.tree) }
                .overlay { FlooCardEdge(size: card.layout.size) }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

/// A conversation's card content: its size's width at least, wider when it can't fit in
/// that (it says it needs more when offered it), as far as the room it's given; as
/// CardFrame's `widens` does for the backend's cards.
private struct FlooAtLeast: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = fitted(subviews, room: proposal.width)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }

    private func fitted(_ subviews: Subviews, room: CGFloat?) -> CGFloat {
        let needed = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).width }.max() ?? width
        guard needed.isFinite else { return width }
        return max(width, min(needed, room ?? .infinity))
    }
}

/// Cards one after another, side by side as the width allows, as a page lays them out
/// (DocMediaLayout.place): slots a glance wide with the gutter between, a glance taking one
/// and every other size two (a summary is two glances and the gutter). A card that doesn't
/// fit on the line starts the next, the gutter below; a line is as tall as its tallest card.
/// The cards keep their own size, or are wider when their content is (CardFrame's
/// `widens`), taking the slots their width covers.
struct FlooCardRun: Layout {
    /// The slots each card takes.
    let spans: [Int]

    static let gutter = CGFloat(CardSize.gutter())
    private static let slot = CGFloat(CardSize.glance.width()) + gutter

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width)
        return frames.reduce(CGRect.zero) { $0.union($1) }.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where each card goes, from the top leading corner, across `width`: as many slots as
    /// fit, never fewer than a summary takes.
    private func place(_ subviews: Subviews, width: CGFloat?) -> [CGRect] {
        let slots = max(2, Int(((width ?? .infinity) + Self.gutter) / Self.slot))
        var frames: [CGRect] = []
        var (used, y, line) = (0, CGFloat(0), CGFloat(0))
        for (subview, span) in zip(subviews, spans) {
            // Offered the line: a card wider than its size is at most that.
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            // (Less a hair: a card its size's width is exactly its slots.)
            let span = max(span, Int(((size.width + Self.gutter) / Self.slot - 0.01).rounded(.up)))
            if used > 0, used + span > slots { (used, y, line) = (0, y + line + Self.gutter, 0) }
            frames.append(CGRect(origin: CGPoint(x: CGFloat(used) * Self.slot, y: y), size: size))
            (used, line) = (used + span, max(line, size.height))
        }
        return frames
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
    /// A fill item's fields as you've typed them, before "好了" sends them; the agent's guesses
    /// until you do.
    @State private var filled: [Int: [String]] = [:]

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
            let values = filled[index] ?? fields.map(\.guess)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(fields.enumerated()), id: \.offset) { place, field in
                    HStack(spacing: 8) {
                        Label(field.label, systemImage: Self.fieldIcon(field.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        TextField(field.label, text: Binding(
                            get: { values[place] },
                            set: { value in
                                var typed = filled[index] ?? fields.map(\.guess)
                                typed[place] = value
                                filled[index] = typed
                            }
                        ))
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(card.agent.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            Button("好了") { demo.answerAsk(card.id, item: index, .filled(values)) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(card.agent.tint)
                .controlSize(.small)
                .disabled(values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
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
        .foregroundStyle(receipt == .failed ? Color.red : receipt == .unseen ? Color.orange : Color.secondary)
        .contentTransition(.opacity)
    }

    private var icon: String {
        switch receipt {
        case .sending: "clock"
        case .failed: "exclamationmark.circle.fill"
        case .delivered: "checkmark"
        case .unseen: "clock"
        case .read: "eye"
        case .answered: "checkmark.circle.fill"
        }
    }
}

/// What a block's reveal last told of how far it has got: nil before it has, nil inside once
/// all is revealed. A reference the reveal writes into, whichever of the block's renders it
/// was handed from.
@MainActor
@Observable
private final class FlooRevealTold {
    var told: CGSize??
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

    /// What the words' reveal last told.
    @State private var reveal = FlooRevealTold()
    /// The words as laid out whole.
    @State private var whole: CGSize = .zero
    /// Where the words can be in the row.
    @State private var frame: CGRect?
    @State private var started = false
    @State private var listener: UUID?

    /// The revealed words' size: all of them unless they're being revealed; nil until known.
    private var revealed: CGSize? {
        if reveals {
            guard let told = reveal.told else { return nil }
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
        // Cut at the bubble: a wide table scrolls under its edges, not past them.
        .clipShape(FlooBubbleClip(top: bubble.top, last: bubble.last))
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
            // more words streaming in below the reveal don't move it. Words that aren't revealed
            // (its work, a thought opening in it) are only ever laid out.
            let laidOut = !reveals && starts == nil || before.map {
                $0.whole.origin != shown.whole.origin || $0.room != shown.room
                    || (state.finished.contains(row) && $0.whole != shown.whole)
            } ?? true
            // Laid out: no animation. The reveal moving on: the bubble's height goes with it.
            var transaction = Transaction(animation: laidOut ? nil : FlooDesignTokens.Motion.layout)
            transaction.flooRevealMoved = !laidOut
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
        let reveal = reveal
        return { reveal.told = .some($0) }
    }

    private func listen() {
        guard let starts, listener == nil else { return }
        listener = starts.addListener { count in
            if count > 0, !started { started = true }
        }
    }
}

extension EnvironmentValues {
    /// Whether the chat is over a picked background: its bubbles are material then.
    @Entry var flooOnBackground = false
}

/// The topics and comments hung on a message, one line each, to go to.
private struct FlooTopicLinks: View {
    let topics: [FlooPlace]
    let demo: FlooDemo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(topics) { topic in
                Button {
                    demo.go(to: topic)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: topic.kind == .topic(listed: true) ? "bubble.left.and.text.bubble.right" : "text.bubble")
                        Text(topic.kind == .topic(listed: true) ? "话题：\(topic.title)" : "评论")
                        if topic.unread > 0 {
                            Text("\(topic.unread) 条新消息").foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.footnote.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }
}

/// The chat's background: one of ChatBackgrounds', or the page's plain one.
private struct FlooChatBackground: View {
    let background: ChatBackground?

    var body: some View {
        if let background {
            ChatBackgroundSurface(background).ignoresSafeArea()
        } else {
            Color(uiColor: .systemBackground).ignoresSafeArea()
        }
    }
}

/// A bubble, drawn once behind the blocks it holds: around what of their words is revealed,
/// as wide as the widest revealed line. While the words stream it grows with the layout spring;
/// words already there have it whole.
private struct FlooBubbleBackground: View {
    @Environment(\.flooOnBackground) private var onBackground
    let run: String
    let state: FlooBubbleState
    let geometry: TiledItemBackgroundGeometry<String>
    let demo: FlooDemo

    static let radius: CGFloat = 18

    /// The bubble in the run's space, whether any of it shows, and how tall the words still
    /// being revealed are. It's over its rows as the list shows them (moving, coming in,
    /// going), as wide as their widest words; a row still being revealed ends it at what of it
    /// is.
    private var bubble: (rect: CGRect, shown: Bool, revealed: CGFloat) {
        // How far a row's padding goes past the bubble's, above its first words and below its
        // last (FlooBubblePiece).
        let edge: CGFloat = 4
        var revealed: CGFloat = 0
        var top = CGFloat.infinity
        var bottom = -CGFloat.infinity
        var x: CGFloat?
        // The rows' words' widths, and how far across each row is in (one coming in or going).
        var widths: [(width: CGFloat, across: CGFloat)] = []
        var room = CGFloat.infinity
        // Where words start across, from any row that told: one never on screen has none.
        let column = geometry.items.lazy.compactMap { state.rows[$0.id] }.first
        for item in geometry.items {
            let told = state.rows[item.id]
            let done = state.finished.contains(item.id)
            var end = item.frame.maxY - edge
            if !done {
                // Nothing of it out yet, or not told yet: not in the bubble.
                guard let words = told?.words, words.height > 0 else { continue }
                revealed += words.height
                end = min(end, item.frame.minY + words.maxY + 10)
            }
            let across = geometry.size.width > 0 ? min(1, item.frame.width / geometry.size.width) : 1
            let words = told.map { done ? $0.whole : $0.words ?? $0.whole }
            widths.append((words?.width ?? column?.room ?? 0, across))
            room = min(room, told?.room ?? .infinity)
            x = x ?? (words?.minX ?? column?.whole.minX).map { item.frame.minX + $0 }
            top = min(top, item.frame.minY + edge)
            bottom = max(bottom, end)
        }
        // A row coming in or going takes the bubble from the others' width to its own as far
        // as it's in, as it does down.
        let staying = widths.filter { $0.across >= 1 }.map(\.width).max() ?? 0
        let width = widths.map { staying + max(0, $0.width - staying) * $0.across }.max() ?? 0
        guard let x, top < bottom else {
            // Nothing shown yet: no bigger than its padding where the words will start.
            let start = geometry.items.first?.frame.minY ?? 0
            return (CGRect(x: (x ?? 0) - 14, y: start + edge, width: 28, height: 0), false, revealed)
        }
        return (CGRect(x: x - 14, y: top, width: min(width, room) + 28, height: bottom - top), true, revealed)
    }


    var body: some View {
        let bubble = bubble
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(onBackground ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.flooReceived))
            .overlay { FlooLit(demo: demo, key: run) }
            .modifier(FlooBubbleFrame(rect: bubble.rect, revealed: bubble.revealed, settled: bubble.revealed))
            // Where it is follows its rows frame by frame as the list moves and loads them (and
            // the words across as they're revealed): an animation of its own would trail
            // behind. Only a line more of words revealed grows it down in a move of its own.
            // It shows up around its first words, fading in there.
            .transaction { $0.animation = $0.flooRevealMoved ? FlooDesignTokens.Motion.layout : nil }
            .opacity(bubble.shown ? 1 : 0)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            // What lifts with its message's menu: placed, not moved there (offset isn't where
            // a view is laid out).
            .overlay {
                if bubble.shown {
                    Color.clear
                        .frame(width: bubble.rect.width, height: bubble.rect.height)
                        .tiledLiftShape(run, cornerRadius: Self.radius)
                        .position(x: bubble.rect.midX, y: bubble.rect.midY)
                }
            }
    }
}

/// A bubble's piece as the bubble cuts it: across, at the bubble's sides (a piece that fills
/// the room is as wide as the bubble); down, at its rounded top and bottom on the first and
/// last pieces, and not at all between them.
private struct FlooBubbleClip: Shape {
    var top: Bool
    var last: Bool

    func path(in rect: CGRect) -> Path {
        let reach: CGFloat = 1000
        let extended = CGRect(
            x: rect.minX,
            y: top ? rect.minY : rect.minY - reach,
            width: rect.width,
            height: rect.height + (top ? 0 : reach) + (last ? 0 : reach)
        )
        let radius = FlooBubbleBackground.radius
        return UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0,
            bottomLeadingRadius: last ? radius : 0,
            bottomTrailingRadius: last ? radius : 0,
            topTrailingRadius: top ? radius : 0,
            style: .continuous
        )
        .path(in: extended)
    }
}

/// Where a bubble is, at once, with its height going to its revealed words' height in a move:
/// only `revealed` animates, and the bubble is short of its full height by what it has still
/// to go.
private struct FlooBubbleFrame: ViewModifier, Animatable {
    var rect: CGRect
    var revealed: CGFloat
    let settled: CGFloat

    nonisolated var animatableData: CGFloat {
        get { revealed }
        set { revealed = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: rect.width, height: max(0, rect.height + revealed - settled))
            .offset(x: rect.minX, y: rect.minY)
            // Frame by frame as `revealed` goes: nothing else of it moves on its own.
            .transaction { $0.animation = nil }
    }
}

private struct FlooRevealMovedKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    /// A row's reveal moved on: its bubble grows to the revealed words in a move.
    fileprivate var flooRevealMoved: Bool {
        get { self[FlooRevealMovedKey.self] }
        set { self[FlooRevealMovedKey.self] = newValue }
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
            FlooAtLeast(width: width - 2 * padding) { content }
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

/// A card the backend draws, in its frame from the start: the frame is the size its fence
/// names, so nothing moves as it comes. It's drawn as it's written: the first of its views
/// takes the place of what it will show, and the rest come in after it. One that finished
/// with nothing to show keeps the request.
private struct FlooLiveCard: View {
    let request: String
    let layout: CardLayout
    let session: CardSession?

    var body: some View {
        let drawing = !(session?.tree.roots.isEmpty ?? true)
        CardFrame(layout: layout, widens: true) {
            // One card view for as long as it's drawn: its own entrances bring in what the
            // source adds, and a retry's reset takes its views out at once. Swapped for the
            // request each time the tree was empty for a moment (as a line is half-written),
            // card views faded out over one another and stayed, half drawn.
            ZStack(alignment: .topLeading) {
                if let session {
                    CardView(tree: session.tree)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(request).lineLimit(layout.size == .glance ? 3 : 4)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .opacity(drawing ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(FlooDesignTokens.Motion.layout, value: drawing)
        }
        .overlay { FlooCardEdge(size: layout.size) }
    }
}

/// The hairline around a card's panel, as the demo's own cards have it.
private struct FlooCardEdge: View {
    let size: CardSize

    var body: some View {
        RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
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
        case .said(_, let text, _, let reply): return prose(text) + (reply == nil ? 0 : 30) + 52
        case .signature(_, _, let marks):
            return 40 + marks.reduce(0) { if case .replying = $1 { $0 + 31 } else { $0 + 18 } }
        case .process(let process, let expanded, let open):
            guard expanded else { return 30 }
            guard !process.tasks.isEmpty else { return 40 + CGFloat(process.steps.count) * 21 }
            let steps = process.tasks.filter { open.contains($0.id) }.reduce(0) { $0 + $1.steps.count }
            return 40 + CGFloat(process.tasks.count) * 44 + CGFloat(steps) * 21
        case .block(let block, _): return prose(block.source) + (bubble == nil ? 10 : 20)
        case .work(.status): return 46
        case .work(.detail(let lines, let divided)):
            return min(lines.reduce(0) { $0 + $1.estimate }, FlooWorkDetail.ceiling) + 20 + (divided ? 5 : 0)
        case .fence(let language, let body, _, let layout):
            guard language != "floo.mention" else { return 90 }
            if let layout { return layout.size.height() + 12 }
            let card = FlooDemo.cardName(language, body.split(separator: "\n").map(String.init))
            return (card.flatMap { FlooDemoCards.all[$0]?.size } ?? .medium).drawingHeight + 12
        case .cards(let cards):
            // As on a phone: two glances to a line, anything else a line of its own.
            var (height, line, used) = (CGFloat(0), CGFloat(0), 0)
            for card in cards {
                let span = card.layout.size == .glance ? 1 : 2
                if used > 0, used + span > 2 { (height, line, used) = (height + line + FlooCardRun.gutter, 0, 0) }
                (line, used) = (max(line, CGFloat(card.layout.size.height())), used + span)
            }
            return height + line + 12
        case .mentions(let mentions): return 70 * CGFloat(mentions.count) + 20
        case .reactions: return 34
        case .page: return DocPageMetrics.rowHeight + 12
        case .images(let images):
            let caption: CGFloat = images.contains { !$0.alt.isEmpty } ? 24 : 0
            return (images.count == 1 ? FlooImagesView.aloneHeight : FlooImagesView.rowHeight) + caption + 12
        case .choice(let choices, _):
            if choices.contains(where: { $0.option.image != nil || $0.option.from != nil }) { return 230 }
            if choices.contains(where: { $0.option.detail != nil }) { return 14 + CGFloat(choices.count) * 56 }
            return 56
        case .topics(let topics):
            return 8 + CGFloat(topics.count) * 30
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

/// A message's menu, the system's: reactions (messaging.md §3.11) — on a phone a bar
/// above the bubble that lifts, on a Mac a row atop the menu —, the one you gave lit and
/// taken back by choosing it again; on an agent's message, a comment under it or a topic of
/// its own.
@MainActor
enum FlooMessageMenu {
    static func menu(for row: FlooRow, demo: FlooDemo) -> TiledContextMenu? {
        guard demo.isLive, let number = demo.number(of: row) else { return nil }
        let lift: String?
        switch row.kind {
        case .reactions: return nil
        case .said: lift = row.id
        case .signature: lift = row.message.map(FlooDemo.leadRun)
        default: lift = row.bubble?.run
        }
        let mine = demo.myReaction(on: row)
        let react = { (emoji: String) in demo.react(number, emoji == mine ? nil : emoji) }
        var sections: [UIMenuElement] = []
        let pointer = FlooDesignTokens.Platform.isPointer
        if pointer {
            sections.append(UIMenu(options: .displayAsPalette, children: FlooReaction.offered.map { emoji in
                UIAction(title: emoji, image: image(of: emoji), state: emoji == mine ? .on : .off) { _ in react(emoji) }
            }))
        }
        var actions = [UIAction(title: "回复", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in demo.reply(to: number) }]
        if let message = row.message {
            actions += [
                UIAction(title: "评论", image: UIImage(systemName: "text.bubble")) { _ in demo.openTopic(on: message, title: nil) },
                UIAction(title: "开话题…", image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { _ in demo.naming = message },
            ]
        }
        sections.append(UIMenu(options: .displayInline, children: actions))
        let yours: Bool = if case .said(.me, _, _, _) = row.kind { true } else { false }
        let accessory = pointer ? nil : TiledMenuAccessory(side: yours ? .trailing : .leading) { dismiss in
            FlooReactionBar(mine: mine) { emoji in
                dismiss()
                react(emoji)
            }
        }
        return TiledContextMenu(menu: UIMenu(children: sections), lift: lift, accessory: accessory)
    }

    /// An emoji as a menu's image (a palette shows images, not titles).
    private static func image(of emoji: String) -> UIImage {
        if let image = images[emoji] { return image }
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 24)]
        let size = (emoji as NSString).size(withAttributes: attributes)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            (emoji as NSString).draw(at: .zero, withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
        images[emoji] = image
        return image
    }

    private static var images: [String: UIImage] = [:]
}

/// What a message replies to, over its bubble (messaging.md §3.12.4): the face of who said
/// that one and how it begins (the words picked out of it in quotes, or the question it
/// answers), an elbow coming down from it to what's under it, `reach` below; a tap goes there.
private struct FlooReplyTag: View {
    @Environment(\.flooOnBackground) private var onBackground
    let reply: FlooReply
    /// On yours, on the right.
    let trailing: Bool
    let reach: CGFloat
    let go: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(reply.initial ?? "")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(reply.tint ?? Color.secondary.opacity(0.4), in: Circle())
            words.lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(3)
        .padding(.trailing, 7)
        .background(onBackground ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.primary.opacity(0.05)), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: go)
        .frame(maxWidth: 260, alignment: trailing ? .trailing : .leading)
        .padding(trailing ? .trailing : .leading, 24)
        .overlay(alignment: trailing ? .trailing : .leading) {
            FlooReplyElbow(trailing: trailing, reach: reach)
                .stroke(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 24)
        }
    }

    @ViewBuilder
    private var words: some View {
        switch reply.shown {
        case .begins(let words): Text(words)
        case .part(let words): Text("“\(words)”")
        case .answer(let title): Text("✓ 答「\(title)」").fontWeight(.semibold).foregroundStyle(.green)
        case .older: Text("一条更早的消息")
        }
    }
}

/// A reply's elbow: from the middle of its tag's side, round the corner, down past the tag by
/// `reach`, 9 points in from the edge of what's under it.
private struct FlooReplyElbow: Shape {
    let trailing: Bool
    let reach: CGFloat

    func path(in rect: CGRect) -> Path {
        let x: CGFloat = trailing ? rect.maxX - 9 : rect.minX + 9
        let end: CGFloat = trailing ? rect.minX + 6 : rect.maxX - 6
        let radius: CGFloat = 7
        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.maxY + reach))
        path.addLine(to: CGPoint(x: x, y: rect.midY + radius))
        path.addQuadCurve(to: CGPoint(x: x + (trailing ? -radius : radius), y: rect.midY), control: CGPoint(x: x, y: rect.midY))
        path.addLine(to: CGPoint(x: end, y: rect.midY))
        return path
    }
}

/// A bubble just gone to from a reply to it, lit up a moment.
private struct FlooLit: View {
    let demo: FlooDemo
    let key: String

    var body: some View {
        let lit = demo.lit == key
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor.opacity(lit ? 0.22 : 0))
            .animation(.easeOut(duration: lit ? 0.15 : 0.9), value: lit)
            .allowsHitTesting(false)
    }
}

/// The reactions offered above a bubble that lifts with its menu: yours ringed.
private struct FlooReactionBar: View {
    let mine: String?
    let choose: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FlooReaction.offered, id: \.self) { emoji in
                Button { choose(emoji) } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(width: 42, height: 42)
                        .background(emoji == mine ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .flooDesignGlass(.clear, in: Capsule())
        .padding(.bottom, 8)
    }
}

/// The reactions on a message, under its bubble (floo messaging.md §3.11): each emoji once, with
/// how many gave it, yours ringed in the tint. A tap gives the same, or takes yours back; who
/// gave it is its help.
private struct FlooReactionsView: View {
    let reactions: [FlooReaction]
    let tap: (FlooReaction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(reactions, id: \.emoji) { reaction in
                Button { tap(reaction) } label: {
                    HStack(spacing: 4) {
                        Text(reaction.emoji).font(.subheadline)
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(reaction.mine ? Color.accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(reaction.mine ? Color.accentColor.opacity(0.12) : Color(.secondarySystemFill), in: Capsule())
                    .overlay {
                        if reaction.mine { Capsule().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1) }
                    }
                }
                .buttonStyle(FlooDesignPlainButtonStyle(in: Capsule()))
                .help(reaction.who.joined(separator: "、"))
                .accessibilityLabel("\(reaction.emoji) \(reaction.who.joined(separator: "、"))")
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// A thing a link found, read only: its title and its whole text.
private struct FlooThingView: View {
    let thing: FlooOpenThing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(thing.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(thing.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
