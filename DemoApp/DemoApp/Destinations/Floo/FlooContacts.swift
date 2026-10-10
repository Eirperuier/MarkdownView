//
//  FlooContacts.swift
//  DemoApp
//
//  Services met the way people meet on a social app: you discover them (the butler introduces
//  some, and you see the kind of thing each posts), open one's profile, follow it. Following
//  one that has to know you first asks you to let it (signing in, or allowing a permission),
//  framed as that, not as setup. Once you follow, it writes to you first. Muting, a nickname
//  and unfollowing sit under 已关注, as on any social app. Played from a script: how a sign-in
//  ends is picked in the menu. `-flooContacts YES` opens it; `-flooContactsPath
//  "profile:gmail"` opens a profile, `"chat:health"` a conversation; `-flooContactsFollow gmail`
//  opens on following one.
//

import SwiftUI

// MARK: - Services

/// A service as people meet it: who it is, how it talks, what it posts.
struct FlooService: Identifiable, Hashable, Sendable {
    enum Needs: Hashable, Sendable {
        /// Nothing: following is one tap.
        case nothing
        /// A permission on this phone, like Health's.
        case permission(String)
        /// Signing in to an account somewhere else, like Google's.
        case signIn(String)
    }

    let id: String
    let name: String
    let tint: Color
    /// Who it is, in its own words.
    let bio: String
    /// How often it speaks up.
    let cadence: String
    /// Made by whom, the way a profile shows a verified maker.
    let maker: String
    let needs: Needs
    /// What it reads and where that stays, said plainly.
    let privacy: String
    /// Services it works with.
    let worksWith: [String]
    /// The kind of thing it posts.
    let posts: [FlooSamplePost]
    /// What it writes first once followed; `account` is whom it signed in as.
    let hello: @Sendable (_ account: String?) -> String

    /// Where its definition says its icon is: the server's copy (floo docs/app.md 3.1).
    var icon: URL? { URL(string: "https://floo-server.fly.dev/v1/icons/\(id).png") }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func named(_ id: String) -> FlooService? { all.first { $0.id == id } }
}

/// One thing a service might post: a line, and maybe a card under it.
struct FlooSamplePost: Hashable, Sendable {
    let time: String
    let text: String
    var card: (title: String, lines: [String])? = nil

    static func == (a: Self, b: Self) -> Bool { a.time == b.time && a.text == b.text }
    func hash(into hasher: inout Hasher) { hasher.combine(text) }
}

