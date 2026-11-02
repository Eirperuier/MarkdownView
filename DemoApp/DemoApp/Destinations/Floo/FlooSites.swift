//
//  FlooSites.swift
//  DemoApp
//
//  The sites you're signed in to, as floo docs/browser.md §6 (统一登录态) has them: a site
//  signed in to in one device's floo browser is kept signed in on all your devices that have
//  one, if you chose that. One row per site group and account container (`GET /v1/sessions`):
//  which devices hold it, when it last changed, a switch for keeping it signed in everywhere
//  (§6.5, `PUT …/sync`) and 在所有设备上退出 (`POST …/sign-out`); a revoked device that once
//  got it is named, to sign out on the site itself. Opened from the chat's account menu, beside
//  设备; `-flooSites YES` opens it once signed in. Only site names: no cookie is ever here.
//

import SwiftUI
import TransportKit
import Wire

/// The page's state, as the floo server has it: the sites, and the devices' names to say
/// who holds each.
@MainActor @Observable
final class FlooSitesDemo {
    @ObservationIgnored let live: FlooLive
    var sites: [SessionSite] = []
    /// The account's devices by id, revoked ones too: their names.
    var devices: [DeviceID: DeviceInfo] = [:]
    var loaded = false
    /// A site being changed, by its row's id: its switch and button wait.
    var changing: Set<String> = []
    var toast: String?

    init(live: FlooLive) {
        self.live = live
    }

    /// The rows shown: a site with something kept, or one you keep in sync; one signed out
    /// everywhere or never uploaded shows only while its switch is on.
    var shown: [SessionSite] {
        sites
            .filter { $0.head.sync || (!$0.head.tombstone && $0.head.rev > 0) }
            .sorted { ($0.head.group, $0.head.container) < ($1.head.group, $1.head.container) }
    }

