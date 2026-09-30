//
//  FlooDemo.swift
//  DemoApp
//
//  A floo conversation played from a script, on the chat's own parts: agents' messages are
//  markdown streamed into blocks, one list row a block, cards and mentions are fences in the
//  answer (```floo.draw, ```floo.card, ```floo.mention), and what makes it asynchronous is
//  shown as it happens: an agent working or waiting, a message not yet read, a question
//  waiting for an answer, what came while you were away.
//

import SwiftUI
import MarkdownView
import MessagingUI
import CardModel
import CardUI

enum FlooAgent: String, Hashable, Sendable {
    case butler = "管家"
    case weather = "天气"
    case health = "健康"

    var tint: Color {
        switch self {
        case .butler: .indigo
        case .weather: .cyan
        case .health: .pink
        }
    }
}

enum FlooSpeaker: Hashable, Sendable {
    case me
    case person(String)
}

/// Where a person's message is, as the agents have it: kept, read into an agent's context,
/// answered.
enum FlooReceipt: Hashable, Sendable {
    case delivered, unseen, read, answered

    var label: String {
        switch self {
        case .delivered: "已送达"
        case .unseen: "还没看到"
        case .read: "已读"
        case .answered: "已回应"
        }
    }
}

enum FlooMark: Hashable, Sendable {
    /// Said with nobody asking: a push.
    case proactive
    /// Picks up what was left: slow work back, a commitment due.
    case continuing(String)
    /// It rang, and why.
    case notified(String)
    /// Said while its work is still going, from what the work has come to so far.
    case soFar(String)
    /// What you asked for went into a thing it already had in hand, by that thing's name.
    case joined(String)
}

/// An agent's work in a message: live while it runs, one line when done. What it's at is the
/// last of its steps; it may look into several things at once, each on its own.
struct FlooProcess: Hashable, Sendable {
    var steps: [String]
    var running = true
    var summary: String?
    /// The thing it took on, as it's listed with the others it has in hand: "GPT-6 值不值得换".
    /// Quick work that nobody waits on has none.
    var title: String?
    var tasks: [FlooTask] = []
    /// What it read itself, apart from what its tasks read.
    var read: [String] = []

    /// What it's at: the last move of a thing it's still looking into, else its last step.
    var doing: String? {
        tasks.filter { $0.state == .running }.max { $0.touched < $1.touched }?.detail ?? steps.last
    }

    var sources: [String] {
        (read + tasks.flatMap(\.sources)).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// One of the things an agent looks into at once: a helper of its own, another agent it asked,
/// or a tool on one of your devices.
struct FlooTask: Hashable, Sendable, Identifiable {
    enum State: Hashable, Sendable {
        case running
        /// Not started: waiting on the others, or on you.
        case waiting
        case done
        case stopped
    }

    let id: String
    let title: String
    /// Who does it, when it isn't the agent's own helper: "交给 Mac 上的 codex".
    let executor: String?
    /// When you added it, if it came after the thing was taken on: "20:33".
    var added: String?
    var state: State
    /// What it's at, what it waits for, or what it came to.
    var detail: String
    var steps: [String] = []
    var sources: [String] = []
    /// When it last moved, as an order among its work's tasks.
    var touched = 0
}

struct FlooRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case time(String)
        case unread(String)
        case catchUp(String)
        /// Who said it, what, where it is with the agents, and the part of an answer it replies to.
        case said(FlooSpeaker, String, FlooReceipt?, quote: String?)
        case signature(FlooAgent, String, [FlooMark])
        /// Its work, whether it's opened, and which of its tasks are.
        case process(FlooProcess, expanded: Bool, open: Set<String>)
        case block(MarkdownStreamBlock, streaming: Bool)
        /// A ```floo.* fence: its language, what's in it, and how far its card is drawn.
        case fence(String, String, version: Int)
    }

    let id: String
    let message: Int?
    let kind: Kind
}

/// A question an agent is waiting on you for, kept above the composer until answered.
struct FlooAsk: Equatable {
    let agent: FlooAgent
    let question: String
    let options: [String]
}

@MainActor
@Observable
final class FlooDemo {
    // MARK: Entries

    @MainActor
    final class Said {
        let id: Int
        let speaker: FlooSpeaker
        let text: String
        var receipt: FlooReceipt?
        /// The part of an answer it replies to, picked out of it.
        let quote: String?

        init(id: Int, speaker: FlooSpeaker, text: String, receipt: FlooReceipt?, quote: String? = nil) {
            self.id = id
            self.speaker = speaker
            self.text = text
            self.receipt = receipt
            self.quote = quote
        }
    }

