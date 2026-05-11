//
//  MathBlockDirectiveRenderer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/12.
//

import Foundation
import SwiftUI
#if canImport(LaTeXSwiftUI)
import LaTeXSwiftUI
#endif

struct MathBlockDirectiveRenderer: BlockDirectiveRenderer {
    func makeBody(configuration: Configuration) -> some View {
        if let argument = configuration.arguments.first,
           let identifier = UUID(uuidString: argument.value) {
            MarkdownDisplayMath(mathIdentifier: identifier)
        } else {
            EmptyView()
        }
    }
}

struct MarkdownDisplayMath: View {
    private enum Source {
        case identifier(UUID)
        case latex(String)
    }

    private var source: Source

    @Environment(\.markdownFontGroup.displayMath) private var font
    @Environment(\.markdownRendererConfiguration.math) private var math

    private var latexMath: String? {
        switch source {
        case .identifier(let mathIdentifier):
            return math.displayMathStorage?[mathIdentifier]
        case .latex(let latex):
            return latex
        }
    }

    private var reservedHeight: CGFloat {
        guard let latexMath else { return 0 }
        return Self.estimatedReservedHeight(for: latexMath)
    }

    private var shouldPreserveLatexColors: Bool {
        guard let latexMath else { return false }
        return MathParser.containsExplicitColorCommand(in: latexMath)
    }

    init(mathIdentifier: UUID) {
        self.source = .identifier(mathIdentifier)
    }

    init(latexMath: String) {
        self.source = .latex(latexMath)
    }

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            ScrollView(.horizontal) {
                latex
            }
        } else {
            ScrollView(.horizontal) {
                latex
            }
        }
    }

    @ViewBuilder
    private var latex: some View {
        #if canImport(LaTeXSwiftUI)
        if let latexMath {
            if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
                LaTeX(latexMath)
                    .renderingStyle(.empty)
                    .renderingAnimation(.easeIn)
                    .imageRenderingMode(shouldPreserveLatexColors ? .original : .template)
                    .ignoreStringFormatting()
                    .blockMode(.blockText)
                    .font(font)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: reservedHeight)
                    .geometryGroup()
            } else {
                LaTeX(latexMath)
                    .renderingStyle(.empty)
                    .renderingAnimation(.easeIn)
                    .imageRenderingMode(shouldPreserveLatexColors ? .original : .template)
                    .ignoreStringFormatting()
                    .blockMode(.blockText)
                    .font(font)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: reservedHeight)
            }
        }
        #else
        EmptyView()
        #endif
    }

    private static func estimatedReservedHeight(for latex: String) -> CGFloat {
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
