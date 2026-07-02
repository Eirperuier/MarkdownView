import SwiftUI
import Markdown
import Combine

private let markdownTableScrollableColumnSpacing: CGFloat = 20
private let markdownTableScrollableStripeOpacity: Double = 0.08
private let markdownTableScrollableStripeHorizontalBleed: CGFloat = 4
private let markdownTableScrollableStripeCornerRadius: CGFloat = 6

/// Where a table cell sits relative to the global reveal frontier.
/// Computed once at the table level and threaded into each cell so the cell
/// itself never has to observe `markdownStreaming`.
///   - `.before`: frontier hasn't reached the cell yet → render invisibly.
///   - `.active`: frontier is in the cell's window → run the fade animation.
///   - `.past`: frontier moved past → render plain Text, no animation work.
enum MarkdownTableCellPhase: Equatable, Sendable {
    case before
    case active
    case past
}

struct MarkdownTableCellKey: Hashable, Sendable {
    var row: Int
    var column: Int
}

struct MarkdownTableFreshCellKey: Hashable, Sendable {
    var cellKey: MarkdownTableCellKey
    var contentHash: Int
}

/// Per-table cache for everything that depends only on the AST shape, not on
/// the streaming frontier. `cellInfoByRow` and `cellHashesByRow` are O(N ×
/// content) to compute (each cell does a recursive `plainText` walk and a
/// recursive `stableContentHash`), and during streaming the table view is
/// re-evaluated 30×/sec because of `revealedCount` changes — without caching,
/// every tick re-walked the whole AST.
///
/// Held by `MarkdownTable` via `@State` so it survives across the inner
/// content view's per-tick re-evaluations. `ensureFresh` is idempotent and
/// only re-walks the AST when `table.stableContentHash` actually changed
/// (i.e. when a new chunk landed and produced a different AST).
final class TableInfoCache {
    private(set) var infoByRow: [[CellInfo]] = []
    private(set) var hashesByRow: [[Int]] = []
    private(set) var flatCellInfos: [MarkdownTableFlatCellInfo] = []
    fileprivate var headerItems: [AdaptiveTableCellItem] = []
    fileprivate var bodyItems: [AdaptiveTableCellItem] = []
    private(set) var freshCellKeys: Set<MarkdownTableFreshCellKey> = []
    private(set) var revision: Int = 0
    private var cachedHash: Int? = nil

    func ensureFresh(for table: Markdown.Table) {
        let probeStart = MarkdownRenderProbe.begin()
        defer {
            MarkdownRenderProbe.finish(
                calls: \.tableInfoEnsureFreshCalls,
                ms: \.tableInfoEnsureFreshMs,
                start: probeStart
            )
        }

        let hash = table.stableContentHash
        if cachedHash == hash {
            MarkdownRenderProbe.increment(\.tableInfoCacheHits)
            return
        }
        MarkdownRenderProbe.increment(\.tableInfoCacheMisses)

        let previousHashesByRow = hashesByRow
        var infos: [[CellInfo]] = []
        var hashes: [[Int]] = []
        var flatInfos: [MarkdownTableFlatCellInfo] = []
        var headerItems: [AdaptiveTableCellItem] = []
        var bodyItems: [AdaptiveTableCellItem] = []
        var freshKeys: Set<MarkdownTableFreshCellKey> = []
        var cursor = 0
        var flatIndex = 0

        var headerInfos: [CellInfo] = []
        var headerHashes: [Int] = []
        headerInfos.reserveCapacity(table.head.childCount)
        headerHashes.reserveCapacity(table.head.childCount)
        headerItems.reserveCapacity(table.head.childCount)
        let columnCount = table.head.childCount
        for (column, cell) in table.head.cells.enumerated() {
            let count = cell.markdownRevealPlainText.count
            let cellHash = cell.stableContentHash
            headerInfos.append(CellInfo(offset: cursor, count: count))
            headerHashes.append(cellHash)
            flatInfos.append(
                MarkdownTableFlatCellInfo(
                    key: MarkdownTableCellKey(row: 0, column: column),
                    flatIndex: flatIndex,
                    offset: cursor,
                    count: count,
                    contentHash: cellHash
                )
            )
            headerItems.append(
                AdaptiveTableCellItem(
                    row: 0,
                    column: column,
                    flatIndex: flatIndex,
                    cell: cell,
                    isHeader: true,
                    blockTextOffset: cursor,
                    phase: .past,
                    contentHash: cellHash
                )
            )
            insertFreshCellKeyIfNeeded(
                into: &freshKeys,
                previousHashesByRow: previousHashesByRow,
                row: 0,
                column: column,
                contentHash: cellHash
            )
            cursor += count
            flatIndex += 1
        }
        infos.append(headerInfos)
        hashes.append(headerHashes)

        for (bodyRowIndex, child) in table.body.children.enumerated() {
            guard let bodyRow = child as? Markdown.Table.Row else { continue }
            let row = bodyRowIndex + 1
            var rowInfos: [CellInfo] = []
            var rowHashes: [Int] = []
            for (column, cell) in bodyRow.cells.enumerated() {
                let count = cell.markdownRevealPlainText.count
                let cellHash = cell.stableContentHash
                rowInfos.append(CellInfo(offset: cursor, count: count))
                rowHashes.append(cellHash)
                flatInfos.append(
                    MarkdownTableFlatCellInfo(
                        key: MarkdownTableCellKey(row: row, column: column),
                        flatIndex: flatIndex,
                        offset: cursor,
                        count: count,
                        contentHash: cellHash
                    )
                )
                bodyItems.append(
                    AdaptiveTableCellItem(
                        row: row,
                        column: column,
                        flatIndex: flatIndex,
                        cell: cell,
                        isHeader: false,
                        blockTextOffset: cursor,
                        phase: .past,
                        contentHash: cellHash
                    )
                )
                insertFreshCellKeyIfNeeded(
                    into: &freshKeys,
                    previousHashesByRow: previousHashesByRow,
                    row: row,
                    column: column,
                    contentHash: cellHash
                )
                cursor += count
                flatIndex += 1
            }
            infos.append(rowInfos)
            hashes.append(rowHashes)
        }

        infoByRow = infos
        hashesByRow = hashes
        flatCellInfos = flatInfos
        self.headerItems = headerItems
        self.bodyItems = bodyItems
        freshCellKeys = freshKeys
        cachedHash = hash
        revision &+= 1
        MarkdownRenderProbe.increment(\.markdownTableBodyItemBuildCalls)
    }

    private func insertFreshCellKeyIfNeeded(
        into freshKeys: inout Set<MarkdownTableFreshCellKey>,
        previousHashesByRow: [[Int]],
        row: Int,
        column: Int,
        contentHash: Int
    ) {
        guard row < previousHashesByRow.count,
              column < previousHashesByRow[row].count,
              previousHashesByRow[row][column] != contentHash
        else { return }

        freshKeys.insert(
            MarkdownTableFreshCellKey(
                cellKey: MarkdownTableCellKey(row: row, column: column),
                contentHash: contentHash
            )
        )
    }
}

/// Outer table view. Holds the `TableInfoCache` and refreshes it from the
/// AST. **Deliberately does not observe `markdownStreaming`** — its body
/// only re-evaluates when the `table` prop changes (i.e. once per chunk),
/// so the expensive AST walks happen at chunk frequency, not at tick
/// frequency. All per-tick work lives in `MarkdownTableContent`.
struct MarkdownTable: View {
    var table: Markdown.Table

    @State private var cache = TableInfoCache()

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.markdownTableBodyCalls)
        let _ = cache.ensureFresh(for: table)
        MarkdownTableContent(table: table, cache: cache)
    }
}

/// Inner table view keeps table-level work at cell-transition frequency. The
/// actual per-character reveal ticks stay inside currently active cells.
struct MarkdownTableContent: View {
    var table: Markdown.Table
    var cache: TableInfoCache

