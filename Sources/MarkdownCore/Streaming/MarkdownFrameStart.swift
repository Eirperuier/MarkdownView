//
//  MarkdownFrameStart.swift
//  MarkdownView
//
//  Waits for the start of the next frame. Work the main thread does when it happens to arrive
//  can run across a vsync: UIKit then skips that vsync's display links, and every animation
//  on one misses a frame, however little the work was. Started at the frame's start, the same
//  work has the whole frame.
//

#if canImport(UIKit) && !os(watchOS)
import QuartzCore
import Foundation

@MainActor
final class MarkdownFrameStart: NSObject {
    static let shared = MarkdownFrameStart()

    /// A window that's hidden or in the background gets no frames: nobody waits past this.
    private static let longestWait: TimeInterval = 0.05

    private var link: CADisplayLink?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var deadline: DispatchWorkItem?

    func next() async {
        await withCheckedContinuation { waiters.append($0); arm() }
    }

    private func arm() {
        guard deadline == nil else { return }
        if let link {
            link.isPaused = false
        } else {
            let link = CADisplayLink(target: self, selector: #selector(fire))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longestWait, execute: deadline)
    }

    @objc private func fire() {
        link?.isPaused = true
        deadline?.cancel()
        deadline = nil
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }
}
#endif