extension FlooService {
    static let all: [FlooService] = [
        FlooService(
            id: "weather", name: "天气", tint: .cyan,
            bio: "我不报每天的天气。会碍着你安排的时候，我提前说。",
            cadence: "下雨、降温、碍着安排时才说", maker: "和风天气", needs: .nothing,
            privacy: "只用你告诉我的城市。", worksWith: ["calendar"],
            posts: [
                FlooSamplePost(time: "周五 20:10", text: "周六下午苏州有雷阵雨，你约的露营在 3 点。要不要改到周日上午？",
                               card: ("周六 苏州", ["14:00 起 雷阵雨 80%", "周日上午 晴 24°"])),
                FlooSamplePost(time: "周一 7:40", text: "今天比昨天冷 9 度，出门带件外套。"),
            ],
            hello: { _ in "你好，我是天气。你常在哪个城市？之后天气要碍着你的事，我会提前说；平常不打扰你。" }
        ),
        FlooService(
            id: "health", name: "健康", tint: .pink,
            bio: "我看着你的睡眠和步数，不评判，只在值得注意时说一句。",
            cadence: "一周一两次", maker: "Apple 健康 · 本机", needs: .permission("读取健康数据"),
            privacy: "数据不离开这台手机。", worksWith: ["calendar"],
            posts: [
                FlooSamplePost(time: "今天 8:02", text: "这周有三天睡不到 6 小时，都是开完晚会的那几天。",
                               card: ("这周睡眠", ["平均 6 小时 12 分", "比上周少 48 分钟"])),
            ],
            hello: { _ in "你好，我是健康，能看到这台手机上的睡眠和步数了。睡得不好的那几天，我会在早上说一声。" }
        ),
        FlooService(
            id: "calendar", name: "日历", tint: .red,
            bio: "撞车的安排、该出发的时间，我替你看着。",
            cadence: "有事才说", maker: "Apple 日历 · 本机", needs: .permission("访问日历"),
            privacy: "数据不离开这台手机。", worksWith: ["weather", "gmail"],
            posts: [
                FlooSamplePost(time: "明天 9:30", text: "明天 10 点的评审和牙医撞了，牙医能改到周四下午。",
                               card: ("明天", ["10:00 设计评审", "10:30 牙医（撞了）"])),
            ],
            hello: { _ in "你好，我是日历。看到撞车的安排，我会提前告诉你；要改什么，跟我说就行。" }
        ),
        FlooService(
            id: "gmail", name: "Gmail", tint: Color(red: 0.86, green: 0.27, blue: 0.22),
            bio: "邮件太多回不过来？我挑出值得回的，先替你拟好草稿。",
            cadence: "一天一两次", maker: "Google", needs: .signIn("Google"),
            privacy: "经你在 Google 同意后读邮件；随时可以在 Google 账号里收回。", worksWith: ["calendar", "googlecalendar"],
            posts: [
                FlooSamplePost(time: "今天 9:15", text: "早上 23 封，值得回的 2 封：房东问续租，王磊要周五的数据。草稿都拟好了。",
                               card: ("值得回", ["房东 · 续租的事", "王磊 · 周五要数据"])),
                FlooSamplePost(time: "昨天 18:40", text: "你等的那张发票到了。"),
            ],
            hello: { account in
                "你好，我是 Gmail，认识你的 \(account ?? "邮箱")了。值得回的邮件我会挑出来、先拟好草稿；发出去之前都会先问你。"
            }
        ),
        FlooService(
            id: "googlecalendar", name: "Google 日历", tint: .blue,
            bio: "Google 上的邀请和日程，我和手机上的日历一起看。",
            cadence: "有新邀请时", maker: "Google", needs: .signIn("Google"),
            privacy: "经你在 Google 同意后读日程；随时可以收回。", worksWith: ["calendar", "gmail"],
            posts: [
                FlooSamplePost(time: "今天 11:02", text: "李然邀你周三 3 点开会，那时你在高铁上。要回个“改天”吗？"),
            ],
            hello: { account in "你好，我是 Google 日历，认识你的 \(account ?? "账号")了。有人邀请你、时间变了，我会告诉你。" }
        ),
        FlooService(
            id: "github", name: "GitHub", tint: .black,
            bio: "有人等你 review、你的 PR 有了回复，我才出声。",
            cadence: "有动静才说", maker: "GitHub", needs: .signIn("GitHub"),
            privacy: "经你在 GitHub 同意后读仓库动态；随时可以在 GitHub 设置里收回。", worksWith: ["slack"],
            posts: [
                FlooSamplePost(time: "今天 14:20", text: "3 个 PR 在等你 review，最久的等了两天。",
                               card: ("等你", ["#412 登录页改版 · 2 天", "#418 修复同步", "#420 升级依赖"])),
            ],
            hello: { account in "你好，我是 GitHub，认识 \(account ?? "你")了。有人等你 review、你的 PR 有了回复，我会说。" }
        ),
        FlooService(
            id: "notion", name: "Notion", tint: .gray,
            bio: "要找哪页、要记什么，跟我说。",
            cadence: "你找我时", maker: "Notion", needs: .signIn("Notion"),
            privacy: "只读你在 Notion 里允许的页面。", worksWith: ["slack", "gmail"],
            posts: [
                FlooSamplePost(time: "周四 16:00", text: "你上周说要整理的“发布清单”，还有 4 项没勾。"),
            ],
            hello: { account in "你好，我是 Notion，认识 \(account ?? "你的工作区")了。要找什么页面、记什么，跟我说。" }
        ),
        FlooService(
            id: "slack", name: "Slack", tint: .purple,
            bio: "群里刷屏我不管，有人 @你、等你回，我提醒你。",
            cadence: "有人等你时", maker: "Slack", needs: .signIn("Slack"),
            privacy: "经你在 Slack 同意后读消息；随时可以收回。", worksWith: ["github", "notion"],
            posts: [
                FlooSamplePost(time: "今天 10:05", text: "#design 里小周 @了你两次，问图标的尺寸。"),
            ],
            hello: { account in "你好，我是 Slack，认识 \(account ?? "你的工作区")了。有人 @你、等你回，我会告诉你。" }
        ),
    ]
}

/// How the sign-in ends, picked in the demo's menu.
enum FlooSignInEnding: String, CaseIterable, Identifiable {
    case signedIn = "登录成功"
    case cancelled = "中途关掉"
    case failed = "对方拒绝"

    var id: String { rawValue }
}

