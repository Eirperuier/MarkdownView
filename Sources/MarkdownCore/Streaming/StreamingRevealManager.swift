//
//  StreamingRevealManager.swift
//  MarkdownView
//

import Foundation

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