    func load() async {
        // Opened as the app starts (-flooSites), the page can come before the sign-in to the
        // server; it waits for it rather than staying empty.
        var server = live.server
        for _ in 0..<100 where server == nil {
            try? await Task.sleep(for: .milliseconds(200))  // try?: cancelled with the page, nothing to load
            server = live.server
        }
        guard let client = server else { return }
        do {
            sites = try await client.sessionSites()
            loaded = true
        } catch {
            show("没读到网站登录：\(error)")
        }
        // try?: unnamed devices show as 一台设备 until read again
        if let list = try? await client.devices() {
            devices = Dictionary(list.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func name(_ device: DeviceID) -> String { devices[device]?.name ?? "一台设备" }

    /// Keeps the site signed in on all your devices, or stops: stopping deletes the server's
    /// copies, and each device keeps what it has.
    func setSync(_ site: SessionSite, _ on: Bool) {
        change(site) { client in
            try await client.setSessionSync(on, group: site.head.group, container: site.head.container)
        }
    }

    /// Signs you out of the site on every device: the copies go, and each device clears it.
    func signOutEverywhere(_ site: SessionSite) {
        change(site, done: "已在所有设备上退出 \(site.head.group)") { client in
            try await client.signOutEverywhere(group: site.head.group, container: site.head.container)
        }
    }

    private func change(_ site: SessionSite, done: String? = nil, _ perform: @escaping (FlooClient) async throws -> SessionHead) {
        guard let client = live.server else { return }
        let id = site.rowID
        changing.insert(id)
        Task {
            defer { changing.remove(id) }
            do {
                let head = try await perform(client)
                if let index = sites.firstIndex(where: { $0.rowID == id }) { sites[index].head = head }
                if let done { show(done) }
                // The holders change with it: read again.
                if let fresh = try? await client.sessionSites() { sites = fresh }  // try?: what's shown stands
            } catch {
                show("没改成：\(error)")
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
}

struct FlooSitesDestination: View {
    @State private var demo: FlooSitesDemo

    /// `-flooSites YES`: opened over the chat once it's signed in.
    static var launches: Bool { UserDefaults.standard.bool(forKey: "flooSites") }

    init(live: FlooLive) {
        _demo = State(initialValue: FlooSitesDemo(live: live))
    }

    var body: some View {
        NavigationStack {
            FlooSiteList(demo: demo)
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
        .task { await demo.load() }
    }
}

private struct FlooSiteList: View {
    let demo: FlooSitesDemo
    /// The site 在所有设备上退出 asks about first.
    @State private var signingOut: SessionSite?

    var body: some View {
        List {
            if demo.loaded, demo.shown.isEmpty {
                ContentUnavailableView(
                    "还没有在所有设备上保持登录的网站",
                    systemImage: "globe",
                    description: Text("在 floo 的浏览器里登录网站时，勾上「在我的所有设备上保持登录」，它就在这里。")
                )
            } else {
                Section {
                    ForEach(demo.shown, id: \.rowID) { site in
                        FlooSiteRow(demo: demo, site: site) { signingOut = site }
                    }
                } footer: {
                    Text("开着的网站，在一台设备的 floo 浏览器里登录，你所有设备上的浏览器都登录着；服务端只存它拆不开的密文。agent 只看到网站名。银行、支付默认不开。")
                }
            }
        }
        .navigationTitle("网站登录")
        .refreshable { await demo.load() }
        .confirmationDialog(
            "在所有设备上退出 \(signingOut?.head.group ?? "")？",
            isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }),
            titleVisibility: .visible
        ) {
            Button("在所有设备上退出", role: .destructive) {
                if let site = signingOut { demo.signOutEverywhere(site) }
                signingOut = nil
            }
        } message: {
            Text("每台设备上的浏览器都会清掉这个网站的登录，之后要重新登录。")
        }
    }
}

private struct FlooSiteRow: View {
    let demo: FlooSitesDemo
    let site: SessionSite
    let signOut: () -> Void

    var body: some View {
        let head = site.head
        let busy = demo.changing.contains(site.rowID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                FlooCallIconView(icon: .site(head.group), fallback: .symbol("globe"), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(head.group).font(.body.weight(.medium))
                        if head.container != SessionContainer.default {
                            Text(head.container)
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Toggle(
                    "在所有设备上保持登录",
                    isOn: Binding(get: { head.sync }, set: { demo.setSync(site, $0) })
                )
                .labelsHidden()
                .disabled(busy)
            }
            ForEach(revoked, id: \.device) { receipt in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("已撤销的 \(demo.name(receipt.device)) 拿到过")
                        Text("去 \(head.group) 上改密码，或退出别的设备上的登录").foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
            if !head.tombstone, head.rev > 0 {
                Button("在所有设备上退出", role: .destructive, action: signOut)
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 4)
    }

    /// Who holds it and when it last changed; signed out everywhere, or not kept yet, says so.
    private var line: String {
        let head = site.head
        var parts: [String] = []
        if head.tombstone {
            parts.append("已在所有设备上退出")
        } else if head.rev == 0 {
            parts.append("还没有登录过")
        } else {
            let holders = site.holders.map(demo.name)
            parts.append(holders.isEmpty ? "没有设备持有" : "在 \(holders.joined(separator: "、")) 上登录着")
        }
        if let at = head.at {
            // time: shown on this device, by its calendar
            let date = Date(timeIntervalSince1970: Double(at.millisecondsSince1970) / 1000)
            parts.append("更新于 \(date.formatted(.relative(presentation: .named)))")
        }
        if !head.sync { parts.append("只在登录的那台") }
        return parts.joined(separator: " · ")
    }

    /// Revoked devices that were sealed a revision of it: the site may still know them.
    private var revoked: [SessionReceipt] { site.received.filter(\.revoked) }
}

private extension SessionSite {
    /// A row's id: its site group in its container, the same as it changes.
    var rowID: String { "\(head.group)|\(head.container)" }
}