    @Environment(\.markdownTableStyle) private var tableStyle
    @Environment(\.markdownRendererConfiguration.table) private var tableConfiguration
    @Environment(\.markdownStreaming) private var revealManager
    @Environment(\.markdownFadeReveal) private var fadeConfig
    @State private var containerWidth: CGFloat = MarkdownTableContent.estimatedContainerWidth
    /// Held via `@State` (not `@StateObject`) so SwiftUI does not subscribe
    /// to the class's `objectWillChange`. The scrollable path doesn't read
    /// `revealState` at all, and the non-scrollable path reads the snapshot
    /// synchronously on each body re-eval — neither path benefits from an
    /// automatic publish, but the scrollable path would suffer O(N) cell-diff
    /// per publish if we subscribed. The instance itself stays stable across
    /// rebuilds because SwiftUI compares `@State` references.
    @State private var revealState: MarkdownTableRevealState = MarkdownTableRevealState()

    private static var estimatedContainerWidth: CGFloat {
        #if os(iOS) || os(tvOS)
        UIScreen.main.bounds.width
        #elseif os(macOS)
        NSScreen.main?.frame.width ?? 800
        #else
        400
        #endif
    }

    fileprivate static let fallbackSettleSlack: Int = 24

    private var effectiveFadeDuration: TimeInterval {
        let baseDuration = fadeConfig?.duration ?? 0.4
        return revealManager?.adaptiveFadeDuration(baseDuration: baseDuration) ?? baseDuration
    }

    private var tableFadeSettleDuration: TimeInterval {
        if let fadeConfig {
            return fadeConfig.colorSettleDuration(adaptiveDuration: effectiveFadeDuration)
        }
        return min(effectiveFadeDuration + 0.05, 0.55)
    }

    private var revealManagerID: ObjectIdentifier? {
        revealManager.map(ObjectIdentifier.init)
    }

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.markdownTableContentBodyCalls)

        Group {
            if tableConfiguration.scrollable {
                // Scrollable path: cells own their phase via per-cell
                // `AdaptiveTableCellPhaseHolder`, so this body deliberately
                // does NOT read `revealState.currentSnapshot()`. Avoiding the
                // snapshot read keeps SwiftUI from rebuilding the
                // `ForEach(cache.bodyItems)` on every reveal tick — that's
                // the O(N)-per-publish path that was the dominant cost at
                // N≈900 cells.
                scrollableTable()
            } else {
                // Non-scrollable path still uses the snapshot-driven
                // `phasesByRow` env, since its cell count is small (native
                // SwiftUI Table) and per-publish O(N) is negligible.
                let revealSnapshot = revealState.currentSnapshot(cellInfos: cache.flatCellInfos)
                let _ = MarkdownRenderProbe.recordTablePhaseCounts(
                    active: revealSnapshot.activeKeys.count,
                    before: max(0, revealSnapshot.cellCount - revealSnapshot.pastCellCount - revealSnapshot.activeKeys.count),
                    past: min(revealSnapshot.pastCellCount, revealSnapshot.cellCount),
                    fresh: revealSnapshot.freshCellCount
                )
                let infoByRow = cache.infoByRow
                let offsetsByRow = infoByRow.map { row in row.map(\.offset) }
                let phasesByRow = revealSnapshot.phasesByRow(infoByRow: infoByRow)
                let configuration = MarkdownTableStyleConfiguration(
                    table: MarkdownTableStyleConfiguration.Table(table: table)
                )
                tableStyle
                    .makeBody(configuration: configuration)
                    .erasedToAnyView()
                    .markdownTableCellStyleApplied()
                    .coordinateSpace(name: MarkdownTable.CoordinateSpaceName)
                    .environment(\.markdownTableCellOffsetsByRow, offsetsByRow)
                    .environment(\.markdownTableCellPhasesByRow, phasesByRow)
            }
        }
        // Cells fade their own content via `FadeRevealMarkdownText`; we
        // deliberately don't wrap the table in a block-level fade-in or
        // layout spring. A smooth-spring layout animation here interacts
        // poorly with multi-pass layout (the `containerWidth` GeometryReader
        // feedback triggers a second pass with slightly different row
        // heights) — the spring takes the first pass's target with momentum,
        // overshoots, and visually "sinks past" before recovering. Letting
        // layout snap is both correct and stable during streaming.
        .onChange(of: revealManagerID, initial: true) { _, _ in
            configureRevealState()
        }
        .onChange(of: cache.revision, initial: true) { _, _ in
            configureRevealState()
        }
        .onChange(of: tableFadeSettleDuration, initial: true) { _, _ in
            configureRevealState()
        }
    }

    private func configureRevealState() {
        revealState.configure(
            manager: revealManager,
            cellInfos: cache.flatCellInfos,
            freshKeys: cache.freshCellKeys,
            settleDuration: tableFadeSettleDuration
        )
    }

    @ViewBuilder
    private func scrollableTable() -> some View {
        let _ = MarkdownRenderProbe.increment(\.markdownTableScrollableBuildCalls)
        let columnCount = table.head.childCount
        let spacing: CGFloat = markdownTableScrollableColumnSpacing
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = horizontalPadding + 5
        let stripeRows = scrollableTableStripeRows

        ScrollView(.horizontal, showsIndicators: true) {
            AdaptiveTableLayout(
                columnCount: columnCount,
                containerWidth: containerWidth,
                cellMaxWidth: tableConfiguration.cellMaxWidth,
                columnWidthBuckets: tableConfiguration.columnWidthBuckets,
                rowBackgroundRows: stripeRows.map(\.row),
                columnSpacing: spacing,
                contentRevision: cache.revision
            ) {
                ForEach(stripeRows) { item in
                    AdaptiveTableRowStripe(
                        blockTextOffset: item.blockTextOffset,
                        characterCount: item.characterCount
                    )
                }
                ForEach(cache.headerItems) { item in
                    let info = cache.flatCellInfos[item.flatIndex]
                    AdaptiveTableCell(
                        cell: item.cell,
                        cellContentHash: item.contentHash,
                        blockTextOffset: item.blockTextOffset,
                        characterCount: info.count,
                        isHeader: item.isHeader
                    )
                        .equatable()
                        .tableCellHash(item.contentHash)
                }
                ForEach(cache.bodyItems) { item in
                    let info = cache.flatCellInfos[item.flatIndex]
                    AdaptiveTableCell(
                        cell: item.cell,
                        cellContentHash: item.contentHash,
                        blockTextOffset: item.blockTextOffset,
                        characterCount: info.count,
                        isHeader: item.isHeader
                    )
                        .equatable()
                        .tableCellHash(item.contentHash)
                }
            }
        }
        .markdownTableCellPadding(.horizontal, horizontalPadding)
        .markdownTableCellPadding(.vertical, verticalPadding)
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.markdownTableCellSettleDuration, tableFadeSettleDuration)
        .background {
            GeometryReader { proxy in
                Color.clear
                    ._task(id: proxy.size.width) {
                        containerWidth = proxy.size.width
                    }
            }
        }
    }

    private var scrollableTableStripeRows: [AdaptiveTableRowStripeItem] {
        cache.infoByRow.indices.compactMap { row in
            guard row > 0, !row.isMultiple(of: 2) else { return nil }
            let infos = cache.infoByRow[row]
            guard let first = infos.first else { return nil }
            let endOffset = infos.reduce(first.offset) { max($0, $1.offset + $1.count) }
            return AdaptiveTableRowStripeItem(
                row: row,
                blockTextOffset: first.offset,
                characterCount: max(0, endOffset - first.offset)
            )
        }
    }
}

struct CellInfo: Hashable, Sendable {
    var offset: Int
    var count: Int
}

struct MarkdownTableFlatCellInfo: Hashable, Sendable {
    var key: MarkdownTableCellKey
    var flatIndex: Int
    var offset: Int
    var count: Int
    var contentHash: Int

    var endOffset: Int { offset + count }
}

