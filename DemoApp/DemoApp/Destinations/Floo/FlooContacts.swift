//
//  FlooContacts.swift
//  DemoApp
//
//  Finding and following services: laid out like the App Store (a discover page of shelves,
//  a product page with its info strip, previews, what it can do and its privacy), met like
//  people on a social app (you follow it, it writes to you first, and once you follow, its
//  page shows what it has posted and what it has done for you). Every element stands on
//  data floo has or a short text someone keeps up; FlooService says which.
//  `-flooContacts YES` opens it; `-flooContactsPath "profile:gmail"` opens a page,
//  `"chat:health"` a conversation; `-flooContactsFollow gmail` opens on following one.
//

import SwiftUI
import CardModel
import CardUI

// MARK: - Services

/// A service as its page shows it, each field marked with where it comes from.
struct FlooService: Identifiable, Hashable, Sendable {
    enum Needs: Hashable, Sendable {
        case nothing
        /// A permission on this phone.
        case permission(String)
        /// Signing in to an account elsewhere.
        case signIn(String)
    }

    /// Where it runs: from its providers.
    enum Place: Hashable, Sendable {
        /// On the person's own device.
        case device(String)
        /// In floo's cloud, through Composio (its tokens are kept there).
        case composio(String)
        /// In floo's cloud, nothing of the person's.
        case cloud
    }

    let id: String
    /// `presentation.localized_names`: kept by hand.
    let name: String
    /// `presentation.color`.
    let tint: Color
    /// `presentation.category`, its name kept by hand once per category.
    let category: String
    /// New, kept by hand in each language: one line on what it does for you, as an App
    /// Store subtitle.
    let tagline: String
    /// From its providers' requirements.
    let needs: Needs
    let place: Place
    /// From its definition: operations that only read, and those that change something.
    let reads: Int
    let changes: Int
    /// From connections, over all accounts.
    let followers: Int
    /// Curated, optional, like App Store screenshots: cards it really sends (drawn ones from
    /// the cards lab here). A service without them shows none.
    let previews: [String]
    /// From devices' reports: why it may already be yours ("你的 Mac 上登录着 GitHub").
    let onYourDevices: String?
    /// What its agent writes first once followed (agent-kernel §3.1); scripted here.
    let hello: @Sendable (_ account: String?) -> String

    var icon: URL? { URL(string: "https://floo-server.fly.dev/v1/icons/\(id).png") }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func named(_ id: String) -> FlooService? { all.first { $0.id == id } }

