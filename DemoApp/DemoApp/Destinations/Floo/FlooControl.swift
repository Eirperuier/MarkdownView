//
//  FlooControl.swift
//  DemoApp
//
//  A test hook: `-flooControl <port>` opens a tiny HTTP server on 127.0.0.1 that reads the
//  conversation shown, sends, answers its cards, opens its sheets and shoots the window, so a
//  test drives the app without clicking through accessibility. Debug builds only. No auth
//  beyond loopback and the launch argument: whoever runs on this Mac while it's on can drive
//  the app as you. See CONTROL.md.
//

#if DEBUG
import Foundation
import Network
import UIKit
import Wire

/// One request as read off the socket: what it asks, and its JSON body.
private struct ControlRequest: Sendable {
    let method: String
    let path: String
    let body: Data
}

/// Why a body doesn't answer a request, as its 400 says.
private struct ControlError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One answer: a status, a type and its bytes.
private struct ControlResponse: Sendable {
    var status = 200
    var type = "application/json"
    var body = Data()
    var headers: [String: String] = [:]

    static func json(_ object: Any, status: Int = 200) -> ControlResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ControlResponse(status: status, body: body)
    }

    static func error(_ message: String, status: Int = 400) -> ControlResponse {
        json(["error": message], status: status)
    }
}

@MainActor
enum FlooControl {
    /// Posted with the page to show ("sites", "devices"; "chat" closes them): FlooDestination
    /// shows its sheet, as its account menu does.
    static let opens = Notification.Name("FlooControl.opens")

    /// The conversation driven: the window's last shown.
    private static weak var demo: FlooDemo?
    private static var listener: NWListener?

