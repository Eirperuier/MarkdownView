//
//  MarkdownImageLoader.swift
//  MarkdownUIKit
//
//  Fetches and decodes off the main thread; what's done is kept by URL, for the life of the app
//  as MarkdownView's CacheStorage does, so a row coming back knows its height at once. One fetch
//  a URL however many rows ask. SVG goes first, then a bitmap, as NetworkImage tries them.
//

import MarkdownCore
import SwiftDrawCore
import UIKit

/// A picture ready to show.
struct MarkdownLoadedImage: @unchecked Sendable {
    let image: UIImage
    /// Its own size in points, whatever was decoded.
    let size: CGSize
    /// Never wider than this.
    let maxWidth: CGFloat
}

@MainActor
final class MarkdownImageLoader {
    static let shared = MarkdownImageLoader()

    enum State {
        case loaded(MarkdownLoadedImage)
        case failed
    }

    private var known: [URL: State] = [:]
    private var waiting: [URL: [@MainActor (State) -> Void]] = [:]

    /// What's known now: a height is asked for synchronously.
    func state(of url: URL) -> State? { known[url] }

    func load(_ url: URL, done: @escaping @MainActor (State) -> Void) {
        if let state = known[url] { return done(state) }
        guard waiting[url] == nil else {
            waiting[url]?.append(done)
            return
        }
        waiting[url] = [done]
        let scale = markdownPixelScale
        let longSide = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        Task.detached(priority: .userInitiated) {
            let loaded: MarkdownLoadedImage?
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                loaded = Self.decode(data, scale: scale, longSide: longSide)
            } else {
                loaded = nil
            }
            await MainActor.run { self.finish(url, loaded) }
        }
    }

    /// A failure is remembered, or each chunk of a stream would fetch again; a tap asks anew.
    func retry(_ url: URL, done: @escaping @MainActor (State) -> Void) {
        known[url] = nil
        load(url, done: done)
    }

    private func finish(_ url: URL, _ loaded: MarkdownLoadedImage?) {
        let state: State = loaded.map { .loaded($0) } ?? .failed
        known[url] = state
        let waiters = waiting.removeValue(forKey: url) ?? []
        waiters.forEach { $0(state) }
    }

    private nonisolated static func decode(_ data: Data, scale: CGFloat, longSide: CGFloat) -> MarkdownLoadedImage? {
        if let text = String(data: data, encoding: .utf8), MarkdownSVGSource.isSVG(text) {
            return svg(data, text: text, scale: scale, longSide: longSide)
        }
        guard let image = UIImage(data: data) else { return nil }
        // A picture isn't drawn wider than its longer side.
        let decoded = downsampled(data, image: image, scale: scale, longSide: longSide) ?? image.preparingForDisplay() ?? image
        return MarkdownLoadedImage(image: decoded, size: image.size, maxWidth: max(image.size.width, image.size.height))
    }

    /// A picture bigger than the screen can show is kept at what it can.
    private nonisolated static func downsampled(_ data: Data, image: UIImage, scale: CGFloat, longSide: CGFloat) -> UIImage? {
        let limit = longSide * scale
        guard max(image.size.width, image.size.height) * image.scale > limit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: limit,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    /// Drawn once, at the size it will show: with a width of its own that's its width; with none
    /// it fills the room, up to the screen's long side.
    private nonisolated static func svg(_ data: Data, text: String, scale: CGFloat, longSide: CGFloat) -> MarkdownLoadedImage? {
        guard let svg = SVG(data: data), svg.size.width > 0, svg.size.height > 0 else { return nil }
        let hasWidth = MarkdownSVGSource.hasWidth(text)
        let width = hasWidth ? min(svg.size.width, longSide) : longSide
        let drawn = svg.sized(CGSize(width: width, height: width * svg.size.height / svg.size.width))
        return MarkdownLoadedImage(
            image: drawn.rasterize(scale: scale),
            size: svg.size,
            maxWidth: hasWidth ? svg.size.width : .greatestFiniteMagnitude
        )
    }
}
