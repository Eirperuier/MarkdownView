//
//  ChatBenchmark.swift
//  DemoApp
//
//  Scripted scenarios over the chat list, measured frame by frame:
//  cold load, load with cached heights, a fast scroll sweep, a streamed reply,
//  on the Mac window resizes, and a paged conversation loading older pages. Results show in the page and print as `BENCH {json}` lines.
//
//  Run unattended with `-chatBenchmark <exchanges>`: the app opens the chat page,
//  runs every scenario, prints the results and exits. `-chatBenchmarkOnly pages,page-rest`
//  times only the named scenarios (the others still run, untimed: later ones start from
//  where they leave the list). `-chatScrollSpeed <points per second>` sets the scroll
//  sweep's speed (3000 by default). `-chatOpen YES` opens on the chat page, to try it by hand.
//  `-chatRenderer uikit|swiftui` picks the text rows' renderer (swiftui by default),
//  `-chatCorpus text` a conversation of only text.
//

import MarkdownUIKit
import SwiftUI
import MessagingUI
import Darwin
import os

/// Measured heights by row, content, width and text size, fed back to the list as height
/// hints, and kept on disk as a chat that's stored locally keeps them with its messages: a
/// conversation opened again, in this run or the next, lays out with no row measured. Keyed by
/// content, as flowith's cache was: a row that changed (a streaming block) must not get its old
/// height back.
@MainActor
final class ChatHeightCache {
    /// One for the app, as a store of messages is: a page shown again finds what it measured.
    /// A benchmark keeps its own, in memory, so a run measures what it means to.
    static let shared = ChatHeightCache(file: ChatBenchmark.autorunExchanges == nil ? defaultFile : nil)

    private static var defaultFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("chat-row-heights.json")
    }

    private var heights: [String: CGFloat] = [:]
    private let file: URL?
    private var saveQueued = false
    var isEnabled = true

    init(file: URL? = nil) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            heights = stored
        }
    }

    func height(for row: ChatRow, width: CGFloat) -> CGFloat? {
        isEnabled ? heights[key(row, width)] : nil
    }

    func record(_ height: CGFloat, for row: ChatRow, width: CGFloat) {
        let key = key(row, width)
        guard heights[key] != height else { return }
        heights[key] = height
        save()
    }

    func removeAll() {
        heights = [:]
        save()
    }

    /// Written once a burst of measuring settles, off the main thread.
    private func save() {
        guard let file, !saveQueued else { return }
        saveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            saveQueued = false
            guard let data = try? JSONEncoder().encode(heights) else { return }
            DispatchQueue.global(qos: .utility).async { try? data.write(to: file, options: .atomic) }
        }
    }

    /// The same across runs: Swift's `hashValue` is seeded per process.
    private func key(_ row: ChatRow, _ width: CGFloat) -> String {
        let content: String
        switch row.kind {
        case .prompt(let text): content = text
        case .block(let block): content = block.source
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in content.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let category = UIApplication.shared.preferredContentSizeCategory.rawValue
        return "\(row.id)|\(String(hash, radix: 36))|\(Int(width.rounded()))|\(category)"
    }
}

/// Watches the rows on screen frame by frame: any move the scroll didn't ask for, or a
/// height change, is jitter. A frame where the list's width changed is skipped: rows rewrap then.
@MainActor
final class JitterProbe {
    /// Screen shift the scroll asked for since the last sample (content moves up as the offset grows).
    var intendedShift: CGFloat = 0
    private(set) var jitterFrames = 0
    private(set) var maxDeviation: CGFloat = 0
    private var previous: [String: CGRect] = [:]
    private var previousWidth: CGFloat = 0

    func reset() {
        intendedShift = 0
        jitterFrames = 0
        maxDeviation = 0
        previous = [:]
        previousWidth = 0
    }