struct MarkdownTableRevealSnapshot: Equatable, Sendable {
    var activeKeys: Set<MarkdownTableCellKey> = []
    var pastCellCount: Int = Int.max
    var cellCount: Int = 0
    var freshCellCount: Int = 0

    fileprivate func phase(for item: AdaptiveTableCellItem) -> MarkdownTableCellPhase {
        if activeKeys.contains(item.id) { return .active }
        if item.flatIndex < pastCellCount { return .past }
        return .before
    }

    func phasesByRow(infoByRow: [[CellInfo]]) -> [[MarkdownTableCellPhase]] {
        infoByRow.enumerated().map { rowIndex, row in
            row.enumerated().map { column, _ in
                let key = MarkdownTableCellKey(row: rowIndex, column: column)
                let flatIndex = infoByRow.prefix(rowIndex).reduce(0) { $0 + $1.count } + column
                if activeKeys.contains(key) { return .active }
                if flatIndex < pastCellCount { return .past }
                return .before
            }
        }
    }
}

@MainActor
private final class MarkdownTableRevealState: ObservableObject {
    private static let maxFreshActiveCells = 6
    private static let freshLookbehindCells = 6
    private static let freshLookbehindCharacters = 240

    @Published private(set) var snapshot = MarkdownTableRevealSnapshot()

    private var cellInfos: [MarkdownTableFlatCellInfo] = []
    private var freshCellExpirations: [MarkdownTableFreshCellKey: Date] = [:]
    private var listenerID: UUID?
    private weak var subscribedManager: StreamingRevealManager?
    private var settleTask: Task<Void, Never>?
    private var settleDuration: TimeInterval = 0.77
    /// Last `revealedCount` we've seen via the manager listener. Used by
    /// `registerCellsCrossedByFrontier` to know which cells got their final
    /// character revealed *this tick*. `nil` means we haven't observed any
    /// revealed value yet (fresh subscribe / table mount) — first observation
    /// is treated as a baseline so already-revealed cells aren't retroactively
    /// stamped as "just-completed".
    private var lastObservedRevealed: Int?

    deinit {
        settleTask?.cancel()
        if let listenerID, let subscribedManager {
            Task { @MainActor in
                subscribedManager.removeListener(listenerID)
            }
        }
    }

    func configure(
        manager: StreamingRevealManager?,
        cellInfos: [MarkdownTableFlatCellInfo],
        freshKeys: Set<MarkdownTableFreshCellKey>,
        settleDuration: TimeInterval
    ) {
        self.cellInfos = cellInfos
        self.settleDuration = settleDuration
        pruneFreshCells(now: Date())
        registerFreshCells(freshKeys)
        subscribeIfNeeded(to: manager)
        refresh(revealed: manager?.revealedCount ?? Int.max)
    }

    func phase(for item: AdaptiveTableCellItem) -> MarkdownTableCellPhase {
        currentSnapshot().phase(for: item)
    }

    func currentSnapshot(cellInfos fallbackCellInfos: [MarkdownTableFlatCellInfo] = []) -> MarkdownTableRevealSnapshot {
        let revealed = subscribedManager?.revealedCount ?? Int.max
        return makeSnapshot(
            revealed: revealed,
            now: Date(),
            fallbackCellInfos: fallbackCellInfos
        ).snapshot
    }

    private func subscribeIfNeeded(to manager: StreamingRevealManager?) {
        guard subscribedManager !== manager else { return }

        if let listenerID, let subscribedManager {
            subscribedManager.removeListener(listenerID)
        }
        listenerID = nil
        subscribedManager = manager
        // Reset frontier-tracking so the first refresh callback below is
        // treated as a baseline, not as if the entire revealed prefix had
        // *just* crossed cell boundaries (which would mass-register every
        // already-revealed cell as fresh).
        lastObservedRevealed = nil

        guard let manager else { return }
        listenerID = manager.addListener { [weak self] revealed in
            self?.refresh(revealed: revealed)
        }
    }

    private func registerFreshCells(_ keys: Set<MarkdownTableFreshCellKey>) {
        guard subscribedManager != nil, !keys.isEmpty else { return }

        let now = Date()
        let infoByFreshKey = Dictionary(
            uniqueKeysWithValues: cellInfos.map { info in
                (
                    MarkdownTableFreshCellKey(
                        cellKey: info.key,
                        contentHash: info.contentHash
                    ),
                    info
                )
            }
        )
        let liveKeys = Set(infoByFreshKey.keys)
        freshCellExpirations = freshCellExpirations.filter { key, expiration in
            liveKeys.contains(key) && expiration > now
        }

        let revealed = subscribedManager?.revealedCount ?? Int.max
        guard revealed != Int.max else { return }

        let currentIndex = lastCellIndex(startingAtOrBefore: revealed, in: cellInfos) ?? 0
        let candidates = keys.compactMap { key -> (key: MarkdownTableFreshCellKey, distance: Int)? in
            guard let info = infoByFreshKey[key],
                  revealed >= info.offset
            else { return nil }

            // Already in the fresh set (i.e. still settling) — skip; we don't
            // overwrite an in-flight expiration with a fresh `now` stamp.
            if freshCellExpirations[key] != nil { return nil }
            // Frontier still inside this cell — it'll be picked up as active
            // via the explicit insertion in `makeSnapshot`, no need to mark
            // fresh.
            if revealed < info.endOffset { return nil }

            let cellDistance = abs(info.flatIndex - currentIndex)
            let charDistance = max(0, revealed - info.endOffset)
            guard cellDistance <= Self.freshLookbehindCells
                    || charDistance <= Self.freshLookbehindCharacters
            else { return nil }

            return (key, min(cellDistance, charDistance))
        }
        .sorted { lhs, rhs in
            lhs.distance < rhs.distance
        }
        .prefix(Self.maxFreshActiveCells)

        let expiration = now.addingTimeInterval(settleDuration)
        for candidate in candidates {
            freshCellExpirations[candidate.key] = expiration
        }
    }

    private func refresh(revealed: Int) {
        let now = Date()
        pruneFreshCells(now: now)
        registerCellsCrossedByFrontier(revealed: revealed, now: now)
        lastObservedRevealed = revealed
        let result = makeSnapshot(revealed: revealed, now: now)
        if snapshot != result.snapshot {
            snapshot = result.snapshot
        }
        scheduleSettleRefresh(at: result.nextRefreshDate)
    }

    private func pruneFreshCells(now: Date) {
        guard !freshCellExpirations.isEmpty else { return }
        freshCellExpirations = freshCellExpirations.filter { _, expiration in
            expiration > now
        }
    }

    /// Event-driven settle registration. Whenever the frontier crosses a
    /// cell's `endOffset` since the last refresh, that cell starts its settle
    /// timer right now — registered into `freshCellExpirations` with a
    /// concrete expiration date. After this, `makeSnapshot` no longer needs
    /// the per-tick backward walk that previously called
    /// `firstSeenTimestamp + settleDuration > now` on each cell (a continuous
    /// time function whose result flipped every tick near the boundary,
    /// causing snapshot churn at tick frequency).
    private func registerCellsCrossedByFrontier(revealed: Int, now: Date) {
        guard !cellInfos.isEmpty else { return }
        guard let prev = lastObservedRevealed else { return } // first observation: baseline only

        // Treat completion as "frontier reaches the end of the table" so the
        // final tail of cells also receive a settle clock.
        let prevEffective = prev == Int.max ? (cellInfos.last?.endOffset ?? 0) : prev
        let currEffective = revealed == Int.max ? (cellInfos.last?.endOffset ?? 0) : revealed
        guard currEffective > prevEffective else { return }

        // Cells whose `endOffset` is in (prevEffective, currEffective]
        // were just fully revealed this tick. Binary-search the lower bound.
        var idx = firstCellIndex(withEndOffsetGreaterThan: prevEffective, in: cellInfos)
        while idx < cellInfos.count {
            let info = cellInfos[idx]
            if info.endOffset > currEffective { break }
            if info.count > 0 {
                let key = MarkdownTableFreshCellKey(
                    cellKey: info.key,
                    contentHash: info.contentHash
                )
                if freshCellExpirations[key] == nil {
                    let stamp = subscribedManager?.firstSeenTimestamp(
                        at: max(info.offset, info.endOffset - 1)
                    ) ?? now
                    freshCellExpirations[key] = stamp.addingTimeInterval(settleDuration)
                }
            }
            idx += 1
        }
    }

