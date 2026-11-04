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
import DocKit
import FlooDesign
import Wire

/// Who wrote a message: the butler, or one of the person's services, by the name it goes by.
struct FlooAgent: Hashable, Sendable {
    let name: String
    let tint: Color

    static let butler = FlooAgent(name: "管家", tint: .indigo)
    static let weather = FlooAgent(name: "天气", tint: .cyan)
    static let health = FlooAgent(name: "健康", tint: .pink)
}

enum FlooSpeaker: Hashable, Sendable {
    case me
    case person(String)
}

/// A conversation of the backend's you can go to (FlooLive): the main one, a group, or one
/// with a service. A group with you and one agent in it is called a topic (floo
/// messaging.md §3.13.7), one with more a group: the same kind, named by who's in it.
struct FlooPlace: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case main
        case group
        case topic
        case service
    }

    let id: String
    let title: String
    let kind: Kind
    var unread = 0
}

/// Where a person's message is, as the agents have it: kept, read into an agent's context,
/// answered.
enum FlooReceipt: Hashable, Sendable {
    case delivered, unseen, read, answered
    /// Shown as you send it, before the backend has it (FlooLive); and one that didn't go.
    case sending, failed

    var label: String {
        switch self {
        case .sending: "发送中"
        case .failed: "未发送，点按重发"
        case .delivered: "已送达"
        case .unseen: "还没看到"
        case .read: "已读"
        case .answered: "已回应"
        }
    }
}

/// A reaction as a bubble shows it (floo messaging.md §3.11): one emoji, how many gave it,
/// whether you did, and who did, as they're called.
struct FlooReaction: Hashable, Sendable {
    let emoji: String
    let count: Int
    let mine: Bool
    let who: [String]

    /// The ones a message's menu offers.
    static let offered = ["👍", "❤️", "😂", "👀", "🎉", "🔥", "😢", "🤔"]
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
    /// What you asked for went into a thing it already had in hand, by that thing's name; the
    /// agent's own words for it, when it gave some.
    case joined(String, label: String? = nil)
    /// It replies to an earlier message, shown over it.
    case replying(FlooReply)
    /// A commitment it took on, changed or stopped in this message: the rule and what it does.
    case committed(String)
}

/// What a message replies to, over its bubble (messaging.md §3.12.4): who said that one, and
/// how it begins, the words picked out of it, or the question it answers; and where it is.
struct FlooReply: Hashable, Sendable {
    enum Shown: Hashable, Sendable {
        /// How it begins.
        case begins(String)
        /// The words picked out of it.
        case part(String)
        /// The question it answers, by its title.
        case answer(String)
        /// It isn't here: an older message.
        case older
    }

    /// Who said it, as their initial on their colour; nil, nobody shown.
    var initial: String?
    var tint: Color?
    var shown: Shown
    /// The row it's in, to go to, and its bubble, lit up there; nil when it isn't shown.
    var row: String? = nil
    var bubble: String? = nil
}

extension FlooReply {
    /// To a message of `agent`'s.
    init(_ agent: FlooAgent, _ shown: Shown, row: String? = nil, bubble: String? = nil) {
        self.init(initial: String(agent.name.prefix(1)), tint: agent.tint, shown: shown, row: row, bubble: bubble)
    }
}

/// A thread as its first message shows it (floo messaging.md §3.13.4): how many replies,
/// and who replied, first to reply first, by their initials on their colours.
struct FlooThreadLine: Hashable, Sendable {
    struct Face: Hashable, Sendable {
        let initial: String
        let tint: Color
    }

    let count: Int
    let faces: [Face]
}

/// A thread open over the conversation (floo messaging.md §3.13.4): its first message's
/// number and its messages, oldest first; what's said in it replies to its newest.
struct FlooThreadShown: Identifiable, Equatable {
    struct Line: Identifiable, Equatable {
        /// The message's number.
        let id: Int64
        let who: String
        let face: FlooThreadLine.Face
        let mine: Bool
        let text: String
        let time: String
    }

    let id: Int64
    var lines: [Line]
    /// Not all of it is on this device yet.
    var loading = false
}

/// Someone in a group as its members sheet shows them (FlooLive): its host first.
struct FlooMember: Identifiable, Hashable {
    let participant: Participant
    let name: String
    let agent: Bool
    let host: Bool

    var id: Participant { participant }
}

/// The message you're replying to, over the composer while you write.
struct FlooReplyDraft: Equatable {
    let number: Int64
    /// Whose it is: "管家", "你".
    let who: String
    let begins: String
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
        /// The day the messages under it were said on, named where it's shown (今天, 昨天, a date).
        case day(Date)
        case unread(String)
        case catchUp(String)
        /// Who said it, what, where it is with the agents, and what it replies to.
        case said(FlooSpeaker, String, FlooReceipt?, reply: FlooReply?)
        case signature(FlooAgent, String, [FlooMark])
        /// Its work, whether it's opened, and which of its tasks are.
        case process(FlooProcess, expanded: Bool, open: Set<String>)
        /// A block of words; `reveals`: they came in while shown, and come out with their reveal.
        case block(MarkdownStreamBlock, reveals: Bool)
        /// An agent's work at the top of its message's bubble (FlooAgentWork): where it is until
        /// its words start coming out, how it went when you ask.
        case work(FlooWorkShown)
        /// A ```floo.* fence: its language, what's in it, how far its card is drawn, and for
        /// the backend's cards, the frame its header names (cards.md: size and overflow).
        case fence(String, String, version: Int, layout: CardLayout? = nil)
        /// The backend's cards one after another with nothing between: side by side as the
        /// width allows (FlooCardRun).
        case cards([FlooCard])
        /// A ```floo.choice fence: its options so far, and which one you picked if you did.
        case choice([FlooChoice], chosen: Int?)
        /// An ask card on a message: in the conversation where it was asked.
        case ask(FlooAskCard)
        /// The topics a thread on a message was made into, to go to.
        case topics([FlooPlace])
        /// The replies to a message, under it: to open its thread.
        case replies(FlooThreadLine, trailing: Bool)
        /// Who a person's message in a group went to when they @'d no one (floo messaging.md
        /// §3.13.7): what the judge or the host made of it.
        case sentTo(String, trailing: Bool)
        /// Where an answer was found, as the backend checked it (FlooLive): in its message's
        /// bubble; several with nothing between, one card of them.
        case mentions([Mention])
        /// A page the agent wrote (```floo.page): its path under /drive/, and its title and
        /// preview, as Docs' page block shows them.
        case page(String, DocPage)
        /// Images in its words, taken out of them (FlooImages): one, or a run of them.
        case images([FlooImage])
        /// The reactions on a message, under its bubble: on the side of yours when it's yours.
        case reactions([FlooReaction], trailing: Bool)
    }

    let id: String
    let message: Int?
    let kind: Kind
    /// Where the block sits in its message's bubble, when agents' words are in bubbles.
    var bubble: FlooBubble?
    /// A person's message's number in the backend's conversation (FlooLive); an agent's is its
    /// message's.
    var number: Int64? = nil
}

/// One of the backend's cards in a run of them: a drawing (its request and its card) or a
/// tool's card, at the size its fence names, and how far it's drawn.
struct FlooCard: Equatable {
    let language: String
    let lines: [String]
    let version: Int
    let layout: CardLayout
}

/// A page open over the conversation: its path, and the page as it was read.
struct FlooOpenPage: Identifiable {
    let id: String
    let doc: Doc
}

/// A thing a floo link found on this device, open over the conversation (floo's
/// docs/services.md §2.10): the link, and the thing as its service tells it.
struct FlooOpenThing: Identifiable {
    let id: String
    let title: String
    let text: String
}

/// A block of an agent's words in its bubble: the blocks between two cards are one bubble,
/// drawn once behind their rows.
struct FlooBubble: Equatable {
    /// The bubble's first row, which names it.
    let run: String
    let top: Bool
    let last: Bool
}

/// What of a bubble's rows is shown, by row: the bubble is drawn around it.
@MainActor
@Observable
final class FlooBubbleState {
    /// Where a row's words are and how much of them is revealed.
    struct Shown: Equatable {
        /// The revealed words, from where they start, in the row; nothing revealed is no height,
        /// nil not told yet.
        var words: CGRect?
        /// All its words, laid out whole.
        var whole: CGRect
        /// How wide the words can be.
        var room: CGFloat
    }

    /// The coordinate space of a row, where its words are told.
    static let space = "flooRow"

    /// What each row's words last told, while it was on screen.
    var rows: [String: Shown] = [:]
    /// The rows whose words are all revealed. Kept from the reveal itself, which runs on with
    /// a row off screen: a row that finished there has its bubble whole.
    private(set) var finished: Set<String> = []
    @ObservationIgnored private var following: [String: (manager: StreamingRevealManager, listener: UUID?)] = [:]

    /// Follows a row's reveal; nil: its words are all there. A row with no words yet isn't
    /// finished, whatever its reveal says (a reveal with nothing to reveal tells it's done).
    func follow(_ row: String, reveal manager: StreamingRevealManager?, empty: Bool = false) {
        if let followed = following[row] {
            guard followed.manager !== manager || (followed.listener == nil) != empty else { return }
            if let listener = followed.listener { followed.manager.removeRevealCompletionListener(listener) }
            following[row] = nil
        }
        guard let manager else {
            finished.insert(row)
            return
        }
        if empty {
            finished.remove(row)
            following[row] = (manager, nil)
            return
        }
        let listener = manager.addRevealCompletionListener { [weak self] revealed in
            guard let self, revealed != finished.contains(row) else { return }
            // The reveal moved on: the bubble follows with the layout spring.
            withAnimation(FlooDesignTokens.Motion.layout) {
                if revealed { finished.insert(row) } else { finished.remove(row) }
            }
        }
        following[row] = (manager, listener)
    }
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

/// One part of a request (floo interaction.md §4): a request is a header and a list of these,
/// drawn in order by one card. A control is a part, not a purpose — a sign-in is two secrets
/// and a toggle, a picture code a view and a field. Its `id` is what its value goes by.
struct FlooControlModel: Hashable, Identifiable {
    let id: String
    /// What the person sees by it: a choice's question, a toggle's words, a link's.
    var label: String?
    /// Whether it must be answered before the request is sent (answered kinds only).
    var required = true
    /// The variant it belongs to where a choice with `groups` picks one (§4.5): shown and
    /// sent only when that group is picked.
    var group: String?
    var kind: Kind

    enum Kind: Hashable {
        /// Pick one or more; `own`, where they may write their own: a box on the card, sent
        /// with its 提交 (§3.3), and what the script types out over the composer ("" live).
        /// `groups`: its options are the request's variants (密码 / 邮件验证码).
        case choice(options: [FlooOption], multiple: Bool = false, own: String? = nil, groups: Bool = false)
        /// A detail to type or pick, the asker's guess filled in.
        case field(FlooField)
        /// What only the device that does it may know — a password, a code: sealed to it,
        /// never the agent's. `kind` as the wire names it (password, email, code…).
        case secret(FlooField, kind: String)
        /// The asker's buttons, signed here (§4.3): the first that isn't standing goes ahead,
        /// the standing ones behind its long press, a dangerous one red.
        case decision([FlooDecisionOption])
        /// Something to do on that device: `open` the button that takes it on, `done` the one
        /// that says it's through.
        case step(what: String, open: String = "我来做", done: String = "做完了")
        /// A live part of a web page, as its device captured it; a new frame as it changes.
        case view(FlooViewFrame)
        /// A tick, `value` its default; `keep`, it is 「在我的所有设备上保持登录」.
        case toggle(value: Bool, keep: Bool = false)
        case say(String)
        case link(url: String)
        case image(url: String)
        /// A kind this build doesn't know: the whole card is answered elsewhere (§8.4).
        case unknown(type: String)
    }

    /// Whether the person answers it (§3.3): a choice, a field, a secret, a decision, a step.
    var answered: Bool {
        switch kind {
        case .choice, .field, .secret, .decision, .step: true
        case .view, .toggle, .say, .link, .image, .unknown: false
        }
    }

