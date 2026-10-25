//
//  FlooThreads.swift
//  DemoApp
//
//  Threads, topics and a group's members, on the floo server (FlooLive; floo messaging.md
//  §3.13): "N 条回复" under a thread's first message, the thread open over the conversation
//  (what's said there replies to its newest), made a topic from there; a group's people and
//  agents, its host, and bringing people and your services in.
//

import SwiftUI
import Wire
import TransportKit

/// "N 条回复" under a thread's first message, with who replied: opens the thread.
struct FlooRepliesLink: View {
    let thread: FlooThreadLine
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                HStack(spacing: -6) {
                    ForEach(Array(thread.faces.prefix(3).enumerated()), id: \.offset) { _, face in
                        Text(face.initial)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(face.tint, in: Circle())
                            .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
                    }
                }
                Text("\(thread.count) 条回复")
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.footnote.weight(.medium))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
    }
}

/// A thread over the conversation, which shows blurred behind it (floo messaging.md
/// §3.13.4): its messages, oldest first; what you say replies to its newest; made a topic
/// from its bar.
struct FlooThreadView: View {
    let thread: FlooThreadShown
    let demo: FlooDemo
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var naming = false
    @State private var title = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if thread.loading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(thread.lines) { line in
                        row(line)
                    }
                }
                .padding()
            }
            // The newest at the bottom, as the conversation's; kept there as replies come.
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("\(max(thread.lines.count - 1, 0)) 条回复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("转为话题…", systemImage: "bubble.left.and.text.bubble.right") { naming = true }
                }
            }
            .alert("转为话题", isPresented: $naming) {
                TextField("话题名", text: $title)
                Button("转") {
                    let name = title.trimmingCharacters(in: .whitespaces)
                    demo.makeTopic(of: thread, title: name.isEmpty ? "话题" : name)
                    title = ""
                }
                Button("取消", role: .cancel) { title = "" }
            } message: {
                Text("这一串会转成一个话题，进对话列表；之后回复这一串的话都进那里。")
            }
        }
        .presentationBackground(.ultraThinMaterial)
    }

    private func row(_ line: FlooThreadShown.Line) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if !line.mine { face(line.face) }
            VStack(alignment: line.mine ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(line.who).font(.caption.weight(.semibold))
                    Text(line.time).font(.caption2).foregroundStyle(.secondary)
                }
                Text(Self.words(line.text))
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        line.mine ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.background.secondary),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .frame(maxWidth: .infinity, alignment: line.mine ? .trailing : .leading)
            if line.mine { face(line.face) }
        }
    }

    private func face(_ face: FlooThreadLine.Face) -> some View {
        Text(face.initial)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(face.tint, in: Circle())
    }

    /// Its words as markdown, its fences left out: the conversation shows those.
    private static func words(_ text: String) -> AttributedString {
        var kept: [Substring] = []
        var fenced = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if !fenced { kept.append(line) }
        }
        let words = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: words, options: options)) ?? AttributedString(words)  // try?: plain when it isn't markdown
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("回复这一串", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background, in: Capsule())
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        demo.sayInThread(draft)
        draft = ""
    }
}

/// A topic's or group's members (floo messaging.md §3.13.7): people and agents, its host
/// marked; you bring people in by their email and your services in, and, in your group,
/// make an agent in it its host.
struct FlooMembersView: View {
    let live: FlooLive
    @Environment(\.dismiss) private var dismiss

    @State private var members: [FlooMember] = []
    @State private var yours = false
    @State private var email = ""
    @State private var services: [FlooLiveService] = []
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(members) { member in
                        HStack {
                            Label(member.name, systemImage: member.agent ? "sparkles" : "person.crop.circle")
                            Spacer()
                            if member.host {
                                Text("主持").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            } else if member.agent, yours {
                                Button("设为主持") { change { try await live.setHost(member.participant) } }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("成员")
                } footer: {
                    Text("没 @ 谁、也看不出是给谁的话，由主持来接。\(yours ? "" : "只有建群的人能换主持。")")
                }
                Section("加人") {
                    HStack {
                        TextField("对方的邮箱", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addPerson)
                        Button("添加", action: addPerson).disabled(!email.contains("@") || busy)
                    }
                }
                let absent = services.filter { service in
                    !members.contains { $0.agent && $0.participant.actor.agent == service.serviceID.map(AgentID.service) }
                }
                if !absent.isEmpty {
                    Section("加服务") {
                        ForEach(absent) { service in
                            Button(service.name) { change { try await live.add(people: [], services: [service.id]) } }
                                .disabled(busy)
                        }
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("完成") { dismiss() } }
                }
            }
        }
        .task {
            await reload()
            services = await live.connectedServices()
        }
    }

    private func reload() async {
        (members, yours) = await live.members()
    }

    /// A change, then the members as they are after it.
    private func change(_ act: @escaping () async throws -> Void) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                try await act()
                // The conversation's copy has it once the server's change comes round.
                try? await Task.sleep(for: .milliseconds(600))  // try?: cancelled, read now
                await reload()
            } catch {
                failure = "没改成：\(error)"
            }
        }
    }

    private func addPerson() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !busy else { return }
        change {
            guard let person = try await live.person(email: email) else {
                throw FlooMembersError.noOne
            }
            try await live.add(people: [person.account], services: [])
            self.email = ""
        }
    }
}

private enum FlooMembersError: LocalizedError {
    case noOne

    var errorDescription: String? { "没有用这个邮箱的账号。" }
}

private extension FlooLiveService {
    /// Its id as the server's.
    var serviceID: ServiceID? { try? ServiceID(id) }  // try?: from the catalog, a name
}
