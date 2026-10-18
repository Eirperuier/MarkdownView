//
//  StreamingRevealCoordinator.swift
//  MarkdownView
//
//  Moved from ios-flowith (ViewModels/StreamingRevealCoordinator.swift); block ids are
//  generic instead of UUID.
//

import Foundation

/// How fast a ``StreamingRevealCoordinator`` reveals text.
public struct StreamingRevealRate: Equatable, Sendable {
    public var velocityMultiplier: Double
    public var finishingVelocityMultiplier: Double
    public var tickMilliseconds: Int

    public static let standard = StreamingRevealRate()
    /// Faster, for reasoning text the reader skims.
    public static let thinkingBlock = StreamingRevealRate(
        velocityMultiplier: 2.2,
        finishingVelocityMultiplier: 1.8,
        tickMilliseconds: 25
    )

    public init(
        velocityMultiplier: Double = 1.0,
        finishingVelocityMultiplier: Double = 1.0,
        tickMilliseconds: Int = 33
    ) {
        self.velocityMultiplier = max(0.1, velocityMultiplier)
        self.finishingVelocityMultiplier = max(0.1, finishingVelocityMultiplier)
        self.tickMilliseconds = max(8, tickMilliseconds)
    }

    var initialVelocity: Double {
        max(0.4, 2.0 * velocityMultiplier)
    }
}

/// Pacing constants (a generic class can't hold static stored properties).
private enum Pacing {
    static let velocityCurve: [(remaining: Double, velocity: Double)] = [
        (0, 0.15),
        (8, 0.35),
        (16, 0.75),
        (25, 1.15),
        (40, 2.4),
        (60, 4.5),
        (90, 8.2),
        (120, 10.2),
        (160, 12),
        (220, 18),
        (300, 27),
        (380, 37),
        (480, 48),
        (620, 58),
        (800, 70)
    ]
    static let fadeDurationScaleVelocityRange = 6.0...48.0
    /// finishQuickly 时,剩余未 reveal 字数超过此值就直接 snap(不再快速动画),
    /// 避免结束瞬间把 fade 扫过大量表格 cell 造成掉帧。
    static let finishSnapThreshold = 300

    static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

/// Coordinates streaming reveal animation across multiple markdown blocks.
///
/// Each block tracks its own `revealedCount` independently. The coordinator
/// advances the first unfinished block per animation tick (left-to-right
/// frontier), so growth in one block doesn't penalize siblings.
///
/// The coordinator decides how fast text appears and when it finishes; each block's
/// ``StreamingRevealManager`` carries the progress the renderers draw from.
@MainActor
public final class StreamingRevealCoordinator<BlockID: Hashable> {
    public typealias Rate = StreamingRevealRate

    private var finishing = false
    private var animationTask: Task<Void, Never>?

    private var rate: Rate
    private var smoothedVelocity: Double
    private var fractionalCarry: Double = 0
    private var frontierIndex = 0
    private var remainingRevealCount = 0
    private var lastSyncedGeneration: Int?

    private struct Entry {
        var length: Int
        let manager: StreamingRevealManager
    }

    private var orderedEntries: [(id: BlockID, entry: Entry)] = []
    private var managers: [BlockID: StreamingRevealManager] = [:]

    public init(rate: Rate = .standard) {
        self.rate = rate
        self.smoothedVelocity = rate.initialVelocity
    }

    // MARK: - Public API

    public func setRate(_ rate: Rate) {
        guard self.rate != rate else { return }
        self.rate = rate
        smoothedVelocity = max(smoothedVelocity, rate.initialVelocity)
        if remainingRevealCount > 0 {
            ensureAnimation()
        }
    }

    public func needsSync(generation: Int, force: Bool = false) -> Bool {
        force || lastSyncedGeneration != generation
    }