    static let all: [FlooService] = [
        FlooService(
            id: "weather", name: "天气", tint: .cyan, category: "生活", tagline: "要下雨、会碍着你安排时，提前说",
            needs: .nothing, place: .cloud, reads: 4, changes: 0, followers: 18_400,
            previews: ["rain", "weather"], onYourDevices: nil,
            hello: { _ in "你好，我是天气。你常在哪个城市？天气要碍着你的事，我会提前说；平常不打扰你。" }
        ),
        FlooService(
            id: "health", name: "健康", tint: .pink, category: "生活", tagline: "睡眠和步数，有变化才提",
            needs: .permission("读取健康数据"), place: .device("iPhone"), reads: 6, changes: 0, followers: 9_200,
            previews: ["sleep", "steps", "heart"], onYourDevices: "在你的 iPhone 上",
            hello: { _ in "你好，我是健康，能看到这台手机上的睡眠和步数了。睡得不好的那几天，我会在早上说一声。" }
        ),
        FlooService(
            id: "calendar", name: "日历", tint: .red, category: "效率", tagline: "撞车的安排，提前告诉你",
            needs: .permission("访问日历"), place: .device("iPhone"), reads: 5, changes: 4, followers: 15_100,
            previews: [], onYourDevices: "在你的 iPhone 上",
            hello: { _ in "你好，我是日历。看到撞车的安排，我会提前告诉你；要改什么，跟我说就行。" }
        ),
        FlooService(
            id: "gmail", name: "Gmail", tint: Color(red: 0.86, green: 0.27, blue: 0.22), category: "效率",
            tagline: "挑出值得回的邮件，先拟好草稿", needs: .signIn("Google"), place: .composio("Google"),
            reads: 41, changes: 20, followers: 12_800, previews: [], onYourDevices: nil,
            hello: { account in
                "你好，我是 Gmail，认识你的 \(account ?? "邮箱")了。值得回的邮件我会挑出来、先拟好草稿；发出去之前都会先问你。"
            }
        ),
        FlooService(
            id: "googlecalendar", name: "Google 日历", tint: .blue, category: "效率", tagline: "Google 上的邀请，和手机日历一起看",
            needs: .signIn("Google"), place: .composio("Google"), reads: 30, changes: 17, followers: 6_300,
            previews: [], onYourDevices: nil,
            hello: { account in "你好，我是 Google 日历，认识你的 \(account ?? "账号")了。有人邀请你、时间变了，我会告诉你。" }
        ),
        FlooService(
            id: "github", name: "GitHub", tint: .black, category: "工作", tagline: "有人等你 review，才出声",
            needs: .signIn("GitHub"), place: .composio("GitHub"), reads: 512, changes: 363, followers: 4_700,
            previews: [], onYourDevices: "你的 Mac 上登录着 GitHub",
            hello: { account in "你好，我是 GitHub，认识 \(account ?? "你")了。有人等你 review、你的 PR 有了回复，我会说。" }
        ),
        FlooService(
            id: "notion", name: "Notion", tint: .gray, category: "工作", tagline: "找页面、记下要记的",
            needs: .signIn("Notion"), place: .composio("Notion"), reads: 31, changes: 26, followers: 3_900,
            previews: [], onYourDevices: nil,
            hello: { account in "你好，我是 Notion，认识 \(account ?? "你的工作区")了。要找什么页面、记什么，跟我说。" }
        ),
        FlooService(
            id: "slack", name: "Slack", tint: .purple, category: "工作", tagline: "有人 @你、等你回，才提醒",
            needs: .signIn("Slack"), place: .composio("Slack"), reads: 96, changes: 65, followers: 3_100,
            previews: [], onYourDevices: nil,
            hello: { account in "你好，我是 Slack，认识 \(account ?? "你的工作区")了。有人 @你、等你回，我会告诉你。" }
        ),
    ]
}

/// One of its real pushes (the Feed, agent-kernel §10.7, for this service).
struct FlooPush: Hashable, Sendable {
    let time: String
    let text: String
    var card: String? = nil
}

/// You and a service you follow: all from records floo keeps.
struct FlooFollowing: Hashable {
    var account: String?
    /// Since the connection was made.
    var days = 0
    /// Its operations for you, from the operation ledger.
    var done = 0
    var quiet = false
    var pushes: [FlooPush] = []
}

enum FlooSignInEnding: String, CaseIterable, Identifiable {
    case signedIn = "登录成功"
    case cancelled = "中途关掉"
    case failed = "对方拒绝"
    var id: String { rawValue }
}

/// What the editors feature: kept by hand, a title and a line per language.
struct FlooFeature: Sendable {
    let service: String
    let kicker: String
    let title: String
}

@MainActor @Observable
final class FlooContactsDemo {
    var following: [String: FlooFollowing] = FlooContactsDemo.start
    var ending: FlooSignInEnding = .signedIn
    var path: [FlooContactsRoute] = FlooContactsRoute.launchPath
    var asking: FlooService?
    var greeted: FlooService?
    /// Drawn cards, by name.
    @ObservationIgnored private var cards: [String: CardSession] = [:]

