//
//  MarkdownAutolinkDetector.swift
//  MarkdownView
//

import Foundation
import SwiftUI

extension MarkdownAutolinkDetector {
    /// Builds an `AttributedString` with `.link / .underlineStyle / .foregroundColor`
    /// runs applied to every URL/email span detected in `plain`. Returns `nil`
    /// when no matches are found, so callers can keep the fast plain-string path.
    static func attributedString(
        from plain: String,
        linkTintColor: Color
    ) -> AttributedString? {
        let links = links(in: plain)
        guard !links.isEmpty else { return nil }

        var attributed = AttributedString(plain)

        for link in links {
            let attrLower = attributed.index(attributed.startIndex, offsetByCharacters: link.characters.lowerBound)
            let attrUpper = attributed.index(attributed.startIndex, offsetByCharacters: link.characters.upperBound)
            let attrRange = attrLower..<attrUpper

            attributed[attrRange].link = link.url
            attributed[attrRange].underlineStyle = .single
            attributed[attrRange].foregroundColor = linkTintColor
        }

        return attributed
    }
}