    public func syncBlocks(_ blocks: [(id: BlockID, plainTextCount: Int)], generation: Int? = nil, force: Bool = false) {
        if let generation, !force, lastSyncedGeneration == generation {
            return
        }

        var oldLengths: [BlockID: Int] = [:]
        oldLengths.reserveCapacity(orderedEntries.count)
        for (id, entry) in orderedEntries {
            oldLengths[id] = entry.length
        }

        var newOrdered: [(id: BlockID, entry: Entry)] = []
        newOrdered.reserveCapacity(blocks.count)

        for block in blocks {
            let mgr: StreamingRevealManager
            if let existing = managers[block.id] {
                mgr = existing
            } else {
                mgr = StreamingRevealManager()
                managers[block.id] = mgr
            }

            let oldLength = oldLengths[block.id] ?? 0
            remapRevealProgressIfLengthShrank(
                manager: mgr,
                oldLength: oldLength,
                newLength: block.plainTextCount
            )
            if block.plainTextCount > oldLength,
               mgr.revealedCount == Int.max {
                mgr.revealedCount = oldLength
            }

            newOrdered.append((id: block.id, entry: Entry(length: block.plainTextCount, manager: mgr)))
        }

        orderedEntries = newOrdered

        let liveIds = Set(newOrdered.map { $0.id })
        managers = managers.filter { liveIds.contains($0.key) }

        rebuildProgressState()

        if remainingRevealCount > 0 {
            ensureAnimation()
        }

        if let generation {
            lastSyncedGeneration = generation
        }
    }

    private func remapRevealProgressIfLengthShrank(
        manager: StreamingRevealManager,
        oldLength: Int,
        newLength: Int
    ) {
        guard oldLength > newLength,
              newLength > 0,
              manager.revealedCount != Int.max,
              manager.revealedCount >= newLength
        else { return }

        // During streaming, inline markdown can make AST plain text shrink
        // when syntax closes (`**bo` -> `**bold**`, `[x]` -> `[x](url)`, etc.).
        // Preserve the distance to the tail instead of interpreting the old
        // absolute reveal count in the new, shorter coordinate space.
        let oldRemaining = max(oldLength - manager.revealedCount, 1)
        manager.revealedCount = max(0, newLength - oldRemaining)
    }

    public func manager(for blockId: BlockID) -> StreamingRevealManager? {
        managers[blockId]
    }

    /// Returns an existing manager for the block, or lazily creates a fresh
    /// one (revealedCount=0) if none exists yet. Views in a live streaming
    /// context must always receive a non-nil manager — otherwise
    /// `StreamingRevealMarker` falls back to "visible" (the loaded-message
    /// default) and decorations flash before the frontier reaches the block.
    /// The newly created manager is kept until the next `syncBlocks` prunes
    /// it if the block doesn't appear in the live set.
    public func ensureManager(for blockId: BlockID) -> StreamingRevealManager {
        if let existing = managers[blockId] { return existing }
        let mgr = StreamingRevealManager()
        managers[blockId] = mgr
        return mgr
    }

    /// Instantly reveal all remaining text without animation.
    public func revealAll() {
        animationTask?.cancel()
        animationTask = nil
        for (_, entry) in orderedEntries {
            entry.manager.finishReveal(contentLength: entry.length)
        }
        frontierIndex = orderedEntries.count
        remainingRevealCount = 0
    }

    public func finishQuickly() {
        revealDetachedManagers()
        // The last block waits at its end while more may come (advanceFrontier): with nothing
        // left to reveal, it's done now.
        if remainingRevealCount == 0 {
            revealAll()
            return
        }
        // 结束时若还有大量未 reveal 的内容(典型:一大段表格还没扫到),继续按
        // finishing 的高 velocity 去「快速动画」会在几个 tick 内把 fade 扫过上百个
        // 表格 cell,造成大量掉帧。这种情况直接整体 snap(revealAll,无动画),
        // 瞬间完成、不再逐 cell 扫 fade。剩余量不大时仍走原来的快速淡入。
        if remainingRevealCount > Pacing.finishSnapThreshold {
            revealAll()
            return
        }
        finishing = true
        ensureAnimation()
    }

    public func reset() {
        animationTask?.cancel()
        animationTask = nil
        finishing = false
        smoothedVelocity = rate.initialVelocity
        fractionalCarry = 0
        orderedEntries.removeAll()
        managers.removeAll()
        frontierIndex = 0
        remainingRevealCount = 0
        lastSyncedGeneration = nil
    }

    // MARK: - Animation loop

    private func ensureAnimation() {
        guard animationTask == nil else { return }
        animationTask = Task { [weak self] in
            defer { self?.animationTask = nil }
            while let self, !Task.isCancelled {
                guard self.advanceFrontier() else { break }
                try? await Task.sleep(for: .milliseconds(self.rate.tickMilliseconds))
            }
            self?.finishing = false
            if let self {
                self.smoothedVelocity = self.rate.initialVelocity
            }
            self?.fractionalCarry = 0
        }
    }

    private func revealDetachedManagers() {
        let orderedIds = Set(orderedEntries.map(\.id))
        for (id, manager) in managers where !orderedIds.contains(id) && manager.revealedCount != Int.max {
            manager.revealedCount = Int.max
        }
    }

