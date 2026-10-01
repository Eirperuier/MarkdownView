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
    /// It can't go on until you allow something on your device.
    var waitsForYou = false

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
        /// A ```floo.choice fence: its options so far, and which one you picked if you did.
        case choice([FlooChoice], chosen: Int?)
        /// An ask card on a message: in the conversation where it was asked.
        case ask(FlooAskCard)
    }

    let id: String
    let message: Int?
    let kind: Kind
}

/// One option of a choice or an ask: a few words, and the complete request tapping it sends.
/// `image` is an asset name here, standing in for a tool-result URL; `from` keys a mention or
/// a small card shown on the option.
struct FlooOption: Hashable {
    var label: String
    var send: String?
    var detail: String?
    var image: String?
    var from: String?
}

/// A floo.choice option as a row shows it: it can be tapped once its `send:` line is whole.
struct FlooChoice: Hashable {
    let option: FlooOption
    let tappable: Bool
}

/// Something an agent asks without stopping: the card rides on the message that asked, the
/// agent goes on, and it stays until answered, withdrawn, or expired.
struct FlooAskItem: Hashable {
    enum Form: Hashable {
        /// Pick one or more; `own` is what the script types when "其他…" is the answer.
        case choose(options: [FlooOption], multiple: Bool, own: String?)
        /// Whether to do what `effect` says will happen.
        case confirm(effect: String, yes: String, no: String)
        /// A few things to fill in, each with the agent's guess.
        case fill(fields: [Field])
    }

    struct Field: Hashable {
        let label: String
        let kind: Kind
        var guess: String
        enum Kind { case text, number, date, time, place, person }
    }

    /// A short name, for the quote the answer carries: "修复方向".
    let title: String
    let question: String
    let form: Form
    /// nil while it's still open.
    var answer: String?
}

struct FlooAskCard: Hashable, Identifiable {
    let id: String
    let agent: FlooAgent
    var items: [FlooAskItem]
    var state: State
    enum State { case open, answered, withdrawn, expired }
}

/// How an ask's item gets answered, by you or by the script answering for you.
enum FlooAnswerPick {
    case option(Int)
    /// Several of a choose(multiple:) item.
    case options([Int])
    /// In your own words: the item's `own` is typed out over the composer, then sent.
    case own
    case confirm(Bool)
    /// Its guesses are right as they are.
    case fill
}

/// An item you're answering in your own words, over the composer while you write.
struct FlooAnsweringItem: Equatable {
    let agent: FlooAgent
    let question: String
}

/// Something an agent wants to do on one of your devices, as that device will do it: the
/// operation and what it's done with, not the agent's words about it. Kept above the composer
/// until you allow it or not.
struct FlooApproval: Equatable {
    let agent: FlooAgent
    /// The device it runs on: "iPhone", "MacBook".
    let device: String
    let action: String
    /// What it's done with, one thing a line: the event's title, its time, the reminder.
    let details: [String]
    /// The call itself, as the device gets it: the tool and its arguments.
    let call: String
    /// What allowing it is called: "允许", or for what can't be undone, what it does ("删除").
    var confirm = "允许"
    /// Can't be undone: asked every time, never covered by having allowed it before.
    var dangerous = false
    /// Runs on another of your devices; allowed here all the same.
    var elsewhere = false
    /// What you may allow from now on instead of just this once: this kind of call, the service.
    var standing: [String] = []

    /// "这台 iPhone", or "你的 MacBook" when it's another one.
    var place: String { elsewhere ? "你的 \(device)" : "这台 \(device)" }
}

/// What you said to something an agent wanted to do on your device.
enum FlooDecision: Equatable {
    case once
    /// Allowed from now on, as the standing choice put it.
    case always(String)
    case denied

    var allowed: Bool { self != .denied }
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
        /// What it asked without stopping: cards on this message, after its words.
        var asks: [FlooAskCard] = []
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
    /// The asks still open, oldest message first: what the line over the composer counts.
    private(set) var openAsks: [(message: Int, card: FlooAskCard)] = []
    private(set) var approval: FlooApproval?
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
    /// Which option of a floo.choice fence you picked, by the fence's row: picking another
    /// later is allowed.
    private var chosen: [String: Int] = [:]
    @ObservationIgnored private var choiceSaid: [String: (option: FlooOption, said: Said)] = [:]
    @ObservationIgnored private var choiceWaits: [String: CheckedContinuation<(option: FlooOption, said: Said), Never>] = [:]
    @ObservationIgnored private var askWaits: [String: CheckedContinuation<Said, Never>] = [:]
    @ObservationIgnored private var decision: CheckedContinuation<FlooDecision, Never>?
    /// The list of open asks, open over the composer.
    var showsAsks = false
    /// What you're answering in your own words: over the composer while you write.
    private(set) var answering: FlooAnsweringItem?
    @ObservationIgnored private(set) var sessions: [String: CardSession] = [:]
    @ObservationIgnored private var versions: [String: Int] = [:]
    @ObservationIgnored private var jumpTarget: String?
    /// 1 is the pace the script is written at; less is faster.
    @ObservationIgnored var pace = 1.0

