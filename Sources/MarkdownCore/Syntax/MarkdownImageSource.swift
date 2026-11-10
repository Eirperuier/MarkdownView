//
//  MarkdownImageSource.swift
//  MarkdownCore
//
//  What a renderer reads from an image or a directive before it draws anything.
//

import Foundation
@preconcurrency import Markdown

public enum MarkdownImageSource {
    /// The caption: its title, or else its description. Nil inside a link, where the image is
    /// the link's content and a caption would read as part of it.
    public static func alternativeText(of image: Markdown.Image) -> String? {
        guard !(image.parent is Markdown.Link) else { return nil }
        if let title = image.title, !title.isEmpty { return title }
        return image.plainText.isEmpty ? nil : image.plainText
    }

    /// A relative path against the document's base.
    public static func resolved(_ url: URL, against base: URL) -> URL {
        URL(string: url.absoluteString, relativeTo: base)?.standardized.resolvingSymlinksInPath() ?? url
    }
}

public enum MarkdownSVGSource {
    /// The text with comments and the XML declaration off, so what's left starts with the tag.
    public static func normalized(_ text: String) -> String {
        var result = text
        for pattern in ["<![\\s\\S]+?>[\\s]*", "<[?]{1}[\\s\\S]*?[?]{1}>[\\s]*"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
                guard let range = Range(match.range, in: text) else { continue }
                result = result.replacingOccurrences(of: text[range], with: "")
            }
        }
        return result
    }

    public static func isSVG(_ text: String) -> Bool {
        normalized(text).starts(with: "<svg")
    }

    /// Whether the root tag names a width. With none, a drawing fills the room it's given.
    public static func hasWidth(_ text: String) -> Bool {
        let source = normalized(text)
        guard let end = source.firstIndex(of: ">") else { return false }
        return source[..<end].range(of: "\\swidth\\s*=", options: .regularExpression) != nil
    }
}

public extension BlockDirective {
    /// What a directive's renderer is given: its content as markdown.
    var markdownWrappedString: String {
        children.compactMap { $0.format() }.joined(separator: "\n")
    }
}
