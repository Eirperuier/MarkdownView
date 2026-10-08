//
//  AutolinkDetectionTests.swift
//  MarkdownView
//

import Foundation
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
    func bareDomainsBecomeLinks() {
        #expect(links("访问 apple.com 看看") == [URL(string: "http://apple.com")!])
        #expect(links("见 claude.ai") == [URL(string: "http://claude.ai")!])
        // File names stay text: the detector tells them from domains.
        #expect(links("改了 workspaceTranscript.ts 和 example.com") == [URL(string: "http://example.com")!])
        #expect(links("README.md 和 main.py") == [])
    }

    /// The filter only skips text the detector would find nothing in.
    @Test
    func skippedTextHoldsNoLink() throws {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let samples = [
            "访问 apple.com 看看", "例子.中国", "例子。中国", "192.168.1.1:8080", "localhost:3000/x", "mailto:a@b.co",
            "a＠b.com", "HTTPS://EXAMPLE.COM", "github.com/a/b", "t.co/x", "bit.ly/abc", "xn--fiqs8s.cn",
            "域名 www.例子.公司", "file:///tmp/x", "ftp://x.org", "Node.js", "v1.2.3", "ChatView.swift:42",
            "纯中文段落，没有链接。", "It ends here. Then: more", "10:30 到 11:00", "e.g. this",
        ]
        for text in samples where !MarkdownAutolinkDetector.mayHoldLink(text) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            #expect(detector.matches(in: text, range: range).isEmpty, "skipped \(text) holds a link")
        }
    }

    @Test
    func proseIsNotScanned() {
        #expect(!MarkdownAutolinkDetector.mayHoldLink("纯中文段落，没有链接。"))
        #expect(!MarkdownAutolinkDetector.mayHoldLink("第一句。第二句：没有地址"))
        #expect(!MarkdownAutolinkDetector.mayHoldLink("It ends here. Then: more, and so on."))
        #expect(MarkdownAutolinkDetector.mayHoldLink("访问 apple.com"))
        #expect(MarkdownAutolinkDetector.mayHoldLink("WWW.Example.com"))
    }
}