/// A service you follow: whom it knows you as, what you call it, whether it's muted.
struct FlooFollowing: Hashable {
    var account: String?
    var nickname: String = ""
    var quiet = false
    /// It wrote to you and you haven't looked.
    var unread = false
}

@MainActor @Observable
final class FlooContactsDemo {
    var following: [String: FlooFollowing] = [
        "weather": FlooFollowing(account: nil),
        "health": FlooFollowing(account: nil),
    ]
    /// The butler's introductions, with why.
    var introduced: [(service: String, why: String)] = [
        ("github", "你最近常提到 PR 和 review"),
        ("gmail", "你说过邮件太多回不过来"),
        ("calendar", "你上周两次记错了会的时间"),
    ]
    var ending: FlooSignInEnding = .signedIn
    var path: [FlooContactsRoute] = FlooContactsRoute.launchPath
    /// A follow being asked for: the sheet that lets it know you.
    var asking: FlooService?
    /// Just followed: the toast saying it wrote to you.
    var greeted: FlooService?

    func reset() {
        let fresh = FlooContactsDemo()
        following = fresh.following
        introduced = fresh.introduced
        path = []
        asking = nil
        greeted = nil
    }

    func name(_ service: FlooService) -> String {
        guard let nickname = following[service.id]?.nickname, !nickname.isEmpty else { return service.name }
        return nickname
    }

    /// Following starts here: at once when it needs nothing, else it asks.
    func follow(_ service: FlooService) {
        if case .nothing = service.needs {
            followed(service, account: nil)
        } else {
            asking = service
        }
    }

    func followed(_ service: FlooService, account: String?) {
        following[service.id] = FlooFollowing(account: account, unread: true)
        introduced.removeAll { $0.service == service.id }
        Task {
            try? await Task.sleep(for: .seconds(1.2))  // try?: cancelled, no matter
            withAnimation(.snappy) { greeted = service }
            try? await Task.sleep(for: .seconds(4))  // try?: cancelled, no matter
            withAnimation(.snappy) { if greeted == service { greeted = nil } }
        }
    }

    func unfollow(_ service: FlooService) {
        following[service.id] = nil
    }

    func open(_ service: FlooService) {
        following[service.id]?.unread = false
        greeted = nil
        path.append(.chat(service.id))
    }
}

enum FlooContactsRoute: Hashable {
    case profile(String)
    case chat(String)

