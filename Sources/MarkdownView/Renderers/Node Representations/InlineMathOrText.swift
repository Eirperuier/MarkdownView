//
//  InlineMathOrText.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/2/24.
//

import SwiftUI
import RegexBuilder
#if canImport(LaTeXSwiftUI)
import LaTeXSwiftUI
import MathJaxSwift
#endif

#if os(iOS) || os(visionOS)
import UIKit
#else
import Cocoa
#endif

@preconcurrency
@MainActor
struct InlineMathOrText {
    var text: String
    
    @preconcurrency
    @MainActor
    func makeBody(configuration: MarkdownRendererConfiguration) -> MarkdownNodeView {
        #if canImport(LaTeXSwiftUI)
        guard !text.isEmpty else { return MarkdownNodeView(text) }
        
        let prefix = MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix
        if let inlineStorage = configuration.math.inlineMathStorage,
           !inlineStorage.isEmpty,
           text.contains(prefix)
        {
            let segments = parseSegments(inlineStorage: inlineStorage)
            if segments.contains(where: { if case .math = $0 { return true }; return false }) {
                return MarkdownNodeView {
                    InlineTextWithMath(segments: segments)
                }
            } else {
                return MarkdownNodeView(text)
            }
        }
        
        let mathParser = MathParser(text: text)
        let mathReps = mathParser.mathRepresentations
        guard !mathReps.isEmpty else { return MarkdownNodeView(text) }
        
        var segments: [InlineTextWithMath.Segment] = []
        var processingIndex = text.startIndex
        
        for math in mathReps {
            let range = math.range
            if processingIndex < range.lowerBound {
                segments.append(.text(String(text[processingIndex..<range.lowerBound])))
            }
            segments.append(.math(String(text[range])))
            processingIndex = range.upperBound
        }
        if processingIndex < text.endIndex {
            segments.append(.text(String(text[processingIndex..<text.endIndex])))
        }
        
        return MarkdownNodeView {
            InlineTextWithMath(segments: segments)
        }
        #else
        return MarkdownNodeView(text)
        #endif
    }
    
    #if canImport(LaTeXSwiftUI)
    private func parseSegments(
        inlineStorage: [String: String]
    ) -> [InlineTextWithMath.Segment] {
        let prefix = MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix
        let suffix = MarkdownRendererConfiguration.Math.inlinePlaceholderSuffix
        
        var segments: [InlineTextWithMath.Segment] = []
        var searchStart = text.startIndex
        
        while searchStart < text.endIndex {
            guard let prefixRange = text.range(of: prefix, range: searchStart..<text.endIndex) else {
                let remaining = String(text[searchStart..<text.endIndex])
                if !remaining.isEmpty {
                    segments.append(.text(remaining))
                }
                break
            }
            
            if searchStart < prefixRange.lowerBound {
                segments.append(.text(String(text[searchStart..<prefixRange.lowerBound])))
            }
            
            let afterPrefix = prefixRange.upperBound
            if let suffixRange = text.range(of: suffix, range: afterPrefix..<text.endIndex) {
                let placeholderId = String(text[afterPrefix..<suffixRange.lowerBound])
                if let latexText = inlineStorage[placeholderId] {
                    segments.append(.math(latexText))
                } else {
                    let fallback = String(text[prefixRange.lowerBound..<suffixRange.upperBound])
                    segments.append(.text(fallback))
                }
                searchStart = suffixRange.upperBound
            } else {
                let remaining = String(text[prefixRange.lowerBound..<text.endIndex])
                segments.append(.text(remaining))
                break
            }
        }
        
        return segments
    }
    #endif
}

#if canImport(LaTeXSwiftUI)
/// Renders a mix of plain text and inline LaTeX as a single concatenated
/// `Text` view, giving native text layout (wrapping, baseline alignment).
@MainActor
struct InlineTextWithMath: View {
    let segments: [Segment]
    
    enum Segment {
        case text(String)
        case math(String)
    }
    
    @Environment(\.displayScale) private var displayScale
    @Environment(\.markdownFontGroup) private var fontGroup
    
    var body: some View {
        combinedText
    }
    
    private var combinedText: Text {
        let xHeight = resolveXHeight(fontGroup.inlineMath)
        
        var result = Text("")
        for segment in segments {
            switch segment {
            case .text(let str):
                result = result + Text(str)
            case .math(let latex):
                result = result + InlineLaTeXRenderer.renderToText(
                    latex,
                    xHeight: xHeight,
                    displayScale: displayScale
                )
            }
        }
        return result
    }
    
    private func resolveXHeight(_ font: Font) -> CGFloat {
        #if os(iOS) || os(visionOS)
        let style: UIFont.TextStyle
        switch font {
        case .largeTitle: style = .largeTitle
        case .title:      style = .title1
        case .title2:     style = .title2
        case .title3:     style = .title3
        case .headline:   style = .headline
        case .subheadline: style = .subheadline
        case .callout:    style = .callout
        case .caption:    style = .caption1
        case .caption2:   style = .caption2
        case .footnote:   style = .footnote
        default:          style = .body
        }
        return UIFont.preferredFont(forTextStyle: style).xHeight
        #else
        return NSFont.preferredFont(forTextStyle: .body).xHeight
        #endif
    }
}
#endif