    private func makeSnapshot(
        revealed: Int,
        now: Date,
        fallbackCellInfos: [MarkdownTableFlatCellInfo] = []
    ) -> (snapshot: MarkdownTableRevealSnapshot, nextRefreshDate: Date?) {
        let snapshotCellInfos = cellInfos.isEmpty ? fallbackCellInfos : cellInfos
        guard !snapshotCellInfos.isEmpty else {
            return (MarkdownTableRevealSnapshot(pastCellCount: 0, cellCount: 0), nil)
        }

        var activeKeys = Set<MarkdownTableCellKey>()
        var nextRefreshDate: Date?

        let isCompleted = revealed == Int.max
        let effectiveRevealed = isCompleted
            ? (snapshotCellInfos.last?.endOffset ?? 0)
            : revealed
        let currentIndex = lastCellIndex(
            startingAtOrBefore: effectiveRevealed,
            in: snapshotCellInfos
        )

        // pastCellCount: count of cells whose `endOffset <= effectiveRevealed`
        // (i.e. frontier has fully crossed them). Cells the frontier is
        // currently inside are NOT past — they're active via the explicit
        // insertion below.
        let pastCellCount: Int
        if let currentIndex {
            let info = snapshotCellInfos[currentIndex]
            if effectiveRevealed < info.endOffset {
                // Frontier still inside this cell — it's active, not past.
                activeKeys.insert(info.key)
                pastCellCount = currentIndex
            } else {
                // Frontier exactly at or past this cell's endOffset.
                pastCellCount = currentIndex + 1
            }
        } else {
            pastCellCount = 0
        }

        // Fresh cells from event-driven registration (settle window). Active
        // is the union of "frontier currently inside" + "still settling".
        for (freshKey, expiration) in freshCellExpirations {
            activeKeys.insert(freshKey.cellKey)
            nextRefreshDate = minDate(nextRefreshDate, expiration)
        }

        let snapshot = MarkdownTableRevealSnapshot(
            activeKeys: activeKeys,
            pastCellCount: pastCellCount,
            cellCount: snapshotCellInfos.count,
            freshCellCount: freshCellExpirations.count
        )
        return (snapshot, nextRefreshDate)
    }

