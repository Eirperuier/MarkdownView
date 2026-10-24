//
//  FlooHelper.swift
//  DemoApp
//
//  Floo Helper, carried in the Mac app (embed-helper.sh): this Mac's node, which holds the
//  Mac's system grants and runs its services — mail, messages, calendar and the rest (floo's
//  docs/mac-services.md §11). It's signed in with the demo's own session, kept in its home
//  for both; the demo starts it, stops it when you sign out, and has it ask for what a
//  service of this Mac needs, through its own commands.
//

#if targetEnvironment(macCatalyst)
import Foundation
import DeviceSupport
import TransportKit
import Wire

enum FlooHelper {
    /// Where it is in the app (embed-helper.sh puts it there).
    static let app = Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/Floo Helper.app", directoryHint: .isDirectory)

    /// Its home, as it has it: ~/.floo/node.
    static let home = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".floo/node", directoryHint: .isDirectory)

    enum State: Equatable {
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
        guard await self.account() == account else { return .signedOut }
        if serving { return .ready }
        if let failure = await launch([], activates: false) { return .stopped(failure) }
        // Up once it holds its home: it reads its settings and session first.
        for _ in 0..<20 {
            if serving { return .ready }
            try? await Task.sleep(for: .milliseconds(250))  // try?: cancelled, looked at once more
        }
        return serving ? .ready : .stopped(lastLog() ?? "没启动")
    }

    /// Where the session is kept, the demo's and the Helper's both: signed in in the demo,
    /// it's signed in.
    static let secrets = home.appending(path: "secrets", directoryHint: .isDirectory)

    /// Its device on `account`: its id, kept in its home when it registered.
    static func device(of account: AccountID) -> String? {
        // try?: not registered yet
        (try? String(contentsOf: secrets.appending(path: "device-id.\(account)"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The account the session is for.
    static func account() async -> AccountID? {
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

    /// You signed in as `account`: it's started again on that session, told where the
    /// server and sign-in are when it doesn't know yet.
    static func signedIn(as account: AccountID) async {
        keepSettings()
        await stop()
        _ = await state(for: account)
    }

    /// You signed out: this Mac's node goes too.
    static func stop() async {
        _ = await run("/usr/bin/pkill", ["-x", "Floo Helper"])
        for _ in 0..<20 where serving {
            try? await Task.sleep(for: .milliseconds(250))  // try?: cancelled, gone on regardless
        }
    }

    /// The server and sign-in it starts with, in its settings.json (docs/mac-services.md
    /// §11), where they aren't there already.
    private static func keepSettings() {
        let file = home.appending(path: "settings.json")
        // try?: none kept yet, or none readable, written afresh
        var kept = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) ?? [:]
        let given = [
            "FLOO_API": "https://\(FlooOnline.server)",
            "SUPABASE_PROJECT_REF": FlooOnline.supabase.components(separatedBy: ".").first ?? "",
            "SUPABASE_PUBLISHABLE_KEY": FlooOnline.publishableKey,
        ]
        guard given.contains(where: { kept[$0.key] != $0.value }) else { return }
        kept.merge(given) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // try?: not written, it says so in its log when it starts
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Has it ask for what `services` need of this Mac — system prompts, or System Settings
    /// with it to drag in — and returns when that's done. A new instance of its own, brought
    /// to the front: a system prompt asked from the background is refused without showing.
    static func allow(_ services: [String]) async {
        _ = await launch(["--allow"] + services, activates: true, waits: true)
    }

    /// The thing a floo link points to, as this Mac's service that has it tells it (floo's
    /// docs/services.md §2.10); nil when none here has it, or it isn't serving. Asked over
    /// its socket in its home, which answers only the app it is in.
    static func thing(at link: String) async -> (title: String, text: String)? {
        /// What it answers: DeepLink's `DeepLinkTarget`, `found` with the thing or `notFound`.
        struct Target: Decodable {
            struct Found: Decodable {
                struct Item: Decodable {
                    let title: String
                    let text: String
                }
                let _0: Item
            }
            let found: Found?
        }
        guard let request = try? JSONSerialization.data(withJSONObject: ["open": link]),  // try?: a string always encodes
              let reply = await ask(request),
              let target = try? JSONDecoder().decode(Target.self, from: reply)  // try?: unreadable, not here
        else { return nil }
        return target.found.map { ($0._0.title, $0._0.text) }
    }

    /// One request over its socket, `<home>/helper.sock`: a JSON line out, a JSON line back.
    private static func ask(_ request: Data) async -> Data? {
        let path = home.appending(path: "helper.sock").path
        return await Task.detached {
            let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard socket >= 0 else { return nil }
            defer { close(socket) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { return nil }
            let line = request + Data([0x0A])
            let written = line.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
            guard written == line.count else { return nil }
            var reply = Data()
            var buffer = [UInt8](repeating: 0, count: 16 << 10)
            while true {
                let count = read(socket, &buffer, buffer.count)
                guard count > 0 else { break }
                reply.append(contentsOf: buffer[0..<count])
                if buffer[0..<count].contains(0x0A) { break }
            }
            return reply.isEmpty ? nil : reply
        }.value
    }

    /// Opens a new instance of it with `arguments` through Launch Services, from this app:
    /// the active one, whose click it is. To come to the front (`activates`) this app hands it
    /// the front once it's running (`bringForward`): since macOS 14 the window server lets an
    /// app activate only when the active one let it (`activates` alone came to nothing, and
    /// its prompts were never asked: not_in_foreground). AppKit's workspace, application and
    /// running application, which Catalyst doesn't declare but has. `waits`: until it has
    /// quit. Why it didn't open, if it didn't.
    private static func launch(_ arguments: [String], activates: Bool, waits: Bool = false) async -> String? {
        guard let workspaceClass = NSClassFromString(name("TlNXb3Jrc3BhY2U=")) as? NSObject.Type,
              let configurationClass = NSClassFromString(name("TlNXb3Jrc3BhY2VPcGVuQ29uZmlndXJhdGlvbg==")) as? NSObject.Type,
              let workspace = workspaceClass.value(forKey: name("c2hhcmVkV29ya3NwYWNl")) as? NSObject
        else { return "这台 Mac 上打不开它" }
        let configuration = configurationClass.init()
        configuration.setValue(arguments, forKey: "arguments")
        configuration.setValue(true, forKey: name("Y3JlYXRlc05ld0FwcGxpY2F0aW9uSW5zdGFuY2U="))
        configuration.setValue(activates, forKey: "activates")
        typealias Open = @convention(c) (
            NSObject, Selector, NSURL, NSObject, @escaping @convention(block) (NSObject?, NSError?) -> Void
        ) -> Void
        let selector = NSSelectorFromString(name("b3BlbkFwcGxpY2F0aW9uQXRVUkw6Y29uZmlndXJhdGlvbjpjb21wbGV0aW9uSGFuZGxlcjo="))
        let open = unsafeBitCast(workspace.method(for: selector), to: Open.self)
        /// What the workspace answers, handed back from its queue.
        struct Opened: @unchecked Sendable {
            let app: NSObject?
            let error: String?
        }
        let opened: Opened = await withCheckedContinuation { done in
            open(workspace, selector, app as NSURL, configuration) { running, error in
                done.resume(returning: Opened(app: running, error: error?.localizedDescription))
            }
        }
        if let error = opened.error { return error }
        if activates, let running = opened.app { await bringForward(running) }
        guard waits, let running = opened.app else { return nil }
        // NSRunningApplication says when it has quit.
        while (running.value(forKey: "terminated") as? Bool) == false {
            try? await Task.sleep(for: .milliseconds(500))  // try?: cancelled, looked at once more
        }
        return nil
    }

    /// Hands `running` the front from this app, the active one: yields it the front
    /// (NSApplication's yieldActivationToApplication:) and activates it with this app's
    /// activation (NSRunningApplication's activateFromApplication:options:). Yielding by
    /// bundle id before it ran let it come forward only sometimes.
    @MainActor private static func bringForward(_ running: NSObject) {
        guard let applicationClass = NSClassFromString(name("TlNBcHBsaWNhdGlvbg==")) as? NSObject.Type,
              let application = applicationClass.value(forKey: name("c2hhcmVkQXBwbGljYXRpb24=")) as? NSObject,
              let runningClass = NSClassFromString(name("TlNSdW5uaW5nQXBwbGljYXRpb24=")) as? NSObject.Type,
              let current = runningClass.value(forKey: name("Y3VycmVudEFwcGxpY2F0aW9u")) as? NSObject
        else { return }
        let yield = NSSelectorFromString(name("eWllbGRBY3RpdmF0aW9uVG9BcHBsaWNhdGlvbjo="))
        if application.responds(to: yield) { _ = application.perform(yield, with: running) }
        let activate = NSSelectorFromString(name("YWN0aXZhdGVGcm9tQXBwbGljYXRpb246b3B0aW9uczo="))
        guard running.responds(to: activate) else { return }
        typealias Activate = @convention(c) (NSObject, Selector, NSObject, UInt) -> Bool
        let activated = unsafeBitCast(running.method(for: activate), to: Activate.self)(running, activate, current, 0)
        if !activated { NSLog("Floo Helper wasn't brought to the front") }
    }

    /// A name Catalyst doesn't declare, from its base64.
    private static func name(_ encoded: String) -> String {
        String(decoding: Data(base64Encoded: encoded) ?? Data(), as: UTF8.self)
    }

    /// The last line it wrote to its log, to say why something didn't go.
    private static func lastLog() -> String? {
        guard let text = try? String(contentsOf: home.appending(path: "helper.log"), encoding: .utf8) else { return nil }  // try?: no log, nothing to say
        return text.split(separator: "\n").last.map { line in
            // Each line starts with its time.
            String(line.split(separator: " ", maxSplits: 1).last ?? line)
        }
    }

    /// Runs `path` with `arguments`, off the main actor: its exit status and what it wrote
    /// to standard error.
    private static func run(_ path: String, _ arguments: [String]) async -> (status: Int32, errors: String) {
        await Task.detached {
            var out: [Int32] = [-1, -1]
            guard pipe(&out) == 0 else { return (-1, "没法启动 \(path)") }
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, out[1], 2)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Nothing else of ours goes with it.
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
            let argv = ([path] + arguments).map { strdup($0) } + [nil]
            let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { (argv + envp).forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
            close(out[1])
            guard spawned == 0 else {
                close(out[0])
                return (-1, "没法启动 \(path)")
            }
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
