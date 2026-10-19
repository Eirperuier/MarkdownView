//
//  FlooLive.swift
//  DemoApp
//
//  The floo Chat on a real backend: the floo server, signed in to with an
//  account of your own (FlooSignIn), or a lab stage on this Mac (floo's
//  Scripts/stage/live.sh) that signs the demo in as its person. The main
//  conversation is shown as the scripted scenarios show theirs.
//

import Foundation
import SwiftUI
import CardModel
import CardUI
import Wire
import TransportKit
import ConversationKit
import DeviceSupport
import DocKit

@MainActor
final class FlooLive {
    /// The stage to talk to, from the launch arguments
    /// `-flooStage http://localhost:8920 -flooAccount <person id>`.
    struct Stage: Sendable {
        let base: URL
        let account: AccountID

        static var launched: Stage? {
            let defaults = UserDefaults.standard
            guard let base = defaults.string(forKey: "flooStage").flatMap(URL.init(string:)),
                  let account = defaults.string(forKey: "flooAccount").flatMap(AccountID.init)
            else { return nil }
            return Stage(base: base, account: account)
        }
    }

    /// Where the conversation is, and who you are there.
    struct Backend {
        let base: URL
        let account: AccountID
        let tokens: any AccessTokenProvider
        /// Where this device's key and its ids there are kept.
        let folder: String
        /// A lab stage, whose card model can be picked (`/lab/cards`).
        let lab: Bool

        var authority: String { base.host().map { host in base.port.map { "\(host):\($0)" } ?? host } ?? "" }
        var scheme: String { base.scheme ?? "https" }
    }

    /// The stage when launched with one; otherwise the floo server, signing in first when
    /// there's no session kept from before.
    static func play(_ demo: FlooDemo) async throws {
        if let stage = Stage.launched {
            demo.reset(title: "本机后端")
            let backend = Backend(base: stage.base, account: stage.account, tokens: StageTokens(stage: stage),
                                  folder: "floo-live", lab: true)
            return try await go(demo, backend)
        }
        demo.reset(title: "floo")
        let auth = FlooOnline.auth()
        // try?: a session that can't be read is signed in again.
        let server = FlooClient(scheme: "https", authority: FlooOnline.server, transport: URLSessionTransport(), tokens: auth)
        var session = try? await auth.session()
        var failure: String?
        // A kept session whose account the server no longer takes: signed in again. try?: not
        // reached now, it's tried as it is and says so.
        if session != nil, (try? await FlooSignIn.admitted(server, auth)) == false {
            session = nil
            failure = FlooSignIn.refused
        }
        if session == nil {
            let signIn = FlooSignIn(auth: auth, server: server, failure: failure)
            demo.signIn = signIn
            session = await signIn.signedIn()
            demo.signIn = nil
        }
        guard let session else { return }
        demo.signedIn = FlooOnline.Account(email: UserDefaults.standard.string(forKey: FlooOnline.emailKey), auth: auth)
        let backend = Backend(base: URL(string: "https://\(FlooOnline.server)")!, account: session.account,
                              tokens: auth, folder: "floo-online", lab: false)
        try await go(demo, backend)
    }

    private static func go(_ demo: FlooDemo, _ backend: Backend) async throws {
        let live = FlooLive(demo: demo, backend: backend)
        demo.goLive(live)
        try await live.run()
    }

    private let demo: FlooDemo
    private let backend: Backend
    private var session: ConversationSession?
    private var client: FlooClient?
    /// The demo's entries for the backend's messages, by number.
    private var said: [Int64: FlooDemo.Said] = [:]
    private var messages: [Int64: FlooDemo.Message] = [:]
    private var agents: [String: FlooAgent] = [:]
    /// How each service operation is shown, from the server's catalog: what tool calls show.
    private var operations: [String: Operation] = [:]
    /// The conversation as last shown, to show again once the catalog is in.
    private var last: ConversationReplica?

    private init(demo: FlooDemo, backend: Backend) {
        self.demo = demo
        self.backend = backend
    }