    private func lastCellIndex(
        startingAtOrBefore revealed: Int,
        in cellInfos: [MarkdownTableFlatCellInfo]
    ) -> Int? {
        var low = 0
        var high = cellInfos.count
        while low < high {
            let mid = (low + high) / 2
            if cellInfos[mid].offset <= revealed {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let index = low - 1
        return index >= 0 ? index : nil
    }

    /// Smallest index `i` such that `cellInfos[i].endOffset > threshold`.
    /// Returns `cellInfos.count` if no such cell exists.
    private func firstCellIndex(
        withEndOffsetGreaterThan threshold: Int,
        in cellInfos: [MarkdownTableFlatCellInfo]
    ) -> Int {
        var low = 0
        var high = cellInfos.count
        while low < high {
            let mid = (low + high) / 2
            if cellInfos[mid].endOffset > threshold {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    private func scheduleSettleRefresh(at date: Date?) {
        settleTask?.cancel()
        guard let date else { return }
        let delay = max(0.01, date.timeIntervalSinceNow)
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.refresh(revealed: self?.subscribedManager?.revealedCount ?? Int.max)
        }
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }
}

private struct AdaptiveTableCellItem: Identifiable {
    var row: Int
    var column: Int
    var flatIndex: Int
    var cell: Markdown.Table.Cell
    var isHeader: Bool
    var blockTextOffset: Int = 0
    var phase: MarkdownTableCellPhase = .past
    /// Pre-computed via `TableInfoCache.ensureFresh` so we don't pay for a
    /// recursive `cell.stableContentHash` walk every body re-evaluation.
    var contentHash: Int = 0

    var id: MarkdownTableCellKey {
        MarkdownTableCellKey(row: row, column: column)
    }
}

private struct AdaptiveTableRowStripeItem: Identifiable {
    var row: Int
    var blockTextOffset: Int
    var characterCount: Int

    var id: Int { row }
}

// MARK: - Cell hash layout value key

private struct TableCellHashKey: LayoutValueKey {
    static let defaultValue: Int = 0
}

private extension View {
    func tableCellHash(_ hash: Int) -> some View {
        layoutValue(key: TableCellHashKey.self, value: hash)
    }
}

// MARK: - Adaptive Table Layout

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct AdaptiveTableLayout: Layout {
    var columnCount: Int
    var containerWidth: CGFloat
    var cellMaxWidth: CGFloat
    var columnWidthBuckets: [CGFloat]
    var rowBackgroundRows: [Int] = []
    var columnSpacing: CGFloat = 12
    var contentRevision: Int

    struct CacheData {
        var columnWidths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
        var columnCount: Int = 0
        var contentRevision: Int = -1
        var cellCount: Int = 0
        var containerWidth: CGFloat = 0
        var cellMaxWidth: CGFloat = 0
        var columnWidthBuckets: [CGFloat] = []
        var cachedSize: CGSize = .zero
        var cellHashes: [Int] = []
        var cellIdealWidths: [CGFloat] = []
        var cellConstrainedHeights: [CGFloat] = []
        var columnOffsets: [CGFloat] = []
        var rowOffsets: [CGFloat] = []
        var relativeCellOrigins: [CGPoint] = []
        var cellProposals: [ProposedViewSize] = []
        var absoluteCellOrigins: [CGPoint] = []
        var absoluteOriginBase: CGPoint?
    }

    func makeCache(subviews: Subviews) -> CacheData { CacheData() }

    func updateCache(_ cache: inout CacheData, subviews: Subviews) {
        if cache.columnCount != columnCount { cache = CacheData() }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let probeStart = MarkdownRenderProbe.begin()
        defer {
            MarkdownRenderProbe.finish(
                calls: \.adaptiveTableLayoutSizeCalls,
                ms: \.adaptiveTableLayoutSizeMs,
                start: probeStart
            )
        }

        let rowBackgroundCount = min(rowBackgroundRows.count, subviews.count)
        let cellSubviewCount = subviews.count - rowBackgroundCount
        guard cellSubviewCount > 0, columnCount > 0 else { return .zero }
        let rowCount = cellSubviewCount / columnCount
        guard rowCount > 0 else { return .zero }

        let totalSpacing = columnSpacing * CGFloat(max(columnCount - 1, 0))
        let widthBuckets = Self.normalizedWidthBuckets(
            columnWidthBuckets,
            cellMaxWidth: cellMaxWidth
        )

        if cache.columnCount == columnCount,
           cache.contentRevision == contentRevision,
           cache.cellCount == cellSubviewCount,
           cache.containerWidth == containerWidth,
           cache.cellMaxWidth == cellMaxWidth,
           cache.columnWidthBuckets == widthBuckets,
           cache.columnWidths.count == columnCount,
           cache.rowHeights.count == rowCount {
            MarkdownRenderProbe.increment(\.adaptiveTableLayoutCacheHits)
            return cache.cachedSize
        }

        let currentHashes = (0..<cellSubviewCount).map { index in
            subviews[rowBackgroundCount + index][TableCellHashKey.self]
        }

        // Build per-cell ideal widths, measuring only changed/new cells
        let hasCellCache = cache.columnCount == columnCount
            && cache.cellMaxWidth == cellMaxWidth
            && cache.columnWidthBuckets == widthBuckets
            && cache.cellIdealWidths.count == cache.cellHashes.count
            && !cache.cellIdealWidths.isEmpty

        var cellIdealWidths = hasCellCache
            ? cache.cellIdealWidths + [CGFloat](repeating: 0, count: max(0, currentHashes.count - cache.cellIdealWidths.count))
            : [CGFloat](repeating: 0, count: currentHashes.count)

        var cellConstrainedHeights = hasCellCache
            ? cache.cellConstrainedHeights + [CGFloat](repeating: 0, count: max(0, currentHashes.count - cache.cellConstrainedHeights.count))
            : [CGFloat](repeating: 0, count: currentHashes.count)

        var changedCols = Set<Int>()
        for (i, hash) in currentHashes.enumerated() {
            let changed = !hasCellCache || i >= cache.cellHashes.count || cache.cellHashes[i] != hash
            if changed {
                let col = i % columnCount
                MarkdownRenderProbe.increment(\.adaptiveTableLayoutIdealMeasures)
                let ideal = subviews[rowBackgroundCount + i].sizeThatFits(.unspecified)
                cellIdealWidths[i] = Self.snappedWidth(
                    min(ideal.width, cellMaxWidth),
                    buckets: widthBuckets,
                    cellMaxWidth: cellMaxWidth
                )
                changedCols.insert(col)
            }
        }

        // Recompute column widths only when affected columns changed
        var colWidths: [CGFloat]
        if changedCols.isEmpty, cache.columnWidths.count == columnCount {
            colWidths = cache.columnWidths
        } else {
            var colIdeals = [CGFloat](repeating: 0, count: columnCount)
            for (i, w) in cellIdealWidths.enumerated() where i < currentHashes.count {
                let col = i % columnCount
                colIdeals[col] = max(colIdeals[col], w)
            }
            let totalIdeal = colIdeals.reduce(0, +) + totalSpacing
            if totalIdeal < containerWidth, containerWidth > 0, colIdeals.reduce(0, +) > 0 {
                let excess = containerWidth - totalIdeal
                let idealSum = colIdeals.reduce(0, +)
                colWidths = colIdeals.map { $0 + excess * ($0 / idealSum) }
            } else {
                colWidths = colIdeals
            }
        }

        // Recompute row heights for changed rows only (or all if colWidths changed)
        let colWidthsChanged = colWidths != cache.columnWidths
        var rowHeights: [CGFloat]

        if colWidthsChanged {
            // 列宽变化时只重测「真正会随宽度改变高度」的 cell。关键事实:一个 cell 只有在它的
            // 自然宽度(idealWidth)≥ 列宽、即会换行时,高度才依赖列宽;能在更窄一侧单行放下的
            // cell(idealWidth < min(新,旧列宽))高度与宽度无关,直接复用缓存高度。
            // 流式时最后一格变宽 → 该列变宽,原来这里 O(整列行数) 全部重测,几百次 Core Text
            // 排版挤在一帧 → 240ms 卡顿(实测 mainCPU 86–95%、maxFrameMs 200+)。改成只测会换行
            // 的少数 cell 后,长表格某列变宽不再触发整列重测。
            let canReuseHeights = hasCellCache
                && cache.cellConstrainedHeights.count == cache.cellHashes.count
                && cache.cellIdealWidths.count == cache.cellHashes.count
            rowHeights = [CGFloat](repeating: 0, count: rowCount)
            for i in 0..<cellSubviewCount {
                let col = i % columnCount
                let row = i / columnCount
                guard row < rowCount else { continue }
                let contentChanged = i >= cache.cellHashes.count || cache.cellHashes[i] != currentHashes[i]
                let oldColWidth = col < cache.columnWidths.count ? cache.columnWidths[col] : .infinity
                let newColWidth = colWidths[col]
                let wrapThreshold = min(oldColWidth, newColWidth) - 0.5
                let widthSensitive = i < cellIdealWidths.count && cellIdealWidths[i] >= wrapThreshold
                let needMeasure = !canReuseHeights
                    || contentChanged
                    || (oldColWidth != newColWidth && widthSensitive)
                let height: CGFloat
                if needMeasure {
                    MarkdownRenderProbe.increment(\.adaptiveTableLayoutConstrainedMeasures)
                    height = subviews[rowBackgroundCount + i]
                        .sizeThatFits(ProposedViewSize(width: newColWidth, height: nil))
                        .height
                } else {
                    height = cache.cellConstrainedHeights[i]
                }
                cellConstrainedHeights[i] = height
                rowHeights[row] = max(rowHeights[row], height)
            }
        } else {
            let prevRowCount = cache.rowHeights.count
            rowHeights = prevRowCount == rowCount
                ? cache.rowHeights
                : cache.rowHeights + [CGFloat](repeating: 0, count: max(0, rowCount - prevRowCount))

            var changedRows = Set<Int>()
            for (i, hash) in currentHashes.enumerated() {
                let changed = !hasCellCache || i >= cache.cellHashes.count || cache.cellHashes[i] != hash
                if changed { changedRows.insert(i / columnCount) }
            }
            for row in changedRows {
                var h: CGFloat = 0
                for col in 0..<columnCount {
                    let i = row * columnCount + col
                    guard i < cellSubviewCount else { break }
                    MarkdownRenderProbe.increment(\.adaptiveTableLayoutConstrainedMeasures)
                    let size = subviews[rowBackgroundCount + i]
                        .sizeThatFits(ProposedViewSize(width: colWidths[col], height: nil))
                    cellConstrainedHeights[i] = size.height
                    h = max(h, size.height)
                }
                rowHeights[row] = h
            }
        }

        cache.columnWidths = colWidths
        cache.rowHeights = rowHeights
        cache.columnCount = columnCount
        cache.contentRevision = contentRevision
        cache.cellCount = cellSubviewCount
        cache.containerWidth = containerWidth
        cache.cellMaxWidth = cellMaxWidth
        cache.columnWidthBuckets = widthBuckets
        cache.cellHashes = currentHashes
        cache.cellIdealWidths = cellIdealWidths
        cache.cellConstrainedHeights = cellConstrainedHeights
        let columnOffsets = Self.offsets(for: colWidths, spacing: columnSpacing)
        let rowOffsets = Self.offsets(for: rowHeights, spacing: 0)
        cache.columnOffsets = columnOffsets
        cache.rowOffsets = rowOffsets
        cache.relativeCellOrigins = Self.cellOrigins(
            columnOffsets: columnOffsets,
            rowOffsets: rowOffsets,
            columnCount: columnCount,
            cellCount: currentHashes.count
        )
        cache.cellProposals = Self.cellProposals(
            columnWidths: colWidths,
            rowHeights: rowHeights,
            columnCount: columnCount,
            cellCount: currentHashes.count
        )
        cache.absoluteCellOrigins.removeAll(keepingCapacity: true)
        cache.absoluteOriginBase = nil

        let totalWidth = colWidths.reduce(0, +) + totalSpacing
        let totalHeight = rowHeights.reduce(0, +)
        let size = CGSize(width: max(totalWidth, containerWidth), height: totalHeight)
        cache.cachedSize = size
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        let rowBackgroundCount = min(rowBackgroundRows.count, subviews.count)
        let cellSubviewCount = subviews.count - rowBackgroundCount
        let cellCount = min(
            cellSubviewCount,
            cache.relativeCellOrigins.count,
            cache.cellProposals.count
        )
        guard cellCount > 0
        else { return }

        let originBase = CGPoint(x: bounds.minX, y: bounds.minY)
        if cache.absoluteOriginBase != originBase || cache.absoluteCellOrigins.count != cache.relativeCellOrigins.count {
            cache.absoluteCellOrigins = cache.relativeCellOrigins.map {
                CGPoint(x: originBase.x + $0.x, y: originBase.y + $0.y)
            }
            cache.absoluteOriginBase = originBase
        }

        for (backgroundIndex, row) in rowBackgroundRows.enumerated() where backgroundIndex < rowBackgroundCount {
            guard row >= 0,
                  row < cache.rowOffsets.count,
                  row < cache.rowHeights.count
            else { continue }

            subviews[backgroundIndex].place(
                at: CGPoint(
                    x: bounds.minX,
                    y: bounds.minY + cache.rowOffsets[row]
                ),
                proposal: ProposedViewSize(
                    width: cache.cachedSize.width,
                    height: cache.rowHeights[row]
                )
            )
        }

        for index in 0..<cellCount {
            subviews[rowBackgroundCount + index].place(
                at: cache.absoluteCellOrigins[index],
                proposal: cache.cellProposals[index]
            )
        }
    }

    private static func offsets(for sizes: [CGFloat], spacing: CGFloat) -> [CGFloat] {
        var result = [CGFloat](repeating: 0, count: sizes.count)
        var cursor: CGFloat = 0
        for index in sizes.indices {
            result[index] = cursor
            cursor += sizes[index] + spacing
        }
        return result
    }

    private static func normalizedWidthBuckets(
        _ buckets: [CGFloat],
        cellMaxWidth: CGFloat
    ) -> [CGFloat] {
        let validBuckets = buckets
            .filter { $0.isFinite && $0 > 0 }
            .map { min($0, cellMaxWidth) }
        let merged = Set(validBuckets + [cellMaxWidth])
        let sorted = merged.sorted()
        return sorted.isEmpty ? [cellMaxWidth] : sorted
    }

    private static func snappedWidth(
        _ width: CGFloat,
        buckets: [CGFloat],
        cellMaxWidth: CGFloat
    ) -> CGFloat {
        guard width.isFinite, width > 0 else {
            return buckets.first ?? cellMaxWidth
        }

        let clamped = min(width, cellMaxWidth)
        return buckets.first(where: { $0 >= clamped }) ?? cellMaxWidth
    }

    private static func cellOrigins(
        columnOffsets: [CGFloat],
        rowOffsets: [CGFloat],
        columnCount: Int,
        cellCount: Int
    ) -> [CGPoint] {
        guard columnCount > 0, !columnOffsets.isEmpty, !rowOffsets.isEmpty else { return [] }

        var origins: [CGPoint] = []
        origins.reserveCapacity(cellCount)
        var index = 0
        for row in rowOffsets.indices {
            let y = rowOffsets[row]
            for column in 0..<columnCount {
                guard index < cellCount else { return origins }
                origins.append(CGPoint(x: columnOffsets[column], y: y))
                index += 1
            }
        }
        return origins
    }

    private static func cellProposals(
        columnWidths: [CGFloat],
        rowHeights: [CGFloat],
        columnCount: Int,
        cellCount: Int
    ) -> [ProposedViewSize] {
        guard columnCount > 0, !columnWidths.isEmpty, !rowHeights.isEmpty else { return [] }

        var proposals: [ProposedViewSize] = []
        proposals.reserveCapacity(cellCount)
        var index = 0
        for row in rowHeights.indices {
            let height = rowHeights[row]
            for column in 0..<columnCount {
                guard index < cellCount else { return proposals }
                proposals.append(
                    ProposedViewSize(
                        width: columnWidths[column],
                        height: height
                    )
                )
                index += 1
            }
        }
        return proposals
    }
}

// MARK: - Adaptive Table Cell

/// Per-cell phase store. Every `AdaptiveTableCell` in the scrollable path owns
/// one (via `@StateObject`) so phase changes invalidate **only that cell**
/// instead of going through `MarkdownTableContent.body` and forcing SwiftUI to
/// diff every cell in `ForEach(cache.bodyItems)` (the O(N)-per-publish path
/// that was the dominant cost at N≈900).
///
/// Subscribes to the shared `StreamingRevealManager` listener; every notify
/// runs `computePhase` and only writes `@Published phase` when it actually
/// changes — so the per-tick fan-out across N listeners costs essentially an
/// int compare per cell, and only the handful of cells whose phase actually
/// transitions trigger a `body` re-eval.
@MainActor
private final class AdaptiveTableCellPhaseHolder: ObservableObject {
    @Published private(set) var phase: MarkdownTableCellPhase = .before

    private weak var manager: StreamingRevealManager?
    private var listenerID: UUID?
    private var settleTask: Task<Void, Never>?
    private var blockTextOffset: Int = 0
    private var characterCount: Int = 0
    private var settleDuration: TimeInterval = 0.55
    /// Re-entrancy guard. `StreamingRevealManager.addListener` synchronously
    /// invokes the listener once with the current `revealedCount`, which
    /// re-enters `refreshPhase` *before* `listenerID` has been assigned. The
    /// flag tells the re-entered `refreshPhase` that a subscribe is already
    /// in progress, so it doesn't infinitely recurse trying to subscribe
    /// again.
    private var isSubscribing: Bool = false

    deinit {
        settleTask?.cancel()
        if let listenerID, let manager {
            Task { @MainActor in
                manager.removeListener(listenerID)
            }
        }
    }

    func configure(
        manager: StreamingRevealManager?,
        blockTextOffset: Int,
        characterCount: Int,
        settleDuration: TimeInterval
    ) {
        let managerChanged = self.manager !== manager
        self.blockTextOffset = blockTextOffset
        self.characterCount = characterCount
        self.settleDuration = settleDuration

        if managerChanged {
            unsubscribe()
            self.manager = manager
        }
        // `refreshPhase` decides whether we need a listener — no unconditional
        // (re)subscribe here. Doing it unconditionally caused thousands of
        // subscribe/unsubscribe round-trips per second: every chunk triggers
        // `onChange` cascades that re-call configure on N cells, and any
        // already-settled cells would re-add a listener only to immediately
        // drop it again.
        refreshPhase()
    }

    func unsubscribe() {
        settleTask?.cancel()
        settleTask = nil
        if let listenerID, let manager {
            manager.removeListener(listenerID)
        }
        listenerID = nil
    }

    private func subscribe() {
        guard let manager, listenerID == nil, !isSubscribing else { return }
        isSubscribing = true
        defer { isSubscribing = false }
        // Note: `manager.addListener` synchronously invokes the listener once
        // with the current `revealedCount` before returning. That re-enters
        // `refreshPhase` while we're still inside this method — the
        // `isSubscribing` flag above prevents the re-entrant call from
        // recursively trying to subscribe again.
        listenerID = manager.addListener { [weak self] _ in
            self?.refreshPhase()
        }
    }

    private func refreshPhase() {
        let newPhase = computePhase()
        if newPhase != phase {
            phase = newPhase
        }
        // Single source of truth for listener subscription state: if there's
        // any chance we'll still need to react to frontier movement, be
        // subscribed; otherwise drop.
        //
        // `revealedCount` is monotonic, so once we're permanently `.past`
        // (frontier moved past, settle expired) we can't possibly need to
        // react again — at N≈1000 cells the per-tick listener fan-out is
        // the dominant late-stream cost. The `settleTask` scheduled inside
        // `computePhase` guarantees this `refreshPhase` runs at least once
        // after the settle expiration even with zero listener notifies.
        let shouldDrop = newPhase == .past && shouldDropListener()
        if shouldDrop {
            if listenerID != nil { unsubscribe() }
        } else {
            if listenerID == nil, !isSubscribing, manager != nil { subscribe() }
        }
    }

    private func computePhase() -> MarkdownTableCellPhase {
        guard characterCount > 0 else { return .past }
        let revealed = manager?.revealedCount ?? Int.max
        let endOffset = blockTextOffset + characterCount

        if revealed != Int.max {
            if revealed < blockTextOffset { return .before }
            if revealed < endOffset { return .active }
        }

        // revealed == Int.max 或已越过本 cell:统一走 settle 窗口判定。
        // 关键:流式中协调器追上当前尾部会瞬时 finishReveal(Int.max)、内容增长又 rewind(非单调!)。
        // 旧逻辑 Int.max 直接 .past —— 整表已解析未揭示的 cell 一起无淡入弹出(「新块出现表格瞬间完成」的根因)。
        // completion 给这些字符盖的是新鲜时间戳 → settle 窗口内应 .active 淡入,与文字路径的 completion-fade 一致。
        if let stamp = manager?.firstSeenTimestamp(at: endOffset - 1) {
            let expiration = stamp.addingTimeInterval(settleDuration)
            if expiration > Date() {
                scheduleSettleTransition(at: expiration)
                return .active
            }
        }
        return .past
    }

    private func shouldDropListener() -> Bool {
        guard let manager else { return true }
        guard characterCount > 0 else { return true }
        let revealed = manager.revealedCount
        let endOffset = blockTextOffset + characterCount
        // Frontier still inside or about to reach us — must stay subscribed.
        // 注意:不能把 Int.max 当"流结束"提前丢监听 —— 流式中协调器追上尾部会瞬时 Int.max、
        // 内容增长又 rewind;掉了监听就收不到 rewind 通知,cell 永久卡死在 .past。
        // Int.max 时按下方 settle 窗口判定:窗口内保活(能接住 rewind),窗口过后再丢。
        if revealed != Int.max, revealed < endOffset { return false }
        // Settle clock still ticking — `settleTask` will refresh us at
        // expiration, but we keep the listener as a defensive backup.
        if let stamp = manager.firstSeenTimestamp(at: endOffset - 1),
           stamp.addingTimeInterval(settleDuration) > Date() {
            return false
        }
        return true
    }

    private func scheduleSettleTransition(at date: Date) {
        settleTask?.cancel()
        let delay = max(0.01, date.timeIntervalSinceNow)
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.refreshPhase()
            }
        }
    }
}

fileprivate struct AdaptiveTableCell: View, Equatable {
    var cell: Markdown.Table.Cell
    var cellContentHash: Int
    var blockTextOffset: Int
    /// Character span this cell covers in the block's reveal frontier. Needed
    /// by the per-cell phase holder to know when frontier crosses this cell's
    /// `endOffset = blockTextOffset + characterCount`.
    var characterCount: Int
    var isHeader: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // `phase` is intentionally not part of equality — it now lives in the
        // per-cell `@StateObject phaseHolder`, so the `ForEach`-emitted value
        // for a given cell stays stable across reveal ticks. Combined with
        // `.equatable()`, SwiftUI fast-paths the diff of unchanged cells.
        lhs.cellContentHash == rhs.cellContentHash
        && lhs.blockTextOffset == rhs.blockTextOffset
        && lhs.characterCount == rhs.characterCount
        && lhs.isHeader == rhs.isHeader
    }

    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownTableCellPadding) private var padding
    @Environment(\.markdownFontGroup.tableHeader) private var headerFont
    @Environment(\.markdownFontGroup.tableBody) private var bodyFont
    @Environment(\.markdownStreaming) private var revealManager
    @Environment(\.markdownTableCellSettleDuration) private var settleDuration
    @Environment(\.markdownTableHeaderDimsParentheticals) private var dimsParentheticals
    @Environment(\.markdownTableCellsSelectable) private var cellsSelectable

