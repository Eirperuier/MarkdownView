//
//  FlooContactsLive.swift
//  DemoApp
//
//  The services pages on the floo server instead of the script: the same pages (FlooContacts,
//  FlooContactPage, FlooSettings), each part read from what the server keeps (floo
//  docs/app.md 3.2) — the catalog, your devices and each service's standing (the hosts that
//  provide it, the cloud and your devices, their requirements, and where it's connected),
//  the watches in its conversation, the feed, the conversation's settings, the providers'
//  settings files — and each action done there: signing in in the browser, Floo Helper
//  asking for what this Mac needs, another device asked to set it up, connecting and
//  disconnecting, muting and pinning.
//

import Foundation
import AppleDeviceImages
import SwiftUI
import Wire
import TransportKit
import ServiceKit

extension FlooContactsDemo {
    /// Reads it all again, showing each part as it comes: the services and which are followed
    /// first (their conversations as the chat's list has them), then where each can come from,
    /// a few at a time, then what each is doing and has sent, then the settings files.
    func load() async {
        guard let live, let client = live.server else { return }
        guard let directory = await live.directory() else {
            show("没读到服务目录")
            return
        }
        let entries = directory.filter { !$0.hidden && !$0.hosts.isEmpty }
        // A page opened before shows its detail as the catalog has it now, read again only
        // when the index says it changed: the catalog is where a service's names are.
        for entry in entries where opened[entry.id.rawValue] != nil {
            if let detail = await live.detail(entry.id) { opened[entry.id.rawValue] = Self.service(detail, standings[entry.id]) }
        }
        if services.isEmpty { services = entries.map { opened[$0.id.rawValue] ?? Self.service($0) } }
        // The services' conversations as the chat's list has them; changes come by `follow`.
        dialogs = Dictionary(uniqueKeysWithValues: live.serviceDialogs().map { ($0.key.rawValue, $0.value) })
        refollow()
        services = entries.map { opened[$0.id.rawValue] ?? Self.service($0) }

        await readStandings(client, entries)

        for (id, dialog) in dialogs where following[id] != nil {
            guard case .service(let service) = dialog.conversation.kind,
                  let found = try? await client.watches(in: dialog.conversation.id) else { continue }  // try?: read again on the next load
            watches[id] = found.filter { $0.agent == .agent(.service(service), of: dialog.conversation.owner) }
            refollow()
        }
        await loadSettings()
    }

    /// Where your services stand: your devices once, then the services you have a page at a
    /// time; nothing comes when nothing changed since the last read. A service you don't
    /// have is looked at when its page opens (`look`).
    private func readStandings(_ client: FlooClient, _ entries: [ServiceSummary]) async {
        guard let read = await standingsRead(client) else { return }
        standingsRevision = read.revision
        deviceStandings = read.devices
        standings = Dictionary(read.services.map { ($0.service, $0) }) { first, _ in first }
        devices = devices(from: read.devices)
        for entry in entries {
            found[entry.id.rawValue] = sources(entry, standings[entry.id])
        }
        refollow()
    }

    /// The standings since `standingsRevision`, all their pages; nil when nothing changed or
    /// they weren't read.
    private func standingsRead(_ client: FlooClient) async -> ServiceStandings? {
        do {
            guard var read = try await client.standings(revision: standingsRevision) else { return nil }
            var page = read
            while page.more, let last = page.services.last?.service {
                guard let next = try await client.standings(after: last) else { break }
                read.services += next.services
                page = next
            }
            return read
        } catch {
            return nil
        }
    }

    /// A service's page opened: all it says of itself (its detail, read once and kept), what
    /// its providers do of it and where it can come from (its own standing: a list's has
    /// no operations), read now when it hasn't been.
    func look(_ service: FlooService) async {
        guard let live, let id = try? ServiceID(service.id),  // try?: not a name
              let entry = await live.directory()?.first(where: { $0.id == id }) else { return }
        if standings[id]?.operations == nil, let client = live.server, let read = try? await client.standing(of: id) {  // try?: read again next time it opens
            deviceStandings = read.devices
            if let standing = read.services.first { standings[id] = standing }
        }
        if let detail = await live.detail(id) {
            let shown = Self.service(detail, standings[id])
            opened[service.id] = shown
            if let at = services.firstIndex(where: { $0.id == service.id }) { services[at] = shown }
        }
        found[service.id] = sources(entry, standings[id])
        // Its album: its agent's posts, newest first.
        if let client = live.server,
           let page = try? await client.feed(from: Participant.agent(.service(id), of: live.account).description, limit: Self.albumPosts) {  // try?: read again next time it opens
            pushes[id] = page.posts
            refollow()
        }
    }

