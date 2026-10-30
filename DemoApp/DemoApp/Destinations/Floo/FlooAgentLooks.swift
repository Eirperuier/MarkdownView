//
//  FlooAgentLooks.swift
//  DemoApp
//
//  What the person calls their agents and shows them by (floo docs/context-format.md §3.5):
//  an agent is its id, which never changes; its name and picture are the person's to change
//  whenever they like. Every page that names a service or its agent — the services' list and
//  pages, the chat, the feed — reads them here first, then the catalog's. Signed in, they are
//  the server's (`GET /v1/agents/looks`); scripted, the pages keep their own.
//

import Observation
import PhotosUI
import SwiftUI
import TransportKit
import UIKit
import Wire

@MainActor @Observable
final class FlooAgentLooks {
    static let shared = FlooAgentLooks()

    /// What the person calls each, by the agent's id: "butler", "service:weather".
    private(set) var names: [String: String] = [:]
    /// The person's picture for each, by the agent's id, as an address to read it from.
    private(set) var pictures: [String: URL] = [:]

    /// A service's agent's name as the person set it; nil, the catalog's.
    func name(of service: String) -> String? { names["service:\(service)"] }

    /// A service's agent's picture; nil, its service's icon.
    func picture(of service: String) -> URL? { pictures["service:\(service)"] }

    /// Reads them all again from the server.
    func read(_ client: FlooClient) async {
        guard let looks = try? await client.agentLooks() else { return }  // try?: the ones shown stand, read again next time
        var names: [String: String] = [:]
        var pictures: [String: URL] = [:]
        for look in looks.agents {
            let key = look.agent.description
            if let name = look.name { names[key] = name }
            if look.avatar != nil, let link = try? await client.agentAvatar(look.agent) {  // try?: its icon then
                pictures[key] = Self.address(link)
            }
        }
        self.names = names
        self.pictures = pictures
    }

    /// Renames `agent`; empty, its catalog name again. Scripted (no `client`), kept here.
    func rename(_ agent: AgentID, to name: String, catalogName: String, on client: FlooClient?) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client else {
            names[agent.description] = name.isEmpty || name == catalogName ? nil : name
            return
        }
        try await client.rename(agent, to: name)
        await read(client)
    }

    /// Shows `agent` by `image`, made a square JPEG of at most 512 points; nil, its icon again.
    func setPicture(_ image: UIImage?, of agent: AgentID, on client: FlooClient?) async throws {
        guard let image else {
            if let client { try await client.removeAvatar(of: agent) }
            pictures[agent.description] = nil
            return
        }
        guard let data = Self.square(image, side: 512).jpegData(compressionQuality: 0.85) else { return }
        guard let client else {
            pictures[agent.description] = URL(string: "data:image/jpeg;base64,\(data.base64EncodedString())")
            return
        }
        let media = try await client.upload(data, type: "image/jpeg")
        try await client.setAvatar(media.hash, of: agent)
        await read(client)
    }

    /// Where to read a picture from: its link, or its bytes as they came.
    private static func address(_ link: MediaLink) -> URL? {
        if let content = link.content { return URL(string: "data:\(link.media.type);base64,\(content.base64EncodedString())") }
        return link.url.flatMap(URL.init(string:))
    }

    /// The middle square of `image`, at most `side` across.
    private static func square(_ image: UIImage, side: CGFloat) -> UIImage {
        let shortest = min(image.size.width, image.size.height)
        let size = min(shortest, side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            let scale = size / shortest
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size - drawn.width) / 2, y: (size - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }
}

/// One photo from the library, as UIKit's picker gives it: `PhotosPicker` lives in the
/// `_PhotosUI_SwiftUI` cross-import overlay, which a Mac Catalyst build doesn't always load.
struct FlooPhotoPicker: UIViewControllerRepresentable {
    /// The photo chosen; nil, cancelled or unreadable.
    let chosen: @MainActor (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(chosen: chosen) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let chosen: @MainActor (UIImage?) -> Void

        init(chosen: @escaping @MainActor (UIImage?) -> Void) { self.chosen = chosen }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                Task { @MainActor in chosen(nil) }
                return
            }
            let chosen = chosen
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                Task { @MainActor in chosen(image) }
            }
        }
    }
}