    /// Rebuilds reveal bookkeeping after parser sync. The animation tick then
    /// only touches the current frontier instead of scanning every block.
    private func rebuildProgressState() {
        frontierIndex = orderedEntries.count
        remainingRevealCount = 0

        for index in orderedEntries.indices {
            let entry = orderedEntries[index].entry
            let current = entry.manager.revealedCount
            if current == Int.max {
                continue
            }
            if current >= entry.length {
                if index != orderedEntries.indices.last || finishing {
                    entry.manager.finishReveal(contentLength: entry.length)
                }
                continue
            }

            if frontierIndex == orderedEntries.count {
                frontierIndex = index
            }
            remainingRevealCount += max(entry.length - current, 0)
        }
    }

    /// Advance the first (frontmost) non-fully-revealed block by one tick.
    /// Velocity is exponentially smoothed to avoid abrupt accel/decel when the
    /// backlog changes (content bursts, stream ending, finishQuickly switch).
    /// Returns false when no block needs further reveal.
    private func advanceFrontier() -> Bool {
        guard remainingRevealCount > 0 else { return false }

        let target = targetVelocity(remaining: remainingRevealCount)
        let diff = target - smoothedVelocity
        let factor = diff < 0 ? 0.35 : 0.15
        smoothedVelocity += diff * factor
        if !finishing, remainingRevealCount <= 25 {
            smoothedVelocity = min(smoothedVelocity, max(target, 0.25))
        }

        fractionalCarry += smoothedVelocity
        let charsThisTick = Int(fractionalCarry)
        guard charsThisTick > 0 else { return true }
        fractionalCarry -= Double(charsThisTick)

        while frontierIndex < orderedEntries.count {
            let entry = orderedEntries[frontierIndex].entry
            let current = entry.manager.revealedCount
            if current == Int.max || current >= entry.length {
                entry.manager.finishReveal(contentLength: entry.length)
                frontierIndex += 1
                continue
            }

            let missing = entry.length - current
            let advanced = min(charsThisTick, missing)
            let next = current + charsThisTick
            entry.manager.setAdaptiveFadeDurationScale(
                adaptiveFadeDurationScale(for: smoothedVelocity)
            )
            if next >= entry.length, frontierIndex == orderedEntries.count - 1, !finishing {
                // The last block, revealed as far as it has come: it waits at its end for more
                // (the words still streaming) instead of finishing, so what comes next goes on
                // from there. It finishes once a block follows it or the stream ends
                // (finishQuickly).
                entry.manager.revealedCount = entry.length
            } else if next >= entry.length {
                entry.manager.finishReveal(contentLength: entry.length)
                frontierIndex += 1
            } else {
                entry.manager.revealedCount = next
            }
            remainingRevealCount = max(remainingRevealCount - advanced, 0)
            return true
        }

        remainingRevealCount = 0
        return false
    }

    private func targetVelocity(remaining: Int) -> Double {
        let r = Double(remaining)
        if finishing {
            return max(5.0, r / 6.0) * rate.finishingVelocityMultiplier
        }
        if r <= 0 { return 0 }

        return interpolatedVelocity(for: r) * rate.velocityMultiplier
    }

    private func adaptiveFadeDurationScale(for velocity: Double) -> Double {
        let range = Pacing.fadeDurationScaleVelocityRange
        guard velocity > range.lowerBound else { return 1.0 }
        guard velocity < range.upperBound else { return 0.45 }

        let progress = Pacing.smoothstep(
            (velocity - range.lowerBound) / (range.upperBound - range.lowerBound)
        )
        return 1.0 - progress * 0.55
    }


    private func interpolatedVelocity(for remaining: Double) -> Double {
        guard let first = Pacing.velocityCurve.first,
              let last = Pacing.velocityCurve.last
        else { return 0 }

        if remaining <= first.remaining {
            return first.velocity
        }
        if remaining >= last.remaining {
            return last.velocity
        }

        for index in 1..<Pacing.velocityCurve.count {
            let upper = Pacing.velocityCurve[index]
            guard remaining <= upper.remaining else { continue }

            let lower = Pacing.velocityCurve[index - 1]
            let span = upper.remaining - lower.remaining
            guard span > 0 else { return upper.velocity }

            let progress = Pacing.smoothstep((remaining - lower.remaining) / span)
            return lower.velocity + (upper.velocity - lower.velocity) * progress
        }

        return last.velocity
    }
}