    /// `profile:<id>`, `chat:<id>`, space-separated.
    static var launchPath: [FlooContactsRoute] {
        (UserDefaults.standard.string(forKey: "flooContactsPath") ?? "").split(separator: " ").compactMap { step in
            let parts = step.split(separator: ":").map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "profile": return .profile(parts[1])
            case "chat": return .chat(parts[1])
            default: return nil
            }
        }
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
                    case .profile(let id): FlooServiceProfile(demo: demo, service: FlooService.named(id)!)
                    case .chat(let id): FlooServiceChat(demo: demo, service: FlooService.named(id)!)
                    }
                }
        }
        .sheet(item: $demo.asking) { service in
            FlooLetItKnowYou(demo: demo, service: service)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        // `-flooContactsFollow gmail` opens on following it.
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

    private var notFollowed: [FlooService] { FlooService.all.filter { demo.following[$0.id] == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                followingRow
                if !demo.introduced.isEmpty { introductions }
                feed
            }
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("发现")
        .searchable(text: $search, prompt: "找服务，或说说你想让谁帮忙")
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

    /// Like stories: whom you follow, a ring on those who wrote to you.
    private var followingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                VStack(spacing: 6) {
                    FlooGlyphIcon(symbol: "sparkles", tint: .indigo, size: 58)
                        .padding(3)
                    Text("管家").font(.caption)
                }
                ForEach(FlooService.all.filter { demo.following[$0.id] != nil }) { service in
                    Button {
                        demo.open(service)
                    } label: {
                        VStack(spacing: 6) {
                            FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 58)
                                .padding(3)
                                .overlay(ring(demo.following[service.id]?.unread == true))
                            Text(demo.name(service)).font(.caption).foregroundStyle(.primary).lineLimit(1)
                        }
                        .frame(width: 70)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// A story ring: it wrote to you and you haven't looked.
    private func ring(_ unread: Bool) -> some View {
        let colors: [Color] = unread ? [.orange, .pink, .purple] : [.clear]
        return FlooIconShape(inset: -1)
            .stroke(LinearGradient(colors: colors, startPoint: .bottomLeading, endPoint: .topTrailing), lineWidth: 2.5)
    }

    /// The butler's introductions: follow straight from the card.
    private var introductions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                FlooGlyphIcon(symbol: "sparkles", tint: .indigo, size: 20)
                Text("管家给你介绍").font(.headline)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(demo.introduced, id: \.service) { item in
                        if let service = FlooService.named(item.service) {
                            FlooIntroductionCard(demo: demo, service: service, why: item.why)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// What they post, as a feed: meet them by what they'd say to you.
    private var feed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("看看它们会发什么").font(.headline).padding(.horizontal, 16)
            ForEach(notFollowed) { service in
                if let post = service.posts.first {
                    FlooPostView(demo: demo, service: service, post: post, showsFollow: true)
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}

private struct FlooIntroductionCard: View {
    let demo: FlooContactsDemo
    let service: FlooService
    let why: String

    var body: some View {
        VStack(spacing: 8) {
            Button {
                demo.path.append(.profile(service.id))
            } label: {
                VStack(spacing: 8) {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 64)
                    Text(service.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(why).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .buttonStyle(.plain)
            FlooFollowButton(demo: demo, service: service, compact: false)
        }
        .padding(14)
        .frame(width: 168)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// 关注, 已关注 ▾ or 回关-style states, as a social app's follow button.
private struct FlooFollowButton: View {
    let demo: FlooContactsDemo
    let service: FlooService
    var compact: Bool

    var body: some View {
        if demo.following[service.id] != nil {
            Menu {
                FlooFollowingMenu(demo: demo, service: service)
            } label: {
                label("已关注", symbol: "chevron.down", filled: false)
            }
        } else {
            Button {
                demo.follow(service)
            } label: {
                label("关注", symbol: "plus", filled: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func label(_ title: String, symbol: String, filled: Bool) -> some View {
        HStack(spacing: 4) {
            if filled { Image(systemName: symbol).font(.caption.weight(.bold)) }
            Text(title).font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
            if !filled { Image(systemName: symbol).font(.caption2.weight(.bold)) }
        }
        .foregroundStyle(filled ? Color.white : Color.primary)
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, compact ? 5 : 8)
        .frame(maxWidth: compact ? nil : .infinity)
        .background(
            filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)),
            in: Capsule()
        )
    }
}

/// Under 已关注, as on any social app: what you call it, mute, unfollow.
private struct FlooFollowingMenu: View {
    let demo: FlooContactsDemo
    let service: FlooService

    var body: some View {
        Button("发消息", systemImage: "message") { demo.open(service) }
        Button(
            demo.following[service.id]?.quiet == true ? "取消少打扰" : "少打扰",
            systemImage: demo.following[service.id]?.quiet == true ? "bell" : "bell.slash"
        ) {
            demo.following[service.id]?.quiet.toggle()
        }
        Button("备注名…", systemImage: "pencil") {
            demo.following[service.id]?.nickname = service.id == "gmail" ? "工作邮箱" : ""
        }
        Button("取消关注", systemImage: "person.badge.minus", role: .destructive) { demo.unfollow(service) }
    }
}

/// A post as the feed shows it.
private struct FlooPostView: View {
    let demo: FlooContactsDemo
    let service: FlooService
    let post: FlooSamplePost
    var showsFollow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    demo.path.append(.profile(service.id))
                } label: {
                    HStack(spacing: 10) {
                        FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(showsFollow ? "示例 · \(service.cadence)" : post.time)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if showsFollow { FlooFollowButton(demo: demo, service: service, compact: true) }
            }
            Text(post.text).font(.body)
            if let card = post.card {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.caption.weight(.semibold)).foregroundStyle(service.tint)
                    ForEach(card.lines, id: \.self) { Text($0).font(.subheadline) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(service.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Profile

private struct FlooServiceProfile: View {
    let demo: FlooContactsDemo
    let service: FlooService
    @State private var tab = 0

    private var following: FlooFollowing? { demo.following[service.id] }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                LinearGradient(colors: [service.tint.opacity(0.55), service.tint.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 180)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom) {
                        FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 88)
                            .padding(4)
                            .background(Color(uiColor: .systemBackground), in: FlooIconShape().inset(by: -4))
                        Spacer()
                        HStack(spacing: 8) {
                            if following != nil {
                                Button {
                                    demo.open(service)
                                } label: {
                                    Text("发消息").font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            FlooFollowButton(demo: demo, service: service, compact: true)
                        }
                        .padding(.bottom, 6)
                    }
                    .padding(.top, -44)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(demo.name(service)).font(.title2.weight(.bold))
                            if following?.quiet == true { Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(.secondary) }
                        }
                        Label(service.maker, systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    Text(service.bio).font(.body)
                    Label(service.cadence, systemImage: "bubble.left.and.text.bubble.right")
                        .font(.subheadline).foregroundStyle(.secondary)
                    worksWith
                    Picker("", selection: $tab) {
                        Text("动态").tag(0)
                        Text("关于").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 6)
                    if tab == 0 {
                        ForEach(service.posts, id: \.self) { post in
                            FlooPostView(demo: demo, service: service, post: post)
                        }
                    } else {
                        about
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Like mutual friends: who it works alongside, the ones you follow first.
    private var worksWith: some View {
        let friends = service.worksWith.compactMap(FlooService.named)
        let names = friends.map { demo.following[$0.id] != nil ? "\($0.name)" : $0.name }
        return HStack(spacing: 8) {
            HStack(spacing: -8) {
                ForEach(friends) { friend in
                    FlooServiceIcon(url: friend.icon, name: friend.name, tint: friend.tint, size: 22)
                        .overlay(FlooIconShape().stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 2))
                }
            }
            Text("和 \(names.joined(separator: "、")) 一起工作").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            aboutRow("hand.raised", "要认识你", knowing)
            aboutRow("lock", "你的数据", service.privacy)
            if let account = following?.account {
                aboutRow("person.crop.circle", "认识的是", account)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func aboutRow(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(service.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var knowing: String {
        switch service.needs {
        case .nothing: "不用，关注就行。"
        case .permission(let what): "关注时请你允许它\(what)。"
        case .signIn(let where_): "关注时用你的 \(where_) 账号登录一次。"
        }
    }
}

// MARK: - Following

/// Before following one that has to know you: who it is, why it asks, and the one step.
private struct FlooLetItKnowYou: View {
    let demo: FlooContactsDemo
    let service: FlooService
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .ready
    @State private var signingIn = false
    @State private var asking = false

    enum Stage: Equatable {
        case ready
        case connecting
        case notYet(String)
    }

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
                Text(title).font(.title3.weight(.bold))
                Text(explanation).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            if case .notYet(let why) = stage {
                Text(why).font(.footnote).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Button(action: start) {
                Group {
                    if stage == .connecting {
                        HStack(spacing: 8) { ProgressView().tint(.white); Text("正在关注…") }
                    } else {
                        Text(action)
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor, in: Capsule())
            }
            .disabled(stage == .connecting)
            .padding(.horizontal, 24)
            Button("先不了") { dismiss() }
                .font(.subheadline)
                .padding(.bottom, 12)
        }
        .sheet(isPresented: $signingIn) {
            if case .signIn(let where_) = service.needs {
                FlooSignInSheet(provider: where_, service: service, ending: demo.ending) { result in
                    switch result {
                    case .signedIn(let account): connected(account)
                    case .refused: stage = .notYet("\(where_) 没有同意，还没关注上。可以再试一次。")
                    case .closed: stage = .notYet("登录没完成，还没关注上。")
                    }
                }
            }
        }
        .alert("“floo”想\(permission)", isPresented: $asking) {
            Button("不允许", role: .cancel) { stage = .notYet("没有允许，还没关注上。") }
            Button("允许") { connected(nil) }
        } message: {
            Text("\(service.name)用它为你做事。\(service.privacy)")
        }
    }

    private var title: String {
        switch service.needs {
        case .signIn: "让 \(service.name) 认识你"
        default: "让 \(service.name) 看到你的\(service.id == "health" ? "健康数据" : "日历")"
        }
    }

    private var explanation: String {
        "它要先认识你，才能为你做事。\(service.privacy)"
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
        stage = .connecting
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
                    Button("关闭") {
                        dismiss()
                        done(.closed)
                    }
                }
            }
        }
    }
}

/// It wrote to you: a banner, as a DM notification on a social app.
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

/// A DM: it wrote first when you followed.
private struct FlooServiceChat: View {
    let demo: FlooContactsDemo
    let service: FlooService

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 64)
                        Text(demo.name(service)).font(.headline)
                        Text("你关注了它 · \(service.cadence)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)
                    HStack(alignment: .top, spacing: 8) {
                        FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 30)
                        Text(service.hello(demo.following[service.id]?.account))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color(uiColor: .secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(spacing: 10) {
                Text("发消息")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle(demo.name(service))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    demo.path.append(.profile(service.id))
                } label: {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: service.tint, size: 28)
                }
            }
        }
    }
}

#Preview {
    FlooContactsDestination()
}
