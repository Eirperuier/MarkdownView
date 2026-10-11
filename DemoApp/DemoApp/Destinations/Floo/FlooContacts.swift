//
//  FlooContacts.swift
//  DemoApp
//
//  Finding and following services, as floo docs/app.md 3.2 has it: two pages, not one in two
//  states. Before following, its page says what it can do and what it needs; after, it is a
//  contact: how it is connected on each of your devices, what it is doing for you, its
//  settings and what it has sent. The words, operations and hooks are the real catalog's
//  (FlooCatalog.json, exported by DemoApp/Scripts/floo-catalog.py); devices, accounts and what
//  each service is doing are scripted.
//  `-flooContacts YES` opens it; `-flooContactsPath "service:gmail"` opens a page,
//  `"chat:health"` a conversation.
//

import SwiftUI
import CardModel
import CardUI

// MARK: - The catalog

/// A service as the server publishes it, its copy laid over (`ServiceDefinition.withCopy`).
struct FlooService: Decodable, Identifiable, Hashable {
    struct Text: Decodable, Hashable {
        var name: String?
        var shortDescription: String?
        var description: String?
        var prompts: [String]?
    }

    struct Presentation: Decodable, Hashable {
        var name: String
        var shortDescription: String?
        var description: String?
        var prompts: [String]?
        var localized: [String: Text]?
        var developer: String?
        var website: String?
        var privacyPolicy: String?
        var termsOfService: String?
        var icon: String?
        var color: String?
        var category: String?
    }

    struct Operation: Decodable, Hashable {
        var title: String
        var effect: String
    }

    struct Hook: Decodable, Hashable {
        var summary: String
    }

    let id: String
    let presentation: Presentation
    let operations: [Operation]
    let hooks: [Hook]

    /// Its words in Chinese, each falling back to English (`Presentation.text(in:)`).
    private var chinese: Text? { presentation.localized?["zh-Hans"] }
    var name: String { chinese?.name ?? presentation.name }
    var shortDescription: String? { chinese?.shortDescription ?? presentation.shortDescription }
    var description: String? { chinese?.description ?? presentation.description }
    var prompts: [String] { Array((chinese?.prompts ?? presentation.prompts ?? []).prefix(3)) }

    var reads: [Operation] { operations.filter { $0.effect == "read" } }
    /// Writes, deletions and those whose effect isn't known: each asks first (PolicyKit).
    var changes: [Operation] { operations.filter { $0.effect != "read" } }

    var icon: URL? { presentation.icon.flatMap { URL(string: "https://floo-server.fly.dev" + $0) } }
    var tint: Color { presentation.color.flatMap(Color.init(hex:)) ?? .gray }

    /// The App's own name for a category (a UI string, localized with the App).
    var category: String? {
        switch presentation.category {
        case "email": "邮件"
        case "scheduling-&-booking", "productivity": "效率"
        case "developer-tools", "development": "开发"
        case "notes": "笔记"
        case "team-chat": "沟通"
        case "health": "健康"
        case "media": "照片与视频"
        default: presentation.category
        }
    }

    var sources: FlooServiceSources { FlooServiceSources.of[id] ?? FlooServiceSources() }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [FlooService] = {
        guard let url = Bundle.main.url(forResource: "FlooCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }  // try?: the demo shows none
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode([FlooService].self, from: data)) ?? []  // try?: as above
    }()

    static func named(_ id: String) -> FlooService? { all.first { $0.id == id } }
}

