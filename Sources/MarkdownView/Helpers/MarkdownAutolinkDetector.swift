//
//  MarkdownAutolinkDetector.swift
//  MarkdownView
//

import Foundation
import SwiftUI

enum MarkdownAutolinkDetector {
    nonisolated(unsafe) private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Builds an `AttributedString` with `.link / .underlineStyle / .foregroundColor`
    /// runs applied to every URL/email span detected in `plain`. Returns `nil`
    /// when no matches are found, so callers can keep the fast plain-string path.
    static func attributedString(
        from plain: String,
        linkTintColor: Color
    ) -> AttributedString? {
        guard let detector, !plain.isEmpty, mayHoldLink(plain) else { return nil }

        let nsText = plain as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = detector.matches(in: plain, options: [], range: fullRange)
        guard !matches.isEmpty else { return nil }

        var attributed = AttributedString(plain)
        var didApply = false

        for match in matches {
            guard let url = match.url else { continue }
            guard let stringRange = Range(match.range, in: plain) else { continue }

            let lower = plain.distance(from: plain.startIndex, to: stringRange.lowerBound)
            let upper = plain.distance(from: plain.startIndex, to: stringRange.upperBound)
            let attrLower = attributed.index(attributed.startIndex, offsetByCharacters: lower)
            let attrUpper = attributed.index(attributed.startIndex, offsetByCharacters: upper)
            let attrRange = attrLower..<attrUpper

            attributed[attrRange].link = url
            attributed[attrRange].underlineStyle = .single
            attributed[attrRange].foregroundColor = linkTintColor
            didApply = true
        }

        return didApply ? attributed : nil
    }

    /// Whether `plain` holds what a GFM autolink literal starts from: a scheme, `www.`, or an address.
    /// Only such text is scanned: those are the links the web makes of bare text, and the scan is a
    /// costly part of rendering a paragraph.
    static func mayHoldLink(_ plain: String) -> Bool {
        plain.contains("://") || plain.contains("@") || plain.range(of: "www.", options: .caseInsensitive) != nil
    }
}