    @StateObject private var phaseHolder = AdaptiveTableCellPhaseHolder()

    private var revealManagerID: ObjectIdentifier? {
        revealManager.map(ObjectIdentifier.init)
    }

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.adaptiveTableCellBodyCalls)
        let phase = phaseHolder.phase
        cellContent
            .markdownTablePhase(phase, offsetBase: blockTextOffset)
            .multilineTextAlignment(cell.textAlignment)
            ._markdownCellPadding(padding)
            .font(isHeader ? headerFont : bodyFont)
            .textCase(isHeader ? .uppercase : .none)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cellAlignment)
            .onAppear { configurePhaseHolder() }
            .onDisappear { phaseHolder.unsubscribe() }
            .onChange(of: revealManagerID) { _, _ in configurePhaseHolder() }
            .onChange(of: blockTextOffset) { _, _ in configurePhaseHolder() }
            .onChange(of: characterCount) { _, _ in configurePhaseHolder() }
            .onChange(of: settleDuration) { _, _ in configurePhaseHolder() }
    }

    @ViewBuilder
    private var cellContent: some View {
        // 表头 + 开关开 + 纯文本单元格:把 (...) 改小一号 + secondary。
        // 含图片/数学等非文本 inline 的表头(asAttributedString == nil)走原渲染。
        if isHeader, dimsParentheticals, let attributed = dimmedHeaderAttributed {
            MarkdownNodeView(attributed)
                .environment(\.markdownRendererConfiguration, configuration)
        } else if !isHeader, cellsSelectable {
            // body cell 可选中(per-cell,不跨 cell):cell 源码单独渲染,reveal 锚点经
            // blockTextOffset 变绝对坐标,与块级 sweep 完全同源(节奏=原版逐 cell 扫过)。
            // 表头保持原渲染(bold/uppercase 样式)。tableBody 默认 Font.body,与可选中路径字体一致。
            // 注意:Table.Cell 禁止整体 format()(swift-markdown fatalError),逐个 inline 子节点拼接。
            MarkdownSelectableText(
                cell.children.map { $0.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines),
                plainOffsetBase: blockTextOffset
            )
        } else {
            CmarkNodeVisitor(configuration: configuration)
                .makeBody(for: cell)
        }
    }

    private var dimmedHeaderAttributed: AttributedString? {
        var visitor = CmarkNodeVisitor(configuration: configuration)
        guard let attributed = visitor.visit(cell).asAttributedString else { return nil }
        return MarkdownTableHeaderStyling.dimmingParentheticals(
            attributed,
            font: .caption,
            color: .secondary
        )
    }

    private func configurePhaseHolder() {
        phaseHolder.configure(
            manager: revealManager,
            blockTextOffset: blockTextOffset,
            characterCount: characterCount,
            settleDuration: settleDuration
        )
    }

    private var cellAlignment: Alignment {
        switch cell.horizontalAlignment {
        case .leading: return .topLeading
        case .trailing: return .topTrailing
        default: return .top
        }
    }
}