    static let start: [String: FlooFollowing] = [
        "weather": FlooFollowing(
            days: 23, done: 41,
            pushes: [
                FlooPush(time: "周五 20:10", text: "周六下午苏州有雷阵雨，你约的露营在 3 点。要不要改到周日上午？", card: "rain"),
                FlooPush(time: "周一 7:40", text: "今天比昨天冷 9 度，出门带件外套。"),
            ]
        ),
        "health": FlooFollowing(
            days: 12, done: 17,
            pushes: [FlooPush(time: "今天 8:02", text: "这周有三天睡不到 6 小时，都是开完晚会的那几天。", card: "sleep")]
        ),
    ]

    static let features = [
        FlooFeature(service: "gmail", kicker: "精选", title: "让邮件不再追着你跑"),
        FlooFeature(service: "github", kicker: "给开发者", title: "只在有人等你时出声"),
    ]

    func reset() {
        following = Self.start
        path = []
        asking = nil
        greeted = nil
    }

    func follow(_ service: FlooService) {
        if case .nothing = service.needs { followed(service, account: nil) } else { asking = service }
    }

    func followed(_ service: FlooService, account: String?) {
        following[service.id] = FlooFollowing(account: account)
        Task {
            try? await Task.sleep(for: .seconds(1.2))  // try?: cancelled, no matter
            withAnimation(.snappy) { greeted = service }
            try? await Task.sleep(for: .seconds(4))  // try?: cancelled, no matter
            withAnimation(.snappy) { if greeted == service { greeted = nil } }
        }
    }

