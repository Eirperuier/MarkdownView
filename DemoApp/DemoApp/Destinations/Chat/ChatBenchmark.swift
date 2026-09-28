//
//  ChatBenchmark.swift
//  DemoApp
//
//  Scripted scenarios over the chat list, measured frame by frame:
//  cold load, load with cached heights, a fast scroll sweep, a streamed reply and,
//  on the Mac, window resizes. Results show in the page and print as `BENCH {json}` lines.
//
//  Run unattended with `-chatBenchmark <exchanges>`: the app opens the chat page,
//  runs every scenario, prints the results and exits.
//

import SwiftUI
import MessagingUI

/// Measured heights by row content and width, fed back to the list as height hints.
/// Keyed by content, as flowith's cache was: a row that changed (a streaming block)
/// must not get its old height back.
@MainActor
final class ChatHeightCache {
    private var heights: [Key: CGFloat] = [:]
    var isEnabled = true

    private struct Key: Hashable {
        let id: String
        let content: Int
        let width: Int
    }

    func height(for row: ChatRow, width: CGFloat) -> CGFloat? {
        isEnabled ? heights[key(row, width)] : nil
    }

    func record(_ height: CGFloat, for row: ChatRow, width: CGFloat) {
        heights[key(row, width)] = height
    }

    func removeAll() {
        heights = [:]
    }

    private func key(_ row: ChatRow, _ width: CGFloat) -> Key {
        let content: Int
        switch row.kind {
        case .prompt(let text): content = text.hashValue
        case .block(let block): content = block.source.hashValue
        }
        return Key(id: row.id, content: content, width: Int(width.rounded()))
    }
}

/// Watches the rows on screen frame by frame: any move the scroll didn't ask for, or a
/// height change, is jitter.
@MainActor
final class JitterProbe {
    /// Screen shift the scroll asked for since the last sample (content moves up as the offset grows).
    var intendedShift: CGFloat = 0
    private(set) var jitterFrames = 0
    private(set) var maxDeviation: CGFloat = 0
    private var previous: [String: CGRect] = [:]

    func reset() {
        intendedShift = 0
        jitterFrames = 0
        maxDeviation = 0
        previous = [:]
    }

    func sample(_ reader: TiledViewReader<String>) {
        guard let height = reader.containerView?.bounds.height, height > 0 else { return }
        let offset = reader.contentOffsetY()
        let visible = CGRect(x: 0, y: offset, width: 100_000, height: height)
        var screen: [String: CGRect] = [:]
        for (id, frame) in reader.contentFrames(intersecting: visible) {
            screen[id] = frame.offsetBy(dx: 0, dy: -offset)
        }
        var deviation: CGFloat = 0
        for (id, now) in screen {
            guard let before = previous[id] else { continue }
            deviation = max(
                deviation,
                abs(now.minY - (before.minY + intendedShift)),
                abs(now.height - before.height)
            )
        }
        if deviation > 0.5 { jitterFrames += 1 }
        maxDeviation = max(maxDeviation, deviation)
        previous = screen
        intendedShift = 0
    }
}

@MainActor
@Observable
final class ChatBenchmark {
    struct Result: Identifiable {
        let id = UUID()
        let scenario: String
        let wallMilliseconds: Double
        let stats: FrameStats
        let jitterFrames: Int
        let maxJitter: CGFloat

        var line: String {
            String(
                format: "%-8@ %7.0fms  hitch %5.1fms/s  p95 %5.1f  max %6.1f  long %3d/%d  jitter %3d (%.0fpt)",
                scenario as NSString, wallMilliseconds, stats.hitchMillisecondsPerSecond,
                stats.p95Milliseconds, stats.maxMilliseconds, stats.longFrames, stats.frames,
                jitterFrames, maxJitter
            )
        }
    }

    static var autorunExchanges: Int? {
        let value = UserDefaults.standard.integer(forKey: "chatBenchmark")
        return value > 0 ? value : nil
    }

    private(set) var isRunning = false
    private(set) var results: [Result] = []
    private(set) var header = ""

    @ObservationIgnored private let clock = FrameClock()
    @ObservationIgnored private let jitter = JitterProbe()
    @ObservationIgnored private weak var reader: TiledViewReader<String>?
    @ObservationIgnored private var layoutWaiters: [CheckedContinuation<Void, Never>] = []

    /// Call from the list's content layout callback.
    func contentLayoutChanged() {
        let waiters = layoutWaiters
        layoutWaiters = []
        waiters.forEach { $0.resume() }
    }

