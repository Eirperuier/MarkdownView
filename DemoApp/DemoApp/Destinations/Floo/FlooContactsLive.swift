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
    /// Reads it all again from the server, showing each part as it comes: the services and
    /// which are followed first, then where each can come from, a few at a time, then what
    /// each is doing and has sent, then the settings files.
    func load() async {
        guard let live, let client = live.server else { return }
        guard let directory = await live.directory() else {
            show("没读到服务目录")
            return
        }
        let entries = directory.services.filter { !$0.hidden && !$0.hosts.isEmpty }
        if services.isEmpty { services = entries.map { Self.service($0) } }
        // try?: each part not read now stays as it was, read again on the next load
        if let conversations = try? await client.dialogs() {
            dialogs = Dictionary(conversations.compactMap { dialog in
                if case .service(let id) = dialog.conversation.kind { (id.rawValue, dialog) } else { nil }
            }) { first, _ in first }
            refollow()
        }
        services = entries.map { Self.service($0) }

        // Where your services stand: your devices once, then the services you have a page at a
        // time; nothing comes when nothing changed since the last read. A service you don't
        // have is looked at when its page opens (`look`).
        if let read = await readStandings(client) {
            standingsRevision = read.revision
            deviceStandings = read.devices
            standings = Dictionary(read.services.map { ($0.service, $0) }) { first, _ in first }
            devices = devices(from: read.devices)
            for entry in entries {
                found[entry.id.rawValue] = sources(entry, standings[entry.id])
            }
            refollow()
        }

        if let feed = try? await client.feed(limit: 100) {  // try?: as above
            pushes = feed
            refollow()
        }
        for (id, dialog) in dialogs where following[id] != nil {
            guard case .service(let service) = dialog.conversation.kind,
                  let found = try? await client.watches(in: dialog.conversation.id) else { continue }  // try?: as above
            watches[id] = found.filter { $0.agent == .agent(.service(service), of: dialog.conversation.owner) }
            refollow()
        }
        await loadSettings()
    }

    /// The standings since `standingsRevision`, all their pages; nil when nothing changed or
    /// they weren't read.
    private func readStandings(_ client: FlooClient) async -> ServiceStandings? {
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

    /// A service's page opened: where it can come from, read now when it isn't one of yours.
    func look(_ service: FlooService) async {
        guard let client = live?.server, let id = try? ServiceID(service.id),  // try?: not a name
              standings[id] == nil, let entry = await live?.directory()?.services.first(where: { $0.id == id }),
              let read = try? await client.standing(of: id) else { return }  // try?: read again next time it opens
        deviceStandings = read.devices
        if let standing = read.services.first { standings[id] = standing }
        found[service.id] = sources(entry, standings[id])
    }

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
            entry.pushes = pushes.filter { $0.conversation.kind == .service(standing.service) }.compactMap(Self.push)
            entry.doing = (watches[id] ?? []).map(Self.doing)
            if let dialog = dialogs[id] {
                entry.quiet = dialog.settings?.notifications.mutedUntil.map { $0 > .now } ?? false
                entry.pinned = dialog.settings?.pinnedAt != nil
            }
            following[id] = entry
        }
        self.following = following
        asked = asked.mapValues { $0.subtracting(following.values.flatMap(\.devices)) }.filter { !$0.value.isEmpty }
    }

    /// While the pages are open: read again now and then, as devices come and go; sooner
    /// while a device was asked to set something up.
    func follow() async {
        while !Task.isCancelled {
            await load()
            guard (try? await Task.sleep(for: .seconds(asked.isEmpty ? 15 : 4))) != nil else { return }  // try?: cancelled, done
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

    /// No longer followed, anywhere: what it took on ends; its conversation and pushes stay.
    func disconnect(_ service: FlooService) async {
        guard let client = live?.server, let id = try? ServiceID(service.id) else { return }  // try?: not a name
        do {
            _ = try await client.disconnect(id)
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
            _ = try await client.change(change, of: dialog.conversation.id)
        } catch {
            show("没改成：\(error)")
        }
        await load()
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

    /// A service as the pages show it: the catalog's words, the operations with their
    /// effects and the hooks from the exported catalog where it has it.
    private static func service(_ entry: ServiceDirectory.Entry) -> FlooService {
        let given = entry.presentation
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
        let exported = FlooService.named(entry.id.rawValue)
        let operations = exported?.operations
            ?? entry.operations.filter { !$0.hidden }.map { FlooService.Operation(title: $0.title, effect: "unknown") }
        return FlooService(id: entry.id.rawValue, presentation: presentation, operations: operations, hooks: exported?.hooks ?? [])
    }

    /// Where it can come from, from its standing: a cloud account when the cloud hosts it,
    /// and each device's providers with what they need.
    private func sources(_ entry: ServiceDirectory.Entry, _ standing: ServiceStanding?) -> FlooServiceSources {
        var sources = FlooServiceSources()
        if entry.hosts.contains(.cloud) {
            sources.account = entry.presentation.developer ?? entry.presentation.name
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
    private static func needs(_ requirements: [Requirement]) -> String? {
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
        let until = watch.until.map { "，到 \(Self.day($0.date)) 为止" } ?? ""
        return FlooDoing(text: watch.why ?? watch.name ?? watch.id, asked: what + until)
    }

    /// A push of its conversation: its words, fences left out.
    private static func push(_ item: FeedItem) -> FlooPush? {
        let text = item.blocks.compactMap { block -> String? in
            if case .text(let words) = block.content { words } else { nil }
        }.joined(separator: "\n")
        let plain = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        let date = item.message.createdAt.date
        return FlooPush(day: day(date), time: date.formatted(.dateTime.hour().minute()), text: plain)
    }

    private static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private static func ago(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
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
