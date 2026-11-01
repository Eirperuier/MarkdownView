//
//  FlooDevices.swift
//  DemoApp
//
//  Your devices, as floo docs/devices.md has them: each with how it is now (§6.1 — in use,
//  battery, network, time zone, where), what it can do with itself (§3.2 — its files, its
//  shell, its browser, its screen) and what it still needs for each, and for each capability
//  how far it reaches there (§8.2, the capability's settings) and when you are asked first
//  (§8.3, by agent and device, over the account's approval mode). All the floo server's:
//  opened from the chat's account menu. `-flooDevices YES` opens it once signed in;
//  `-flooDevicesPath "device:mac capability:mac:shell"` a page.
//

import AppleDeviceImages
import SwiftUI
import FlooDesign
import Wire
import TransportKit
import ServiceKit

// MARK: - What a device says

/// How a device is now, from its last state report (docs/devices.md §6.1); nil for a part it
/// hasn't said.
struct FlooDeviceState: Hashable {
    enum Use: String { case floo, unlocked, locked }
    enum Battery: String { case critical, low, half, ok }
    enum Network: String { case wifi, cellular, wired, other, none }

    var use: Use?
    var battery: Battery?
    var charging = false
    var network: Network?
    /// Metered, or Low Data Mode.
    var limited = false
    var zone: String?
    var place: String?
    /// When it last said any of it.
    var at: String?
}

/// A capability on one device, as it reported it: what it still needs there (unmet
/// requirements, in words); none reported, the device doesn't have it.
struct FlooCapabilityShown: Hashable {
    var needs: [String] = []
}

/// One capability's approval set apart from the account's (`CapabilityApproval`): for an agent
/// (nil: every agent), on a device (nil: every device).
struct FlooCapabilityRule: Hashable {
    var capability: String
    var agent: String?
    var device: String?
    var mode: ApprovalMode
    var reads = false

    /// As `ApprovalPolicy.capability(_:agent:device:)` orders them.
    var specificity: Int { (agent == nil ? 0 : 2) + (device == nil ? 0 : 1) }
}

/// What was allowed from now on for a capability: one tool's call as it was, or all of its
/// tool, for an agent, on a device.
struct FlooCapabilityGrant: Hashable, Identifiable {
    let id: String
    var capability: String
    var what: String
    var agent: String?
    var device: String?
    /// The grant itself, to take it out of the policy.
    var grant: ApprovalGrant?
}

/// An agent as the pages name it.
struct FlooAgentShown: Hashable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let tint: Color
}

// MARK: - The capabilities

/// floo's capabilities (`CapabilityDefinition.floo`) as the pages say them, and their settings'
/// keys: lists of folders or sites.
enum FlooCapabilityWords {
    struct Key: Hashable, Identifiable {
        let id: String
        let title: String
        let summary: String
        /// What one item is: a folder's path or a site.
        let item: String
        let placeholder: String
    }

    static let all = ["files", "shell", "browser", "screen"]

    static func name(_ capability: String) -> String {
        switch capability {
        case "files": "文件"
        case "shell": "命令"
        case "browser": "浏览器"
        case "screen": "屏幕"
        default: capability
        }
    }

    static func symbol(_ capability: String) -> String {
        switch capability {
        case "files": "folder"
        case "shell": "terminal"
        case "browser": "safari"
        case "screen": "macwindow"
        default: "square.dashed"
        }
    }

    static func tint(_ capability: String) -> Color {
        switch capability {
        case "files": .blue
        case "shell": .gray
        case "browser": .teal
        case "screen": .indigo
        default: .secondary
        }
    }

    /// What it lets agents do there, a line.
    static func summary(_ capability: String) -> String {
        switch capability {
        case "files": "读、写、搬这台设备上的文件"
        case "shell": "在这台设备上跑命令"
        case "browser": "用 floo 的浏览器打开网页、登录、操作"
        case "screen": "看屏幕、点按、输入"
        default: ""
        }
    }

    /// Its settings (docs/devices.md §8.2), as `CapabilityDefinition.floo` has them.
    static func keys(_ capability: String) -> [Key] {
        switch capability {
        case "files":
            [
                Key(id: "excluded", title: "不碰的文件夹", summary: "里面的文件读不到、写不了，连有没有都看不到。",
                    item: "文件夹", placeholder: "~/Documents/私人"),
                Key(id: "read_only", title: "只读的文件夹", summary: "能读，不能改、删、往里放。",
                    item: "文件夹", placeholder: "~/Pictures"),
            ]
        case "shell":
            [
                Key(id: "writable", title: "沙盒里能写的文件夹", summary: "命令在沙盒里跑时，除了它所在的文件夹和临时目录，只能写这些。",
                    item: "文件夹", placeholder: "~/Developer"),
                Key(id: "domains", title: "沙盒里能上的网站", summary: "命令在沙盒里只能连这些网站（含子域名），别的都拒。",
                    item: "网站", placeholder: "github.com"),
            ]
        default: []
        }
    }

