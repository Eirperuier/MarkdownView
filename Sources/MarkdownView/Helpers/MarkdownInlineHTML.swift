//
//  MarkdownInlineHTML.swift
//  MarkdownView
//

import Foundation

enum MarkdownInlineHTML {
    static func replacementText(for rawHTML: String) -> String? {
        let trimmed = rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "<", trimmed.last == ">" else {
            return nil
        }

        var body = trimmed.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix("/") {
            body = body.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tagName = body
            .prefix { !$0.isWhitespace && $0 != "/" }
            .lowercased()

        switch tagName {
        case "br":
            return "\n"
        default:
            return nil
        }
    }
}