    @MainActor
    final class Message {
        let id: Int
        let agent: FlooAgent
        let time: String
        var marks: [FlooMark]
        var process: FlooProcess?
        var text = ""
        var blocks: [MarkdownStreamBlock] = []
        var streaming = false
        /// Its work shows under what it said (a quick answer, then the slow work it started),
        /// not above it.
        var processAfterText = false
        var splitter = MarkdownBlockSplitter(customFence: { language, source in
            guard language.hasPrefix("floo.") else { return nil }
            // In the list from its first whole line: what the card will show, or what it points
            // at. A line still being written names nothing yet, and the row keeps what it first
            // showed.
            return FlooDemo.wholeLines(source).contains { !$0.isEmpty }
        })
        let coordinator = StreamingRevealCoordinator<UUID>()
        var generation = 0

        init(id: Int, agent: FlooAgent, time: String, marks: [FlooMark]) {
            self.id = id
            self.agent = agent
            self.time = time
            self.marks = marks
        }
    }

    enum Entry {
        case time(String)
        case unread(String)
        case catchUp(String)
        case said(Said)
        case message(Message)
    }

    private(set) var rows: [FlooRow] = []
    var scrollPosition = TiledScrollPosition(autoScrollsToBottomOnAppend: true, scrollsToBottomOnReplace: true)
    private(set) var title = ""
    /// Who is doing what right now, in the order they started.
    private(set) var presence: [(agent: FlooAgent, doing: String)] = []
    private(set) var composer = ""
    private(set) var ask: FlooAsk?
    private(set) var expanded: Set<String> = []
    /// What you said while an agent was mid-message: it waits over the composer, not yet
    /// seen, and takes its place once the agent has finished speaking.
    private(set) var queued: [Said] = []
    /// The first row of the message being written, while it's written: a long one stops the
    /// list following once its start reaches the top, so you read it from there.
    private(set) var speaking: String?
    /// The list keeps to the newest while you're there; scrolled up, it stays where you are.
    var following = true

    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var nextTouch = 0
    @ObservationIgnored private var answer: CheckedContinuation<Said, Never>?
    @ObservationIgnored private(set) var sessions: [String: CardSession] = [:]
    @ObservationIgnored private var versions: [String: Int] = [:]
    @ObservationIgnored private var jumpTarget: String?
    /// 1 is the pace the script is written at; less is faster.
    @ObservationIgnored var pace = 1.0

    // MARK: Script

    func reset(title: String) {
        // The script waiting on it is cancelled; what it gets back is never used.
        answer?.resume(returning: Said(id: -1, speaker: .me, text: "", receipt: nil))
        answer = nil
        entries = []
        sessions = [:]
        versions = [:]
        presence = []
        composer = ""
        ask = nil
        expanded = []
        queued = []
        showsErrands = false
        speaking = nil
        jumpTarget = nil
        following = true
        self.title = title
        publish()
    }

