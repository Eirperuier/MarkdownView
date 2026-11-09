//
//  AheadWork.swift
//  DemoApp
//
//  Rows made ahead of showing, as Telegram lays its nodes out ahead: work a list hands over for
//  a row coming soon, done one piece at a time while the main thread has nothing else to do and
//  the list isn't moving, in a place in the window out of sight (its stage) so what's made is
//  drawn for the window it will show in.
//

import UIKit

@MainActor
enum AheadWork {
    /// Whether the list is moving now: the work waits till it isn't.
    static var isBusy: (() -> Bool)?
    /// Where rows are made ahead and kept, in the window but out of sight: a view coming into a
    /// window is laid out and drawn again for it (its traits, its scale), the cost made ahead
    /// was to spare. Nil: off any window.
    static weak var stage: UIView?

    private static var waiting: [(key: String, work: () -> Void)] = []
    private static var idle: CFRunLoopObserver?

    static func isWaiting(_ key: String) -> Bool { waiting.contains { $0.key == key } }

    /// `work` for `key`, done when the main thread is idle; once for a key while it waits.
    static func add(_ key: String, _ work: @escaping () -> Void) {
        guard !isWaiting(key) else { return }
        waiting.append((key, work))
        guard idle == nil else { return }
        // Before the main run loop waits, in its default mode (not while a finger scrolls).
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { doOne() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        idle = observer
    }

    private static func doOne() {
        guard isBusy?() != true else { return }
        guard !waiting.isEmpty else {
            if let idle { CFRunLoopRemoveObserver(CFRunLoopGetMain(), idle, .defaultMode) }
            idle = nil
            return
        }
        waiting.removeFirst().work()
        // Another turn of the run loop for the next one.
        if !waiting.isEmpty { CFRunLoopWakeUp(CFRunLoopGetMain()) }
    }
}
