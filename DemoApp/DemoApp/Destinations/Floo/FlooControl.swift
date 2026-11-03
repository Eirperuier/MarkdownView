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
        let asked = demo.live?.asked(card.id) ?? (nil, nil)
        var out: [String: Any] = [
            "id": card.id,
            "status": "\(card.state)",
            "answered": card.state == .answered || card.items.allSatisfy { $0.answer != nil },
            "from": card.agent.name,
        ]
        if let item = card.items.first { out.merge(describe(item, asked)) { a, _ in a } }
        if card.items.count > 1 { out["items"] = card.items.map { describe($0, (nil, nil)) } }
        if card.closes != .one { out["closes"] = "\(card.closes)" }
        if let line = card.line { out["line"] = line }
        if let device = card.place?.components(separatedBy: " · ").first { out["device"] = device }
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

    private static func describe(_ item: FlooAskItem, _ asked: (options: [ConsentOption]?, fields: [SecretField]?)) -> [String: Any] {
        var out: [String: Any] = ["title": item.title]
        if item.question != item.title { out["question"] = item.question }
        if let answer = item.answer { out["answer"] = answer }
        switch item.form {
        case .step(let what, _, _):
            out["kind"] = "step"
            out["what"] = what
        case .decision(let go, let no, let standing, let dangerous):
            out["kind"] = "decision"
            out["dangerous"] = dangerous
            out["options"] =
                asked.options?.map { ["key": $0.key, "label": $0.label, "standing": $0.standing] as [String: Any] }
                ?? ([["key": go, "label": go, "standing": false], ["key": no, "label": no, "standing": false]]
                    + standing.map { ["key": $0, "label": $0, "standing": true] })
        case .secret(let fields, let ways, _, _, let keep):
            out["kind"] = "secret"
            out["fields"] =
                asked.fields?.map { ["key": $0.key, "label": $0.label, "kind": $0.kind.rawValue, "autofill": orNull($0.autofill)] as [String: Any] }
                ?? fields.map { ["key": $0.label, "label": $0.label, "kind": "\($0.kind)", "autofill": orNull($0.autofill)] as [String: Any] }
            if !ways.isEmpty { out["ways"] = ways }
            if let keep { out["keep"] = keep }
        case .view(_, let sha256, let width, let height, let scale, let keep):
            out["kind"] = "view"
            out["sha256"] = sha256
            out["width"] = width
            out["height"] = height
            out["scale"] = scale
            out["keep"] = keep.map { $0 as Any } ?? NSNull()
        case .choose(let options, let multiple, _):
            out["kind"] = "choose"
            out["multiple"] = multiple
            out["options"] = options.enumerated().map { ["key": "\($0.offset)", "label": $0.element.label, "standing": false] }
        case .confirm(let effect, _, _):
            out["kind"] = "confirm"
            out["effect"] = effect
        case .fill(let fields):
            out["kind"] = "fill"
            out["fields"] = fields.enumerated().map {
                ["key": "\($0.offset)", "label": $0.element.label, "kind": "\($0.element.kind)",
                 "autofill": orNull($0.element.autofill), "guess": $0.element.guess] as [String: Any]
            }
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

    /// As the card's buttons answer (`FlooDemo.answerAsk`): live, that's FlooLive's
    /// decide / submit / decline / step / answer, signed and sealed as ever.
    private static func answer(_ demo: FlooDemo, _ body: [String: Any]) -> ControlResponse {
        guard let id = body["ask"] as? String else { return .error("ask is required") }
        guard let card = demo.shownEntries.lazy.compactMap({ entry -> FlooAskCard? in
            if case .message(let message) = entry { message.asks.first { $0.id == id } } else { nil }
        }).first else { return .error("no such ask shown", status: 404) }
        let index = body["item"] as? Int ?? 0
        guard card.items.indices.contains(index) else { return .error("no such item") }
        let item = card.items[index]
        guard card.state == .open, item.answer == nil else { return .error("not open: \(card.state)", status: 409) }
        let decline = body["decline"] as? Bool == true
        let pick: FlooAnswerPick
        switch item.form {
        case .decision(let go, let no, let standing, _):
            if decline {
                pick = .decide(go: false, standing: nil)
                break
            }
            guard let choice = body["choice"] as? String else { return .error("choice is required") }
            // A key names its label; the card's buttons go by labels.
            let label = demo.live?.asked(id).options?.first { $0.key == choice }?.label ?? choice
            if label == no {
                pick = .decide(go: false, standing: nil)
            } else if label == go {
                pick = .decide(go: true, standing: nil)
            } else if standing.contains(label) {
                pick = .decide(go: true, standing: label)
            } else {
                return .error("no such choice")
            }
        case .secret(let fields, _, _, _, _):
            if decline {
                pick = .step(.skip)
                break
            }
            guard let values = body["values"] as? [String: String] else { return .error("values is required") }
            let keys = demo.live?.asked(id).fields?.map(\.key) ?? fields.map(\.label)
            var ordered: [String] = []
            for (place, key) in keys.enumerated() {
                guard let value = values[key] ?? values[fields[place].label] else { return .error("missing value for \(key)") }
                ordered.append(value)
            }
            pick = .secrets(way: body["way"] as? Int ?? 0, ordered, keep: body["keep"] as? Bool)
        case .view:
            // Cancelled, or its keep turned: nothing else is the person's to say on a view.
            if body["cancel"] as? Bool == true || decline {
                pick = .step(.skip)
            } else if let on = body["keep"] as? Bool {
                pick = .keep(on)
            } else {
                return .error("cancel: true, or keep: true or false")
            }
        case .step:
            switch body["step"] as? String {
            case "engaged": pick = .step(.open)
            case "completed": pick = .step(.done)
            case "skipped": pick = .step(.skip)
            default: return .error("step is engaged, completed or skipped")
            }
        case .choose(let options, let multiple, let own):
            let picked = (body["picked"] as? [Int]) ?? (body["picked"] as? Int).map { [$0] }
            if body["own"] as? Bool == true, own != nil {
                pick = .own
            } else if let picked, !picked.isEmpty, picked.allSatisfy(options.indices.contains) {
                pick = card.closes == .vote ? .vote(picked) : multiple ? .options(picked) : .option(picked[0])
            } else {
                return .error("picked: option indexes")
            }
        case .confirm:
            guard let yes = body["confirmed"] as? Bool else { return .error("confirmed is required") }
            pick = .confirm(yes)
        case .fill(let fields):
            if let filled = body["filled"] as? [String] {
                guard filled.count == fields.count else { return .error("filled: one per field") }
                pick = .filled(filled)
            } else if body["filled"] as? Bool == true {
                pick = .fill
            } else {
                return .error("filled: values in order, or true for the guesses")
            }
        }
        demo.answerAsk(id, item: index, pick)
        return .json(["ok": true])
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