    func sample(_ reader: TiledViewReader<String>) {
        guard let bounds = reader.containerView?.bounds, bounds.height > 0 else { return }
        let height = bounds.height
        defer { previousWidth = bounds.width }
        if bounds.width != previousWidth { previous = [:] }
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

/// Each row's rendered height, as the row itself lays out (reported by the row view).
@MainActor
final class ChatRenderedHeights {
    /// The size each row last rendered at. The width tells a row's cell from another host
    /// rendering the same row off screen at another width (measuring, or pooled).
    var sizes: [String: CGSize] = [:]
}

/// Watches for rows whose layout height stays different from the height they render at:
/// the list then overlaps rows or leaves gaps. Self-sizing settles within a frame or two,
/// so only a mismatch lasting `tolerance` counts.
@MainActor
final class StaleHeightProbe {
    private(set) var staleFrames = 0
    private(set) var maxMismatch: CGFloat = 0
    private var mismatchSince: [String: CFTimeInterval] = [:]
    private let tolerance: CFTimeInterval = 0.25

    func reset() {
        staleFrames = 0
        maxMismatch = 0
        mismatchSince = [:]
    }

    func sample(_ reader: TiledViewReader<String>, rendered: ChatRenderedHeights) {
        guard let height = reader.containerView?.bounds.height, height > 0 else { return }
        let offset = reader.contentOffsetY()
        let now = CACurrentMediaTime()
        var stale: CGFloat = 0
        var mismatched = Set<String>()
        for (id, frame) in reader.contentFrames(intersecting: CGRect(x: 0, y: offset, width: 100_000, height: height)) {
            guard let renderedSize = rendered.sizes[id], abs(renderedSize.width - frame.width) < 1 else { continue }
            let renderedHeight = renderedSize.height
            let mismatch = abs(renderedHeight - frame.height)
            guard mismatch > 1 else { continue }
            mismatched.insert(id)
            let since = mismatchSince[id] ?? now
            mismatchSince[id] = since
            if now - since > tolerance { stale = max(stale, mismatch) }
        }
        mismatchSince = mismatchSince.filter { mismatched.contains($0.key) }
        if stale > 0 { staleFrames += 1 }
        maxMismatch = max(maxMismatch, stale)
    }
}

@MainActor
@Observable
final class ChatBenchmark {
    struct Result: Identifiable {
        let id = UUID()
        let scenario: String
        let wallMilliseconds: Double
        /// Main thread CPU time: the work itself, which a busy machine doesn't skew as it
        /// does frame times.
        let cpuMilliseconds: Double
        let stats: FrameStats
        let jitterFrames: Int
        let maxJitter: CGFloat
        let staleFrames: Int
        let maxStale: CGFloat
        /// The process's footprint: the most seen in the scenario, and at its end.
        let peakFootprintMB: Double
        let endFootprintMB: Double

        var line: String {
            String(
                format: "%-8@ %7.0fms  hitch %5.1fms/s  p95 %5.1f  max %6.1f  long %3d/%d  jitter %3d (%.0fpt)  stale %3d (%.0fpt)",
                scenario as NSString, wallMilliseconds, stats.hitchMillisecondsPerSecond,
                stats.p95Milliseconds, stats.maxMilliseconds, stats.longFrames, stats.frames,
                jitterFrames, maxJitter, staleFrames, maxStale
            )
        }
    }

    static var autorunExchanges: Int? {
        let value = UserDefaults.standard.integer(forKey: "chatBenchmark")
        return value > 0 ? value : nil
    }

    /// The scroll sweep's speed, points per second.
    static var scrollSpeed: CGFloat {
        let value = UserDefaults.standard.double(forKey: "chatScrollSpeed")
        return value > 0 ? value : 3_000
    }

    /// Scenarios to time; nil times all of them.
    static var onlyScenarios: Set<String>? {
        UserDefaults.standard.string(forKey: "chatBenchmarkOnly")
            .map { Set($0.split(separator: ",").map(String.init)) }
    }

    private(set) var isRunning = false
    private(set) var results: [Result] = []
    private(set) var header = ""

    @ObservationIgnored private let clock = FrameClock()
    @ObservationIgnored private let jitter = JitterProbe()
    @ObservationIgnored private let stale = StaleHeightProbe()
    @ObservationIgnored private var renderedHeights: ChatRenderedHeights?
    @ObservationIgnored private weak var reader: TiledViewReader<String>?
    @ObservationIgnored private var layoutWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var peakFootprint: Double = 0

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
        heightCache: ChatHeightCache,
        renderedHeights: ChatRenderedHeights
    ) async {
        guard !isRunning else { return }
        self.renderedHeights = renderedHeights
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
        printMix(conversation: conversation, exchanges: exchanges)

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

        ChatCards.hold(conversation.rows)
        await measure("scroll") {
            await self.sweep(reader: reader, conversation: conversation, distance: 20_000, speed: Self.scrollSpeed)
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

        // A reply streamed right after the conversation opens (nothing scrolled or measured yet).
        conversation.seed(0)
        heightCache.removeAll()
        await settle()
        conversation.seed(exchanges)
        await settle(1)
        await measure("stream-fresh") {
            await conversation.stream(ChatCorpus.longReply, every: .milliseconds(30))
            await self.settle(0.6)
        }

        // Paged: the latest page first, older pages as the list reaches the top, none measured before.
        await openPaged(exchanges, conversation: conversation, heightCache: heightCache)
        await measure("pages") {
            await self.climb(reader: reader, conversation: conversation, speed: 2_000)
        }

        // A page arriving while the list rests at the top: the jump there (which starts the
        // fetch) isn't timed, only the page landing.
        await openPaged(exchanges, conversation: conversation, heightCache: heightCache)
        reader.scrollToContentOffsetY(reader.contentOffsetY() - 100_000, animated: false)
        await settle(0.1)
        await measure("page-rest") {
            await self.settle(1)
        }
    }

    private func openPaged(_ exchanges: Int, conversation: ChatConversation, heightCache: ChatHeightCache) async {
        conversation.seed(0)
        heightCache.removeAll()
        await settle()
        conversation.seed(exchanges, loaded: ChatDestination.pageSize)
        await settle(1)
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

    /// Scrolls up at `speed` like a finger holding the list against its top: pages load as
    /// the top is reached, until nothing older is left.
    private func climb(reader: TiledViewReader<String>, conversation: ChatConversation, speed: CGFloat) async {
        var framesAtTop = 0
        await clock.drive { delta in
            let offset = reader.contentOffsetY()
            reader.scrollToContentOffsetY(offset - speed * CGFloat(delta), animated: false)
            // Only what the scroll itself moved is intended; anything the list does later is jitter.
            let moved = reader.contentOffsetY()
            self.jitter.intendedShift += offset - moved
            framesAtTop = moved < offset - 0.5 ? 0 : framesAtTop + 1
            return conversation.hasOlder || framesAtTop < 30
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

    private static let signposter = OSSignposter(subsystem: "DemoApp", category: "ChatBenchmark")

    private func measure(_ scenario: String, _ body: () async -> Void) async {
        FrameMarks.scenario = scenario
        if let only = Self.onlyScenarios, !only.contains(scenario) {
            // Untimed, but the clock still drives the scenarios that scroll frame by frame.
            clock.start()
            await body()
            clock.stop()
            return
        }
        clock.start()
        // Let the clock tick first: a stall in the very first frame would go unrecorded.
        await settle(0.1)
        jitter.reset()
        stale.reset()
        peakFootprint = Self.footprintMB()
        clock.onFrame = { [weak self] in
            guard let self, let reader = self.reader else { return }
            self.jitter.sample(reader)
            self.peakFootprint = max(self.peakFootprint, Self.footprintMB())
            if let rendered = self.renderedHeights { self.stale.sample(reader, rendered: rendered) }
        }
        // An interval per scenario, to line Instruments traces (Animation Hitches, say) up with it.
        let interval = Self.signposter.beginInterval("scenario", "\(scenario)")
        // To time a `sample` of one scenario: stdout goes to a file, so it's flushed by hand.
        print("BENCHSTART \(scenario)")
        fflush(stdout)
        let start = CACurrentMediaTime()
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let counters = Self.processCounters()
        await body()
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
        let countersEnd = Self.processCounters()
        let wall = (CACurrentMediaTime() - start) * 1000
        Self.signposter.endInterval("scenario", interval)
        clock.onFrame = nil
        let result = Result(
            scenario: scenario,
            wallMilliseconds: wall,
            cpuMilliseconds: cpu,
            stats: clock.stop(),
            jitterFrames: jitter.jitterFrames,
            maxJitter: jitter.maxDeviation,
            staleFrames: stale.staleFrames,
            maxStale: stale.maxMismatch,
            peakFootprintMB: max(peakFootprint, Self.footprintMB()),
            endFootprintMB: Self.footprintMB()
        )
        results.append(result)
        print("BENCH", json(result, instructions: countersEnd.instructions - counters.instructions, cycles: countersEnd.cycles - counters.cycles))
    }

    /// Which rows the conversation is made of, under this renderer.
    private func printMix(conversation: ChatConversation, exchanges: Int) {
        let rows = conversation.rows
        let uikit = rows.filter(\.drawsInUIKit).count
        let prompts = rows.filter { if case .prompt = $0.kind { true } else { false } }.count
        // What the hosted rows are, by kind.
        var hosted: [String: Int] = [:]
        for row in rows where !row.drawsInUIKit {
            if case .block(let block) = row.kind { hosted[String(describing: block.descriptor.kind), default: 0] += 1 } else { hosted["prompt", default: 0] += 1 }
        }
        let hostedKinds = hosted.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        print("BENCHMIX {\"renderer\":\"\(ChatRenderer.current.rawValue)\",\"corpus\":\"\(UserDefaults.standard.string(forKey: "chatCorpus") ?? "mixed")\",\"exchanges\":\(exchanges),\"rows\":\(rows.count),\"uikit\":\(uikit),\"swiftui\":\(rows.count - uikit),\"prompts\":\(prompts),\"hosted\":{\(hostedKinds)}}")
    }

    /// What the system charges the process for, in megabytes.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private func nextLayout() async {
        await withCheckedContinuation { layoutWaiters.append($0) }
    }

    private func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The process's instructions and cycles so far. CPU time moves with the cores' speed, which
    /// a thread with less to do gets less of; these don't.
    private static func processCounters() -> (instructions: UInt64, cycles: UInt64) {
        typealias Rusage = @convention(c) (Int32, Int32, UnsafeMutablePointer<rusage_info_v4>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return (0, 0) }
        var info = rusage_info_v4()
        guard unsafeBitCast(symbol, to: Rusage.self)(getpid(), RUSAGE_INFO_V4, &info) == 0 else { return (0, 0) }
        return (info.ri_instructions, info.ri_cycles)
    }

    private func json(_ result: Result, instructions: UInt64, cycles: UInt64) -> String {
        let stats = result.stats
        let fields: [(String, Any)] = [
            ("platform", "\"\(Self.platform)\""),
            ("scenario", "\"\(result.scenario)\""),
            ("wall_ms", String(format: "%.1f", result.wallMilliseconds)),
            ("cpu_ms", String(format: "%.1f", result.cpuMilliseconds)),
            ("fcpu_p50", String(format: "%.2f", result.stats.frameCPU.p50Milliseconds)),
            ("fcpu_p95", String(format: "%.2f", result.stats.frameCPU.p95Milliseconds)),
            ("fcpu_p99", String(format: "%.2f", result.stats.frameCPU.p99Milliseconds)),
            ("fcpu_max", String(format: "%.2f", result.stats.frameCPU.maxMilliseconds)),
            ("fcpu_over4", String(format: "%.4f", result.stats.frameCPU.over4ms)),
            ("fcpu_over8", String(format: "%.4f", result.stats.frameCPU.over8ms)),
            ("fcpu_over16", String(format: "%.4f", result.stats.frameCPU.over16ms)),
            ("main_minstr", String(format: "%.0f", stats.frameWork.totalMillionInstructions)),
            ("finstr_p50", String(format: "%.0f", stats.frameWork.instructionsP50)),
            ("finstr_p95", String(format: "%.0f", stats.frameWork.instructionsP95)),
            ("finstr_p99", String(format: "%.0f", stats.frameWork.instructionsP99)),
            ("fcyc_p50", String(format: "%.0f", stats.frameWork.cyclesP50)),
            ("fcyc_p95", String(format: "%.0f", stats.frameWork.cyclesP95)),
            ("fcyc_p99", String(format: "%.0f", stats.frameWork.cyclesP99)),
            ("minstr", instructions / 1_000_000),
            ("mcycles", cycles / 1_000_000),
            ("frames", stats.frames),
            ("budget_ms", String(format: "%.2f", stats.budgetMilliseconds)),
            ("hitch_ms_per_s", String(format: "%.2f", stats.hitchMillisecondsPerSecond)),
            ("p50_ms", String(format: "%.2f", stats.p50Milliseconds)),
            ("p95_ms", String(format: "%.2f", stats.p95Milliseconds)),
            ("max_ms", String(format: "%.1f", stats.maxMilliseconds)),
            ("long_frames", stats.longFrames),
            ("jitter_frames", result.jitterFrames),
            ("max_jitter_pt", String(format: "%.1f", result.maxJitter)),
            ("stale_frames", result.staleFrames),
            ("max_stale_pt", String(format: "%.1f", result.maxStale)),
            ("peak_mb", String(format: "%.1f", result.peakFootprintMB)),
            ("end_mb", String(format: "%.1f", result.endFootprintMB)),
            ("renderer", "\"\(ChatRenderer.current.rawValue)\""),
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
