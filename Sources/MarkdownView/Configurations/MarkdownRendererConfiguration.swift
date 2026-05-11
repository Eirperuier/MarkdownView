//
//  MarkdownRendererConfiguration.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2024/12/11.
//

import Foundation
import SwiftUI

struct MarkdownRendererConfiguration: Equatable, AllowingModifyThroughKeyPath, Sendable {
    var preferredBaseURL: URL?
    var componentSpacing: CGFloat = 10
    
    var math: Math = Math()
    var table: Table = Table()
    
    var linkTintColor: Color = .blue
    var inlineCodeTintColor: Color = .gray
    var blockQuoteTintColor: Color = .accentColor
    var preferredColor: Color = .accentColor
    
    var showFullCode: Bool = false
    
    var listConfiguration: MarkdownListConfiguration = MarkdownListConfiguration()
    
    var allowedImageRenderers: Set<String> = ["https", "http"]
    var allowedBlockDirectiveRenderers: Set<String> = []

    var autolinkDetectionEnabled: Bool = true

    var highlightedStrings: [String] = []
    var highlightedColor: Color = .white
    var highlightedBackgroundColor: Color = .yellow

    /// Lightweight fingerprint for node-level cache keys.
    /// Captures the fields most likely to affect block-level rendering.
    var stableFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(preferredBaseURL)
        hasher.combine(componentSpacing)
        hasher.combine(showFullCode)
        hasher.combine(math)
        hasher.combine(table.scrollable)
        hasher.combine(table.cellMaxWidth)
        hasher.combine(listConfiguration)
        hasher.combine(allowedImageRenderers)
        hasher.combine(allowedBlockDirectiveRenderers)
        hasher.combine(autolinkDetectionEnabled)
        hasher.combine(highlightedStrings)
        hasher.combine(linkTintColor.description)
        hasher.combine(inlineCodeTintColor.description)
        hasher.combine(blockQuoteTintColor.description)
        hasher.combine(preferredColor.description)
        hasher.combine(highlightedColor.description)
        hasher.combine(highlightedBackgroundColor.description)
        return hasher.finalize()
    }
}

// MARK: - Table Configuration

extension MarkdownRendererConfiguration {
    /// Configuration for markdown table rendering.
    struct Table: Equatable, Sendable {
        /// Whether the table should be horizontally scrollable.
        var scrollable: Bool = false
        
        /// The maximum width for each table cell when scrollable is enabled.
        var cellMaxWidth: CGFloat = 300
    }
}

// MARK: - SwiftUI Environment

struct MarkdownRendererConfigurationKey: EnvironmentKey {
    static let defaultValue: MarkdownRendererConfiguration = .init()
}

extension EnvironmentValues {
    var markdownRendererConfiguration: MarkdownRendererConfiguration {
        get { self[MarkdownRendererConfigurationKey.self] }
        set { self[MarkdownRendererConfigurationKey.self] = newValue }
    }
}

// MARK: - Streaming Environment (kept separate to avoid cache invalidation)

private final class StreamingRevealTimestampStore: @unchecked Sendable {
    private let lock = NSLock()
    private var firstSeenTimestamps: [Date?] = []
    private var completionFreshStart: Int?
    private var completionTimestamp: Date?

    func record(from oldValue: Int, to newValue: Int) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if newValue == Int.max {
            if oldValue != Int.max {
                completionFreshStart = max(0, oldValue)
                completionTimestamp = now
            }
            return
        }

        completionFreshStart = nil
        completionTimestamp = nil

        let start = oldValue == Int.max ? 0 : max(0, oldValue)
        guard newValue > start else { return }
        ensureCapacity(newValue)
        for index in start..<newValue where firstSeenTimestamps[index] == nil {
            firstSeenTimestamps[index] = now
        }
    }

    func firstSeenTimestamp(at index: Int) -> Date? {
        lock.lock()
        defer { lock.unlock() }

        guard index >= 0 else { return nil }
        if index < firstSeenTimestamps.count, let timestamp = firstSeenTimestamps[index] {
            return timestamp
        }
        if let start = completionFreshStart,
           let timestamp = completionTimestamp,
           index >= start {
            return timestamp
        }
        return nil
    }

    private func ensureCapacity(_ count: Int) {
        guard count > firstSeenTimestamps.count else { return }
        firstSeenTimestamps.append(contentsOf: Array(repeating: nil, count: count - firstSeenTimestamps.count))
    }
}

/// Holds the character-by-character reveal count for streaming text.
/// Driven externally by `StreamingRevealCoordinator`.
/// When not injected into the environment (nil), `_MarkdownText` shows full text.
@MainActor
public final class StreamingRevealManager {
    public var revealedCount: Int = 0 {
        didSet {
            guard oldValue != revealedCount else { return }
            timestampStore.record(from: oldValue, to: revealedCount)
            notifyListeners()
        }
    }

    private var listeners: [UUID: (Int) -> Void] = [:]
    private nonisolated let timestampStore = StreamingRevealTimestampStore()