    var mustAnswer: Bool { answered && required }

    /// The words of 「在我的所有设备上保持登录」 as a control.
    static func keep(_ on: Bool, id: String = "keep") -> FlooControlModel {
        FlooControlModel(id: id, label: "在我的所有设备上保持登录", kind: .toggle(value: on, keep: true))
    }
}

/// A field as a card types it.
struct FlooField: Hashable {
    let label: String
    let kind: Kind
    var guess: String
    enum Kind { case text, number, date, time, place, person, file, secret }
    /// Where a value comes from when you don't type it: "钥匙串", "从邮件填".
    var autofill: String?
    /// What the system's autofill offers for it (a secret): the account, its password, a code.
    var content: Content?
    enum Content { case username, email, password, newPassword, code }
}

/// One of a decision's buttons: `key` what is signed, `label` what you see; `standing` lasts
/// beyond this once, `danger` can't be undone.
struct FlooDecisionOption: Hashable {
    let key: String
    let label: String
    var standing = false
    var danger = false

    /// How a card draws them: the first that isn't standing goes ahead, the last other one
    /// declines; the standing ones (and any more) wait behind a long press of the first. Nil
    /// with fewer than two.
    static func buttons(_ options: [FlooDecisionOption]) -> (go: Self, no: Self, aside: [Self])? {
        let now = options.filter { !$0.standing }
        guard let go = now.first ?? options.first,
              let no = now.count > 1 ? now.last : options.last(where: { $0 != go })
        else { return nil }
        return (go, no, options.filter { $0 != go && $0 != no })
    }
}

/// A view's frame: a PNG `width` × `height` pixels at `scale` pixels per point of the page,
/// named by `sha256`. Only for looking (人 2026-11-04「我不需要用户交互网页」). `state`: when the
/// frame is not the part as it is now — something on the page lies over it (`cover` says what)
/// while its agent deals with it, or it is no longer on the page (floo interaction.md §4.3 view).
struct FlooViewFrame: Hashable {
    let png: Data
    let sha256: String
    let width: Int
    let height: Int
    let scale: Double
    var state: FlooViewState? = nil
    var cover: String? = nil
}

enum FlooViewState: String, Hashable {
    case covered, gone
}

/// How a request is sent, from its controls (floo interaction.md §3.3), never written apart.
enum FlooSubmit {
    /// One control to answer, decided by a tap (one pick without their own words, a decision,
    /// a step): its own buttons.
    case tap
    /// Anything to fill: one 提交 (and 不做了).
    case button
    /// Nothing to answer (a view, a toggle, words): its asker closes it; 不做了.
    case asker
}

/// A value given on a card, by control id; a secret's never among them.
enum FlooValue: Hashable {
    case choice([Int], own: String? = nil)
    case text(String)
    case key(String)
    case step(FlooStepPick)
    case toggle(Bool)
}

/// One request (floo interaction.md §3): what it's called, its words, its controls in order.
/// The card's header (who, where, why) is its card's; an agent's older ask may hold several.
/// Grown midway (§4.5), the controls before `from` were sent before: folded to `earlier`.
struct FlooRequest: Hashable {
    /// A short name, for the quote the answer carries: "修复方向".
    let title: String
    let question: String
    var controls: [FlooControlModel]
    var from = 0
    /// What was sent of the controls before `from`, a line each time.
    var earlier: [String] = []
    /// The words of its 提交.
    var submitLabel = "提交"
    /// nil while it's still open.
    var answer: String?

    init(title: String, question: String, controls: [FlooControlModel], answer: String? = nil) {
        self.title = title
        self.question = question
        self.controls = controls
        self.answer = answer
    }

    /// Whether some control is one this build doesn't know.
    var unknown: Bool { controls.contains { if case .unknown = $0.kind { true } else { false } } }

    /// The choice whose options are the variants, if there is one.
    var groups: FlooControlModel? {
        controls.first { if case .choice(_, _, _, true) = $0.kind { true } else { false } }
    }

    /// The group picked: `picked` of the groups choice, its first option before that.
    func group(_ picked: [Int]?) -> String? {
        guard let groups, case .choice(let options, _, _, _) = groups.kind, !options.isEmpty else { return nil }
        let index = picked?.first.flatMap { options.indices.contains($0) ? $0 : nil } ?? 0
        return options[index].label
    }

    /// The controls to answer now: from `from`, those of the picked group.
    func current(group: String?) -> [FlooControlModel] {
        controls.dropFirst(from).filter { $0.group == nil || $0.group == group }
    }

    /// How it is sent (§3.3).
    func submit(group: String? = nil) -> FlooSubmit {
        let answering = current(group: group ?? self.group(nil)).filter(\.answered)
        guard let only = answering.first else { return .asker }
        guard answering.count == 1 else { return .button }
        switch only.kind {
        // Their own words are typed on the card, so only a pick that can't be written goes on a tap.
        case .choice(_, let multiple, let own, let groups): return multiple || groups || own != nil ? .button : .tap
        case .decision, .step: return .tap
        default: return .button
        }
    }

    /// The options of its first choice (a vote's).
    var choiceOptions: [FlooOption] {
        for control in controls { if case .choice(let options, _, _, _) = control.kind { return options } }
        return []
    }

    /// What a pick of the script's, or a tap's, gives each control now; nil if it gives none.
    func resolve(_ pick: FlooAnswerPick) -> (values: [String: FlooValue], secrets: [String: String])? {
        let now = current(group: group(nil))
        let choice = now.first { if case .choice(_, _, _, false) = $0.kind { true } else { false } }
        switch pick {
        case .submit(let values, let secrets): return (values, secrets)
        case .option(let index): return choice.map { ([$0.id: .choice([index])], [:]) }
        case .options(let picked): return choice.map { ([$0.id: .choice(picked.sorted())], [:]) }
        case .confirm(let yes): return choice.map { ([$0.id: .choice([yes ? 0 : 1])], [:]) }
        case .decide(let go, let standing):
            for control in now {
                guard case .decision(let options) = control.kind, let buttons = FlooDecisionOption.buttons(options) else { continue }
                let option = !go ? buttons.no : standing.flatMap { label in buttons.aside.first { $0.label == label } } ?? buttons.go
                return ([control.id: .key(option.key)], [:])
            }
            return nil
        case .step(let step) where step != .open:
            return now.first { if case .step = $0.kind { true } else { false } }.map { ([$0.id: .step(step)], [:]) }
        case .guesses:
            var values: [String: FlooValue] = [:]
            var secrets: [String: String] = [:]
            if let groups { values[groups.id] = .choice([0]) }
            for control in now {
                switch control.kind {
                case .choice(_, _, _, false): values[control.id] = .choice([0])
                case .field(let field): values[control.id] = .text(field.guess)
                case .secret(let field, _): secrets[control.id] = field.guess
                case .decision(let options): FlooDecisionOption.buttons(options).map { values[control.id] = .key($0.go.key) }
                case .step: values[control.id] = .step(.done)
                case .toggle(let on, _): values[control.id] = .toggle(on)
                default: break
                }
            }
            return (values, secrets)
        default: return nil
        }
    }

    /// The answer in a line (§3.4): the picks' words, what was typed, the button pressed, a
    /// step's state, a ticked toggle's words; secrets only that they went to `sealedTo`. A
    /// pick or a decision alone is its words alone.
    func said(_ values: [String: FlooValue], _ secrets: [String: String], sealedTo: String?, separator: String = " · ") -> String {
        var parts: [String] = []
        var sealed = false
        for control in controls.dropFirst(from) {
            switch (control.kind, values[control.id]) {
            case (.choice(let options, _, _, _), .choice(let picked, let own)?):
                var words = picked.filter(options.indices.contains).map { options[$0].send ?? options[$0].label }
                if let own, !own.isEmpty { words.append(own) }
                guard !words.isEmpty else { continue }
                let joined = words.joined(separator: "、")
                parts.append(control.label.map { "\($0)：\(joined)" } ?? joined)
            case (.field(let field), .text(let words)?):
                parts.append(field.label.isEmpty ? words : "\(field.label)：\(words)")
            case (.secret, _):
                guard !sealed, secrets[control.id]?.isEmpty == false else { continue }
                sealed = true
                parts.append("已交给 \(sealedTo ?? "那台设备")")
            case (.decision(let options), .key(let key)?):
                if let option = options.first(where: { $0.key == key }) { parts.append(option.label) }
            case (.step(_, _, let done), .step(let step)?):
                parts.append(step == .skip ? "跳过了" : done)
            case (.toggle, .toggle(true)?):
                if let label = control.label { parts.append(label) }
            default: break
            }
        }
        return parts.joined(separator: separator)
    }
}

struct FlooAskCard: Hashable, Identifiable {
    let id: String
    let agent: FlooAgent
    var items: [FlooRequest]
    var state: State
    /// Asking several, ended before all answered: its until passed, or you ended it.
    enum State { case open, answered, withdrawn, expired, closed }
    /// When it is through, asking several (floo interaction.md §5.4): whoever answers
    /// first, each of them, or a vote — a tap, no message.
    var closes: Closes = .one
    enum Closes { case one, first, each, vote }
    /// Whom it asks, by name, you as "我"; empty: you alone.
    var askees: [String] = []
    /// Each one's answer so far: who (nil in an anonymous vote), the options picked, what
    /// they said.
    var replies: [Reply] = []
    struct Reply: Hashable {
        var who: String?
        var picked: [Int] = []
        var said: String?
    }
    /// Whether it asks you: in a group it may ask someone else.
    var asksYou = true
    /// Whether you may end it early: it is your agent's (a vote).
    var youEnd = false
    /// When it stops waiting, as it reads: "周五 20:00".
    var until: String?
    /// The thing in hand it is for.
    var errand: String?

    static let you = "我"

    /// What the system asks (floo interaction.md §5.2, §5.3): its line in the conversation
    /// ("管家 想在你的 Mac 上新建日程"); nil for an agent's own question.
    var line: String?
    /// Where it happens and for whom: "📅 日历 · MacBook Pro · 为管家".
    var place: String?
    /// The device it is on, by name: where a card this build can't draw is answered.
    var device: String?
    /// Where its secrets go, sealed: "MacBook Pro 上的浏览器"; said up top when it has any.
    var sealedTo: String?
    /// A model's question's secret: the service it is kept for, as its key, sealed to the
    /// cloud (floo interaction.md §6.1); said up top.
    var storesIn: String?
    /// Where it happens, as the code that does it found it — a sign-in's origin, not the
    /// agent's words: shown before all else.
    var origin: String?
    /// What it does, as the code that does it writes it.
    var about: [String] = []
    /// The agent's words on why, marked as its.
    var why: String?
    /// The call itself, behind 详情.
    var call: String?
    /// Where it stands once you've answered and the device is on it.
    var stage: Stage?
    enum Stage: Hashable {
        /// You're doing it, on that device: the clock stops.
        case engaged(String)
        /// The device is on it: "提交中…", or the line it wrote (`progress`).
        case working(String)
        /// It didn't go through, and why; it may be tried again.
        case failed(String)
    }
    /// Folded, what came of it: "已登录 x.com · @eirperuier · MacBook Pro".
    var done: String?

    /// Whether answering it is a message of yours: an agent's question is; what the system
    /// asks isn't, it goes to the device that asked.
    var answersAreMessages: Bool { line == nil }

    /// Whether it still waits on you: asked, and you haven't answered or voted.
    var waitsOnYou: Bool {
        guard state == .open, asksYou else { return false }
        if case .working? = stage { return false }
        if closes == .vote { return !replies.contains { $0.who == Self.you } }
        return items.contains { $0.answer == nil }
    }