    /// The posts its album shows.
    private static let albumPosts = 20

    /// What's followed and how it stands, from what was read so far.
    private func refollow() {
        var following: [String: FlooFollowing] = [:]
        for standing in standings.values where standing.connected {
            let id = standing.service.rawValue
            let cloud = standing.hosts.filter { $0.host == .cloud && $0.connected }
            var entry = FlooFollowing()
            entry.account = cloud.compactMap(\.account).first
            entry.expired = cloud.contains { $0.requirements.contains { $0.state == .expired } }
            // The devices it's connected on and works on now.
            entry.devices = Set(standing.hosts.filter { $0.connected && Self.provides($0) }.compactMap { $0.host.device?.description })
            entry.asked = (asked[id] ?? []).subtracting(entry.devices)
            entry.pushes = (pushes[standing.service] ?? []).compactMap(push)
            entry.doing = (watches[id] ?? []).map(Self.doing)
            if let dialog = dialogs[id] {
                entry.quiet = dialog.settings?.notifications.mutedUntil.map { $0.date > FlooClock.now } ?? false
                entry.pinned = dialog.settings?.pinnedAt != nil
            }
            following[id] = entry
        }
        self.following = following
        asked = asked.mapValues { $0.subtracting(following.values.flatMap(\.devices)) }.filter { !$0.value.isEmpty }
    }

    /// While the pages are open: all read once, then the services' conversations as they
    /// change, from the chat's list and the account's one stream it follows (FlooLive), not
    /// listed again; a message in one (a watch its agent set) reads its watches. Only while a device was asked to set something up are the
    /// standings asked again (no stream says when it's done), an answer only once they changed.
    func follow() async {
        guard let live else { return }
        let rows = live.serviceRows()
        await load()
        let waiting = Task { await waitForAsked() }
        defer { waiting.cancel() }
        for await row in rows {
            await take(row)
        }
    }

    /// A service's conversation as it is now: muted, pinned; with a message since, what its
    /// agent watches.
    private func take(_ row: FlooLive.ServiceRow) async {
        let id = row.service.rawValue
        let old = dialogs[id]
        dialogs[id] = row.dialog
        refollow()
        guard let client = live?.server, let old, let dialog = row.dialog, dialog.activeAt != old.activeAt else { return }
        // try?: not read now, read again on the next change or load
        if following[id] != nil, let found = try? await client.watches(in: dialog.conversation.id) {
            watches[id] = found.filter { $0.agent == .agent(.service(row.service), of: dialog.conversation.owner) }
        }
        refollow()
    }

    /// While a device was asked to set a service up: where your services stand, asked every
    /// few seconds until it provides it (`refollow` ends the asking).
    private func waitForAsked() async {
        while !Task.isCancelled {
            guard (try? await Task.sleep(for: .seconds(4))) != nil else { return }  // try?: cancelled, done
            guard !asked.isEmpty, let live, let client = live.server, let directory = await live.directory() else { continue }
            let following = Set(self.following.keys)
            await readStandings(client, directory.filter { !$0.hidden && !$0.hosts.isEmpty })
            if Set(self.following.keys) != following { await loadSettings() }
        }
    }

    // MARK: Doing

    /// Signs in to its account in the browser; connected once that's done.
    func signIn(_ service: FlooService) async {
        guard let live, let id = try? ServiceID(service.id) else { return }  // try?: not a name, none to sign in to
        do {
            try await live.connect(id)
            await load()
        } catch {
            show("没连上：\(error)")
        }
    }

