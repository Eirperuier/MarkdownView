//
//  FlooChatHost.swift
//  DemoApp
//
//  What the conversation's cards and mention rows ask of this device: a picture a card
//  names by its floo link (`AsyncImage(url: "floo://photos/…")`) comes from this device's
//  own service that has it, never uploaded (floo's docs/services.md §2.10); a server's
//  photo (`media:<hash>`) as a mini program's page fetches it (FlooProgramHost).
//

import Foundation
import CardModel
import CardRuntime

struct FlooChatHost: CardHost {
    /// The server's photos, signed in; nil on a stage.
    var media: FlooProgramHost?

    /// How large a picture is asked for: the host isn't told the size it's drawn at, and
    /// CardUI's MediaCache decodes it down to that and keeps it, so it's asked once.
    static let longest = 1024

    /// Tools aren't run from the conversation's cards: their intents run on the server.
    func call(_ tool: String, arguments: [String: CardValue]) async throws -> CardValue {
        throw FlooProgramHost.NotHere()
    }

    func image(_ url: String) async -> Data? {
        if url.hasPrefix("floo://") {
#if targetEnvironment(macCatalyst)
            return await FlooHelper.picture(at: url, longest: Self.longest)
#else
            // The iPhone demo runs no services of its own yet: a floo link's picture isn't here.
            return nil
#endif
        }
        return await media?.image(url)
    }
}
