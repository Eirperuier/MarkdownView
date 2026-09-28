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
    @Test(arguments: [
        "- Blocks keep their ids while the text grows, so nothing re-renders from scratch.",
        "1. Blocks keep their ids while the text grows, so nothing re-renders from scratch.",
        "Blocks keep their ids while the text grows, so nothing re-renders from scratch.",
        "> Quotes are selectable too, with the same look as before, across several lines of text.",
    ])
    func textViewsAreNotClipped(source: String) throws {
        var splitter = MarkdownBlockSplitter()
        let blocks = splitter.split(source)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIHostingController(rootView:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { MarkdownStreamBlockView($0) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
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
        window.isHidden = true
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
#endif
