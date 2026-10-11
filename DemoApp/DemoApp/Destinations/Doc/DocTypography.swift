//
//  DocTypography.swift
//  DemoApp
//
//  The document's own type and rhythm, not a chat answer's: its fonts and line height,
//  and the space above each block by what it is and what comes before it. Headings
//  stand apart from the section before and hug what they lead; list items stay close;
//  code, math, tables, quotes and media get room around them; links and files
//  follow one another closely.
//

import SwiftUI
import DocKit
import MarkdownView

enum DocTypography {
    /// On the Mac the page's text reads at Craft's size: the app is drawn smaller there
    /// (scaled as an iPad's), and Craft's Mac text, measured against ours, is this much
    /// larger: body text 1.16 times, headings 1.24 times.
    #if targetEnvironment(macCatalyst)
    static let textScale: CGFloat = 1.16
    static let headingScale: CGFloat = 1.24
    #else
    static let textScale: CGFloat = 1
    static let headingScale: CGFloat = 1
    #endif

    /// The selectable path's fonts: body text, headings by level, inline code.
    static let fonts = MarkdownPlatformTypography(
        body: .init(.body, scale: textScale),
        headings: [
            .init(.title1, weight: .bold, scale: headingScale),
            .init(.title2, weight: .bold, scale: headingScale),
            .init(.title3, weight: .semibold, scale: headingScale),
            .init(.headline, weight: .semibold, scale: textScale),
        ],
        inlineCode: .init(.callout, scale: textScale),
        tableBody: .init(.body, scale: textScale)
    )
    /// A caption's: smaller text, drawn secondary.
    static var captionFonts: MarkdownPlatformTypography {
        var fonts = fonts
        fonts.body = .init(.footnote, scale: textScale)
        fonts.inlineCode = .init(.caption1, scale: textScale)
        return fonts
    }
    /// Between the lines of a paragraph (body text about 1.7 lines high); a heading's
    /// and a caption's lines stay closer.
    static let lineSpacing: CGFloat = 8
    static let headingLineSpacing: CGFloat = 3
    static let captionLineSpacing: CGFloat = 4
    /// Above the first block and below the last.
    static let pageTop: CGFloat = 32
    static let pageBottom: CGFloat = 80
}

/// What a row is, as far as spacing goes.
enum DocRowRole: Equatable {
    case heading(level: Int)
    case paragraph
    case caption
    case listItem
    /// Code, math, a table, a quote, a divider, an image, a card: set apart.
    case boxed
    /// A link or a file: set apart, but close to the next one (Craft's).
    case media

    init(_ kind: BlockKind) {
        switch kind {
        case .heading(let level): self = .heading(level: level)
        case .paragraph: self = .paragraph
        case .caption: self = .caption
        case .listItem: self = .listItem
        case .link, .file: self = .media
        case .quote, .code, .math, .divider, .image, .card, .database: self = .boxed
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

    /// Between a row's lines.
    var lineSpacing: CGFloat {
        switch self {
        case .heading: DocTypography.headingLineSpacing
        case .caption: DocTypography.captionLineSpacing
        default: DocTypography.lineSpacing
        }
    }

    /// The space above a row of this role that follows one of `previous` (nil: the page's top).
    func spacing(after previous: DocRowRole?) -> CGFloat {
        guard let previous else { return DocTypography.pageTop }
        switch (previous, self) {
        case (.heading, .heading): return 16
        case (_, .heading(let level)): return [44, 34, 28][safe: level - 1] ?? 22
        case (.heading, _): return 14
        case (.listItem, .listItem): return 12
        case (.media, .media): return 8
        case (.boxed, _), (_, .boxed), (.media, _), (_, .media): return 22
        default: return 16
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
