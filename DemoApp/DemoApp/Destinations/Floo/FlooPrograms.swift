//
//  FlooPrograms.swift
//  DemoApp
//
//  The person's mini programs (floo docs/pages.md): listed from the server, each opened as its
//  published version, compiled here with the programs it reads, its data kept in step with
//  the server's. Intents that only change data run here; those that call tools or a model
//  run on the server. Photos come through the server's short links.
//

import SwiftUI
import CardModel
import CardRuntime
import CardSyntax
import CardUI
import TransportKit
import Wire

/// The list of the person's mini programs.
@MainActor @Observable
final class FlooPrograms {
    let server: FlooClient
    private(set) var programs: [ProgramSummary] = []
    private(set) var problem: String?
    private(set) var loaded = false

    init(server: FlooClient) {
        self.server = server
    }

    func load() async {
        do {
            programs = try await server.programs().programs.filter { $0.version > 0 }
            problem = nil
        } catch {
            problem = "没能读取小程序：\(error)"
        }
        loaded = true
    }
}

/// One mini program, open: its compiled source and its data as this device has it.
@MainActor @Observable
final class FlooOpenProgram: Identifiable {
    let summary: ProgramSummary
    let server: FlooClient
    let session = CardSession(runtime: FlooOpenProgram.runtime)
    @ObservationIgnored private(set) var store: CloudStore!
    private(set) var mini: MiniProgram?
    private(set) var problem: String?
    let host: FlooProgramHost
    @ObservationIgnored private var version: Int64 = 0
    @ObservationIgnored private var following: [Task<Void, Never>] = []

    nonisolated var id: ProgramID { summary.id }

    /// A page's runtime: its lists make each row as it's drawn, and screens, sheets and tabs what they show when shown.
    static let runtime = CardRuntime(formatting: .foundation, lazy: true)

    init(summary: ProgramSummary, server: FlooClient) {
        self.summary = summary
        self.server = server
        self.host = FlooProgramHost(server: server)
        store = CloudStore { [weak self] batch in self?.send(batch) }
    }

    /// Its source, its data and the data of the programs it reads, then follows all of them.
    func open(among all: [ProgramSummary]) async {
        guard await compile(among: all) else { return }
        await load(summary, from: nil)
        follow(summary, from: nil, among: all)
        for name in mini?.program.readsFrom ?? [] {
            guard let other = all.first(where: { $0.name == name }) else { continue }
            await load(other, from: name)
            follow(other, from: name, among: all)
        }
    }

    func close() {
        for task in following { task.cancel() }
        following = []
    }

    /// The published version, with the public types of the programs it reads.
    private func compile(among all: [ProgramSummary]) async -> Bool {
        do {
            let files = try await server.source(of: summary.id)
            let module = Self.module(files)
            // What it reads is known once compiled; then again with their types.
            var compiled = CardCompiler.compile(module)
            var imports: [String: ModuleSource] = [:]
            for name in compiled.program.readsFrom {
                guard let other = all.first(where: { $0.name == name }) else { continue }
                imports[name] = Self.module(try await server.source(of: other.id))
            }
            if !imports.isEmpty { compiled = CardCompiler.compile(module, importing: imports) }
            version = files.version
            if compiled.hasErrors {
                problem = module.describe(compiled.diagnostics.filter { $0.severity == .error })
                return false
            }
            session.show(compiled)
            mini = MiniProgram(program: compiled.program, store: store) { [weak self] intent, arguments in
                await self?.runRemotely(intent, arguments)
            }
            problem = nil
            return true
        } catch {
            problem = "没能读取源码：\(error)"
            return false
        }
    }

