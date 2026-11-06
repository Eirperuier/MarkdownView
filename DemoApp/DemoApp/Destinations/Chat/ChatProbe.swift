//
//  ChatProbe.swift
//  DemoApp
//
//  Looks at the chat page from outside, without the app coming to the front:
//  `-chatProbe <file>` reads one command at a time from that file and removes it.
//
//      shot <png path>     the window as it is now
//      scroll <delta>      moves the list, up for a negative delta
//      send                streams a reply
//      select <x> <y>      selects the sentence at a point in the window
//      quit                exits
//
//  A link tapped under a probe prints `LINK <url>` and opens nothing.
//

import MessagingUI
import UIKit

@MainActor
enum ChatProbe {
    static let file = UserDefaults.standard.string(forKey: "chatProbe")

    static func run(reader: TiledViewReader<String>, send: @escaping @MainActor () -> Void) async {
        guard let file else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            guard let command = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(atPath: file)
            let words = command.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
            switch words.first {
            case "shot": if words.count > 1 { shot(to: words[1]) }
            case "scroll":
                if words.count > 1, let delta = Double(words[1]) {
                    reader.scrollToContentOffsetY(reader.contentOffsetY() + delta, animated: false)
                }
            case "send": send()
            case "select":
                let numbers = (words.count > 1 ? words[1] : "").split(separator: " ").compactMap { Double($0) }
                if numbers.count == 2 { select(CGPoint(x: numbers[0], y: numbers[1])) }
            case "quit":
                fflush(stdout)
                exit(0)
            default: print("PROBE unknown \(command)")
            }
            fflush(stdout)
        }
    }

    /// Selects the word at a point in the window, as a drag would leave it. Injected mouse events
    /// don't reach an app that isn't active, so this doesn't try the gestures themselves.
    private static func select(_ point: CGPoint) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
              let view = textView(at: point, in: window) else {
            print("PROBE no text view there")
            return
        }
        let local = view.convert(point, from: window)
        guard let position = view.closestPosition(to: local),
              let line = view.tokenizer.rangeEnclosingPosition(position, with: .sentence, inDirection: .storage(.forward)) else { return }
        view.selectedTextRange = line
        print("PROBE selected \(view.selectedRange)")
    }

    /// What's hit is often a text view's own canvas, inside it.
    private static func textView(at point: CGPoint, in window: UIWindow) -> UITextView? {
        var view = window.hitTest(point, with: nil)
        while let current = view {
            if let textView = current as? UITextView { return textView }
            view = current.superview
        }
        return nil
    }

    private static func shot(to path: String) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first }).first else { return }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("PROBE shot \(path)")
    }
}
