//
//  FlooContactPage.swift
//  DemoApp
//
//  A followed service as a close contact (floo docs/app.md 3.2): its page looks like a
//  contact's in Messages (a poster, a few actions, what you share), and what it has pushed
//  you is browsed like someone's Moments in WeChat: an album by day, each post opening on
//  its own. Every part reads records floo keeps: the Feed for this service, the cards it
//  drew in your conversation, its commitments and watches, its providers on your devices.
//

import AppleDeviceImages
import PhotosUI
import SwiftUI
import CardModel
import CardUI
import Wire

// MARK: - Its colour

extension FlooService {
    /// The backdrop's colour: the definition's, else the icon's most common vivid colour.
    @MainActor func backdrop() async -> Color {
        if let hex = presentation.color, let color = Color(hex: hex) { return color }
        if let url = icon, let tint = await FlooIconLoader.shared.icon(at: url)?.tint { return Color(uiColor: tint) }
        return Color(white: 0.45)
    }
}

/// Its colour washing down from the top of a page, as a contact's poster does.
struct FlooBackdrop: View {
    let tint: Color
    var height: CGFloat = 440

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: tint.opacity(0.55), location: 0),
                .init(color: tint.opacity(0.18), location: 0.6),
                .init(color: tint.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

// MARK: - The contact

struct FlooContactPage: View {
    let demo: FlooContactsDemo
    let service: FlooService
    @State private var tint = Color(white: 0.45)
    @State private var showsAbout = false
    @State private var confirmsUnfollow = false
    @State private var renames = false
    @State private var newName = ""
    @State private var picked: PhotosPickerItem?

    private var following: FlooFollowing { demo.following[service.id] ?? FlooFollowing() }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                poster
                actions
                if !following.pushes.isEmpty { momentsRow }
                devicesRow
                permissionsRow
                if !following.doing.isEmpty { doing }
                if !following.shared.isEmpty { shared }
                closing
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background { FlooBackdrop(tint: tint) }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .task { tint = await service.backdrop() }
        // All it says of itself, read once and kept.
        .task { if demo.live != nil { await demo.look(service) } }
        .task { await demo.readApprovals() }
        .sheet(isPresented: $showsAbout) { FlooAboutSheet(service: service) }
        .alert("重命名", isPresented: $renames) {
            TextField(service.catalogName, text: $newName)
            Button("好") { Task { await demo.rename(service, to: newName) } }
            if FlooAgentLooks.shared.name(of: service.id) != nil {
                Button("恢复为“\(service.catalogName)”") { Task { await demo.rename(service, to: "") } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("它会以新名字称呼自己，之前的对话保留原来的名字。")
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                // try?: unreadable, the picture stays as it was
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                await demo.setPicture(image, of: service)
                tint = await service.backdrop()
            }
        }
        .confirmationDialog("不再关注 \(service.name)？", isPresented: $confirmsUnfollow, titleVisibility: .visible) {
            Button("不再关注", role: .destructive) {
                if demo.live != nil {
                    Task { await demo.disconnect(service) }
                } else {
                    demo.following[service.id] = nil
                }
                demo.path.removeAll()
            }
        } message: {
            Text("进行中的任务将停止，服务将断开连接。对话记录和动态将保留。")
        }
    }

    // MARK: Poster and actions

    // Its name and picture are the person's to change; its id stays (floo docs/context-format.md §3.5).
    private var poster: some View {
        VStack(spacing: 8) {
            Menu {
                PhotosPicker("换头像", selection: $picked, matching: .images)
                if FlooAgentLooks.shared.picture(of: service.id) != nil {
                    Button("恢复默认头像", role: .destructive) {
                        Task { await demo.setPicture(nil, of: service) }
                    }
                }
            } label: {
                FlooServiceIcon(url: service.icon, name: service.name, tint: tint, size: 104)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            }
            Button {
                newName = service.name
                renames = true
            } label: {
                Text(service.name).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.primary)
            }
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            FlooActionButton(symbol: "message.fill", title: "消息", tint: tint) {
                demo.openChat(service)
            }
            FlooActionButton(
                symbol: following.quiet ? "bell.slash.fill" : "bell.fill",
                title: following.quiet ? "静音已开启" : "静音", tint: tint, on: following.quiet
            ) {
                if demo.live != nil {
                    Task { await demo.change(service, quiet: !following.quiet) }
                } else {
                    demo.following[service.id]?.quiet.toggle()
                }
            }
            FlooActionButton(
                symbol: following.pinned ? "pin.fill" : "pin", title: following.pinned ? "已置顶" : "置顶",
                tint: tint, on: following.pinned
            ) {
                if demo.live != nil {
                    Task { await demo.change(service, pinned: !following.pinned) }
                } else {
                    demo.following[service.id]?.pinned.toggle()
                }
            }
        }
    }

    /// From the providers' reports: computed, never stored (services.md §10.1).
    private var status: (text: String, color: Color) {
        if following.expired { return ("需要重新登录", .orange) }
        let set = following.devices.compactMap(demo.device)
        let online = set.filter(\.online).map { $0.name.replacingOccurrences(of: "这台 ", with: "") }
        if following.account != nil { return ("已连接", .green) }
        if !online.isEmpty { return ("已在 \(online.joined(separator: "、")) 上启用", .green) }
        if !set.isEmpty { return ("所有设备均不在线", .gray) }
        if !following.asked.isEmpty { return ("等待在其他设备上完成设置", .orange) }
        return ("未连接", .orange)
    }

    // MARK: Moments

    /// WeChat's 朋友圈 row on a contact: the latest few, small.
    private var momentsRow: some View {
        Button { demo.path.append(.moments(service.id)) } label: {
            HStack(spacing: 12) {
                Text("动态").font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ForEach(Array(following.pushes.prefix(4).enumerated()), id: \.offset) { _, push in
                        FlooPushThumbnail(demo: demo, push: push, tint: tint, side: 56)
                    }
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Devices

    private enum Bubble: Identifiable {
        case account(String, String)
        case device(FlooDevice)

        var id: String {
            switch self {
            case .account(let provider, _): "account:\(provider)"
            case .device(let device): device.id
            }
        }
    }

    /// The account it is signed in with, then the person's devices that matter to it: those
    /// providing it, and those online now.
    private var bubbles: [Bubble] {
        var result: [Bubble] = []
        if let provider = demo.sources(service).account, let account = following.account {
            result.append(.account(provider, account))
        }
        guard !demo.sources(service).devices.isEmpty else { return result }
        for device in demo.devices
        where following.devices.contains(device.id) || following.asked.contains(device.id) || device.online {
            result.append(.device(device))
        }
        return result
    }

    /// Like AirDrop's row of nearby devices: each with how it stands with this service.
    private var devicesRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(demo.sources(service).devices.isEmpty ? "连接" : "设备").font(.body.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(bubbles) { bubble in bubbleView(bubble) }
                    if demo.sources(service).account != nil && following.account == nil {
                        bubbleButton(symbol: "person.crop.circle.badge.plus", name: "\(demo.sources(service).account!) 账号",
                                     state: ("去登录", Color.accentColor), dimmed: false) {
                            demo.follow(service)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            if !demo.sources(service).devices.isEmpty {
                Text(
                    FlooSettingsFormat.all[service.id] == nil
                        ? "轻点在线设备以在该设备上设置“\(service.name)”。"
                        : "轻点已启用的设备查看设置，或轻点其他在线设备进行设置。"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func bubbleView(_ bubble: Bubble) -> some View {
        switch bubble {
        case .account(let provider, let account):
            bubbleButton(
                symbol: "person.crop.circle.fill", name: account,
                state: following.expired ? ("重新登录", .orange) : ("\(provider) · 已连接", .green), dimmed: false
            ) {
                guard following.expired else { return }
                if demo.live != nil {
                    Task { await demo.signIn(service) }
                    return
                }
                demo.following[service.id]?.expired = false
                demo.show("已重新登录 \(provider)")
            }
        case .device(let device):
            let provides = following.devices.contains(device.id)
            let asked = following.asked.contains(device.id)
            let can = demo.sources(service).provides(on: device)
            let state: (String, Color) =
                asked ? ("待设置", .orange)
                : provides ? (device.online ? (service.id == "github" ? "gh 已登录" : "已启用") : "\(device.lastSeen ?? "")在线", device.online ? .green : .gray)
                : can ? ("设置", Color.accentColor) : ("不支持", .gray)
            bubbleButton(symbol: device.symbol, product: device.product, name: device.name, state: state, dimmed: !can && !provides) {
                if provides, FlooSettingsFormat.all[service.id] != nil {
                    demo.path.append(.settings(service.id, device.id))
                    return
                }
                guard can, !provides, !asked, device.online else { return }
                if demo.live == nil && device.id == demo.thisDevice {
                    demo.following[service.id]?.devices.insert(device.id)
                } else {
                    demo.setUp(service, on: device)
                }
            }
            // Connected there: it can be let go of there alone, the others it's on going on.
            .contextMenu {
                if provides, demo.live != nil {
                    Button("在\(device.name)上断开", role: .destructive) {
                        Task { await demo.disconnect(service, on: device) }
                    }
                }
            }
        }
    }

    /// A source on the page: an account, or a device by its picture (as Settings shows your
    /// devices) where it says what it is, its symbol until then; how it stands in its dot.
    private func bubbleButton(
        symbol: String, product: AppleDevice? = nil, name: String, state: (String, Color), dimmed: Bool,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let product {
                        AppleDeviceImage(product, size: .small) { image in
                            image.resizable().scaledToFit().saturation(dimmed ? 0 : 1)
                        } placeholder: {
                            symbolBadge(symbol, dimmed: dimmed)
                        }
                    } else {
                        symbolBadge(symbol, dimmed: dimmed)
                    }
                }
                .frame(width: 58, height: 58)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(state.1).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2.5))
                }
                Text(name).font(.caption).foregroundStyle(.primary).lineLimit(1)
                Text(state.0).font(.caption2).foregroundStyle(state.1 == .gray ? .secondary : state.1).lineLimit(1)
            }
            .frame(width: 80)
            .opacity(dimmed ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }

    private func symbolBadge(_ symbol: String, dimmed: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 24))
            .foregroundStyle(dimmed ? Color.secondary : tint)
            .frame(width: 58, height: 58)
            .background(tint.opacity(dimmed ? 0.05 : 0.14), in: Circle())
    }

    // MARK: Permissions

    /// How what it does is let through: as the account's mode, or its own.
    private var permissionsRow: some View {
        Button { demo.path.append(.permissions(service.id)) } label: {
            HStack(spacing: 12) {
                Text("权限").font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(FlooApprovalWords.summary(demo.approvals[service.id], account: demo.approvalMode))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Doing, shared, closing

    private var doing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("进行中的任务").font(.body.weight(.semibold))
            ForEach(following.doing, id: \.self) { item in
                Button { demo.openChat(service) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checklist").font(.title3).foregroundStyle(tint)
                            .frame(width: 40, height: 40)
                            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).foregroundStyle(.primary)
                            Text(item.asked).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Like Messages' shared photos: the cards it drew in your conversation.
    private var shared: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("对话中的卡片").font(.body.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(following.shared, id: \.self) { name in
                    if let session = demo.card(name) {
                        FlooCardThumbnail(session: session, side: 104)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var closing: some View {
        VStack(spacing: 0) {
            Button { showsAbout = true } label: {
                HStack {
                    Text("关于 \(service.name)").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(14)
            }
            Divider().padding(.leading, 14)
            Button(role: .destructive) { confirmsUnfollow = true } label: {
                Text("不再关注").frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// One service's permissions (floo agent-kernel.md §7.3): its own approval mode over the
/// account's, and whether what it reads is asked first too — what it lets agents read of you
/// (your mail, what you do in Claude Code) can be yours to give each time.
struct FlooPermissionsPage: View {
    let demo: FlooContactsDemo
    let service: FlooService

    private var approval: ServiceApproval? { demo.approvals[service.id] }

    var body: some View {
        List {
            Section {
                Picker("批准方式", selection: mode) {
                    choice("跟随账户", "现在是「\(FlooApprovalWords.name(demo.approvalMode))」").tag(ApprovalMode?.none)
                    ForEach(ApprovalMode.allCases, id: \.self) { mode in
                        choice(FlooApprovalWords.name(mode), FlooApprovalWords.detail(mode)).tag(Optional(mode))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("修改之前")
            } footer: {
                Text("只管\(service.name)，盖过账户的批准方式。以前选过「以后都允许」的照旧直接执行，删除这类撤不回的除外。")
            }

            if !service.reads.isEmpty {
                Section {
                    Toggle("读取也按上面的方式", isOn: reads)
                        .disabled(approval == nil)
                } footer: {
                    Text(
                        approval == nil
                            ? "先给\(service.name)选一种批准方式，才能单独管它的读取。"
                            : "它的 \(service.reads.count) 项读取（\(service.reads.prefix(3).map(\.title).joined(separator: "、"))\(service.reads.count > 3 ? "等" : "")）平时直接执行；打开后和修改一样，按上面的方式问你。"
                    )
                }
            }
        }
        .navigationTitle("权限")
        .navigationBarTitleDisplayMode(.inline)
        .task { await demo.readApprovals() }
    }

    private func choice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Its own mode; nil follows the account's (and drops what it set of its reads).
    private var mode: Binding<ApprovalMode?> {
        Binding(get: { approval?.mode }) { mode in
            set(mode.flatMap { mode in
                (try? ServiceID(service.id)).map { ServiceApproval(service: $0, mode: mode, reads: approval?.reads ?? false) }  // try?: not a name
            })
        }
    }

    private var reads: Binding<Bool> {
        Binding(get: { approval?.reads ?? false }) { reads in
            guard var approval else { return }
            approval.reads = reads
            set(approval)
        }
    }

    private func set(_ approval: ServiceApproval?) {
        Task { await demo.setApproval(service, approval) }
    }
}

/// The approval modes as the App says them (floo agent-kernel.md §7.3).
enum FlooApprovalWords {
    static func name(_ mode: ApprovalMode) -> String {
        switch mode {
        case .open: "全部放开"
        case .review: "自动审核"
        case .ask: "每次都问"
        }
    }

    static func detail(_ mode: ApprovalMode) -> String {
        switch mode {
        case .open: "直接执行；不是你发起的运行里，先由判断模型看一眼。"
        case .review: "先由判断模型看，是你要的就执行，拿不准再问你。"
        case .ask: "每次都等你批准。"
        }
    }

    /// A service's row: its own mode, and its reads when they're asked too; else the account's.
    static func summary(_ approval: ServiceApproval?, account: ApprovalMode) -> String {
        guard let approval else { return "跟随账户 · \(name(account))" }
        return name(approval.mode) + (approval.reads ? " · 含读取" : "")
    }
}

/// Messages' contact actions: a symbol over a word, on a soft tile.
private struct FlooActionButton: View {
    let symbol: String
    let title: String
    let tint: Color
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(on ? Color.white : tint)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                on ? AnyShapeStyle(tint) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FlooAboutSheet: View {
    let service: FlooService

    var body: some View {
        NavigationStack {
            List {
                if let description = service.description { Section { Text(description) } }
                Section {
                    if let developer = service.presentation.developer { LabeledContent("提供方", value: developer) }
                    if let category = service.category { LabeledContent("分类", value: category) }
                    ForEach(
                        [("网站", service.presentation.website), ("隐私政策", service.presentation.privacyPolicy),
                         ("服务条款", service.presentation.termsOfService)],
                        id: \.0
                    ) { title, address in
                        if let address, let url = URL(string: address) { Link(title, destination: url) }
                    }
                }
            }
            .navigationTitle("关于 \(service.name)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Thumbnails

/// A drawn card, shrunk into a square from its top left, as an album shows a photo.
struct FlooCardThumbnail: View {
    let session: CardSession
    let side: CGFloat
    private let width: CGFloat = 232

    var body: some View {
        CardView(tree: session.tree)
            .frame(width: width, alignment: .topLeading)
            .padding(12)
            .background(Color(uiColor: .systemBackground))
            .scaleEffect(side / (width + 24), anchor: .topLeading)
            .frame(width: side, height: side, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// A push, small: its card, else what it points at, else its first words.
struct FlooPushThumbnail: View {
    let demo: FlooContactsDemo
    let push: FlooPush
    let tint: Color
    let side: CGFloat

    var body: some View {
        if let name = push.card, let session = demo.card(name) {
            FlooCardThumbnail(session: session, side: side)
        } else if let mention = push.mention {
            Image(systemName: mention.symbol)
                .font(.system(size: side * 0.36))
                .foregroundStyle(tint)
                .frame(width: side, height: side)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Text(push.text)
                .font(.system(size: side * 0.15))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(5)
                .frame(width: side, height: side, alignment: .topLeading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// What a `floo.mention` points at, as Moments shows a shared link.
struct FlooMentionBox: View {
    let mention: FlooMention
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mention.symbol)
                .font(.title3).foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14))
            VStack(alignment: .leading, spacing: 2) {
                Text(mention.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Text(mention.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(Color.primary.opacity(0.05))
    }
}

// MARK: - Its moments

/// WeChat's album of one person's Moments: a cover, then its posts by day.
struct FlooMomentsPage: View {
    let demo: FlooContactsDemo
    let service: FlooService
    @State private var tint = Color(white: 0.45)

    private var pushes: [FlooPush] { demo.following[service.id]?.pushes ?? [] }

    /// Days in order, each with its posts and their places in the feed: a day of this
    /// device's calendar, said as it is now.
    private var days: [(day: Date, posts: [(index: Int, push: FlooPush)])] {
        var result: [(day: Date, posts: [(index: Int, push: FlooPush)])] = []
        for (index, push) in pushes.enumerated() {
            let day = Calendar.current.startOfDay(for: push.at)  // time: shown on this device, by its calendar
            if result.last?.day == day {
                result[result.count - 1].posts.append((index, push))
            } else {
                result.append((day, [(index, push)]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cover
                if let short = service.shortDescription {
                    Text(short).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 36).padding(.horizontal, 16)
                }
                ForEach(days, id: \.day) { day in
                    HStack(alignment: .top, spacing: 8) {
                        dayLabel(FlooDay.label(day.day)).frame(width: 76, alignment: .leading)
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(day.posts, id: \.index) { post in
                                Button { demo.path.append(.post(service.id, post.index)) } label: {
                                    entry(post.push)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 30)
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .task { tint = await service.backdrop() }
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .topLeading) {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: tint, size: 260)
                        .opacity(0.16)
                        .rotationEffect(.degrees(-12))
                        .offset(x: -40, y: 40)
                }
                .clipped()
                .frame(height: 320)
            HStack(alignment: .bottom, spacing: 14) {
                Text(service.name)
                    .font(.title3.weight(.bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .padding(.bottom, 30)
                FlooServiceIcon(url: service.icon, name: service.name, tint: tint, size: 72)
                    .overlay(FlooIconShape().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
            }
            .padding(.trailing, 16)
            .offset(y: 24)
        }
    }

    @ViewBuilder private func dayLabel(_ day: String) -> some View {
        if let month = day.firstIndex(of: "月") {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(day[day.index(after: month)...].replacingOccurrences(of: "日", with: ""))
                    .font(.system(size: 28, weight: .bold))
                Text(day[...month]).font(.caption.weight(.semibold))
            }
        } else {
            Text(day).font(.system(size: 24, weight: .bold))
        }
    }

    @ViewBuilder private func entry(_ push: FlooPush) -> some View {
        if push.card != nil || push.mention != nil {
            HStack(alignment: .top, spacing: 8) {
                FlooPushThumbnail(demo: demo, push: push, tint: tint, side: 78)
                VStack(alignment: .leading, spacing: 4) {
                    Text(push.text).font(.subheadline).lineLimit(3)
                    if let mention = push.mention, !mention.title.isEmpty {
                        Text(mention.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            Text(push.text)
                .font(.subheadline)
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
        }
    }
}

/// One post, as Moments opens it: who, what, the card or link, when; and a way back into
/// the conversation about it.
struct FlooPostPage: View {
    let demo: FlooContactsDemo
    let service: FlooService
    let index: Int
    @State private var tint = Color(white: 0.45)

    var body: some View {
        ScrollView {
            if let pushes = demo.following[service.id]?.pushes, pushes.indices.contains(index) {
                let push = pushes[index]
                HStack(alignment: .top, spacing: 10) {
                    FlooServiceIcon(url: service.icon, name: service.name, tint: tint, size: 44)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(service.name).font(.body.weight(.semibold))
                            .foregroundStyle(Color(red: 0.34, green: 0.42, blue: 0.58))
                        Text(push.text)
                        if let name = push.card, let session = demo.card(name) {
                            CardView(tree: session.tree)
                                .frame(width: 232, alignment: .topLeading)
                                .padding(12)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        if let shown = push.mention?.shown {
                            MentionList([shown], now: FlooClock.now).frame(width: 256, alignment: .topLeading)
                        } else if let mention = push.mention {
                            FlooMentionBox(mention: mention, tint: tint)
                        }
                        HStack {
                            Text("\(FlooDay.label(push.at)) \(push.at.formatted(.dateTime.hour().minute()))")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                demo.drafts[service.id] = nil
                                demo.openChat(service)
                            } label: {
                                Label("在对话中回复", systemImage: "bubble.left")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { tint = await service.backdrop() }
    }
}
