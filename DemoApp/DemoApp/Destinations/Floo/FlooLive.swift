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
        let live = FlooLive(demo: demo, backend: backend)
        demo.goLive(live)
        try await live.run()
    }

    private let demo: FlooDemo
    private let backend: Backend
    private var session: ConversationSession?
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
        do {
            let folder = URL.demoSupport.appending(path: backend.folder, directoryHint: .isDirectory)
            let device: DeviceCredentials
            #if targetEnvironment(macCatalyst)
            // On the Mac it's one device with Floo Helper, this Mac: its key, kept in the Helper's
            // home, signs for both, and it's named and described as the Mac it is.
            let identity: DeviceIdentity? = backend.lab ? nil : DeviceIdentity(store: try FileSecrets(folder: FlooHelper.secrets))
            #else
            let identity: DeviceIdentity? = nil
            #endif
            if let identity {
                device = try await identity.registered(for: backend.account, with: base, appVersion: Self.helperVersion)
            } else {
                device = try await DeviceIdentity(store: FileSecrets(folder: folder)).registered(
                    for: backend.account,
                    with: base,
                    platform: .iPad,
                    appVersion: "demo",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString
                )
            }
            self.client = base.with(device: device)
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
            // The lab's people have their own zone; here it's this device's.
            if !backend.lab { following.append(Task { await followTimeZone(client) }) }
        }
        if backend.lab { Task { await loadCardModel() } }
        Task { await loadIndex() }
        let listing = Task { await keepListing() }
        defer { listing.cancel() }
        current = .main(of: backend.account)
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
            for await update in await session.updates() {
                guard !Task.isCancelled else { return }
                last = update.replica
                show(update)
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

    /// A topic on a message of the conversation shown, gone to once it's open.
    func openTopic(on number: Int64, title: String?) {
        guard let client, let current else { return }
        let topic = TopicOpen(id: .generate(), origin: MessageRef(conversation: current, number: number),
                              title: title, listed: title != nil)
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

    /// Whether the list shows the row: not agents' own conversations; a topic when it's listed
    /// or it's the one you're in; the rest unless archived.
    private func shows(_ dialog: Dialog) -> Bool {
        switch dialog.conversation.kind {
        case .agents, .helper: false
        case .topic(_, let listed): listed || dialog.conversation.id == current
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
            return FlooPlace(id: id.description, title: id == .main(of: backend.account) ? "floo" : "对话", kind: .group)
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
            kind = .group
            title = info.title ?? "群聊"
        case .topic(_, let listed):
            kind = .topic(listed: listed)
            title = info.title ?? "评论"
        case .service(let service):
            kind = .service
            title = info.title ?? agent(.service(service)).name
        case .agents, .helper:
            kind = .service
            title = info.title ?? ""
        }
        return FlooPlace(id: info.id.description, title: title, kind: kind, unread: unread)
    }

    /// The one you're in, and where a topic you're in hangs, to go back to; an unlisted topic
    /// shows in the list while you're in it.
    private func showPlaces() {
        let left = listedCurrent
        listedCurrent = current
        for id in Set([left, current].compactMap { $0 }) { reposition(id, was: dialogs[id]) }
        var origin: FlooPlace?
        if let current, case .topic(let from, _)? = dialogs[current]?.conversation.kind {
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
        if case .topic(let origin, _)? = dialog?.conversation.kind { origin.number } else { nil }
    }

    /// The row hung where it is now: under its message if it's a topic on the shown
    /// conversation, and off the message it was under.
    private func hang(_ id: ConversationID) {
        let was = hangs[id]
        var now: Int64?
        if let dialog = dialogs[id], case .topic(let origin, _) = dialog.conversation.kind, origin.conversation == current {
            now = origin.number
        }
        guard was != nil || now != nil else { return }
        if let was { hung[was]?.removeAll { $0.id == id.description } }
        hangs[id] = now
        if let now { hung[now, default: []].append(place(id)) }
        for number in Set([was, now].compactMap { $0 }) { showTopics(on: number) }
    }

    /// The topics on the shown message holding `number`: those hung on any of its parts.
    private func showTopics(on number: Int64) {
        guard let message = messages[number] else { return }
        let numbers = parts[ObjectIdentifier(message)] ?? [number]
        demo.setTopics(message, numbers.flatMap { hung[$0] ?? [] })
    }

    // MARK: Sending

    func send(_ text: String) {
        guard let session else { return }
        // try?: one that doesn't go shows so in the conversation, to send again.
        Task { _ = try? await session.send(MessageSend(id: .generate(), text: text)) }
    }

    func choose(message: Int64, fence: Int, item: Int, option: FlooOption) {
        guard let session else { return }
        let send = MessageSend(
            id: .generate(),
            text: option.send ?? option.label,
            choosing: ChoiceRef(message: message, fence: fence, item: item)
        )
        Task { _ = try? await session.send(send) }  // try?: as `send`
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
        Task { _ = try? await session.send(send) }  // try?: as `send`
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
            Task {
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
        if changes.all || !changes.removed.isEmpty || changes.parts.contains(.members) { return show(replica) }
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
        for number in numbers.sorted() where !seen.contains(number) {
            guard let at = replica.position(of: number) else { continue }
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
            showPerson(first, blocks: replica.blocks(of: first.number), agentsRead: agentsRead)
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

    /// How an agent's message stands to what came before it (§19.2): the message it replies to
    /// (`replyTo`, messaging.md §3.12), and the errand it goes on with — in the agent's words
    /// when it gave some, else by what it points at.
    private func marks(of parts: [MessageInfo], _ replica: ConversationReplica) -> [FlooMark] {
        let label = parts.lazy.flatMap { replica.blocks(of: $0.number) }
            .compactMap { if case .aboutLabel(let label) = $0.content { label } else { nil } }.first
        var marks: [FlooMark] = []
        if let number = parts.lazy.reversed().compactMap(\.replyTo).first {
            marks.append(replying(to: number, replica))
        }
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
            if let number = about.message, marks.isEmpty { marks.append(replying(to: number, replica)) }
        }
        return marks
    }

    /// "回复 X「…」": who wrote the message replied to and how it begins.
    private func replying(to number: Int64, _ replica: ConversationReplica) -> FlooMark {
        guard let info = replica.message(number) else { return .replying("回复一条更早的消息", row: nil) }
        let words = replica.blocks(of: number)
            .compactMap { if case .text(let text) = $0.content, $0.audience != .model { text } else { nil } }
            .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let begins = words.count > 18 ? "\(words.prefix(18))…" : words
        let who = whose(number, replica) ?? ""
        return .replying(begins.isEmpty ? "回复\(who)的消息" : "回复\(who)「\(begins)」", row: row(info.number))
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
            let quote = item.message.answering.flatMap { answer in
                replica.asks[answer.ask].flatMap { $0.items.indices.contains(answer.item) ? "回答「\($0.items[answer.item].title)」" : nil }
            }
            let shown = demo.say(.me, item.message.text, receipt: receipt, quote: quote)
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
        // Sent from here: the backend's message is the one already shown.
        if said[info.number] == nil, let mine = outgoing.removeValue(forKey: info.id) {
            said[info.number] = mine
            demo.retries[demo.row(of: mine)] = nil
        }
        // Someone else's, in a group: by name, with no receipt of yours.
        let mine = info.author.account == backend.account
        if let said = said[info.number] {
            if mine, said.receipt != receipt { demo.mark(said, receipt) }
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
        if mine {
            said[info.number] = demo.say(.me, text, receipt: receipt, quote: quote)
        } else {
            let theirs = demo.say(.person(names[info.author.account] ?? "成员"), text, quote: quote)
            said[info.number] = theirs
            saidBy[info.author.account, default: []].append(theirs)
        }
    }

    /// An agent's message, from the backend's messages it's made of: one, or a run's work
    /// overtaken and its words after.
    private func showAgent(_ parts: [MessageInfo], replica: ConversationReplica) {
        guard let first = parts.first, let last = parts.last, case .agent(let id) = first.author.actor else { return }
        let owner = first.author.account
        let message = parts.lazy.compactMap { self.messages[$0.number] }.first ?? {
            let message = demo.begin(agent(id, of: owner), at: Self.time(first.createdAt))
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
        // What was asked on it and the topics hung on it.
        let numbers = Set(parts.map(\.number))
        let asks = replica.asks.values.filter { $0.message.map(numbers.contains) == true }.sorted { $0.pts < $1.pts }
        demo.setAsks(message, asks.compactMap { ask in ask.agent.actor.agent.map { card(ask, agent($0), replica) } })
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

    /// The person's time zone, as this device has it, and again whenever it changes: the
    /// agents tell the time where they are by it.
    private func followTimeZone(_ client: FlooClient) async {
        var changes = NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange).makeAsyncIterator()
        repeat {
            do { try await client.setTimeZone(TimeZone.autoupdatingCurrent.identifier) } catch {
                demo.catchUp("时区没告诉服务器：\(error)")
            }
        } while await changes.next() != nil
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

    private static func mention(_ mention: AnswerMention) -> Mention {
        let conversation = mention.conversation.flatMap { place in
            Mention.Conversation.Kind(rawValue: place.kind).map { Mention.Conversation(id: place.id.description, kind: $0) }
        }
        let doc = mention.doc.map { Mention.Doc(path: $0.path, page: $0.page, block: $0.block, preview: $0.preview) }
        // A topic, group or page says what it is where it says nothing of where it's from.
        let source = !mention.source.isEmpty ? mention.source
            : conversation?.kind == .topic ? "话题" : conversation?.kind == .group ? "群聊" : doc != nil ? "文档" : ""
        return Mention(
            kind: Mention.Kind(rawValue: mention.kind) ?? .note,
            source: source,
            date: mention.date.flatMap(date),
            end: mention.end.flatMap(date),
            title: mention.title,
            quote: mention.quote,
            image: mention.image.flatMap(URL.init(string:)),
            url: mention.url.flatMap(URL.init(string:)),
            conversation: conversation,
            doc: doc
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
