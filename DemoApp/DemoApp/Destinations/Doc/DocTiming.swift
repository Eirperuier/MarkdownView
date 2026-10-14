//
//  DocTiming.swift
//  DemoApp
//
//  -docTiming YES: how long going into a document takes, step by step, printed as
//  `DOCTIME <ms since the start> <step>` (the start: the window's first document made, or
//  a page block opened).
//

import Foundation

@MainActor
enum DocTiming {
    static let isOn = UserDefaults.standard.bool(forKey: "docTiming")
    private static var start = CFAbsoluteTimeGetCurrent()
    private static var marked: Set<String> = []

    /// A new start: what follows is timed from here.
    static func begin(_ step: String) {
        guard isOn else { return }
        start = CFAbsoluteTimeGetCurrent()
        marked = []
        say("DOCTIME 0 \(step)")
    }

    /// The first row's body, and the main thread's first free turn after it (about when
    /// the first rows reach the screen).
    static func firstRow() {
        guard isOn, marked.insert("first row body").inserted else { return }
        mark("first row body")
        DispatchQueue.main.async { mark("main thread free after the first rows") }
    }

    /// Unbuffered, so a log read while the app runs has it.
    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// A step, once a start (`once`: only its first time).
    static func mark(_ step: String, once: Bool = false) {
        guard isOn, !once || marked.insert(step).inserted else { return }
        say("DOCTIME \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) \(step)")
    }
}