    private static func module(_ files: ProgramSourceFiles) -> ModuleSource {
        ModuleSource(files: Dictionary(files.files.map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first }))
    }

    private func load(_ program: ProgramSummary, from: String?) async {
        do {
            let data = try await server.data(of: program.id, as: CardValue.self)
            store.load(data.values, seq: data.seq, from: from)
        } catch {
            problem = "没能读取数据：\(error)"
        }
    }

    /// Its changes as they're made, wherever: and a new version, when it's its own.
    private func follow(_ program: ProgramSummary, from: String?, among all: [ProgramSummary]) {
        following.append(
            Task { [weak self, server] in
                do {
                    for try await head in server.heads(of: program.id) {
                        guard let self else { return }
                        if head.seq > self.store.seq[from, default: 0] { await self.catchUp(program, from: from) }
                        if from == nil, head.version > self.version {
                            self.close()
                            await self.open(among: all)
                            return
                        }
                    }
                } catch {
                    // Cancelled on close; the stream itself reconnects after transport failures.
                }
            }
        )
    }

    private func catchUp(_ program: ProgramSummary, from: String?) async {
        do {
            while true {
                let log = try await server.changes(
                    of: program.id,
                    after: store.seq[from, default: 0],
                    as: CloudChange.self
                )
                if log.reset {
                    await load(program, from: from)
                    return
                }
                store.receive(log.changes.map { ($0.seq, $0.change) }, from: from)
                if !log.more { return }
            }
        } catch {
            // The next head brings it again.
        }
    }

    /// What this device changed, to the server; refused, it goes.
    private func send(_ batch: CloudStore.Batch) {
        Task { [server, summary] in
            do {
                let accepted = try await server.change(summary.id, batch.changes, requestID: batch.id)
                store.accepted(batch.id, seq: accepted.seq)
            } catch {
                store.refused(batch.id)
                problem = "这次修改没有保存：\(error)"
            }
        }
    }

    /// An intent that calls tools or a model, run on the server; its changes come back with the others.
    private func runRemotely(_ intent: String, _ arguments: [String: CardValue]) async -> IntentOutcome? {
        do {
            let ran = try await server.run(summary.id, intent: intent, arguments: arguments, as: CardValue.self)
            // Its changes are the server's by then: brought in now, not on the next head.
            if ran.seq > store.seq[nil, default: 0] { await catchUp(summary, from: nil) }
            return IntentOutcome(value: ran.value ?? .null, dialog: ran.dialog)
        } catch {
            problem = "没能执行：\(error)"
            return nil
        }
    }
}

/// Fetches a mini program's photos (`media:<hash>`) through the server's short links, and
/// uploads those it picks.
struct FlooProgramHost: CardHost {
    let server: FlooClient

    struct NotHere: Error {}

    /// Intents with tools run on the server: nothing here calls one.
    func call(_ tool: String, arguments: [String: CardValue]) async throws -> CardValue {
        throw NotHere()
    }

    func image(_ url: String) async -> Data? {
        guard let (hash, variant) = MediaAddress.parse(url), let content = try? ContentHash(hash),
            let link = try? await server.link(to: content, variant: variant)  // nil: the placeholder stays
        else { return nil }
        if let bytes = link.content { return bytes }
        guard let address = link.url.flatMap(URL.init(string:)) else { return nil }
        return try? await URLSession.shared.data(from: address).0  // nil: the placeholder stays
    }

    /// A picked photo, uploaded: the program's Media for it.
    func upload(_ data: Data, type: String) async throws -> CardValue {
        let media = try await server.upload(data, type: type)
        return try JSONDecoder().decode(CardValue.self, from: JSONEncoder().encode(media))
    }
}

/// The list, and the program opened from it in its place, as the window's inspector shows them.
struct FlooProgramsView: View {
    @State var programs: FlooPrograms
    /// Puts the inspector away.
    var close: () -> Void
    @State private var open: FlooOpenProgram?

    var body: some View {
        if let open {
            FlooProgramScreen(program: open) {
                open.close()
                self.open = nil
            }
        } else {
            list
        }
    }

    private var list: some View {
        NavigationStack {
            List(programs.programs, id: \.id) { summary in
                Button(summary.name) {
                    let program = FlooOpenProgram(summary: summary, server: programs.server)
                    open = program
                    Task { await program.open(among: programs.programs) }
                }
            }
            .overlay {
                if let problem = programs.problem {
                    ContentUnavailableView("没有读到", systemImage: "exclamationmark.triangle", description: Text(problem))
                } else if programs.loaded, programs.programs.isEmpty {
                    ContentUnavailableView("还没有小程序", systemImage: "square.grid.2x2")
                }
            }
            .navigationTitle("小程序")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { close() } }
            }
            .task { await programs.load() }
            .refreshable { await programs.load() }
        }
    }
}

/// An open mini program, as it draws itself.
struct FlooProgramScreen: View {
    let program: FlooOpenProgram
    /// Back to the list.
    var close: () -> Void

    var body: some View {
        // A bar of its own above the program, whose toolbar has both corners.
        VStack(spacing: 0) {
            HStack {
                Button("关闭", systemImage: "xmark") { close() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let problem = program.problem, program.mini == nil {
                ScrollView { Text(problem).font(.system(.footnote, design: .monospaced)).padding() }
            } else {
                CardView(tree: program.session.tree)
                    .environment(\.cloudStore, program.store)
                    .environment(\.miniProgram, program.mini)
                    .environment(\.cardHost, program.host)
                    .environment(\.cardShowsPage, true)
                    .environment(\.cardRuntime, FlooOpenProgram.runtime)
                    .environment(\.horizontalSizeClass, .compact)
            }
        }
    }
}