    // MARK: Script

    func reset(title: String) {
        // The script waiting on it is cancelled; what it gets back is never used.
        let cancelled = Said(id: -1, speaker: .me, text: "", receipt: nil)
        for wait in choiceWaits.values { wait.resume(returning: (FlooOption(label: ""), cancelled)) }
        for wait in askWaits.values { wait.resume(returning: cancelled) }
        decision?.resume(returning: .denied)
        decision = nil
        choiceWaits = [:]
        askWaits = [:]
        choiceSaid = [:]
        chosen = [:]
        approval = nil
        answering = nil
        entries = []
        sessions = [:]
        versions = [:]
        presence = []
        composer = ""
        openAsks = []
        showsAsks = false
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
            // Waiting on you it isn't at anything: what it waits for is over the composer.
            if case .message(let message) = entry, message.agent == agent, let process = message.process, process.running,
                !process.waitsForYou
            {
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

    /// Asks without stopping: the card rides on the message that asked, the script goes on.
    /// Answers come in as your messages, each quoting its item.
    func ask(_ message: Message, _ card: FlooAskCard) {
        message.asks.append(card)
        publish()
    }

    /// Waits for one item of an ask; the script answers for you after `autoAfter`
    /// milliseconds if you don't. Several asks and items can be waited on at once.
    func awaitAnswer(_ id: String, item: Int, autoAfter: Int, auto: FlooAnswerPick) async throws -> Said {
        if let message = askMessage(id), let card = message.asks.first(where: { $0.id == id }),
           card.items.indices.contains(item), let answered = card.items[item].answer
        {
            return Said(id: -1, speaker: .me, text: answered, receipt: .read, quote: "回答「\(card.items[item].title)」")
        }
        let automatic = Task { [weak self] in
            try await self?.wait(autoAfter)
            self?.answerAsk(id, item: item, auto)
        }
        let said = await withCheckedContinuation { askWaits["\(id)#\(item)"] = $0 }
        automatic.cancel()
        try Task.checkCancellation()
        return said
    }

    /// Your answer to an item: a message of yours quoting it, and the card closes when every
    /// item is answered.
    func answerAsk(_ id: String, item index: Int, _ pick: FlooAnswerPick) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }),
              message.asks[ci].state == .open,
              message.asks[ci].items.indices.contains(index), message.asks[ci].items[index].answer == nil
        else { return }
        let item = message.asks[ci].items[index]
        let value: String
        switch (pick, item.form) {
        case (.option(let i), .choose(let options, _, _)) where options.indices.contains(i):
            value = options[i].send ?? options[i].label
        case (.options(let picked), .choose(let options, _, _)):
            value = picked.sorted().compactMap { options.indices.contains($0) ? options[$0].send ?? options[$0].label : nil }
                .joined(separator: "、")
            guard !value.isEmpty else { return }
        case (.confirm(let yes), .confirm(_, let y, let n)):
            value = yes ? y : n
        case (.fill, .fill(let fields)):
            value = fields.map(\.guess).joined(separator: "，")
        case (.own, .choose(_, _, let own)):
            guard let own else { return }
            answering = FlooAnsweringItem(agent: message.asks[ci].agent, question: item.question)
            Task {
                try? await typeOut(own)  // try?: cut short, it's sent as far as it got
                // Reset meanwhile: the script waiting on it is gone.
                guard answering == FlooAnsweringItem(agent: message.asks[ci].agent, question: item.question) else { return }
                answering = nil
                finishAnswer(id, item: index, own)
            }
            return
        default:
            return
        }
        finishAnswer(id, item: index, value)
    }

    private func finishAnswer(_ id: String, item index: Int, _ value: String) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }) else { return }
        message.asks[ci].items[index].answer = value
        if message.asks[ci].items.allSatisfy({ $0.answer != nil }) { message.asks[ci].state = .answered }
        let said = say(.me, value, receipt: .read, quote: "回答「\(message.asks[ci].items[index].title)」")
        askWaits.removeValue(forKey: "\(id)#\(index)")?.resume(returning: said)
    }

    /// The ask is taken back: the card stays, struck through, and nothing waits on it.
    func withdraw(_ id: String) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }) else { return }
        message.asks[ci].state = .withdrawn
        for index in message.asks[ci].items.indices {
            askWaits.removeValue(forKey: "\(id)#\(index)")?
                .resume(returning: Said(id: -1, speaker: .me, text: "", receipt: nil))
        }
        publish()
    }

    private func askMessage(_ id: String) -> Message? {
        for entry in entries {
            if case .message(let message) = entry, message.asks.contains(where: { $0.id == id }) { return message }
        }
        return nil
    }

    /// Tapping a floo.choice option sends its `send` as your message and marks it 选了;
    /// picking another later is allowed.
    func choose(_ row: String, _ index: Int, _ option: FlooOption) {
        chosen[row] = index
        let said = say(.me, option.send ?? option.label, receipt: .read)
        choiceSaid[row] = (option, said)
        choiceWaits.removeValue(forKey: row)?.resume(returning: (option, said))
    }

    /// Waits for a tap on the `nth` choice fence of a message; the script taps option `auto`
    /// for you after `autoAfter` milliseconds if you don't. Waits on different fences run
    /// side by side.
    func awaitChoice(_ message: Message, _ nth: Int = 0, autoAfter: Int, auto: Int) async throws -> (option: FlooOption, said: Said) {
        guard let (row, options) = choiceRow(message, nth) else { throw CancellationError() }
        if let done = choiceSaid[row] { return done }
        let automatic = Task { [weak self] in
            try await self?.wait(autoAfter)
            if options.indices.contains(auto) { self?.choose(row, auto, options[auto]) }
        }
        let picked = await withCheckedContinuation { choiceWaits[row] = $0 }
        automatic.cancel()
        try Task.checkCancellation()
        return picked
    }

    /// The row of a message's `nth` floo.choice fence and its options, once it's in the list.
    private func choiceRow(_ message: Message, _ nth: Int) -> (id: String, options: [FlooOption])? {
        var seen = 0
        for block in message.blocks {
            guard case .customFence(let language) = block.kind, language == "floo.choice" else { continue }
            if seen == nth {
                return ("m\(message.id)#\(block.id)", Self.choiceOptions(block.source).map(\.option))
            }
            seen += 1
        }
        return nil
    }

    /// A floo.choice fence's options so far: an option shows once its `- ` label line is
    /// whole, and it can be tapped once its `send:` line is whole too or the fence is closed.
    nonisolated static func choiceOptions(_ source: String) -> [(option: FlooOption, tappable: Bool)] {
        let body = fenceBody(source)
        let whole = wholeLines(source)
        let closed = source.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().last?
            .trimmingCharacters(in: .whitespaces).hasPrefix("```") ?? false
        var options: [(option: FlooOption, tappable: Bool)] = []
        for (index, line) in body.enumerated() where !line.isEmpty {
            if line.hasPrefix("- ") {
                guard closed || index < whole.count else { continue }
                options.append((FlooOption(label: String(line.dropFirst(2))), tappable: closed))
            } else if !options.isEmpty, let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "send":
                    options[options.count - 1].option.send = value
                    options[options.count - 1].tappable = closed || index < whole.count
                case "detail": options[options.count - 1].option.detail = value
                case "image": options[options.count - 1].option.image = value
                case "from": options[options.count - 1].option.from = value
                default: break
                }
            }
        }
        return options
    }

    /// Asks to do something on your device and waits for you; the script decides for you after
    /// `autoAfter` milliseconds if you don't. Its work waits on you meanwhile.
    func approve(
        _ approval: FlooApproval,
        for message: Message,
        autoAfter: Int,
        deciding: FlooDecision
    ) async throws -> FlooDecision {
        self.approval = approval
        message.process?.waitsForYou = true
        workChanged(message.agent)
        let auto = Task { [weak self] in
            try await self?.wait(autoAfter)
            self?.decide(deciding)
        }
        let decided = await withCheckedContinuation { decision = $0 }
        auto.cancel()
        message.process?.waitsForYou = false
        workChanged(message.agent)
        try Task.checkCancellation()
        return decided
    }

    func decide(_ decided: FlooDecision) {
        guard let continuation = decision else { return }
        decision = nil
        approval = nil
        continuation.resume(returning: decided)
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

    /// To the card an open ask rides on, wherever in the conversation it was asked.
    func jump(toAsk waiting: (message: Int, card: FlooAskCard)) {
        showsAsks = false
        following = false
        scrollPosition.scrollTo(id: "m\(waiting.message)#ask-\(waiting.card.id)", anchor: .top, animated: true)
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
        openAsks = entries.flatMap { entry -> [(message: Int, card: FlooAskCard)] in
            guard case .message(let message) = entry else { return [] }
            return message.asks.filter { $0.state == .open }.map { (message: message.id, card: $0) }
        }
        if openAsks.count < 2 { showsAsks = false }
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
                    if language == "floo.choice" {
                        let options = Self.choiceOptions(block.source).map { FlooChoice(option: $0.option, tappable: $0.tappable) }
                        rows.append(FlooRow(id: id, message: message.id, kind: .choice(options, chosen: chosen[id])))
                        continue
                    }
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
            // What it asked rides on its words; the work it went on with is under them.
            for card in message.asks {
                rows.append(FlooRow(id: "m\(message.id)#ask-\(card.id)", message: message.id, kind: .ask(card)))
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