    /// How many of those asked have answered (or voted).
    var answeredCount: Int { Set(replies.compactMap(\.who)).intersection(askees).count }
}

/// How a request gets answered, by you or by the script answering for you: what is given
/// once resolved against its controls (`FlooRequest.resolve`) is sent whole, one answer.
enum FlooAnswerPick {
    /// The card's 提交, or a tap that decides it: values by control id, secrets apart.
    case submit([String: FlooValue], secrets: [String: String] = [:])
    /// One option of its choice.
    case option(Int)
    /// Several of a multiple choice.
    case options([Int])
    /// In your own words: the choice's `own` is typed out over the composer, then sent.
    case own
    /// A 好 / 先不 choice.
    case confirm(Bool)
    /// A vote: the options picked; voting again replaces it.
    case vote([Int])
    /// A decision: the button pressed, or a standing choice from its long press.
    case decide(go: Bool, standing: String?)
    /// A step: taken on (`open`, not an answer), through, or skipped.
    case step(FlooStepPick)
    /// As it stands: guesses, defaults, the first option, the button that goes ahead.
    case guesses
    /// 不做了.
    case decline
    /// A toggle turned while it is open (§5.4), without answering it.
    case turn(String, Bool)
}

enum FlooStepPick { case open, done, skip }

/// An item you're answering in your own words, over the composer while you write.
struct FlooAnsweringItem: Equatable {
    let agent: FlooAgent
    let question: String
    /// The ask and item it is, when it's the backend's: what you send answers it (FlooLive).
    var ask: String? = nil
    var item = 0
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
    /// Agents' words in bubbles, as people's are; off, they're on the page as a document's.
    static let agentBubbles = true

    // MARK: Entries

    @MainActor
    final class Said {
        let id: Int
        /// Who said it, as they're called now (``rename(_:as:)``).
        fileprivate(set) var speaker: FlooSpeaker
        let text: String
        var receipt: FlooReceipt?
        /// What it replies to.
        let reply: FlooReply?
        /// Its number in the backend's conversation (FlooLive); nil for a scripted one.
        var number: Int64?
        var reactions: [FlooReaction] = []
        /// When it was said (FlooLive); nil for a scripted one, whose times are its own rows.
        let at: Date?
        /// The thread it begins, if it was replied to and not made a topic.
        var thread: FlooThreadLine?
        /// The topics its thread was made into (FlooLive), under it.
        var topics: [FlooPlace] = []
        /// Whom it went to, in a group, when it @'d no one.
        var sentTo: String?

        init(id: Int, speaker: FlooSpeaker, text: String, receipt: FlooReceipt?, reply: FlooReply? = nil, at: Date? = nil) {
            self.id = id
            self.speaker = speaker
            self.text = text
            self.receipt = receipt
            self.reply = reply
            self.at = at
        }
    }

    @MainActor
    final class Message {
        let id: Int
        /// Whose it is, as they're called now (``rename(_:as:)``).
        fileprivate(set) var agent: FlooAgent
        let time: String
        /// When it began (FlooLive); nil for a scripted one.
        let at: Date?
        var marks: [FlooMark]
        var process: FlooProcess?
        var text = ""
        var blocks: [MarkdownStreamBlock] = []
        var streaming = false {
            didSet { if streaming { streamed = true } }
        }
        /// Its words came in while shown: they come out with their reveal, which runs on to its
        /// end after the stream stops. Words that were there before (history) show whole.
        private(set) var streamed = false
        /// Its work shows under what it said (a quick answer, then the slow work it started),
        /// not above it.
        var processAfterText = false
        /// What it asked without stopping: cards on this message, after its words.
        var asks: [FlooAskCard] = []
        /// The topics its thread was made into (FlooLive), under it.
        var topics: [FlooPlace] = []
        /// The thread it begins, if it was replied to and not made a topic.
        var thread: FlooThreadLine?
        var reactions: [FlooReaction] = []
        var splitter = MarkdownBlockSplitter(customFence: { language, source in
            guard language.hasPrefix("floo.") else { return nil }
            // In the list from its first whole line: what the card will show, or what it points
            // at. A line still being written names nothing yet, and the row keeps what it first
            // showed.
            return FlooDemo.wholeLines(source).contains { !$0.isEmpty }
        })
        let coordinator = StreamingRevealCoordinator<UUID>()
        var generation = 0
        /// Its number in the backend's conversation (FlooLive); nil for a scripted one.
        var number: Int64?
        /// What fills its `floo.` fences, by their place among them from 0 (FlooLive): the
        /// cards' session keys, a mention, or the page pointed to, by its path and block.
        var fenceCards: [Int: [String]] = [:]
        var fenceMentions: [Int: Mention] = [:]
        var fencePages: [Int: (path: String, page: DocPage)] = [:]
        /// Fences whose cards couldn't be drawn: they show nothing.
        var fenceFailed: Set<Int> = []
        /// Its work as steps (FlooLive), its thinking by step, and the thinking opened.
        var work: [FlooStep] = []
        var thoughts: [String: FlooThought] = [:]
        var openThoughts: Set<String> = []
        /// Its bubble shows how the work went, not just where it is.
        var detailed = false
        /// Where its bubble shows the work is, and the wait before it goes from calls to
        /// thinking (`setSteps`).
        var status = FlooWorkStatus([])
        var settling: Task<Void, Never>?

        init(id: Int, agent: FlooAgent, time: String, at: Date?, marks: [FlooMark]) {
            self.id = id
            self.agent = agent
            self.time = time
            self.at = at
            self.marks = marks
        }
    }

    enum Entry {
        case time(String)
        case unread(String)
        case catchUp(String)
        case said(Said)
        case message(Message)

        /// When it was said, for a live one.
        var at: Date? {
            switch self {
            case .said(let said): said.at
            case .message(let message): message.at
            default: nil
            }
        }
    }

    /// The rows shown, kept as the changes made to them: a change re-makes the rows of the
    /// message (or line) it's in, nothing else, and the list applies just that.
    @ObservationIgnored let list = TiledList<FlooRow>()
    /// The last row: following the newest follows it.
    private(set) var lastRow: FlooRow?
    var scrollPosition = TiledScrollPosition(autoScrollsToBottomOnAppend: true, scrollsToBottomOnReplace: true)
    /// The list's rows where they are on screen: where you were, to come back to.
    @ObservationIgnored let reader = TiledViewReader<String>()
    private(set) var title = ""
    /// Who is doing what right now, in the order they started.
    private(set) var presence: [(agent: FlooAgent, doing: String)] = []
    private(set) var composer = ""
    /// The asks still open, oldest message first: what the line over the composer counts.
    private(set) var openAsks: [(message: Int, card: FlooAskCard)] = []
    private(set) var expanded: Set<String> = []
    /// What you said while an agent was mid-message: it waits over the composer, not yet
    /// seen, and takes its place once the agent has finished speaking.
    private(set) var queued: [Said] = []
    /// The first row of the message being written, while it's written: a long one stops the
    /// list following once its start reaches the top, so you read it from there.
    private(set) var speaking: String?
    /// The list keeps to the newest while you're there; scrolled up, it stays where you are.
    var following = true

    /// What's in the conversation, in order, each by its key (its message's or said's id).
    @ObservationIgnored private var entries: [(key: Int, entry: Entry)] = []
    /// The same, read by FlooControl.
    var shownEntries: [Entry] { entries.map(\.entry) }
    /// Where each entry is in `entries`, by its key.
    @ObservationIgnored private var order = TiledPositions<Int>()
    /// Each entry's rows in the list, by its key; none while it shows nothing.
    @ObservationIgnored private var shownRows: [Int: [FlooRow]] = [:]
    @ObservationIgnored private var messageByID: [Int: Message] = [:]
    /// People's messages by their backend's number (FlooLive).
    @ObservationIgnored private var saidByNumber: [Int64: Said] = [:]
    /// The message each ask is on, and the messages each card shows in.
    @ObservationIgnored private var askMessages: [String: Int] = [:]
    @ObservationIgnored private var cardMessages: [String: Set<Int>] = [:]
    /// The messages at work, by agent, oldest first (a scripted agent's presence).
    @ObservationIgnored private var working: [FlooAgent: [Int]] = [:]
    /// While a batch of changes is made (`batch`), the messages changed, shown once at its end.
    @ObservationIgnored private var batching = 0
    /// Remaking rows for a list filled at once at a batch's end: they're kept, not put in.
    @ObservationIgnored private var filling = false
    @ObservationIgnored private var changed: Set<Int> = []
    @ObservationIgnored private var changedAnimated = false
    /// The backend this conversation is with, when it's the live one (FlooLive).
    @ObservationIgnored var live: FlooLive?
    private(set) var isLive = false
    /// What you're typing, in the live conversation.
    var draft = ""
    /// The message what you're typing replies to.
    var replying: FlooReplyDraft?
    /// Asks the composer to take the keyboard: counts up each time.
    var composing = 0
    /// The bubble just gone to, lit up a moment (`jump(to:)`).
    var lit: String?
    /// The page open over the conversation.
    var openPage: FlooOpenPage?
    /// The thing a link opened, over the conversation.
    var openThing: FlooOpenThing?
    /// A link tapped that isn't on this device.
    var cannotOpen = false
    /// The model the backend's cards are drawn with, as the stage has it (FlooLive).
    var cardModel: FlooCardModel?
    /// The floo server's sign-in, while it's asked for (FlooLive).
    var signIn: FlooSignIn?
    /// The zone the person goes by, asked for once after signing in (FlooLive).
    var zoneChoice: FlooZoneChoice?
    /// The zone they go by, as the account has it; nil before they pick one.
    var usualZone: ZoneName?
    /// Who is signed in to the floo server.
    var signedIn: FlooOnline.Account?
    /// Each choice row's message and fence place, for a choice sent to the backend.
    @ObservationIgnored private var choiceFences: [String: (message: Int, fence: Int)] = [:]
    /// Per message, the block whose reveal the next block waits for (`rows(for:)`).
    @ObservationIgnored private var waits: [Int: (manager: StreamingRevealManager, listener: UUID)] = [:]
    /// Per message, the reveal of its first words, while its bubble waits for them to start.
    @ObservationIgnored private var starts: [Int: (manager: StreamingRevealManager, listener: UUID)] = [:]
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var nextTouch = 0
    /// Which option of a floo.choice fence you picked, by the fence's row: picking another
    /// later is allowed.
    private var chosen: [String: Int] = [:]
    @ObservationIgnored private var choiceSaid: [String: (option: FlooOption, said: Said)] = [:]
    @ObservationIgnored private var choiceWaits: [String: CheckedContinuation<(option: FlooOption, said: Said), Never>] = [:]
    @ObservationIgnored private var askWaits: [String: CheckedContinuation<Said, Never>] = [:]
    /// Approvals asked so far, for their cards' ids.
    @ObservationIgnored private var approvals = 0
    /// The list of open asks, open over the composer.
    var showsAsks = false
    /// Sending again what didn't go, by its row (FlooLive).
    @ObservationIgnored var retries: [String: () -> Void] = [:]

    /// What you're answering in your own words: over the composer while you write.
    private(set) var answering: FlooAnsweringItem?
    @ObservationIgnored private(set) var sessions: [String: CardSession] = [:]
    @ObservationIgnored private var versions: [String: Int] = [:]
    @ObservationIgnored private var jumpTarget: String?
    /// What of each bubble's rows is shown, by bubble.
    @ObservationIgnored private var bubbleStates: [String: FlooBubbleState] = [:]
    /// 1 is the pace the script is written at; less is faster.
    @ObservationIgnored var pace = 1.0

    // MARK: Script

    func reset(title: String) {
        keepPlace()
        // The script waiting on it is cancelled; what it gets back is never used.
        let cancelled = Said(id: -1, speaker: .me, text: "", receipt: nil)
        for wait in choiceWaits.values { wait.resume(returning: (FlooOption(label: ""), cancelled)) }
        for wait in askWaits.values { wait.resume(returning: cancelled) }
        choiceWaits = [:]
        askWaits = [:]
        choiceSaid = [:]
        chosen = [:]
        for wait in waits.values { wait.manager.removeRevealCompletionListener(wait.listener) }
        for start in starts.values { start.manager.removeListener(start.listener) }
        starts = [:]
        waits = [:]
        live = nil
        isLive = false
        signIn = nil
        signedIn = nil
        draft = ""
        drafted = [:]
        openPage = nil
        cardModel = nil
        choiceFences = [:]
        answering = nil
        // The conversations listed were the last account's.
        places = []
        place = nil
        origin = nil
        hasMorePlaces = false
        entries = []
        order = TiledPositions()
        shownRows = [:]
        messageByID = [:]
        saidByNumber = [:]
        askMessages = [:]
        cardMessages = [:]
        working = [:]
        changed = []
        changedAnimated = false
        errands = []
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
        bubbleStates = [:]
        following = true
        self.title = title
        list.reset([])
        lastRow = nil
    }

