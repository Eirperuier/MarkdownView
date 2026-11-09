//
//  DocInsertSources.swift
//  DemoApp
//
//  Where images and files come from to go into a document (Craft's insert menu's File,
//  Scan, Gallery and Camera; on a Mac, files and image files): each a source the command menu lists while it can be used
//  here, which shows its picker and gives what was picked. What it gives is a file for
//  the store to keep (DocBlobs), or content a store already keeps (floo's /drive, picked
//  from the server: nothing goes up again). Floo registers its own sources beside these.
//

import UIKit
import DocKit
import PhotosUI
import VisionKit
import UniformTypeIdentifiers

/// What a source gave.
enum DocPicked {
    /// A file of the source's (in a folder of its own, removed once kept), named as the
    /// person knows it.
    case file(URL, name: String, type: UTType)
    /// Content a store already keeps.
    case blob(DocBlob, name: String)
}

/// A place images and files come from.
@MainActor
protocol DocInsertSource {
    /// The command's id, and its menu row.
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    var glyph: DocBlockIcon.Glyph { get }
    var keywords: [String] { get }
    /// Whether it can be used on this device (a camera, a scanner).
    var isAvailable: Bool { get }
    /// Shows its picker over `presenter`; what was picked, in order (nothing: cancelled).
    func pick(over presenter: UIViewController) async -> [DocPicked]
}

/// The sources the command menu lists, in its order.
@MainActor
enum DocInsertSources {
    static var all: [any DocInsertSource] = [DocFileSource.files, DocScanSource(), DocFileSource.images, DocPhotosSource(), DocCameraSource()]

    static var available: [any DocInsertSource] { all.filter(\.isAvailable) }

    static func source(_ id: String) -> (any DocInsertSource)? { all.first { $0.id == id } }

    /// A folder for one pick's files.
    static func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

// MARK: Files

/// Files (the Files app; on a Mac, the open panel), copied: any, or images only (a Mac's
/// pictures are files; it has no photo picker of its own).
struct DocFileSource: DocInsertSource {
    let id: String
    let title: String
    let symbol: String
    let glyph: DocBlockIcon.Glyph
    let keywords: [String]
    let types: [UTType]
    let isAvailable: Bool

    static let files = DocFileSource(id: "insert-file", title: String(localized: "File"), symbol: "folder", glyph: .folder,
                                     keywords: ["file", "attachment", "upload", "wenjian"], types: [.item], isAvailable: true)

    static let images = DocFileSource(id: "insert-image", title: String(localized: "Image"), symbol: "photo", glyph: .image,
                                      keywords: ["image", "picture", "photo", "tupian"], types: [.image], isAvailable: DocDevice.isMac)

    func pick(over presenter: UIViewController) async -> [DocPicked] {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        let urls: [URL] = await DocPickerSession.run(picker, over: presenter) { session in
            let delegate = DocumentDelegate(session: session)
            picker.delegate = delegate
            return delegate
        }
        return urls.map { url in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
            return .file(url, name: url.lastPathComponent, type: type)
        }
    }

    private final class DocumentDelegate: NSObject, UIDocumentPickerDelegate {
        let session: DocPickerSession<URL>
        init(session: DocPickerSession<URL>) { self.session = session }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { session.finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { session.finish([]) }
    }
}

// MARK: Photos

/// The photo library's images, as they're kept there (a HEIC stays one).
struct DocPhotosSource: DocInsertSource {
    let id = "insert-photos"
    let title = String(localized: "Gallery")
    let symbol = "photo.on.rectangle"
    let glyph = DocBlockIcon.Glyph.photos
    let keywords = ["gallery", "photo", "image", "picture", "tupian", "zhaopian"]
    /// A phone's or a pad's; a Mac picks image files (DocFileSource.images).
    var isAvailable: Bool { !DocDevice.isMac }

    func pick(over presenter: UIViewController) async -> [DocPicked] {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        let results: [PHPickerResult] = await DocPickerSession.run(picker, over: presenter) { session in
            let delegate = PhotosDelegate(session: session)
            picker.delegate = delegate
            return delegate
        }
        let folder = DocInsertSources.folder()
        var picked: [DocPicked] = []
        for result in results {
            if let file = await Self.copy(result.itemProvider, into: folder) { picked.append(file) }
        }
        return picked
    }