    /// Below its settings: what the device keeps away from every agent whatever is set here
    /// (§8.1), and for the shell, what leaves the sandbox.
    static func footer(_ capability: String) -> String? {
        switch capability {
        case "files": "floo 自己的钥匙（~/.floo）、~/.ssh、~/.gnupg、~/.aws、钥匙串和浏览器存密码的文件，在这台设备上一直碰不到，这里改不了。"
        case "shell": "命令默认在沙盒里跑。不在沙盒里跑的，每次都要你批准，「以后都允许」也盖不过；受保护的文件在沙盒里读不到。"
        default: nil
        }
    }

    static func use(_ use: FlooDeviceState.Use) -> String {
        switch use {
        case .floo: "正在用 floo"
        case .unlocked: "已解锁"
        case .locked: "已锁定"
        }
    }

    static func battery(_ battery: FlooDeviceState.Battery, charging: Bool) -> String {
        let level = switch battery {
        case .critical: "电量很低"
        case .low: "电量低"
        case .half: "电量不到一半"
        case .ok: "电量充足"
        }
        return charging ? "\(level) · 充电中" : level
    }

    static func batterySymbol(_ battery: FlooDeviceState.Battery, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        return switch battery {
        case .critical: "battery.0percent"
        case .low: "battery.25percent"
        case .half: "battery.50percent"
        case .ok: "battery.100percent"
        }
    }

    static func network(_ network: FlooDeviceState.Network, limited: Bool) -> String {
        let kind = switch network {
        case .wifi: "Wi-Fi"
        case .cellular: "蜂窝网络"
        case .wired: "有线"
        case .other: "已连接"
        case .none: "没有网络"
        }
        return limited ? "\(kind) · 省流量" : kind
    }
}

// MARK: - The pages' state

enum FlooDevicesRoute: Hashable {
    case device(String)
    case capability(String, String)
    case approval(String, String, String?)
    case list(String, String, String)

    /// `-flooDevicesPath "device:mac capability:mac:shell"`: a device by its id, or the first of
    /// a kind (`mac`, `iphone`, `ipad`).
    static var launchPath: [FlooDevicesRoute] {
        (UserDefaults.standard.string(forKey: "flooDevicesPath") ?? "").split(separator: " ").compactMap { step in
            let parts = step.split(separator: ":").map(String.init)
            switch parts.first {
            case "device" where parts.count == 2: return .device(parts[1])
            case "capability" where parts.count == 3: return .capability(parts[1], parts[2])
            case "approval" where parts.count >= 3:
                // The agent's id has its own colon (service:gmail).
                return .approval(parts[1], parts[2], parts.count > 3 ? parts[3...].joined(separator: ":") : nil)
            case "list" where parts.count == 4: return .list(parts[1], parts[2], parts[3])
            default: return nil
            }
        }
    }
}

/// The pages' state, as the floo server has it: the devices with their state and capabilities
/// from the standings (`GET /v1/services/standing`), each capability's settings by device
/// (`GET`/`PUT /v1/capabilities/{capability}/settings`), the approval policy from this
/// device's mailbox, set whole (`PUT /v1/approval-policy`), as the services' permissions page
/// sets it.
@MainActor @Observable
final class FlooDevicesDemo {
    @ObservationIgnored let live: FlooLive
    var devices: [FlooDevice] = []
    var thisDevice = ""
    var states: [String: FlooDeviceState] = [:]
    /// By device, then capability.
    var capabilities: [String: [String: FlooCapabilityShown]] = [:]
    /// By device, then capability, then key: its settings file.
    var settings: [String: [String: [String: [String]]]] = [:]
    /// Whose file each is, by device, then capability.
    @ObservationIgnored var providers: [String: [String: ProviderID]] = [:]
    var approvalMode: ApprovalMode = .open
    var rules: [FlooCapabilityRule] = []
    var grants: [FlooCapabilityGrant] = []
    var agents: [FlooAgentShown] = [FlooDevicesDemo.butler]
    var path: [FlooDevicesRoute] = FlooDevicesRoute.launchPath
    var loaded = false
    var toast: String?