    func wait(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(Int(Double(milliseconds) * pace)))
    }

    func time(_ text: String) {
        add(.time(text), key: takeID())
    }

    func unread(_ text: String) {
        add(.unread(text), key: takeID())
    }

    func catchUp(_ text: String) {
        add(.catchUp(text), key: takeID())
    }

    /// Saying something yourself brings you back to the latest, wherever you'd scrolled to.
    @discardableResult
    func say(
        _ speaker: FlooSpeaker, _ text: String, receipt: FlooReceipt? = nil, reply: FlooReply? = nil, at: Date? = nil
    ) -> Said {
        let said = Said(
            id: takeID(),
            speaker: speaker,
            text: text,
            receipt: speaker == .me ? receipt ?? .delivered : nil,
            reply: reply,
            at: at
        )
        if speaker == .me { following = true }
        add(.said(said), key: said.id)
        return said
    }

    /// Types `text` into the composer as a person would, then sends it; `quote`, replying to
    /// those words of the butler's.
    @discardableResult
    func type(_ text: String, receipt: FlooReceipt = .delivered, quote: String? = nil) async throws -> Said {
        try await typeOut(text)
        let reply = quote.map { FlooReply(.butler, .part($0)) }
        return say(.me, text, receipt: receipt, reply: reply)
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
        add(.said(said), key: said.id)
    }

    private func typeOut(_ text: String) async throws {
        for character in text {
            composer.append(character)
            try await wait(70)
        }
        try await wait(300)
        composer = ""
    }

    /// The row a thing you said shows in.
    func row(of said: Said) -> String { "s\(said.id)" }

    /// Sends again what didn't go.
    func retry(_ row: String) {
        retries[row]?()
    }

    func mark(_ said: Said, _ receipt: FlooReceipt) {
        said.receipt = receipt
        show(said.id)
    }

    /// Someone shown goes by another name (FlooLive: names are kept by person, apart from
    /// what they said): what they said shows it.
    func rename(_ said: Said, as speaker: FlooSpeaker) {
        guard said.speaker != speaker else { return }
        said.speaker = speaker
        show(said.id)
    }

    /// An agent's message whose agent goes by another name (someone else's, named after
    /// them): it shows it.
    func rename(_ message: Message, as agent: FlooAgent) {
        guard message.agent != agent else { return }
        message.agent = agent
        show(message.id)
    }

    /// An agent's message, empty until it works or speaks; `on`: when, for a live one.
    func begin(_ agent: FlooAgent, at time: String, on date: Date? = nil, marks: [FlooMark] = []) -> Message {
        let message = Message(id: takeID(), agent: agent, time: time, at: date, marks: marks)
        messageByID[message.id] = message
        add(.message(message), key: message.id)
        return message
    }

    /// A message taken back (its run passed having said nothing): it goes.
    func remove(_ message: Message) {
        guard let index = order[message.id] else { return }
        take(at: index)
        messageByID[message.id] = nil
        for card in message.asks where askMessages[card.id] == message.id { askMessages[card.id] = nil }
        note(message, gone: true)
    }

    func step(_ message: Message, _ step: String, source: String? = nil) {
        if message.process == nil { message.process = FlooProcess(steps: []) }
        message.process?.steps.append(step)
        if let source { message.process?.read.append(source) }
        workChanged(message)
    }

    func finishWork(_ message: Message, _ summary: String) {
        message.process?.running = false
        message.process?.summary = summary
        workChanged(message)
    }

    /// The agent takes something on, by name: it's in hand until its work is finished, however
    /// much else comes up meanwhile.
    func takeOn(_ message: Message, _ title: String) {
        message.process = FlooProcess(steps: [], title: title)
        workChanged(message)
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
        workChanged(message)
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
        workChanged(message)
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
        /// Where it's gone to: where the agent took it on (scripted), or the message that asked
        /// for it (the backend's; nil while that isn't shown).
        let row: String?
    }

    /// Everything the agents have in hand here, oldest first.
    private(set) var errands: [Errand] = []
    /// The list of what's in hand, open over the composer.
    var showsErrands = false

    /// Over the composer, what an agent is doing is one line however much it has in hand: the
    /// one thing it's at, or how many.
    private func workChanged(_ message: Message) {
        show(message.id)
        refreshPresence(message.agent)
    }

    private func refreshPresence(_ agent: FlooAgent) {
        // The backend's agents are at work while their runs go (FlooLive).
        guard !isLive else { return }
        let at = working[agent] ?? []
        switch at.count {
        case 0: setPresence(agent, nil)
        case 1: setPresence(agent, "\(messageByID[at[0]]?.process?.doing ?? "在弄")…")
        default: setPresence(agent, "手上 \(at.count) 件事")
        }
        if errands.count < 2 { showsErrands = false }
    }

    /// What the backend's agents have in hand here, as it is now (FlooLive).
    func setErrands(_ errands: [Errand]) {
        guard self.errands != errands else { return }
        self.errands = errands
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
        guard message.text.isEmpty, let index = order[message.id], index != entries.count - 1 else { return }
        take(at: index)
        add(.message(message), key: message.id)
    }

    /// Draws the card a ```floo.draw asked for, in its place, as the drawing model streams it.
    /// The row changes once, to take the session; the card watches the session itself and
    /// shows when it's finished.
    func draw(_ card: String, chunk: Int = 24) async throws {
        guard let spec = FlooDemoCards.all[card] else { return }
        let session = CardSession(data: Self.value(spec.data))
        sessions[card] = session
        versions[card, default: 0] += 1
        showCard(card)
        let source = Array(spec.source)
        var index = 0
        while index < source.count {
            let end = min(source.count, index + chunk)
            session.append(String(source[index..<end]))
            index = end
            try await wait(40)
        }
        session.finish()
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

    // MARK: Live (FlooLive)

    /// The conversation is the backend's: you type and send, and what comes is its.
    func goLive(_ live: FlooLive) {
        self.live = live
        isLive = true
    }

    /// The backend's conversations you can go to, and the one shown (FlooLive).
    private(set) var places: [FlooPlace] = []
    private(set) var place: FlooPlace?
    /// Where a topic shown hangs: the conversation to go back to.
    private(set) var origin: FlooPlace?
    /// The backend's message whose thread is being made a topic, while it's named.
    var naming: Int64?
    /// The backend's messages in a thread, first ones too: their menus open it.
    private(set) var inThread: Set<Int64> = []
    /// Starting a group, connecting services, a group's members, the feed: their sheets.
    var startsGroup = false
    var showsServices = false
    var showsMembers = false
    var showsFeed = false

    func setInThread(_ numbers: Set<Int64>) {
        if inThread != numbers { inThread = numbers }
    }

    func setPlaces(_ places: [FlooPlace], current: FlooPlace?, origin: FlooPlace?) {
        self.places = places
        place = current
        self.origin = origin
    }

    /// One of the backend's conversations changed in the list (FlooLive): out of row `from`
    /// if it was shown there, into row `to` (counted once it's out) if it's shown now.
    func movePlace(from: Int?, to: Int?, _ place: FlooPlace) {
        if let from { places.remove(at: from) }
        if let to { places.insert(place, at: to) }
        if self.place?.id == place.id { self.place = place }
    }

    /// Whether the list goes on below the places shown: `morePlaces()` brings its next page.
    private(set) var hasMorePlaces = false

    func setHasMorePlaces(_ more: Bool) {
        hasMorePlaces = more
    }

    func morePlaces() {
        guard let live else { return }
        Task { await live.loadMorePlaces() }
    }

    /// Another of the backend's conversations in place of this one: what's shown goes, the
    /// backend and who's signed in stay.
    func enter(_ place: FlooPlace) {
        let live = live, signedIn = signedIn, cardModel = cardModel, places = places
        reset(title: place.title)
        self.live = live
        isLive = live != nil
        self.signedIn = signedIn
        self.cardModel = cardModel
        self.places = places
        self.place = place
    }

    func go(to place: FlooPlace) {
        guard place.id != self.place?.id else { return }
        live?.open(place)
    }

    /// The reactions on a message as they are now, under it.
    func setReactions(_ message: Message, _ reactions: [FlooReaction]) {
        guard message.reactions != reactions else { return }
        message.reactions = reactions
        show(message.id)
    }

    /// A person's message is the backend's message `number`.
    func setNumber(_ said: Said, _ number: Int64) {
        saidByNumber[number] = said
        guard said.number != number else { return }
        said.number = number
        show(said.id)
    }

    func setReactions(_ said: Said, _ reactions: [FlooReaction]) {
        guard said.reactions != reactions else { return }
        said.reactions = reactions
        show(said.id)
    }

    /// The thread a message begins (floo messaging.md §3.13.4): its replies under it; nil,
    /// none, or it was made a topic.
    func setThread(_ said: Said, _ thread: FlooThreadLine?) {
        guard said.thread != thread else { return }
        said.thread = thread
        show(said.id)
    }

    func setThread(_ message: Message, _ thread: FlooThreadLine?) {
        guard message.thread != thread else { return }
        message.thread = thread
        show(message.id)
    }

    /// Whom a person's message in a group went to, when they @'d no one.
    func setSentTo(_ said: Said, _ to: String?) {
        guard said.sentTo != to else { return }
        said.sentTo = to
        show(said.id)
    }

    /// The thread open over the conversation; nil, none.
    var openThread: FlooThreadShown?

    /// Opens the thread a message of the backend's is in.
    func showThread(of number: Int64) {
        live?.showThread(of: number)
    }

    /// Says something in the open thread: a reply to its newest message.
    func sayInThread(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let live, let thread = openThread, !text.isEmpty else { return }
        following = true
        live.send(text, replyTo: thread.lines.last?.id ?? thread.id)
    }

    /// The open thread made a topic, titled.
    func makeTopic(of thread: FlooThreadShown, title: String) {
        openThread = nil
        live?.openTopic(on: thread.id, title: title)
    }

    /// The backend's number of the message a row is of: a person's, or an agent's.
    func number(of row: FlooRow) -> Int64? {
        row.number ?? row.message.flatMap { messageByID[$0]?.number }
    }

    /// The reaction you gave a row's message, if you did.
    func myReaction(on row: FlooRow) -> String? {
        if let message = row.message.flatMap({ messageByID[$0] }) { return message.reactions.first(where: \.mine)?.emoji }
        guard case .reactions(let reactions, _) = row.kind else {
            return number(of: row).flatMap { number in saidByNumber[number]?.reactions.first(where: \.mine)?.emoji }
        }
        return reactions.first(where: \.mine)?.emoji
    }

    /// Gives your reaction to a message of the backend's; nil takes it back.
    func react(_ number: Int64, _ emoji: String?) {
        live?.react(number, emoji)
    }

    /// The thread on a message of the backend's made a topic (floo messaging.md §3.13.6),
    /// listed with the conversations.
    func openTopic(on number: Int64, title: String) {
        live?.openTopic(on: number, title: title)
    }

    /// The topics hung on a person's message, under it.
    func setTopics(_ said: Said, _ topics: [FlooPlace]) {
        guard said.topics != topics else { return }
        said.topics = topics
        show(said.id)
    }

    /// The topics hung on a message, under it.
    func setTopics(_ message: Message, _ topics: [FlooPlace]) {
        guard message.topics != topics else { return }
        message.topics = topics
        show(message.id)
    }

    /// The backend's next cards are drawn with this model and reasoning.
    func chooseCards(_ model: FlooCardModel) {
        live?.chooseCards(model)
    }

    /// Sends what's typed to the backend. What it gives back: the message's number once the
    /// backend took it (FlooControl waits on it); none answering an ask in your own words.
    @discardableResult
    func sendDraft() -> Task<Int64?, Never>? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let live, !text.isEmpty else { return nil }
        draft = ""
        following = true
        // Answering an ask's item in your own words: what you send is its answer.
        if let answering, let ask = answering.ask {
            self.answering = nil
            live.answer(ask: ask, item: answering.item, text: text)
            return nil
        }
        let sent = live.send(text, replyTo: replying?.number)
        replying = nil
        return sent
    }

