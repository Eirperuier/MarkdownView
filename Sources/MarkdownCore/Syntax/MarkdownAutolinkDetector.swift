//
//  MarkdownAutolinkDetector.swift
//  MarkdownView
//

import Foundation

public enum MarkdownAutolinkDetector {
    nonisolated(unsafe) private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Every URL or email detected in `plain`, as character offsets into it, in the order
    /// they come. Empty when there's none.
    public static func links(in plain: String) -> [(url: URL, characters: Range<Int>)] {
        guard let detector, !plain.isEmpty, mayHoldLink(plain) else { return [] }

        let nsText = plain as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = detector.matches(in: plain, options: [], range: fullRange)

        var links: [(url: URL, characters: Range<Int>)] = []
        for match in matches {
            guard let url = match.url else { continue }
            guard let stringRange = Range(match.range, in: plain) else { continue }

            let lower = plain.distance(from: plain.startIndex, to: stringRange.lowerBound)
            let upper = plain.distance(from: plain.startIndex, to: stringRange.upperBound)
            links.append((url, lower..<upper))
        }
        return links
    }

    /// Whether `plain` can hold anything the detector links, so text that can't is never
    /// scanned (the scan is a costly part of rendering a paragraph). Every link the detector
    /// finds has an address's `@`, or a `.` or `:` right before a letter or digit: a domain
    /// (`apple.com`, bare ones too), an IP, a scheme (`https:`, `:` also before `/`). A
    /// sentence's full stop or a label's colon is followed by a space, so prose goes unscanned.
    public static func mayHoldLink(_ plain: String) -> Bool {
        var previous: Unicode.Scalar = " "
        for scalar in plain.unicodeScalars {
            if scalar == "@" || scalar == "\u{FF20}" { return true }
            // ASCII only: the detector links no domain written with a fullwidth or ideographic
            // full stop, and Chinese prose runs straight on after "。".
            if previous == "." || previous == ":",
               scalar.properties.isAlphabetic || scalar.properties.numericType != nil || (previous == ":" && scalar == "/") {
                return true
            }
            previous = scalar
        }
        return false
    }
}
