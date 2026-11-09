//
//  DocScrollBench.swift
//  DemoApp
//
//  -docScrollBench SPEED: the page scrolled top to bottom and back at SPEED points a second
//  (a fling's), a step a frame, twice: the first time rows are made and measured, the second
//  they're known. Each late frame is logged with the rows that came into view in it, by kind,
//  to doctest.log as DOCBENCH lines; then the app quits.
//

import MessagingUI
import UIKit

@MainActor
final class DocScrollBench: NSObject {
    private let demo: DocDemo
    private let reader: TiledViewReader<String>
    private let speed: CGFloat
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var direction: CGFloat = 1
    private var pass = 0
    private var shown: Set<String> = []
    private var frames = 0, late = 0
    private var lost: CFTimeInterval = 0, worst: CFTimeInterval = 0
    private var gaps: [CFTimeInterval] = []
    /// Late frames' kinds of rows coming in, and how long they took, by kind.
    private var blame: [String: (count: Int, lost: CFTimeInterval)] = [:]
    private var lateLines: [String] = []
    private var finished: CheckedContinuation<Void, Never>?

    init(demo: DocDemo, reader: TiledViewReader<String>, speed: CGFloat) {
        self.demo = demo
        self.reader = reader
        self.speed = speed
    }

    func run() async {
        reader.scrollToContentOffsetY(top, animated: false)
        try? await Task.sleep(for: .seconds(1))
        for run in 0..<(Self.aroundCollection ? 6 : 2) {
            pass = run
            DocRowTimes.reset()
            await withCheckedContinuation { continuation in
                finished = continuation
                start()
            }
            report()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// -docBenchAround collection: only across the first collection, it coming in from below
    /// and going out again each pass, six times.
    private static let aroundCollection = UserDefaults.standard.string(forKey: "docBenchAround") == "collection"

    private var collectionFrame: CGRect? {
        demo.rows.first { $0.collection != nil }.flatMap { reader.frame(forItem: $0.id) }
    }

    private var top: CGFloat {
        let screen = reader.visibleContentHeight() ?? 800
        if Self.aroundCollection, let frame = collectionFrame { return max(0, frame.minY - screen * 2) }
        return demo.rows.first.flatMap { reader.frame(forItem: $0.id) }.map { $0.minY - 200 } ?? 0
    }

    private var bottom: CGFloat {
        let screen = reader.visibleContentHeight() ?? 600
        if Self.aroundCollection, let frame = collectionFrame { return frame.maxY + screen * 0.2 }
        let end = demo.rows.last.flatMap { reader.frame(forItem: $0.id)?.maxY } ?? 0
        return max(top, end - screen)
    }

    private func start() {
        (frames, late, lost, worst, gaps, blame, lateLines, direction, last) = (0, 0, 0, 0, [], [:], [], 1, 0)
        shown = visibleIDs()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else { return }
        let gap = now - last
        let frame = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        frames += 1
        gaps.append(gap)
        worst = max(worst, gap)
        let visible = visibleIDs()
        defer { DocRowTimes.frame = [:] }
        let came = visible.subtracting(shown)
        shown = visible
        if gap > frame * 1.5 {
            late += 1
            lost += gap - frame
            let kinds = Set(came.compactMap { id in demo.rows.first { $0.id == id }.map(Self.kind) })
            for kind in kinds.isEmpty ? ["(none came)"] : Array(kinds) {
                blame[kind, default: (0, 0)].count += 1
                blame[kind, default: (0, 0)].lost += gap - frame
            }
            let rows = came.compactMap { id in demo.rows.first { $0.id == id } }
                .map { "\(Self.kind($0)) \($0.source.prefix(24).replacingOccurrences(of: "\n", with: " "))" }
            let spent = DocRowTimes.frame.sorted { $0.value > $1.value }.map { String(format: "%@ %.0fms", $0.key as NSString, $0.value * 1000) }
            lateLines.append(String(format: "%.0fms at %.0f: %@ — rows: %@", gap * 1000, reader.contentOffsetY(), rows.joined(separator: " | ") as NSString,
                                    spent.joined(separator: ", ") as NSString))
        }
        // A step for the time that passed: the speed's, as a fling's, whatever the frame took.
        // At an end the list holds the offset where it can go no further: down, it turns; up, it's done.
        let offset = reader.contentOffsetY()
        let stuck = frames > 2 && abs(offset - asked) > 1 && abs(offset - previous) < 0.5
        previous = offset
        if stuck, direction > 0 { direction = -1 }
        var y = offset + direction * speed * CGFloat(min(gap, 0.1))
        if direction > 0, y >= bottom { y = bottom; direction = -1 }
        if direction < 0, y <= top || (stuck && frames > 4) {
            reader.scrollToContentOffsetY(top, animated: false)
            link.invalidate()
            self.link = nil
            finished?.resume()
            finished = nil
            return
        }
        asked = y
        reader.scrollToContentOffsetY(y, animated: false)
    }

    private var asked: CGFloat = 0
    private var previous: CGFloat = 0

    private func visibleIDs() -> Set<String> {
        let from = reader.contentOffsetY(), to = from + (reader.visibleContentHeight() ?? 800)
        return Set(demo.rows.lazy.filter { row in
            guard let frame = self.reader.frame(forItem: row.id) else { return false }
            return frame.maxY > from && frame.minY < to
        }.map(\.id))
    }

    static func kind(_ row: DocRow) -> String {
        if row.isStreaming { return "stream" }
        if let collection = row.collection { return collection.collection.currentView?.layout.chart == nil ? "collection" : "chart" }
        if row.recordFields != nil { return "record" }
        if let media = row.media { return row.run != nil && DocMediaRowContent.draws(media) ? "media" : "card" }
        if row.page != nil { return "page" }
        if row.table != nil { return "table" }
        if case .code = row.sourceKind { return "code" }
        if row.sourceKind == .math { return "math" }
        if row.text != nil { return "text" }
        return row.tree != nil ? "card" : "other"
    }

    private func report() {
        let sorted = gaps.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let seconds = gaps.reduce(0, +)
        docTestLog(String(format: "DOCBENCH pass %d (%@): %.1fs, frames %d, late %d, lost %.0fms (%.1fms/s), p95 %.1fms, worst %.0fms",
                          pass + 1, pass == 0 ? "cold" : "warm", seconds, frames, late, lost * 1000, seconds > 0 ? lost * 1000 / seconds : 0, p95 * 1000, worst * 1000))
        for (kind, value) in blame.sorted(by: { $0.value.lost > $1.value.lost }) {
            docTestLog(String(format: "DOCBENCH   %@: %d late, %.0fms", kind as NSString, value.count, value.lost * 1000))
        }
        for line in lateLines.prefix(40) { docTestLog("DOCBENCH     " + line) }
        DocRowTimes.report()
        let counts = HostedRowView.counts
        docTestLog("DOCBENCH   hosted: asked ahead \(counts.asked), made ahead \(counts.madeAhead), taken again \(counts.kept), made when shown \(counts.made)")
    }
}

/// Under the bench: a row's content timed, its configuring and measuring, by row and kind.
@MainActor
enum DocRowTimes {
    static var isOn = UserDefaults.standard.object(forKey: "docScrollBench") != nil
    private(set) static var times: [String: (kind: String, label: String, configure: Double, height: Double, configures: Int, heights: Int)] = [:]

    static func wrap(_ content: any TiledUIKitCellContent, row: DocRow) -> any TiledUIKitCellContent {
        guard isOn else { return content }
        return timed(content, row: row)
    }

    private static func timed<C: TiledUIKitCellContent>(_ content: C, row: DocRow) -> any TiledUIKitCellContent {
        Timed(inner: content, id: row.id, kind: DocScrollBench.kind(row), label: String(row.source.prefix(24)).replacingOccurrences(of: "\n", with: " "))
    }

    /// What rows took since the last frame, by kind and what (configure, height).
    static var frame: [String: Double] = [:]

    static func add(_ id: String, kind: String, label: String, configure: Double = 0, height: Double = 0) {
        if configure > 1e-6 { frame["\(kind) configure", default: 0] += configure }
        if height > 1e-6 { frame["\(kind) height", default: 0] += height }
        var entry = times[id] ?? (kind, label, 0, 0, 0, 0)
        entry.configure += configure
        entry.height += height
        if configure > 0 { entry.configures += 1 }
        if height > 0 { entry.heights += 1 }
        times[id] = entry
    }

    static func reset() { times = [:] }

    static func report() {
        var kinds: [String: (Double, Double, Int, Int)] = [:]
        for entry in times.values {
            var k = kinds[entry.kind] ?? (0, 0, 0, 0)
            k.0 += entry.configure; k.1 += entry.height; k.2 += entry.configures; k.3 += entry.heights
            kinds[entry.kind] = k
        }
        for (kind, k) in kinds.sorted(by: { $0.value.0 + $0.value.1 > $1.value.0 + $1.value.1 }) {
            docTestLog(String(format: "DOCBENCH   kind %@: configure %.0fms (%d), height %.0fms (%d)", kind as NSString, k.0 * 1000, k.2, k.1 * 1000, k.3))
        }
        for (_, entry) in times.sorted(by: { $0.value.configure + $0.value.height > $1.value.configure + $1.value.height }).prefix(15) {
            docTestLog(String(format: "DOCBENCH   row %@ %@: configure %.1fms (%d), height %.1fms (%d)", entry.kind as NSString, entry.label as NSString,
                              entry.configure * 1000, entry.configures, entry.height * 1000, entry.heights))
        }
    }

    private struct Timed<C: TiledUIKitCellContent>: TiledUIKitCellContent {
        let inner: C
        let id: String
        let kind: String
        let label: String

        var drivesRowMoves: Bool { inner.drivesRowMoves }
        static func makeRowView() -> C.RowView { C.makeRowView() }
        static func prepareForReuse(_ view: C.RowView) { C.prepareForReuse(view) }

        func configure(_ view: C.RowView, context: TiledUIKitCellContext) {
            let start = CACurrentMediaTime()
            inner.configure(view, context: context)
            DocRowTimes.add(id, kind: kind, label: label, configure: max(CACurrentMediaTime() - start, 1e-9))
        }

        func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
            let start = CACurrentMediaTime()
            defer { DocRowTimes.add(id, kind: kind, label: label, height: max(CACurrentMediaTime() - start, 1e-9)) }
            return inner.height(forWidth: width, traits: traits)
        }

        func prepareAhead(forWidth width: CGFloat, traits: UITraitCollection) { inner.prepareAhead(forWidth: width, traits: traits) }
        func isPreparingAhead(forWidth width: CGFloat, traits: UITraitCollection) -> Bool { inner.isPreparingAhead(forWidth: width, traits: traits) }
    }
}
