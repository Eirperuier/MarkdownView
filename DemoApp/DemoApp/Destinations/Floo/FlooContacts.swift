//
//  FlooContacts.swift
//  DemoApp
//
//  Adding a service the way you add a friend: the services you have are your contacts; you
//  find one, read its card, add it (signing in or allowing what it needs on the way), wait a
//  moment while it is let in, and its conversation opens with it saying hello. Played from a
//  script: how the sign-in ends is picked in the menu. `-flooContacts YES` opens it;
//  `-flooContactsPath "profile:gmail request:gmail"` opens it there.
//

import SwiftUI

// MARK: - Services

/// What a service shows people: its presentation (name, icon, colour, one line) and what
/// adding it takes.
struct FlooService: Identifiable, Hashable, Sendable {
    enum Needs: Hashable, Sendable {
        /// Nothing: added at once.
        case nothing
        /// A permission on this phone, like Health's.
        case permission(String)
        /// Signing in to an account somewhere else, like Google's.
        case signIn(String)
    }

    let id: String
    let name: String
    let symbol: String
    let tint: Color
    let blurb: String
    let category: String
    let needs: Needs
    /// Where what it reads stays, said plainly.
    let data: String
    /// What it says first, once added; `account` is the one signed in to.
    let hello: @Sendable (_ account: String?) -> String

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [FlooService] = [
        FlooService(
            id: "weather", name: "天气", symbol: "cloud.sun.fill", tint: .cyan,
            blurb: "只在影响你安排时才说话。", category: "生活", needs: .nothing,
            data: "只用你告诉它的城市。",
            hello: { _ in "我是天气。你在哪个城市？之后天气要碍着你的安排，我会提前说；平常不打扰你。" }
        ),
        FlooService(
            id: "health", name: "健康", symbol: "heart.fill", tint: .pink,
            blurb: "睡眠、步数、运动。", category: "生活", needs: .permission("读取健康数据"),
            data: "数据不离开手机。",
            hello: { _ in "我是健康，能看到你这台手机上的睡眠和步数了。睡得不好的那几天，我会在早上说一声。" }
        ),
        FlooService(
            id: "calendar", name: "日历", symbol: "calendar", tint: .red,
            blurb: "提前告诉你撞车的日程。", category: "效率", needs: .permission("访问日历"),
            data: "数据不离开手机。",
            hello: { _ in "我是日历。看到撞车的安排，我会提前告诉你；要改什么，跟我说就行。" }
        ),
        FlooService(
            id: "gmail", name: "Gmail", symbol: "envelope.fill", tint: Color(red: 0.86, green: 0.27, blue: 0.22),
            blurb: "挑出值得回的，先拟好草稿。", category: "效率", needs: .signIn("Google"),
            data: "经 Google 授权读取，可随时在 Google 账号里收回。",
            hello: { account in
                "我是 Gmail，连上了 \(account ?? "你的邮箱")。值得回的邮件我会挑出来、先拟好草稿；发出去之前都会先问你。"
            }
        ),
        FlooService(
            id: "googlecalendar", name: "Google 日历", symbol: "calendar.badge.clock", tint: .blue,
            blurb: "Google 上的日程，和手机上的放一起看。", category: "效率", needs: .signIn("Google"),
            data: "经 Google 授权读取，可随时在 Google 账号里收回。",
            hello: { account in "我是 Google 日历，连上了 \(account ?? "你的账号")。有人邀请你、时间变了，我会告诉你。" }
        ),
        FlooService(
            id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", tint: .black,
            blurb: "等你的 PR 和 issue，有动静才提。", category: "工作", needs: .signIn("GitHub"),
            data: "经 GitHub 授权读取，可随时在 GitHub 设置里收回。",
            hello: { account in "我是 GitHub，连上了 \(account ?? "你的账号")。有人等你 review、你的 PR 有了回复，我会说。" }
        ),
        FlooService(
            id: "notion", name: "Notion", symbol: "doc.text.fill", tint: .gray,
            blurb: "找页面、记下要记的。", category: "工作", needs: .signIn("Notion"),
            data: "只读你在 Notion 里允许它看的页面。",
            hello: { account in "我是 Notion，连上了 \(account ?? "你的工作区")。要找什么页面、记什么，跟我说。" }
        ),
        FlooService(
            id: "slack", name: "Slack", symbol: "number", tint: .purple,
            blurb: "有人 @你、等你回，才提醒。", category: "工作", needs: .signIn("Slack"),
            data: "经 Slack 授权读取，可随时在 Slack 里收回。",
            hello: { account in "我是 Slack，连上了 \(account ?? "你的工作区")。有人 @你、等你回，我会告诉你。" }
        ),
    ]