    /// The image's file, copied out before the provider removes it.
    private static func copy(_ provider: NSItemProvider, into folder: URL) async -> DocPicked? {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }),
              let type = UTType(identifier)
        else { return nil }
        let suggested = provider.suggestedName ?? String(localized: "Image")
        let ext = (suggested as NSString).pathExtension.isEmpty ? type.preferredFilenameExtension.map { "." + $0 } ?? "" : ""
        let name = suggested + ext
        let target = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url, (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return continuation.resume(returning: nil) }
                continuation.resume(returning: .file(target, name: name, type: type))
            }
        }
    }

    private final class PhotosDelegate: NSObject, PHPickerViewControllerDelegate {
        let session: DocPickerSession<PHPickerResult>
        init(session: DocPickerSession<PHPickerResult>) { self.session = session }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { session.finish(results) }
    }
}

// MARK: Camera

/// A photo taken now (a phone's or a pad's camera).
struct DocCameraSource: DocInsertSource {
    let id = "insert-camera"
    let title = String(localized: "Camera")
    let symbol = "camera"
    let glyph = DocBlockIcon.Glyph.camera
    let keywords = ["camera", "photo", "take", "paizhao", "xiangji"]
    var isAvailable: Bool { !DocDevice.isMac && UIImagePickerController.isSourceTypeAvailable(.camera) }

    func pick(over presenter: UIViewController) async -> [DocPicked] {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        let images: [UIImage] = await DocPickerSession.run(picker, over: presenter) { session in
            let delegate = CameraDelegate(session: session)
            picker.delegate = delegate
            return delegate
        }
        return DocScanSource.files(images, named: String(localized: "Photo"))
    }

    private final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let session: DocPickerSession<UIImage>
        init(session: DocPickerSession<UIImage>) { self.session = session }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            session.finish((info[.originalImage] as? UIImage).map { [$0] } ?? [])
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { session.finish([]) }
    }
}

// MARK: Scan

/// A document scanned with the camera: its pages, each an image.
struct DocScanSource: DocInsertSource {
    let id = "insert-scan"
    let title = String(localized: "Scan")
    let symbol = "doc.viewfinder"
    let glyph = DocBlockIcon.Glyph.scan
    let keywords = ["scan", "document", "saomiao"]
    // Loads VisionKit to ask: once.
    private static let supported = !DocDevice.isMac && VNDocumentCameraViewController.isSupported
    var isAvailable: Bool { Self.supported }

    func pick(over presenter: UIViewController) async -> [DocPicked] {
        let camera = VNDocumentCameraViewController()
        let pages: [UIImage] = await DocPickerSession.run(camera, over: presenter) { session in
            let delegate = ScanDelegate(session: session)
            camera.delegate = delegate
            return delegate
        }
        return Self.files(pages, named: String(localized: "Scan"))
    }

    /// Images taken here, as JPEG files: "Scan.jpg", or "Scan 1.jpg", "Scan 2.jpg"….
    static func files(_ images: [UIImage], named name: String) -> [DocPicked] {
        let folder = DocInsertSources.folder()
        return images.enumerated().compactMap { index, image in
            let file = images.count == 1 ? "\(name).jpg" : "\(name) \(index + 1).jpg"
            let url = folder.appendingPathComponent(file)
            guard let data = image.jpegData(compressionQuality: 0.9), (try? data.write(to: url)) != nil else { return nil }
            return .file(url, name: file, type: .jpeg)
        }
    }

    @MainActor
    private final class ScanDelegate: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let session: DocPickerSession<UIImage>
        init(session: DocPickerSession<UIImage>) { self.session = session }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            session.finish((0..<scan.pageCount).map(scan.imageOfPage))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { session.finish([]) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) { session.finish([]) }
    }
}

// MARK: Presenting

enum DocDevice {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
}

/// A picker shown until it gives its result once: picked, cancelled, or swiped away
/// (a sheet's dismissal tells no delegate of the picker's).
@MainActor
final class DocPickerSession<Picked>: NSObject, UIAdaptivePresentationControllerDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var picked: [Picked] = []
    private weak var picker: UIViewController?

    /// Presents `picker`, its delegate made by `delegate` (kept until it finishes).
    static func run(_ picker: UIViewController, over presenter: UIViewController,
                    delegate: (DocPickerSession<Picked>) -> AnyObject) async -> [Picked] {
        let session = DocPickerSession<Picked>()
        session.picker = picker
        let kept = delegate(session)
        await withCheckedContinuation { continuation in
            session.continuation = continuation
            presenter.present(picker, animated: true)
            picker.presentationController?.delegate = session
        }
        withExtendedLifetime(kept) {}
        return session.picked
    }

    func finish(_ result: [Picked]) {
        guard let continuation else { return }
        self.continuation = nil
        picked = result
        if let picker, picker.presentingViewController != nil, !picker.isBeingDismissed { picker.dismiss(animated: true) }
        continuation.resume()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish([]) }
}

// MARK: Inserting