extension Color {
    init?(hex: String) {
        guard hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Providers and devices

/// The person's devices, as the server knows them (`DeviceStore.online`: seen in the last minute).
struct FlooDevice: Identifiable, Hashable {
    enum Kind { case iPhone, mac, iPad }

    let id: String
    let name: String
    let kind: Kind
    let symbol: String
    var online = true
    /// When it was last seen, if it isn't online.
    var lastSeen: String?

    static let this = "iphone"
    static let all = [
        FlooDevice(id: "iphone", name: "这台 iPhone", kind: .iPhone, symbol: "iphone"),
        FlooDevice(id: "mac", name: "林晓的 MacBook Pro", kind: .mac, symbol: "laptopcomputer"),
        FlooDevice(id: "ipad", name: "iPad", kind: .iPad, symbol: "ipad"),
        FlooDevice(id: "imac", name: "家里的 iMac", kind: .mac, symbol: "desktopcomputer", online: false, lastSeen: "2 天前"),
    ]
}

/// Where a service can come from: an account signed in through Composio, and the kinds of
/// device that provide it, each with what it needs there (the providers' requirements).
struct FlooServiceSources {
    var account: String?
    var devices: [FlooDevice.Kind: String] = [:]

    func provides(on device: FlooDevice) -> Bool { devices[device.kind] != nil }

    static let of: [String: FlooServiceSources] = [
        "gmail": FlooServiceSources(account: "Google"),
        "googlecalendar": FlooServiceSources(account: "Google"),
        "notion": FlooServiceSources(account: "Notion"),
        "slack": FlooServiceSources(account: "Slack"),
        "github": FlooServiceSources(account: "GitHub", devices: [.mac: "登录 gh"]),
        "calendar": FlooServiceSources(devices: [.iPhone: "允许访问日历", .mac: "允许访问日历", .iPad: "允许访问日历"]),
        "reminders": FlooServiceSources(devices: [.iPhone: "允许访问提醒事项", .mac: "允许访问提醒事项", .iPad: "允许访问提醒事项"]),
        "contacts": FlooServiceSources(devices: [.iPhone: "允许访问通讯录", .mac: "允许访问通讯录", .iPad: "允许访问通讯录"]),
        "photos": FlooServiceSources(devices: [.iPhone: "允许访问照片", .mac: "允许访问照片", .iPad: "允许访问照片"]),
        "health": FlooServiceSources(devices: [.iPhone: "允许读取健康数据"]),
        "codex": FlooServiceSources(devices: [.mac: "装好 Codex 并登录"]),
    ]
}

// MARK: - You and a service

/// One of its pushes (the Feed, agent-kernel §10.7, for this service): its words, and the
/// card (`floo.card`) or the thing it points at (`floo.mention`) it came with.
struct FlooPush: Hashable {
    /// "今天", "昨天", or a date: the album groups by it.
    let day: String
    let time: String
    let text: String
    var card: String? = nil
    var mention: FlooMention? = nil
}

/// What a `floo.mention` points at, as the App previews it: like a link shared in Moments.
struct FlooMention: Hashable {
    let symbol: String
    let title: String
    let detail: String
}

/// Something it took on for you: a commitment or a watch it wrote (agent-kernel §22), and
/// where in the conversation it was asked.
struct FlooDoing: Hashable {
    let text: String
    let asked: String
}

/// You and a service you follow: all from records floo keeps.
struct FlooFollowing: Hashable {
    /// The account it was signed in with (Composio's connected account).
    var account: String?
    var expired = false
    /// Devices it is provided on: set up there and reporting.
    var devices: Set<String> = []
    /// Devices asked to set it up, not yet reporting.
    var asked: Set<String> = []
    var doing: [FlooDoing] = []
    /// Newest first.
    var pushes: [FlooPush] = []
    /// Cards it drew in your conversation, newest first.
    var shared: [String] = []
    var quiet = false
    var pinned = false
}

enum FlooSignInEnding: String, CaseIterable, Identifiable {
    case signedIn = "登录成功"
    case cancelled = "中途关掉"
    case failed = "对方拒绝"
    var id: String { rawValue }
}

enum FlooContactsRoute: Hashable {
    case service(String)
    case chat(String)
    case operations(String)
    case hooks(String)
    case moments(String)
    case post(String, Int)

    static var launchPath: [FlooContactsRoute] {
        (UserDefaults.standard.string(forKey: "flooContactsPath") ?? "").split(separator: " ").compactMap { step in
            let parts = step.split(separator: ":").map(String.init)
            guard parts.count >= 2 else { return nil }
            switch parts[0] {
            case "service": return .service(parts[1])
            case "chat": return .chat(parts[1])
            case "moments": return .moments(parts[1])
            case "post": return .post(parts[1], Int(parts.count > 2 ? parts[2] : "0") ?? 0)
            default: return nil
            }
        }
    }
}

@MainActor @Observable
final class FlooContactsDemo {
    var following: [String: FlooFollowing] = FlooContactsDemo.start
    var devices = FlooDevice.all
    var ending: FlooSignInEnding = .signedIn
    var path: [FlooContactsRoute] = FlooContactsRoute.launchPath
    var asking: FlooService?
    /// What's put in a conversation's input: a prompt tapped on its page.
    var drafts: [String: String] = [:]
    var toast: String?
    @ObservationIgnored private var cards: [String: CardSession] = [:]

    static let start: [String: FlooFollowing] = [
        "health": FlooFollowing(
            devices: ["iphone"],
            doing: [FlooDoing(text: "睡得不好的早上，8 点说一声", asked: "10月3日 你在对话里说的")],
            pushes: [
                FlooPush(day: "今天", time: "8:02", text: "这周有三天睡不到 6 小时，都是开完晚会的那几天。", card: "sleep"),
                FlooPush(day: "昨天", time: "21:30", text: "今天走了一万两千步，比你平时多一半。", card: "steps"),
                FlooPush(day: "10月6日", time: "9:15", text: "静息心率这周回到 58 了，和上个月差不多。", card: "heart"),
                FlooPush(day: "10月3日", time: "8:00", text: "最近三晚都是一点以后才睡着。"),
            ],
            shared: ["heart", "steps", "sleep"]
        ),
        "calendar": FlooFollowing(
            devices: ["iphone", "imac"],
            doing: [FlooDoing(text: "日程撞车时提前告诉你", asked: "9月28日 你在对话里说的")],
            pushes: [
                FlooPush(
                    day: "今天", time: "18:20", text: "周五 3 点的评审和牙医撞了，要挪哪个？",
                    mention: FlooMention(symbol: "calendar", title: "设计评审", detail: "周五 15:00–16:00 · 会议室 B")
                ),
                FlooPush(day: "10月5日", time: "20:40", text: "下周三全天没有安排。"),
            ]
        ),
        "github": FlooFollowing(
            account: "linxiao",
            doing: [FlooDoing(text: "盯着 floo-sandbox 上等你 review 的 PR", asked: "10月2日 你在对话里说的")],
            pushes: [
                FlooPush(
                    day: "昨天", time: "16:05", text: "#14 在等你 review，作者催了一次。",
                    mention: FlooMention(symbol: "arrow.triangle.pull", title: "Fix flaky sync test", detail: "floo-sandbox #14 · 3 个文件")
                ),
                FlooPush(
                    day: "10月6日", time: "11:20", text: "main 上的 CI 连着挂了两次，都是 SyncTests 超时。",
                    mention: FlooMention(symbol: "xmark.octagon", title: "CI · main", detail: "floo-sandbox · 2 次失败")
                ),
            ]
        ),
    ]

    func reset() {
        following = Self.start
        devices = FlooDevice.all
        path = []
        asking = nil
        drafts = [:]
    }

    func device(_ id: String) -> FlooDevice? { devices.first { $0.id == id } }

    /// Starts following: what it needs is asked in a sheet.
    func follow(_ service: FlooService, saying prompt: String? = nil) {
        if let prompt { drafts[service.id] = prompt }
        asking = service
    }

    func followed(_ service: FlooService, account: String? = nil, device: String? = nil) {
        var following = following[service.id] ?? FlooFollowing()
        if let account { following.account = account; following.expired = false }
        if let device { following.devices.insert(device) }
        self.following[service.id] = following
        if drafts[service.id] != nil { path.append(.chat(service.id)) }
    }

    /// Puts "open this service's settings" in the device's mailbox; it reports once set up.
    func setUp(_ service: FlooService, on device: FlooDevice) {
        following[service.id, default: FlooFollowing()].asked.insert(device.id)
        show("已在\(device.name)上打开「\(service.name)」的设置")
        Task {
            try? await Task.sleep(for: .seconds(3))  // try?: cancelled, no matter
            withAnimation(FlooDesignTokens.Motion.feedback) {
                following[service.id]?.asked.remove(device.id)
                following[service.id]?.devices.insert(device.id)
            }
        }
    }

    func show(_ text: String) {
        withAnimation(FlooDesignTokens.Motion.layout) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))  // try?: cancelled, no matter
            withAnimation(FlooDesignTokens.Motion.layout) { if toast == text { toast = nil } }
        }
    }

    func card(_ name: String) -> CardSession? {
        if let session = cards[name] { return session }
        guard let spec = FlooDemoCards.all[name] else { return nil }
        let session = CardSession(data: FlooDemo.value(spec.data))
        session.append(spec.source)
        session.finish()
        cards[name] = session
        return session
    }
}