    /// Adds one the server runs itself, connected in the cloud there and then.
    func addInCloud(_ service: FlooService) async {
        guard let client = live?.server, let id = try? ServiceID(service.id) else { return }  // try?: not a name, none to add
        do {
            try await client.add(id)
            // One added before adding connected it (by an agent, say) is connected now.
            _ = try await client.connect(id, on: .cloud)
            await load()
        } catch {
            show("没添加上：\(error)")
        }
    }

    /// Has it set up on this device: Floo Helper asks for what this Mac needs, and connects it
    /// here once it can work.
    func allowHere(_ service: FlooService) async {
        #if targetEnvironment(macCatalyst)
        await FlooHelper.allow([service.id])
        #endif
        await load()
    }

    /// Asks `device`, online, to open its settings for it (`SetupRequest`); that device
    /// connects it there once it's set up.
    func setUpLive(_ service: FlooService, on device: FlooDevice) async {
        guard let client = live?.server, let id = try? ServiceID(service.id),  // try?: not a name
              let target = DeviceID(device.id) else { return }
        if device.id == thisDevice { return await allowHere(service) }
        do {
            _ = try await client.askToSetUp(id, on: target)
            asked[service.id, default: []].insert(device.id)
            show("已在\(device.name)上打开「\(service.name)」的设置")
            await load()
        } catch {
            show("没能在\(device.name)上打开：\(error)")
        }
    }

    /// No longer on `device`: the others it's connected on go on; its conversation stays.
    func disconnect(_ service: FlooService, on device: FlooDevice) async {
        guard let client = live?.server, let id = try? ServiceID(service.id),  // try?: not a name
              let target = DeviceID(device.id) else { return }
        do {
            _ = try await client.disconnect(id, on: .device(target))
        } catch {
            show("没断开：\(error)")
        }
        await load()
    }

    /// No longer followed, anywhere: removed, so what it took on ends; its conversation and
    /// pushes stay.
    func disconnect(_ service: FlooService) async {
        guard let client = live?.server, let id = try? ServiceID(service.id) else { return }  // try?: not a name
        do {
            try await client.remove(id)
        } catch {
            show("没断开：\(error)")
        }
        await load()
    }

    /// Its conversation's notifications muted, or not; pinned, or not.
    func change(_ service: FlooService, quiet: Bool? = nil, pinned: Bool? = nil) async {
        guard let client = live?.server, let dialog = dialogs[service.id] else { return }
        let change = DialogSettingsChange(
            pinned: pinned,
            notifications: quiet.map { NotifySettings(mutedUntil: $0 ? NotifySettings.forever : nil) }
        )
        do {
            // The row comes back changed by the account's stream (`follow`).
            _ = try await client.change(change, of: dialog.conversation.id)
        } catch {
            show("没改成：\(error)")
        }
    }

    // MARK: Permissions

    /// The approval policy as the cloud has it, from this device's mailbox (floo
    /// agent-kernel.md §7.3).
    func readApprovals() async {
        guard let client = live?.server else { return }
        do {
            take(try await Self.policy(client))
        } catch {
            show("没读到权限：\(error)")
        }
    }

    /// `service` set apart from the account's approval mode, or put back under it (nil). The
    /// rest of the policy — the mode, what was allowed from now on, the other services — is
    /// read from the cloud first and kept, as the App's DeviceOperations sets it.
    func setApproval(_ service: FlooService, _ approval: ServiceApproval?) async {
        guard let live, let client = live.server else {
            approvals[service.id] = approval
            return
        }
        guard let id = try? ServiceID(service.id) else { return }  // try?: not a name, nothing to set
        do {
            let now = try await Self.policy(client)
            let policy = ApprovalPolicy(
                account: live.account,
                mode: now?.mode ?? .open,
                grants: now?.grants ?? [],
                services: (now?.services ?? []).filter { $0.service != id } + (approval.map { [$0] } ?? []),
                at: .now
            )
            try await client.setApprovalPolicy(policy)
            take(policy)
        } catch {
            show("没改成：\(error)")
        }
    }

    // MARK: Name and picture

