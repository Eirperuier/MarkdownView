//
//  InlineMathOrText.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/2/24.
//

import SwiftUI
import RegexBuilder
import Foundation
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

        if let latexMath = MathParser.standaloneDisplayMath(in: text) {
            return MarkdownNodeView {
                MarkdownDisplayMath(latexMath: latexMath)
                    .streamingRevealFadeIn()
            }
        }
        
        var segments: [InlineTextWithMath.Segment] = []
        var processingIndex = text.startIndex
        
        for math in mathReps {
            let range = math.range
            if processingIndex < range.lowerBound {
                segments.append(.text(String(text[processingIndex..<range.lowerBound])))
            }
            // 原始 $ 语法路径:revealUnits = 源文本长度(plainText 原样含定界符)。
            let source = String(text[range])
            segments.append(.math(source, revealUnits: source.count))
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
                    // revealUnits = 占位符全长(⸨imath: + id + ⸩),与 manager 的 plainText 计数一致。
                    let units = text.distance(from: prefixRange.lowerBound, to: suffixRange.upperBound)
                    segments.append(.math(latexText, revealUnits: units))
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
/// `Text` view outside streaming. During streaming, text runs are split out so
/// they can use the same per-character reveal renderer as normal Markdown text.
@MainActor
struct InlineTextWithMath: View {
    let segments: [Segment]
    
    enum Segment {
        case text(String)
        /// revealUnits = 该公式在 manager plain 坐标里占的单位数(app 管线下 = 占位符 ⸨imath:ID⸩ 的字符数,
        /// 原始 $ 语法下 = 源文本长度)。**不是 1**:manager 按 descriptor.plainText 计数,占位符 ~11 字符;
        /// 若按 1 记账,后续 run 的 offset 会比 manager 坐标小 ~10 → 公式后内容提前出现。
        case math(String, revealUnits: Int)
    }
    
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.markdownFontGroup) private var fontGroup
    @Environment(\.markdownTextOffsetBase) private var envOffsetBase
    @Environment(\.markdownTableRevealTextContext) private var tableRevealContext

    /// 表格 cell 内的偏移基准由 tableRevealContext 携带(scrollable 路径不设 markdownTextOffsetBase 环境)。
    /// `_MarkdownText` 读它 ✓,这里的数学 token 也必须读 —— 否则 cell 内公式的门槛是 `rc > 0+runOffset`,
    /// 挂载即满足 → 表格公式完全没有 reveal(原版遗留缺口,app 表格没跑过公式)。
    private var offsetBase: Int {
        if case let .active(base, _, _) = tableRevealContext { return base }
        return envOffsetBase
    }

    var body: some View {
        StreamingRevealCountReader { _, revealCount in
            if let revealCount, revealCount != Int.max {
                // Legacy/iOS-16 path needs the cell-relative count; the iOS 18+
                // `InlineRevealFlow` path delegates to children that subscribe
                // themselves so it doesn't need the adjustment here.
                let localRevealed = max(0, revealCount - offsetBase)
                if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
                    InlineRevealFlow(segments: segments)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.2), value: revealCount)
                } else {
                    revealedText(revealedUnits: localRevealed)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.2), value: revealCount)
                }
            } else {
                combinedText
            }
        }
    }
    
    private var combinedText: Text {
        composedText(revealedUnits: nil)
    }

    private func revealedText(revealedUnits: Int) -> Text {
        var remaining = revealedUnits
        return composedText(revealedUnits: &remaining)
    }

    private func composedText(revealedUnits: UnsafeMutablePointer<Int>?) -> Text {
        let xHeight = resolveXHeight(fontGroup.inlineMath)
        
        var result = Text("")
        for segment in segments {
            switch segment {
            case .text(let str):
                result = result + revealedText(str, remainingUnits: revealedUnits)
            case .math(let latex, let units):
                result = result + revealedMath(
                    latex,
                    xHeight: xHeight,
                    revealUnits: units,
                    remainingUnits: revealedUnits
                )
            }
        }
        return result
    }

    private func revealedText(
        _ text: String,
        remainingUnits: UnsafeMutablePointer<Int>?
    ) -> Text {
        guard let remainingUnits else {
            return Text(text)
        }

        let visibleCount = min(max(remainingUnits.pointee, 0), text.count)
        remainingUnits.pointee -= visibleCount

        guard visibleCount < text.count else {
            return Text(text)
        }

        let splitIndex = text.index(text.startIndex, offsetBy: visibleCount)
        return Text(String(text[..<splitIndex]))
            + Text(String(text[splitIndex...])).foregroundColor(.clear)
    }

    private func revealedMath(
        _ latex: String,
        xHeight: CGFloat,
        revealUnits: Int,
        remainingUnits: UnsafeMutablePointer<Int>?
    ) -> Text {
        guard let remainingUnits else {
            return renderedMath(latex, xHeight: xHeight, visible: true)
        }

        guard remainingUnits.pointee > 0 else {
            return renderedMath(latex, xHeight: xHeight, visible: false)
        }

        // 公式原子显隐:frontier 越过起点即整体可见,消耗其 plain 单位数(与 manager 计数对齐)。
        remainingUnits.pointee -= revealUnits
        return renderedMath(latex, xHeight: xHeight, visible: true)
    }

    private func renderedMath(
        _ latex: String,
        xHeight: CGFloat,
        visible: Bool
    ) -> Text {
        let preserveLatexColors = visible && MathParser.containsExplicitColorCommand(in: latex)
        let math = InlineLaTeXRenderer.renderToText(
            latex,
            xHeight: xHeight,
            displayScale: displayScale,
            renderingMode: preserveLatexColors ? .original : .template,
            resolvedCurrentColor: preserveLatexColors
                ? (colorScheme == .dark ? "#FFFFFF" : "#000000")
                : nil
        )

        return visible ? math : math.foregroundColor(.clear)
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

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
@MainActor
private struct InlineRevealFlow: View {
    let segments: [InlineTextWithMath.Segment]

    var body: some View {
        let runs = Self.makeRuns(from: segments)

        FlowLayout(verticleSpacing: 0) {
            ForEach(runs.indices, id: \.self) { index in
                runView(runs[index])
            }
        }
    }

    @ViewBuilder
    private func runView(_ run: InlineRevealRun) -> some View {
        switch run.content {
        case .text(let text):
            _MarkdownText(AttributedString(text), blockTextOffset: run.blockTextOffset)
        case .math(let latex):
            InlineMathRevealToken(latex: latex, blockTextOffset: run.blockTextOffset)
        }
    }

    private static func makeRuns(from segments: [InlineTextWithMath.Segment]) -> [InlineRevealRun] {
        var runs: [InlineRevealRun] = []
        var offset = 0

        for segment in segments {
            switch segment {
            case .text(let text):
                for textRun in splitTextIntoFlowRuns(text) where !textRun.isEmpty {
                    runs.append(
                        InlineRevealRun(
                            content: .text(textRun),
                            blockTextOffset: offset
                        )
                    )
                    offset += textRun.count
                }
            case .math(let latex, let units):
                runs.append(
                    InlineRevealRun(
                        content: .math(latex),
                        blockTextOffset: offset
                    )
                )
                // 与 manager 的 plain 计数对齐(占位符全长,非 1)——否则公式后的 run 偏移
                // 比 manager 坐标小 ~10,内容提前出现。
                offset += units
            }
        }

        return runs
    }

    private static func splitTextIntoFlowRuns(_ text: String) -> [String] {
        var runs: [String] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if isWhitespace(character) {
                let whitespaceStart = index
                consumeWhitespace(in: text, from: &index)
                appendWhitespace(String(text[whitespaceStart..<index]), to: &runs)
                continue
            }

            if isASCIIWordCharacter(character) {
                let tokenStart = index
                consumeASCIIWord(in: text, from: &index)
                var token = String(text[tokenStart..<index])
                token += consumeTrailingWhitespace(in: text, from: &index)
                runs.append(token)
                continue
            }

            let nextIndex = text.index(after: index)
            var token = String(text[index..<nextIndex])
            index = nextIndex
            token += consumeTrailingWhitespace(in: text, from: &index)
            runs.append(token)
        }

        return runs
    }

    private static func appendWhitespace(_ whitespace: String, to runs: inout [String]) {
        guard !whitespace.isEmpty else { return }

        if let lastIndex = runs.indices.last {
            runs[lastIndex] += whitespace
        } else {
            runs.append(whitespace)
        }
    }

    private static func consumeTrailingWhitespace(in text: String, from index: inout String.Index) -> String {
        let whitespaceStart = index
        consumeWhitespace(in: text, from: &index)
        return String(text[whitespaceStart..<index])
    }

    private static func consumeWhitespace(in text: String, from index: inout String.Index) {
        while index < text.endIndex, isWhitespace(text[index]) {
            index = text.index(after: index)
        }
    }

    private static func consumeASCIIWord(in text: String, from index: inout String.Index) {
        while index < text.endIndex, isASCIIWordCharacter(text[index]) {
            index = text.index(after: index)
        }
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else {
            return false
        }

        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}

private struct InlineRevealRun {
    enum Content {
        case text(String)
        case math(String)
    }

    let content: Content
    let blockTextOffset: Int
}

@MainActor
private struct InlineMathRevealToken: View {
    let latex: String
    let blockTextOffset: Int

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.markdownFontGroup) private var fontGroup
    @Environment(\.markdownTextOffsetBase) private var envOffsetBase
    @Environment(\.markdownTableRevealTextContext) private var tableRevealContext
    @Environment(\.markdownFadeReveal) private var fadeConfig

    /// 同 InlineTextWithMath:表格 cell 内偏移基准来自 tableRevealContext(.active 携带),
    /// 否则 token 门槛 rc>0+runOffset 挂载即满足 → 表格公式无 reveal。
    private var offsetBase: Int {
        if case let .active(base, _, _) = tableRevealContext { return base }
        return envOffsetBase
    }

    var body: some View {
        // 原子显隐统一走 StreamingRevealGate(与 marker/代码块/非文字块同款):
        // 只在越过阈值时翻转 @State(fresh-crossing 先隐一帧再显 → 动画必触发)、首帧同步判定不闪、
        // phase 切换重挂安全。阈值 = 公式锚点(offsetBase + run 偏移),经 env 传入。
        StreamingRevealGate { revealManager, visible in
            // fade 时长对齐文字(同 streamingRevealFadeIn):fadeConfig.duration 经 adaptive 缩放。
            let baseDuration = fadeConfig?.duration ?? 0.3
            let duration = revealManager?.adaptiveFadeDuration(baseDuration: baseDuration) ?? baseDuration
            renderedMath
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: duration), value: visible)
        }
        .environment(\.markdownTextOffsetBase, offsetBase + blockTextOffset)
    }

    private var renderedMath: Text {
        let preserveLatexColors = MathParser.containsExplicitColorCommand(in: latex)

        return InlineLaTeXRenderer.renderToText(
            latex,
            xHeight: resolveXHeight(fontGroup.inlineMath),
            displayScale: displayScale,
            renderingMode: preserveLatexColors ? .original : .template,
            resolvedCurrentColor: preserveLatexColors
                ? (colorScheme == .dark ? "#FFFFFF" : "#000000")
                : nil
        )
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
