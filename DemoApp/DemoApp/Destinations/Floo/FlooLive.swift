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
import MarkdownView
import CardModel
import CardUI
import Wire
import TransportKit
import ConversationKit
import DeviceSupport
import LocalStore
import DocKit
import ServiceKit

/// A service you can connect (FlooLive.services): through the cloud, or one this Mac runs.
struct FlooLiveService: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let icon: URL?
    var connected: Bool
    /// Whether a node of yours can do its work now.
    var reachable: Bool
    /// Run by a Mac (Floo Helper, FlooHelper.swift), not the cloud.
    let mac: Bool
}

struct FlooConnectError: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

@MainActor
final class FlooLive {
    /// The stage to talk to, from the launch arguments
    /// `-flooStage http://localhost:8920 -flooAccount <person id>`; for screenshots, where
    /// to start: `-flooOpen <conversation id>`, then `-flooThread <message number>` open
    /// over it or `-flooMembers 1` its members.
    struct Stage: Sendable {
        let base: URL
        let account: AccountID

        static var opens: ConversationID? { UserDefaults.standard.string(forKey: "flooOpen").flatMap(ConversationID.init) }
        static var thread: Int64? { UserDefaults.standard.string(forKey: "flooThread").flatMap { Int64($0) } }
        static var members: Bool { UserDefaults.standard.bool(forKey: "flooMembers") }

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
        #if targetEnvironment(macCatalyst)
        // This Mac's node, started when it's signed in as you and isn't running.
        let account = session.account
        Task { _ = await FlooHelper.state(for: account) }
        #endif
        let backend = Backend(base: URL(string: "https://\(FlooOnline.server)")!, account: session.account,
                              tokens: auth, folder: "floo-online", lab: false)
        try await go(demo, backend)
    }

    private static func go(_ demo: FlooDemo, _ backend: Backend) async throws {
        // Pictures of things and services' icons from the server played.
        Assets.server = backend.base
        let live = FlooLive(demo: demo, backend: backend)
        demo.goLive(live)
        try await live.run()
    }

    private let demo: FlooDemo
    private let backend: Backend
    private var session: ConversationSession?
    /// Whether this device is the person's phone, which says where they are (floo docs/time.md §6.2).
    private var phone = false
    /// Where the conversations are kept on this device (encrypted, LocalStore): opened from
    /// here with no network, the server only bringing what's new; in memory if it won't open.
    private var store: LocalStore?
    /// The oldest message shown: one older than it, loaded on scrolling up, goes before all.
    private var lowestShown: Int64?
    private var client: FlooClient?
    /// The demo's entries for the backend's messages, by number.
    private var said: [Int64: FlooDemo.Said] = [:]
    /// What you sent from here, shown at once, by its message's id until the backend has it.
    private var outgoing: [MessageID: FlooDemo.Said] = [:]
    private var messages: [Int64: FlooDemo.Message] = [:]
    /// The topics and comments hung on the shown conversation's messages, by number.
    private var hung: [Int64: [FlooPlace]] = [:]
    /// The agents with messages here, and each message being written's agent: who's writing.
    private var speakers: Set<AgentID> = []
    private var writing: [Int64: AgentID] = [:]
    private var agents: [String: FlooAgent] = [:]
    /// The catalog's index of services, kept across launches with its revision: read again
    /// only to see whether it changed.
    private var index: ServiceIndexPage?
    /// Services' details as they were needed (a call to one shown, its page opened), kept
    /// across launches by their revisions: what a tool call's operation shows.
    private var details: [ServiceID: ServiceDetail] = [:]
    /// Details being read, so one is asked for once.
    private var reading: Set<ServiceID> = []
    /// Services whose details a shown call waits for: one read each, then one show.
    private var describing: Set<ServiceID> = []
    /// The conversation as last shown, to show again once the catalog is in.
    private var last: ConversationReplica?
    /// The conversation shown, and the following of it, ended to go to another.
    private var current: ConversationID?
    private var watching: Task<Void, Never>?
    /// The account's conversation list (floo docs/messaging.md §3.2), kept in the store and
    /// followed by the account's one stream; the services pages follow it through here too.
    private var list: DialogList?
    /// The rows this device has had, each's newest copy, by id: paged down from the top (from
    /// the store first), and kept up a row at a time by the stream.
    private var dialogs: [ConversationID: Dialog] = [:]
    /// The rows shown, in the list's order: those paged down to (`listEnd`).
    private var listed: [DialogPlace] = []
    /// Rows the stream brought below where the list is paged to: shown once paging gets there.
    private var below: Set<ConversationID> = []
    /// Where the last page ended, where the next starts; and whether the list ends there.
    private var listEnd: Dialog?
    private var listDone = false
    private var paging = false
    /// Bumped as the list is made anew: a page asked for before is dropped.
    private var listGeneration = 0
    /// The services pages following their conversations' rows (`serviceRows`).
    private var serviceFollowers: [Int: AsyncStream<ServiceRow>.Continuation] = [:]
    private var nextServiceFollower = 0
    /// The conversation the list shows as the one you're in.
    private var listedCurrent: ConversationID?
    /// The topics and comments on the shown conversation's messages: by message, and the
    /// message each hangs on; older ones are read below `topicsBelow` as older messages show.
    private var hangs: [ConversationID: Int64] = [:]
    private var topicsBelow: Int64?
    /// The backend's messages each shown agent message is made of, for the topics on it.
    private var parts: [ObjectIdentifier: [Int64]] = [:]
    /// People's names (floo docs/messaging.md §3.10): rows and messages name people by
    /// account, and the account's one copy of each name is kept on this device, asked for
    /// together as people show and kept up by the list's stream (`DialogList`).
    private var people: PeopleNames?
    /// The conversation list's and the names' store: the device's, or memory.
    private var listStorage: any ConversationStorage = MemoryConversationStorage()
    /// The names had so far, by account, and what's shown of each person to name again when
    /// theirs changes: what they said, and their agents' messages ("林的天气").
    private var names: [AccountID: String] = [:]
    private var saidBy: [AccountID: [FlooDemo.Said]] = [:]
    private var agentsOf: [AccountID: [(message: FlooDemo.Message, agent: AgentID)]] = [:]
    private var entered = false
    /// The things the agents took on, by what they're called here: kept after they're
    /// delivered (the replica lets them go) for the messages that go on with them. And each
    /// one's key in the demo's list, below zero, apart from its messages'.
    private var errandTitles: [ErrandID: String] = [:]
    private var errandKeys: [ErrandID: Int] = [:]

    private init(demo: FlooDemo, backend: Backend) {
        self.demo = demo
        self.backend = backend
    }

    /// Joins as the backend's person on a device of its own (one with no services: on a
    /// stage, its Mac and phone run those), then follows the main conversation, or the one
    /// you go to.
    private func run() async throws {
        let base = FlooClient(
            scheme: backend.scheme,
            authority: backend.authority,
            transport: URLSessionTransport(),
            tokens: backend.tokens
        )
        // This device, as the server knows it: registered, or described again when what it is
        // changed — its system's time zone too, said again whenever that changes, which is how
        // a phone tells where the person is (floo docs/time.md §6.2).
        let register: @MainActor () async throws -> DeviceCredentials
        do {
            let folder = URL.demoSupport.appending(path: backend.folder, directoryHint: .isDirectory)
            #if targetEnvironment(macCatalyst)
            // On the Mac it's one device with Floo Helper, this Mac: its key, kept in the Helper's
            // home, signs for both, and it's named and described as the Mac it is.
            let identity: DeviceIdentity? = backend.lab ? nil : DeviceIdentity(store: try FileSecrets(folder: FlooHelper.secrets))
            #else
            let identity: DeviceIdentity? = nil
            #endif
            // Online it is the phone or iPad it runs on; on a stage, an iPad of the person's, the
            // stage's own phone being theirs.
            let platform: DevicePlatform = backend.lab ? .iPad : ThisDevice.platform
            phone = platform == .iPhone
            let account = backend.account
            if let identity {
                register = { try await identity.registered(for: account, with: base, appVersion: Self.helperVersion) }
            } else {
                let plain = try DeviceIdentity(store: FileSecrets(folder: folder))
                register = {
                    try await plain.registered(
                        for: account,
                        with: base,
                        platform: platform,
                        appVersion: "demo",
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString
                    )
                }
            }
            self.client = base.with(device: try await register())
        } catch {
            demo.catchUp("没连上：\(error)")
            return
        }
        do {
            let folder = URL.demoSupport.appending(path: backend.folder, directoryHint: .isDirectory)
            let key = try DatabaseKeys(store: FileSecrets(folder: folder)).key(for: backend.account)
            // One file per account, as its key is: the lab starts a new person each time.
            store = try LocalStore(path: folder.appending(path: "conversations.\(backend.account).sqlite").path, key: key, account: backend.account)
        } catch {
            demo.catchUp("本地库没打开，这次只在内存里：\(error)")
        }
        if let store { listStorage = store.conversations }
        // Followed while this account is live, and no longer once it isn't.
        var following: [Task<Void, Never>] = []
        defer { for task in following { task.cancel() } }
        if let client {
            let people = PeopleNames(remote: client, storage: listStorage)
            self.people = people
            following.append(Task { await followNames(people) })
            following.append(Task { await followTimeZone(register) })
            // The zone they go by, asked once when the account has none (floo docs/time.md
            // §6.1); the lab's people have theirs.
            if !backend.lab { await askZone(client) }
        }
        if backend.lab {
            Task { await loadCardModel() }
            // The lab's clock, which a scene moves: "today" and "3 minutes ago" are said by it,
            // and cards read it as their now.
            following.append(Task { await FlooClock.follow(lab: backend.base) })
            CardClock.follow { Wire.Timestamp(FlooClock.now) }
        }
        Task { await loadIndex() }
        Task { await loadLibrary() }
        let listing = Task { await keepListing() }
        defer { listing.cancel() }
        current = backend.lab ? Stage.opens ?? .main(of: backend.account) : .main(of: backend.account)
        while let current, !Task.isCancelled {
            await follow(current)
        }
    }