    static let butler = FlooAgentShown(id: "butler", name: "管家", symbol: "sparkles", tint: .orange)

    init(live: FlooLive) {
        self.live = live
        thisDevice = live.ownDevice?.description ?? ""
        #if targetEnvironment(macCatalyst)
        if let account = live.onlineAccount, let helper = FlooHelper.device(of: account) { thisDevice = helper }
        #endif
    }

    /// Reads it all again: the devices first, then the settings and the policy.
    func load() async {
        guard let client = live.server else { return }
        // Each part on its own: one not read leaves the others shown.
        do {
            guard let standings = try await client.standings() else { return }
            take(standings)
            loaded = true
            await readAgents(standings.services.filter(\.connected).map(\.service))
        } catch {
            show("没读到设备：\(error)")
        }
        for capability in [CapabilityID.files, .shell] {
            do {
                take(try await client.settings(of: capability), of: capability.rawValue)
            } catch {
                show("没读到\(FlooCapabilityWords.name(capability.rawValue))的范围：\(error)")
            }
        }
        do {
            take(try await Self.policy(client))
        } catch {
            show("没读到批准方式：\(error)")
        }
    }

    private func take(_ standings: ServiceStandings) {
        devices = standings.devices.map { standing in
            let (kind, symbol): (FlooDevice.Kind, String) = switch standing.platform {
            case .mac: (.mac, "laptopcomputer")
            case .iPhone: (.iPhone, "iphone")
            case .iPad: (.iPad, "ipad")
            case .watch: (.iPhone, "applewatch")
            }
            return FlooDevice(
                id: standing.device.description,
                name: standing.name,
                kind: kind,
                symbol: symbol,
                product: standing.model.map {
                    AppleDevice($0, color: standing.color, osVersion: standing.osVersion.firstMatch(of: /\d+(\.\d+)*/).map { String($0.output.0) })
                },
                online: standing.online,
                lastSeen: standing.online ? nil : standing.lastSeen.map { FlooContactsDemo.ago($0.date) }
            )
        }
        .sorted { ($0.id == thisDevice ? 0 : 1, $0.online ? 0 : 1) < ($1.id == thisDevice ? 0 : 1, $1.online ? 0 : 1) }
        states = Dictionary(uniqueKeysWithValues: standings.devices.map { ($0.device.description, Self.state($0)) })
        capabilities = Dictionary(uniqueKeysWithValues: standings.devices.map { standing in
            (standing.device.description, Dictionary(standing.capabilities.map { report in
                let unmet = report.requirements.filter { !$0.optional && $0.state != .met }
                let needs = FlooContactsDemo.needs(unmet.map(\.requirement)).map { [$0] }
                    ?? unmet.map { $0.detail ?? "\($0.requirement.kind):\($0.requirement.name)" }
                return (report.capability.rawValue, FlooCapabilityShown(needs: needs))
            }) { first, _ in first })
        })
    }

    private static func state(_ standing: DeviceStanding) -> FlooDeviceState {
        let said = standing.state
        var state = FlooDeviceState()
        state.use = said.use.flatMap { FlooDeviceState.Use(rawValue: $0.rawValue) }
        state.battery = said.power.flatMap { FlooDeviceState.Battery(rawValue: $0.battery.rawValue) }
        state.charging = said.power?.charging ?? false
        state.network = said.network.flatMap { FlooDeviceState.Network(rawValue: $0.kind.rawValue) }
        state.limited = said.network?.limited ?? false
        state.zone = said.zone?.identifier
        state.place = said.place?.name
        state.at = standing.stateAt.map { FlooContactsDemo.ago($0.date) }
        return state
    }

    /// The butler, the agents of the services you have, and the helpers you've named, by
    /// what you call them.
    private func readAgents(_ services: [ServiceID]) async {
        let looks = FlooAgentLooks.shared
        if let client = live.server { await looks.read(client) }
        let catalog = Dictionary((await live.directory() ?? []).map { ($0.id, $0.name) }) { first, _ in first }
        var found = [FlooAgentShown(id: "butler", name: looks.names["butler"] ?? "管家", symbol: "sparkles", tint: .orange)]
        for service in services.sorted() {
            found.append(FlooAgentShown(
                id: "service:\(service)", name: looks.names["service:\(service)"] ?? catalog[service] ?? service.rawValue,
                symbol: "app", tint: .blue
            ))
        }
        for (id, name) in looks.names.sorted(by: { $0.key < $1.key }) where id.hasPrefix("helper:") {
            found.append(FlooAgentShown(id: id, name: name, symbol: "person.crop.circle", tint: .purple))
        }
        agents = found
    }