    static func named(_ id: String) -> FlooService? { all.first { $0.id == id } }
}

/// How the sign-in ends, picked in the demo's menu.
enum FlooSignInEnding: String, CaseIterable, Identifiable {
    case signedIn = "登录成功"
    case cancelled = "中途关掉"
    case failed = "对方拒绝"

    var id: String { rawValue }
}

/// A service you have: whom you signed in as, what you call it, whether it keeps quiet.
struct FlooAdded: Hashable {
    var account: String?
    var nickname: String
    var quiet: Bool
}

@Observable
final class FlooContactsDemo {
    var added: [String: FlooAdded] = [
        "weather": FlooAdded(account: nil, nickname: "", quiet: false),
        "health": FlooAdded(account: nil, nickname: "", quiet: false),
    ]
    /// Introduced by the butler, not yet added: 新的服务.
    var introduced: [(service: String, why: String)] = [
        ("github", "你常提到 PR 和 review"),
        ("gmail", "你说过邮件太多回不过来"),
    ]
    var ending: FlooSignInEnding = .signedIn
    var path: [FlooContactsRoute] = FlooContactsRoute.launchPath

    func reset() {
        let fresh = FlooContactsDemo()
        added = fresh.added
        introduced = fresh.introduced
        path = []
    }

    var contacts: [FlooService] {
        FlooService.all.filter { added[$0.id] != nil }
    }

    func add(_ service: FlooService, account: String?, nickname: String, quiet: Bool) {
        added[service.id] = FlooAdded(account: account, nickname: nickname, quiet: quiet)
        introduced.removeAll { $0.service == service.id }
    }

    func remove(_ service: FlooService) {
        added[service.id] = nil
    }
}

enum FlooContactsRoute: Hashable {
    case find
    case introduced
    case profile(String)
    case request(String)
    case chat(String, fresh: Bool)

    /// `find`, `introduced`, `profile:<id>`, `request:<id>`, `chat:<id>`, space-separated.
    static var launchPath: [FlooContactsRoute] {
        (UserDefaults.standard.string(forKey: "flooContactsPath") ?? "").split(separator: " ").compactMap { step in
            let parts = step.split(separator: ":").map(String.init)
            switch (parts.first, parts.count) {
            case ("find", 1): return .find
            case ("introduced", 1): return .introduced
            case ("profile", 2): return .profile(parts[1])
            case ("request", 2): return .request(parts[1])
            case ("chat", 2): return .chat(parts[1], fresh: false)
            default: return nil
            }
        }
    }
}

// MARK: - Contacts

struct FlooContactsDestination: View {
    @State private var demo = FlooContactsDemo()

    static var launches: Bool { UserDefaults.standard.bool(forKey: "flooContacts") }

