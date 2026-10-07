//
//  AutolinkDetectionTests.swift
//  MarkdownView
//

import SwiftUI
import Testing
@testable import MarkdownView

struct AutolinkDetectionTests {
    private func links(_ text: String) -> [URL] {
        guard let attributed = MarkdownAutolinkDetector.attributedString(from: text, linkTintColor: .blue) else {
            return []
        }
        return attributed.runs.compactMap(\.link)
    }

    @Test
    func gfmLiteralsBecomeLinks() {
        #expect(links("见 https://example.com/a 和 http://b.org") == [
            URL(string: "https://example.com/a")!, URL(string: "http://b.org")!,
        ])
        #expect(links("打开 www.example.com 看看").count == 1)
        #expect(links("联系 dev@example.com").count == 1)
    }

    @Test
    func textWithoutALiteralIsNotScanned() {
        // The web links no bare domain either.
        #expect(links("改了 workspaceTranscript.ts 和 example.com") == [])
        #expect(links("纯中文段落，没有链接。") == [])
        #expect(!MarkdownAutolinkDetector.mayHoldLink("ChatView.swift:42"))
        #expect(MarkdownAutolinkDetector.mayHoldLink("WWW.Example.com"))
    }
}