extension DocEditor {
    /// A source's picker over the page; what's picked is kept (DocBlobs) and goes in as
    /// images (what ImageIO reads) and files, in the order picked, the "/query" going in
    /// the same step: a line that was only the slash becomes the first, a line to write
    /// on following the last; else they follow the line, the caret staying in it. Nothing
    /// picked: only the "/query" goes.
    func insert(from sourceID: String, in block: DocBlock, replacing typed: Range<Int>, from head: DocPosition) {
        guard let source = DocInsertSources.source(sourceID), let presenter = presenter(near: block.id) else { return }
        let units = Array(block.text.string.utf16)
        let typedUnits = typed.upperBound <= units.count ? Array(units[typed]) : []
        inserting = Task { [weak self] in
            let picked = await source.pick(over: presenter)
            let kinds = await Self.keep(picked)
            self?.insert(kinds, in: block.id, replacing: typed, typed: typedUnits, from: head)
        }
    }

    /// The view controller a picker shows over: the top one of the block's window.
    private func presenter(near id: DocBlockID) -> UIViewController? {
        let window = textView(for: id)?.window
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    /// What was picked, kept by the store, as blocks (what couldn't be kept is left out),
    /// worked out away from the main thread.
    private static func keep(_ picked: [DocPicked]) async -> [BlockKind] {
        var kinds: [BlockKind] = []
        for item in picked {
            switch item {
            case .file(let url, let name, let type):
                defer { try? FileManager.default.removeItem(at: url) }
                guard let blob = try? await DocBlobs.store.put(url, type: type) else { continue }
                kinds.append(await Task.detached(priority: .userInitiated) { kind(of: blob, name: name) }.value)
            case .blob(let blob, let name):
                kinds.append(await Task.detached(priority: .userInitiated) { kind(of: blob, name: name) }.value)
            }
        }
        return kinds
    }

    /// An image if it is one ImageIO reads, with its size and blur (DocBlobImages.facts),
    /// named by its file's name; else a file. Content that isn't here yet goes by its type.
    private nonisolated static func kind(of blob: DocBlob, name: String) -> BlockKind {
        let alt = (name as NSString).deletingPathExtension
        guard let file = DocBlobs.store.local(blob.ref) else {
            return blob.type.conforms(to: .image) ? .image(image: DocImage(source: blob.ref.source, alt: alt))
                : .file(file: DocFile(source: blob.ref.source, name: name, size: blob.byteCount))
        }
        guard DocBlobImages.reads(file) else { return .file(file: DocFile(source: blob.ref.source, name: name, size: blob.byteCount)) }
        let facts = DocBlobImages.facts(file)
        return .image(image: DocImage(source: blob.ref.source, alt: alt, width: facts.map { Double($0.size.width) },
                                      height: facts.map { Double($0.size.height) }, blurHash: facts?.blurHash))
    }

    /// The picked blocks in, and the "/query" out if it's still what was typed.
    private func insert(_ kinds: [BlockKind], in id: DocBlockID, replacing typed: Range<Int>, typed typedUnits: [UInt16], from head: DocPosition) {
        guard let block = demo.doc.block(id) else { return }
        let units = Array(block.text.string.utf16)
        let stillTyped = !typed.isEmpty && typed.upperBound <= units.count && Array(units[typed]) == typedUnits
        let before = stillTyped ? DocSelection(anchor: head, head: head) : (selection ?? DocSelection(anchor: head, head: head))
        let here = stillTyped ? DocPosition(block: id, offset: typed.lowerBound) : before.head
        var steps: [DocStep] = stillTyped ? [.deleteText(block: id, range: typed, removed: DocText())] : []
        var caret = here
        if kinds.isEmpty {
            guard !steps.isEmpty else { return }
        } else if units.count == (stillTyped ? typed.count : 0) {
            // Only the slash was on the line (or nothing): it becomes the first.
            steps.append(.setBlock(block: id, kind: kinds[0], indent: block.indent, previousKind: block.kind, previousIndent: block.indent))
            var last = id
            for kind in kinds.dropFirst() {
                let next = demo.newBlockID()
                steps.append(.insertBlock(block: DocBlock(id: next, kind: kind, indent: block.indent), after: last))
                last = next
            }
            let line = demo.newBlockID()
            steps.append(.insertBlock(block: DocBlock(id: line, kind: .paragraph, indent: block.indent), after: last))
            caret = DocPosition(block: line, offset: 0)
        } else {
            var last = id
            for kind in kinds {
                let next = demo.newBlockID()
                steps.append(.insertBlock(block: DocBlock(id: next, kind: kind, indent: block.indent), after: last))
                last = next
            }
        }
        commitSlash(steps, from: before, to: DocSelection(anchor: caret, head: caret))
    }
}