    /// The page shown is the one driven; the server starts with the first, when launched with
    /// `-flooControl <port>`.
    static func attach(_ demo: FlooDemo) {
        self.demo = demo
        guard listener == nil,
              let given = UserDefaults.standard.string(forKey: "flooControl").flatMap(UInt16.init),
              let port = NWEndpoint.Port(rawValue: given)
        else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in ControlConnection(connection).start() }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: print("FlooControl: listening on 127.0.0.1:\(given)")
                case .failed(let error): print("FlooControl: \(error)")
                default: break
                }
            }
            listener.start(queue: ControlConnection.queue)
            self.listener = listener
        } catch {
            print("FlooControl: not started: \(error)")
        }
    }

    fileprivate static func handle(_ request: ControlRequest) async -> ControlResponse {
        // Only where it goes is said: bodies carry what's typed into secret forms.
        print("FlooControl: \(request.method) \(request.path)")
        guard let demo else { return .error("no conversation shown", status: 503) }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/state"): return state(demo)
        case ("POST", "/send"): return await send(demo, body)
        case ("POST", "/answer"): return answer(demo, body)
        case ("POST", "/open"): return await open(body)
        case ("GET", "/shot"): return shot()
        #if targetEnvironment(macCatalyst)
            case ("GET", "/panel"): return .json(["steps": FlooStepPanel.opened])
            case ("POST", "/panel"):
                return FlooStepPanel.drive(body) ? .json(["ok": true]) : .error("no step window for that ask", status: 404)
        #endif
        default: return .error("no such endpoint", status: 404)
        }
    }

    // MARK: State

    private static func state(_ demo: FlooDemo) -> ControlResponse {
        var messages: [[String: Any]] = []
        var asks: [[String: Any]] = []
        for entry in demo.shownEntries {
            switch entry {
            case .said(let said):
                let from: String =
                    switch said.speaker {
                    case .me: "me"
                    case .person(let name): name
                    }
                messages.append(["number": said.number.map { $0 as Any } ?? NSNull(), "from": from, "text": said.text])
            case .message(let message):
                messages.append(["number": message.number.map { $0 as Any } ?? NSNull(), "from": message.agent.name, "text": message.text])
                asks += message.asks.map { describe($0, demo) }
            default: break
            }
        }
        return .json([
            "signedIn": demo.live?.server != nil,
            "live": demo.isLive,
            "conversation": demo.place?.id ?? NSNull(),
            "title": demo.title,
            "messages": Array(messages.suffix(30)),
            "asks": asks,
        ])
    }

    private static func describe(_ card: FlooAskCard, _ demo: FlooDemo) -> [String: Any] {
        var out: [String: Any] = [
            "id": card.id,
            "status": "\(card.state)",
            "answered": card.state == .answered || card.items.allSatisfy { $0.answer != nil },
            "from": card.agent.name,
        ]
        if let item = card.items.first { out.merge(describe(item)) { a, _ in a } }
        if card.items.count > 1 { out["items"] = card.items.map(describe) }
        if card.closes != .one { out["closes"] = "\(card.closes)" }
        if let line = card.line { out["line"] = line }
        if let device = card.device ?? card.place?.components(separatedBy: " · ").first { out["device"] = device }
        if let sealedTo = card.sealedTo { out["sealedTo"] = sealedTo }
        if let origin = card.origin { out["origin"] = origin }
        if !card.about.isEmpty { out["about"] = card.about }
        if let why = card.why { out["why"] = why }
        if let done = card.done { out["done"] = done }
        switch card.stage {
        case .engaged(let words)?: out["stage"] = ["engaged": words]
        case .working(let words)?: out["stage"] = ["working": words]
        case .failed(let words)?: out["stage"] = ["failed": words]
        case nil: break
        }
        return out
    }

    /// A request: its controls in order (floo interaction.md §4), how it is sent, and — where
    /// it is exactly one of the forms before controls — that form's keys as they were
    /// (`kind`, `options`, `fields`, `keep`…), for scripts written against them.
    private static func describe(_ item: FlooRequest) -> [String: Any] {
        var out: [String: Any] = ["title": item.title]
        if item.question != item.title { out["question"] = item.question }
        if let answer = item.answer { out["answer"] = answer }
        out["controls"] = item.controls.map(describe)
        out["submit"] = "\(item.submit())"
        if item.from > 0 {
            out["from"] = item.from
            out["earlier"] = item.earlier
        }
        out.merge(legacy(item)) { a, _ in a }
        return out
    }

    private static func describe(_ control: FlooControlModel) -> [String: Any] {
        var out: [String: Any] = ["id": control.id, "required": control.mustAnswer]
        if let label = control.label { out["label"] = label }
        if let group = control.group { out["group"] = group }
        switch control.kind {
        case .choice(let options, let multiple, let own, let groups):
            out["type"] = "choice"
            out["options"] = options.enumerated().map { ["key": "\($0.offset)", "label": $0.element.label] }
            out["multiple"] = multiple
            out["own"] = own != nil
            if groups { out["groups"] = true }
        case .field(let field):
            out["type"] = "field"
            out["label"] = field.label
            out["kind"] = "\(field.kind)"
            out["guess"] = field.guess
        case .secret(let field, let kind):
            out["type"] = "secret"
            out["label"] = field.label
            out["kind"] = kind
            out["autofill"] = orNull(field.autofill)
        case .decision(let options):
            out["type"] = "decision"
            out["options"] = options.map { ["key": $0.key, "label": $0.label, "standing": $0.standing, "danger": $0.danger] }
        case .step(let what, _, _):
            out["type"] = "step"
            out["what"] = what
        case .view(let frame):
            out["type"] = "view"
            out["sha256"] = frame.sha256
            out["width"] = frame.width
            out["height"] = frame.height
            out["scale"] = frame.scale
        case .toggle(let value, let keep):
            out["type"] = "toggle"
            out["value"] = value
            if keep { out["effect"] = "keep-signed-in" }
        case .say(let text):
            out["type"] = "say"
            out["text"] = text
        case .link(let url):
            out["type"] = "link"
            out["url"] = url
        case .image(let url):
            out["type"] = "image"
            out["url"] = url
        case .unknown(let type):
            out["type"] = type
            out["unknown"] = true
        }
        return out
    }

    /// The keys a request of one of the forms before controls was described by.
    private static func legacy(_ item: FlooRequest) -> [String: Any] {
        let controls = item.controls
        var out: [String: Any] = [:]
        let keep = controls.lazy.compactMap { control -> Bool? in
            if case .toggle(let value, true) = control.kind { value } else { nil }
        }.first
        if let only = controls.first, controls.count == 1 {
            switch only.kind {
            case .step(let what, _, _):
                out["kind"] = "step"
                out["what"] = what
            case .decision(let options):
                out["kind"] = "decision"
                out["dangerous"] = options.contains(where: \.danger)
                out["options"] = options.map { ["key": $0.key, "label": $0.label, "standing": $0.standing] as [String: Any] }
            case .choice(let options, let multiple, _, _):
                out["kind"] = "choose"
                out["multiple"] = multiple
                out["options"] = options.enumerated().map { ["key": "\($0.offset)", "label": $0.element.label, "standing": false] }
            default: break
            }
        }
        if controls.count == 2, case .say(let effect) = controls[0].kind, case .choice = controls[1].kind {
            out["kind"] = "confirm"
            out["effect"] = effect
        }
        if !controls.isEmpty, controls.allSatisfy({ if case .field = $0.kind { true } else { false } }) {
            out["kind"] = "fill"
            out["fields"] = controls.map { control -> [String: Any] in
                guard case .field(let field) = control.kind else { return [:] }
                return ["key": control.id, "label": field.label, "kind": "\(field.kind)", "autofill": orNull(field.autofill), "guess": field.guess]
            }
        }
        let secrets = controls.compactMap { control -> [String: Any]? in
            guard case .secret(let field, let kind) = control.kind else { return nil }
            return ["key": control.id, "label": field.label, "kind": kind, "autofill": orNull(field.autofill)]
        }
        if !secrets.isEmpty {
            out["kind"] = "secret"
            out["fields"] = secrets
            if let keep { out["keep"] = keep }
            if let groups = item.groups, case .choice(let options, _, _, _) = groups.kind { out["ways"] = options.map(\.label) }
        }
        if let view = controls.lazy.compactMap({ control -> FlooViewFrame? in
            if case .view(let frame) = control.kind { frame } else { nil }
        }).first, secrets.isEmpty, !controls.contains(where: \.answered) {
            out["kind"] = "view"
            out["sha256"] = view.sha256
            out["width"] = view.width
            out["height"] = view.height
            out["scale"] = view.scale
            out["keep"] = keep.map { $0 as Any } ?? NSNull()
        }
        return out
    }

    private static func orNull(_ value: String?) -> Any { value ?? NSNull() }

    // MARK: Send

    /// As the composer sends: what's typed goes as the draft (one you were typing is put back
    /// after), answered once the backend took it.
    private static func send(_ demo: FlooDemo, _ body: [String: Any]) async -> ControlResponse {
        guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("text is required")
        }
        guard demo.live != nil else { return .error("not live: a scenario's conversation takes no messages", status: 409) }
        let answersAsk = demo.answering?.ask != nil
        let kept = demo.draft
        demo.draft = text
        let sent = demo.sendDraft()
        if !kept.isEmpty, demo.draft.isEmpty { demo.draft = kept }
        if answersAsk { return .json(["ok": true, "answered": true]) }
        guard let sent else { return .error("not sent: no conversation open yet", status: 409) }
        guard let number = await sent.value else { return .error("not accepted", status: 502) }
        return .json(["ok": true, "number": number])
    }

    // MARK: Answer

    /// As the card answers (`FlooDemo.answerAsk`): live, that's FlooLive's respond / decline /
    /// take / turn / answer, signed and sealed as ever. Per control:
    /// `{ask, item?, values: {control: value}, secrets?: {control: words}, declined?}` — a
    /// choice's `{"picked": [i], "own"?}` (or `[i]`, `i`), a field's words, a decision's key, a
    /// step's `engaged` / `completed` / `skipped`, a toggle's true or false; a value given a
    /// secret's id is taken as that secret. Only toggles, on a request with nothing to send,
    /// are turned without answering it. The forms' bodies before controls still work.
    private static func answer(_ demo: FlooDemo, _ body: [String: Any]) -> ControlResponse {
        guard let id = body["ask"] as? String else { return .error("ask is required") }
        guard let card = demo.shownEntries.lazy.compactMap({ entry -> FlooAskCard? in
            if case .message(let message) = entry { message.asks.first { $0.id == id } } else { nil }
        }).first else { return .error("no such ask shown", status: 404) }
        let index = body["item"] as? Int ?? 0
        guard card.items.indices.contains(index) else { return .error("no such item") }
        let item = card.items[index]
        guard card.state == .open, item.answer == nil else { return .error("not open: \(card.state)", status: 409) }
        if body["declined"] as? Bool == true || body["decline"] as? Bool == true || body["cancel"] as? Bool == true {
            // A decision's no where it is one alone, as its button; else 不做了.
            if item.controls.count == 1, case .decision = item.controls[0].kind {
                demo.answerAsk(id, item: index, .decide(go: false, standing: nil))
            } else {
                demo.answerAsk(id, item: index, .decline)
            }
            return .json(["ok": true])
        }
        switch picked(body, item, card) {
        case .failure(let error): return .error(error.message)
        case .success(let picks): for pick in picks { demo.answerAsk(id, item: index, pick) }
        }
        return .json(["ok": true])
    }

    /// What a body gives a request, as the card's own actions.
    private static func picked(_ body: [String: Any], _ item: FlooRequest, _ card: FlooAskCard) -> Result<[FlooAnswerPick], ControlError> {
        let byID = Dictionary(item.controls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hasSecrets = item.controls.contains { if case .secret = $0.kind { true } else { false } }
        // The forms before controls, by their keys.
        let secretNames = Set(item.controls.flatMap { control -> [String] in
            if case .secret(let field, _) = control.kind { [control.id, field.label] } else { [] }
        })
        let secretsAlone = (body["values"] as? [String: String]).map { !$0.isEmpty && Set($0.keys).isSubset(of: secretNames) } ?? false
        if body["values"] == nil || (hasSecrets && body["secrets"] == nil && secretsAlone) {
            if let legacy = legacyPick(body, item, card) { return legacy }
        }
        var values: [String: FlooValue] = [:]
        var secrets = body["secrets"] as? [String: String] ?? [:]
        for (key, raw) in body["values"] as? [String: Any] ?? [:] {
            guard let control = byID[key] ?? item.controls.first(where: { if case .secret(let field, _) = $0.kind { field.label == key } else { false } })
            else { return .failure(ControlError("no control \(key)")) }
            switch (control.kind, raw) {
            case (.secret, let words as String): secrets[control.id] = words
            case (.choice, let object as [String: Any]):
                values[control.id] = .choice(object["picked"] as? [Int] ?? [], own: object["own"] as? String)
            case (.choice, let picks as [Int]): values[control.id] = .choice(picks)
            case (.choice, let pick as Int): values[control.id] = .choice([pick])
            case (.field, let words as String): values[control.id] = .text(words)
            case (.decision(let options), let key as String):
                guard options.contains(where: { $0.key == key || $0.label == key }) else { return .failure(ControlError("no such choice \(key)")) }
                values[control.id] = .key(options.first { $0.key == key || $0.label == key }!.key)
            case (.step, let state as String):
                switch state {
                case "engaged": return .success([.step(.open)])
                case "completed": values[control.id] = .step(.done)
                case "skipped": values[control.id] = .step(.skip)
                default: return .failure(ControlError("step is engaged, completed or skipped"))
                }
            case (.toggle, let on as Bool): values[control.id] = .toggle(on)
            default: return .failure(ControlError("not a value for \(control.id) (\(control.kind))"))
            }
        }
        if card.closes == .vote, let only = values.first, case .choice(let picks, _) = only.value { return .success([.vote(picks)]) }
        let turnsOnly = secrets.isEmpty && !values.isEmpty && values.allSatisfy { if case .toggle = $0.value { true } else { false } }
        if turnsOnly, item.submit() == .asker {
            return .success(values.compactMap { id, value in if case .toggle(let on) = value { .turn(id, on) } else { nil } })
        }
        guard !values.isEmpty || !secrets.isEmpty else { return .failure(ControlError("values is required")) }
        // What isn't given goes as the card holds it: guesses, defaults.
        var whole = item.resolve(.guesses) ?? ([:], [:])
        if hasSecrets { whole.secrets = [:] }
        whole.values.merge(values) { _, given in given }
        whole.secrets.merge(secrets) { _, given in given }
        for control in item.current(group: item.group(nil)) where control.mustAnswer {
            switch control.kind {
            case .secret: if whole.secrets[control.id] == nil { return .failure(ControlError("missing value for \(control.id)")) }
            case .choice, .decision, .step:
                if values[control.id] == nil, item.submit() == .button { return .failure(ControlError("missing value for \(control.id)")) }
                if whole.values[control.id] == nil { return .failure(ControlError("missing value for \(control.id)")) }
            default: break
            }
        }
        // A tap's control alone: just that.
        if item.submit() == .tap { whole = (values, secrets) }
        return .success([.submit(whole.values, secrets: whole.secrets)])
    }

    /// The bodies of the forms before controls: `choice` (a decision's key or label),
    /// `values` (a secret form's, by key or label) with `way` and `keep`, `keep` alone (a
    /// view), `step`, `picked` / `own`, `confirmed`, `filled`.
    private static func legacyPick(_ body: [String: Any], _ item: FlooRequest, _ card: FlooAskCard) -> Result<[FlooAnswerPick], ControlError>? {
        let controls = item.current(group: item.group(nil))
        if let choice = body["choice"] as? String,
           let decision = controls.first(where: { if case .decision = $0.kind { true } else { false } }),
           case .decision(let options) = decision.kind
        {
            guard let option = options.first(where: { $0.key == choice || $0.label == choice }) else {
                return .failure(ControlError("no such choice"))
            }
            return .success([.submit([decision.id: .key(option.key)])])
        }
        if let given = body["values"] as? [String: String] {
            var secrets: [String: String] = [:]
            var values: [String: FlooValue] = [:]
            if let groups = item.groups { values[groups.id] = .choice([body["way"] as? Int ?? 0]) }
            let group = item.group((values[item.groups?.id ?? ""]).flatMap { if case .choice(let p, _) = $0 { p } else { nil } })
            for control in item.current(group: group) {
                guard case .secret(let field, _) = control.kind else { continue }
                guard let words = given[control.id] ?? given[field.label] else { return .failure(ControlError("missing value for \(control.id)")) }
                secrets[control.id] = words
            }
            if let keep = body["keep"] as? Bool, let toggle = controls.first(where: { if case .toggle(_, true) = $0.kind { true } else { false } }) {
                values[toggle.id] = .toggle(keep)
            } else {
                for control in controls { if case .toggle(let on, _) = control.kind { values[control.id] = .toggle(on) } }
            }
            return .success([.submit(values, secrets: secrets)])
        }
        if let keep = body["keep"] as? Bool, let toggle = controls.first(where: { if case .toggle(_, true) = $0.kind { true } else { false } }) {
            return .success([.turn(toggle.id, keep)])
        }
        if let step = body["step"] as? String {
            switch step {
            case "engaged": return .success([.step(.open)])
            case "completed": return .success([.step(.done)])
            case "skipped": return .success([.step(.skip)])
            default: return .failure(ControlError("step is engaged, completed or skipped"))
            }
        }
        if body["own"] as? Bool == true { return .success([.own]) }
        if let picked = (body["picked"] as? [Int]) ?? (body["picked"] as? Int).map({ [$0] }), !picked.isEmpty {
            if card.closes == .vote { return .success([.vote(picked)]) }
            return .success([picked.count == 1 ? .option(picked[0]) : .options(picked)])
        }
        if let yes = body["confirmed"] as? Bool { return .success([.confirm(yes)]) }
        if let filled = body["filled"] as? [String] {
            let fields = controls.filter { if case .field = $0.kind { true } else { false } }
            guard filled.count == fields.count else { return .failure(ControlError("filled: one per field")) }
            return .success([.submit(Dictionary(uniqueKeysWithValues: zip(fields.map(\.id), filled.map(FlooValue.text))))])
        }
        if body["filled"] as? Bool == true { return .success([.guesses]) }
        return nil
    }

    // MARK: Pages

    private static func open(_ body: [String: Any]) async -> ControlResponse {
        guard let page = body["page"] as? String, ["sites", "devices", "chat"].contains(page) else {
            return .error("page is sites, devices or chat")
        }
        // One sheet at a time: what's open goes first.
        NotificationCenter.default.post(name: opens, object: "chat")
        if page != "chat" {
            try? await Task.sleep(for: .milliseconds(600))  // try?: not cancelled here
            NotificationCenter.default.post(name: opens, object: page)
        }
        try? await Task.sleep(for: .milliseconds(800))  // its sheet in, for a shot after
        return .json(["ok": true])
    }

    // MARK: Shot

    /// The key window as it looks, sheets and all. On the Mac a sheet is a window of its own
    /// (`_UIBridgedPresentationWindow`, an AppKit sheet) that isn't among its scene's, so the
    /// key window's drawing alone (`-flooShots`) leaves it out: each presented controller's
    /// window is drawn over it too, as the Mac shows a sheet — centred under the window's top
    /// bar, on the page's background (AppKit draws the sheet's own, which UIKit can't).
    private static func shot() -> ControlResponse {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let key = windows.first(where: \.isKeyWindow) ?? windows.first else { return .error("no window", status: 503) }
        var drawn = (key.windowScene?.windows ?? [key]).filter { !$0.isHidden && $0.alpha > 0 }
            .enumerated().sorted { ($0.element.windowLevel.rawValue, $0.offset) < ($1.element.windowLevel.rawValue, $1.offset) }.map(\.element)
        // Sheets, in the order they were presented, over all else.
        var top = drawn.last?.rootViewController ?? key.rootViewController
        while let next = top?.presentedViewController {
            if let window = next.viewIfLoaded?.window, !drawn.contains(where: { $0 === window }) { drawn.append(window) }
            top = next
        }
        var placed: [String] = []
        let image = UIGraphicsImageRenderer(bounds: key.bounds).image { _ in
            for window in drawn {
                let frame = place(window, over: key)
                if window !== key, !(key.windowScene?.windows.contains { $0 === window } ?? false) {
                    let sheet = UIBezierPath(roundedRect: frame, cornerRadius: 10)
                    UIColor.systemBackground.resolvedColor(with: window.traitCollection).setFill()
                    sheet.fill()
                    UIColor.separator.resolvedColor(with: window.traitCollection).setStroke()
                    sheet.stroke()
                }
                placed.append("\(type(of: window)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
                _ = window.drawHierarchy(in: frame, afterScreenUpdates: true)
            }
        }
        guard let png = image.pngData() else { return .error("not drawn", status: 500) }
        return ControlResponse(type: "image/png", body: png, headers: ["X-Floo-Windows": placed.joined(separator: "; ")])
    }

    /// Where `window` shows over `key`, in its points: a window of the scene where it is; a
    /// sheet's, whose place on screen UIKit doesn't tell (its conversions give 0,0), as the
    /// Mac puts it.
    private static func place(_ window: UIWindow, over key: UIWindow) -> CGRect {
        if window === key { return key.bounds }
        if key.windowScene?.windows.contains(where: { $0 === window }) == true { return window.convert(window.bounds, to: key) }
        let size = window.bounds.size
        return CGRect(x: (key.bounds.width - size.width) / 2, y: key.safeAreaInsets.top, width: size.width, height: size.height)
    }
}

/// One connection: a request read (its head, then Content-Length of body), answered on the
/// main actor, then closed.
private final class ControlConnection: @unchecked Sendable {
    static let queue = DispatchQueue(label: "floo.control")
    private static let largest = 1 << 20

    private let connection: NWConnection
    private var buffer = Data()

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.start(queue: Self.queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if let request = parsed() {
                Task { @MainActor in
                    let response = await FlooControl.handle(request)
                    self.reply(response)
                }
            } else if error != nil || complete || buffer.count > Self.largest {
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    /// The request once it's all in; nil while more is to come.
    private func parsed() -> ControlRequest? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return ControlRequest(method: "", path: "", body: Data()) }
        var length = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        let path = first[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return ControlRequest(method: String(first[0]), path: path, body: Data(body.prefix(length)))
    }

    private func reply(_ response: ControlResponse) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 409: "Conflict"][response.status] ?? "Error"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}
#endif
