//
//  DocDemoHost.swift
//  DemoApp
//
//  What the page's cards and views ask of the demo. `send(message:)` hands a view's words
//  to the agent, as a form's answer goes back to the conversation; the demo has no
//  conversation, so it keeps them (DocDemo.sentToAgent). Every other tool is refused.
//

import CardModel
import CardRuntime

struct DocDemoHost: CardHost {
    let send: @MainActor @Sendable (String) -> Void

    func call(_ tool: String, arguments: [String: CardValue]) async throws -> CardValue {
        guard tool == "send", case .string(let message)? = arguments["message"] else { throw Refused() }
        await send(message)
        return .object(["sent": .bool(true)])
    }

    private struct Refused: Error {}
}