    /// Joins as the backend's person on a device of its own (one with no services: on a
    /// stage, its Mac and phone run those), then follows the main conversation.
    private func run() async throws {
        let base = FlooClient(
            scheme: backend.scheme,
            authority: backend.authority,
            transport: URLSessionTransport(),
            tokens: backend.tokens
        )
        let session: ConversationSession
        do {
            let folder = URL.applicationSupportDirectory.appending(path: backend.folder, directoryHint: .isDirectory)
            let device = try await DeviceIdentity(store: FileSecrets(folder: folder)).registered(
                for: backend.account,
                with: base,
                platform: .iPad,
                appVersion: "demo",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
            let client = base.with(device: device)
            self.client = client
            session = ConversationSession(.main(of: backend.account), remote: client)
        } catch {
            demo.catchUp("没连上：\(error)")
            return
        }
        self.session = session
        if backend.lab { Task { await loadCardModel() } }
        Task { await loadCatalog() }
        let following = Task { await session.follow() }
        defer { following.cancel() }
        for await replica in await session.changes() {
            try Task.checkCancellation()
            last = replica
            show(replica)
        }
    }

    // MARK: Sending

    func send(_ text: String) {
        guard let session else { return }
        Task {
            do {
                _ = try await session.send(MessageSend(id: .generate(), text: text))
            } catch {
                self.demo.catchUp("没发出去：\(error)")
            }
        }
    }

    func choose(message: Int64, fence: Int, item: Int, option: FlooOption) {
        guard let session else { return }
        let send = MessageSend(
            id: .generate(),
            text: option.send ?? option.label,
            choosing: ChoiceRef(message: message, fence: fence, item: item)
        )
        Task {
            do {
                _ = try await session.send(send)
            } catch {
                self.demo.catchUp("没发出去：\(error)")
            }
        }
    }

    /// Your answer to an item of an agent's ask: a message of yours answering it, with what you
    /// picked, whether you went ahead, or what you filled in.
    func answer(ask: String, item: Int, text: String, picked: [Int]? = nil, confirmed: Bool? = nil, filled: [String]? = nil) {
        guard let session, let id = AskID(ask) else { return }
        let send = MessageSend(
            id: .generate(),
            text: text,
            answering: AskAnswer(ask: id, item: item, picked: picked, confirmed: confirmed, filled: filled)
        )
        Task {
            do {
                _ = try await session.send(send)
            } catch {
                self.demo.catchUp("没发出去：\(error)")
            }
        }
    }

    // MARK: Card model

    /// The stage's card model, for the header's menu; an older stage has none, and no menu.
    private func loadCardModel() async {
        demo.cardModel = try? await Self.cardModel(URLRequest(url: backend.base.appending(path: "lab/cards")))  // try?: no menu
    }

    func chooseCards(_ model: FlooCardModel) {
        var request = URLRequest(url: backend.base.appending(path: "lab/cards"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(model)  // try?: two strings always encode
        Task {
            do {
                self.demo.cardModel = try await Self.cardModel(request)
            } catch {
                self.demo.catchUp("画卡模型没换成：\(error)")
            }
        }
    }

    private static func cardModel(_ request: URLRequest) async throws -> FlooCardModel {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(FlooCardModel.self, from: data)
    }

    // MARK: Catalog

    /// A service operation as people are shown it.
    struct Operation {
        let title: String
        let symbol: String?
        let hidden: Bool
        /// Its service's icon, when the service has an image.
        let icon: URL?
    }

    /// The server's catalog: each operation's title (in Chinese where it has one), symbol,
    /// whether it's shown, and its service's icon.
    private func loadCatalog() async {
        guard let client, let catalog = try? await client.catalog() else { return }  // try?: calls show by name
        var found: [String: Operation] = [:]
        for entry in catalog.services {
            let zh = entry.presentation.localized["zh-Hans"]?.operations ?? [:]
            let icon = entry.presentation.icon.flatMap { path in
                path.hasPrefix("/") ? backend.base.appending(path: String(path.dropFirst())) : URL(string: path)
            }
            for operation in entry.operations {
                found["\(entry.id).\(operation.id)"] = Operation(
                    title: zh[operation.id.rawValue]?.title ?? operation.title,
                    symbol: operation.symbol,
                    hidden: operation.hidden,
                    icon: icon
                )
            }
        }
        operations = found
        if let last { show(last) }
    }

    // MARK: Pages

    /// A page the agent wrote, read whole as it is now; nil, said, if it can't be.
    func page(_ path: String) async -> Doc? {
        guard let client else { return nil }
        do {
            return try JSONDecoder().decode(Doc.self, from: try await client.driveFile(path).content)
        } catch {
            demo.catchUp("页面没读到（\(path)）：\(error)")
            return nil
        }
    }

    // MARK: Showing

    private func show(_ replica: ConversationReplica) {
        let agentsRead = replica.members.filter { $0.key.actor.agent != nil }.map(\.value)
        // Taken back (its run passed having said nothing): it goes.
        let present = Set(replica.messages.map(\.number))
        for (number, message) in messages where !present.contains(number) {
            messages[number] = nil
            if !messages.values.contains(where: { $0 === message }) { demo.remove(message) }
        }
        // A run's message of work only is overtaken when something comes in while it works (an
        // errand's result): its words go to the run's next message, after that. With nothing
        // shown between them, they're one message here: the work, then the words.
        var parts: [MessageInfo] = []
        for info in replica.messages {
            switch info.author.actor {
            case .person:
                showAgent(parts, replica: replica)
                parts = []
                showPerson(info, blocks: replica.blocks(of: info.number), agentsRead: agentsRead)
            case .agent:
                if let last = parts.last, info.run != nil, info.run == last.run, !Self.speaks(last, replica) {
                    parts.append(info)
                } else if !parts.isEmpty, !Self.shows(info, replica) {
                    showAgent([info], replica: replica)
                } else {
                    showAgent(parts, replica: replica)
                    parts = [info]
                }
            }
        }
        showAgent(parts, replica: replica)
        showAsks(replica)
        // An agent with a run going is writing, between its model's calls too (its message
        // stops streaming while a tool runs, and the next one starts after).
        var writing = Set(replica.active.compactMap(\.agent.actor.agent))
        for info in replica.messages where info.state == .streaming {
            if let id = info.author.actor.agent { writing.insert(id) }
        }
        for id in Set(replica.messages.compactMap(\.author.actor.agent)).union(writing) {
            demo.setPresence(agent(id), writing.contains(id) ? "正在写…" : nil)
        }
        demo.refresh()
    }

    // MARK: Asks

    /// The agents' asks, each on the message that asked it: its card there and, while it's
    /// open, over where you type.
    private func showAsks(_ replica: ConversationReplica) {
        // Every message shown, so one whose asks are gone has none.
        var cards: [ObjectIdentifier: (message: FlooDemo.Message, cards: [FlooAskCard])] = [:]
        for message in messages.values { cards[ObjectIdentifier(message)] = (message, []) }
        for ask in replica.asks.values.sorted(by: { $0.pts < $1.pts }) {
            guard let number = ask.message, let message = messages[number], let id = ask.agent.actor.agent else { continue }
            cards[ObjectIdentifier(message), default: (message, [])].cards.append(card(ask, agent(id), replica))
        }
        for (message, asks) in cards.values { demo.setAsks(message, asks) }
    }

    private func card(_ ask: AskInfo, _ agent: FlooAgent, _ replica: ConversationReplica) -> FlooAskCard {
        let state: FlooAskCard.State =
            switch ask.status {
            case .open: .open
            case .answered: .answered
            case .withdrawn: .withdrawn
            case .expired: .expired
            }
        let items = ask.items.map { item in
            // Answered: what the answering message says.
            let answer = item.answer.map { number in
                replica.blocks(of: number).compactMap { if case .text(let text) = $0.content { text } else { nil } }
                    .joined(separator: " ")
            }
            return FlooAskItem(title: item.title, question: item.question, form: Self.form(item.form), answer: answer)
        }
        return FlooAskCard(id: ask.id.description, agent: agent, items: items, state: state)
    }

    private static func form(_ form: AskForm) -> FlooAskItem.Form {
        switch form {
        case .choose(let options, let multiple, let own):
            .choose(
                options: options.map { FlooOption(label: $0.label, send: $0.send, detail: $0.detail, image: $0.image) },
                multiple: multiple,
                own: own ? "" : nil
            )
        case .confirm(let effect):
            .confirm(effect: effect, yes: "好", no: "先不要")
        case .fill(let fields):
            .fill(fields: fields.map { FlooAskItem.Field(label: $0.label, kind: Self.kind($0.kind), guess: $0.guess ?? "") })
        case .unknown:
            .fill(fields: [])
        }
    }

    private static func kind(_ kind: AskField.Kind) -> FlooAskItem.Field.Kind {
        switch kind {
        case .text: .text
        case .number: .number
        case .date: .date
        case .time: .time
        case .place: .place
        case .person: .person
        }
    }

    /// Whether a message has words, stored or coming.
    private static func speaks(_ info: MessageInfo, _ replica: ConversationReplica) -> Bool {
        replica.blocks(of: info.number).contains {
            if case .text = $0.content { $0.audience != .model } else { false }
        } || replica.live(of: info.id).contains {
            if case .text = $0.kind { true } else { false }
        }
    }

    /// Whether a message shows anything: words, thinking or calls, stored or coming.
    private static func shows(_ info: MessageInfo, _ replica: ConversationReplica) -> Bool {
        info.state == .streaming || !replica.live(of: info.id).isEmpty || speaks(info, replica)
            || replica.blocks(of: info.number).contains {
                switch $0.content {
                case .reasoning, .toolCall: true
                default: false
                }
            }
    }

    private func showPerson(_ info: MessageInfo, blocks: [BlockInfo], agentsRead: [MemberInfo]) {
        let receipt: FlooReceipt =
            agentsRead.contains { $0.answeredMax >= info.number } ? .answered
            : agentsRead.contains { $0.readMax >= info.number } ? .read : .delivered
        if let said = said[info.number] {
            if said.receipt != receipt { demo.mark(said, receipt) }
            return
        }
        var text = blocks.compactMap { if case .text(let text) = $0.content { text } else { nil } }.joined(separator: "\n\n")
        var quote: String?
        for block in blocks {
            switch block.content {
            case .quote(let words): quote = words
            case .answering(_, _, let title, _) where quote == nil: quote = "回答「\(title)」"
            case .choosing(_, _, _, let label) where text.isEmpty: text = label
            default: break
            }
        }
        guard !text.isEmpty else { return }
        said[info.number] = demo.say(.me, text, receipt: receipt, quote: quote)
    }

    /// An agent's message, from the backend's messages it's made of: one, or a run's work
    /// overtaken and its words after.
    private func showAgent(_ parts: [MessageInfo], replica: ConversationReplica) {
        guard let first = parts.first, let last = parts.last, case .agent(let id) = first.author.actor else { return }
        let message = parts.lazy.compactMap { self.messages[$0.number] }.first
            ?? demo.begin(agent(id), at: Self.time(first.createdAt))
        for info in parts { messages[info.number] = message }
        // Its fences are its words', the last part's: what a choice answers.
        message.number = last.number
        let streaming = parts.contains { $0.state == .streaming }

        var words: [String] = []
        var work = Work(live: streaming)
        for info in parts {
            let blocks = replica.blocks(of: info.number)
            let stored = Set(blocks.map(\.id))
            let live = replica.live(of: info.id).filter { !stored.contains($0.id) }
            for block in blocks {
                switch block.content {
                case .text(let text) where block.audience != .model:
                    words.append(text)
                case .reasoning(let summary, _, _):
                    work.think(block.id.description, summary, going: false, started: block.startedAt, ended: block.endedAt)
                case .toolCall(let callID, let name, let arguments, let operation):
                    work.call(
                        callID, name: name, operation: operation, says: Self.described(arguments),
                        turn: block.turn.map(String.init) ?? "", started: block.startedAt
                    )
                case .toolResult(let callID, _, let isError):
                    work.answer(callID, failed: isError, started: block.startedAt, ended: block.endedAt)
                case .workResult(let callID, _, _, let isError):
                    work.answer(callID, failed: isError, started: block.startedAt, ended: block.endedAt)
                case .toolData(let callID, let data):
                    work.data(callID, data)
                case .card(let card):
                    guard let source = card.source else {
                        if card.failure != nil { message.fenceFailed.insert(card.fence) }
                        continue
                    }
                    let key = "live-\(info.number)-\(card.fence)-\(card.item)"
                    demo.setCard(key, source: source, data: Self.value(card.data))
                    var keys = message.fenceCards[card.fence] ?? []
                    if !keys.contains(key) {
                        keys.append(key)
                        message.fenceCards[card.fence] = keys.sorted { Self.item($0) < Self.item($1) }
                    }
                case .mention(let mention):
                    message.fenceMentions[mention.fence] = Self.mention(mention)
                case .page(let page):
                    message.fencePages[page.fence] = Self.page(page)
                default:
                    break
                }
            }
            // Cards being drawn, as they're written: each in the place its stored card takes.
            for draft in replica.drafts.values where draft.place.message == info.number {
                let key = "live-\(info.number)-\(draft.place.fence)-\(draft.place.item)"
                demo.draftCard(key, source: draft.source, attempt: draft.attempt, data: Self.value(draft.data))
                var keys = message.fenceCards[draft.place.fence] ?? []
                if !keys.contains(key) {
                    keys.append(key)
                    message.fenceCards[draft.place.fence] = keys.sorted { Self.item($0) < Self.item($1) }
                }
            }
            // Mentions checked and pages read as their fences closed, before they're stored.
            for (place, content) in replica.filled where place.message == info.number {
                if case .mention(let mention) = content, message.fenceMentions[mention.fence] == nil {
                    message.fenceMentions[mention.fence] = Self.mention(mention)
                }
                if case .page(let page) = content, message.fencePages[page.fence] == nil {
                    message.fencePages[page.fence] = Self.page(page)
                }
            }
            for block in live {
                switch block.kind {
                case .text:
                    words.append(block.text)
                case .reasoning:
                    work.think(block.id.description, block.text, going: !block.done, started: block.startedAt, ended: block.endedAt)
                case .toolCall:
                    // The call is known from its first event: its id (what its progress is under),
                    // its tool and operation; what it does, once its arguments say.
                    if let call = block.call {
                        work.call(
                            call.id, name: call.name, operation: call.operation, says: Self.described(block.text),
                            turn: "live-\(block.run)", started: block.startedAt
                        )
                    }
                case .toolResult:
                    if let call = block.call { work.running(call.id, started: block.startedAt, ended: block.endedAt) }
                default: break
                }
            }
        }

        demo.setSteps(message, steps(work, progress: replica.progress), thinking: work.thinking)
        demo.setText(message, words.filter { !$0.isEmpty }.joined(separator: "\n\n"), streaming: streaming)
    }

    // MARK: Work

    /// A message's work as its blocks have it, in order: its thinking, and its calls grouped by
    /// the reply that made them.
    private struct Work {
        struct Call {
            let id: String
            let name: String
            let operation: ToolID?
            var says: String?
            var state: FlooCall.State
            var started: Wire.Timestamp?
            var ended: Wire.Timestamp?
            var data: Wire.JSONValue?
        }

        enum Step {
            case thinking(id: String, going: Bool, started: Wire.Timestamp?, ended: Wire.Timestamp?)
            case calls(turn: String, [Call])
        }

        /// Still being written: a call with no answer is running.
        let live: Bool
        var steps: [Step] = []
        var thinking: [String: String] = [:]

        init(live: Bool) {
            self.live = live
        }

        mutating func think(_ id: String, _ text: String, going: Bool, started: Wire.Timestamp?, ended: Wire.Timestamp?) {
            guard !text.isEmpty || going else { return }
            thinking[id] = text
            steps.append(.thinking(id: id, going: going, started: started, ended: ended))
        }

        mutating func call(_ id: String, name: String, operation: ToolID?, says: String?, turn: String, started: Wire.Timestamp?) {
            let call = Call(id: id, name: name, operation: operation, says: says, state: live ? .running : .done, started: started)
            if case .calls(let last, var calls)? = steps.last, last == turn {
                calls.append(call)
                steps[steps.count - 1] = .calls(turn: turn, calls)
            } else {
                steps.append(.calls(turn: turn, [call]))
            }
        }

        mutating func answer(_ id: String, failed: Bool, started: Wire.Timestamp?, ended: Wire.Timestamp?) {
            update(id) { call in
                call.state = failed ? .failed : .done
                call.started = started ?? call.started
                call.ended = ended ?? call.ended
            }
        }

        /// A live result: the call runs from `started`, and is done once it has `ended`.
        mutating func running(_ id: String, started: Wire.Timestamp?, ended: Wire.Timestamp?) {
            update(id) { call in
                call.started = started ?? call.started
                if let ended {
                    call.ended = ended
                    call.state = .done
                }
            }
        }

        mutating func data(_ id: String, _ data: Wire.JSONValue) {
            update(id) { $0.data = data }
        }

        private mutating func update(_ id: String, _ change: (inout Call) -> Void) {
            for index in steps.indices {
                guard case .calls(let turn, var calls) = steps[index], let at = calls.firstIndex(where: { $0.id == id }) else { continue }
                change(&calls[at])
                steps[index] = .calls(turn: turn, calls)
                return
            }
        }
    }

    /// The work as the demo shows it: hidden operations left out, each call with its title,
    /// icon and where it went.
    private func steps(_ work: Work, progress: [String: CallProgress]) -> [FlooStep] {
        work.steps.compactMap { step -> FlooStep? in
            switch step {
            case .thinking(let id, let going, let started, let ended):
                return FlooStep(id: id, kind: .thinking, going: going, started: Self.date(started), ended: Self.date(ended))
            case .calls(let turn, let calls):
                let shown = calls.compactMap { present($0, progress: progress[$0.id]) }
                guard let first = shown.first else { return nil }
                let starts = shown.compactMap(\.started)
                let going = shown.contains { $0.state == .running }
                return FlooStep(
                    id: "calls-\(turn)-\(first.id)",
                    kind: .calls(shown),
                    going: going,
                    started: starts.min(),
                    ended: going ? nil : shown.compactMap(\.ended).max()
                )
            }
        }
    }

    private func present(_ call: Work.Call, progress: CallProgress?) -> FlooCall? {
        let operation = call.operation.flatMap { operations[$0.description] }
        if operation?.hidden == true { return nil }
        let title = operation?.title ?? call.name
        let own: FlooCall.Icon =
            if let icon = operation?.icon { .image(icon) } else { .symbol(operation?.symbol ?? "wrench.and.screwdriver") }
        // A call that says which site it's on shows that site's icon: live as it goes, after
        // from what it gave the cards.
        let site = progress?.source.flatMap { Self.isHost($0) ? $0 : nil } ?? call.data?["site"]?.stringValue
        return FlooCall(
            id: call.id,
            says: call.says ?? progress?.line ?? title,
            title: title,
            icon: site.map { .site($0) } ?? own,
            fallback: site == nil ? nil : own,
            detail: [site, Self.summary(call.data)].compactMap { $0 }.joined(separator: " · "),
            state: call.state,
            started: Self.date(call.started),
            ended: Self.date(call.ended)
        )
    }

    private static func isHost(_ text: String) -> Bool {
        text.contains(".") && !text.contains("/") && !text.contains(" ")
    }

    /// What a call came back with, from what it gave the cards: a page's title, how many results.
    private static func summary(_ data: Wire.JSONValue?) -> String? {
        guard let data else { return nil }
        if case .array(let results)? = data["results"] { return "\(results.count) 个结果" }
        return data["title"]?.stringValue
    }

    /// `_description` from a call's arguments as they're written, once its string has closed.
    static func described(_ arguments: String) -> String? {
        guard let match = arguments.firstMatch(of: /"_description"\s*:\s*"((?:[^"\\]|\\.)*)"/) else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data("\"\(match.1)\"".utf8))  // try?: not yet whole
    }

    private static func date(_ timestamp: Wire.Timestamp?) -> Date? {
        timestamp.map { Date(timeIntervalSince1970: Double($0.millisecondsSince1970) / 1000) }
    }

    // MARK: Mapping

    private static let palette: [Color] = [.orange, .teal, .purple, .mint, .brown]

    /// The demo's agent for one of the backend's: the butler, or a service by what it's for.
    private func agent(_ id: AgentID) -> FlooAgent {
        guard case .service(let service) = id else { return .butler }
        let name = service.rawValue
        if let known = agents[name] { return known }
        let lower = name.lowercased()
        let agent: FlooAgent =
            if lower.contains("health") { .health }
            else if lower.contains("weather") { .weather }
            else if lower.contains("calendar") { FlooAgent(name: "日历", tint: .red) }
            else if lower.contains("mail") { FlooAgent(name: "邮件", tint: .blue) }
            else if lower.contains("github") { FlooAgent(name: "GitHub", tint: .gray) }
            else if lower.contains("codex") { FlooAgent(name: "codex", tint: .green) }
            else { FlooAgent(name: name, tint: Self.palette[agents.count % Self.palette.count]) }
        agents[name] = agent
        return agent
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func time(_ timestamp: Wire.Timestamp) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp.millisecondsSince1970) / 1000)
        return clock.string(from: date)
    }

    private static func item(_ key: String) -> Int { Int(key.split(separator: "-").last ?? "") ?? 0 }

    private static func value(_ json: Wire.JSONValue?) -> CardValue {
        guard let json, let data = try? JSONEncoder().encode(json) else { return .object([:]) }
        return (try? JSONDecoder().decode(CardValue.self, from: data)) ?? .object([:])
    }

    /// A page an answer points to, as Docs' page block shows it.
    private static func page(_ page: AnswerPage) -> (path: String, page: DocPage) {
        (page.path, DocPage(doc: DocID(page.page) ?? DocID(rawValue: UUID()), title: page.title, preview: page.preview))
    }

    private static func mention(_ mention: AnswerMention) -> Mention {
        Mention(
            kind: Mention.Kind(rawValue: mention.kind) ?? .note,
            source: mention.source,
            date: mention.date.flatMap(date),
            end: mention.end.flatMap(date),
            title: mention.title,
            quote: mention.quote,
            image: mention.image.flatMap(URL.init(string:)),
            url: mention.url.flatMap(URL.init(string:))
        )
    }

    private static func date(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withFullDate]
        return full.date(from: text)
    }
}