    private func take(_ files: [ProviderSettingsFile], of capability: String) {
        for file in files {
            guard let device = file.device?.description else { continue }
            providers[device, default: [:]][capability] = file.provider
            var keys: [String: [String]] = [:]
            if case .object(let fields) = file.settings {
                for (key, value) in fields {
                    if case .array(let items) = value { keys[key] = items.compactMap(\.stringValue) }
                }
            }
            settings[device, default: [:]][capability] = keys
        }
    }

    private func take(_ policy: ApprovalPolicy?) {
        approvalMode = policy?.mode ?? .open
        rules = (policy?.capabilities ?? []).map {
            FlooCapabilityRule(capability: $0.capability.rawValue, agent: $0.agent?.description,
                               device: $0.device?.description, mode: $0.mode, reads: $0.reads)
        }
        grants = (policy?.grants ?? []).compactMap { grant in
            guard case .capability(let capability) = grant.owner else { return nil }
            return FlooCapabilityGrant(
                id: "\(grant.hashValue)", capability: capability.rawValue, what: Self.what(grant, capability),
                agent: grant.agent?.description, device: grant.device?.description, grant: grant
            )
        }
    }

    /// What a grant lets through, in a line: the call as it was, or all of a tool.
    private static func what(_ grant: ApprovalGrant, _ capability: CapabilityID) -> String {
        guard let tool = grant.tool else { return "\(FlooCapabilityWords.name(capability.rawValue))的所有操作" }
        if let command = grant.arguments["command"]?.stringValue { return "跑 \(command)" }
        if let path = grant.arguments["path"]?.stringValue { return "\(tool) \(path)" }
        return grant.arguments.isEmpty ? "\(tool) 的所有调用" : "\(tool)（\(grant.arguments.keys.sorted().joined(separator: "、"))）"
    }

    /// The policy the first mailbox brings; nil when none was chosen.
    private static func policy(_ client: FlooClient) async throws -> ApprovalPolicy? {
        for try await mailbox in client.mailbox() { return mailbox.policy }
        return nil
    }

    /// The policy changed by `change`, read again first so what else is in it stands.
    private func changePolicy(_ change: @escaping (inout ApprovalPolicy) -> Void) {
        guard let client = live.server else { return }
        let account = live.account
        Task {
            do {
                var policy = try await Self.policy(client) ?? ApprovalPolicy(account: account, mode: .open, at: .now)
                change(&policy)
                policy.at = .now
                try await client.setApprovalPolicy(policy)
                take(policy)
            } catch {
                show("没改成：\(error)")
                take(try? await Self.policy(client))  // try?: what's shown stands
            }
        }
    }