    /// The version the Mac device goes by: Floo Helper's (floo's `HelperApp.version`), said
    /// alike by both, or each would say its own back on its next connect.
    private static let helperVersion = "helper-1"

    /// Follows a conversation until you go to another one.
    private func follow(_ id: ConversationID) async {
        guard let client else { return }
        let session = ConversationSession(id, remote: client, storage: store?.conversations ?? MemoryConversationStorage())
        self.session = session
        lowestShown = nil
        said = [:]
        outgoing = [:]
        messages = [:]
        last = nil
        saidBy = [:]
        agentsOf = [:]
        hung = [:]
        hangs = [:]
        parts = [:]
        topicsBelow = nil
        // The first is shown as the page began it; another takes its place.
        if entered { demo.enter(place(id)) }
        entered = true
        showPlaces()
        let topics = Task { await loadTopics(of: id) }
        defer { topics.cancel() }
        let following = Task { await session.follow() }
        let watching = Task { @MainActor in
            var first = true
            for await update in await session.updates() {
                guard !Task.isCancelled else { return }
                last = update.replica
                show(update)
                // A stage started here for a screenshot: what it asked for over it.
                if first, backend.lab, id == Stage.opens {
                    first = false
                    if let number = Stage.thread { showThread(of: number) }
                    if Stage.members { demo.showsMembers = true }
                }
            }
        }
        self.watching = watching
        await withTaskCancellationHandler {
            await watching.value
        } onCancel: {
            watching.cancel()
        }
        following.cancel()
    }

    // MARK: Places

    /// Goes to another of the backend's conversations.
    func open(_ place: FlooPlace) {
        guard let id = ConversationID(place.id), id != current else { return }
        current = id
        watching?.cancel()
    }

    /// Your reaction to a message of the conversation shown (messaging.md §3.11); nil takes
    /// it back. It shows once the conversation has it.
    func react(_ number: Int64, _ emoji: String?) {
        guard let client, let current else { return }
        Task {
            do {
                if let emoji {
                    try await client.react(emoji, to: number, in: current)
                } else {
                    try await client.unreact(to: number, in: current)
                }
            } catch {
                demo.catchUp("回应没成：\(error)")
            }
        }
    }

    /// The thread on a message of the conversation shown made a topic (floo messaging.md
    /// §3.13.6), gone to once it's open.
    func openTopic(on number: Int64, title: String) {
        guard let client, let current else { return }
        let topic = TopicOpen(id: .generate(), origin: MessageRef(conversation: current, number: number), title: title)
        Task {
            do {
                let info = try await client.open(topic)
                open(place(info))
            } catch {
                demo.catchUp("话题没开成：\(error)")
            }
        }
    }

    /// The list, local first (floo docs/messaging.md §3.2): the first page kept on this device
    /// shows at once, with no network; the account's stream resumes from the kept seq, and each
    /// row that changed since, and as it changes, is kept and applied to that row alone. With
    /// nothing kept, the first page comes once the stream says where the list is; it's paged
    /// again from the top only when the server's list is another one. One stream for the
    /// account (`DialogList`): the services pages take their rows from here.
    private func keepListing() async {
        guard let client else { return }
        let list = DialogList(remote: client, storage: listStorage, names: people, pageSize: Self.listPage)
        self.list = list
        let changes = await list.changes()
        let following = Task { await list.follow() }
        defer { following.cancel() }
        Task { await loadMorePlaces() }
        for await change in changes {
            switch change {
            case .reset:
                resetList()
                Task { await loadMorePlaces() }
            case .row(let change):
                take(change.dialog, of: change.conversation, seq: change.seq)
            }
        }
    }

    /// A page of the list.
    private static let listPage = 50

    /// The next page of the list below the rows paged so far (the first, when none are): the
    /// kept rows, then the server's past them; rows the stream brought below them show as
    /// paging reaches them.
    func loadMorePlaces() async {
        guard let list, !listDone, !paging else { return }
        paging = true
        let generation = listGeneration
        // try?: not paged now, asked again with the next `morePlaces`
        let page = try? await list.page(after: listEnd)
        // Made anew meanwhile: paged again from the top.
        guard generation == listGeneration else { return }
        paging = false
        guard let page else { return }
        listEnd = page.end ?? listEnd
        listDone = !page.more
        for dialog in page.rows { take(dialog, of: dialog.conversation.id, seq: dialog.seq) }
        for id in below { reposition(id, was: dialogs[id]) }
        demo.setHasMorePlaces(!listDone)
    }

    /// The list made anew: nothing held, paged from the top again.
    private func resetList() {
        listGeneration += 1
        paging = false
        dialogs = [:]
        listed = []
        below = []
        listEnd = nil
        listDone = false
        demo.setPlaces([], current: current.map(place), origin: nil)
    }

    /// A row as it is now, at `seq` (nil: gone from the list) — unless the copy held is newer.
    private func take(_ dialog: Dialog?, of id: ConversationID, seq: Int64?) {
        let old = dialogs[id]
        if let had = old?.seq, let seq, seq < had {
            hang(id)
            return
        }
        dialogs[id] = dialog
        reposition(id, was: old)
        hang(id)
        if !serviceFollowers.isEmpty, case .service(let service)? = (dialog ?? old)?.conversation.kind {
            for follower in serviceFollowers.values { follower.yield(ServiceRow(service: service, dialog: dialog)) }
        }
    }

    /// Whether the list shows the row: not agents' own conversations (their chats among
    /// themselves, a helper's, each agent's own, floo agent-kernel.md §4.8); the rest
    /// unless archived.
    private func shows(_ dialog: Dialog) -> Bool {
        switch dialog.conversation.kind {
        case .agents, .helper, .own: false
        default: !dialog.conversation.archived
        }
    }

    /// The row moved from where `old` had it to where it goes now, in the rows shown (in the
    /// list's order, `DialogPlace`): found and placed by binary search, the one row changed
    /// in the demo's list.
    private func reposition(_ id: ConversationID, was old: Dialog?) {
        var from: Int?
        if let old {
            let at = insertion(DialogPlace(old))
            if at < listed.count, listed[at].id == id.description {
                from = at
                listed.remove(at: at)
            }
        }
        var to: Int?
        below.remove(id)
        if let dialog = dialogs[id], shows(dialog) {
            let here = DialogPlace(dialog)
            if here.main || listDone || listEnd.map({ here <= DialogPlace($0) }) == true {
                let at = insertion(here)
                listed.insert(here, at: at)
                to = at
            } else {
                below.insert(id)
            }
        }
        guard from != nil || to != nil else { return }
        demo.movePlace(from: from, to: to, place(id))
    }