    /// What the person calls `service`'s agent from now on; empty, its catalog name again
    /// (floo docs/context-format.md §3.5). Its id stays what it is.
    func rename(_ service: FlooService, to name: String) async {
        guard let id = try? ServiceID(service.id) else { return }  // try?: not a name, nothing to rename
        do {
            try await FlooAgentLooks.shared.rename(.service(id), to: name, catalogName: service.catalogName, on: live?.server)
        } catch {
            show("没改成：\(error)")
        }
    }

    /// Shows `service`'s agent by `image`; nil, its icon again.
    func setPicture(_ image: UIImage?, of service: FlooService) async {
        guard let id = try? ServiceID(service.id) else { return }  // try?: not a name, nothing to set
        do {
            try await FlooAgentLooks.shared.setPicture(image, of: .service(id), on: live?.server)
        } catch {
            show("没换成：\(error)")
        }
    }

    /// The policy the first mailbox brings; nil when none was chosen.
    private static func policy(_ client: FlooClient) async throws -> ApprovalPolicy? {
        for try await mailbox in client.mailbox() { return mailbox.policy }
        return nil
    }

    private func take(_ policy: ApprovalPolicy?) {
        approvalMode = policy?.mode ?? .open
        approvals = Dictionary((policy?.services ?? []).map { ($0.service.rawValue, $0) }) { _, last in last }
    }

    /// Goes to its conversation in the chat.
    func message(_ service: FlooService) {
        guard let live, let id = try? ServiceID(service.id) else { return }  // try?: not a name
        live.openService(id)
        leave?()
    }

    // MARK: Settings

    /// The providers' settings files of the services followed that have a settings page.
    private func loadSettings() async {
        guard let client = live?.server else { return }
        var files: [String: [String: [String: FlooJSON]]] = [:]
        var providers: [String: [String: ProviderID]] = [:]
        for id in following.keys where FlooSettingsFormat.all[id] != nil {
            guard let service = try? ServiceID(id), let found = try? await client.settings(of: service) else { continue }  // try?: none shown
            for file in found {
                let device = file.device?.description ?? "cloud"
                files[id, default: [:]][device] = Self.json(file.settings).fields
                providers[id, default: [:]][device] = file.provider
            }
        }
        settings = files
        settingsProviders = providers
    }

    /// One key of a provider's file written on the server; nil removes it.
    func write(_ service: FlooService, on device: FlooDevice, _ key: String, _ value: FlooJSON?) {
        guard let client = live?.server, let id = try? ServiceID(service.id),  // try?: not a name
              let provider = settingsProviders[service.id]?[device.id] else { return }
        let change = ProviderSettingsChange(
            device: DeviceID(device.id),
            provider: provider,
            set: value.map { [key: Self.value($0)] } ?? [:],
            remove: value == nil ? [key] : []
        )
        Task {
            do {
                _ = try await client.change(change, of: id)
            } catch {
                show("没存上：\(error)")
                await load()
            }
        }
    }

    // MARK: From the server's words

    /// Your devices, from the standings, each by its name: this one first (on the Mac, Floo
    /// Helper's), then the others that are online now or provide anything; the demo's own
    /// device, which provides nothing, left out.
    private func devices(from standings: [DeviceStanding]) -> [FlooDevice] {
        let own = live?.ownDevice?.description
        let providing = Set(self.standings.values.flatMap(\.hosts).filter { $0.provider != nil }.compactMap { $0.host.device?.description })
        let result = standings.compactMap { device -> FlooDevice? in
            let id = device.device.description
            // The demo's own device is left out, unless it's this Mac's (one device with Floo Helper).
            guard id != own || id == thisDevice, device.online || providing.contains(id) || id == thisDevice else { return nil }
            let (kind, symbol): (FlooDevice.Kind, String) = switch device.platform {
            case .mac: (.mac, "laptopcomputer")
            case .iPhone: (.iPhone, "iphone")
            case .iPad: (.iPad, "ipad")
            case .watch: (.iPhone, "applewatch")
            }
            return FlooDevice(
                id: id,
                name: device.name,
                kind: kind,
                symbol: symbol,
                product: device.model.map { AppleDevice($0, color: device.color, osVersion: Self.version(device.osVersion)) },
                online: device.online,
                lastSeen: device.online ? nil : device.lastSeen.map { Self.ago($0.date) }
            )
        }
        return result.sorted { ($0.id == thisDevice ? 0 : 1) < ($1.id == thisDevice ? 0 : 1) }
    }