    func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(3))  // try?: cancelled, gone anyway
            withAnimation { toast = nil }
        }
    }

    /// A device by its id, or the first of a kind (`mac`, `iphone`, `ipad`).
    func device(_ id: String) -> FlooDevice? {
        devices.first { $0.id == id } ?? devices.first { device in
            switch id {
            case "mac": device.kind == .mac
            case "iphone": device.kind == .iPhone
            case "ipad": device.kind == .iPad
            default: false
            }
        }
    }

    func agent(_ id: String) -> FlooAgentShown? { agents.first { $0.id == id } }

    /// Its capabilities, as the pages order them: those it has, then those it doesn't.
    func capabilities(of device: String) -> [String] {
        let have = capabilities[device] ?? [:]
        return FlooCapabilityWords.all.filter { have[$0] != nil } + FlooCapabilityWords.all.filter { have[$0] == nil }
    }

    /// The rule set exactly for `agent` on `device`, if any.
    func rule(_ capability: String, agent: String?, device: String) -> FlooCapabilityRule? {
        rules.first { $0.capability == capability && $0.agent == agent && $0.device == device }
    }

    /// What applies to `agent` using `capability` on `device`: the most specific rule that fits,
    /// leaving out the one set exactly here when `inherited` (what it would follow without it).
    func applying(_ capability: String, agent: String?, device: String, inherited: Bool = false) -> FlooCapabilityRule? {
        rules.filter { rule in
            rule.capability == capability && (rule.agent == nil || rule.agent == agent)
                && (rule.device == nil || rule.device == device)
                && !(inherited && rule.agent == agent && rule.device == device)
        }.max { $0.specificity < $1.specificity }
    }

    func set(_ capability: String, agent: String?, device: String, _ rule: FlooCapabilityRule?) {
        rules.removeAll { $0.capability == capability && $0.agent == agent && $0.device == device }
        if let rule { rules.append(rule) }
        guard let id = try? CapabilityID(capability) else { return }  // try?: not one, nothing to set
        let agentID = agent.flatMap(AgentID.init)
        let deviceID = DeviceID(device)
        changePolicy { policy in
            policy.capabilities.removeAll { $0.capability == id && $0.agent == agentID && $0.device == deviceID }
            if let rule {
                policy.capabilities.append(
                    CapabilityApproval(capability: id, agent: agentID, device: deviceID, mode: rule.mode, reads: rule.reads)
                )
            }
        }
    }

    func grants(_ capability: String, on device: String) -> [FlooCapabilityGrant] {
        grants.filter { $0.capability == capability && ($0.device == nil || $0.device == device) }
    }

    func revoke(_ grant: FlooCapabilityGrant) {
        grants.removeAll { $0.id == grant.id }
        guard let revoked = grant.grant else { return }
        changePolicy { policy in policy.grants.removeAll { $0 == revoked } }
    }

    func items(_ device: String, _ capability: String, _ key: String) -> [String] {
        settings[device]?[capability]?[key] ?? []
    }

    /// One key of the capability's file on `device`, written on the server; the device is told.
    func setItems(_ items: [String], _ device: String, _ capability: String, _ key: String) {
        settings[device, default: [:]][capability, default: [:]][key] = items
        guard let client = live.server, let id = try? CapabilityID(capability),  // try?: not one
              let provider = providers[device]?[capability], let deviceID = DeviceID(device) else { return }
        let change = ProviderSettingsChange(
            device: deviceID, provider: provider,
            set: items.isEmpty ? [:] : [key: .array(items.map(JSONValue.string))],
            remove: items.isEmpty ? [key] : []
        )
        Task {
            do {
                take([try await client.change(change, of: id)], of: capability)
            } catch {
                show("没存上：\(error)")
                if let files = try? await client.settings(of: id) { take(files, of: capability) }  // try?: what's shown stands
            }
        }
    }

    /// What a rule's row says: its mode, and its reads when they're asked too.
    func summary(_ rule: FlooCapabilityRule?) -> String {
        guard let rule else { return FlooApprovalWords.name(approvalMode) }
        return FlooApprovalWords.name(rule.mode) + (rule.reads ? " · 含读取" : "")
    }

    /// Where a rule followed comes from, said under it.
    func source(_ rule: FlooCapabilityRule?) -> String {
        guard let rule else { return "跟随账户" }
        switch (rule.agent, rule.device) {
        case (nil, nil): return "跟随所有设备上的设置"
        case (nil, _): return "跟随这台上所有 agent 的设置"
        case (let agent?, nil): return "跟随\(self.agent(agent)?.name ?? agent)在所有设备上的设置"
        case (let agent?, _): return "\(self.agent(agent)?.name ?? agent)在这台上"
        }
    }
}

// MARK: - Your devices

struct FlooDevicesDestination: View {
    @State private var demo: FlooDevicesDemo

    /// `-flooDevices YES`: opened over the chat once it's signed in.
    static var launches: Bool { UserDefaults.standard.bool(forKey: "flooDevices") }

    init(live: FlooLive) {
        _demo = State(initialValue: FlooDevicesDemo(live: live))
    }

    var body: some View {
        NavigationStack(path: $demo.path) {
            FlooDeviceList(demo: demo)
                .navigationDestination(for: FlooDevicesRoute.self) { route in
                    switch route {
                    case .device(let id):
                        if let device = demo.device(id) { FlooDevicePage(demo: demo, device: device) }
                    case .capability(let id, let capability):
                        if let device = demo.device(id) { FlooCapabilityPage(demo: demo, device: device, capability: capability) }
                    case .approval(let id, let capability, let agent):
                        if let device = demo.device(id) {
                            FlooCapabilityApprovalPage(demo: demo, device: device, capability: capability, agent: agent)
                        }
                    case .list(let id, let capability, let key):
                        if let device = demo.device(id),
                           let key = FlooCapabilityWords.keys(capability).first(where: { $0.id == key }) {
                            FlooCapabilityListPage(demo: demo, device: device, capability: capability, key: key)
                        }
                    }
                }
        }
        .overlay(alignment: .top) {
            if let toast = demo.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            await demo.load()
            await Self.shoot()
        }
    }

