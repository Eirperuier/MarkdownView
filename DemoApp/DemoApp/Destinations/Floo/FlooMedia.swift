//
//  FlooMedia.swift
//  DemoApp
//
//  The server's pictures as this device shows them (floo docs/content-cache.md §9.5, §10.1):
//  one cache for the signed-in account, a ContentStore in Application Support (memory, then
//  its encrypted disk, then the server by hash), and one view, CardUI's CardAsyncImage, that
//  draws the picture's ThumbHash first and decodes it at the size it's drawn. Cards' photos,
//  the feed's, agents' pictures and the conversation's all come through here. A picture is
//  named by its hash, which never changes; a link the server gives for it runs out, so links
//  are asked for when needed and never kept.
//
//  A cutout (`photo.variant("cutout")`) is made here, when a view draws one: from the
//  original, with Vision (CardUI's MediaCutout), kept in this cache as the original's
//  `cutout` and never uploaded. No subject, or no Vision: the original.
//

import CardUI
import ContentKit
import ContentStore
import Foundation
import LocalStore
import SwiftUI
import TransportKit
import Wire

@MainActor
enum FlooMedia {
    /// The signed-in account's cache.
    private static var opened: (account: AccountID, store: ContentStore)?
    /// Photos Vision found no subject in this launch: the original is their cutout.
    private static var noSubject: Set<ContentID> = []
    /// Cutouts being made, so a photo drawn twice at once is cut out once.
    private static var cutting: [ContentID: Task<Data?, Never>] = [:]

    static var store: ContentStore? { opened?.store }

    /// Opens `account`'s cache on its device store, its files in `directory`, fetching
    /// through `client`. The same account again keeps the one open.
    static func open(account: AccountID, local: LocalContent, directory: URL, client: FlooClient) {
        guard opened?.account != account else { return }
        noSubject = []
        // try?: a cache that won't open leaves pictures fetched each time, as before.
        opened = (try? ContentStore(local: local, directory: directory, fetcher: FlooContentFetcher(client: client)))
            .map { (account, $0) }
    }

    /// How a picture is reached when this device hasn't it: by hash from the server, which
    /// gives the account's own (its programs' photos, its agents' pictures, what its agents
    /// sent it); then, or only, through a link something else gives (a post's picture,
    /// which may be someone else's), read once and its bytes kept.
    struct Reach: Sendable {
        var byHash = true
        var link: (@Sendable () async throws -> MediaLink)?
    }

    /// The bytes of picture `id`: kept here, else fetched and kept. Nil when it can't be had
    /// now; its placeholder stays.
    nonisolated static func data(_ id: ContentID, size: Int64? = nil, as use: ContentUse, reach: Reach = Reach()) async -> Data? {
        let store = await store
        if let store {
            if reach.byHash, let bytes = try? await store.data(of: id, size: size, as: use) { return bytes }  // try?: not the account's, or not now
            if !reach.byHash, let bytes = try? await store.kept(id) { return bytes }  // try?: unread, fetched again
        }
        guard let link = reach.link, let read = try? await link() else { return nil }  // try?: the placeholder stays
        var bytes = read.content
        if bytes == nil, let url = read.url.flatMap(URL.init(string:)) {
            bytes = try? await URLSession.shared.data(from: url).0  // try?: the placeholder stays
        }
        guard let bytes else { return nil }
        // Kept by the hash of what came: these bytes, if they are the picture's.
        if let store { _ = try? await store.put(bytes, as: use, pin: nil) }  // try?: shown anyway, fetched next time
        return bytes
    }

    /// Photo `id`'s subject cut out on a transparent background, as a PNG: made here from
    /// the original once and kept as its `cutout`; the original where Vision finds no
    /// subject or can't run.
    nonisolated static func cutout(_ id: ContentID, size: Int64? = nil, as use: ContentUse, reach: Reach = Reach()) async -> Data? {
        if let kept = try? await store?.kept(id, variant: .cutout) { return kept }  // try?: unread, made again
        return await cut(id) { await data(id, size: size, as: use, reach: reach) } keep: { png in
            _ = try? await store?.put(png, as: .cutout, of: id, use: use)  // try?: shown anyway, made again next time
        }
    }

    private static func cut(
        _ id: ContentID,
        original: @escaping @Sendable () async -> Data?,
        keep: @escaping @Sendable (Data) async -> Void
    ) async -> Data? {
        if noSubject.contains(id) { return await original() }
        if let task = cutting[id] { return await task.value }
        let task = Task<Data?, Never> {
            guard let photo = await original() else { return nil }
            let png = await Task.detached(priority: .userInitiated) { MediaCutout.png(of: photo) }.value
            guard let png else {
                noSubject.insert(id)
                return photo
            }
            await keep(png)
            return png
        }
        cutting[id] = task
        let made = await task.value
        cutting[id] = nil
        return made
    }

    // MARK: Addresses

    /// A picture's name in CardUI's cache of decoded images: its hash, which never changes.
    static func address(_ id: ContentID, cutout: Bool = false) -> String {
        "media:\(id)" + (cutout ? "?variant=cutout" : "")
    }

    /// The ThumbHash a picture carries, for drawing before it comes.
    static func placeholder(_ media: MediaRef) -> [UInt8]? {
        media.thumbhash.map(Array.init)
    }
}

/// A picture of the server's in its frame: its ThumbHash, then the picture, filling the frame
/// (or fitting it), decoded at the size it's drawn.
struct FlooMediaImage: View {
    let media: MediaRef
    var use = ContentUse(.image, keep: .mine)
    var reach = FlooMedia.Reach()
    var contentMode: ContentMode = .fill

    var body: some View {
        let id = media.hash
        let size = media.size > 0 ? media.size : nil
        let use = use
        let reach = reach
        CardAsyncImage(url: FlooMedia.address(id), thumbhash: FlooMedia.placeholder(media), contentMode: contentMode) {
            await FlooMedia.data(id, size: size, as: use, reach: reach)
        }
    }
}
