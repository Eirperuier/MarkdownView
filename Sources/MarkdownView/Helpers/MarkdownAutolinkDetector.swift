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
        guard let detector, !plain.isEmpty else { return nil }

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
}