// MARK: - Finding services

struct FlooContactsDestination: View {
    @State private var demo = FlooContactsDemo()

    static var launches: Bool { UserDefaults.standard.bool(forKey: "flooContacts") }

    var body: some View {
        NavigationStack(path: $demo.path) {
            FlooServiceList(demo: demo)
                .navigationDestination(for: FlooContactsRoute.self) { route in
                    switch route {
                    case .service(let id):
                        let service = FlooService.named(id)!
                        if demo.following[id] != nil {
                            FlooContactPage(demo: demo, service: service)
                        } else {
                            FlooServicePage(demo: demo, service: service)
                        }
                    case .chat(let id): FlooServiceChat(demo: demo, service: FlooService.named(id)!)
                    case .operations(let id): FlooOperationsPage(service: FlooService.named(id)!)
                    case .hooks(let id): FlooHooksPage(service: FlooService.named(id)!)
                    case .moments(let id): FlooMomentsPage(demo: demo, service: FlooService.named(id)!)
                    case .post(let id, let index): FlooPostPage(demo: demo, service: FlooService.named(id)!, index: index)
                    }
                }
        }
        .sheet(item: $demo.asking) { service in
            FlooFollowSheet(demo: demo, service: service)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
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
    }
}

/// Like WeChat's list of official accounts: who you follow, then what is on your devices
/// already, then the rest.
private struct FlooServiceList: View {
    let demo: FlooContactsDemo
    @State private var search = ""