    func run(
        exchanges: Int,
        conversation: ChatConversation,
        reader: TiledViewReader<String>,
        heightCache: ChatHeightCache
    ) async {
        guard !isRunning else { return }
        isRunning = true
        results = []
        defer { isRunning = false }
        self.reader = reader

        conversation.seed(0)
        heightCache.removeAll()
        await settle()
        header = "\(Self.platform) · \(exchanges) exchanges"

        // Cold: no height known. Parsing happens first, as a store would have it ready.
        conversation.seed(exchanges)
        conversation.hide()
        await settle()
        heightCache.removeAll()
        await measure("load") {
            conversation.restore()
            await self.nextLayout()
            await self.settle()
        }
        header += " · \(conversation.rows.count) rows"

        // Nothing touched: whatever the list still does after loading (measuring, say).
        await measure("idle") {
            await self.settle(3)
        }

        // Same rows again: heights come from the cache.
        conversation.hide()
        await settle()
        await measure("reload") {
            conversation.restore()
            await self.nextLayout()
            await self.settle()
        }

        await measure("scroll") {
            await self.sweep(reader: reader, conversation: conversation, distance: 20_000, speed: 3_000)
        }

        await measure("stream") {
            await conversation.stream(ChatCorpus.longReply, every: .milliseconds(30))
            await self.settle(0.6)
        }

        #if targetEnvironment(macCatalyst)
        await measure("resize") {
            await self.resizeWindow(times: 6)
        }
        #endif
    }

    // MARK: Scenarios

    /// Scrolls up by `distance` (or to the top) and back down to the bottom at `speed` points per second.
    private func sweep(
        reader: TiledViewReader<String>,
        conversation: ChatConversation,
        distance: CGFloat,
        speed: CGFloat
    ) async {
        let start = reader.contentOffsetY()
        var goingUp = true
        var bounds: (top: CGFloat, bottom: CGFloat)?
        var framesSinceBounds = 0
        await clock.drive { delta in
            // Frame lookups by id scan the list; refresh the edges now and then, not every frame.
            if bounds == nil || framesSinceBounds >= 30 {
                let rows = conversation.rows
                guard let first = rows.first, let last = rows.last,
                      let top = reader.frame(forItem: first.id)?.minY,
                      let bottom = reader.frame(forItem: last.id)?.maxY
                else { return false }
                bounds = (top, bottom)
                framesSinceBounds = 0
            }
            framesSinceBounds += 1
            guard let (top, bottom) = bounds else { return false }
            let visible = reader.visibleContentHeight() ?? 0
            let offset = reader.contentOffsetY()
            let step = speed * CGFloat(delta)
            if goingUp {
                let target = max(start - distance, top)
                let next = max(offset - step, target)
                self.jitter.intendedShift += offset - next
                reader.scrollToContentOffsetY(next, animated: false)
                if offset - step <= target { goingUp = false }
                return true
            }
            let target = max(top, bottom - visible)
            let next = min(offset + step, target)
            self.jitter.intendedShift += offset - next
            reader.scrollToContentOffsetY(next, animated: false)
            return offset + step < target
        }
    }

    #if targetEnvironment(macCatalyst)
    private func resizeWindow(times: Int) async {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let original = scene.effectiveGeometry.systemFrame
        for index in 0..<times {
            var frame = original
            frame.size.width = index.isMultiple(of: 2) ? max(700, original.width - 400) : original.width
            scene.requestGeometryUpdate(.Mac(systemFrame: frame))
            await settle(0.5)
        }
        scene.requestGeometryUpdate(.Mac(systemFrame: original))
        await settle(0.5)
    }
    #endif

    // MARK: Measuring

    private func measure(_ scenario: String, _ body: () async -> Void) async {
        clock.start()
        // Let the clock tick first: a stall in the very first frame would go unrecorded.
        await settle(0.1)
        jitter.reset()
        clock.onFrame = { [weak self] in
            guard let self, let reader = self.reader else { return }
            self.jitter.sample(reader)
        }
        let start = CACurrentMediaTime()
        await body()
        let wall = (CACurrentMediaTime() - start) * 1000
        clock.onFrame = nil
        let result = Result(
            scenario: scenario,
            wallMilliseconds: wall,
            stats: clock.stop(),
            jitterFrames: jitter.jitterFrames,
            maxJitter: jitter.maxDeviation
        )
        results.append(result)
        print("BENCH", json(result))
    }

    private func nextLayout() async {
        await withCheckedContinuation { layoutWaiters.append($0) }
    }

    private func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func json(_ result: Result) -> String {
        let stats = result.stats
        let fields: [(String, Any)] = [
            ("platform", "\"\(Self.platform)\""),
            ("scenario", "\"\(result.scenario)\""),
            ("wall_ms", String(format: "%.1f", result.wallMilliseconds)),
            ("frames", stats.frames),
            ("budget_ms", String(format: "%.2f", stats.budgetMilliseconds)),
            ("hitch_ms_per_s", String(format: "%.2f", stats.hitchMillisecondsPerSecond)),
            ("p50_ms", String(format: "%.2f", stats.p50Milliseconds)),
            ("p95_ms", String(format: "%.2f", stats.p95Milliseconds)),
            ("max_ms", String(format: "%.1f", stats.maxMilliseconds)),
            ("long_frames", stats.longFrames),
            ("jitter_frames", result.jitterFrames),
            ("max_jitter_pt", String(format: "%.1f", result.maxJitter)),
        ]
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    static var platform: String {
        #if targetEnvironment(macCatalyst)
        "catalyst"
        #elseif targetEnvironment(simulator)
        "ios-simulator"
        #else
        "ios"
        #endif
    }
}