    func wait(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(Int(Double(milliseconds) * pace)))
    }

    func time(_ text: String) {
        entries.append(.time(text))
        publish()
    }

    func unread(_ text: String) {
        entries.append(.unread(text))
        publish()
    }

    func catchUp(_ text: String) {
        entries.append(.catchUp(text))
        publish()
    }

    /// Saying something yourself brings you back to the latest, wherever you'd scrolled to.
    @discardableResult
    func say(_ speaker: FlooSpeaker, _ text: String, receipt: FlooReceipt? = nil, quote: String? = nil) -> Said {
        let said = Said(
            id: takeID(),
            speaker: speaker,
            text: text,
            receipt: speaker == .me ? receipt ?? .delivered : nil,
            quote: quote
        )
        if speaker == .me { following = true }
        entries.append(.said(said))
        publish()
        return said
    }

    /// Types `text` into the composer as a person would, then sends it.
    @discardableResult
    func type(_ text: String, receipt: FlooReceipt = .delivered, quote: String? = nil) async throws -> Said {
        try await typeOut(text)
        return say(.me, text, receipt: receipt, quote: quote)
    }

    /// Types `text` and sends it while an agent is mid-message: it waits over the composer
    /// until `land` puts it in the conversation.
    @discardableResult
    func typeWhileWriting(_ text: String) async throws -> Said {
        try await typeOut(text)
        let said = Said(id: takeID(), speaker: .me, text: text, receipt: .unseen)
        queued.append(said)
        return said
    }

    /// A waiting message takes its place, read now that the agent has finished speaking.
    func land(_ said: Said) {
        queued.removeAll { $0 === said }
        said.receipt = .read
        entries.append(.said(said))
        publish()
    }

    private func typeOut(_ text: String) async throws {
        for character in text {
            composer.append(character)
            try await wait(70)
        }
        try await wait(300)
        composer = ""
    }

    func mark(_ said: Said, _ receipt: FlooReceipt) {
        said.receipt = receipt
        publish()
    }

    /// An agent's message, empty until it works or speaks.
    func begin(_ agent: FlooAgent, at time: String, marks: [FlooMark] = []) -> Message {
        let message = Message(id: takeID(), agent: agent, time: time, marks: marks)
        entries.append(.message(message))
        publish()
        return message
    }

    func step(_ message: Message, _ step: String, source: String? = nil) {
        if message.process == nil { message.process = FlooProcess(steps: []) }
        message.process?.steps.append(step)
        if let source { message.process?.read.append(source) }
        workChanged(message.agent)
    }

    func finishWork(_ message: Message, _ summary: String) {
        message.process?.running = false
        message.process?.summary = summary
        workChanged(message.agent)
    }

    /// The agent takes something on, by name: it's in hand until its work is finished, however
    /// much else comes up meanwhile.
    func takeOn(_ message: Message, _ title: String) {
        message.process = FlooProcess(steps: [], title: title)
        workChanged(message.agent)
    }

    /// A task joins the work; one that starts now goes before those still waiting on others.
    func spawn(
        _ message: Message,
        _ id: String,
        _ title: String,
        executor: String? = nil,
        waiting: String? = nil,
        added: String? = nil
    ) {
        guard var process = message.process else { return }
        let task = FlooTask(
            id: id,
            title: title,
            executor: executor,
            added: added,
            state: waiting == nil ? .running : .waiting,
            detail: waiting ?? "开始了"
        )
        let firstWaiting = process.tasks.firstIndex { $0.state == .waiting }
        if waiting == nil, let firstWaiting {
            process.tasks.insert(task, at: firstWaiting)
        } else {
            process.tasks.append(task)
        }
        message.process = process
        workChanged(message.agent)
    }

    /// A task moves on: what it's at now, and the source it's reading, if any. It's what the
    /// work as a whole is at, too.
    func progress(_ message: Message, _ id: String, _ step: String, source: String? = nil) {
        message.process?.steps.append(step)
        updateTask(message, id) { task in
            task.state = .running
            task.detail = step
            task.steps.append(step)
            if let source, !task.sources.contains(source) { task.sources.append(source) }
        }
    }

    func complete(_ message: Message, _ id: String, _ result: String) {
        updateTask(message, id) { task in
            task.state = .done
            task.detail = result
        }
    }

    func stop(_ message: Message, _ id: String, _ note: String) {
        updateTask(message, id) { task in
            task.state = .stopped
            task.detail = note
        }
    }

    private func updateTask(_ message: Message, _ id: String, _ change: (inout FlooTask) -> Void) {
        guard let index = message.process?.tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&message.process!.tasks[index])
        nextTouch += 1
        message.process!.tasks[index].touched = nextTouch
        workChanged(message.agent)
    }

    // MARK: In hand

    /// A thing an agent has taken on and not finished.
    struct Errand: Identifiable, Equatable {
        let id: Int
        let agent: FlooAgent
        let title: String
        let doing: String
        /// When you asked for it.
        let since: String
    }

    /// Everything the agents have in hand here, oldest first.
    private(set) var errands: [Errand] = []
    /// The list of what's in hand, open over the composer.
    var showsErrands = false

    /// Over the composer, what an agent is doing is one line however much it has in hand: the
    /// one thing it's at, or how many.
    private func workChanged(_ agent: FlooAgent) {
        publish()
        refreshPresence(agent)
    }

    private func refreshPresence(_ agent: FlooAgent) {
        let working = entries.compactMap { entry -> FlooProcess? in
            if case .message(let message) = entry, message.agent == agent, let process = message.process, process.running {
                process
            } else {
                nil
            }
        }
        switch working.count {
        case 0: setPresence(agent, nil)
        case 1: setPresence(agent, "\(working[0].doing ?? "在弄")…")
        default: setPresence(agent, "手上 \(working.count) 件事")
        }
        if errands.count < 2 { showsErrands = false }
    }

    /// A message as history has it: there already, nothing to reveal.
    func write(_ message: Message, _ text: String) {
        message.text = text
        commit(message, streaming: false)
    }

    /// Streams `text` into the message as the model would, a few characters at a time;
    /// `finishing: false` when more of the same message follows.
    func stream(_ message: Message, _ text: String, perSecond: Double = 45, finishing: Bool = true) async throws {
        message.streaming = true
        setPresence(message.agent, "正在写…")
        takePlace(message)
        speaking = "m\(message.id)#sig"
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let count = min(characters.count - index, Int.random(in: 2...5))
            message.text += String(characters[index..<index + count])
            index += count
            commit(message, streaming: true)
            try await wait(Int(Double(count) / perSecond * 1000))
        }
        guard finishing else { return }
        commit(message, streaming: false)
        message.coordinator.finishQuickly()
        refreshPresence(message.agent)
        speaking = nil
    }

    /// A message takes its place when it first says something: work before that happens where
    /// the agent is, but what it says lands after everything said meanwhile, where you're reading.
    private func takePlace(_ message: Message) {
        guard message.text.isEmpty,
              let index = entries.firstIndex(where: { if case .message(let m) = $0 { m === message } else { false } }),
              index != entries.count - 1
        else { return }
        let entry = entries.remove(at: index)
        entries.append(entry)
        publish()
    }

    /// Draws the card a ```floo.draw asked for, in its place, as the drawing model streams it.
    func draw(_ card: String, chunk: Int = 24) async throws {
        guard let spec = FlooDemoCards.all[card] else { return }
        let session = CardSession(data: Self.value(spec.data))
        sessions[card] = session
        let source = Array(spec.source)
        var index = 0
        while index < source.count {
            let end = min(source.count, index + chunk)
            session.append(String(source[index..<end]))
            index = end
            versions[card, default: 0] += 1
            publish()
            try await wait(40)
        }
        session.finish()
        versions[card, default: 0] += 1
        publish()
    }

    /// A card that comes whole: a tool's own, or one drawn before.
    func card(_ card: String) -> CardSession? {
        if let session = sessions[card] { return session }
        guard let spec = FlooDemoCards.all[card] else { return nil }
        let session = CardSession(data: Self.value(spec.data))
        session.append(spec.source)
        session.finish()
        sessions[card] = session
        return session
    }

    func setPresence(_ agent: FlooAgent, _ doing: String?) {
        presence.removeAll { $0.agent == agent }
        if let doing { presence.append((agent, doing)) }
    }

    /// Asks the person and waits for an answer; the script answers for them after `autoAfter`
    /// milliseconds if they don't. The answer is read at once, since the agent is waiting on it;
    /// it's the script's to mark it answered when the agent acts on it.
    func ask(_ agent: FlooAgent, _ question: String, options: [String], autoAfter: Int) async throws -> Said {
        ask = FlooAsk(agent: agent, question: question, options: options)
        let auto = Task { [weak self] in
            try await self?.wait(autoAfter)
            self?.respond(options.last ?? "")
        }
        let chosen = await withCheckedContinuation { answer = $0 }
        auto.cancel()
        try Task.checkCancellation()
        return chosen
    }

    func respond(_ option: String) {
        guard let continuation = answer else { return }
        answer = nil
        ask = nil
        continuation.resume(returning: say(.me, option, receipt: .read))
    }

    /// Opens the conversation where it was last read rather than at its end.
    func openAtUnread() {
        guard let id = rows.first(where: { if case .unread = $0.kind { true } else { false } })?.id else { return }
        following = false
        scrollPosition.scrollTo(id: id, anchor: .top, animated: false)
    }

    /// Marks the message the catch-up line jumps to.
    func setJumpTarget(_ message: Message) {
        jumpTarget = "m\(message.id)#sig"
    }

    func jump() {
        guard let jumpTarget else { return }
        following = false
        scrollPosition.scrollTo(id: jumpTarget, anchor: .top, animated: true)
    }

    /// To where the agent took the thing on, wherever that is by now.
    func jump(to errand: Errand) {
        showsErrands = false
        following = false
        scrollPosition.scrollTo(id: "m\(errand.id)#sig", anchor: .top, animated: true)
    }

    /// Back to the newest, as the "回到最新" button does.
    func backToLatest() {
        following = true
        scrollPosition.scrollTo(edge: .bottom, animated: true)
    }

    /// The row a message's work shows in, to open it as a tap would.
    func workRow(_ message: Message) -> String { "m\(message.id)#work" }

    /// From where you asked for more, to the thing it went into.
    func jumpToErrand(titled title: String) {
        guard let errand = errands.first(where: { $0.title == title }) else { return }
        jump(to: errand)
    }

    /// From an answer given while work was going on, to that work.
    func jumpToWork(of agent: FlooAgent) {
        guard let errand = errands.last(where: { $0.agent == agent }) else { return }
        jump(to: errand)
    }

    func toggle(_ row: String) {
        if expanded.contains(row) { expanded.remove(row) } else { expanded.insert(row) }
        publish()
    }

    // MARK: Rows

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    private func commit(_ message: Message, streaming: Bool) {
        message.blocks = message.splitter.split(streaming ? Self.settled(message.text) : message.text, isStreaming: streaming)
        message.generation += 1
        message.coordinator.syncBlocks(
            message.blocks.map { ($0.id, $0.revealPlainTextCount) },
            generation: message.generation
        )
        publish()
    }

    private func publish() {
        rows = entries.flatMap(rows(for:))
        errands = entries.compactMap { entry in
            guard case .message(let message) = entry, let process = message.process, process.running,
                  let title = process.title
            else { return nil }
            return Errand(id: message.id, agent: message.agent, title: title, doing: process.doing ?? "在弄", since: message.time)
        }
    }

    private func rows(for entry: Entry) -> [FlooRow] {
        switch entry {
        case .time(let text):
            return [FlooRow(id: "time:\(text)", message: nil, kind: .time(text))]
        case .unread(let text):
            return [FlooRow(id: "unread", message: nil, kind: .unread(text))]
        case .catchUp(let text):
            return [FlooRow(id: "catchUp", message: nil, kind: .catchUp(text))]
        case .said(let said):
            return [FlooRow(id: "s\(said.id)", message: nil, kind: .said(said.speaker, said.text, said.receipt, quote: said.quote))]
        case .message(let message):
            // A message is there once it has something: its first step of work or words.
            guard message.process != nil || !message.blocks.isEmpty else { return [] }
            var rows = [
                FlooRow(
                    id: "m\(message.id)#sig",
                    message: message.id,
                    kind: .signature(message.agent, message.time, message.marks)
                )
            ]
            var work: FlooRow?
            if let process = message.process {
                let id = "m\(message.id)#work"
                let open = Set(process.tasks.map(\.id).filter { expanded.contains("\(id)/\($0)") })
                work = FlooRow(id: id, message: message.id, kind: .process(process, expanded: expanded.contains(id), open: open))
            }
            if let work, !message.processAfterText { rows.append(work) }
            for block in message.blocks {
                let id = "m\(message.id)#\(block.id)"
                if case .customFence(let language) = block.kind {
                    let body = Self.fenceBody(block.source)
                    let card = Self.cardName(language, body)
                    rows.append(FlooRow(
                        id: id,
                        message: message.id,
                        kind: .fence(language, body.joined(separator: "\n"), version: card.flatMap { versions[$0] } ?? 0)
                    ))
                } else {
                    rows.append(FlooRow(id: id, message: message.id, kind: .block(block, streaming: message.streaming)))
                }
            }
            if let work, message.processAfterText { rows.append(work) }
            return rows
        }
    }

    func message(_ id: Int) -> Message? {
        for entry in entries {
            if case .message(let message) = entry, message.id == id { return message }
        }
        return nil
    }

    /// The lines between a fence's first line and its end.
    nonisolated static func fenceBody(_ source: String) -> [String] {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }
        lines.removeFirst()
        if let last = lines.last, last.hasPrefix("```") { lines.removeLast() }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// What of a message being written can be shown: all but a fence's first line still being
    /// written, which would show as code until its language is whole, then leave the list.
    nonisolated static func settled(_ text: String) -> String {
        guard let lineStart = text.lastIndex(of: "\n").map({ text.index(after: $0) }) ?? Optional(text.startIndex),
              text[lineStart...].trimmingCharacters(in: .whitespaces).hasPrefix("`")
        else { return text }
        return String(text[..<lineStart])
    }

    /// A fence's lines that are written through: all of them once it's closed, else those a
    /// newline has ended.
    nonisolated static func wholeLines(_ source: String) -> [String] {
        let body = fenceBody(source)
        let closed = source.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().last?
            .trimmingCharacters(in: .whitespaces).hasPrefix("```") ?? false
        return closed || source.hasSuffix("\n") ? body : Array(body.dropLast())
    }

    /// The card a fence shows: the `card:` line of a draw, the one line of a card.
    nonisolated static func cardName(_ language: String, _ body: [String]) -> String? {
        switch language {
        case "floo.draw":
            body.first { $0.hasPrefix("card:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        case "floo.card":
            body.first { !$0.isEmpty }
        default:
            nil
        }
    }

    static func value(_ json: String) -> CardValue {
        (try? JSONDecoder().decode(CardValue.self, from: Data(json.utf8))) ?? .object([:])
    }
}