    private func matching(_ services: [FlooService]) -> [FlooService] {
        search.isEmpty ? services : services.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.shortDescription ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        let followed = FlooService.all.filter { demo.following[$0.id] != nil }
        let onDevices = FlooService.all.filter { service in
            demo.following[service.id] == nil && demo.devices.contains { $0.online && service.sources.provides(on: $0) }
        }
        let rest = FlooService.all.filter { !followed.contains($0) && !onDevices.contains($0) }
        List {
            section("已关注", matching(followed))
            section("你的设备上就能用", matching(onDevices))
            section("连接账号", matching(rest))
        }
        .navigationTitle("服务")
        .searchable(text: $search, prompt: "搜索服务")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("登录结果", selection: Bindable(demo).ending) {
                        ForEach(FlooSignInEnding.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("GitHub 登录过期", systemImage: "clock.badge.exclamationmark") {
                        demo.following["github"]?.expired = true
                    }
                    Button(
                        demo.device("mac")?.online == true ? "Mac 离线" : "Mac 上线",
                        systemImage: "laptopcomputer"
                    ) {
                        if let index = demo.devices.firstIndex(where: { $0.id == "mac" }) {
                            demo.devices[index].online.toggle()
                            demo.devices[index].lastSeen = demo.devices[index].online ? nil : "刚才"
                        }
                    }
                    Button("重来", systemImage: "arrow.counterclockwise") { demo.reset() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ services: [FlooService]) -> some View {
        if !services.isEmpty {
            Section(title) {
                ForEach(services) { service in
                    NavigationLink(value: FlooContactsRoute.service(service.id)) {
                        HStack(spacing: 12) {
                            FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                Text(service.shortDescription ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Before following

/// What it can do and what it needs; all from its definition and providers.
private struct FlooServicePage: View {
    let demo: FlooContactsDemo
    let service: FlooService
    @State private var tint = Color(white: 0.45)

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: tint, size: 104)
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    Text(service.name).font(.system(size: 30, weight: .bold, design: .rounded))
                    if let short = service.shortDescription {
                        Text(short).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let here = onYourDevices {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(here)
                        }
                        .font(.caption).foregroundStyle(.green)
                    }
                    Button { demo.follow(service) } label: {
                        Text("关注").font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(tint)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .listRowBackground(Color.clear)
            }

            if !service.prompts.isEmpty {
                Section {
                    ForEach(service.prompts, id: \.self) { prompt in
                        Button { demo.follow(service, saying: prompt) } label: {
                            HStack {
                                Text(prompt).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("可以这样用")
                } footer: {
                    Text("点一条，关注后它会出现在对话里。")
                }
            }

            if let description = service.description {
                Section("介绍") { Text(description).font(.subheadline) }
            }

            Section {
                Label("读取 \(service.reads.count) 项", systemImage: "eye")
                if !service.changes.isEmpty {
                    Label("修改 \(service.changes.count) 项，每次都先问你", systemImage: "pencil")
                }
                NavigationLink("全部 \(service.operations.count) 项操作", value: FlooContactsRoute.operations(service.id))
                if !service.hooks.isEmpty {
                    NavigationLink("能告诉你的 \(service.hooks.count) 种变化", value: FlooContactsRoute.hooks(service.id))
                }
            } header: {
                Text("能做的事")
            }

            Section("关注需要") {
                if let account = service.sources.account {
                    Label("登录你的 \(account) 账号", systemImage: "person.crop.circle")
                }
                ForEach(deviceNeeds, id: \.self) { need in
                    Label(need, systemImage: "lock.shield")
                }
            }

            FlooInfoSection(service: service)
        }
        .scrollContentBackground(.hidden)
        .background { FlooBackdrop(tint: tint) }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .task { tint = await service.backdrop() }
    }

    /// From devices' reports: which online devices could provide it now.
    private var onYourDevices: String? {
        let here = demo.devices.filter { $0.online && service.sources.provides(on: $0) }.map(\.name)
        return here.isEmpty ? nil : "在\(here.joined(separator: "、")) 上能用"
    }

    private var deviceNeeds: [String] {
        let kinds: [(FlooDevice.Kind, String)] = [(.iPhone, "iPhone"), (.mac, "Mac"), (.iPad, "iPad")]
        var byNeed: [String: [String]] = [:]
        var order: [String] = []
        for (kind, name) in kinds {
            guard let need = service.sources.devices[kind] else { continue }
            if byNeed[need] == nil { order.append(need) }
            byNeed[need, default: []].append(name)
        }
        let prefix = service.sources.account == nil ? "" : "或"
        return order.map { "\(prefix)在 \(byNeed[$0]!.joined(separator: " 或 ")) 上\($0)" }
    }
}

/// Who makes it and its links, then a fixed line on where its data goes.
private struct FlooInfoSection: View {
    let service: FlooService

    var body: some View {
        Section {
            if let developer = service.presentation.developer { LabeledContent("提供方", value: developer) }
            if let category = service.category { LabeledContent("分类", value: category) }
            link("网站", service.presentation.website)
            link("隐私政策", service.presentation.privacyPolicy)
            link("服务条款", service.presentation.termsOfService)
        } header: {
            Text("信息")
        } footer: {
            Text(dataPath)
        }
    }

    @ViewBuilder private func link(_ title: String, _ address: String?) -> some View {
        if let address, let url = URL(string: address) {
            Link(destination: url) {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dataPath: String {
        switch (service.sources.account, service.sources.devices.isEmpty) {
        case (let account?, true):
            "经 Composio 连接你的 \(account) 账号，登录凭证存在 Composio。floo 只在你让它做事、或它在替你看着时读取。不再关注就断开连接。"
        case (let account?, false):
            "可以经 Composio 连接你的 \(account) 账号，也可以由你设备上已登录的工具提供。不再关注就断开连接。"
        default:
            "在你的设备上读取，floo 只拿到它这次要的那部分。不再关注，或在系统设置里关掉权限，就停止。"
        }
    }
}

private struct FlooOperationsPage: View {
    let service: FlooService

    var body: some View {
        List {
            Section("读取") { ForEach(service.reads, id: \.self) { Text($0.title) } }
            if !service.changes.isEmpty {
                Section {
                    ForEach(service.changes, id: \.self) { Text($0.title) }
                } header: {
                    Text("修改")
                } footer: {
                    Text("每次修改之前都会先问你。")
                }
            }
        }
        .navigationTitle("\(service.operations.count) 项操作")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FlooHooksPage: View {
    let service: FlooService

    var body: some View {
        List {
            Section {
                ForEach(service.hooks, id: \.self) { Text($0.summary).font(.subheadline) }
            } footer: {
                Text("关注之后，它会按你说的盯着其中几种，有变化时告诉你。")
            }
        }
        .navigationTitle("能告诉你的变化")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Following

/// The ways to follow it: sign in, allow on this iPhone, or set it up on another device online.
private struct FlooFollowSheet: View {
    let demo: FlooContactsDemo
    let service: FlooService
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn = false
    @State private var allowing = false
    @State private var notYet: String?

    private var here: FlooDevice? {
        demo.device(FlooDevice.this).flatMap { service.sources.provides(on: $0) ? $0 : nil }
    }

    private var elsewhere: [FlooDevice] {
        demo.devices.filter { $0.online && $0.id != FlooDevice.this && service.sources.provides(on: $0) }
    }

    var body: some View {
        VStack(spacing: 16) {
            FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 56).padding(.top, 24)
            Text("关注 \(service.name)").font(.title3.weight(.bold))
            if let notYet { Text(notYet).font(.footnote).foregroundStyle(.orange) }
            VStack(spacing: 10) {
                if let account = service.sources.account {
                    way("用 \(account) 登录", "person.crop.circle", prominent: true) { signingIn = true }
                }
                if let here, let need = service.sources.devices[here.kind] {
                    way("在这台 iPhone 上\(need)", "iphone", prominent: service.sources.account == nil) { allowing = true }
                }
                ForEach(elsewhere) { device in
                    way("在\(device.name)上设置", device.symbol, prominent: false) {
                        demo.setUp(service, on: device)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 24)
            if service.sources.account == nil && here == nil && elsewhere.isEmpty {
                Text("需要一台在线的 Mac。").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("先不了") { dismiss() }.font(.subheadline).padding(.bottom, 12)
        }
        .sheet(isPresented: $signingIn) {
            if let account = service.sources.account {
                FlooSignInSheet(provider: account, service: service, ending: demo.ending) { result in
                    switch result {
                    case .signedIn(let name): dismiss(); demo.followed(service, account: name)
                    case .refused: notYet = "\(account) 没有同意，还没关注上。"
                    case .closed: notYet = "登录没完成，还没关注上。"
                    }
                }
            }
        }
        .alert("“floo”想\(here.flatMap { service.sources.devices[$0.kind] } ?? "")", isPresented: $allowing) {
            Button("不允许", role: .cancel) { notYet = "没有允许，还没关注上。" }
            Button("允许") { dismiss(); demo.followed(service, device: FlooDevice.this) }
        }
    }

    private func way(_ title: String, _ symbol: String, prominent: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
        .buttonBorderShape(.capsule)
    }
}

private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<Style: PrimitiveButtonStyle>(_ style: Style) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Stands in for the sign-in page the App opens in a web sheet.
private struct FlooSignInSheet: View {
    enum Result { case signedIn(String), refused, closed }

    let provider: String
    let service: FlooService
    let ending: FlooSignInEnding
    let done: (Result) -> Void
    @Environment(\.dismiss) private var dismiss

    private var accounts: [String] {
        switch provider {
        case "Google": ["lin.xiao@gmail.com", "xiao@studio.example"]
        case "GitHub": ["linxiao"]
        default: ["林晓的工作区"]
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(accounts, id: \.self) { account in
                        Button {
                            dismiss()
                            switch ending {
                            case .signedIn: done(.signedIn(account))
                            case .cancelled: done(.closed)
                            case .failed: done(.refused)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(account.prefix(1)).uppercased())
                                    .font(.headline).foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(Color.teal, in: Circle())
                                Text(account).foregroundStyle(.primary)
                            }
                        }
                    }
                } header: {
                    Text("选择一个 \(provider) 账号，继续使用 floo 的「\(service.name)」").textCase(nil)
                }
            }
            .navigationTitle("登录 \(provider)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss(); done(.closed) }
                }
            }
        }
    }
}

// MARK: - Its conversation

private struct FlooServiceChat: View {
    let demo: FlooContactsDemo
    let service: FlooService

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 64)
                        Text(service.name).font(.headline)
                        Text("你关注了它").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)
                }
            }
            HStack(spacing: 10) {
                Text(demo.drafts[service.id] ?? "发消息")
                    .foregroundStyle(demo.drafts[service.id] == nil ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                Image(systemName: "arrow.up.circle.fill").font(.title)
                    .foregroundStyle(demo.drafts[service.id] == nil ? Color.secondary.opacity(0.4) : Color.accentColor)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { demo.path.append(.service(service.id)) } label: {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 28)
                }
            }
        }
    }
}

#Preview {
    FlooContactsDestination()
}
