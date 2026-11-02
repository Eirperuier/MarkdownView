import SwiftUI
import CardModel
import CardSyntax
import CardUI
import Observation
import TransportKit
import Wire

/// A mini program's cards and rows in the conversation (floo docs/pages.md §6): the call the
/// answer stored (`衣柜.TodayCard(…)`), compiled with the program's module as the server
/// checked it (`ProgramCard`); the keys of its data it names, as this device keeps them, so
/// the card changes as the data does; its buttons run the program's intents.
@MainActor
final class FlooProgramCards {
    private let server: FlooClient
    /// Draws the conversation again: a program read, its cards and rows can be.
    private let refresh: @MainActor () -> Void
    private var programs: [ProgramID: FlooOpenProgram] = [:]
    private var modules: [ProgramID: ModuleSource] = [:]
    private var loading: Set<ProgramID> = []
    /// The program each card shown is of, by the card's key: what the view drawing it sets up.
    private static var shown: [String: FlooOpenProgram] = [:]

    init(server: FlooClient, refresh: @escaping @MainActor () -> Void) {
        self.server = server
        self.refresh = refresh
    }

    /// The source `call` is drawn from: rewritten, with the program's module; nil while the
    /// program is read, after which the conversation is drawn again.
    func source(_ call: String, of program: AnswerCard.Program) -> String? {
        guard let module = modules[program.id] else {
            load(program)
            return nil
        }
        let rewritten = ProgramCard.rewritten(call, program: program.name, keys: Set(program.keys)).text
        return ProgramCard.module(module, call: rewritten).text
    }

    /// `data` with the program's keys as this device has them now; as it was sent until the
    /// program is read.
    func data(_ data: CardValue, of program: AnswerCard.Program) -> CardValue {
        guard let store = programs[program.id]?.store, case .object(var fields) = data else { return data }
        for key in program.keys {
            if let value = store.value(CloudStore.Key(key, from: nil)) { fields[ProgramCard.dataName(key)] = value }
        }
        return .object(fields)
    }

    /// Shows card `key` of `program` in `demo`, once the program is read, and keeps its data
    /// the program's.
    func show(_ key: String, call: String, program: AnswerCard.Program, data: CardValue, in demo: FlooDemo) {
        guard let source = source(call, of: program) else { return }
        let fresh = demo.sessions[key] == nil
        demo.setCard(key, source: source, data: self.data(data, of: program))
        Self.shown[key] = programs[program.id]
        if fresh, let session = demo.sessions[key] { keep(session, data: data, of: program) }
    }

    /// The program card `key` is of, for the view that draws it.
    static func program(of key: String) -> FlooOpenProgram? { shown[key] }

    private func keep(_ session: CardSession, data: CardValue, of program: AnswerCard.Program) {
        withObservationTracking {
            _ = self.data(data, of: program)
        } onChange: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                session.data = self.data(data, of: program)
                self.keep(session, data: data, of: program)
            }
        }
    }

    /// Opens the program as its page does — its source, its data, following both — and keeps
    /// its module for the cards.
    private func load(_ program: AnswerCard.Program) {
        guard loading.insert(program.id).inserted else { return }
        Task {
            do {
                let all = try await server.programs().programs.filter { $0.version > 0 }
                guard let summary = all.first(where: { $0.id == program.id }) else { return }
                let open = FlooOpenProgram(summary: summary, server: server)
                await open.open(among: all)
                let files = try await server.source(of: program.id)
                modules[program.id] = ModuleSource(
                    files: Dictionary(files.files.map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first }))
                programs[program.id] = open
                refresh()
            } catch {
                // Unread, it's tried again when a card of it is shown next.
                loading.remove(program.id)
            }
        }
    }
}

extension View {
    /// Card `key` as a mini program's, when it is one: its buttons run the program's intents.
    func flooProgram(card key: String?) -> some View {
        let program = key.flatMap(FlooProgramCards.program(of:))
        return environment(\.miniProgram, program?.mini).environment(\.cloudStore, program?.store)
            // Its photos as the program's, in the account's cache.
            .transformEnvironment(\.cardHost) { host in
                if let program { host = FlooChatHost(media: program.host) }
            }
    }
}