    public init() {}

    @discardableResult
    public func addListener(_ listener: @escaping (Int) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        listener(revealedCount)
        return id
    }

    public func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    public nonisolated func firstSeenTimestamp(at index: Int) -> Date? {
        timestampStore.firstSeenTimestamp(at: index)
    }

    private func notifyListeners() {
        for listener in listeners.values {
            listener(revealedCount)
        }
    }
}

struct MarkdownStreamingKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: StreamingRevealManager? = nil
}

struct MarkdownStreamingRevealCountKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var markdownStreaming: StreamingRevealManager? {
        get { self[MarkdownStreamingKey.self] }
        set { self[MarkdownStreamingKey.self] = newValue }
    }

    var markdownStreamingRevealCount: Int? {
        get { self[MarkdownStreamingRevealCountKey.self] }
        set { self[MarkdownStreamingRevealCountKey.self] = newValue }
    }
}

// MARK: - Block-relative text offset for nested reveal

/// Anchors a subtree's text into the parent block's plainText. Tables push
/// each cell's start offset here so `_MarkdownText` inside the cell can map
/// its local indices into the block's reveal frontier.
struct MarkdownTextOffsetBaseKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var markdownTextOffsetBase: Int {
        get { self[MarkdownTextOffsetBaseKey.self] }
        set { self[MarkdownTextOffsetBaseKey.self] = newValue }
    }
}

/// Tells `RevealFadeRenderer` to treat already-revealed glyphs on its very
/// first `draw` as freshly-revealed (stamp them as `now`, animate them in)
/// instead of as long-settled (`.distantPast`, snap-in static).
///
/// Set by table cells transitioning into `.active` phase, where the cell is
/// being mounted right as the frontier crosses its window — `revealedLocal`
/// can already be > 0 because the streaming coordinator advances multiple
/// chars per tick. Without this, the first 1–2 chars of every cell snap in.
///
/// Default `false` preserves the existing single-block behavior: a paragraph
/// re-mounting mid-stream (e.g. scrolled out and back) doesn't re-animate the
/// glyphs the user has already seen.
struct MarkdownStreamingFreshActivationKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var markdownStreamingFreshActivation: Bool {
        get { self[MarkdownStreamingFreshActivationKey.self] }
        set { self[MarkdownStreamingFreshActivationKey.self] = newValue }
    }
}

enum MarkdownTableRevealTextContext: Equatable, Sendable {
    case inherited
    case hidden
    case active(offsetBase: Int, freshActivation: Bool, minimumInterval: TimeInterval)
    case past
}

struct MarkdownTableRevealTextContextKey: EnvironmentKey {
    static let defaultValue: MarkdownTableRevealTextContext = .inherited
}

extension EnvironmentValues {
    var markdownTableRevealTextContext: MarkdownTableRevealTextContext {
        get { self[MarkdownTableRevealTextContextKey.self] }
        set { self[MarkdownTableRevealTextContextKey.self] = newValue }
    }
}

// MARK: - Fade Reveal Configuration

public struct MarkdownFadeRevealConfig: Equatable, Sendable {
    public static let legacyHighlightHue: Double = 30.0 / 360.0

    public var duration: TimeInterval
    public var highlightColor: Color

    public init(duration: TimeInterval = 0.4, highlightColor: Color = .accentColor) {
        self.duration = duration
        self.highlightColor = highlightColor
    }

    /// Creates a reveal highlight color from a SwiftUI-style hue in the `0...1` range.
    public init(
        duration: TimeInterval = 0.4,
        hue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) {
        self.duration = duration
        self.highlightColor = Color(
            hue: Self.normalizedHue(hue),
            saturation: saturation,
            brightness: brightness
        )
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        guard hue.isFinite else { return 0 }
        let normalized = hue.truncatingRemainder(dividingBy: 1)
        return normalized >= 0 ? normalized : normalized + 1
    }
}

struct MarkdownFadeRevealKey: EnvironmentKey {
    static let defaultValue: MarkdownFadeRevealConfig? = nil
}

extension EnvironmentValues {
    var markdownFadeReveal: MarkdownFadeRevealConfig? {
        get { self[MarkdownFadeRevealKey.self] }
        set { self[MarkdownFadeRevealKey.self] = newValue }
    }
}

extension View {
    /// Enable per-character fade-in animation during streaming reveal.
    /// Requires iOS 18+; on older OS this is a no-op.
    nonisolated public func markdownFadeReveal(
        duration: TimeInterval = 0.4,
        highlightColor: Color = .accentColor
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(duration: duration, highlightColor: highlightColor)
        )
    }

    /// Enable per-character fade-in animation with a caller-provided hue.
    /// The hue follows SwiftUI's `Color(hue:saturation:brightness:)` convention: `0...1`.
    nonisolated public func markdownFadeReveal(
        duration: TimeInterval = 0.4,
        hue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(
                duration: duration,
                hue: hue,
                saturation: saturation,
                brightness: brightness
            )
        )
    }
}