/// The model a stage draws its cards with and its reasoning (floo's `/lab/cards`).
struct FlooCardModel: Codable, Hashable {
    var model: String
    var reasoning: String

    /// The models to choose from, the stage's own among them.
    static func models(with current: String) -> [(id: String, name: String)] {
        let known = [
            ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5"),
            ("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5"),
            ("openai/gpt-6-luna", "GPT-6 luna"),
        ]
        return known.contains { $0.0 == current } ? known : known + [(current, current)]
    }

    static let reasonings = [("none", "不推理"), ("low", "低"), ("medium", "中"), ("high", "高")]
}

/// The floo server on Fly and the sign-in it takes (Supabase Auth's password grant): the
/// publishable key is the one made for apps to carry.
enum FlooOnline {
    static let server = "floo-server.fly.dev"
    static let supabase = "qfidchtgytvhzzoayouh.supabase.co"
    static let publishableKey = "sb_publishable_4DziZAUMdWo2a4AwvqBkbg_ivDbaUxY"
    /// Supabase's own minimum.
    static let minimumPassword = 6
    /// The email last signed in with, filled in next time and shown while signed in.
    static let emailKey = "flooOnlineEmail"

    /// The session kept as a file beside the device's key (a demo signed ad hoc has no
    /// Keychain of its own).
    static func auth() -> SupabaseAuth {
        let folder = URL.applicationSupportDirectory.appending(path: "floo-online", directoryHint: .isDirectory)
        let store: any SessionStore = (try? FileSecrets(folder: folder)).map { KeychainSessionStore(store: $0) } ?? Unkept()
        return SupabaseAuth(authority: supabase, publishableKey: publishableKey, transport: URLSessionTransport(), store: store)
    }

    /// Who is signed in, to show and to sign out.
    struct Account {
        let email: String?
        let auth: SupabaseAuth
    }

    /// Where the session goes when its folder can't be made: nowhere, signed in until quit.
    private struct Unkept: SessionStore {
        func load() async throws -> AuthSession? { nil }
        func save(_ session: AuthSession?) async throws {}
    }
}

/// Tokens from the stage's token route, fetched again when half an hour old
/// (they last an hour), as the Floo app's debug sign-in does.
private actor StageTokens: AccessTokenProvider {
    let stage: FlooLive.Stage
    private var last: (token: String, at: Date)?

    init(stage: FlooLive.Stage) {
        self.stage = stage
    }

    func accessToken() async throws -> String {
        if let last, Date().timeIntervalSince(last.at) < 30 * 60 { return last.token }
        var request = URLRequest(url: stage.base.appending(path: "lab/people/\(stage.account)/token"))
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let token = try JSONDecoder().decode(Issued.self, from: data).token
        last = (token, Date())
        return token
    }

    private struct Issued: Decodable {
        var token: String
    }
}
