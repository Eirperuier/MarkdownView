//
//  FlooHelper.swift
//  DemoApp
//
//  Floo Helper, carried in the Mac app (embed-helper.sh): this Mac's node, which holds the
//  Mac's system grants and runs its services — mail, messages, calendar and the rest (floo's
//  docs/mac-services.md §11). The demo signs it in as you, starts it, and has it ask for
//  what a service of this Mac needs; everything goes through the Helper's own commands.
//

#if targetEnvironment(macCatalyst)
import Foundation
import DeviceSupport
import TransportKit
import Wire

enum FlooHelper {
    /// Where it is in the app; nil when the app was built without it.
    static var app: URL? {
        let app = Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/Floo Helper.app", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    /// Its home, as it has it: ~/.floo/node.
    static let home = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".floo/node", directoryHint: .isDirectory)

    enum State: Equatable {
        /// The app was built without it.
        case missing
        /// Not signed in, or as another account.
        case signedOut
        /// Signed in as you, and serving.
        case ready
        /// Signed in as you, but it didn't start.
        case stopped(String)
    }

    /// Where it stands for `account`, started first when it's signed in as it and isn't
    /// serving.
    static func state(for account: AccountID) async -> State {
        guard let app else { return .missing }
        guard await self.account() == account else { return .signedOut }
        if serving { return .ready }
        let started = await run("/usr/bin/open", ["-n", "-g", "-a", app.path])
        guard started.status == 0 else { return .stopped(started.errors) }
        // Up once it holds its home: it reads its settings and session first.
        for _ in 0..<20 {
            if serving { return .ready }
            try? await Task.sleep(for: .milliseconds(250))  // try?: cancelled, looked at once more
        }
        return serving ? .ready : .stopped(lastLog() ?? "没启动")
    }

    /// The account its kept session is for.
    static func account() async -> AccountID? {
        let secrets = home.appending(path: "secrets", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: secrets.path), let store = try? FileSecrets(folder: secrets) else { return nil }
        return try? await KeychainSessionStore(store: store).load()?.account  // try?: one it can't read is none
    }

    /// Whether one serves from its home: it holds the home's lock while it does.
    static var serving: Bool {
        let descriptor = open(home.appending(path: "node.lock").path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// Signs it in as `email`, in place of whoever it was signed in as: the one serving is
    /// stopped first, and it's started again on the new session.
    static func signIn(email: String, password: String) async throws {
        guard let app else { return }
        _ = await run("/usr/bin/pkill", ["-x", "Floo Helper"])
        for _ in 0..<20 where serving {
            try await Task.sleep(for: .milliseconds(250))
        }
        let ref = FlooOnline.supabase.components(separatedBy: ".").first ?? ""
        var environment = ProcessInfo.processInfo.environment
        environment["FLOO_API"] = "https://\(FlooOnline.server)"
        environment["SUPABASE_PROJECT_REF"] = ref
        environment["SUPABASE_PUBLISHABLE_KEY"] = FlooOnline.publishableKey
        // Not through Launch Services: signing in asks nothing of the system's grants.
        let signed = await run(
            app.appending(path: "Contents/MacOS/Floo Helper").path,
            ["--sign-in", email],
            environment: environment,
            input: password + "\n"
        )
        guard signed.status == 0 else {
            throw FlooConnectError(reason: lastLog() ?? "Floo Helper 没登录上")
        }
        if let account = await account() { _ = await state(for: account) }
    }

    /// Has it ask for what `services` need of this Mac — system prompts, or System Settings
    /// with it to drag in — and returns when that's done. Through Launch Services, so the
    /// grants are the Helper's.
    static func allow(_ services: [String]) async {
        guard let app else { return }
        _ = await run("/usr/bin/open", ["-n", "-W", "-a", app.path, "--args", "--allow"] + services)
    }

    /// The last line it wrote to its log, to say why something didn't go.
    private static func lastLog() -> String? {
        guard let text = try? String(contentsOf: home.appending(path: "helper.log"), encoding: .utf8) else { return nil }  // try?: no log, nothing to say
        return text.split(separator: "\n").last.map { line in
            // Each line starts with its time.
            String(line.split(separator: " ", maxSplits: 1).last ?? line)
        }
    }

    /// Runs `path` with `arguments`, `input` on its standard input, off the main actor:
    /// its exit status and what it wrote to standard error.
    private static func run(
        _ path: String,
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: String = ""
    ) async -> (status: Int32, errors: String) {
        await Task.detached {
            var into: [Int32] = [-1, -1]
            var out: [Int32] = [-1, -1]
            guard pipe(&into) == 0, pipe(&out) == 0 else { return (-1, "没法启动 \(path)") }
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, into[0], 0)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, out[1], 2)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Nothing else of ours goes with it.
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
            let argv = ([path] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { (argv + envp).forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
            close(into[0])
            close(out[1])
            guard spawned == 0 else {
                close(into[1])
                close(out[0])
                return (-1, "没法启动 \(path)")
            }
            _ = input.utf8CString.withUnsafeBufferPointer { write(into[1], $0.baseAddress, $0.count - 1) }
            close(into[1])
            var errors = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(out[0], &buffer, buffer.count)
                if count <= 0 { break }
                errors.append(contentsOf: buffer[0..<count])
            }
            close(out[0])
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let exited = status & 0x7f == 0 ? (status >> 8) & 0xff : -1
            return (exited, String(decoding: errors, as: UTF8.self))
        }.value
    }
}
#endif