    var body: some View {
        NavigationStack(path: $demo.path) {
            List {
                Section {
                    NavigationLink(value: FlooContactsRoute.find) {
                        FlooContactRow(symbol: "magnifyingglass", tint: .orange, name: "添加服务", line: nil)
                    }
                    NavigationLink(value: FlooContactsRoute.introduced) {
                        HStack {
                            FlooContactRow(symbol: "person.badge.plus", tint: .green, name: "新的服务", line: nil)
                            if !demo.introduced.isEmpty {
                                Spacer()
                                Text("\(demo.introduced.count)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.red, in: Capsule())
                            }
                        }
                    }
                }
                Section {
                    FlooContactRow(symbol: "sparkles", tint: .indigo, name: "管家", line: "一直都在")
                    ForEach(demo.contacts) { service in
                        NavigationLink(value: FlooContactsRoute.profile(service.id)) {
                            FlooContactRow(service: service, added: demo.added[service.id])
                        }
                    }
                } header: {
                    Text("我的服务")
                }
            }
            .navigationTitle("服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("登录结果", selection: $demo.ending) {
                            ForEach(FlooSignInEnding.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button("重来", systemImage: "arrow.counterclockwise") { demo.reset() }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: FlooContactsRoute.find) {
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .navigationDestination(for: FlooContactsRoute.self) { route in
                switch route {
                case .find: FlooFindService(demo: demo)
                case .introduced: FlooIntroduced(demo: demo)
                case .profile(let id): FlooServiceProfile(demo: demo, service: FlooService.named(id)!)
                case .request(let id): FlooAddRequest(demo: demo, service: FlooService.named(id)!)
                case .chat(let id, let fresh): FlooServiceChat(demo: demo, service: FlooService.named(id)!, fresh: fresh)
                }
            }
        }
    }
}

struct FlooServiceAvatar: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

private struct FlooContactRow: View {
    let symbol: String
    let tint: Color
    let name: String
    let line: String?

    init(symbol: String, tint: Color, name: String, line: String?) {
        self.symbol = symbol
        self.tint = tint
        self.name = name
        self.line = line
    }

    init(service: FlooService, added: FlooAdded?) {
        self.init(
            symbol: service.symbol, tint: service.tint,
            name: added.map { $0.nickname.isEmpty ? service.name : $0.nickname } ?? service.name,
            line: added?.account ?? service.blurb
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            FlooServiceAvatar(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let line {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Finding one

private struct FlooFindService: View {
    let demo: FlooContactsDemo
    @State private var search = ""

    private var found: [FlooService] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return FlooService.all.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.blurb.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            ForEach(["生活", "效率", "工作"], id: \.self) { category in
                let services = found.filter { $0.category == category }
                if !services.isEmpty {
                    Section(category) {
                        ForEach(services) { service in
                            NavigationLink(value: FlooContactsRoute.profile(service.id)) {
                                HStack {
                                    FlooContactRow(service: service, added: nil)
                                    Spacer()
                                    if demo.added[service.id] != nil {
                                        Text("已添加").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "名字，或想让它做什么")
        .navigationTitle("添加服务")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FlooIntroduced: View {
    let demo: FlooContactsDemo

    var body: some View {
        List {
            if demo.introduced.isEmpty {
                Text("暂时没有").foregroundStyle(.secondary)
            }
            ForEach(demo.introduced, id: \.service) { item in
                if let service = FlooService.named(item.service) {
                    NavigationLink(value: FlooContactsRoute.profile(service.id)) {
                        HStack(spacing: 12) {
                            FlooServiceAvatar(symbol: service.symbol, tint: service.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                Text("管家介绍：\(item.why)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("查看")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
        }
        .navigationTitle("新的服务")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Its card

private struct FlooServiceProfile: View {
    let demo: FlooContactsDemo
    let service: FlooService

    private var added: FlooAdded? { demo.added[service.id] }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    FlooServiceAvatar(symbol: service.symbol, tint: service.tint, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(added.map { $0.nickname.isEmpty ? service.name : $0.nickname } ?? service.name)
                            .font(.title2.weight(.semibold))
                        if let added, !added.nickname.isEmpty {
                            Text("名字：\(service.name)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let account = added?.account {
                            Text("账号：\(account)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(service.blurb).font(.subheadline)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("需要", value: needs)
                LabeledContent("数据", value: service.data)
                if let added {
                    LabeledContent("少打扰", value: added.quiet ? "开" : "关")
                }
            }
            Section {
                if added != nil {
                    Button {
                        demo.path.append(.chat(service.id, fresh: false))
                    } label: {
                        Label("发消息", systemImage: "message.fill").frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        demo.path.append(.request(service.id))
                    } label: {
                        Text("添加").fontWeight(.semibold).foregroundStyle(.white).frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.green)
                }
            }
            if added != nil {
                Section {
                    Button("删除", role: .destructive) {
                        demo.remove(service)
                        demo.path.removeLast()
                    }
                    .frame(maxWidth: .infinity)
                } footer: {
                    Text("删除后不再为你做事；和它的聊天记录还在。")
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var needs: String {
        switch service.needs {
        case .nothing: "什么都不用"
        case .permission(let what): "在这台手机上\(what)"
        case .signIn(let where_): "登录你的 \(where_) 账号"
        }
    }
}

// MARK: - Adding it

/// WeChat's 申请添加朋友: what you call it and how much it may bother you, then the one
/// step it needs.
private struct FlooAddRequest: View {
    let demo: FlooContactsDemo
    let service: FlooService
    @State private var nickname = ""
    @State private var quiet = false
    @State private var stage: Stage = .ready

    enum Stage: Equatable {
        case ready
        case signingIn
        case asking
        /// Signed in; waiting for it to be let in.
        case adding(String?)
        case notAdded(String)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    FlooServiceAvatar(symbol: service.symbol, tint: service.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name).font(.headline)
                        Text(service.blurb).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                TextField(service.name, text: $nickname)
            } header: {
                Text("给它起个名字")
            } footer: {
                Text("有两个邮箱时，叫它「工作邮箱」就分得清。")
            }
            Section {
                Toggle("少打扰", isOn: $quiet)
            } footer: {
                Text(quiet ? "只在要紧时来找你，别的放进它的聊天里等你看。" : "有值得说的就来找你。")
            }
            if case .notAdded(let why) = stage {
                Section {
                    Label(why, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: start) {
                Group {
                    if case .adding = stage {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("正在添加…")
                        }
                    } else {
                        Text(action)
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.green, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(stage != .ready && !isNotAdded)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle("添加 \(service.name)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { stage == .signingIn }, set: { if !$0 && stage == .signingIn { closed() } })) {
            if case .signIn(let where_) = service.needs {
                FlooSignInSheet(provider: where_, service: service, ending: demo.ending) { result in
                    switch result {
                    case .signedIn(let account): adding(account)
                    case .refused: stage = .notAdded("\(where_) 没有同意，没加上。可以再试一次。")
                    case .closed: closed()
                    }
                }
                .interactiveDismissDisabled(false)
            }
        }
        .alert(
            "“floo”想\(permission)",
            isPresented: Binding(get: { stage == .asking }, set: { _ in })
        ) {
            Button("不允许", role: .cancel) { stage = .notAdded("没有允许，没加上。可以在设置里打开后再试。") }
            Button("允许") { adding(nil) }
        } message: {
            Text("\(service.name)用它为你做事。\(service.data)")
        }
    }

    private var isNotAdded: Bool {
        if case .notAdded = stage { return true }
        return false
    }

    private var permission: String {
        if case .permission(let what) = service.needs { return what }
        return ""
    }

    private var action: String {
        switch service.needs {
        case .nothing: "添加"
        case .permission: "允许并添加"
        case .signIn(let where_): "登录 \(where_) 并添加"
        }
    }

    private func start() {
        switch service.needs {
        case .nothing: adding(nil)
        case .permission: stage = .asking
        case .signIn: stage = .signingIn
        }
    }

    private func closed() {
        stage = .notAdded("登录没完成，没加上。")
    }

    /// The server is letting it in: a moment, then its conversation opens.
    private func adding(_ account: String?) {
        stage = .adding(account)
        Task {
            try? await Task.sleep(for: .seconds(1.6))  // try?: cancelled, no matter
            demo.add(service, account: account, nickname: nickname.trimmingCharacters(in: .whitespaces), quiet: quiet)
            demo.path = [.chat(service.id, fresh: true)]
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
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption2)
                    Text(host).font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))
                List {
                    Section {
                        ForEach(accounts, id: \.self) { account in
                            Button {
                                finish(account)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(String(account.prefix(1)).uppercased())
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(Color.teal, in: Circle())
                                    Text(account).foregroundStyle(.primary)
                                }
                            }
                        }
                    } header: {
                        Text("选择一个 \(provider) 账号，继续使用 floo 的「\(service.name)」")
                            .textCase(nil)
                    }
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

    private var host: String {
        switch provider {
        case "Google": "accounts.google.com"
        case "GitHub": "github.com"
        default: "\(provider.lowercased()).com"
        }
    }

    private func finish(_ account: String) {
        dismiss()
        switch ending {
        case .signedIn: done(.signedIn(account))
        case .cancelled: done(.closed)
        case .failed: done(.refused)
        }
    }
}

// MARK: - Its conversation

/// Opens on adding it, as WeChat's chat does once a friend accepts: a line saying you're
/// connected, then it says hello.
private struct FlooServiceChat: View {
    let demo: FlooContactsDemo
    let service: FlooService
    let fresh: Bool
    @State private var said = false

    private var added: FlooAdded? { demo.added[service.id] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    Text(fresh ? "你添加了\(name)，现在可以开始聊天了" : "你添加了\(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        .padding(.top, 16)
                    if said || !fresh {
                        HStack(alignment: .top, spacing: 8) {
                            FlooServiceAvatar(symbol: service.symbol, tint: service.tint, size: 32)
                            Text(service.hello(added?.account))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color(uiColor: .secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Spacer(minLength: 40)
                        }
                        .padding(.horizontal, 12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        HStack(spacing: 8) {
                            FlooServiceAvatar(symbol: service.symbol, tint: service.tint, size: 32)
                            Text("正在写…").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                    }
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
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: FlooContactsRoute.profile(service.id)) {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task {
            guard fresh, !said else { return }
            try? await Task.sleep(for: .seconds(1.2))  // try?: cancelled, no matter
            withAnimation(.snappy) { said = true }
        }
    }

    private var name: String {
        guard let added, !added.nickname.isEmpty else { return service.name }
        return added.nickname
    }
}

#Preview {
    FlooContactsDestination()
}
