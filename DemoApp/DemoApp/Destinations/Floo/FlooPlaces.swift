//
//  FlooPlaces.swift
//  DemoApp
//
//  Starting a group and connecting services, on the floo server (FlooLive): a group with your
//  butler, people found by their email and services you have; a service connected by signing
//  in to it in the browser, or, one this Mac runs, by Floo Helper getting what it needs here.
//

import SwiftUI
import Wire
import TransportKit

/// A new group: its name, the people in it (each found by email) and your services in it.
struct FlooNewGroupView: View {
    let live: FlooLive
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var email = ""
    @State private var people: [PersonFound] = []
    @State private var services: [FlooLiveService] = []
    @State private var picked: Set<String> = []
    @State private var finding = false
    @State private var opening = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("群名称", text: $title)
                }
                Section {
                    ForEach(people, id: \.account) { person in
                        Label(person.name ?? "没有名字的成员", systemImage: "person.crop.circle")
                    }
                    .onDelete { people.remove(atOffsets: $0) }
                    HStack {
                        TextField("对方的邮箱", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(find)
                        if finding {
                            ProgressView()
                        } else {
                            Button("添加", action: find)
                                .disabled(!email.contains("@"))
                        }
                    }
                } header: {
                    Text("成员")
                } footer: {
                    Text("你的管家会在群里；每个成员也带着自己的管家。")
                }
                if !services.isEmpty {
                    Section("服务") {
                        ForEach(services) { service in
                            Toggle(service.name, isOn: Binding(
                                get: { picked.contains(service.id) },
                                set: { on in if on { picked.insert(service.id) } else { picked.remove(service.id) } }
                            ))
                        }
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("新建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if opening {
                        ProgressView()
                    } else {
                        Button("建群", action: open)
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .task { services = await live.connectedServices() }
    }

    private func find() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !finding else { return }
        finding = true
        failure = nil
        Task {
            defer { finding = false }
            do {
                guard let person = try await live.person(email: email) else {
                    failure = "没有用这个邮箱的账号。"
                    return
                }
                if !people.contains(where: { $0.account == person.account }) { people.append(person) }
                self.email = ""
            } catch ClientError.server(status: 429, _) {
                failure = "查得太频繁了，请稍后再试。"
            } catch {
                failure = "没查到：\(error)"
            }
        }
    }

    private func open() {
        opening = true
        failure = nil
        Task {
            defer { opening = false }
            do {
                try await live.openGroup(
                    title: title.trimmingCharacters(in: .whitespaces),
                    people: people.map(\.account),
                    services: Array(picked)
                )
                dismiss()
            } catch {
                failure = "群没建成：\(error)"
            }
        }
    }
}

/// The services you can connect, each connected by signing in to it in the browser.
struct FlooServicesView: View {
    let live: FlooLive
    @Environment(\.dismiss) private var dismiss

    @State private var services: [FlooLiveService] = []
    @State private var loaded = false
    @State private var connecting: String?
    @State private var failures: [String: String] = [:]
    @State private var failure: String?
    #if targetEnvironment(macCatalyst)
    /// Floo Helper, for this Mac's services; nil until looked at.
    @State private var helper: FlooHelper.State?
    @State private var password = ""
    @State private var signingIn = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loaded && services.allSatisfy(\.mac) {
                        Text("这台服务器没有可连接的服务。").foregroundStyle(.secondary)
                    }
                    ForEach(services.filter { !$0.mac }) { service in
                        row(service, note: connecting == service.id ? "在浏览器里登录，完成后回到这里" : nil) {
                            Button("连接") { connect(service) }
                        }
                    }
                }
                #if targetEnvironment(macCatalyst)
                if live.onlineAccount != nil {
                    Section("这台 Mac") { mac }
                }
                #endif
                if let failure {
                    Text(failure).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("连接服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    /// A service, with what it says under its name (`note`, else why it didn't connect, else
    /// what it is) and, when it isn't connected, `action`.
    private func row(_ service: FlooLiveService, note: String?, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: service.icon) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                Text(failures[service.id] ?? note ?? service.summary)
                    .font(.footnote)
                    .foregroundStyle(failures[service.id] == nil ? Color.secondary : Color.red)
            }
            Spacer()
            if service.connected && (service.reachable || !service.mac) {
                Label("已连接", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else if connecting == service.id {
                ProgressView()
            } else {
                action()
                    .buttonStyle(.bordered)
                    .disabled(connecting != nil)
            }
        }
        .padding(.vertical, 2)
    }

    #if targetEnvironment(macCatalyst)
    /// This Mac's services, once Floo Helper serves as you.
    @ViewBuilder private var mac: some View {
        switch helper {
        case nil:
            ProgressView()
        case .missing:
            Text("这个版本没有带 Floo Helper，用不了这台 Mac 上的服务。").foregroundStyle(.secondary)
        case .signedOut:
            VStack(alignment: .leading, spacing: 10) {
                Text("这台 Mac 上的服务由 Floo Helper 来用，它需要用你的账号登录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .onSubmit(signInHelper)
                    if signingIn {
                        ProgressView()
                    } else {
                        Button("登录", action: signInHelper)
                            .buttonStyle(.bordered)
                            .disabled(password.isEmpty)
                    }
                }
            }
            .padding(.vertical, 2)
        case .stopped(let reason):
            HStack {
                Text("Floo Helper 没有启动：\(reason)").font(.footnote).foregroundStyle(.red)
                Spacer()
                Button("重试") { Task { await lookAtHelper() } }.buttonStyle(.bordered)
            }
        case .ready:
            ForEach(services.filter(\.mac)) { service in
                row(service, note: connecting == service.id
                    ? "在弹出的窗口或系统设置里允许"
                    : service.connected ? "还没有在这台 Mac 上允许" : nil) {
                    Button(service.connected ? "允许" : "连接") { connectHere(service) }
                }
            }
        }
    }

    private func lookAtHelper() async {
        guard let account = live.onlineAccount else { return }
        helper = nil
        helper = await FlooHelper.state(for: account)
    }

    private func signInHelper() {
        guard !password.isEmpty, let email = UserDefaults.standard.string(forKey: FlooOnline.emailKey) else { return }
        let password = password
        signingIn = true
        failure = nil
        Task {
            defer { signingIn = false }
            do {
                try await FlooHelper.signIn(email: email, password: password)
                self.password = ""
                await lookAtHelper()
            } catch {
                failure = "Floo Helper 没登录上：\(error)"
            }
        }
    }

    /// Floo Helper asks for what it needs here (nothing, if it has it already); then it's
    /// connected, and the server knows from the Helper whether it can do its work.
    private func connectHere(_ service: FlooLiveService) {
        connecting = service.id
        failures[service.id] = nil
        Task {
            defer { connecting = nil }
            await FlooHelper.allow([service.id])
            do {
                if !service.connected { try await live.connectHere(service) }
                await load()
                // The Helper tells the server what it can do now a moment after.
                try await Task.sleep(for: .seconds(3))
                await load()
            } catch {
                failures[service.id] = "没连上：\(error)"
            }
        }
    }
    #endif

    private func load() async {
        do {
            services = try await live.services()
        } catch {
            failure = "没读到服务：\(error)"
        }
        loaded = true
        #if targetEnvironment(macCatalyst)
        if helper == nil { await lookAtHelper() }
        #endif
    }

    private func connect(_ service: FlooLiveService) {
        connecting = service.id
        failures[service.id] = nil
        Task {
            defer { connecting = nil }
            do {
                try await live.connect(service)
                await load()
            } catch {
                failures[service.id] = "没连上：\(error)"
            }
        }
    }
}
