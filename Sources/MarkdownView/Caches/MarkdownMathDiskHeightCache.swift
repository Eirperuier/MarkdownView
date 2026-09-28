//
//  MarkdownMathDiskHeightCache.swift
//  MarkdownView
//
//  Moved from ios-flowith (SharedServices/LaTeXHeightCache.swift); the caller now
//  chooses the file instead of a shared instance under Application Support/flowith.
//
//  Disk-backed map of LaTeX source → previously-measured rendered height.
//  Consumed by `MarkdownDisplayMath` via `markdownMathHeightCache(_:)` to
//  eliminate the empty-placeholder → MathJax-SVG height jump on any
//  formula that has been seen at least once.
//
//  Concurrency model: the in-memory map is isolated to the main actor.
//  All reads/writes from SwiftUI views (which are themselves main-actor
//  isolated) hit it synchronously. Persistence is off-loaded to a
//  detached Task at .utility QoS, taking a Sendable snapshot of the dict
//  so the disk write never blocks the UI.
//

import CoreGraphics
import CryptoKit
import Foundation

public final class MarkdownMathDiskHeightCache: MarkdownMathHeightCache, @unchecked Sendable {
    /// `let` is fine on a nonisolated context (immutable after init).
    private nonisolated let storeURL: URL

    @MainActor private var memory: [String: CGFloat]
    @MainActor private var saveInFlight = false

    private static let saveDebounceSeconds: TimeInterval = 1.0
    /// Bounds the persisted file size. Each entry is ~80 bytes on disk,
    /// so 10k entries caps the file at well under 1 MB. Misses degrade
    /// gracefully (back to the estimate), so eviction order isn't
    /// quality-critical.
    private static let maxEntries = 10_000

    /// Loads `fileURL` synchronously; writes it back, debounced, as heights change.
    @MainActor
    public init(fileURL: URL) {
        storeURL = fileURL
        memory = Self.loadFromDisk(fileURL)
    }

    // MARK: - MarkdownMathHeightCache

    /// Protocol surface is `nonisolated` and synchronous; SwiftUI bodies
    /// (already on the main actor) call this without an `await`. The
    /// runtime check below traps if a caller ever drifts off-main, which
    /// would indicate a programming error elsewhere.
    public nonisolated func height(forLatex latex: String) -> CGFloat? {
        let k = Self.key(for: latex)
        return MainActor.assumeIsolated {
            memory[k]
        }
    }

    public nonisolated func setHeight(_ height: CGFloat, forLatex latex: String) {
        guard height.isFinite, height > 0 else { return }
        // Quantize so subpixel jitter (dynamic type rounding, layout
        // passes) doesn't churn the cache file.
        let quantized = (height * 2).rounded() / 2
        let k = Self.key(for: latex)
        MainActor.assumeIsolated {
            // Only-grow: callers (`MarkdownDisplayMath`) live behind
            // `MarkdownNodeView`'s `AnyView` wrap, which resets their
            // `@State` on every render, so they have no way of knowing
            // about a prior peak. Without enforcing monotonicity here,
            // a fresh-render's tiny placeholder height (e.g. the 14pt
            // pre-MathJax stub) overwrites a previously-captured 102pt
            // peak, and the next render of the same LaTeX bumps again.
            if let existing = memory[k], existing >= quantized { return }
            memory[k] = quantized
            scheduleSave()
        }
    }

    // MARK: - Persistence

    @MainActor
    private func scheduleSave() {
        guard !saveInFlight else { return }
        saveInFlight = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.saveDebounceSeconds))
            await self?.persistSnapshot()
        }
    }

    @MainActor
    private func persistSnapshot() async {
        saveInFlight = false
        trimIfNeeded()
        let snapshot = memory
        let url = storeURL
        await Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Cache is an optimization; a failed write just means the
                // next launch starts cold for these entries.
            }
        }.value
    }

    @MainActor
    private func trimIfNeeded() {
        guard memory.count > Self.maxEntries else { return }
        let overflow = memory.count - Self.maxEntries
        for key in Array(memory.keys.prefix(overflow)) {
            memory.removeValue(forKey: key)
        }
    }

    private static func loadFromDisk(_ url: URL) -> [String: CGFloat] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: CGFloat].self, from: data)) ?? [:]
    }

    // MARK: - Key

    private static func key(for latex: String) -> String {
        let digest = SHA256.hash(data: Data(latex.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