    /// Starts a reply to a message of the backend's: it shows over the composer, which takes
    /// the keyboard.
    func reply(to number: Int64) {
        Task {
            guard let draft = await live?.replyDraft(number) else { return }
            replying = draft
            composing += 1
        }
    }

    /// The backend's asks on a message, as they are now (FlooLive).
    func setAsks(_ message: Message, _ asks: [FlooAskCard]) {
        guard message.asks != asks else { return }
        message.asks = asks
        show(message.id)
    }

    /// An agent's message as the backend has it now: all its words so far, still coming in or not.
    func setText(_ message: Message, _ text: String, streaming: Bool) {
        let wasStreaming = message.streaming
        guard text != message.text || streaming != wasStreaming else { return }
        if streaming, message.text.isEmpty { takePlace(message) }
        message.streaming = streaming
        message.text = text
        // Words that were all written before they came (the conversation as it was) show
        // whole: only words being written are revealed.
        commit(message, streaming: streaming, whole: !streaming && !wasStreaming)
        if wasStreaming, !streaming { message.coordinator.finishQuickly() }
    }

    /// An agent's work as steps, as the backend has it now, with each stretch of thinking's
    /// words so far (FlooLive).
    func setSteps(_ message: Message, _ steps: [FlooStep], thinking: [String: String]) {
        for step in steps where step.kind == .thinking {
            let thought = message.thoughts[step.id] ?? FlooThought()
            message.thoughts[step.id] = thought
            thought.update(thinking[step.id] ?? "", going: step.going)
        }
        guard message.work != steps else { return }
        message.work = steps
        let next = FlooWorkStatus(steps)
        // From its calls to thinking the bubble waits two seconds, showing the calls done:
        // thinking over by then (what came back read before the next calls) isn't shown.
        if case .calls = message.status.kind, next.kind == .thinking, !message.detailed,
           let calls = steps.lastIndex(where: { if case .calls = $0.kind { true } else { false } }) {
            message.status = FlooWorkStatus(Array(steps[...calls]))
            if message.settling == nil {
                message.settling = Task { [weak self, weak message] in
                    try? await Task.sleep(for: .seconds(2))  // try?: cancelled, checked below
                    guard !Task.isCancelled, let self, let message else { return }
                    message.settling = nil
                    self.show(message, FlooWorkStatus(message.work))
                }
            }
            workChanged(message)
            return
        }
        message.settling?.cancel()
        message.settling = nil
        show(message, next)
    }

    /// The bubble going from one thing it's at to another (thinking, the calls it's making)
    /// goes there with the layout spring, as it goes on to the words. Only a bubble in the list
    /// showing where the work is has somewhere to go from: one not in yet (a conversation being
    /// opened) or showing its words isn't animated, which would have the list drawn there and
    /// then, before the rest of what's coming in with it.
    private func show(_ message: Message, _ status: FlooWorkStatus) {
        let was = message.status
        message.status = status
        let shown = (shownRows[message.id] ?? []).contains {
            if case .work(.status) = $0.kind { true } else { false }
        }
        guard shown, !was.shows(as: status) else {
            workChanged(message)
            return
        }
        show(message.id, animated: true)
        refreshPresence(message.agent)
    }

    /// A tap on a bubble: how the work went, or back to where it is.
    func toggleDetail(_ id: Int) {
        guard let message = message(id), !message.work.isEmpty else { return }
        message.detailed.toggle()
        // The bubble opens in place, the rows after it moving with it.
        show(id, animated: true)
    }

    /// A tap on a stretch of thinking that's done: its words, or folded again.
    func toggleThought(_ id: Int, _ step: String) {
        guard let message = message(id) else { return }
        if message.openThoughts.remove(step) == nil { message.openThoughts.insert(step) }
        // The thought opens in its line, what's after it moving down with it.
        show(id, animated: true)
    }

    func thought(_ id: Int, _ step: String) -> FlooThought? {
        message(id)?.thoughts[step]
    }

    /// An agent's work as the backend has it now.
    func setWork(_ message: Message, _ process: FlooProcess?) {
        guard message.process != process else { return }
        message.process = process
        workChanged(message)
    }

    /// What each backend card's session was given of its source while it was drawn, and on
    /// which attempt (FlooLive).
    @ObservationIgnored private var drafted: [String: (attempt: Int, source: String)] = [:]

    /// A backend card as it's being drawn: its session takes the source as it comes, and
    /// starts over when the drawing does (a retry).
    /// `data`: read only when the card is new here.
    func draftCard(_ key: String, source: String, attempt: Int, data: @autoclosure () -> CardValue) {
        let session = sessions[key] ?? {
            let session = CardSession(data: data())
            sessions[key] = session
            versions[key, default: 0] += 1
            return session
        }()
        guard !session.isFinal else { return }
        var given = drafted[key] ?? (attempt, "")
        if given.attempt != attempt || !source.hasPrefix(given.source) {
            session.reset()
            given = (attempt, "")
        }
        guard source.count > given.source.count else { return }
        session.append(source.dropFirst(given.source.count))
        drafted[key] = (attempt, source)
    }

    /// A card the backend sent, whole: compiled here from its source, shown in its fence's place.
    /// One drawn here as it was written takes what's left of it and is finished.
    /// `data`: read only when the card is new here.
    /// One that keeps updating (floo docs/cards.md §5.2) has its `live` version, and `values`, the
    /// use's values as the card runtime writes them; its message rewritten a version on, the
    /// version is applied to the session showing it, so the card keeps its views, their state
    /// and its transitions; an older one, or the same, changes nothing.
    func setCard(
        _ key: String, source: String?, live: AnswerCard.Live? = nil, values: Wire.JSONValue? = nil,
        data: @autoclosure () -> CardValue
    ) {
        if let live, let session = sessions[key], session.use == live.id {
            session.apply(live, values: values)
            return
        }
        if let session = sessions[key], let given = drafted.removeValue(forKey: key) {
            if let source, source.hasPrefix(given.source) {
                session.append(source.dropFirst(given.source.count))
            } else {
                session.reset()
                if let source { session.append(source) }
            }
            session.finish()
            if let live { session.apply(live, values: values) }
            return
        }
        // Another use in its place is a new card.
        guard sessions[key] == nil || live != nil else { return }
        let session = live == nil ? CardSession(data: data()) : CardSession()
        if let source { session.append(source) }
        session.finish()
        if let live { session.apply(live, values: values) }
        sessions[key] = session
        versions[key, default: 0] += 1
        showCard(key)
    }

    /// Opens a floo link (`floo://<service>/…`) on this device: the service here that has
    /// the thing finds it; none does, it can't be opened — never looked for elsewhere.
    func open(link: String) {
        Task {
            #if targetEnvironment(macCatalyst)
            if let thing = await FlooHelper.thing(at: link) {
                openThing = FlooOpenThing(id: link, title: thing.title, text: thing.text)
                return
            }
            #endif
            cannotOpen = true
        }
    }

    /// Opens a page the conversation shows, over it, read as it is now.
    func open(page path: String) {
        Task {
            guard let doc = await live?.page(path) else { return }
            openPage = FlooOpenPage(id: path, doc: doc)
        }
    }

    /// Changes `body` makes are shown once it's done, each message changed once (FlooLive:
    /// all an update brings).
    func batch(_ body: () -> Void) {
        batching += 1
        body()
        batching -= 1
        guard batching == 0, !changed.isEmpty else { return }
        let keys = changed.compactMap { key in order[key].map { (key, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        let animated = changedAnimated
        changed = []
        changedAnimated = false
        if list.items.isEmpty {
            // A conversation entered: its rows go in as one whole list, which opens at its end,
            // not inserted one by one into a list at its top that then scrolls down past them all.
            filling = true
            for key in keys { remake(key) }
            filling = false
            list.reset(entries.flatMap { shownRows[$0.key] ?? [] })
            showLast()
            openWhereLeft()
        } else if animated {
            withAnimation(FlooDesignTokens.Motion.layout) { for key in keys { remake(key) } }
        } else {
            for key in keys { remake(key) }
        }
    }

    /// A message changed in ways only its rows show (its fences' cards, mentions, pages).
    func touch(_ message: Message) {
        show(message.id)
    }

    func setPresence(_ agent: FlooAgent, _ doing: String?) {
        // As it was: the line keeps its order.
        guard presence.first(where: { $0.agent == agent })?.doing != doing else { return }
        presence.removeAll { $0.agent == agent }
        if let doing { presence.append((agent, doing)) }
    }

    /// Asks without stopping: the card rides on the message that asked, the script goes on.
    /// Answers come in as your messages, each quoting its item.
    func ask(_ message: Message, _ card: FlooAskCard) {
        message.asks.append(card)
        show(message.id)
    }

    /// Waits for one item of an ask; the script answers for you after `autoAfter`
    /// milliseconds if you don't. Several asks and items can be waited on at once.
    func awaitAnswer(_ id: String, item: Int, autoAfter: Int, auto: FlooAnswerPick) async throws -> Said {
        if let message = askMessage(id), let card = message.asks.first(where: { $0.id == id }),
           card.items.indices.contains(item), let answered = card.items[item].answer
        {
            return Said(id: -1, speaker: .me, text: answered, receipt: .read, reply: FlooReply(card.agent, .answer(card.items[item].title)))
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

    /// Your answer to a request: resolved against its controls, sent whole — a message of
    /// yours quoting it for an agent's question, to the device for the system's; the card
    /// closes when every request on it is answered.
    func answerAsk(_ id: String, item index: Int, _ pick: FlooAnswerPick) {
        if case .vote(let picked) = pick {
            vote(id, picked)
            return
        }
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }),
              message.asks[ci].state == .open,
              message.asks[ci].items.indices.contains(index), message.asks[ci].items[index].answer == nil
        else { return }
        let card = message.asks[ci]
        let request = card.items[index]
        if let live {
            answerLive(live, card, request, at: index, pick)
            return
        }
        switch pick {
        case .step(.open):
            stage(id, .engaged("你在做"))
        case .turn:
            // Kept on the card; the script reads it when it ends the request.
            return
        case .decline:
            finishAnswer(id, item: index, "不做了")
        case .own:
            guard let choice = request.current(group: request.group(nil)).first(where: {
                if case .choice(_, _, _?, false) = $0.kind { true } else { false }
            }), case .choice(_, _, let own?, _) = choice.kind else { return }
            answering = FlooAnsweringItem(agent: card.agent, question: request.question)
            Task {
                try? await typeOut(own)  // try?: cut short, it's sent as far as it got
                // Reset meanwhile: the script waiting on it is gone.
                guard answering == FlooAnsweringItem(agent: card.agent, question: request.question) else { return }
                answering = nil
                finishAnswer(id, item: index, own)
            }
        default:
            guard let (values, secrets) = request.resolve(pick) else { return }
            let said = request.said(values, secrets, sealedTo: card.sealedTo)
            guard !said.isEmpty || !secrets.isEmpty else { return }
            finishAnswer(id, item: index, said)
        }
    }

    /// An answer to the backend's request: an agent's question as your message answering it
    /// (in your own words, typed in the composer first); the system's through the one signed
    /// answer (FlooLive.respond). The card changes as the backend has it once it comes back.
    private func answerLive(_ live: FlooLive, _ card: FlooAskCard, _ request: FlooRequest, at index: Int, _ pick: FlooAnswerPick) {
        switch pick {
        case .vote: return
        case .own:
            answering = FlooAnsweringItem(agent: card.agent, question: request.question, ask: card.id, item: index)
            return
        case .step(.open):
            live.take(ask: card.id)
        case .turn(let control, let on):
            live.turn(ask: card.id, control, on)
            return
        case .decline:
            live.decline(ask: card.id)
        default:
            guard let (values, secrets) = request.resolve(pick) else { return }
            if card.answersAreMessages {
                // A secret is never words: given, it says so (floo interaction.md §6.1).
                let text = request.said(values, [:], sealedTo: nil, separator: "\n")
                guard !text.isEmpty || !secrets.isEmpty else { return }
                live.answer(
                    ask: card.id, item: index, text: [text, secrets.isEmpty ? "" : "已提供"].filter { !$0.isEmpty }.joined(separator: "\n"),
                    values: values, secrets: secrets)
            } else {
                live.respond(ask: card.id, values: values, secrets: secrets)
            }
        }
        following = true
    }

    private func finishAnswer(_ id: String, item index: Int, _ value: String) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }) else { return }
        message.asks[ci].items[index].answer = value
        // What the system asked: your answer goes to the device, not into the chat; the
        // script says where it stands next.
        guard message.asks[ci].answersAreMessages else {
            message.asks[ci].stage = nil
            show(message.id)
            askWaits.removeValue(forKey: "\(id)#\(index)")?
                .resume(returning: Said(id: -1, speaker: .me, text: value, receipt: nil))
            return
        }
        if message.asks[ci].closes == .one {
            if message.asks[ci].items.allSatisfy({ $0.answer != nil }) { message.asks[ci].state = .answered }
        } else {
            // Asking several, yours is one of theirs.
            tally(id, who: FlooAskCard.you, said: value)
        }
        // Folded where it was asked, as it now stands.
        show(message.id)
        let said = say(.me, value, receipt: .read, reply: FlooReply(message.agent, .answer(message.asks[ci].items[index].title), row: "m\(message.id)#sig", bubble: Self.leadRun(message.id)))
        askWaits.removeValue(forKey: "\(id)#\(index)")?.resume(returning: said)
    }

