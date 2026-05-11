import Foundation
import QuartzCore

public struct MarkdownRenderProbeSnapshot: Equatable, Sendable {
    public var tableInfoEnsureFreshCalls: Int = 0
    public var tableInfoEnsureFreshMs: Double = 0
    public var tableInfoCacheHits: Int = 0
    public var tableInfoCacheMisses: Int = 0

    public var markdownTableBodyCalls: Int = 0
    public var markdownTableContentBodyCalls: Int = 0
    public var markdownTableScrollableBuildCalls: Int = 0
    public var markdownTableBodyItemBuildCalls: Int = 0
    public var markdownTableActiveCells: Int = 0
    public var markdownTableBeforeCells: Int = 0
    public var markdownTablePastCells: Int = 0
    public var markdownTableFreshCells: Int = 0
    public var markdownTableRowBodyCalls: Int = 0
    public var adaptiveTableCellBodyCalls: Int = 0

    public var adaptiveTableLayoutSizeCalls: Int = 0
    public var adaptiveTableLayoutSizeMs: Double = 0
    public var adaptiveTableLayoutCacheHits: Int = 0
    public var adaptiveTableLayoutIdealMeasures: Int = 0
    public var adaptiveTableLayoutConstrainedMeasures: Int = 0

    public var markdownTextBodyCalls: Int = 0
    public var revealAnimatedTextBodyCalls: Int = 0
    public var fadeRevealTextBodyCalls: Int = 0
    public var fadeRevealRendererDrawCalls: Int = 0
    public var fadeRevealRendererGlyphVisits: Int = 0
    public var streamingMarkerBodyCalls: Int = 0

    public init() {}
}

private final class MarkdownRenderProbeStorage: @unchecked Sendable {
    let lock = NSLock()
    var enabled = false
    var snapshot = MarkdownRenderProbeSnapshot()

    func withLock<T>(_ body: (inout MarkdownRenderProbeSnapshot) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&snapshot)
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }
}

public enum MarkdownRenderProbe {
    private static let storage = MarkdownRenderProbeStorage()

    public static func setEnabled(_ enabled: Bool) {
        storage.setEnabled(enabled)
    }

    public static func reset() {
        storage.withLock { snapshot in
            snapshot = MarkdownRenderProbeSnapshot()
        }
    }

    public static func snapshot() -> MarkdownRenderProbeSnapshot {
        storage.withLock { $0 }
    }

    static func increment(_ keyPath: WritableKeyPath<MarkdownRenderProbeSnapshot, Int>, by value: Int = 1) {
        guard storage.enabled else { return }
        storage.withLock { snapshot in
            snapshot[keyPath: keyPath] += value
        }
    }

    static func recordTablePhaseCounts(active: Int, before: Int, past: Int, fresh: Int) {
        guard storage.enabled else { return }
        storage.withLock { snapshot in
            snapshot.markdownTableActiveCells = active
            snapshot.markdownTableBeforeCells = before
            snapshot.markdownTablePastCells = past
            snapshot.markdownTableFreshCells = fresh
        }
    }

    static func begin() -> Double {
        storage.enabled ? CACurrentMediaTime() : 0
    }

    static func finish(
        calls: WritableKeyPath<MarkdownRenderProbeSnapshot, Int>,
        ms: WritableKeyPath<MarkdownRenderProbeSnapshot, Double>,
        start: Double
    ) {
        guard storage.enabled else { return }
        storage.withLock { snapshot in
            snapshot[keyPath: calls] += 1
            snapshot[keyPath: ms] += (CACurrentMediaTime() - start) * 1000
        }
    }
}
