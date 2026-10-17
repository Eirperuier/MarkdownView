//
//  FlooLive.swift
//  DemoApp
//
//  The floo Chat on a real backend: a lab stage on this Mac (floo's
//  Scripts/stage/live.sh) signs the demo in as its person, and the main
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

        var authority: String { base.host().map { host in base.port.map { "\(host):\($0)" } ?? host } ?? "" }
        var scheme: String { base.scheme ?? "http" }
    }

    static func play(_ demo: FlooDemo) async throws {
        demo.reset(title: "本机后端")
        guard let stage = Stage.launched else {
            demo.catchUp("没连上：用 floo 的 Scripts/stage/live.sh 起一个实验台，再带上 -flooStage 和 -flooAccount 打开。")
            return
        }
        let live = FlooLive(demo: demo, stage: stage)
        demo.goLive(live)
        try await live.run()
    }

    private let demo: FlooDemo
    private let stage: Stage
    private var session: ConversationSession?
    private var client: FlooClient?
    /// The pages asked for, read or being read.
    private var pages: Set<String> = []
    /// The demo's entries for the backend's messages, by number.
    private var said: [Int64: FlooDemo.Said] = [:]
    private var messages: [Int64: FlooDemo.Message] = [:]
    private var agents: [String: FlooAgent] = [:]

    private init(demo: FlooDemo, stage: Stage) {
        self.demo = demo
        self.stage = stage
    }

    /// Signs in as the stage's person on a device of its own (one with no services: the
    /// stage's Mac and phone run those), then follows the main conversation.
    private func run() async throws {
        let base = FlooClient(
            scheme: stage.scheme,
            authority: stage.authority,
            transport: URLSessionTransport(),
            tokens: StageTokens(stage: stage)
        )
        let session: ConversationSession
        do {
            let folder = URL.applicationSupportDirectory.appending(path: "floo-live", directoryHint: .isDirectory)
            let device = try await DeviceIdentity(store: FileSecrets(folder: folder)).registered(
                for: stage.account,
                with: base,
                platform: .iPad,
                appVersion: "demo",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
            let client = base.with(device: device)
            self.client = client
            session = ConversationSession(.main(of: stage.account), remote: client)
        } catch {
            demo.catchUp("没连上：\(error)")
            return
        }
        self.session = session
        Task { await loadCardModel() }
        let following = Task { await session.follow() }
        defer { following.cancel() }
        for await replica in await session.changes() {
            try Task.checkCancellation()
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

    // MARK: Card model

    /// The stage's card model, for the header's menu; an older stage has none, and no menu.
    private func loadCardModel() async {
        demo.cardModel = try? await Self.cardModel(URLRequest(url: stage.base.appending(path: "lab/cards")))  // try?: no menu
    }

    func chooseCards(_ model: FlooCardModel) {
        var request = URLRequest(url: stage.base.appending(path: "lab/cards"))
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

    // MARK: Pages

    /// Reads a page the agent wrote, once: the conversation shows it when it's in.
    func loadPage(_ path: String) {
        guard let client, pages.insert(path).inserted else { return }
        Task {
            do {
                let file = try await client.driveFile(path)
                self.demo.setPage(path, try JSONDecoder().decode(Doc.self, from: file.content))
            } catch {
                self.demo.catchUp("页面没读到（\(path)）：\(error)")
            }
        }
    }

    // MARK: Showing

    private func show(_ replica: ConversationReplica) {
        let agentsRead = replica.members.filter { $0.key.actor.agent != nil }.map(\.value)
        for info in replica.messages {
            let blocks = replica.blocks(of: info.number)
            switch info.author.actor {
            case .person:
                showPerson(info, blocks: blocks, agentsRead: agentsRead)
            case .agent(let agent):
                showAgent(info, agent: agent, blocks: blocks, replica: replica)
            }
        }
        demo.refresh()
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
            case .choosing(_, _, _, let label) where text.isEmpty: text = label
            default: break
            }
        }
        guard !text.isEmpty else { return }
        said[info.number] = demo.say(.me, text, receipt: receipt, quote: quote)
    }

    private func showAgent(_ info: MessageInfo, agent id: AgentID, blocks: [BlockInfo], replica: ConversationReplica) {
        let message = messages[info.number] ?? {
            let message = demo.begin(agent(id), at: Self.time(info.createdAt))
            message.number = info.number
            messages[info.number] = message
            return message
        }()
        let streaming = info.state == .streaming
        let stored = Set(blocks.map(\.id))
        let live = replica.live(of: info.id).filter { !stored.contains($0.id) }

        var words: [String] = []
        var calls: [(id: String, name: String)] = []
        var answered: Set<String> = []
        for block in blocks {
            switch block.content {
            case .text(let text) where block.audience != .model:
                words.append(text)
            case .toolCall(let callID, let name, _):
                calls.append((callID, name))
            case .toolResult(let callID, _, _), .workResult(let callID, _, _, _):
                answered.insert(callID)
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
        // Mentions checked as their fences closed, before they're stored.
        for (place, content) in replica.filled where place.message == info.number {
            if case .mention(let mention) = content, message.fenceMentions[mention.fence] == nil {
                message.fenceMentions[mention.fence] = Self.mention(mention)
            }
        }
        for block in live {
            switch block.kind {
            case .text: words.append(block.text)
            case .toolCall: calls.append((block.id.description, "调用工具"))  // its name comes with the stored call
            default: break
            }
        }

        if calls.isEmpty {
            demo.setWork(message, nil)
        } else {
            let steps = calls.map { call in replica.progress[call.id]?.line ?? call.name }
            let running = streaming && calls.contains { !answered.contains($0.id) }
            var process = FlooProcess(steps: steps, running: running)
            if !running { process.summary = "用了 \(calls.count) 个工具" }
            demo.setWork(message, process)
        }
        demo.setText(message, words.filter { !$0.isEmpty }.joined(separator: "\n\n"), streaming: streaming)
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

    private static func mention(_ mention: AnswerMention) -> Mention {
        Mention(
            kind: Mention.Kind(rawValue: mention.kind) ?? .note,
            source: mention.source,
            date: mention.date.flatMap(date),
            end: mention.end.flatMap(date),
            title: mention.title,
            quote: mention.quote,
            image: mention.image.flatMap(URL.init(string:))
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
