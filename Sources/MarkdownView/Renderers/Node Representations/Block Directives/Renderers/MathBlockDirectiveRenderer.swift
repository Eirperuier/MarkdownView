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

@_spi(MarkdownMath)
public struct MarkdownDisplayMath: View {
    private enum Source {
        case identifier(UUID)
        case latex(String)
    }

    private var source: Source

    @Environment(\.markdownFontGroup.displayMath) private var font
    @Environment(\.markdownRendererConfiguration.math) private var math
    @Environment(\.markdownMathHeightCache) private var heightCache

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

    /// Persistent cache lookup. The cache itself enforces only-grow, so
    /// once any prior render of this LaTeX captured a peak intrinsic the
    /// value cannot regress — which is what makes the floor stable across
    /// re-renders even though `MarkdownNodeView`'s `AnyView` wrap resets
    /// every `@State` we might have put in this view.
    private var cachedHeight: CGFloat {
        guard let latexMath, let heightCache else { return 0 }
        return heightCache.height(forLatex: latexMath) ?? 0
    }

    /// Height the `minHeight` floor uses. No view-local growing state —
    /// the cache is the single source of truth.
    private var resolvedHeight: CGFloat {
        max(reservedHeight, cachedHeight)
    }

    private var shouldPreserveLatexColors: Bool {
        guard let latexMath else { return false }
        return MathParser.containsExplicitColorCommand(in: latexMath)
    }

    init(mathIdentifier: UUID) {
        self.source = .identifier(mathIdentifier)
    }

    @_spi(MarkdownMath)
    public init(latexMath: String) {
        self.source = .latex(latexMath)
    }

    /// `minHeight` is a floor, not a lock — LaTeXSwiftUI's `.blockMode`
    /// view refuses to render under any hard vertical constraint, so
    /// `.frame(minHeight:)` is the only frame shape that keeps the SVG
    /// visible. Stability is enforced via the persistent height cache
    /// (`markdownMathHeightCache`), which is only-grow internally so the
    /// floor on any repeat render already covers every intermediate the
    /// first render passed through.
    @_spi(MarkdownMath)
    public var body: some View {
        ScrollView(.horizontal) {
            latex
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
                    .background(latexHeightMeasurer)
                    .frame(maxWidth: .infinity, minHeight: resolvedHeight)
                    .geometryGroup()
                    .animation(.smooth(duration: 0.25), value: resolvedHeight)
                    .onPreferenceChange(LaTeXRenderedHeightKey.self) { h in
                        commitMeasuredHeight(h, latex: latexMath)
                    }
            } else {
                LaTeX(latexMath)
                    .renderingStyle(.empty)
                    .renderingAnimation(.easeIn)
                    .imageRenderingMode(shouldPreserveLatexColors ? .original : .template)
                    .ignoreStringFormatting()
                    .blockMode(.blockText)
                    .font(font)
                    .foregroundStyle(.primary)
                    .background(latexHeightMeasurer)
                    .frame(maxWidth: .infinity, minHeight: resolvedHeight)
                    .animation(.smooth(duration: 0.25), value: resolvedHeight)
                    .onPreferenceChange(LaTeXRenderedHeightKey.self) { h in
                        commitMeasuredHeight(h, latex: latexMath)
                    }
            }
        }
        #else
        EmptyView()
        #endif
    }

    /// GR sees LaTeX's **unconstrained** intrinsic size (no frame between
    /// LaTeX and the measurer). MathJax's transient mid-render layouts
    /// are explicitly what we want to capture — they're the heights the
    /// envelope must cover on future renders if we want zero jumps.
    private var latexHeightMeasurer: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: LaTeXRenderedHeightKey.self,
                    value: proxy.size.height
                )
        }
    }

    /// Forwards every preference fire to the cache; the cache enforces
    /// monotonic only-grow internally, so the tiny pre-MathJax stub (14pt)
    /// can't clobber a previously captured peak (e.g. 88pt). View-local
    /// only-grow would not work — `MarkdownNodeView`'s `AnyView` wrap
    /// resets `@State` on every render, so each cycle's local "current
    /// max" starts at 0 and any prior peak would be invisible to a guard
    /// that checked view state.
    private func commitMeasuredHeight(_ h: CGFloat, latex: String) {
        guard h > 0 else { return }
        heightCache?.setHeight(h, forLatex: latex)
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

private struct LaTeXRenderedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
