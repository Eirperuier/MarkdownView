//
//  MarkdownDisplayMathHeight.swift
//  MarkdownCore
//
//  The height set aside for a display formula before it's drawn, from its source. Every
//  renderer sets aside the same, so a formula takes the same room in each.
//

import Foundation

public enum MarkdownDisplayMathHeight {
    public static func reserved(for latex: String) -> CGFloat {
        let source = latex
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rowBreaks = texRowBreakCount(in: source)
        let rowCount = rowBreaks + 1
        var height: CGFloat = 48

        if hasTallEnvironment(in: source) {
            height = max(height, CGFloat(rowCount) * 26 + 24)
        }
        if source.contains(#"\frac"#) || source.contains(#"\dfrac"#) {
            height += 16
        }
        if source.contains(#"\sum"#) || source.contains(#"\int"#) || source.contains(#"\lim"#) {
            height += 10
        }
        if source.contains(#"\sqrt"#) {
            height += 6
        }

        return min(max(height, 48), 180)
    }

    private static func hasTallEnvironment(in source: String) -> Bool {
        [
            "matrix",
            "pmatrix",
            "bmatrix",
            "Bmatrix",
            "vmatrix",
            "Vmatrix",
            "cases",
            "aligned",
            "gathered",
            "split",
            "array",
        ].contains { environment in
            source.contains(#"\begin{\#(environment)}"#)
        }
    }

    private static func texRowBreakCount(in source: String) -> Int {
        var count = 0
        var index = source.startIndex

        while index < source.endIndex {
            guard source[index] == "\\" else {
                index = source.index(after: index)
                continue
            }

            let nextIndex = source.index(after: index)
            guard nextIndex < source.endIndex, source[nextIndex] == "\\" else {
                index = nextIndex
                continue
            }

            let afterNextIndex = source.index(after: nextIndex)
            if afterNextIndex < source.endIndex,
               isASCIIControlWordLetter(source[afterNextIndex]) {
                index = afterNextIndex
                continue
            }

            count += 1
            index = afterNextIndex
        }

        return count
    }

    private static func isASCIIControlWordLetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else {
            return false
        }

        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}
