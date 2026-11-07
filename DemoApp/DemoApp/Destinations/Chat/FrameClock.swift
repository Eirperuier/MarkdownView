//
//  FrameClock.swift
//  DemoApp
//
//  Records frame intervals with a display link and can drive work once per frame.
//

import UIKit

struct FrameStats {
    let frames: Int
    let duration: TimeInterval
    /// Time past each frame's deadline, per second of recording (Apple's hitch ratio).
    let hitchMillisecondsPerSecond: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double
    /// Frames that took more than twice their budget.
    let longFrames: Int
    let budgetMilliseconds: Double
    /// Main thread CPU between one frame and the next: how full each frame was, whatever the
    /// display did with it. Time a frame waited for the machine doesn't count.
    let frameCPU: FrameCPU
}

struct FrameCPU {
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maxMilliseconds: Double
    /// Share of frames that used more than half of an 8.3 ms frame, and more than all of it,
    /// and more than all of a 16.7 ms frame.
    let over4ms: Double
    let over8ms: Double
    let over16ms: Double
}

@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var intervals: [CFTimeInterval] = []
    private var frameCPUs: [Double] = []
    private var lastCPU: UInt64 = 0
    private var hitch: CFTimeInterval = 0
    private var budget: CFTimeInterval = 1.0 / 60
    /// Called on every frame while recording, before the driven step.
    var onFrame: (() -> Void)?
    private var step: ((CFTimeInterval) -> Bool)?
    private var stepDone: CheckedContinuation<Void, Never>?

    func start() {
        stop()
        intervals = []
        frameCPUs = []
        lastCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        hitch = 0
        lastTimestamp = nil
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Calls `step` with the time since the previous frame until it returns false.
    func drive(_ step: @escaping (CFTimeInterval) -> Bool) async {
        await withCheckedContinuation { continuation in
            self.step = step
            self.stepDone = continuation
        }
    }

    @discardableResult
    func stop() -> FrameStats {
        link?.invalidate()
        link = nil
        finishStep()
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] * 1000
        }
        let duration = intervals.reduce(0, +)
        let cpus = frameCPUs.sorted()
        func cpuPercentile(_ p: Double) -> Double {
            guard !cpus.isEmpty else { return 0 }
            return cpus[min(cpus.count - 1, Int(Double(cpus.count - 1) * p))]
        }
        func share(over limit: Double) -> Double {
            cpus.isEmpty ? 0 : Double(cpus.filter { $0 > limit }.count) / Double(cpus.count)
        }
        return FrameStats(
            frames: intervals.count,
            duration: duration,
            hitchMillisecondsPerSecond: duration > 0 ? hitch * 1000 / duration : 0,
            p50Milliseconds: percentile(0.5),
            p95Milliseconds: percentile(0.95),
            maxMilliseconds: (sorted.last ?? 0) * 1000,
            longFrames: intervals.filter { $0 > budget * 2 }.count,
            budgetMilliseconds: budget * 1000,
            frameCPU: FrameCPU(
                p50Milliseconds: cpuPercentile(0.5),
                p95Milliseconds: cpuPercentile(0.95),
                p99Milliseconds: cpuPercentile(0.99),
                maxMilliseconds: cpus.last ?? 0,
                over4ms: share(over: 4.15),
                over8ms: share(over: 8.33),
                over16ms: share(over: 16.67)
            )
        )
    }

    @objc private func tick(_ link: CADisplayLink) {
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if lastTimestamp != nil { frameCPUs.append(Double(cpu - lastCPU) / 1_000_000) }
        lastCPU = cpu
        let frameBudget = link.targetTimestamp - link.timestamp
        if frameBudget > 0 { budget = frameBudget }
        var delta: CFTimeInterval = 0
        if let lastTimestamp {
            delta = link.timestamp - lastTimestamp
            intervals.append(delta)
            // A frame that missed its deadline by more than half a frame counts as a hitch.
            if delta > budget * 1.5 { hitch += delta - budget }
        }
        lastTimestamp = link.timestamp
        onFrame?()
        if let step, !step(delta) { finishStep() }
    }

    private func finishStep() {
        step = nil
        stepDone?.resume()
        stepDone = nil
    }
}
