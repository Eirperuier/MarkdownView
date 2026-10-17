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
            session = ConversationSession(.main(of: stage.account), remote: base.with(device: device))
        } catch {
            demo.catchUp("没连上：\(error)")
            return
        }
        self.session = session
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
                guard let source = card.source else { continue }
                let key = "live-\(info.number)-\(card.fence)-\(card.item)"
                demo.setCard(key, source: source, data: Self.value(card.data), size: card.size == "small" ? .small : .medium)
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

    private static func time(_ timestamp: Timestamp) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp.millisecondsSince1970) / 1000)
        return clock.string(from: date)
    }

    private static func item(_ key: String) -> Int { Int(key.split(separator: "-").last ?? "") ?? 0 }

    private static func value(_ json: JSONValue?) -> CardValue {
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
