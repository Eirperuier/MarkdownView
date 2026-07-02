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
    var codeBlock: CodeBlock = CodeBlock()
    
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
        hasher.combine(table.columnWidthBuckets)
        hasher.combine(codeBlock.scrollable)
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

        /// Fixed width buckets used to stabilize scrollable table column widths.
        var columnWidthBuckets: [CGFloat] = [80, 120, 160, 220, 300]
    }

    /// Configuration for markdown code block rendering.
    struct CodeBlock: Equatable, Sendable {
        /// Whether code blocks should use a horizontal scroll view instead of wrapping.
        var scrollable: Bool = false
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
    private var completionEnd: Int?
    private var completionTimestamp: Date?

    func record(from oldValue: Int, to newValue: Int, completionEnd: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if newValue == Int.max {
            if oldValue != Int.max {
                completionFreshStart = max(0, oldValue)
                completionTimestamp = now
                // Upper bound = the block's content length at completion time.
                // Without it, indices that don't exist yet (text that streams
                // in AFTER this completion) would also resolve to
                // `completionTimestamp` — a stale stamp that kills their fade
                // once the reveal rewinds and re-advances over them.
                self.completionEnd = completionEnd
            }
            return
        }

        // Rewinding out of completion: chars revealed by the completion jump
        // never got per-index stamps. Backfill their nil entries with the
        // completion timestamp (when they actually appeared), not `now`.
        let completionFillStamp = oldValue == Int.max ? completionTimestamp : nil

        // 有限值回拉(coordinator remap:plainText 收缩,如段落→表格成型、公式闭合):
        // frontier 会重扫 [new, old) 这段。旧的 per-index 戳(早已过 settle)若留着,重扫经过的
        // 字符/表格 cell 会被判定"已定型"瞬间实心 —— 表头无 fade、表格数学 cell 无 reveal 的根因。
        // 与 RevealFadeRenderer 的 rewind 失效语义一致:重扫必须拿到新鲜戳、重新淡入。
        if oldValue != Int.max, newValue < oldValue {
            let hi = min(oldValue, firstSeenTimestamps.count)
            let lo = max(0, newValue)
            if lo < hi {
                for index in lo..<hi { firstSeenTimestamps[index] = nil }
            }
        }

        completionFreshStart = nil
        completionTimestamp = nil
        self.completionEnd = nil

        let start = oldValue == Int.max ? 0 : max(0, oldValue)
        guard newValue > start else { return }
        ensureCapacity(newValue)
        for index in start..<newValue where firstSeenTimestamps[index] == nil {
            firstSeenTimestamps[index] = completionFillStamp ?? now
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
           index >= start,
           completionEnd.map({ index < $0 }) ?? true {
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
            let completionEnd = pendingCompletionEnd
            pendingCompletionEnd = nil
            timestampStore.record(from: oldValue, to: revealedCount, completionEnd: completionEnd)
            notifyListeners()
            if (oldValue == Int.max) != isRevealed {
                notifyRevealCompletionListeners()
            }
        }
    }

    /// Marks the block fully revealed, bounding the completion timestamp to
    /// `contentLength`. Prefer this over assigning `revealedCount = Int.max`
    /// directly whenever the caller knows the block's plain-text length:
    /// text streaming in after this completion then gets a fresh first-seen
    /// stamp (and fades in) instead of inheriting the stale completion stamp.
    public func finishReveal(contentLength: Int) {
        guard revealedCount != Int.max else { return }
        pendingCompletionEnd = max(0, contentLength)
        revealedCount = Int.max
    }

    public var isRevealed: Bool {
        revealedCount == Int.max
    }

    public private(set) var adaptiveFadeDurationScale: Double = 1.0

    private var listeners: [UUID: (Int) -> Void] = [:]
    private var revealCompletionListeners: [UUID: (Bool) -> Void] = [:]
    private var pendingCompletionEnd: Int?
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

    @discardableResult
    public func addRevealCompletionListener(_ listener: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        revealCompletionListeners[id] = listener
        listener(isRevealed)
        return id
    }

    public func removeRevealCompletionListener(_ id: UUID) {
        revealCompletionListeners.removeValue(forKey: id)
    }

    public func setAdaptiveFadeDurationScale(_ scale: Double) {
        adaptiveFadeDurationScale = min(max(scale, 0.45), 1.0)
    }

    public func adaptiveFadeDuration(baseDuration: TimeInterval) -> TimeInterval {
        guard baseDuration > 0 else { return 0 }
        return baseDuration * adaptiveFadeDurationScale
    }

    public nonisolated func firstSeenTimestamp(at index: Int) -> Date? {
        timestampStore.firstSeenTimestamp(at: index)
    }

    private func notifyListeners() {
        // Snapshot before iteration: listener callbacks may self-unsubscribe
        // (e.g. table cell phase holders dropping their listener once they're
        // permanently `.past`), and mutating a Dictionary while iterating its
        // `.values` is undefined behavior — observed as some downstream cells
        // missing notifies and their phase staying stuck at `.before`
        // (opacity 0 → "missing" content).
        let snapshot = Array(listeners.values)
        for listener in snapshot {
            listener(revealedCount)
        }
    }

    private func notifyRevealCompletionListeners() {
        for listener in revealCompletionListeners.values {
            listener(isRevealed)
        }
    }
}

public struct MarkdownStreamingKey: EnvironmentKey {
    nonisolated(unsafe) public static let defaultValue: StreamingRevealManager? = nil
}

struct MarkdownStreamingRevealCountKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// The per-block streaming reveal manager, if this subtree is being
    /// revealed (set via ``markdownStreaming(_:)``). `nil` for loaded /
    /// non-streaming content. Read it to learn whether the surrounding
    /// markdown block is currently mid-stream — e.g. a custom code-block
    /// renderer that wants to mirror the host's reveal behavior.
    public var markdownStreaming: StreamingRevealManager? {
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
    public static let legacyHighlightStartHue: Double = 30.0 / 360.0
    public static let legacyHighlightEndHue: Double = 270.0 / 360.0
    public static let legacyHighlightHue: Double = legacyHighlightStartHue
    public static let colorDurationMultiplier: Double = 1.8

    public var duration: TimeInterval
    public var delay: TimeInterval
    public var highlightColor: Color?
    public var highlightStartHue: Double?
    public var highlightEndHue: Double?
    public var hueSaturation: Double
    public var hueBrightness: Double

    public init(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        highlightColor: Color = .accentColor
    ) {
        self.duration = duration
        self.delay = Self.nonnegativeTime(delay)
        self.highlightColor = highlightColor
        self.highlightStartHue = nil
        self.highlightEndHue = nil
        self.hueSaturation = 0.9
        self.hueBrightness = 0.95
    }

    /// Creates a static reveal highlight color from a SwiftUI-style hue in the `0...1` range.
    public init(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        hue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) {
        self.duration = duration
        self.delay = Self.nonnegativeTime(delay)
        self.highlightColor = Color(
            hue: Self.normalizedHue(hue),
            saturation: saturation,
            brightness: brightness
        )
        self.highlightStartHue = nil
        self.highlightEndHue = nil
        self.hueSaturation = saturation
        self.hueBrightness = brightness
    }

    /// Creates a reveal highlight trail between two SwiftUI-style hues in the `0...1` range.
    public init(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        startHue: Double,
        endHue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) {
        self.duration = duration
        self.delay = Self.nonnegativeTime(delay)
        self.highlightColor = nil
        self.highlightStartHue = Self.normalizedHue(startHue)
        self.highlightEndHue = Self.normalizedHue(endHue)
        self.hueSaturation = saturation
        self.hueBrightness = brightness
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        guard hue.isFinite else { return 0 }
        let normalized = hue.truncatingRemainder(dividingBy: 1)
        return normalized >= 0 ? normalized : normalized + 1
    }

    private static func nonnegativeTime(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }

    func colorSettleDuration(adaptiveDuration: TimeInterval? = nil) -> TimeInterval {
        let effectiveDuration = Self.nonnegativeTime(adaptiveDuration ?? duration)
        return delay + effectiveDuration * Self.colorDurationMultiplier
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
        delay: TimeInterval = 0,
        highlightColor: Color = .accentColor
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(duration: duration, delay: delay, highlightColor: highlightColor)
        )
    }

    /// Enable per-character fade-in animation with a caller-provided hue.
    /// The hue follows SwiftUI's `Color(hue:saturation:brightness:)` convention: `0...1`.
    nonisolated public func markdownFadeReveal(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        hue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(
                duration: duration,
                delay: delay,
                hue: hue,
                saturation: saturation,
                brightness: brightness
            )
        )
    }

    /// Enable per-character fade-in animation with a caller-provided hue range.
    /// The hues follow SwiftUI's `Color(hue:saturation:brightness:)` convention: `0...1`.
    nonisolated public func markdownFadeReveal(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        startHue: Double,
        endHue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(
                duration: duration,
                delay: delay,
                startHue: startHue,
                endHue: endHue,
                saturation: saturation,
                brightness: brightness
            )
        )
    }
}
