//
//  DocStore.swift
//  DemoApp
//
//  The documents as they were left, so a relaunch finds them (Docs/doc.md §5.3, the
//  demo's): each document (the first page, a page, a record's page) is a snapshot of its
//  Doc, the checkpoint's shape (§5.2), in the app's Application Support (Docs/<id>.json),
//  written a moment after it changes and at once when the app goes to the background or
//  quits; the first page's id is beside them (Docs/root). There's no step log or server
//  here: the demo syncs with nothing. The edit tests and a -docFile document keep theirs
//  in memory only, the person's untouched. Undo histories aren't kept (as Craft's).
//
//  A document open in several windows is one document (Craft's): each window has its own
//  copy (its DocDemo, its undo history), and a change made in one goes to the others at
//  once. They're on the main thread together, so every copy is where the others are when
//  a change comes: its steps apply as they were, §5's server with nothing to rebase.
//

import UIKit
import DocKit

@MainActor
final class DocStore {
    static let shared = DocStore(folder: DocStore.keepsInMemory ? nil : DocStore.folder)

    /// Where the snapshots are; nil: in memory only.
    private let folder: URL?
    /// The documents read or written this run.
    private var known: [DocID: Doc] = [:]
    /// Documents with no snapshot (read once and not there).
    private var missing: Set<DocID> = []
    /// Documents changed and not yet written, the write waiting.
    private var dirty: [DocID: Doc] = [:]
    private var writing: Task<Void, Never>?
    /// The writes go one after another, off the main thread.
    private let queue = DispatchQueue(label: "DocStore.write", qos: .utility)

    private static let delay: Duration = .milliseconds(600)

    private init(folder: URL?) {
        self.folder = folder
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DocStore.shared.flush() }
            }
        }
    }

    /// The tests and a document handed in (-docFile) don't touch the person's documents.
    private static var keepsInMemory: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "docEditTest") || defaults.string(forKey: "docFile") != nil
    }

    private static var folder: URL? {
        URL.demoSupport.appendingPathComponent("Docs", isDirectory: true)
    }

    // MARK: Reading

    /// A document as it was left; nil if it never was.
    func load(_ id: DocID) -> Doc? {
        if let doc = dirty[id] ?? known[id] { return doc }
        guard let folder, !missing.contains(id) else { return nil }
        guard let data = try? Data(contentsOf: file(id, in: folder)), let doc = try? JSONDecoder().decode(Doc.self, from: data) else {
            missing.insert(id)
            return nil
        }
        known[id] = doc
        return doc
    }

    /// The first page's id, if one was kept.
    var root: DocID? {
        guard let folder, let text = try? String(contentsOf: folder.appendingPathComponent("root"), encoding: .utf8),
              let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return DocID(rawValue: uuid)
    }

    func setRoot(_ id: DocID) {
        guard let folder else { return }
        try? id.rawValue.uuidString.write(to: folder.appendingPathComponent("root"), atomically: true, encoding: .utf8)
    }

    // MARK: Writing

    /// Keeps a document as it is now, written a moment later (the last of several
    /// changes in that moment).
    func save(_ doc: Doc) {
        known[doc.id] = doc
        missing.remove(doc.id)
        guard folder != nil else { return }
        dirty[doc.id] = doc
        guard writing == nil else { return }
        writing = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            self?.flush()
        }
    }

    /// Writes what's waiting now.
    func flush() {
        writing?.cancel()
        writing = nil
        guard let folder, !dirty.isEmpty else { return }
        let docs = Array(dirty.values)
        dirty = [:]
        let files = docs.map { file($0.id, in: folder) }
        queue.async {
            for (doc, file) in zip(docs, files) {
                guard let data = try? JSONEncoder().encode(doc) else { continue }
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// A copy of a page, kept under `copy`: its blocks, tables and collections under new
    /// ids, the pages in it copied the same way (a duplicated page block opens a page of
    /// its own, Craft's). A page never written (none kept, not the corpus's) has nothing to
    /// copy: the copy opens new too.
    @discardableResult
    func copyPage(_ id: DocID, as copy: DocID = .generate()) -> DocID {
        copyPage(id, as: copy, inside: [])
    }

    private func copyPage(_ id: DocID, as copy: DocID, inside: Set<DocID>) -> DocID {
        guard !inside.contains(id), let doc = load(id) ?? DocDemoCorpus.page(id) else { return copy }
        var renamed: [DatabaseID: DatabaseID] = [:]
        var databases: [DatabaseID: Database] = [:]
        for (old, var database) in doc.databases {
            database.id = .generate()
            renamed[old] = database.id
            databases[database.id] = database
        }
        let blocks = doc.blocks.map { block in
            var block = block
            block.id = .generate()
            switch block.kind {
            case .page(var page):
                page.doc = copyPage(page.doc, as: .generate(), inside: inside.union([id]))
                block.kind = .page(page: page)
            case .database(let database, let view):
                block.kind = .database(id: renamed[database] ?? database, view: view)
            case .collection(var collection):
                collection.database = renamed[collection.database] ?? collection.database
                block.kind = .collection(collection: collection)
            default:
                break
            }
            return block
        }
        save(Doc(id: copy, blocks: blocks, databases: databases))
        return copy
    }

    /// Every document gone (Reset): the next launch starts from the corpus again.
    func removeAll() {
        writing?.cancel()
        writing = nil
        known = [:]
        missing = []
        dirty = [:]
        guard let folder else { return }
        queue.sync {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    // MARK: Windows

    private struct Copy {
        weak var demo: DocDemo?
    }

    /// The copies of each document open now.
    private var copies: [DocID: [Copy]] = [:]

    /// A document's copy, made for a window: it hears the others' changes from now on.
    func attach(_ demo: DocDemo) {
        copies[demo.doc.id, default: []].removeAll { $0.demo == nil }
        copies[demo.doc.id, default: []].append(Copy(demo: demo))
    }

    /// A change one copy made, applied to the others.
    func share(_ steps: [DocStep], from demo: DocDemo) {
        guard !steps.isEmpty else { return }
        for other in others(of: demo) { other.receive(steps) }
    }

    /// One copy started over (Reset): the others take what it has now.
    func share(reset demo: DocDemo) {
        for other in others(of: demo) { other.take(demo.doc) }
    }

    private func others(of demo: DocDemo) -> [DocDemo] {
        (copies[demo.doc.id] ?? []).compactMap(\.demo).filter { $0 !== demo }
    }

    private func file(_ id: DocID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(id.rawValue.uuidString).json")
    }
}
