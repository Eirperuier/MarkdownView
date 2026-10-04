//
//  ExtensionsDestination.swift
//  DemoApp
//
//  The syntax extensions from ios-flowith, rendered both ways: as plain MarkdownView and
//  as selectable stream blocks.
//

import SwiftUI
import MarkdownView

struct ExtensionsDestination: View {
    @State private var selectable = true

    static let text = #"""
    ## Extended heading
    ## Two same-level headings: a title and its subtitle

    Highlight ==this phrase== and mark :circle[关键词] or :wavy[a doubt] by hand.

    Cited inline [Apple](https://www.apple.com "cite") and folded [Swift](https://swift.org "cite") [GitHub](https://github.com "cite"); a plain [link](https://example.com) stays a link.

    - {🚀} Emoji bullet
    - {star.fill} SF Symbol bullet
    - {✅}中文不加空格也行
    - Ordinary bullet

    | Item | Price (USD) | Note |
    | --- | --- | --- |
    | Coffee | 4.5 | first<br>second |

    A footnote[^1] rides along.

    [^1]: Footnote definitions render as their own list.
    """#

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Selectable text", isOn: $selectable)
            Section {
                MarkdownView(Self.text)
            } header: {
                Text("MarkdownView").font(.headline)
            }
            Divider()
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MarkdownContent(Self.text).topLevelBlocks(), id: \.id) { descriptor in
                        MarkdownStreamBlockView(content: MarkdownContent(Self.text), descriptor: descriptor)
                    }
                }
                .markdownSelectableTextEnabled(selectable)
            } header: {
                Text("Stream blocks").font(.headline)
            }
        }
        .lineSpacing(5)
        .markdownTableHeaderDimsParentheticals()
        .environment(\.openURL, OpenURLAction { url in
            if let targets = MarkdownLinkChips.urls(from: url) {
                print("chip tapped:", targets)
                return .handled
            }
            return .systemAction
        })
    }

    /// What ios-flowith turns on before any markdown is parsed.
    @MainActor
    static func enableSyntax() {
        MarkdownLinkChips.isEnabled = true
        MarkdownHighlightSyntax.isEnabled = true
        MarkdownHighlightSyntax.backgroundColor = .orange
        MarkdownHighlightSyntax.foregroundColor = .white
        MarkdownPenMarkSyntax.isEnabled = true
        MarkdownLinkChips.placeholderIcon = { Image(systemName: "globe") }
    }
}