    func open(_ service: FlooService) {
        greeted = nil
        path.append(.chat(service.id))
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

enum FlooContactsRoute: Hashable {
    case profile(String)
    case chat(String)

    static var launchPath: [FlooContactsRoute] {
        (UserDefaults.standard.string(forKey: "flooContactsPath") ?? "").split(separator: " ").compactMap { step in
            let parts = step.split(separator: ":").map(String.init)
            guard parts.count == 2 else { return nil }
            return parts[0] == "profile" ? .profile(parts[1]) : parts[0] == "chat" ? .chat(parts[1]) : nil
        }
    }
}

extension Int {
    /// 18400 → "1.8万", as Chinese apps count followers.
    var followerCount: String {
        self >= 10_000 ? String(format: "%.1f万", Double(self) / 10_000) : "\(self)"
    }
}

// MARK: - Discover

struct FlooContactsDestination: View {
    @State private var demo = FlooContactsDemo()

    static var launches: Bool { UserDefaults.standard.bool(forKey: "flooContacts") }

    var body: some View {
        NavigationStack(path: $demo.path) {
            FlooDiscover(demo: demo)
                .navigationDestination(for: FlooContactsRoute.self) { route in
                    switch route {
                    case .profile(let id): FlooServicePage(demo: demo, service: FlooService.named(id)!)
                    case .chat(let id): FlooServiceChat(demo: demo, service: FlooService.named(id)!)
                    }
                }
        }
        .sheet(item: $demo.asking) { service in
            FlooLetItKnowYou(demo: demo, service: service)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .task {
            if let id = UserDefaults.standard.string(forKey: "flooContactsFollow") { demo.asking = FlooService.named(id) }
        }
        .overlay(alignment: .top) {
            if let service = demo.greeted {
                FlooGreetingToast(service: service) { demo.open(service) }
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct FlooDiscover: View {
    let demo: FlooContactsDemo
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                features
                onYourDevices
                ForEach(["效率", "工作", "生活"], id: \.self) { category in
                    FlooShelf(demo: demo, title: category, services: FlooService.all.filter { $0.category == category })
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("发现")
        .searchable(text: $search, prompt: "服务、或想让谁帮忙")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("登录结果", selection: Bindable(demo).ending) {
                        ForEach(FlooSignInEnding.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("重来", systemImage: "arrow.counterclockwise") { demo.reset() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    /// The editors' picks: App Store's large cards.
    private var features: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(FlooContactsDemo.features, id: \.service) { feature in
                    if let service = FlooService.named(feature.service) {
                        FlooFeatureCard(demo: demo, feature: feature, service: service)
                            .containerRelativeFrame(.horizontal) { width, _ in width - 40 }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .scrollTargetBehavior(.viewAligned)
    }

    /// Like "people you may know": services already on the person's devices.
    @ViewBuilder private var onYourDevices: some View {
        let known = FlooService.all.filter { $0.onYourDevices != nil && demo.following[$0.id] == nil }
        if !known.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                FlooShelfTitle(title: "你的设备上已经有")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(known) { service in
                            Button {
                                demo.path.append(.profile(service.id))
                            } label: {
                                VStack(spacing: 8) {
                                    FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 64)
                                    Text(service.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text(service.onYourDevices ?? "").font(.caption).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
                                    FlooFollowButton(demo: demo, service: service)
                                }
                                .padding(14)
                                .frame(width: 150)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

private struct FlooShelfTitle: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            Text("查看全部").font(.subheadline).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
    }
}

private struct FlooFeatureCard: View {
    let demo: FlooContactsDemo
    let feature: FlooFeature
    let service: FlooService

    var body: some View {
        Button {
            demo.path.append(.profile(service.id))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.kicker).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    Text(feature.title).font(.title2.weight(.bold)).foregroundStyle(.white)
                }
                .padding(18)
                Spacer(minLength: 24)
                HStack(spacing: 12) {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text(service.tagline).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                    Spacer()
                    FlooFollowButton(demo: demo, service: service, onColor: true)
                }
                .padding(14)
                .background(.ultraThinMaterial.opacity(0.6))
            }
            .frame(height: 230)
            .background(LinearGradient(colors: [service.tint, service.tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// App Store's shelf: three rows to a column, paged sideways.
private struct FlooShelf: View {
    let demo: FlooContactsDemo
    let title: String
    let services: [FlooService]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlooShelfTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(72), spacing: 0), count: min(3, max(services.count, 1))), spacing: 16) {
                    ForEach(services) { service in
                        FlooServiceRow(demo: demo, service: service)
                            .containerRelativeFrame(.horizontal) { width, _ in width - 48 }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct FlooServiceRow: View {
    let demo: FlooContactsDemo
    let service: FlooService

    var body: some View {
        HStack(spacing: 12) {
            Button {
                demo.path.append(.profile(service.id))
            } label: {
                HStack(spacing: 12) {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name).font(.body).foregroundStyle(.primary)
                        Text(service.tagline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            FlooFollowButton(demo: demo, service: service)
        }
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 68)
        }
    }
}

/// App Store's Get pill, as a follow button: 关注, then 已关注 with its menu.
private struct FlooFollowButton: View {
    let demo: FlooContactsDemo
    let service: FlooService
    var onColor = false

    var body: some View {
        if demo.following[service.id] != nil {
            Menu {
                Button("发消息", systemImage: "message") { demo.open(service) }
                Button(
                    demo.following[service.id]?.quiet == true ? "取消少打扰" : "少打扰",
                    systemImage: demo.following[service.id]?.quiet == true ? "bell" : "bell.slash"
                ) { demo.following[service.id]?.quiet.toggle() }
                Button("取消关注", systemImage: "person.badge.minus", role: .destructive) {
                    demo.following[service.id] = nil
                }
            } label: {
                pill("已关注", filled: false)
            }
        } else {
            Button { demo.follow(service) } label: { pill("关注", filled: true) }
                .buttonStyle(.plain)
        }
    }

    private func pill(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(onColor ? Color.white : filled ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(onColor ? Color.white.opacity(0.25) : Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

// MARK: - Its page

private struct FlooServicePage: View {
    let demo: FlooContactsDemo
    let service: FlooService

    private var following: FlooFollowing? { demo.following[service.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                infoStrip
                if let following { relationship(following) }
                if !service.previews.isEmpty { previews }
                if let following, !following.pushes.isEmpty { pushes(following) }
                abilities
                privacy
                FlooShelf(
                    demo: demo, title: "同类服务",
                    services: FlooService.all.filter { $0.category == service.category && $0.id != service.id }
                )
                .padding(.horizontal, -16)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text(service.name).font(.title2.weight(.bold))
                Text(service.tagline).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 10)
                HStack {
                    if following != nil {
                        Button { demo.open(service) } label: {
                            Text("发消息").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 6)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    FlooFollowButton(demo: demo, service: service)
                }
            }
            .frame(height: 112, alignment: .top)
        }
        .padding(.top, 8)
    }

    /// App Store's strip under the header: a few facts, each small.
    private var infoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                fact("关注", service.followers.followerCount, "人")
                fact("分类", service.category, "")
                fact("需要", needsShort, needsSub)
                fact("在哪运行", placeShort, placeSub)
                fact("能做", "\(service.reads + service.changes)", "件事")
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
    }

    private func fact(_ caption: String, _ value: String, _ sub: String) -> some View {
        VStack(spacing: 3) {
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).foregroundStyle(.secondary).lineLimit(1)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 96)
        .padding(.vertical, 8)
        .overlay(alignment: .trailing) { Divider().frame(height: 30) }
    }

    /// You and it, as a social page counts: since when, what it has done.
    private func relationship(_ following: FlooFollowing) -> some View {
        HStack(spacing: 0) {
            stat("\(following.days)", "天", "关注了")
            stat("\(following.done)", "件", "替你做了")
            stat("\(following.pushes.count)", "条", "发过动态")
        }
        .padding(.vertical, 12)
        .background(service.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stat(_ value: String, _ unit: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.weight(.bold))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Like App Store screenshots: cards it really sends.
    private var previews: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("它发来的样子").font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(service.previews, id: \.self) { name in
                        if let session = demo.card(name) {
                            CardPanel(padding: 14, cornerRadius: 20) {
                                CardView(tree: session.tree).frame(width: 232, alignment: .topLeading)
                            }
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                        }
                    }
                }
            }
        }
    }

    /// Its real posts, newest first: social, and only once you follow.
    private func pushes(_ following: FlooFollowing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("动态").font(.title3.weight(.bold))
            ForEach(following.pushes, id: \.self) { push in
                VStack(alignment: .leading, spacing: 8) {
                    Text(push.time).font(.caption).foregroundStyle(.secondary)
                    Text(push.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    /// From its definition: how much it only reads, how much it changes, and that changes
    /// wait for you (PolicyKit asks before every write).
    private var abilities: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("它能做的事").font(.title3.weight(.bold))
            GeometryReader { proxy in
                let total = Double(service.reads + service.changes)
                HStack(spacing: 2) {
                    Capsule().fill(service.tint.opacity(0.5)).frame(width: proxy.size.width * Double(service.reads) / max(total, 1))
                    Capsule().fill(service.tint)
                }
            }
            .frame(height: 8)
            HStack {
                Label("只看 \(service.reads) 件", systemImage: "eye").foregroundStyle(.secondary)
                Spacer()
                Label("会改动 \(service.changes) 件", systemImage: "pencil").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            if service.changes > 0 {
                Text("会改动的，每次都先问你。").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// App Store's privacy label: what follows from where it runs, a few fixed sentences.
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("隐私").font(.title3.weight(.bold))
            HStack(alignment: .top, spacing: 10) {
                privacyBox("lock.shield", "数据在哪", privacyWhere)
                privacyBox("hand.raised", "怎么收回", privacyRevoke)
            }
        }
    }

    private func privacyBox(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var needsShort: String {
        switch service.needs {
        case .nothing: "无"
        case .permission: "授权"
        case .signIn: "登录"
        }
    }

    private var needsSub: String {
        switch service.needs {
        case .nothing: "关注即可"
        case .permission: "这台手机"
        case .signIn(let where_): where_
        }
    }

    private var placeShort: String {
        switch service.place {
        case .device: "本机"
        case .composio, .cloud: "云端"
        }
    }

    private var placeSub: String {
        switch service.place {
        case .device(let device): device
        case .composio: "经 Composio"
        case .cloud: "floo"
        }
    }

    private var privacyWhere: String {
        switch service.place {
        case .device: "在你的手机上读，读到的不离开手机。"
        case .composio(let where_): "经 Composio 连接你的 \(where_) 账号，登录凭证存在 Composio。"
        case .cloud: "只用你告诉它的城市，不碰你的别的数据。"
        }
    }

    private var privacyRevoke: String {
        switch service.place {
        case .device: "取消关注，或在系统设置里关掉权限。"
        case .composio(let where_): "取消关注；也可以在 \(where_) 账号设置里收回。"
        case .cloud: "取消关注即可。"
        }
    }
}

// MARK: - Following

private struct FlooLetItKnowYou: View {
    let demo: FlooContactsDemo
    let service: FlooService
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var notYet: String?
    @State private var signingIn = false
    @State private var asking = false

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: -14) {
                Circle().fill(Color.teal.gradient).frame(width: 64, height: 64)
                    .overlay(Text("林").font(.title2.weight(.semibold)).foregroundStyle(.white))
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 4))
                FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 64)
                    .overlay(FlooIconShape().stroke(Color(uiColor: .systemBackground), lineWidth: 4))
            }
            .padding(.top, 24)
            VStack(spacing: 6) {
                Text("让 \(service.name) 认识你").font(.title3.weight(.bold))
                Text(explanation).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            if let notYet { Text(notYet).font(.footnote).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            Button(action: start) {
                Group {
                    if connecting {
                        HStack(spacing: 8) { ProgressView().tint(.white); Text("正在关注…") }
                    } else {
                        Text(action)
                    }
                }
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.accentColor, in: Capsule())
            }
            .disabled(connecting)
            .padding(.horizontal, 24)
            Button("先不了") { dismiss() }.font(.subheadline).padding(.bottom, 12)
        }
        .sheet(isPresented: $signingIn) {
            if case .signIn(let where_) = service.needs {
                FlooSignInSheet(provider: where_, service: service, ending: demo.ending) { result in
                    switch result {
                    case .signedIn(let account): connected(account)
                    case .refused: notYet = "\(where_) 没有同意，还没关注上。可以再试一次。"
                    case .closed: notYet = "登录没完成，还没关注上。"
                    }
                }
            }
        }
        .alert("“floo”想\(permission)", isPresented: $asking) {
            Button("不允许", role: .cancel) { notYet = "没有允许，还没关注上。" }
            Button("允许") { connected(nil) }
        }
    }

    private var explanation: String {
        switch service.place {
        case .device: "它要先能读到你手机上的数据，才能为你做事。读到的不离开手机。"
        case .composio(let where_): "它要先用你的 \(where_) 账号登录，才能为你做事。改动之前都会先问你。"
        case .cloud: "关注之后它就开始为你做事。"
        }
    }

    private var permission: String {
        if case .permission(let what) = service.needs { return what }
        return ""
    }

    private var action: String {
        switch service.needs {
        case .signIn(let where_): "用 \(where_) 登录并关注"
        default: "允许并关注"
        }
    }

    private func start() {
        switch service.needs {
        case .signIn: signingIn = true
        case .permission: asking = true
        case .nothing: connected(nil)
        }
    }

    private func connected(_ account: String?) {
        connecting = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))  // try?: cancelled, no matter
            demo.followed(service, account: account)
            dismiss()
        }
    }
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

private struct FlooGreetingToast: View {
    let service: FlooService
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(service.name) 给你发了消息").font(.subheadline.weight(.semibold))
                    Text(service.hello(nil)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
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
                    HStack(alignment: .top, spacing: 8) {
                        FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 30)
                        Text(service.hello(demo.following[service.id]?.account))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(spacing: 10) {
                Text("发消息").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { demo.path.append(.profile(service.id)) } label: {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 28)
                }
            }
        }
    }
}

#Preview {
    FlooContactsDestination()
}