    /// The version number in what a device says of its system ("iOS 26.1", "27.0").
    private static func version(_ said: String) -> String? {
        said.firstMatch(of: /\d+(\.\d+)*/).map { String($0.output.0) }
    }

    /// A service as the list shows it, from the catalog's index: its names and short words;
    /// what it does once its page is opened (its detail), or from the exported catalog.
    private static func service(_ entry: ServiceSummary) -> FlooService {
        let presentation = FlooService.Presentation(
            name: entry.name,
            shortDescription: entry.shortDescription,
            localized: entry.localized.mapValues { FlooService.Text(name: $0.name, shortDescription: $0.shortDescription) },
            icon: entry.icon,
            color: entry.color,
            category: entry.category
        )
        let exported = FlooService.named(entry.id.rawValue)
        return FlooService(id: entry.id.rawValue, presentation: presentation, operations: exported?.operations ?? [],
                           hooks: exported?.hooks ?? [])
    }

    /// A service as its page shows it, from its detail: all its words, what it does with each
    /// operation's effect, what it tells of; those two from its standing when its providers
    /// reported them (a service devices provide has none in the catalog).
    private static func service(_ detail: ServiceDetail, _ standing: ServiceStanding?) -> FlooService {
        let given = detail.presentation
        let presentation = FlooService.Presentation(
            name: given.name,
            shortDescription: given.shortDescription,
            description: given.description,
            prompts: given.prompts,
            localized: given.localized.mapValues { text in
                FlooService.Text(name: text.name, shortDescription: text.shortDescription,
                                 description: text.description, prompts: text.prompts)
            },
            developer: given.developer,
            website: given.website,
            privacyPolicy: given.privacyPolicy,
            termsOfService: given.termsOfService,
            icon: given.icon,
            color: given.color,
            category: given.category
        )
        let zh = given.localized["zh-Hans"]?.operations ?? [:]
        let operations = (standing?.operations ?? detail.operations).filter { !$0.hidden }.map {
            FlooService.Operation(title: zh[$0.id.rawValue]?.title ?? $0.title, effect: $0.effect?.rawValue ?? "unknown")
        }
        return FlooService(id: detail.id.rawValue, presentation: presentation, operations: operations,
                           hooks: (standing?.hooks ?? detail.hooks).map { FlooService.Hook(summary: $0.summary) })
    }

    /// Where it can come from, from its standing: a cloud account when the cloud hosts it,
    /// and each device's providers with what they need.
    private func sources(_ entry: ServiceSummary, _ standing: ServiceStanding?) -> FlooServiceSources {
        var sources = FlooServiceSources()
        if entry.hosts.contains(.cloud) {
            if entry.signIn {
                sources.account = opened[entry.id.rawValue]?.presentation.developer ?? entry.name
            } else {
                sources.cloud = true
            }
        }
        let platforms = Dictionary(deviceStandings.map { ($0.device, $0.platform) }) { first, _ in first }
        var byDevice: [String: String] = [:]
        for host in standing?.hosts ?? [] where host.provider != nil {
            guard let device = host.host.device, let platform = platforms[device] else { continue }
            let kind: FlooDevice.Kind = switch platform {
            case .mac: .mac
            case .iPad: .iPad
            default: .iPhone
            }
            let required = host.requirements.filter { !$0.optional }
            if sources.devices[kind] == nil {
                sources.devices[kind] = Self.needs(required.map(\.requirement)) ?? "启用"
            }
            byDevice[device.description] = Self.needs(required.filter { $0.state != .met }.map(\.requirement)) ?? ""
        }
        sources.byDevice = byDevice
        return sources
    }

    /// All its required requirements met there.
    private static func provides(_ host: HostStanding) -> Bool {
        host.provider != nil && host.requirements.allSatisfy { $0.optional || $0.state == .met }
    }