fileprivate struct AdaptiveTableRowStripe: View, Equatable {
    var blockTextOffset: Int
    var characterCount: Int

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.blockTextOffset == rhs.blockTextOffset
        && lhs.characterCount == rhs.characterCount
    }

    @Environment(\.markdownStreaming) private var revealManager
    @Environment(\.markdownTableCellSettleDuration) private var settleDuration
    @StateObject private var phaseHolder = AdaptiveTableCellPhaseHolder()

    private var revealManagerID: ObjectIdentifier? {
        revealManager.map(ObjectIdentifier.init)
    }

    var body: some View {
        let phase = phaseHolder.phase
        RoundedRectangle(
            cornerRadius: markdownTableScrollableStripeCornerRadius,
            style: .continuous
        )
        .foregroundStyle(.tertiary.opacity(markdownTableScrollableStripeOpacity))
        .padding(.horizontal, -markdownTableScrollableStripeHorizontalBleed)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .markdownTableRevealVisible(phase != .before)
        .allowsHitTesting(false)
        .onAppear { configurePhaseHolder() }
        .onDisappear { phaseHolder.unsubscribe() }
        .onChange(of: revealManagerID) { _, _ in configurePhaseHolder() }
        .onChange(of: blockTextOffset) { _, _ in configurePhaseHolder() }
        .onChange(of: characterCount) { _, _ in configurePhaseHolder() }
        .onChange(of: settleDuration) { _, _ in configurePhaseHolder() }
    }

    private func configurePhaseHolder() {
        phaseHolder.configure(
            manager: revealManager,
            blockTextOffset: blockTextOffset,
            characterCount: characterCount,
            settleDuration: settleDuration
        )
    }
}

struct MarkdownTableCellSettleDurationKey: EnvironmentKey {
    static let defaultValue: TimeInterval = 0.55
}