    /// Where `key` is or would go among the rows shown.
    private func insertion(_ key: DialogPlace) -> Int {
        var low = 0, high = listed.count
        while low < high {
            let middle = (low + high) / 2
            if listed[middle] < key { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// A conversation as the list shows it.
    private func place(_ id: ConversationID) -> FlooPlace {
        guard let dialog = dialogs[id] else {
            // Before the list has its row: yours with the butler is the main one still.
            let main = id == .main(of: backend.account)
            return FlooPlace(id: id.description, title: main ? "floo" : "对话", kind: main ? .main : .group)
        }
        return place(dialog.conversation, unread: dialog.unread)
    }

    private func place(_ info: ConversationInfo, unread: Int = 0) -> FlooPlace {
        let kind: FlooPlace.Kind
        let title: String
        switch info.kind {
        case .main:
            kind = .main
            title = "floo"
        case .group:
            kind = Self.isTopic(dialogs[info.id]) ? .topic : .group
            title = info.title ?? (kind == .topic ? "话题" : "群聊")
        case .service(let service):
            kind = .service
            title = info.title ?? agent(.service(service)).name
        case .agents, .helper, .own:
            kind = .service
            title = info.title ?? ""
        }
        return FlooPlace(id: info.id.description, title: title, kind: kind, unread: unread)
    }

    /// Whether a group is a topic, as it's called (floo messaging.md §3.13.7): you and one
    /// agent in it; another person or agent makes it a group.
    static func isTopic(_ dialog: Dialog?) -> Bool {
        guard let dialog else { return false }
        let members = dialog.members.filter { !$0.left }
        let count = dialog.memberCount ?? members.count
        return count == 2 && members.count { $0.participant.actor == .person } == 1
            && members.count { $0.participant.actor.agent != nil } == 1
    }

    /// The one you're in, and where a topic you're in hangs, to go back to.
    private func showPlaces() {
        let left = listedCurrent
        listedCurrent = current
        for id in Set([left, current].compactMap { $0 }) { reposition(id, was: dialogs[id]) }
        var origin: FlooPlace?
        if let current, let from = dialogs[current]?.conversation.origin {
            origin = place(from.conversation)
        }
        demo.setPlaces(demo.places, current: current.map(place), origin: origin)
    }

    // MARK: Topics

    /// The topics and comments on the shown conversation's messages, read as it opens: the
    /// newest page of them; older ones as older messages show (`moreTopics`).
    private func loadTopics(of id: ConversationID) async {
        guard let client, let page = try? await client.topics(on: id, limit: Self.topicPage) else { return }  // try?: read again when it opens again
        guard id == current else { return }
        for dialog in page { take(dialog, of: dialog.conversation.id, seq: dialog.seq) }
        topicsBelow = page.count < Self.topicPage ? nil : Self.origin(of: page.last)
    }

    /// Older messages showing: the topics on them, if some may not be read yet.
    private func moreTopics() {
        guard let client, let current, let below = topicsBelow, let lowest = lowestShown, lowest < below else { return }
        topicsBelow = nil
        Task {
            guard let page = try? await client.topics(on: current, before: below, limit: Self.topicPage) else { return }  // try?: as loadTopics
            guard current == self.current else { return }
            for dialog in page { take(dialog, of: dialog.conversation.id, seq: dialog.seq) }
            topicsBelow = page.count < Self.topicPage ? nil : Self.origin(of: page.last)
            moreTopics()
        }
    }

    private static let topicPage = 100

    private static func origin(of dialog: Dialog?) -> Int64? {
        dialog?.conversation.origin?.number
    }

    /// The row hung where it is now: under its message if it's a topic on the shown
    /// conversation, and off the message it was under.
    private func hang(_ id: ConversationID) {
        let was = hangs[id]
        var now: Int64?
        if let dialog = dialogs[id], let origin = dialog.conversation.origin, origin.conversation == current {
            now = origin.number
        }
        guard was != nil || now != nil else { return }
        if let was { hung[was]?.removeAll { $0.id == id.description } }
        hangs[id] = now
        if let now { hung[now, default: []].append(place(id)) }
        for number in Set([was, now].compactMap { $0 }) { showTopics(on: number) }
    }

    /// The topics on the shown message holding `number`: those hung on any of its parts; a
    /// person's, on it.
    private func showTopics(on number: Int64) {
        if let shown = said[number] {
            demo.setTopics(shown, hung[number] ?? [])
            if let last { showThreads(last) }
            return
        }
        guard let message = messages[number] else { return }
        let numbers = parts[ObjectIdentifier(message)] ?? [number]
        demo.setTopics(message, numbers.flatMap { hung[$0] ?? [] })
        if let last { showThreads(last) }
    }

    // MARK: Threads

    /// The replies under each thread's first message (floo messaging.md §3.13.4), counted
    /// from the messages on this device: replies come after their first, so with it here
    /// they all are. A thread made a topic shows its topic instead. Every message in a thread
    /// opens it from its menu; the thread open is shown again as it changes.
    private func showThreads(_ replica: ConversationReplica) {
        var replies: [Int64: [MessageInfo]] = [:]
        for info in replica.messages { if let first = info.thread { replies[first, default: []].append(info) } }
        var inThread = Set<Int64>()
        for (first, them) in replies {
            inThread.insert(first)
            inThread.formUnion(them.map(\.number))
        }
        demo.setInThread(inThread)
        func line(_ numbers: [Int64]) -> FlooThreadLine? {
            guard !numbers.contains(where: { hung[$0]?.isEmpty == false }) else { return nil }
            let them = numbers.flatMap { replies[$0] ?? [] }.sorted { $0.number < $1.number }
            guard !them.isEmpty else { return nil }
            var faces: [FlooThreadLine.Face] = []
            var seen = Set<Participant>()
            for info in them where seen.insert(info.author).inserted {
                let face = self.face(info.author)
                faces.append(FlooThreadLine.Face(initial: String(face.name.prefix(1)), tint: face.tint))
            }
            return FlooThreadLine(count: them.count, faces: faces)
        }
        for (number, shown) in said { demo.setThread(shown, line([number])) }
        var done = Set<ObjectIdentifier>()
        for message in messages.values where done.insert(ObjectIdentifier(message)).inserted {
            demo.setThread(message, line(parts[ObjectIdentifier(message)] ?? message.number.map { [$0] } ?? []))
        }
        if let open = demo.openThread { demo.openThread = thread(open.id, replica, loading: open.loading) }
    }

    /// Who wrote a message, as a face shows them: your name, someone else's, or the agent's.
    private func face(_ author: Participant) -> (name: String, tint: Color) {
        switch author.actor {
        case .agent(let id): (agent(id, of: author.account).name, agent(id, of: author.account).tint)
        case .person: author.account == backend.account ? (names[backend.account] ?? "我", .accentColor) : (names[author.account] ?? "成员", .gray)
        }
    }

    /// Opens the thread `number` is in: its messages here; the server's when its first isn't.
    func showThread(of number: Int64) {
        guard let replica = last, let current else { return }
        let first = replica.message(number)?.thread ?? number
        let here = replica.message(first) != nil
        demo.openThread = thread(first, replica, loading: !here)
        guard !here, let client else { return }
        Task {
            // try?: the lines here stay, without the older ones
            let page = try? await client.thread(first, of: current, limit: 100)
            guard demo.openThread?.id == first else { return }
            var shown = thread(first, replica, loading: false)
            if let page {
                let local = Set(shown.lines.map(\.id))
                let older = page.messages.filter { !local.contains($0.number) }.compactMap { info in
                    lineOf(info, words: page.blocks.filter { $0.message == info.number })
                }
                shown.lines = (older + shown.lines).sorted { $0.id < $1.id }
            }
            demo.openThread = shown
        }
    }

    /// A thread's messages on this device, oldest first.
    private func thread(_ first: Int64, _ replica: ConversationReplica, loading: Bool) -> FlooThreadShown {
        let lines = replica.messages.filter { $0.number == first || $0.thread == first }.compactMap {
            lineOf($0, words: replica.blocks(of: $0.number))
        }
        return FlooThreadShown(id: first, lines: lines, loading: loading)
    }

    /// A message as a thread shows it: who, when, and its words for people.
    private func lineOf(_ info: MessageInfo, words blocks: [BlockInfo]) -> FlooThreadShown.Line? {
        let text = blocks.compactMap { if case .text(let text) = $0.content, $0.audience != .model { text } else { nil } }
            .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || info.state == .streaming else { return nil }
        let face = face(info.author)
        return FlooThreadShown.Line(
            id: info.number,
            who: face.name,
            face: FlooThreadLine.Face(initial: String(face.name.prefix(1)), tint: face.tint),
            mine: info.author == .person(backend.account),
            text: text.isEmpty ? "…" : text,
            time: Self.time(info.createdAt)
        )
    }

    // MARK: Members

    /// Who is in the conversation shown, its host first marked, and whether you may change
    /// the host: it's your group (floo messaging.md §3.13.7).
    func members() async -> (members: [FlooMember], yours: Bool) {
        guard let replica = await session?.replica else { return ([], false) }
        let host = replica.conversation?.host
        let members = replica.members.values.filter { !$0.left }.map { member in
            let face = face(member.participant)
            return FlooMember(
                participant: member.participant,
                name: member.participant == .person(backend.account) ? "你" : face.name,
                agent: member.participant.actor.agent != nil,
                host: member.participant == host
            )
        }.sorted { ($0.host ? 0 : $0.agent ? 2 : 1, $0.name) < ($1.host ? 0 : $1.agent ? 2 : 1, $1.name) }
        return (members, replica.conversation?.owner == backend.account)
    }

    /// Brings people (each with their butler) and your services into the group shown.
    func add(people: [AccountID], services: [String]) async throws {
        guard let client, let current else { return }
        try await client.add(
            MembersAdd(people: people, services: services.compactMap { try? ServiceID($0) }),  // try?: from the catalog, names
            to: current
        )
    }

    /// Makes an agent in the group shown its host: who answers what you say there when it
    /// isn't clear whom it's for.
    func setHost(_ host: Participant) async throws {
        guard let client, let current else { return }
        try await client.setHost(host, of: current)
    }

    // MARK: Sending

    func send(_ text: String, replyTo: Int64? = nil) {
        guard let session else { return }
        // try?: one that doesn't go shows so in the conversation, to send again.
        let send = zoned(MessageSend(id: .generate(), text: text, replyTo: replyTo))
        Task {
            // A reply to a thread made a topic goes into the topic (floo messaging.md
            // §3.13.6): it's shown there.
            if let accepted = try? await session.send(send), let went = accepted.conversation, went != current {
                demo.openThread = nil
                open(place(went))
            }
        }
    }

    /// A message of the backend's as a reply to it shows over the composer: whose it is and
    /// how it begins.
    func replyDraft(_ number: Int64) async -> FlooReplyDraft? {
        guard let replica = await session?.replica, replica.message(number) != nil else { return nil }
        return FlooReplyDraft(number: number, who: whose(number, replica) ?? "", begins: begins(number, replica))
    }

    func choose(message: Int64, fence: Int, item: Int, option: FlooOption) {
        guard let session else { return }
        let send = MessageSend(
            id: .generate(),
            text: option.send ?? option.label,
            choosing: ChoiceRef(message: message, fence: fence, item: item)
        )
        let zoned = zoned(send)
        Task { _ = try? await session.send(zoned) }  // try?: as `send`
    }

    /// Your answer to an item of an agent's ask: a message of yours answering it, with what you
    /// picked, whether you went ahead, or what you filled in. A question in a message's words is
    /// answered at its fence; an older ask by its id.
    func answer(ask: String, item: Int, text: String, picked: [Int]? = nil, confirmed: Bool? = nil, filled: [String]? = nil) {
        guard let session, let id = AskID(ask) else { return }
        Task {
            let send: MessageSend
            let asked = await session.replica.asks[id]
            // What was typed, as each field takes it: a date field's words a day, a time field's a clock.
            let kinds: [AskField.Kind] =
                if let form = asked?.items.indices.contains(item) == true ? asked?.items[item].form : nil,
                    case .fill(let fields) = form { fields.map(\.kind) } else { [] }
            let filled = filled?.enumerated().map { place, words in
                AskValue.text(words).read(as: kinds.indices.contains(place) ? kinds[place] : .text)
            }
            if let asked, let message = asked.message, let fence = asked.fence {
                send = MessageSend(
                    id: .generate(),
                    text: text,
                    choosing: FenceAnswer(message: message, fence: fence, picked: picked, confirmed: confirmed, filled: filled)
                )
            } else {
                send = MessageSend(
                    id: .generate(),
                    text: text,
                    answering: AskAnswer(ask: id, item: item, picked: picked, confirmed: confirmed, filled: filled)
                )
            }
            _ = try? await session.send(zoned(send))  // try?: as `send`
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

    /// The catalog's index: the kept one, then the server's if it changed since (pages read
    /// only then).
    private func loadIndex() async {
        if index == nil { index = kept.read(ServiceIndexPage.self, "catalog-index") }
        guard let client else { return }
        // try?: not read now, the kept one stands and it's read again next time
        if let read = try? await client.wholeServiceIndex(revision: index?.revision) {
            index = read
            kept.write(read, "catalog-index")
        }
    }

    /// The card library (floo docs/cards.md §5.1): the kept one put in use at once, then the
    /// server's when it changed since. Until one is, the built-in library draws the cards; a
    /// card keeps the catalog it began with.
    private func loadLibrary() async {
        let held = kept.read(CardLibrary.self, "card-library")
        if let held { await Self.use(held) }
        guard let client else { return }
        // try?: not read now, the kept one (or the built-in) stands and it's asked again next time
        guard let read = try? await client.cardLibrary(language: CardLanguage.version, revision: held?.revision)
        else { return }
        if await Self.use(read) { kept.write(read, "card-library") }
    }

    /// Compiles `library` off the main actor and draws the cards begun from now on with it;
    /// false when it doesn't compile with this app's card language.
    @discardableResult
    private static func use(_ library: CardLibrary) async -> Bool {
        await Task.detached(priority: .utility) {
            let files = library.files.map { (category: $0.category, source: $0.source) }
            guard let catalog = Catalog.withLibrary(files, words: library.words) else { return false }
            Catalog.use(catalog)
            return true
        }.value
    }

    /// Where what was read of this backend is kept across launches (the demo's files; the
    /// app keeps it in its local store).
    private var kept: Kept { Kept(folder: URL.demoSupport.appending(path: "\(backend.folder)/kept", directoryHint: .isDirectory)) }

    /// A service's detail: the kept one while the index says it's current, else the server's.
    func detail(_ service: ServiceID) async -> ServiceDetail? {
        if details[service] == nil { details[service] = kept.read(ServiceDetail.self, "catalog-\(service)") }
        let current = index?.services.first { $0.id == service }?.detail
        if let held = details[service], held.revision == current { return held }
        guard let client, reading.insert(service).inserted else { return details[service] }
        defer { reading.remove(service) }
        // try?: not read now, the kept one (or none) stands
        if let read = try? await client.serviceDetail(service, revision: details[service]?.revision) {
            details[service] = read
            kept.write(read, "catalog-\(service)")
        }
        return details[service]
    }

    /// How a call's operation is shown: from its service's detail, read the first time one
    /// of its calls is shown (shown again then).
    private func operation(_ tool: ToolID) -> Operation? {
        guard let detail = details[tool.service] else {
            // The other calls of its service wait for this read, not one each.
            guard describing.insert(tool.service).inserted else { return nil }
            Task {
                defer { describing.remove(tool.service) }
                guard await detail(tool.service) != nil, let last else { return }
                show(last)
            }
            return nil
        }
        guard let found = detail.operations.first(where: { $0.id.rawValue == tool.name.rawValue }) else { return nil }
        let zh = detail.presentation.localized["zh-Hans"]?.operations?[found.id.rawValue]?.title
        return Operation(title: zh ?? found.title, symbol: found.symbol, hidden: found.hidden, icon: icon(detail.presentation.icon))
    }

    // MARK: Services

    /// The account signed in, on the floo server; nil on a stage, whose Mac is its own.
    var onlineAccount: AccountID? { backend.lab ? nil : backend.account }

    /// The server, for the services pages (FlooContactsLive.swift).
    var server: FlooClient? { client }
    /// This app's own device there.
    var ownDevice: DeviceID? { client?.device?.id }

    /// The catalog's services, the index loaded first if it isn't.
    func directory() async -> [ServiceSummary]? {
        if index == nil { await loadIndex() }
        return index?.services
    }

    /// A service's conversation as the list has it, or as it left it (nil).
    struct ServiceRow: Sendable {
        let service: ServiceID
        let dialog: Dialog?
    }

    /// The services' conversations the list has now, by service.
    func serviceDialogs() -> [ServiceID: Dialog] {
        var found: [ServiceID: Dialog] = [:]
        for dialog in dialogs.values {
            if case .service(let service) = dialog.conversation.kind, found[service] == nil { found[service] = dialog }
        }
        return found
    }

    /// The services' conversations' rows as they change from now on, whatever brings them (a
    /// page, the account's stream, a topic read): the services pages follow these rather than
    /// listing conversations themselves, so the account has one stream.
    func serviceRows() -> AsyncStream<ServiceRow> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServiceRow.self)
        let id = nextServiceFollower
        nextServiceFollower += 1
        serviceFollowers[id] = continuation
        continuation.onTermination = { _ in Task { @MainActor [weak self] in self?.serviceFollowers[id] = nil } }
        return stream
    }

    /// Goes to `service`'s conversation, once listed.
    func openService(_ service: ServiceID) {
        guard let dialog = dialogs.values.first(where: { $0.conversation.kind == .service(service) }) else { return }
        open(place(dialog.conversation))
    }

    /// The services you can connect, through the cloud or on a Mac, and whether each is.
    func services() async throws -> [FlooLiveService] {
        guard let client else { return [] }
        if index == nil { await loadIndex() }
        let connections = Dictionary(try await client.connections().map { ($0.service, $0) }) { first, _ in first }
        return (index?.services ?? []).filter { !$0.hidden && ($0.hosts.contains(.cloud) || $0.hosts.contains(.mac)) }.map { entry in
            let zh = entry.text(in: "zh-Hans")
            return FlooLiveService(
                id: entry.id.rawValue,
                name: zh.name ?? entry.name,
                summary: zh.shortDescription ?? entry.shortDescription ?? "",
                icon: icon(entry.icon),
                connected: connections[entry.id]?.connected ?? false,
                reachable: connections[entry.id]?.reachable ?? false,
                mac: !entry.hosts.contains(.cloud)
            )
        }
    }

    /// The services you have, for a group to bring in.
    func connectedServices() async -> [FlooLiveService] {
        ((try? await services()) ?? []).filter(\.connected)  // try?: none to pick
    }

    /// Connects a service: you sign in to it in the browser, and it's yours once that's done.
    func connect(_ id: ServiceID) async throws {
        guard let client else { return }
        let link = try await client.connect(id)
        if let url = URL(string: link.url) { await UIApplication.shared.open(url) }
        // Asked again until it's done, for as long as signing in reasonably takes.
        for _ in 0..<150 {
            try await Task.sleep(for: .seconds(2))
            let state = try await client.signIn(link.link)
            switch state.state {
            case .pending: continue
            case .failed: throw FlooConnectError(reason: state.reason ?? "没连上")
            case .connected:
                // Signed in, it's connected in the cloud.
                return
            }
        }
        throw FlooConnectError(reason: "等登录等太久了")
    }

    private func icon(_ path: String?) -> URL? {
        path.flatMap { path in
            path.hasPrefix("/") ? backend.base.appending(path: String(path.dropFirst())) : URL(string: path)
        }
    }

    // MARK: Groups

    /// Someone to bring into a group, by their email; nil if there's no such account.
    func person(email: String) async throws -> PersonFound? {
        guard let client else { return nil }
        return try await client.person(email: email)
    }

    /// A group of yours with your butler, these people (each with theirs) and services, gone
    /// to once it's open.
    func openGroup(title: String, people: [AccountID], services: [String]) async throws {
        guard let client else { return }
        let group = GroupOpen(id: .generate(), title: title, people: people,
                              services: services.compactMap { try? ServiceID($0) })  // try?: from the catalog, names
        let info = try await client.open(group)
        open(place(info))
    }

    // MARK: Pages

    /// A page the agent wrote, read whole as it is now; nil, said, if it can't be.
    /// What a floo link names, as this device has it now (CardUI's `ItemName`, `ItemPreview`):
    /// a topic or group by its number in the account (`/places/c12/`), a page by its path.
    func item(_ url: String) async -> CardItem? {
        if let place = place(at: url) {
            return CardItem(name: place.title, line: place.kind == .topic ? "话题" : place.kind == .group ? "群聊" : nil)
        }
        // A block of it (`#<block id>`) is the page's.
        let path = String(url.prefix { $0 != "#" })
        guard path.hasPrefix("/drive/"), let doc = await page(path) else { return nil }
        let summary = DocPage.summary(of: doc)
        return CardItem(name: summary.title, line: summary.preview.isEmpty ? nil : summary.preview)
    }

    /// The conversation a link names by its number in the account (`/places/c12/`), as the
    /// list has it (docs/place-refs.md §1); nil when it names none the list has.
    func place(at url: String) -> FlooPlace? {
        guard let match = url.wholeMatch(of: #/\/places\/c(\d+)\/?/#), let number = Int64(match.output.1),
            let dialog = dialogs.values.first(where: { $0.place == number })
        else { return nil }
        return place(dialog.conversation, unread: dialog.unread)
    }

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
        demo.batch { showAll(replica) }
    }

    private func showAll(_ replica: ConversationReplica) {
        speakers = []
        writing = [:]
        name(Set(replica.members.keys.map(\.account)))
        let agentsRead = replica.members.filter { $0.key.actor.agent != nil }.map(\.value)
        // Taken back, or the work of a run that passed having said nothing: it goes.
        let told = Self.told(replica)
        let shown = replica.messages.filter { !Self.unheard($0, told: told, replica) }
        let present = Set(shown.map(\.number))
        for (number, message) in messages where !present.contains(number) {
            messages[number] = nil
            if !messages.values.contains(where: { $0 === message }) { demo.remove(message) }
        }
        // A run's message of work only is overtaken when something comes in while it works (an
        // errand's result): its words go to the run's next message, after that. With nothing
        // shown between them, they're one message here: the work, then the words.
        var parts: [MessageInfo] = []
        for info in shown {
            switch info.author.actor {
            case .person:
                showAgent(parts, replica: replica)
                parts = []
                showPerson(info, replica, agentsRead: agentsRead)
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
        showReactions(replica)
        showThreads(replica)
        showOutbox(replica)
        showAsks(replica)
        showErrands(replica)
        showPresence(replica)
        lowestShown = replica.messages.first?.number
        moreTopics()
        demo.setHasOlder(replica.hasOlder)
    }

    /// What changed, and only that: the messages it touched (each with the run's parts it's
    /// shown with), older ones loaded on scrolling up before everything shown; the whole
    /// window again only when it was loaded anew, something was taken back or receipts moved.
    private func show(_ update: ConversationUpdate) {
        let replica = update.replica, changes = update.changes
        demo.setHasOlder(replica.hasOlder)
        // A run ending may leave its work unheard: that goes too.
        if changes.all || !changes.removed.isEmpty || changes.parts.contains(.members) || changes.parts.contains(.active) {
            return show(replica)
        }
        demo.batch { showChanges(changes, replica) }
    }

    private func showChanges(_ changes: ReplicaChanges, _ replica: ConversationReplica) {
        let older = changes.messages.filter { $0 < lowestShown ?? .max }
        if let lowest = older.min() {
            demo.prepending { for group in groups(older, replica) { showGroup(group, replica) } }
            lowestShown = lowest
            moreTopics()
        }
        let rest = changes.messages.subtracting(older)
        for group in groups(rest, replica) { showGroup(group, replica) }
        showReactions(replica, of: changes.messages)
        if !changes.messages.isEmpty { showThreads(replica) }
        if changes.parts.contains(.outbox) { showOutbox(replica) }
        // A message's own asks and topics are shown with it (showAgent).
        if changes.parts.contains(.asks) { showAsks(replica) }
        // In hand: where each hangs may have come in with older messages.
        if changes.parts.contains(.errands) || !changes.messages.isEmpty { showErrands(replica) }
        if changes.parts.contains(.active) || changes.parts.contains(.errands) || !rest.isEmpty { showPresence(replica) }
    }

    /// The shown units holding `numbers`: a person's message, or an agent's run's parts shown
    /// as one (show(replica)'s rule).
    private func groups(_ numbers: Set<Int64>, _ replica: ConversationReplica) -> [[MessageInfo]] {
        let list = replica.messages
        func joins(_ a: MessageInfo, _ b: MessageInfo) -> Bool {
            a.author.actor.agent != nil && b.author.actor.agent != nil && b.run != nil && b.run == a.run && !Self.speaks(a, replica)
        }
        var seen = Set<Int64>()
        var groups: [[MessageInfo]] = []
        let told = Self.told(replica)
        for number in numbers.sorted() where !seen.contains(number) {
            guard let at = replica.position(of: number), !Self.unheard(list[at], told: told, replica) else { continue }
            var start = at, end = at
            while start > 0, joins(list[start - 1], list[start]) { start -= 1 }
            while end + 1 < list.count, joins(list[end], list[end + 1]) { end += 1 }
            let group = Array(list[start...end])
            groups.append(group)
            seen.formUnion(group.map(\.number))
        }
        return groups
    }

    private func showGroup(_ group: [MessageInfo], _ replica: ConversationReplica) {
        guard let first = group.first else { return }
        if first.author.actor == .person {
            let agentsRead = replica.members.filter { $0.key.actor.agent != nil }.map(\.value)
            showPerson(first, replica, agentsRead: agentsRead)
        } else {
            showAgent(group, replica: replica)
        }
    }

    /// An agent with a run going is writing, between its model's calls too (its message
    /// stops streaming while a tool runs, and the next one starts after). Not writing, it's at
    /// what it has in hand: the one thing it's doing, or how many it has.
    private func showPresence(_ replica: ConversationReplica) {
        let writing = Set(replica.active.compactMap(\.agent.actor.agent)).union(self.writing.values)
        var inHand: [AgentID: [ErrandInfo]] = [:]
        for errand in replica.inHand {
            if let id = errand.agent.actor.agent { inHand[id, default: []].append(errand) }
        }
        for id in speakers.union(writing).union(inHand.keys) {
            let doing: String? =
                if writing.contains(id) { "正在写…" }
                else if let errands = inHand[id] { errands.count == 1 ? "\(Self.doing(errands[0]))…" : "手上 \(errands.count) 件事" }
                else { nil }
            demo.setPresence(agent(id), doing)
        }
    }

    // MARK: In hand

    /// The things the agents have in hand here, each going to the message that asked for it,
    /// in the conversation's order.
    private func showErrands(_ replica: ConversationReplica) {
        let errands = replica.inHand.sorted { ($0.origin ?? .max, $0.pts) < ($1.origin ?? .max, $1.pts) }
        demo.setErrands(errands.compactMap { errand in
            guard let id = errand.agent.actor.agent else { return nil }
            let title = Self.title(errand)
            errandTitles[errand.id] = title
            let key = errandKeys[errand.id] ?? -(errandKeys.count + 1)
            errandKeys[errand.id] = key
            return FlooDemo.Errand(
                id: key,
                agent: agent(id, of: errand.agent.account),
                title: title,
                doing: Self.doing(errand),
                since: errand.origin.flatMap { replica.message($0) }.map { Self.time($0.createdAt) } ?? "",
                row: errand.origin.flatMap { row($0) }
            )
        })
    }

    /// What a thing is called: its name, or before it's named, what its first work does.
    private static func title(_ errand: ErrandInfo) -> String {
        errand.title ?? errand.works.lazy.compactMap(\.label).first ?? "在办的事"
    }

    /// What it's at: the newest of its works still going, else the next step it means to take.
    private static func doing(_ errand: ErrandInfo) -> String {
        if let work = errand.works.last(where: { $0.status == .running }) { return work.doing ?? work.label ?? "在弄" }
        if let next = errand.notStarted.first { return "等 \(next)" }
        return "在收尾"
    }

    /// The row a message of the backend's is shown in, if it is.
    private func row(_ number: Int64) -> String? {
        if let said = said[number] { return demo.row(of: said) }
        return messages[number].map { "m\($0.id)#sig" }
    }

    /// How an agent's message stands to what came before it (§19.2): pushed, and the line it
    /// rang with (`tell`'s alert, floo proactivity.md 5.5); the message it replies to (`replyTo`, messaging.md §3.12);
    /// and the errand it goes on with — in the agent's words when it gave some, else by what
    /// it points at.
    private func marks(of parts: [MessageInfo], _ replica: ConversationReplica) -> [FlooMark] {
        let blocks = parts.lazy.flatMap { replica.blocks(of: $0.number) }
        let label = blocks.compactMap { if case .aboutLabel(let label) = $0.content { label } else { nil } }.first
        var marks: [FlooMark] = []
        if let why = blocks.compactMap({ if case .notified(let why) = $0.content { why } else { nil } }).first {
            marks += [.proactive, .notified(why)]
        }
        if let number = parts.lazy.reversed().compactMap(\.replyTo).first {
            marks.append(.replying(reply(to: number, replica)))
        }
        for case .committed(let committed) in blocks.map(\.content) { marks.append(.committed(Self.said(committed))) }
        guard let about = parts.lazy.reversed().compactMap(\.about).first else { return marks }
        let errand = about.errand.flatMap { errandTitles[$0] ?? replica.errands[$0].map(Self.title) }
        switch about.kind {
        case .delivery:
            break
        case .continuing:
            marks.append(.continuing(label ?? errand.map { "接着 \($0)" } ?? "接着之前的事"))
        case .joined:
            marks.append(.joined(errand ?? "在办的事", label: label))
        case .soFar:
            marks.append(.soFar(label ?? "按目前进度"))
        case .following, .replying:
            // Stored before replies moved to `replyTo`; the server moved them over (m0112).
            if let number = about.message, marks.isEmpty { marks.append(.replying(reply(to: number, replica))) }
        }
        return marks
    }

    /// What a message replies to (messaging.md §3.12.4): who wrote that one and how it begins,
    /// or the words picked out of it; where it's shown, to go to.
    private func reply(to number: Int64, quote: String? = nil, _ replica: ConversationReplica) -> FlooReply {
        guard let info = replica.message(number) else { return FlooReply(shown: .older) }
        let mine = info.author.account == backend.account
        let face: (name: String, tint: Color) = switch info.author.actor {
        case .agent(let id): (agent(id, of: info.author.account).name, agent(id, of: info.author.account).tint)
        case .person: mine ? (names[backend.account] ?? "我", .accentColor) : (names[info.author.account] ?? "成员", .gray)
        }
        let bubble = said[number].map { demo.row(of: $0) } ?? messages[number].map { FlooDemo.leadRun($0.id) }
        return FlooReply(
            initial: String(face.name.prefix(1)),
            tint: face.tint,
            shown: quote.map { .part($0) } ?? .begins(begins(number, replica)),
            row: row(number),
            bubble: bubble
        )
    }

    /// How a message begins, as a reply to it shows it: its words for people on one line.
    private func begins(_ number: Int64, _ replica: ConversationReplica) -> String {
        let words = replica.blocks(of: number)
            .compactMap { if case .text(let text) = $0.content, $0.audience != .model { text } else { nil } }
            .joined(separator: " ").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.prefix(80))
    }

    /// Who said a message, as a mark names them: "你" for yours, else their name or their
    /// agent's.
    private func whose(_ number: Int64, _ replica: ConversationReplica) -> String? {
        guard let info = replica.message(number) else { return nil }
        switch info.author.actor {
        case .person: return info.author.account == backend.account ? "你" : names[info.author.account] ?? "成员"
        case .agent(let id): return agent(id, of: info.author.account).name
        }
    }

    /// Scrolled to the top: the page before, from this device's store, or the server's
    /// history where it has a hole.
    func loadOlder() async {
        _ = try? await session?.loadOlder()  // try?: the loader shows again on the next pull to the top
    }

    // MARK: Outbox

    /// What you sent from here that the backend doesn't have yet: shown as you send it, as a
    /// messenger does, marked until it's there; one that didn't go is sent again with a tap.
    private func showOutbox(_ replica: ConversationReplica) {
        for item in replica.outbox {
            let receipt: FlooReceipt = item.state == .failed ? .failed : .sending
            if let shown = outgoing[item.message.id] {
                if shown.receipt != receipt { demo.mark(shown, receipt) }
                continue
            }
            let answers = item.message.answering.flatMap { answer in
                replica.asks[answer.ask].flatMap { $0.items.indices.contains(answer.item) ? $0.items[answer.item].title : nil }
            } ?? item.message.choosing.flatMap { answer in
                replica.asks.values.first { $0.message == answer.message && $0.fence == answer.fence }?.title
            }
            let reply = answers.map { FlooReply(.butler, .answer($0)) }
                ?? item.message.replyTo.map { reply(to: $0, quote: item.message.quote, replica) }
            let shown = demo.say(.me, item.message.text, receipt: receipt, reply: reply, at: item.at.date)
            outgoing[item.message.id] = shown
            let id = item.message.id
            demo.retries[demo.row(of: shown)] = { [weak self] in
                guard let session = self?.session else { return }
                Task { _ = try? await session.resend(id) }  // try?: as `send`
            }
        }
    }

    // MARK: Asks

    /// The agents' asks, each on the message that asked it: its card there and, while it's
    /// open, over where you type.
    private func showAsks(_ replica: ConversationReplica) {
        // Every message shown, so one whose asks are gone has none.
        var cards: [ObjectIdentifier: (message: FlooDemo.Message, cards: [FlooAskCard])] = [:]
        for message in messages.values { cards[ObjectIdentifier(message)] = (message, []) }
        for ask in replica.asks.values.sorted(by: { $0.pts < $1.pts }) {
            guard let number = ask.message, let message = messages[number], let id = ask.agent.actor.agent,
                let card = card(ask, agent(id), replica)
            else { continue }
            cards[ObjectIdentifier(message), default: (message, [])].cards.append(card)
        }
        for (message, asks) in cards.values { demo.setAsks(message, asks) }
    }

    /// `text` with its citation chips (§20.2) as MarkdownView draws them: a web one as written; a
    /// result one checked, as a tool chip with its tool's icon; one not checked (yet) left out.
    /// `from`: the index of its first chip among the message's.
    private static func chips(_ text: String, _ cites: [Int: AnswerCite], from index: inout Int) -> String {
        text.replacing(#/\[([^\]\n]+)\]\(([^\s()"]+)[ \t]+"cite"\)/#) { match in
            defer { index += 1 }
            let target = String(match.2)
            guard target.hasPrefix("result:") else { return String(match.0) }
            guard let cite = cites[index], "result:" + cite.from == target else { return "" }
            let link = "\(MarkdownLinkChips.toolScheme)://\(cite.from)"
            FlooSiteIcons.cites[link] = cite
            return "[\(match.1)](\(link) \"cite\")"
        }
    }

    /// An ask as its card shows it; a question in a message's words, once its block is in.
    private func card(_ ask: AskInfo, _ agent: FlooAgent, _ replica: ConversationReplica) -> FlooAskCard? {
        let state: FlooAskCard.State =
            switch ask.status {
            case .open: .open
            case .answered: .answered
            case .withdrawn, .replaced: .withdrawn
            case .expired: .expired
            }
        // Answered: what the answering message says.
        func said(_ number: Int64) -> String {
            replica.blocks(of: number).compactMap { if case .text(let text) = $0.content { text } else { nil } }
                .joined(separator: " ")
        }
        if let number = ask.message, let fence = ask.fence, let title = ask.title {
            let blocks = replica.blocks(of: number)
            guard
                let question = blocks.lazy.compactMap({ block -> AnswerQuestion? in
                    if case .question(let question) = block.content, question.fence == fence { question } else { nil }
                }).first
            else { return nil }
            let words = blocks.compactMap { if case .text(let text) = $0.content { text } else { nil } }.joined(separator: "\n")
            let item = FlooAskItem(
                title: title, question: Self.asking(title, in: words), form: Self.form(question.form),
                answer: ask.answer.map(said)
            )
            return FlooAskCard(id: ask.id.description, agent: agent, items: [item], state: state)
        }
        let items = ask.items.map { item in
            FlooAskItem(title: item.title, question: item.question, form: Self.form(item.form), answer: item.answer.map(said))
        }
        return FlooAskCard(id: ask.id.description, agent: agent, items: items, state: state)
    }

    /// The sentence a `floo.ask` fence follows in `words`: what it asks; its title if none.
    private static func asking(_ title: String, in words: String) -> String {
        guard let fence = words.firstRange(of: "```floo.ask \(title)") else { return title }
        let before = words[..<fence.lowerBound].split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return before.map { $0.trimmingCharacters(in: .whitespaces) } ?? title
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
            .fill(fields: fields.map { FlooAskItem.Field(label: $0.label, kind: Self.kind($0.kind), guess: $0.guess.map(Self.words) ?? "") })
        case .unknown:
            .fill(fields: [])
        }
    }

    /// A commitment as the message shows it (floo docs/time.md §8): what happened to it, its rule
    /// as a rule ("每天 07:00"), the zone it goes by where that isn't this device's, what it does.
    private static func said(_ committed: Committed) -> String {
        let change = switch committed.change {
        case .added: "约好"
        case .changed: "改成"
        case .stopped: "不再"
        }
        let zone = committed.next?.zone
        // time: shown on this device, by its calendar
        let elsewhere = zone.flatMap { $0.identifier == TimeZone.current.identifier ? nil : FlooZones.city(of: $0) }
        let when: String? =
            switch committed.trigger {
            case .at(let moment)?: "\(FlooDay.label(moment.at.date)) \(moment.at.date.formatted(.dateTime.hour().minute()))"
            case .daily(let clock, let weekdays)?: "\(Self.days(weekdays)) \(clock)"
            case .on?, .when?: "有动静时"
            case nil: committed.said
            }
        let rule = [when, elsewhere.map { "（\($0) 时间）" }].compactMap { $0 }.joined()
        return [change, rule, "· \(committed.line)"].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "每天", "工作日", or the days by name.
    private static func days(_ weekdays: Set<Weekday>) -> String {
        if weekdays.isEmpty || weekdays.count == 7 { return "每天" }
        if weekdays == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "工作日" }
        let names: [Weekday: String] = [
            .monday: "一", .tuesday: "二", .wednesday: "三", .thursday: "四", .friday: "五", .saturday: "六", .sunday: "日",
        ]
        let order: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        return "每周" + order.filter(weekdays.contains).compactMap { names[$0] }.joined(separator: "、")
    }

    /// A field's value as it's typed: a day as "2026-10-23", a clock as "07:30".
    private static func words(_ value: AskValue) -> String {
        switch value {
        case .text(let words): words
        case .day(let day): day.description
        case .clock(let clock): clock.description
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

    /// Whether a message has words, stored or coming. Only what people read speaks: a run's
    /// work is its agent's own, its words there drafts (floo messaging.md §3.14).
    private static func speaks(_ info: MessageInfo, _ replica: ConversationReplica) -> Bool {
        guard info.visibility == .members else { return false }
        return replica.blocks(of: info.number).contains {
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

    /// A run's work out of sight: the run is over and told nothing here, as it passed unheard
    /// (floo messaging.md §3.14). While it goes, its work shows.
    private static func unheard(_ info: MessageInfo, told: Set<RunID>, _ replica: ConversationReplica) -> Bool {
        guard info.visibility != .members, let run = info.run, !told.contains(run) else { return false }
        return !replica.active.contains { $0.run == run }
    }

    /// The runs that told something here.
    private static func told(_ replica: ConversationReplica) -> Set<RunID> {
        Set(replica.messages.filter { $0.visibility == .members }.compactMap(\.run))
    }

    private func showPerson(_ info: MessageInfo, _ replica: ConversationReplica, agentsRead: [MemberInfo]) {
        let blocks = replica.blocks(of: info.number)
        let receipt: FlooReceipt =
            agentsRead.contains { $0.answeredMax >= info.number } ? .answered
            : agentsRead.contains { $0.readMax >= info.number } ? .read : .delivered
        // Sent from here: the backend's message is the one already shown.
        if said[info.number] == nil, let mine = outgoing.removeValue(forKey: info.id) {
            said[info.number] = mine
            demo.retries[demo.row(of: mine)] = nil
        }
        // Someone else's, in a group: by name, with no receipt of yours.
        let mine = info.author.account == backend.account
        if let said = said[info.number] {
            demo.setNumber(said, info.number)
            if mine, said.receipt != receipt { demo.mark(said, receipt) }
            demo.setSentTo(said, sentTo(info, replica))
            return
        }
        var text = blocks.compactMap { if case .text(let text) = $0.content { text } else { nil } }.joined(separator: "\n\n")
        var quote: String?
        var answers: (title: String, message: Int64?)?
        for block in blocks {
            switch block.content {
            case .quote(let words): quote = words
            case .answering(let ask, _, let title, _) where answers == nil: answers = (title, replica.asks[ask]?.message)
            case .answers(let message, _, let title) where answers == nil: answers = (title, message)
            case .choosing(_, _, _, let label) where text.isEmpty: text = label
            default: break
            }
        }
        guard !text.isEmpty else { return }
        // An answer shows the question it answers, by the face of the one who asked.
        let reply = answers.map { answers in
            var reply = answers.message.map { reply(to: $0, replica) } ?? FlooReply(.butler, .older)
            reply.shown = .answer(answers.title)
            return reply
        } ?? info.replyTo.map { reply(to: $0, quote: quote, replica) }
        if mine {
            said[info.number] = demo.say(.me, text, receipt: receipt, reply: reply, at: info.createdAt.date)
        } else {
            let theirs = demo.say(.person(names[info.author.account] ?? "成员"), text, reply: reply, at: info.createdAt.date)
            said[info.number] = theirs
            saidBy[info.author.account, default: []].append(theirs)
        }
        if let shown = said[info.number] {
            demo.setNumber(shown, info.number)
            demo.setSentTo(shown, sentTo(info, replica))
        }
    }

    /// Whom a person's message in a group went to, when it @'d none of them (floo
    /// messaging.md §3.13.7): the agents the judge or the host gave it to, by name.
    private func sentTo(_ info: MessageInfo, _ replica: ConversationReplica) -> String? {
        guard replica.conversation?.kind == .group else { return nil }
        let agents = info.addressees.filter { $0.actor.agent != nil }
        guard !agents.isEmpty else { return nil }
        let text = replica.blocks(of: info.number).compactMap { if case .text(let text) = $0.content { text } else { nil } }
            .joined(separator: " ")
        let names = agents.map { face($0).name }
        guard !names.contains(where: { text.contains("@" + $0) }) else { return nil }
        return names.joined(separator: "、")
    }

    /// The reactions on the messages shown (or on `numbers` of them), each emoji once with how
    /// many gave it, in the order first given; yours marked.
    private func showReactions(_ replica: ConversationReplica, of numbers: Set<Int64>? = nil) {
        for info in replica.messages where numbers?.contains(info.number) ?? true {
            let given = replica.reactions(of: info.number)
            var shown: [FlooReaction] = []
            for reaction in given {
                guard let emoji = reaction.emoji, !shown.contains(where: { $0.emoji == emoji }) else { continue }
                let all = given.filter { $0.emoji == emoji }
                shown.append(FlooReaction(
                    emoji: emoji,
                    count: all.count,
                    mine: all.contains { $0.by == .person(backend.account) },
                    who: all.map { who($0.by) }
                ))
            }
            if let person = said[info.number] {
                demo.setReactions(person, shown)
            } else if let message = messages[info.number], message.number == info.number {
                demo.setReactions(message, shown)
            }
        }
    }

    /// Who gave a reaction, as they're called here.
    private func who(_ participant: Participant) -> String {
        switch participant.actor {
        case .person: participant.account == backend.account ? "你" : names[participant.account] ?? "成员"
        case .agent(let id): agent(id, of: participant.account).name
        }
    }

    /// The calls an agent speaks and ends with: what they say is its words, not its work.
    private static let speech: Set<String> = ["tell", "pass"]

    /// An agent's message, from the backend's messages it's made of: one, or a run's work
    /// and what it told after.
    private func showAgent(_ parts: [MessageInfo], replica: ConversationReplica) {
        guard let first = parts.first, let last = parts.last, case .agent(let id) = first.author.actor else { return }
        let owner = first.author.account
        let message = parts.lazy.compactMap { self.messages[$0.number] }.first ?? {
            let message = demo.begin(agent(id, of: owner), at: Self.time(first.createdAt), on: first.createdAt.date)
            if owner != backend.account { agentsOf[owner, default: []].append((message, id)) }
            return message
        }()
        for info in parts { messages[info.number] = message }
        self.parts[ObjectIdentifier(message)] = parts.map(\.number)
        // Its fences are its words', the last part's: what a choice answers.
        message.number = last.number
        message.marks = marks(of: parts, replica)
        let streaming = parts.contains { $0.state == .streaming }

        var words: [String] = []
        var work = Work(live: streaming)
        for info in parts {
            let start = words.count
            let blocks = replica.blocks(of: info.number)
            let stored = Set(blocks.map(\.id))
            let live = replica.live(of: info.id).filter { !stored.contains($0.id) }
            // Words only in what people read; in its work, drafts, shown as its thinking.
            let read = info.visibility == .members
            for block in blocks {
                switch block.content {
                case .text(let text) where block.audience != .model:
                    if read {
                        words.append(text)
                    } else {
                        work.think(block.id.description, text, going: false, started: block.startedAt, ended: block.endedAt)
                    }
                case .toolCall(_, let name, _, _) where Self.speech.contains(name):
                    break
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
                    message.fenceMentions[mention.fence] = self.mention(mention)
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
                    message.fenceMentions[mention.fence] = self.mention(mention)
                }
                if case .page(let page) = content, message.fencePages[page.fence] == nil {
                    message.fencePages[page.fence] = Self.page(page)
                }
            }
            for block in live {
                switch block.kind {
                case .text where read:
                    words.append(block.text)
                case .text:
                    work.think(block.id.description, block.text, going: !block.done, started: block.startedAt, ended: block.endedAt)
                case .toolCall where block.call.map { Self.speech.contains($0.name) } == true:
                    break
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
            // Its result chips as checked (§20.2), as stored or as they closed.
            var cites = replica.cited[info.number] ?? [:]
            for block in blocks { if case .cite(let cite) = block.content { cites[cite.index] = cite } }
            var chip = 0
            for at in words.indices where at >= start { words[at] = Self.chips(words[at], cites, from: &chip) }
        }

        demo.setSteps(message, steps(work, progress: replica.progress), thinking: work.thinking)
        demo.setText(message, words.filter { !$0.isEmpty }.joined(separator: "\n\n"), streaming: streaming)
        // What was asked on it and the topics hung on it.
        let numbers = Set(parts.map(\.number))
        let asks = replica.asks.values.filter { $0.message.map(numbers.contains) == true }.sorted { $0.pts < $1.pts }
        demo.setAsks(message, asks.compactMap { ask in ask.agent.actor.agent.flatMap { card(ask, agent($0), replica) } })
        demo.setTopics(message, parts.flatMap { hung[$0.number] ?? [] })
        speakers.insert(id)
        for info in parts {
            if info.state == .streaming { writing[info.number] = id } else { writing[info.number] = nil }
        }
        // Its fences' cards, mentions and pages, which only its rows show.
        demo.touch(message)
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
        let operation = call.operation.flatMap { self.operation($0) }
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

    // MARK: Names

    /// Names the people of `accounts` not named yet: the kept names at once, the rest asked
    /// for together; each then shows where they're shown.
    private func name(_ accounts: Set<AccountID>) {
        let unnamed = accounts.filter { names[$0] == nil }
        guard let people, !unnamed.isEmpty else { return }
        Task {
            showNames(Array(await people.people(unnamed).values))
        }
    }

    /// This device's system zone, said again whenever it changes: a phone's says where the
    /// person is (floo docs/time.md §6.2). It never sets the zone they go by.
    private func followTimeZone(_ register: @MainActor () async throws -> DeviceCredentials) async {
        for await _ in NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange) {
            do { _ = try await register() } catch {
                demo.catchUp("时区没告诉服务器：\(error)")
            }
        }
    }

    /// The zone they go by, when the account has none yet: picked here, where their phone says
    /// they are, else this device's zone.
    private func askZone(_ client: FlooClient) async {
        do {
            // A server from before zones says none: nothing to ask then.
            guard let zones = try await client.account().zones else { return }
            demo.usualZone = zones.usual
            guard zones.usual == nil else { return }
            let choice = FlooZoneChoice(zone: zones.here ?? ThisDevice.timeZone ?? .utc)
            demo.zoneChoice = choice
            let zone = await choice.chosen()
            demo.zoneChoice = nil
            try await setUsualZone(zone)
        } catch {
            demo.zoneChoice = nil
            demo.catchUp("没读到时区：\(error)")
        }
    }

    /// The zone they go by, as they picked it.
    func setUsualZone(_ zone: ZoneName) async throws {
        guard let client else { return }
        try await client.setTimeZone(zone.identifier)
        demo.usualZone = zone
    }

    /// A message as this device sends it: from a phone, with the zone it's sent in.
    private func zoned(_ send: MessageSend) -> MessageSend {
        var send = send
        if phone { send.zone = ThisDevice.timeZone }
        return send
    }

    /// The names' changes, as the list's stream brings them: each shows where it's shown.
    private func followNames(_ people: PeopleNames) async {
        for await change in await people.changes() {
            switch change {
            case .people(let changed): showNames(changed)
            case .reset:
                // Started anew: those shown are named again.
                let shown = Set(names.keys)
                names = [:]
                name(shown)
            }
        }
    }

    /// People as they're called now, in what's shown of them.
    private func showNames(_ people: [PersonInfo]) {
        for person in people {
            guard let name = person.name, names[person.account] != name else { continue }
            names[person.account] = name
            for said in saidBy[person.account] ?? [] { demo.rename(said, as: .person(name)) }
            for (message, id) in agentsOf[person.account] ?? [] { demo.rename(message, as: agent(id, of: person.account)) }
        }
    }

    // MARK: Mapping

    private static let palette: [Color] = [.orange, .teal, .purple, .mint, .brown]

    /// The demo's agent for one of the backend's: the butler, or a service by what it's for.
    /// Someone else's agent, in a group: theirs by name.
    private func agent(_ id: AgentID, of owner: AccountID) -> FlooAgent {
        let own = agent(id)
        guard owner != backend.account else { return own }
        return FlooAgent(name: "\(names[owner] ?? "别人")的\(own.name)", tint: .teal)
    }

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

    private static let clock: DateFormatter = {  // time: shown on this device, by its calendar
        let formatter = DateFormatter()  // time: shown on this device, by its calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func time(_ timestamp: Wire.Timestamp) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp.millisecondsSince1970) / 1000)
        return clock.string(from: date)
    }

    private static func item(_ key: String) -> Int { Int(key.split(separator: "-").last ?? "") ?? 0 }

    /// A card's data as cards take it: the same values, kind for kind.
    private static func value(_ json: Wire.JSONValue?) -> CardValue {
        guard let json else { return .object([:]) }
        return card(json)
    }

    private static func card(_ json: Wire.JSONValue) -> CardValue {
        switch json {
        case .null: .null
        case .bool(let bool): .bool(bool)
        case .int(let number): .number(Double(number))
        case .double(let number): .number(number)
        case .string(let string): .string(string)
        case .array(let items): .array(items.map(card))
        case .object(let fields): .object(fields.mapValues(card))
        }
    }

    /// A page an answer points to, as Docs' page block shows it.
    private static func page(_ page: AnswerPage) -> (path: String, page: DocPage) {
        (page.path, DocPage(doc: DocID(page.page) ?? DocID(rawValue: UUID()), title: page.title, preview: page.preview))
    }

    /// A mention as CardUI shows it, on its corner the catalog's icon of its result's service.
    private func mention(_ mention: AnswerMention) -> Mention {
        let conversation = mention.conversation.flatMap { place in
            Mention.Conversation.Kind(rawValue: place.kind).map { Mention.Conversation(id: place.id.description, kind: $0) }
        }
        let doc = mention.doc.map { Mention.Doc(path: $0.path, page: $0.page, block: $0.block, preview: $0.preview) }
        // A topic, group or page says what it is where it says nothing of where it's from.
        let source = !mention.source.isEmpty ? mention.source
            : conversation?.kind == .topic ? "话题" : conversation?.kind == .group ? "群聊" : doc != nil ? "文档" : ""
        // Media were a kind of their own once: a file now.
        let kind = mention.kind == "media" ? "file" : mention.kind
        let service = ResultIDs.tool(of: mention.from).flatMap(service(of:))
        return Mention(
            kind: Mention.Kind(rawValue: kind) ?? .note,
            source: source,
            date: mention.date,
            end: mention.end,
            title: mention.title,
            quote: mention.quote,
            image: mention.image.flatMap(URL.init(string:)),
            url: mention.url.flatMap(URL.init(string:)),
            badge: icon(service?.icon),
            conversation: conversation,
            doc: doc,
            subtitle: mention.subtitle,
            value: mention.value,
            mark: mention.mark,
            tags: mention.tags,
            facts: mention.facts?.map { Mention.Fact(name: $0.name, value: $0.value) },
            pieces: mention.pieces?.map { Mention.Piece(field: $0.field, component: $0.component) },
            view: mention.view,
            data: mention.data.map(Self.card),
            templates: mention.templates
        )
    }

    /// The service a tool is of, as the catalog has it: a service's tools are named
    /// `<service>_<operation>`; the kernel's own (read_page) by an operation of its service.
    private func service(of tool: String) -> ServiceSummary? {
        let services = index?.services ?? []
        let named = services.filter { tool.hasPrefix($0.id.rawValue + "_") }
        if let longest = named.max(by: { $0.id.rawValue.count < $1.id.rawValue.count }) { return longest }
        return services.first { details[$0.id]?.operations.contains { $0.id.rawValue == tool } == true }
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

    /// The session kept as a file (a demo signed ad hoc has no Keychain of its own): beside
    /// the device's key, or on the Mac in Floo Helper's home, which it shares.
    static func auth() -> SupabaseAuth {
        #if targetEnvironment(macCatalyst)
        let folder = FlooHelper.secrets
        #else
        let folder = URL.demoSupport.appending(path: "floo-online", directoryHint: .isDirectory)
        #endif
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

/// Values kept as files under a folder, by name: what was read once, read from here next launch.
struct Kept {
    let folder: URL

    func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        // try?: none kept, or one from an older shape: read from the server again
        (try? Data(contentsOf: folder.appending(path: "\(name).json"))).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    func write<T: Encodable>(_ value: T, _ name: String) {
        // try?: not kept, it's read from the server again next launch
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: folder.appending(path: "\(name).json"), options: .atomic)
    }
}
