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
}

@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var intervals: [CFTimeInterval] = []
    private var hitch: CFTimeInterval = 0
    private var budget: CFTimeInterval = 1.0 / 60
    /// Called on every frame while recording, before the driven step.
    var onFrame: (() -> Void)?
    private var step: ((CFTimeInterval) -> Bool)?
    private var stepDone: CheckedContinuation<Void, Never>?

    func start() {
        stop()
        intervals = []
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
        return FrameStats(
            frames: intervals.count,
            duration: duration,
            hitchMillisecondsPerSecond: duration > 0 ? hitch * 1000 / duration : 0,
            p50Milliseconds: percentile(0.5),
            p95Milliseconds: percentile(0.95),
            maxMilliseconds: (sorted.last ?? 0) * 1000,
            longFrames: intervals.filter { $0 > budget * 2 }.count,
            budgetMilliseconds: budget * 1000
        )
    }

    @objc private func tick(_ link: CADisplayLink) {
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