    /// Your vote on a question asking several (floo interaction.md §5.5): a tap, no
    /// message; voting again replaces it. Live, the backend's tally comes back.
    func vote(_ id: String, _ picked: [Int]) {
        guard let message = askMessage(id), let card = message.asks.first(where: { $0.id == id }),
              card.state == .open, card.closes == .vote, card.asksYou, !picked.isEmpty
        else { return }
        if let live {
            live.vote(ask: id, picked: picked)
            return
        }
        tally(id, who: FlooAskCard.you, picked: picked)
    }

    /// One's answer or vote on a question asking several, as the script has them: theirs
    /// replaces any before; once all those asked have, it is answered — at once when the
    /// first answer is enough.
    func tally(_ id: String, who: String?, picked: [Int] = [], said: String? = nil) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }),
              message.asks[ci].state == .open
        else { return }
        if let who { message.asks[ci].replies.removeAll { $0.who == who } }
        message.asks[ci].replies.append(FlooAskCard.Reply(who: who, picked: picked, said: said))
        let card = message.asks[ci]
        if card.closes == .one {
            // Asked of one other: theirs is the answer.
            message.asks[ci].items[0].answer = said ?? ""
            message.asks[ci].state = .answered
        } else if card.closes == .first || card.answeredCount >= card.askees.count {
            message.asks[ci].state = .answered
        }
        show(message.id)
    }

    /// Whether question `id` still waits on you: the script answers for you if so.
    func waitsOnYou(_ id: String) -> Bool {
        askMessage(id)?.asks.first { $0.id == id }?.waitsOnYou ?? false
    }

    /// Ends a question asking several before all have answered: only yours (§5.5).
    func endAsk(_ id: String) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }),
              message.asks[ci].state == .open, message.asks[ci].youEnd
        else { return }
        if let live {
            live.closeAsk(id)
            return
        }
        message.asks[ci].state = .closed
        show(message.id)
    }

    /// The ask is taken back: the card stays, struck through, and nothing waits on it.
    func withdraw(_ id: String) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }) else { return }
        message.asks[ci].state = .withdrawn
        for index in message.asks[ci].items.indices {
            askWaits.removeValue(forKey: "\(id)#\(index)")?
                .resume(returning: Said(id: -1, speaker: .me, text: "", receipt: nil))
        }
        show(message.id)
    }

    private func askMessage(_ id: String) -> Message? {
        askMessages[id].flatMap { messageByID[$0] }
    }

    /// Tapping a floo.choice option sends its `send` as your message and marks it 选了;
    /// picking another later is allowed.
    func choose(_ row: String, _ index: Int, _ option: FlooOption) {
        if let live, let place = choiceFences[row], let number = message(place.message)?.number {
            // The backend has your message after: it comes back with the conversation.
            chosen[row] = index
            show(place.message)
            live.choose(message: number, fence: place.fence, item: index, option: option)
            return
        }
        chosen[row] = index
        if let place = choiceFences[row] { show(place.message) }
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

    /// Something an agent wants to do on your device, asked as a card in the conversation
    /// (floo interaction.md §5.2): its line says who wants what where, the card what the code
    /// will do; you decide on it — a long press of the button allows it from now on — or the
    /// script does after `autoAfter`. Its work waits meanwhile; decided, the card folds.
    func approve(
        _ approval: FlooApproval,
        for message: Message,
        autoAfter: Int,
        deciding: FlooDecision
    ) async throws -> FlooDecision {
        message.process?.waitsForYou = true
        workChanged(message)
        approvals += 1
        let id = "approval-\(approvals)"
        var card = FlooAskCard(
            id: id, agent: approval.agent,
            items: [
                FlooRequest(
                    title: approval.action, question: approval.action,
                    controls: [
                        FlooControlModel(
                            id: "0",
                            kind: .decision(
                                [
                                    FlooDecisionOption(key: "once", label: approval.confirm, danger: approval.dangerous),
                                    FlooDecisionOption(key: "no", label: "不用了"),
                                ] + (approval.dangerous ? [] : approval.standing).map {
                                    FlooDecisionOption(key: $0, label: $0, standing: true)
                                }))
                    ])
            ],
            state: .open)
        card.line = "\(approval.agent.name) 想在\(approval.place)上\(approval.action)"
        card.place = "\(approval.device) · 为\(approval.agent.name)"
        card.about = approval.details
        card.call = approval.call
        ask(message, card)
        let auto: FlooAnswerPick =
            switch deciding {
            case .once: .decide(go: true, standing: nil)
            case .always(let choice): .decide(go: true, standing: choice)
            case .denied: .decide(go: false, standing: nil)
            }
        let said = try await awaitAnswer(id, item: 0, autoAfter: autoAfter, auto: auto)
        message.process?.waitsForYou = false
        workChanged(message)
        let decided: FlooDecision =
            said.text == "不用了" || said.text.isEmpty ? .denied : approval.standing.contains(said.text) ? .always(said.text) : .once
        switch decided {
        case .denied: complete(id, "没允许", as: .withdrawn)
        case .once: complete(id, "\(approval.confirm)了 · 仅这一次")
        case .always(let choice): complete(id, "\(approval.confirm)了 · \(choice)")
        }
        return decided
    }

    /// The device is on a request you answered: where it stands, on its card.
    func stage(_ id: String, _ stage: FlooAskCard.Stage?) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }) else { return }
        message.asks[ci].stage = stage
        show(message.id)
    }

    /// It needs one thing more — a code the site sent (floo interaction.md §4.5): the same
    /// request grows by `controls`, what was sent before folded above them, and is answered
    /// again on the same card.
    func grow(_ id: String, _ controls: [FlooControlModel]) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }),
              let last = message.asks[ci].items.indices.last
        else { return }
        var request = message.asks[ci].items[last]
        if let sent = request.answer { request.earlier.append(sent) }
        request.from = request.controls.count
        request.controls += controls
        request.answer = nil
        message.asks[ci].items[last] = request
        message.asks[ci].stage = nil
        show(message.id)
    }

    /// Through: the card folds to `done`.
    func complete(_ id: String, _ done: String, as state: FlooAskCard.State = .answered) {
        guard let message = askMessage(id), let ci = message.asks.firstIndex(where: { $0.id == id }) else { return }
        message.asks[ci].done = done
        message.asks[ci].stage = nil
        message.asks[ci].state = state
        show(message.id)
    }

    /// Where each of the backend's conversations was left, by its id: [the number of the
    /// message at the top, which of its rows, how far below the top that row's top was].
    private static let leftKey = "flooConversationsLeft"

    /// Keeps where you are in the backend's conversation, to open it there again, as Telegram
    /// does (gone to another, the page closed, the app put away): the message at the top by its
    /// number, which outlives the rows' ids. At the newest, nothing is kept: it opens at its end.
    func keepPlace() {
        guard isLive, let place, !list.items.isEmpty else { return }
        var left = UserDefaults.standard.dictionary(forKey: Self.leftKey) as? [String: [Double]] ?? [:]
        left[place.id] = following ? nil : whereRead()
        UserDefaults.standard.set(left, forKey: Self.leftKey)
    }

    /// The first row at the top that's of a message of the backend's (a day's line isn't).
    private func whereRead() -> [Double]? {
        guard let top = reader.topVisibleItem(), let first = list.items.firstIndex(where: { $0.id == top.id }),
              let at = list.items[first...].firstIndex(where: { number(of: $0) != nil }),
              let number = number(of: list.items[at])
        else { return nil }
        var offset = top.offset
        if at != first, let from = reader.frame(forItem: top.id), let to = reader.frame(forItem: list.items[at].id) {
            offset += to.minY - from.minY
        }
        let row = list.items[..<at].reversed().prefix { self.number(of: $0) == number }.count
        return [Double(number), Double(row), offset]
    }

    /// A conversation filled anew opens where it was left, if that's among what's shown;
    /// otherwise at its end.
    private func openWhereLeft() {
        guard isLive, let place, let left = (UserDefaults.standard.dictionary(forKey: Self.leftKey) as? [String: [Double]])?[place.id],
              left.count == 3
        else { return }
        let rows = list.items.filter { number(of: $0) == Int64(left[0]) }
        guard let row = rows.isEmpty ? nil : rows[min(Int(left[1]), rows.count - 1)] else { return }
        following = false
        scrollPosition.scrollTo(id: row.id, anchor: .top, offset: left[2], animated: false)
    }

    /// Opens the conversation where it was last read rather than at its end.
    func openAtUnread() {
        guard let id = list.items.last(where: { if case .unread = $0.kind { true } else { false } })?.id else { return }
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
        if let row = errand.row { jump(toRow: row) }
    }

    /// To a row, wherever in the conversation it is: the message a reply answers.
    func jump(toRow row: String) {
        following = false
        scrollPosition.scrollTo(id: row, anchor: .top, animated: true)
    }

    /// To the message a reply replies to, its bubble lit up a moment.
    func jump(to reply: FlooReply) {
        guard let row = reply.row else { return }
        jump(toRow: row)
        lit = reply.bubble
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))  // try?: a cancelled wait only ends it sooner
            if self?.lit == reply.bubble { self?.lit = nil }
        }
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
        if let message = Self.message(ofRow: row) { show(message) }
    }

    // MARK: Rows

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    private func commit(_ message: Message, streaming: Bool, whole: Bool = false) {
        let text = Self.imagesApart(streaming ? Self.settled(message.text) : message.text)
        message.blocks = message.splitter.split(text, isStreaming: streaming)
        message.generation += 1
        message.coordinator.syncBlocks(
            message.blocks.map { ($0.id, $0.revealPlainTextCount) },
            generation: message.generation
        )
        if whole { message.coordinator.revealAll() }
        show(message.id)
    }

    /// The backend's conversation has messages older than those shown (FlooLive).
    private(set) var hasOlder = false
    @ObservationIgnored private var holding = false

    func setHasOlder(_ older: Bool) {
        if hasOlder != older { hasOlder = older }
    }

    /// What `body` adds (`begin`, `say`) goes before everything shown: older messages,
    /// loaded on scrolling up. Their rows go in at the top together.
    func prepending(_ body: () -> Void) {
        let shown = entries
        entries = []
        holding = true
        body()
        holding = false
        let page = entries
        entries = page + shown
        order.moved(0..<page.count, by: page.count, count: entries.count) { entries[$0].key }
        var rows: [FlooRow] = []
        var last: FlooAgent?
        for (index, (key, entry)) in page.enumerated() {
            let day = opensDay(at: index)
            var continuing = false
            if day == nil, case .message(let message) = entry { continuing = last == message.agent }
            var made = self.rows(for: entry, key: key, continuing: continuing)
            if let day, !made.isEmpty { made.insert(FlooRow(id: "day:\(key)", message: nil, kind: .day(day)), at: 0) }
            if case .message(let message) = entry { note(message) }
            changed.remove(key)
            guard !made.isEmpty else { continue }
            shownRows[key] = made
            if case .message(let message) = entry { last = message.agent } else { last = nil }
            rows += made
        }
        list.prepend(rows)
        // The first message shown before may go under the page's last signature now.
        if let next = shownEntry(from: page.count, by: 1) { show(entries[next].key) }
        showLast()
    }

    /// Scrolled to the top of the conversation: the page before it.
    func loadOlder() async {
        await live?.loadOlder()
    }

    /// Where `placing` puts what's added: the index the next entry takes.
    @ObservationIgnored private var placeAt: Int?

    /// What `body` adds (`begin`, `say`) goes before the entry `key`, in the order added; at
    /// the end when there's none (FlooLive: a message shown later than those after it, by its
    /// number, not at the bottom).
    func placing<T>(before key: Int?, _ body: () -> T) -> T {
        guard !holding, let key, let index = order[key] else { return body() }
        placeAt = index
        defer { placeAt = nil }
        return body()
    }

    /// An entry at the end of the conversation, or where `placing` puts it.
    private func add(_ entry: Entry, key: Int) {
        if let at = placeAt {
            entries.insert((key, entry), at: at)
            order.moved(at..<(at + 1), by: 1, count: entries.count) { entries[$0].key }
            placeAt = at + 1
            show(key)
            // The one after it may go under its signature now, or open the day no more.
            if let next = shownEntry(from: at + 1, by: 1) { show(entries[next].key) }
            return
        }
        entries.append((key, entry))
        order.moved((entries.count - 1)..<entries.count, by: 1, count: entries.count) { entries[$0].key }
        show(key)
    }

    /// The entry at `index` leaves the conversation, its rows with it.
    private func take(at index: Int) {
        let key = entries[index].key
        let rows = shownRows.removeValue(forKey: key) ?? []
        changed.remove(key)
        entries.remove(at: index)
        order.forget(key)
        order.moved(index..<index, by: -1, count: entries.count) { entries[$0].key }
        guard !rows.isEmpty else { return }
        list.remove(rows.map(\.id))
        // The message after it may need its signature now, or not.
        if let next = shownEntry(from: index, by: 1) { show(entries[next].key) }
        showLast()
    }

    /// An entry's rows made again, and put in the list in place of what it showed: the work
    /// follows the entry, not the conversation. In a batch, once at its end. `animated`: with
    /// the layout spring.
    private func show(_ key: Int, animated: Bool = false) {
        guard !holding, order[key] != nil else { return }
        if batching > 0 {
            changed.insert(key)
            if animated { changedAnimated = true }
        } else if animated {
            withAnimation(FlooDesignTokens.Motion.layout) { remake(key) }
        } else {
            remake(key)
        }
    }

    private func remake(_ key: Int) {
        guard let index = order[key] else { return }
        let entry = entries[index].entry
        let before = shownEntry(from: index - 1, by: -1)
        let day = opensDay(at: index)
        var continuing = false
        if day == nil, case .message(let message) = entry, let before, case .message(let previous) = entries[before].entry {
            continuing = previous.agent == message.agent
        }
        var made = rows(for: entry, key: key, continuing: continuing)
        if let day, !made.isEmpty { made.insert(FlooRow(id: "day:\(key)", message: nil, kind: .day(day)), at: 0) }
        if case .message(let message) = entry { note(message) }
        let old = shownRows[key] ?? []
        guard made != old else { return }
        shownRows[key] = made.isEmpty ? nil : made
        if !filling {
            list.replace(old, with: made, after: before.flatMap { shownRows[entries[$0].key]?.last?.id })
        }
        // Coming or going, it may put the message after it under its signature or out of it.
        if old.isEmpty != made.isEmpty, let next = shownEntry(from: index + 1, by: 1),
           case .message = entries[next].entry {
            show(entries[next].key)
        }
        showLast()
    }

    /// The messages showing a card, again: what's drawn of it changed.
    private func showCard(_ card: String) {
        for message in cardMessages[card] ?? [] { show(message) }
    }

    /// The day the entry at `index` opens: a live one said on another day (of this device's
    /// calendar) than the one shown before it, or the first shown. Its messages go under it.
    private func opensDay(at index: Int) -> Date? {
        guard let at = entries[index].entry.at else { return nil }
        let before = entries[..<index].last { $0.entry.at != nil && shownRows[$0.key] != nil }?.entry.at
        // time: shown on this device, by its calendar
        return before.map { Calendar.current.isDate($0, inSameDayAs: at) } == true ? nil : at
    }

    /// The nearest entry from `index` on (`step` 1) or back (-1) that shows something.
    private func shownEntry(from index: Int, by step: Int) -> Int? {
        var at = index
        while entries.indices.contains(at) {
            if shownRows[entries[at].key] != nil { return at }
            at += step
        }
        return nil
    }

    private func showLast() {
        let last = list.items.last
        if lastRow != last { lastRow = last }
    }

    /// What depends on a message besides its rows, as it is now: what it has in hand, its open
    /// asks, the cards it shows, its work for its agent's presence. Gone: none of it.
    private func note(_ message: Message, gone: Bool = false) {
        let id = message.id
        var errand: Errand?
        if !gone, let process = message.process, process.running, let title = process.title {
            errand = Errand(id: id, agent: message.agent, title: title, doing: process.doing ?? "在弄", since: message.time, row: "m\(id)#sig")
        }
        if errands.first(where: { $0.id == id }) != errand {
            var all = errands.filter { $0.id != id }
            if let errand { all.insert(errand, at: place(id, among: all.map(\.id))) }
            errands = all
        }
        let open = gone ? [] : message.asks.filter(\.waitsOnYou)
        if openAsks.filter({ $0.message == id }).map(\.card) != open {
            var all = openAsks.filter { $0.message != id }
            all.insert(contentsOf: open.map { (message: id, card: $0) }, at: place(id, among: all.map(\.message)))
            openAsks = all
            if openAsks.count < 2 { showsAsks = false }
        }
        if !gone { for card in message.asks { askMessages[card.id] = id } }
        let atWork = !gone && message.process.map { $0.running && !$0.waitsForYou } == true
        var ids = working[message.agent] ?? []
        if atWork != ids.contains(id) {
            if atWork { ids.insert(id, at: place(id, among: ids)) } else { ids.removeAll { $0 == id } }
            working[message.agent] = ids
        }
    }

    /// Where an entry goes among others in the conversation's order.
    private func place(_ key: Int, among keys: [Int]) -> Int {
        let at = order[key] ?? .max
        return keys.firstIndex { (order[$0] ?? .max) > at } ?? keys.count
    }

    /// The message a row is of: `m<id>#…`.
    private static func message(ofRow row: String) -> Int? {
        guard row.hasPrefix("m"), let end = row.firstIndex(of: "#") else { return nil }
        return Int(row[row.index(after: row.startIndex)..<end])
    }

    /// `continuing`: the message follows another of its agent's, whose signature it's under.
    private func rows(for entry: Entry, key: Int, continuing: Bool = false) -> [FlooRow] {
        switch entry {
        case .time(let text):
            return [FlooRow(id: "time:\(key)", message: nil, kind: .time(text))]
        case .unread(let text):
            return [FlooRow(id: "unread:\(key)", message: nil, kind: .unread(text))]
        case .catchUp(let text):
            return [FlooRow(id: "catchUp:\(key)", message: nil, kind: .catchUp(text))]
        case .said(let said):
            var rows = [FlooRow(id: row(of: said), message: nil, kind: .said(said.speaker, said.text, said.receipt, reply: said.reply))]
            rows[0].number = said.number
            if let to = said.sentTo {
                var sent = FlooRow(id: "\(row(of: said))#to", message: nil, kind: .sentTo(to, trailing: said.speaker == .me))
                sent.number = said.number
                rows.append(sent)
            }
            if !said.reactions.isEmpty {
                var reactions = FlooRow(
                    id: "\(row(of: said))#reactions", message: nil,
                    kind: .reactions(said.reactions, trailing: said.speaker == .me)
                )
                reactions.number = said.number
                rows.append(reactions)
            }
            if !said.topics.isEmpty {
                var topics = FlooRow(id: "\(row(of: said))#topics", message: nil, kind: .topics(said.topics))
                topics.number = said.number
                rows.append(topics)
            } else if let thread = said.thread {
                var replies = FlooRow(id: "\(row(of: said))#replies", message: nil, kind: .replies(thread, trailing: said.speaker == .me))
                replies.number = said.number
                rows.append(replies)
            }
            return rows
        case .message(let message):
            // A message is there once it has something: its first step of work or words, what
            // it asks, or (the backend's) once it's being written.
            guard message.process != nil || !message.blocks.isEmpty || !message.work.isEmpty || !message.asks.isEmpty
                || (message.number != nil && message.streaming)
            else { return [] }
            var rows: [FlooRow] = []
            // A mark (a push, what it picks up) is the message's own: it keeps its signature.
            if !continuing || !message.marks.isEmpty {
                rows.append(FlooRow(
                    id: "m\(message.id)#sig",
                    message: message.id,
                    kind: .signature(message.agent, message.time, message.marks)
                ))
            }
            var work: FlooRow?
            if let process = message.process {
                let id = "m\(message.id)#work"
                let open = Set(process.tasks.map(\.id).filter { expanded.contains("\(id)/\($0)") })
                work = FlooRow(id: id, message: message.id, kind: .process(process, expanded: expanded.contains(id), open: open))
            }
            if let work, !message.processAfterText { rows.append(work) }
            // Its work in its bubble (FlooAgentWork): how it went when you asked, else where it
            // is until its words start coming out.
            // One row throughout: opening it is a row put in, the words after it staying as they are.
            let lead = FlooBubble(run: Self.leadRun(message.id), top: true, last: true)
            var shown: FlooWorkShown?
            if message.detailed, !message.work.isEmpty {
                let lines = FlooWorkLine.lines(
                    of: message.work, message: message.id, thoughts: message.thoughts, open: message.openThoughts
                )
                shown = .detail(lines, divided: !message.blocks.isEmpty)
            } else if message.number != nil, message.streaming || !message.work.isEmpty,
                      message.blocks.isEmpty || !wordsStarted(message) {
                shown = .status(message.status)
            }
            if let shown {
                // Where its work is shows in the row its first words come out in: they take
                // its place, the bubble going from the one to the other.
                let id = if case .status = shown { Self.firstRow(message.id) } else { "m\(message.id)#steps" }
                var row = FlooRow(id: id, message: message.id, kind: .work(shown))
                row.bubble = lead
                rows.append(row)
            }
            // A block comes in once the blocks before it are revealed, as the reveal goes on
            // block by block: the next block's row, its marker or a card, doesn't stand there
            // ahead of the words still coming out.
            var waiting: StreamingRevealManager?
            // Its words wait out of the list while its bubble shows where its work is: in, they
            // would stand below it, empty, until they start coming out.
            if case .status = shown, let first = message.blocks.first {
                waiting = message.coordinator.ensureManager(for: first.id)
            }
            // Its `floo.` fences' places among them, from 0: where the backend's cards go.
            var fence = 0
            // A fence with nothing to show yet still ends the bubble before it: the words after
            // it start their own as they come, not once its card is in.
            var cut = false
            var cuts: Set<String> = []
            // The cards in a row with nothing between, and where their row is.
            var run: (index: Int, id: String, cards: [FlooCard])?
            // The same for mentions.
            var mentioned: (index: Int, id: String, mentions: [Mention])?
            for block in message.blocks {
                if waiting != nil { break }
                if let manager = message.coordinator.manager(for: block.id), !manager.isRevealed { waiting = manager }
                let id = block.id == message.blocks.first?.id && Self.inBubble(block)
                    ? Self.firstRow(message.id) : "m\(message.id)#\(block.id)"
                if case .customFence(let info) = block.kind {
                    // Its images, out of the words: the demo's own fence, not one of the backend's.
                    if info == "floo.images" {
                        rows.append(FlooRow(id: id, message: message.id, kind: .images(Self.images(block.source))))
                        continue
                    }
                    // The fence's name; a size may follow it (`floo.draw medium`).
                    var language = String(info.split(separator: " ").first ?? "")
                    // Places are counted among the backend's answer fences only (a floo.re in
                    // the words being written isn't one).
                    defer { if Self.answerFences.contains(language) { fence += 1 } }
                    if language == "floo.page" {
                        // The backend's page, as the answer has its block: a new row.
                        if message.number != nil, let shown = message.fencePages[fence] {
                            rows.append(FlooRow(id: "\(id)#page", message: message.id, kind: .page(shown.path, shown.page)))
                        } else {
                            cut = true
                        }
                        continue
                    }
                    // A question shows as its card, which rides on the message (FlooLive).
                    if language == "floo.ask" { continue }
                    if language == "floo.choice" {
                        let options = Self.choiceOptions(block.source).map { FlooChoice(option: $0.option, tappable: $0.tappable) }
                        choiceFences[id] = (message.id, fence)
                        rows.append(FlooRow(id: id, message: message.id, kind: .choice(options, chosen: chosen[id])))
                        continue
                    }
                    var body = Self.fenceBody(block.source)
                    // The backend's cards and mentions come after the words. What comes is a
                    // new row, not the fence's row changed: views put into a row in place don't
                    // show on TiledView's reconfigure pass.
                    var row = id
                    if message.number != nil, let keys = message.fenceCards[fence] {
                        // A drawing waits in its place for its one card; a tool's cards show side
                        // by side.
                        if language == "floo.draw" {
                            body = [body.first { !$0.isEmpty } ?? "", "card: \(keys[0])"]
                        } else {
                            language = "floo.card"
                            body = keys
                            row = "\(id)#\(keys.count)"
                        }
                    } else if let mention = message.number != nil
                        ? message.fenceMentions[fence]
                        : language == "floo.mention" ? body.first.flatMap({ FlooDemoMentions.all[$0] }) : nil
                    {
                        // In the bubble with the words around it; after the one before with
                        // nothing between, one card with it (a page or a place stands alone).
                        if let before = mentioned, before.index == rows.count - 1,
                            Self.joins(mention), before.mentions.allSatisfy(Self.joins)
                        {
                            let all = before.mentions + [mention]
                            var row = FlooRow(id: "\(before.id)#\(all.count)", message: message.id, kind: .mentions(all))
                            row.bubble = rows[before.index].bubble
                            rows[before.index] = row
                            mentioned = (before.index, before.id, all)
                            continue
                        }
                        let rowID = "\(id)#mention"
                        var row = FlooRow(id: rowID, message: message.id, kind: .mentions([mention]))
                        if Self.agentBubbles {
                            row.bubble = FlooBubble(run: rowID, top: true, last: true)
                            if cut { cuts.insert(rowID) }
                        }
                        cut = false
                        mentioned = (rows.count, rowID, [mention])
                        rows.append(row)
                        continue
                    } else if message.number != nil, language != "floo.draw" || message.fenceFailed.contains(fence) {
                        // What is still to come ends the bubble before it; once the words are all
                        // in, a mention not found or a card not drawn never comes, and the words go
                        // on in the same bubble.
                        let never = !message.streaming && (language == "floo.mention" || message.fenceFailed.contains(fence))
                        if !never { cut = true }
                        continue
                    }
                    if message.number != nil {
                        let layout = Self.cardLayout(info)
                        let cards = (language == "floo.card" ? body.map { [$0] } : [body]).map { lines in
                            let name = Self.cardName(language, lines)
                            if let name { cardMessages[name, default: []].insert(message.id) }
                            return FlooCard(language: language, lines: lines, version: name.flatMap { versions[$0] } ?? 0, layout: layout)
                        }
                        // After the card before with nothing between: one row with it, a new row
                        // as it grows (what's put into a row in place doesn't show).
                        if let before = run, before.index == rows.count - 1 {
                            let all = before.cards + cards
                            rows[before.index] = FlooRow(id: "\(before.id)#\(all.count)", message: message.id, kind: .cards(all))
                            run = (before.index, before.id, all)
                            continue
                        }
                        run = (rows.count, id, cards)
                        if cards.count > 1 {
                            rows.append(FlooRow(id: "\(id)#\(cards.count)", message: message.id, kind: .cards(cards)))
                            continue
                        }
                    }
                    let card = Self.cardName(language, body)
                    if let card { cardMessages[card, default: []].insert(message.id) }
                    rows.append(FlooRow(
                        id: row,
                        message: message.id,
                        kind: .fence(
                            language,
                            body.joined(separator: "\n"),
                            version: card.flatMap { versions[$0] } ?? 0,
                            layout: message.number == nil ? nil : Self.cardLayout(info)
                        )
                    ))
                } else {
                    var row = FlooRow(id: id, message: message.id, kind: .block(block, reveals: message.streamed))
                    if Self.agentBubbles, Self.inBubble(block) {
                        row.bubble = FlooBubble(run: id, top: true, last: true)
                        if cut { cuts.insert(id) }
                    }
                    cut = false
                    rows.append(row)
                }
            }
            joinBubbles(&rows, cuts: cuts, lead: message.number == nil ? nil : lead.run)
            for row in rows {
                // A mention is whole as soon as it's there.
                if let bubble = row.bubble, case .mentions = row.kind {
                    bubbleState(bubble.run).follow(row.id, reveal: nil)
                }
                guard let bubble = row.bubble, case .block(let block, _) = row.kind else { continue }
                // Once the words are all in, a reveal still running them out is followed to its end.
                let reveal = message.streaming
                    ? message.coordinator.ensureManager(for: block.id) : message.coordinator.manager(for: block.id)
                bubbleState(bubble.run).follow(row.id, reveal: reveal, empty: block.revealPlainTextCount == 0)
            }
            wait(message.id, on: waiting)
            // What it asked rides on its words; the work it went on with is under them.
            guard waiting == nil else { return rows }
            if !message.reactions.isEmpty {
                rows.append(FlooRow(id: "m\(message.id)#reactions", message: message.id, kind: .reactions(message.reactions, trailing: false)))
            }
            for card in message.asks {
                rows.append(FlooRow(id: "m\(message.id)#ask-\(card.id)", message: message.id, kind: .ask(card)))
            }
            if !message.topics.isEmpty {
                rows.append(FlooRow(id: "m\(message.id)#topics", message: message.id, kind: .topics(message.topics)))
            } else if let thread = message.thread {
                rows.append(FlooRow(id: "m\(message.id)#replies", message: message.id, kind: .replies(thread, trailing: false)))
            }
            if let work, message.processAfterText { rows.append(work) }
            return rows
        }
    }

    /// Whether a message's words have started coming out: some of its first block is revealed,
    /// or it shows whole. Until then its bubble shows where its work is; the rows are made
    /// again once the reveal starts.
    private func wordsStarted(_ message: Message) -> Bool {
        guard let first = message.blocks.first else { return false }
        guard message.streamed, let manager = message.coordinator.manager(for: first.id), manager.revealedCount == 0 else {
            if let start = starts.removeValue(forKey: message.id) { start.manager.removeListener(start.listener) }
            return true
        }
        if starts[message.id]?.manager !== manager {
            if let start = starts[message.id] { start.manager.removeListener(start.listener) }
            let listener = manager.addListener { [weak self] count in
                guard count > 0, let self, let start = self.starts[message.id], start.manager === manager else { return }
                // Once: the rows made again find the words started.
                start.manager.removeListener(start.listener)
                self.starts[message.id] = nil
                // The status gives way to the words in the bubble, which goes from the one to
                // the other.
                Task { @MainActor in self.show(message.id, animated: true) }
            }
            starts[message.id] = (manager, listener)
        }
        return false
    }

    /// Shows a message's next block once `manager`'s block is revealed; nil: nothing waits.
    private func wait(_ message: Int, on manager: StreamingRevealManager?) {
        if let current = waits[message] {
            guard current.manager !== manager else { return }
            current.manager.removeRevealCompletionListener(current.listener)
            waits[message] = nil
        }
        guard let manager else { return }
        let listener = manager.addRevealCompletionListener { [weak self] revealed in
            guard revealed else { return }
            // Not inside the reveal's own call to its listeners.
            Task { @MainActor in self?.show(message) }
        }
        waits[message] = (manager, listener)
    }

    /// The backend's answer fences (AnswerFence): what a fence's place counts.
    static let answerFences: Set<String> = ["floo.card", "floo.draw", "floo.mention", "floo.choice", "floo.page", "floo.ask"]

    /// All of an agent's markdown goes in its bubble: words, lists, quotes, math, tables and
    /// code; only a card (a fence of floo's own) stands between bubbles.
    /// A mention that shares a card with those next to it: not a page or a place, which show
    /// as themselves.
    private static func joins(_ mention: Mention) -> Bool {
        mention.doc == nil && mention.conversation == nil
    }

    private static func inBubble(_ block: MarkdownStreamBlock) -> Bool {
        if case .markdown = block.kind { true } else { false }
    }

    /// Next rows in bubbles are one bubble, named by its first row; a row in `cuts` starts
    /// its own.
    /// `lead`: the name of the first bubble whatever row it starts with, so a message's bubble
    /// stays itself while its work and words come and go at its top.
    private func joinBubbles(_ rows: inout [FlooRow], cuts: Set<String> = [], lead: String? = nil) {
        var start = 0
        var first = true
        while start < rows.count {
            guard rows[start].bubble != nil else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < rows.count, rows[end + 1].bubble != nil, !cuts.contains(rows[end + 1].id) { end += 1 }
            let run = first ? lead ?? rows[start].id : rows[start].id
            first = false
            for index in start...end {
                rows[index].bubble = FlooBubble(run: run, top: index == start, last: index == end)
            }
            start = end + 1
        }
    }

    /// A message's first bubble: its work, then the words that follow it.
    static func leadRun(_ message: Int) -> String { "m\(message)#lead" }

    /// The row of a message's first words, and of where its work is until they come out.
    static func firstRow(_ message: Int) -> String { "m\(message)#first" }

    /// What of a bubble's rows is shown, by its first row.
    func bubbleState(_ run: String) -> FlooBubbleState {
        if let state = bubbleStates[run] { return state }
        let state = FlooBubbleState()
        bubbleStates[run] = state
        return state
    }

    func message(_ id: Int) -> Message? {
        messageByID[id]
    }

    /// The lines between a fence's first line and its end.
    /// The frame a backend card's fence header names: `floo.draw detail overflow=extend`;
    /// a summary when it names none (cards.md), clipped when it can't grow.
    nonisolated static func cardLayout(_ info: String) -> CardLayout {
        let words = info.split(separator: " ").dropFirst()
        let size = words.lazy.compactMap { CardSize(token: String($0)) }.first ?? .summary
        let overflow: CardOverflow = words.contains("overflow=extend") ? .extend : .clip
        return (try? CardLayout(size: size, overflow: overflow)) ?? CardLayout(size: size)
    }

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