    /// What a person does to meet `requirements`, as one phrase; nil for none.
    static func needs(_ requirements: [Requirement]) -> String? {
        var said: [String] = []
        for requirement in requirements {
            let phrase: String? = switch requirement.kind {
            case "permission": permission(requirement.name)
            case "sign_in": "登录 \(requirement.name)"
            case "installed": "装好\(app(requirement.name))"
            case "version": "更新 \(requirement.name)"
            default: nil  // what follows from the others (a store readable once access is given)
            }
            if let phrase, !said.contains(phrase) { said.append(phrase) }
        }
        return said.isEmpty ? nil : said.joined(separator: "、")
    }

    private static func permission(_ name: String) -> String {
        if name.hasPrefix("automation:") { return "允许控制\(app(String(name.dropFirst("automation:".count))))" }
        return switch name {
        case "calendar": "允许访问日历"
        case "reminders": "允许访问提醒事项"
        case "contacts": "允许访问通讯录"
        case "photos": "允许访问照片"
        case "health": "允许读取健康数据"
        case "location": "允许访问位置"
        case "full_disk_access": "给完全磁盘访问权限"
        case "accessibility": "给辅助功能权限"
        case "screen_recording": "给录屏权限"
        default: "允许 \(name)"
        }
    }

    private static func app(_ bundle: String) -> String {
        switch bundle {
        case "com.apple.mail": "「邮件」"
        case "com.apple.MobileSMS": "「信息」"
        case "com.apple.Notes": "「备忘录」"
        case "com.apple.iCal": "「日历」"
        default: " \(bundle)"
        }
    }

    /// A watch its agent keeps, as a task: why, and what it looks at.
    private static func doing(_ watch: WatchInfo) -> FlooDoing {
        let what: String = switch watch.source {
        case .hook(let event): "有变化时就知道（\(event)）"
        case .polls(let tool, let every): "每 \(every >= 3600 ? "\(every / 3600) 小时" : "\(max(1, every / 60)) 分钟")看一次 \(tool)"
        }
        let until = watch.until.map { "，到 \(FlooDay.label($0.at.date)) 为止" } ?? ""
        return FlooDoing(text: watch.why ?? watch.name ?? watch.id, asked: what + until)
    }

    /// One of its posts in the feed (floo docs/plugins.md §6 item 9): its words, fences left
    /// out, with its first card and the first thing it points at.
    private func push(_ post: FeedPost) -> FlooPush? {
        var card: String?
        var mention: FlooMention?
        for block in post.blocks {
            switch block {
            case .card(let drawn) where card == nil:
                guard let source = drawn.source else { continue }
                let key = "feed-\(post.number)-\(drawn.fence)-\(drawn.item)"
                setCard(key, source: source, data: FlooLive.cardData(drawn.data))
                card = key
            case .mention(let found) where mention == nil:
                mention = FlooMention(symbol: FlooFeedText.symbol(found.kind), title: found.title ?? found.source, detail: found.source,
                                      shown: live?.mention(found))
            default:
                continue
            }
        }
        let words = FlooFeedText.words(post.text)
        guard !words.isEmpty || card != nil || mention != nil else { return nil }
        return FlooPush(at: post.at.date, text: words, card: card, mention: mention)
    }

    static func ago(_ date: Date) -> String {
        let minutes = Int(FlooClock.now.timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(max(1, minutes)) 分钟前" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小时前" }
        return "\(minutes / (24 * 60)) 天前"
    }

    static func json(_ value: JSONValue) -> FlooJSON {
        switch value {
        case .null: .null
        case .bool(let bool): .bool(bool)
        case .int(let number): .number(Double(number))
        case .double(let number): .number(number)
        case .string(let string): .string(string)
        case .array(let values): .array(values.map(json))
        case .object(let fields): .object(fields.mapValues(json))
        }
    }

    static func value(_ json: FlooJSON) -> JSONValue {
        switch json {
        case .null: .null
        case .bool(let bool): .bool(bool)
        case .number(let number): number.rounded() == number && abs(number) < 1e15 ? .int(Int64(number)) : .double(number)
        case .string(let string): .string(string)
        case .array(let values): .array(values.map(value))
        case .object(let fields): .object(fields.mapValues(value))
        }
    }
}
