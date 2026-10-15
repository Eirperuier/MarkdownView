//
//  DocBlobs.swift
//  DemoApp
//
//  Where a document's images and files are kept (Docs/doc.md §3.4.1). A block holds a
//  ref to its content, `blob:sha256:<64 hex>`: the content's hash, floo's BlobRef's
//  (floo's docs/files.md §6), so the same content is kept once and a ref never changes
//  what it means. Who keeps the content is a store (`DocBlobStore`): the demo's keeps it
//  on this device; floo's server (its /drive, content-addressed the same way) is another
//  store, and the blocks it's given stay as they are.
//

import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// A ref to content kept by its hash.
struct DocBlobRef: Hashable, Sendable {
    /// The SHA-256 digest, 64 lowercase hex digits.
    let hex: String

    /// The ref as a block's source holds it.
    var source: String { "blob:sha256:\(hex)" }

    init?(source: String) {
        let prefix = "blob:sha256:"
        guard source.hasPrefix(prefix) else { return nil }
        let hex = String(source.dropFirst(prefix.count))
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.hex = hex
    }

    init(digest: SHA256.Digest) {
        hex = digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Content kept: its ref, how big it is, what it is.
struct DocBlob: Hashable, Sendable {
    let ref: DocBlobRef
    let byteCount: Int
    let type: UTType
}

/// Who keeps the content blocks refer to.
protocol DocBlobStore: Sendable {
    /// Keeps a file's content (copied: the file may go once this returns), by its hash.
    func put(_ file: URL, type: UTType) async throws -> DocBlob
    /// The content as a file here, fetched first if it's kept elsewhere.
    func file(for ref: DocBlobRef) async throws -> URL
    /// The content as a file here if it already is (no fetching): what a page can show at
    /// once, or nil.
    func local(_ ref: DocBlobRef) -> URL?
}

enum DocBlobError: Error {
    case missing(DocBlobRef)
}

/// The demo's store: each content a file named by its hash in a folder of this device.
final class DocLocalBlobStore: DocBlobStore {
    let folder: URL

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func put(_ file: URL, type: UTType) async throws -> DocBlob {
        let (digest, byteCount) = try Self.hash(file)
        let ref = DocBlobRef(digest: digest)
        let kept = folder.appendingPathComponent(ref.hex)
        if !FileManager.default.fileExists(atPath: kept.path) {
            // Copied beside it, then moved in: a ref's file is whole or isn't there.
            let partial = folder.appendingPathComponent(ref.hex + ".partial-" + UUID().uuidString)
            try FileManager.default.copyItem(at: file, to: partial)
            do {
                try FileManager.default.moveItem(at: partial, to: kept)
            } catch where FileManager.default.fileExists(atPath: kept.path) {
                // Kept meanwhile by another put of the same content.
                try? FileManager.default.removeItem(at: partial)
            }
        }
        return DocBlob(ref: ref, byteCount: byteCount, type: type)
    }

    func file(for ref: DocBlobRef) async throws -> URL {
        guard let file = local(ref) else { throw DocBlobError.missing(ref) }
        return file
    }

    func local(_ ref: DocBlobRef) -> URL? {
        let file = folder.appendingPathComponent(ref.hex)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The content's digest, read a piece at a time (a video needn't fit in memory).
    private static func hash(_ file: URL) throws -> (SHA256.Digest, Int) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            count += chunk.count
        }
        return (hasher.finalize(), count)
    }
}

/// The app's store.
enum DocBlobs {
    /// This device's, in the app's Application Support (Blobs/); the edit tests and a
    /// -docFile document keep theirs in a folder of their own, the person's untouched.
    /// Floo sets its server's here.
    nonisolated(unsafe) static var store: any DocBlobStore = DocLocalBlobStore(folder: DocBlobs.folder)

    private static var folder: URL {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "docEditTest") || defaults.string(forKey: "docFile") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("DocBlobs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Blobs", isDirectory: true)
    }

    /// The content as a file named as the person knows it (`name`, its type's extension
    /// if it has none), for the system to open: the kept file has only its hash.
    static func openable(_ ref: DocBlobRef, name: String, type: UTType?) async throws -> URL {
        let kept = try await store.file(for: ref)
        var name = name.isEmpty ? String(localized: "Untitled") : name
        if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension { name += "." + ext }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Open-\(ref.hex)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        if !FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.linkItem(at: kept, to: file) } catch { try FileManager.default.copyItem(at: kept, to: file) }
        }
        return file
    }
}