extension EnvironmentValues {
    /// Settle duration (color-trail end time) for table cells in the scrollable
    /// path. Set by `MarkdownTableContent.scrollableTable` so each cell's phase
    /// holder can schedule its own `.active → .past` transition without
    /// involving a parent-level snapshot publish.
    var markdownTableCellSettleDuration: TimeInterval {
        get { self[MarkdownTableCellSettleDurationKey.self] }
        set { self[MarkdownTableCellSettleDurationKey.self] = newValue }
    }
}

extension MarkdownTable {
    static let CoordinateSpaceName: String = "markdownview-table"
}

struct MarkdownTableRowSeparator<Separator: View>: View {
    var rowIndex: Int
    var separator: Separator

    @Environment(\.markdownTableCellPhasesByRow) private var phasesByRow

    init(rowIndex: Int, @ViewBuilder separator: () -> Separator) {
        self.rowIndex = rowIndex
        self.separator = separator()
    }

    var body: some View {
        separator
            .markdownTableRevealVisible(isVisible)
    }

    private var isVisible: Bool {
        guard let phasesByRow,
              rowIndex >= 0,
              rowIndex < phasesByRow.count
        else { return true }

        let rowPhases = phasesByRow[rowIndex]
        guard !rowPhases.isEmpty else { return true }
        return rowPhases.contains { $0 != .before }
    }
}

// MARK: - Table cell offset / phase propagation (non-scrollable path)

/// `MarkdownTable` publishes the per-row, per-column starting offsets so
/// `MarkdownTableRow` can apply the right `markdownTextOffsetBase` to each cell
/// without changing the public table-style protocol surface.
struct MarkdownTableCellOffsetsByRowKey: EnvironmentKey {
    static let defaultValue: [[Int]]? = nil
}

extension EnvironmentValues {
    var markdownTableCellOffsetsByRow: [[Int]]? {
        get { self[MarkdownTableCellOffsetsByRowKey.self] }
        set { self[MarkdownTableCellOffsetsByRowKey.self] = newValue }
    }
}

/// Per-row, per-column reveal phase. Computed once at the table level so
/// `MarkdownTableRow` (used by the public table-style protocol) can apply the
/// matching streaming gate to each cell.
struct MarkdownTableCellPhasesByRowKey: EnvironmentKey {
    static let defaultValue: [[MarkdownTableCellPhase]]? = nil
}

extension EnvironmentValues {
    var markdownTableCellPhasesByRow: [[MarkdownTableCellPhase]]? {
        get { self[MarkdownTableCellPhasesByRowKey.self] }
        set { self[MarkdownTableCellPhasesByRowKey.self] = newValue }
    }
}

extension View {
    func markdownTableRevealVisible(_ visible: Bool) -> some View {
        modifier(MarkdownTableRevealVisibilityModifier(visible: visible))
    }

    /// Gates a table cell's content based on its reveal phase.
    /// `.before` hides the content while keeping its layout footprint;
    /// `.past` cuts the streaming env so `_MarkdownText` renders plain Text
    /// (no TimelineView, no task, no renderer recreation per tick); `.active`
    /// leaves the env intact and applies the cell's offset base so the fade
    /// renderer maps its glyph indices to the right block-level positions.
    @ViewBuilder
    func markdownTablePhase(_ phase: MarkdownTableCellPhase, offsetBase: Int) -> some View {
        switch phase {
        case .before:
            self
                .environment(\.markdownImageIsInTableCell, true)
                .environment(\.markdownTableRevealTextContext, .hidden)
                .opacity(0)
        case .active:
            // `markdownStreamingFreshActivation` tells the fade renderer that
            // this cell mounts at the moment the frontier enters its window,
            // so glyphs already past the frontier on the very first draw
            // (`revealedLocal > 0`) are genuinely fresh and should animate
            // rather than snap. Without this, fast streaming where the
            // coordinator advances >1 char/tick would skip the leading chars
            // of every cell's fade-in.
            self
                .environment(\.markdownImageIsInTableCell, true)
                .environment(
                    \.markdownTableRevealTextContext,
                    .active(
                        offsetBase: offsetBase,
                        freshActivation: true,
                        minimumInterval: 1.0 / 20.0
                    )
                )
        case .past:
            self
                .environment(\.markdownImageIsInTableCell, true)
                .environment(\.markdownTableRevealTextContext, .past)
        }
    }
}

private struct MarkdownTableRevealVisibilityModifier: ViewModifier {
    var visible: Bool

    @Environment(\.markdownFadeReveal) private var fadeConfig
    @Environment(\.markdownStreaming) private var revealManager

    func body(content: Content) -> some View {
        let baseDuration = fadeConfig?.duration ?? 0.3
        let duration = revealManager?.adaptiveFadeDuration(baseDuration: baseDuration) ?? baseDuration
        content
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: duration), value: visible)
    }
}

struct MarkdownTableBody: View {
    var tableBody: Markdown.Table.Body
    
    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownFontGroup.tableBody) private var font
    
    var body: some View {
        ForEach(Array(tableBody.children.enumerated()), id: \.offset) { (_, row) in
            CmarkNodeVisitor(configuration: configuration)
                .makeBody(for: row)
                .font(font)
        }
    }
}


// MARK: - Auxiliary

fileprivate extension View {
    nonisolated func markdownTableCellStyleApplied() -> some View {
        modifier(MarkdownTableCellStylingViewModifier())
    }
}

fileprivate struct MarkdownTableCellStylingViewModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(
                MarkdownTableRowStyleCollectionPreference.self
            ) { styleCollection in
                if styleCollection.values.contains(where: { $0.backgroundStyle != nil }) {
                    ZStack(alignment: .topLeading) {
                        ForEach(styleCollection.rows) { row in
                            if let backgroundStyle = row.backgroundStyle {
                                resolveShape(row.backgroundShape, style: backgroundStyle)
                                    .offset(styleCollection.offset(for: row.position))
                                    .frame(height: styleCollection.heights[row.position.row])
                                    .frame(maxWidth: .infinity)
                                    
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .backgroundPreferenceValue(
                MarkdownTableCellStyleCollectionPreference.self
            ) { styleCollection in
                if styleCollection.cells.contains(where: { $0.backgroundStyle != nil }) {
                    ZStack(alignment: .topLeading) {
                        ForEach(styleCollection.cells) { cell in
                            if let backgroundStyle = cell.backgroundStyle {
                                resolveShape(cell.backgroundShape, style: backgroundStyle)
                                    .offset(styleCollection.offset(for: cell.position))
                                    .frame(
                                        width: styleCollection.widths[cell.position.column],
                                        height: styleCollection.heights[cell.position.row]
                                    )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .overlayPreferenceValue(
                MarkdownTableCellStyleCollectionPreference.self
            ) { styleCollection in
                if styleCollection.cells.contains(where: { $0.overlayContent != nil }) {
                    ZStack(alignment: .topLeading) {
                        ForEach(styleCollection.cells) { cell in
                            if let overlayContent = cell.overlayContent {
                                overlayContent
                                    .offset(styleCollection.offset(for: cell.position))
                                    .frame(
                                        width: styleCollection.widths[cell.position.column],
                                        height: styleCollection.heights[cell.position.row]
                                    )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
    }
    
    func resolveShape(_ shape: any Shape, style: some ShapeStyle) -> AnyView {
        func cast(_ shape: some Shape) -> AnyView {
            AnyView(shape.fill(style))
        }
        return _openExistential(shape, do: cast(_:))
    }
}

extension View {
    nonisolated package func _markdownTableStylesIgnored(_ ignored: Bool = true) -> some View {
        transformEnvironment(\.self) { environmentValues in
            if ignored {
                environmentValues.markdownTableCellPadding = .zero
                environmentValues.markdownTableCellBackgroundStyle = nil
                environmentValues.markdownTableCellOverlayContent = nil
                environmentValues.markdownTableRowBackgroundStyle = nil
            }
        }
    }
}
