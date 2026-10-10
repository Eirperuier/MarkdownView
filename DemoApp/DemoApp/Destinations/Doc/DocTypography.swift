//
//  DocTypography.swift
//  DemoApp
//
//  The document's own type and rhythm, not a chat answer's: its fonts and line height,
//  and the space above each block by what it is and what comes before it. Headings
//  stand apart from the section before and hug what they lead; list items stay close;
//  code, math, tables, quotes and media get room around them.
//

import SwiftUI
import DocKit
import MarkdownView

enum DocTypography {
    /// The selectable path's fonts: body text, headings by level, inline code.
    static let fonts = MarkdownPlatformTypography(
        body: .init(.body),
        headings: [
            .init(.title1, weight: .bold),
            .init(.title2, weight: .bold),
            .init(.title3, weight: .semibold),
            .init(.headline, weight: .semibold),
        ],
        inlineCode: .init(.callout),
        tableBody: .init(.body)
    )
    /// Between the lines of a paragraph (body text about 1.7 lines high); a heading's
    /// lines stay closer.
    static let lineSpacing: CGFloat = 8
    static let headingLineSpacing: CGFloat = 3
    /// Above the first block and below the last.
    static let pageTop: CGFloat = 32
    static let pageBottom: CGFloat = 80
}

/// What a row is, as far as spacing goes.
enum DocRowRole: Equatable {
    case heading(level: Int)
    case paragraph
    case listItem
    /// Code, math, a table, a quote, a divider, an image, a card: set apart.
    case boxed

    init(_ kind: BlockKind) {
        switch kind {
        case .heading(let level): self = .heading(level: level)
        case .paragraph: self = .paragraph
        case .listItem: self = .listItem
        case .quote, .code, .math, .divider, .image, .link, .file, .card, .database: self = .boxed
        }
    }

    /// A row of the agent's layer, from its markdown.
    init(markdown: String) {
        let line = markdown.drop { $0 == " " }
        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
            self = .heading(level: hashes)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
                    || line.prefix { $0.isNumber }.count > 0 && line.drop { $0.isNumber }.hasPrefix(". ") {
            self = .listItem
        } else if ["```", "~~~", "$$", "|", ">", "![", "---", "***"].contains(where: line.hasPrefix) {
            self = .boxed
        } else {
            self = .paragraph
        }
    }

    var isHeading: Bool {
        if case .heading = self { true } else { false }
    }

    /// The space above a row of this role that follows one of `previous` (nil: the page's top).
    func spacing(after previous: DocRowRole?) -> CGFloat {
        guard let previous else { return DocTypography.pageTop }
        switch (previous, self) {
        case (.heading, .heading): return 16
        case (_, .heading(let level)): return [44, 34, 28][safe: level - 1] ?? 22
        case (.heading, _): return 14
        case (.listItem, .listItem): return 12
        case (.boxed, _), (_, .boxed): return 22
        default: return 16
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
