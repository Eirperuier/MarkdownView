//
//  SelectableLayoutTests.swift
//  MarkdownView
//

#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import MarkdownView

@MainActor
struct SelectableLayoutTests {
    /// Every text view is at least as tall as its own content at its own width.
    ///
    /// Needs a window. A package test on Mac Catalyst runs in a bare xctest process with
    /// no NSApplication, where creating a UIWindow throws; check Catalyst layout in the DemoApp.
    #if targetEnvironment(macCatalyst)
    nonisolated static let hasWindow = false
    #else
    nonisolated static let hasWindow = true
    #endif

    @Test(.enabled(if: hasWindow, "needs an app host on Mac Catalyst"), arguments: [
        "- Blocks keep their ids while the text grows, so nothing re-renders from scratch.",
        "1. Blocks keep their ids while the text grows, so nothing re-renders from scratch.",
        "Blocks keep their ids while the text grows, so nothing re-renders from scratch.",
        "> Quotes are selectable too, with the same look as before, across several lines of text.",
    ])
    func textViewsAreNotClipped(source: String) throws {
        var splitter = MarkdownBlockSplitter()
        let blocks = splitter.split(source)
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { MarkdownStreamBlockView($0) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        )
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<5 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let textViews = allSubviews(of: host.view).compactMap { $0 as? UITextView }
        try #require(!textViews.isEmpty)
        for textView in textViews where textView.bounds.width > 0 {
            let needed = textView.sizeThatFits(
                CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            ).height
            #expect(
                textView.bounds.height >= needed - 0.5,
                "\(textView.bounds.size) needs \(needed): \(textView.text ?? "")"
            )
        }
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
#endif