    /// `-flooDevicesShot <file>`: the window as it is a moment after it's read, written as a
    /// PNG — a look at a page where the screen can't be recorded.
    private static func shoot() async {
        guard let file = UserDefaults.standard.string(forKey: "flooDevicesShot") else { return }
        try? await Task.sleep(for: .seconds(3))  // try?: cancelled, nothing to write
        // Opened in the background, no window is key: the scene's first then. Over the chat
        // it's a sheet: what's presented last is drawn, not the window under it.
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let view = top?.view ?? window as UIView? else { return }
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(filePath: file))  // try?: a look, nothing depends on it
    }
}

private struct FlooDeviceList: View {
    let demo: FlooDevicesDemo

    var body: some View {
        List {
            Section {
                ForEach(demo.devices) { device in
                    NavigationLink(value: FlooDevicesRoute.device(device.id)) {
                        HStack(spacing: 14) {
                            FlooDevicePicture(device: device, side: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(device.name).font(.body.weight(.medium))
                                    if device.id == demo.thisDevice {
                                        Text("这台").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(line(device)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                capabilityIcons(device)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("每个 agent 都能用你设备上的文件、命令、浏览器和屏幕；在哪台上能碰到哪里、什么时候先问你，在每台设备里设。")
            }
        }
        .navigationTitle("设备")
    }

    /// Online or when it was, then how it is now.
    private func line(_ device: FlooDevice) -> String {
        var parts = [device.online ? "在线" : "\(device.lastSeen ?? "很久以前")在线"]
        if let state = demo.states[device.id] {
            if device.online, let use = state.use { parts.append(FlooCapabilityWords.use(use)) }
            if let battery = state.battery { parts.append(FlooCapabilityWords.battery(battery, charging: state.charging)) }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func capabilityIcons(_ device: FlooDevice) -> some View {
        let have = demo.capabilities[device.id] ?? [:]
        if !have.isEmpty {
            HStack(spacing: 6) {
                ForEach(FlooCapabilityWords.all.filter { have[$0] != nil }, id: \.self) { capability in
                    Image(systemName: FlooCapabilityWords.symbol(capability))
                        .font(.caption2)
                        .foregroundStyle(have[capability]?.needs.isEmpty == false ? Color.orange : Color.secondary)
                }
            }
            .padding(.top, 1)
        }
    }
}

/// A device by its picture, its symbol until then; grey when it isn't online.
struct FlooDevicePicture: View {
    let device: FlooDevice
    let side: CGFloat

    var body: some View {
        Group {
            if let product = device.product {
                // The list's image is about 60 pt, the detail's about 150: drawn larger than it is, it blurs.
                AppleDeviceImage(product, size: side > 64 ? .large : .small) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    symbol
                }
            } else {
                symbol
            }
        }
        .frame(width: side, height: side)
        .saturation(device.online ? 1 : 0)
        .opacity(device.online ? 1 : 0.7)
    }

    private var symbol: some View {
        Image(systemName: device.symbol)
            .font(.system(size: side * 0.42))
            .foregroundStyle(.secondary)
            .frame(width: side, height: side)
            .background(.quaternary.opacity(0.5), in: Circle())
    }
}

// MARK: - One device

private struct FlooDevicePage: View {
    let demo: FlooDevicesDemo
    let device: FlooDevice

    private var state: FlooDeviceState? { demo.states[device.id] }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    FlooDevicePicture(device: device, side: 120)
                    Text(device.name).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        Circle().fill(device.online ? Color.green : Color.gray).frame(width: 8, height: 8)
                        Text(device.online ? "在线" : "上次在线：\(device.lastSeen ?? "很久以前")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let product = device.product {
                        Text(product.osVersion.map { "\(kind) · \(system) \($0)" } ?? kind)
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }

            Section {
                if let state {
                    if let use = state.use {
                        row("在用", FlooCapabilityWords.use(use), symbol: use == .locked ? "lock" : "lock.open")
                    }
                    if let battery = state.battery {
                        row("电量", FlooCapabilityWords.battery(battery, charging: state.charging),
                            symbol: FlooCapabilityWords.batterySymbol(battery, charging: state.charging))
                    }
                    if let network = state.network {
                        row("网络", FlooCapabilityWords.network(network, limited: state.limited),
                            symbol: network == .cellular ? "antenna.radiowaves.left.and.right" : network == .none ? "wifi.slash" : "wifi")
                    }
                    if let zone = state.zone.flatMap(ZoneName.init) { row("时区", FlooZones.name(of: zone), symbol: "globe") }
                    if let place = state.place { row("位置", place, symbol: "location") }
                } else {
                    Text("这台设备还没报过状态").foregroundStyle(.secondary)
                }
            } header: {
                Text("状态")
            } footer: {
                if let at = state?.at {
                    Text("这台设备 \(at) 说的。agent 按它判断该在哪台上做、找不找得到你；锁着时要解锁才能做的事会等你。")
                }
            }

            Section {
                ForEach(demo.capabilities(of: device.id), id: \.self) { capability in
                    if let shown = demo.capabilities[device.id]?[capability] {
                        NavigationLink(value: FlooDevicesRoute.capability(device.id, capability)) {
                            capabilityRow(capability, detail: shown.needs.isEmpty ? FlooCapabilityWords.summary(capability) : "还需要：\(shown.needs.joined(separator: "、"))",
                                          warning: !shown.needs.isEmpty)
                        }
                    } else {
                        capabilityRow(capability, detail: "这台设备不提供", warning: false)
                            .opacity(0.45)
                    }
                }
            } header: {
                Text("能力")
            } footer: {
                Text("能力是 floo 自带的，不用添加；这台设备上的 Floo 在运行，就能用。")
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var kind: String {
        switch device.kind {
        case .iPhone: "iPhone"
        case .mac: "Mac"
        case .iPad: "iPad"
        }
    }

    private var system: String {
        switch device.kind {
        case .iPhone: "iOS"
        case .mac: "macOS"
        case .iPad: "iPadOS"
        }
    }

    private func row(_ title: String, _ value: String, symbol: String) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func capabilityRow(_ capability: String, detail: String, warning: Bool) -> some View {
        HStack(spacing: 12) {
            FlooCapabilityIcon(capability: capability)
            VStack(alignment: .leading, spacing: 2) {
                Text(FlooCapabilityWords.name(capability))
                Text(detail).font(.footnote).foregroundStyle(warning ? Color.orange : Color.secondary).lineLimit(2)
            }
        }
    }
}

struct FlooCapabilityIcon: View {
    let capability: String

    var body: some View {
        Image(systemName: FlooCapabilityWords.symbol(capability))
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(FlooCapabilityWords.tint(capability).gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - One capability on a device

private struct FlooCapabilityPage: View {
    let demo: FlooDevicesDemo
    let device: FlooDevice
    let capability: String

    private var name: String { FlooCapabilityWords.name(capability) }

    var body: some View {
        List {
            if let needs = demo.capabilities[device.id]?[capability]?.needs, !needs.isEmpty {
                Section {
                    ForEach(needs, id: \.self) { need in
                        Label(need, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    Button(device.id == demo.thisDevice ? "去设置" : "在\(device.name)上设置") {}
                } footer: {
                    Text("没给之前，agent 在这台上用不了\(name)。")
                }
            }

            let keys = FlooCapabilityWords.keys(capability)
            if !keys.isEmpty {
                Section {
                    ForEach(keys) { key in
                        NavigationLink(value: FlooDevicesRoute.list(device.id, capability, key.id)) {
                            LabeledContent {
                                Text(count(key))
                            } label: {
                                FlooDesignSettingsLabel(key.title)
                            }
                        }
                    }
                } header: {
                    Text("范围")
                } footer: {
                    if let footer = FlooCapabilityWords.footer(capability) { Text(footer) }
                }
            }

            Section {
                approvalRow(agent: nil)
                ForEach(demo.agents) { agent in approvalRow(agent: agent) }
            } header: {
                Text("什么时候先问你")
            } footer: {
                Text("只管在\(device.name)上用\(name)，盖过账户的批准方式（现在是「\(FlooApprovalWords.name(demo.approvalMode))」）。读外来内容的 agent（比如邮件）最容易被带偏，可以单独让它每次都问。")
            }

            let grants = demo.grants(capability, on: device.id)
            if !grants.isEmpty {
                Section {
                    ForEach(grants) { grant in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(grant.what)
                            Text("\(grant.agent.flatMap { demo.agent($0)?.name } ?? "所有 agent") · \(grant.device == nil ? "所有设备" : "只这台")")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("撤回", role: .destructive) { demo.revoke(grant) }
                        }
                    }
                } header: {
                    Text("以后都允许")
                } footer: {
                    Text("批准时选过「以后都允许」的，照这里直接做。向左滑撤回。")
                }
            }
        }
        .navigationTitle("\(name) · \(device.name)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func count(_ key: FlooCapabilityWords.Key) -> String {
        let items = demo.items(device.id, capability, key.id)
        return items.isEmpty ? "没有" : items.count == 1 ? items[0] : "\(items.count) 个\(key.item)"
    }

    private func approvalRow(agent: FlooAgentShown?) -> some View {
        let set = demo.rule(capability, agent: agent?.id, device: device.id)
        let follows = demo.applying(capability, agent: agent?.id, device: device.id)
        return NavigationLink(value: FlooDevicesRoute.approval(device.id, capability, agent?.id)) {
            HStack(spacing: 12) {
                Image(systemName: agent?.symbol ?? "person.3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(agent?.tint ?? .secondary)
                    .frame(width: 30, height: 30)
                    .background((agent?.tint ?? .secondary).opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent?.name ?? "所有 agent")
                    Text(set == nil ? demo.source(follows) : "单独设了")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Text(demo.summary(follows)).foregroundStyle(set == nil ? .secondary : .primary)
            }
        }
    }
}

// MARK: - When an agent is asked

private struct FlooCapabilityApprovalPage: View {
    let demo: FlooDevicesDemo
    let device: FlooDevice
    let capability: String
    let agent: String?

    private var set: FlooCapabilityRule? { demo.rule(capability, agent: agent, device: device.id) }
    private var inherited: FlooCapabilityRule? { demo.applying(capability, agent: agent, device: device.id, inherited: true) }
    private var who: String { agent.flatMap { demo.agent($0)?.name } ?? "所有 agent" }

    var body: some View {
        List {
            Section {
                Picker("批准方式", selection: mode) {
                    choice("跟随", "\(demo.source(inherited)) · \(demo.summary(inherited))").tag(ApprovalMode?.none)
                    ForEach(ApprovalMode.allCases, id: \.self) { mode in
                        choice(FlooApprovalWords.name(mode), FlooApprovalWords.detail(mode)).tag(Optional(mode))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("\(who)在\(device.name)上用\(FlooCapabilityWords.name(capability))")
            } footer: {
                Text("越具体的越先：某个 agent 在这台上 > 某个 agent 在所有设备上 > 这台上所有 agent > 账户。")
            }

            Section {
                Toggle("读取也按上面的方式", isOn: reads)
                    .tint(FlooDesignTokens.Component.Settings.switchTint)
                    .disabled(set == nil)
            } footer: {
                Text(set == nil ? "先选一种批准方式，才能单独管读取。" : readsWords)
            }
        }
        .navigationTitle(who)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var readsWords: String {
        switch capability {
        case "files": "读文件、列文件夹平时直接做；打开后和写一样，按上面的方式问你。"
        case "shell": "命令都算修改，这一项只管它读设置之类的小事。"
        default: "读平时直接做；打开后和修改一样，按上面的方式问你。"
        }
    }

    private func choice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var mode: Binding<ApprovalMode?> {
        Binding(get: { set?.mode }) { mode in
            demo.set(capability, agent: agent, device: device.id, mode.map {
                FlooCapabilityRule(capability: capability, agent: agent, device: device.id, mode: $0, reads: set?.reads ?? false)
            })
        }
    }

    private var reads: Binding<Bool> {
        Binding(get: { set?.reads ?? false }) { reads in
            guard var rule = set else { return }
            rule.reads = reads
            demo.set(capability, agent: agent, device: device.id, rule)
        }
    }
}

// MARK: - A list of folders or sites

private struct FlooCapabilityListPage: View {
    let demo: FlooDevicesDemo
    let device: FlooDevice
    let capability: String
    let key: FlooCapabilityWords.Key
    @State private var adding = ""
    @FocusState private var typing: Bool

    private var items: [String] { demo.items(device.id, capability, key.id) }

    var body: some View {
        List {
            Section {
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: key.item == "网站" ? "globe" : "folder")
                }
                .onDelete { offsets in
                    var items = items
                    items.remove(atOffsets: offsets)
                    demo.setItems(items, device.id, capability, key.id)
                }
                HStack {
                    TextField("添加\(key.item)，如 \(key.placeholder)", text: $adding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($typing)
                        .onSubmit(add)
                    if !adding.isEmpty {
                        Button("添加", action: add)
                    }
                }
            } footer: {
                Text(key.summary)
            }
        }
        .navigationTitle(key.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func add() {
        let item = adding.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty, !items.contains(item) else { return }
        demo.setItems(items + [item], device.id, capability, key.id)
        adding = ""
    }
}
