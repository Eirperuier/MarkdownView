//
//  DefaultCodeBlockStyle.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/3/25.
//

import SwiftUI
import UIKit

/// Default code block style that applies to a MarkdownView.
public struct DefaultCodeBlockStyle: CodeBlockStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DefaultMarkdownCodeBlock(codeBlockConfiguration: configuration)
    }
}

extension CodeBlockStyle where Self == DefaultCodeBlockStyle {
    static public var `default`: DefaultCodeBlockStyle { .init() }
}

// MARK: - Correct range-based line splitting

extension AttributedString {
    func splitByLines() -> [AttributedString] {
        let ns = NSAttributedString(self)
        let fullString = ns.string as NSString
        let length = fullString.length
        var lines: [AttributedString] = []
        var loc = 0

        while loc < length {
            let lineRange = fullString.lineRange(for: NSMakeRange(loc, 0))
            var effectiveRange = lineRange
            // Strip trailing newline characters from the range
            while effectiveRange.length > 0 {
                let lastChar = fullString.character(at: effectiveRange.location + effectiveRange.length - 1)
                if lastChar == 0x0A || lastChar == 0x0D {
                    effectiveRange.length -= 1
                } else {
                    break
                }
            }
            let sub = ns.attributedSubstring(from: effectiveRange)
            if let attrLine = try? AttributedString(sub, including: \.uiKit) {
                lines.append(attrLine)
            }
            loc = lineRange.location + lineRange.length
        }
        return lines
    }
}

extension Collection {
    func prefix(_ maxLength: Int?) -> SubSequence {
        guard let maxLength = maxLength else { return self[...] }
        return prefix(maxLength)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Default View Implementation

struct DefaultMarkdownCodeBlock: View {
    var codeBlockConfiguration: CodeBlockStyleConfiguration

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.markdownFontGroup) private var fontGroup
    @Environment(\.markdownTextOffsetBase) private var offsetBase
    @Environment(\.markdownFadeReveal) private var fadeConfig
    @Environment(\.markdownRendererConfiguration) private var rendererConfiguration
    @Environment(\.codeHighlighter) private var injectedHighlighter
    @Environment(\.codeBlockContentRenderers) private var customRenderers

    @State private var attributedCode: AttributedString?
    @State private var attributedCodeStyleTrigger: Int?
    @State private var attributedCodeSource: String?
    @State private var fullAttributedCode: AttributedString?
    @State private var fullAttributedCodeStyleTrigger: Int?
    @State private var fullAttributedCodeSource: String?
    @State private var codeHighlightTask: Task<Void, Error>?
    @State private var sheetHighlightTask: Task<Void, Error>?
    @State var showFullSheet: Bool = false
    @State private var codeCopied = false
    @State private var displayMode: DisplayMode = .rendered
    @State private var blockHeight: CGFloat?
    @State private var headerHeight: CGFloat?
    @State private var moreButtonHeight: CGFloat?

    enum DisplayMode: Hashable { case rendered, code }

    private var customRenderer: AnyCodeBlockContentRenderer? {
        guard let lang = codeBlockConfiguration.language?.lowercased() else { return nil }
        return customRenderers[lang]
    }

    private var totalLineCount: Int {
        plainCodeLines.count
    }

    private var showMoreButton: Bool {
        totalLineCount > 15 && !codeBlockConfiguration.showFullCode
    }

    private var displayedCodeLineCount: Int {
        codeBlockConfiguration.showFullCode
            ? totalLineCount
            : min(totalLineCount, 15)
    }

    private var isShowingCustomRenderer: Bool {
        customRenderer != nil && displayMode == .rendered
    }

    private var codeBlockScrollable: Bool {
        rendererConfiguration.codeBlock.scrollable
    }

    private let codeLineRowHeight: CGFloat = 28
    private let sheetCodeLineRowHeight: CGFloat = 24
    private let codeBlockBottomPadding: CGFloat = 10

    private var lineRevealMetrics: CodeBlockLineRevealMetrics {
        CodeBlockLineRevealMetrics(code: codeBlockConfiguration.code)
    }

    private var plainCodeLines: [String] {
        let rawLines = codeBlockConfiguration.code.components(separatedBy: .newlines)
        return rawLines.last == "" ? Array(rawLines.dropLast()) : rawLines
    }

    private var currentAttributedCodeLines: [AttributedString]? {
        attributedLinesFromCachedHighlight(
            attributedCode,
            source: attributedCodeSource,
            styleTrigger: attributedCodeStyleTrigger
        )
    }

    private var currentFullAttributedCodeLines: [AttributedString]? {
        attributedLinesFromCachedHighlight(
            fullAttributedCode,
            source: fullAttributedCodeSource,
            styleTrigger: fullAttributedCodeStyleTrigger
        )
    }

    private func attributedLinesFromCachedHighlight(
        _ attributed: AttributedString?,
        source: String?,
        styleTrigger: Int?
    ) -> [AttributedString]? {
        guard styleTrigger == highlightStyleTrigger,
              let attributed,
              let source,
              !source.isEmpty
        else { return nil }

        let prefixCount = commonPrefixCharacterCount(source, codeBlockConfiguration.code)
        guard prefixCount > 0 else { return nil }

        var merged = attributed.substring(
            from: 0,
            length: min(prefixCount, attributed.characters.count)
        )

        if prefixCount < codeBlockConfiguration.code.count {
            let suffixStart = codeBlockConfiguration.code.index(
                codeBlockConfiguration.code.startIndex,
                offsetBy: prefixCount
            )
            merged += AttributedString(String(codeBlockConfiguration.code[suffixStart...]))
        }

        return merged.splitByLines()
    }

    private func commonPrefixCharacterCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var left = lhs.startIndex
        var right = rhs.startIndex

        while left < lhs.endIndex, right < rhs.endIndex {
            guard lhs[left] == rhs[right] else { break }
            count += 1
            left = lhs.index(after: left)
            right = rhs.index(after: right)
        }

        return count
    }

    // MARK: - Main list code source (limited to 15 lines)

    func codeLinesSource(revealCount: Int?) -> some View {
        let lines = plainCodeLines
        let displayLines = codeBlockConfiguration.showFullCode ? lines : Array(lines.prefix(15))
        let attributedLines = currentAttributedCodeLines

        return Group {
            ForEach(displayLines.indices, id: \.self) { index in
                revealedCodeLine(
                    plainLine: displayLines[index],
                    attributedLine: attributedLines?[safe: index],
                    index: index,
                    total: displayLines.count,
                    revealCount: revealCount
                )
            }
        }
    }

    private func moreButtonSource(revealCount: Int?) -> some View {
        let revealMetrics = lineRevealMetrics

        return Group {
            if showMoreButton {
                CodeBlockRevealGate(
                    revealCount: revealCount,
                    startOffset: revealMetrics.endOffset(afterLineCount: displayedCodeLineCount)
                ) {
                    moreButton(remaining: totalLineCount - 15)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            roundedHeight(proxy.size.height)
                        } action: { height in
                            updateMoreButtonHeight(height)
                        }
                }
            }
        }
    }

    private func revealedCodeLine(
        plainLine: String,
        attributedLine: AttributedString?,
        index: Int,
        total: Int,
        revealCount: Int?
    ) -> some View {
        let startOffset = lineRevealMetrics.startOffset(forLine: index)
        let content = CodeBlockLineContent(
            plainLine: plainLine,
            attributedLine: attributedLine
        )

        return codeLine(
            content: content,
            visibleCharacterCount: content.visibleCharacterCount(
                revealCount: revealCount,
                offsetBase: offsetBase,
                startOffset: startOffset
            ),
            index: index,
            total: total
        )
    }

    private func codeLine(
        content: CodeBlockLineContent,
        visibleCharacterCount: Int?,
        index: Int,
        total: Int
    ) -> some View {
        CodeBlockLineView(
            content: content,
            visibleCharacterCount: visibleCharacterCount,
            horizontalPadding: 10,
            verticalPadding: 5,
            bottomPadding: codeBlockScrollable ? 0 : (index == total - 1 ? codeBlockBottomPadding : 0),
            rowHeight: codeBlockScrollable ? codeLineRowHeight : nil,
            wraps: !codeBlockScrollable,
            showsInlineStripe: !codeBlockScrollable,
            isStriped: index % 2 != 0
        )
    }

    private func codeLineBackgrounds(revealCount: Int?) -> some View {
        let visibleLineCount = visibleCodeLineCount(revealCount: revealCount)

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<visibleLineCount, id: \.self) { index in
                Rectangle()
                    .foregroundStyle(.tertiary.opacity(index % 2 != 0 ? 0.1 : 0))
                    .frame(height: codeLineRowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func visibleCodeLineCount(revealCount: Int?) -> Int {
        visibleCodeLineCount(revealCount: revealCount, maxLineCount: displayedCodeLineCount)
    }

    private func visibleCodeLineCount(revealCount: Int?, maxLineCount: Int) -> Int {
        guard let revealCount else { return maxLineCount }
        let localRevealCount = revealCount - offsetBase
        return lineRevealMetrics.visibleLineCount(
            forLocalRevealCount: localRevealCount,
            maxLineCount: maxLineCount
        )
    }

    private func moreButton(remaining: Int) -> some View {
        VStack(spacing: 0) {
            Rectangle().frame(height: 1).foregroundStyle(.gray.opacity(0.2))
            Button {
                debouncedHighlight(lineLimit: nil, targetFullSheet: true)
                showFullSheet = true
            } label: {
                HStack {
                    Spacer(minLength: 0)
                    (
                        Text("Show the Remaining ") +
                        Text("\(remaining)")
                            .monospacedDigit()
                        +
                        Text(" line\(remaining == 1 ? "" : "s")")
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .contentTransition(.identity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Code block layout

    var code: some View {
        StreamingRevealCountReader { _, revealCount in
            codeContent(revealCount: revealCount)
        }
        .task(id: highlightTrigger) {
            debouncedHighlight(lineLimit: codeBlockConfiguration.showFullCode ? nil : 15)
        }
        .font(fontGroup.codeBlock)
    }

    private func codeContent(revealCount: Int?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if codeBlockScrollable {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        codeLinesSource(revealCount: revealCount)
                    }
                    .padding(.bottom, codeBlockBottomPadding)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .background(alignment: .topLeading) {
                    codeLineBackgrounds(revealCount: revealCount)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    codeLinesSource(revealCount: revealCount)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            moreButtonSource(revealCount: revealCount)
        }
    }

    @Namespace var namespace

    @ViewBuilder
    private var bodyContent: some View {
        if let renderer = customRenderer, displayMode == .rendered {
            renderer.makeBody(
                code: codeBlockConfiguration.code,
                language: codeBlockConfiguration.language
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            code
        }
    }

    var body: some View {
        bodyContent
            .frame(maxWidth: .infinity, alignment: .leading)
#if os(macOS) || os(iOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        if customRenderer != nil {
                            modePicker
                        }
                        codeLanguage
                        if customRenderer == nil, !codeBlockConfiguration.showFullCode {
                            fullSheet
                        }
                        Spacer(minLength: 10)
                        copyButton
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    Rectangle().frame(height: 1).foregroundStyle(.gray.opacity(0.2))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    roundedHeight(proxy.size.height)
                } action: { height in
                    updateHeaderHeight(height)
                }
                .background {
                    Rectangle().foregroundStyle(
                        colorScheme == .dark ? .gray.opacity(0.1) : .white.opacity(0.5))
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                roundedHeight(proxy.size.height)
            } action: { height in
                updateBlockHeight(height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .background(alignment: .top) {
                codeBlockBackground
            }
#endif
            .sheet(isPresented: $showFullSheet) {
                fullCodeSheet
            }
    }

    private var codeBlockBackground: some View {
        StreamingRevealCountReader { revealManager, revealCount in
            let height = backgroundHeight(revealCount: revealCount)
            let visible = height > 0
            let baseDuration = fadeConfig?.duration ?? 0.3
            let duration = revealManager?.adaptiveFadeDuration(baseDuration: baseDuration) ?? baseDuration
            let isRevealing = revealCount != nil

            RoundedRectangle(cornerRadius: 15)
                .foregroundStyle(colorScheme == .dark ? .gray.opacity(0.1) : .white.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: 15).stroke(lineWidth: 1)
                        .foregroundStyle(.gray.opacity(0.2))
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .opacity(visible ? 1 : 0)
                .animation(isRevealing ? .smooth(duration: 0.24) : nil, value: height)
                .animation(isRevealing ? .easeOut(duration: duration) : nil, value: visible)
        }
    }

    private func backgroundHeight(revealCount: Int?) -> CGFloat {
        guard let blockHeight, blockHeight > 0 else { return 0 }
        guard let revealCount else { return blockHeight }

        let localRevealCount = revealCount - offsetBase
        guard localRevealCount > 0 else { return 0 }
        guard !isShowingCustomRenderer else { return blockHeight }
        guard codeBlockScrollable else { return blockHeight }

        let visibleLineCount = lineRevealMetrics.visibleLineCount(
            forLocalRevealCount: localRevealCount,
            maxLineCount: displayedCodeLineCount
        )
        let linesHeight = CGFloat(visibleLineCount) * codeLineRowHeight
        let bottomPadding = visibleLineCount == displayedCodeLineCount && displayedCodeLineCount > 0
            ? codeBlockBottomPadding
            : 0
        let moreHeight: CGFloat
        if showMoreButton,
           localRevealCount > lineRevealMetrics.endOffset(afterLineCount: displayedCodeLineCount) {
            moreHeight = moreButtonHeight ?? 0
        } else {
            moreHeight = 0
        }

        let height = (headerHeight ?? 0) + linesHeight + bottomPadding + moreHeight
        return min(max(height, 0), blockHeight)
    }

    private func roundedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return 0 }
        return (height * 2).rounded() / 2
    }

    private func updateBlockHeight(_ height: CGFloat) {
        guard shouldUpdateHeight(blockHeight, with: height) else { return }
        blockHeight = height
    }

    private func updateHeaderHeight(_ height: CGFloat) {
        guard shouldUpdateHeight(headerHeight, with: height) else { return }
        headerHeight = height
    }

    private func updateMoreButtonHeight(_ height: CGFloat) {
        guard shouldUpdateHeight(moreButtonHeight, with: height) else { return }
        moreButtonHeight = height
    }

    private func shouldUpdateHeight(_ current: CGFloat?, with next: CGFloat) -> Bool {
        guard next > 0 else { return false }
        guard let current else { return true }
        return abs(current - next) >= 0.5
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            modePickerSegment(title: "Preview", mode: .rendered)
            modePickerSegment(title: "Code", mode: .code)
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .foregroundStyle(.gray.opacity(0.1))
        }
        .padding(.vertical, -2)
    }

    private func modePickerSegment(title: String, mode: DisplayMode) -> some View {
        let isSelected = displayMode == mode
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                displayMode = mode
            }
        } label: {
            ZStack {
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0)
                Text(verbatim: title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.15) : Color.white)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Full-code sheet

    @ViewBuilder
    private var fullCodeSheet: some View {
        if #available(iOS 18.0, *) {
            NavigationStack {
                GeometryReader { proxy in
                    StreamingRevealCountReader { _, revealCount in
                        ScrollView(.vertical, showsIndicators: true) {
                            if codeBlockScrollable {
                                ZStack(alignment: .topLeading) {
                                    sheetLineBackgrounds(
                                        revealCount: revealCount,
                                        minWidth: proxy.size.width
                                    )

                                    ScrollView(.horizontal, showsIndicators: true) {
                                        sheetCodeLines(
                                            revealCount: revealCount,
                                            minWidth: proxy.size.width
                                        )
                                    }
                                }
                            } else {
                                HStack {
                                    sheetCodeLines(
                                        revealCount: revealCount,
                                        minWidth: proxy.size.width
                                    )
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .task(id: highlightTrigger) {
                            debouncedHighlight(lineLimit: nil, targetFullSheet: true)
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
#if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                codeBlockConfiguration.code, forType: .string)
#elseif os(iOS) || os(visionOS)
                            UIPasteboard.general.string = codeBlockConfiguration.code
#endif
                            Task {
                                withAnimation(.spring()) { codeCopied = true }
                                try await Task.sleep(nanoseconds: 2_000_000_000)
                                withAnimation(.spring()) { codeCopied = false }
                            }
                        } label: {
                            if codeCopied {
                                Label("Copied", systemImage: "checkmark")
                            } else {
                                Label("Copy", systemImage: "square.on.square")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sheetCodeLines(revealCount: Int?, minWidth: CGFloat) -> some View {
        let lines = plainCodeLines
        let attributedLines = currentFullAttributedCodeLines

        let stack = LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let content = CodeBlockLineContent(
                    plainLine: lines[index],
                    attributedLine: attributedLines?[safe: index]
                )
                sheetCodeLine(
                    content: content,
                    visibleCharacterCount: content.visibleCharacterCount(
                        revealCount: revealCount,
                        offsetBase: offsetBase,
                        startOffset: lineRevealMetrics.startOffset(forLine: index)
                    ),
                    index: index,
                    minWidth: minWidth
                )
            }
        }
        .font(fontGroup.codeBlock)

        if codeBlockScrollable {
            stack
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: minWidth, alignment: .leading)
        } else {
            stack
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sheetLineBackgrounds(revealCount: Int?, minWidth: CGFloat) -> some View {
        let visibleLineCount = visibleCodeLineCount(
            revealCount: revealCount,
            maxLineCount: totalLineCount
        )

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<visibleLineCount, id: \.self) { index in
                Rectangle()
                    .foregroundStyle(.tertiary.opacity(index % 2 != 0 ? 0.1 : 0))
                    .frame(minWidth: minWidth)
                    .frame(height: sheetCodeLineRowHeight)
            }
        }
        .frame(minWidth: minWidth, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func sheetCodeLine(
        content: CodeBlockLineContent,
        visibleCharacterCount: Int?,
        index: Int,
        minWidth: CGFloat
    ) -> some View {
        CodeBlockLineView(
            content: content,
            visibleCharacterCount: visibleCharacterCount,
            horizontalPadding: 5,
            verticalPadding: 3,
            bottomPadding: 0,
            rowHeight: codeBlockScrollable ? sheetCodeLineRowHeight : nil,
            minWidth: codeBlockScrollable ? minWidth : nil,
            wraps: !codeBlockScrollable,
            showsInlineStripe: !codeBlockScrollable,
            isStriped: index % 2 != 0
        )
    }

    // MARK: - Header widgets

    private var fullSheet: some View {
        Button {
            debouncedHighlight(lineLimit: nil, targetFullSheet: true)
            showFullSheet = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var codeLanguage: some View {
        if let language = codeBlockConfiguration.language {
            HStack(spacing: 5) {
                LanguageIcon(language: language)
                Text(language.localizedCapitalized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Highlighting

    private var highlightTrigger: Int {
        var hasher = Hasher()
        hasher.combine(codeBlockConfiguration.code)
        hasher.combine(codeBlockConfiguration.language)
        hasher.combine(colorScheme)
        return hasher.finalize()
    }

    private var highlightStyleTrigger: Int {
        var hasher = Hasher()
        hasher.combine(codeBlockConfiguration.language)
        hasher.combine(colorScheme)
        return hasher.finalize()
    }

    private func debouncedHighlight(lineLimit: Int?, targetFullSheet: Bool = false) {
        let code = codeBlockConfiguration.code
        let language = codeBlockConfiguration.language
        let scheme = colorScheme
        let highlighter = injectedHighlighter
        let styleTrigger = highlightStyleTrigger

        let task = Task.detached(priority: .userInitiated) {
            // Debounce only for compact list rendering; the open sheet should track streaming promptly.
            if !targetFullSheet {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try Task.checkCancellation()
            try await performHighlight(
                code: code,
                language: language,
                colorScheme: scheme,
                highlighter: highlighter,
                lineLimit: lineLimit,
                targetFullSheet: targetFullSheet,
                styleTrigger: styleTrigger
            )
        }

        if targetFullSheet {
            sheetHighlightTask?.cancel()
            sheetHighlightTask = task
        } else {
            codeHighlightTask?.cancel()
            codeHighlightTask = task
        }
    }

    @Sendable
    nonisolated private func performHighlight(
        code: String,
        language: String?,
        colorScheme: ColorScheme,
        highlighter: AnyCodeHighlighter?,
        lineLimit: Int?,
        targetFullSheet: Bool,
        styleTrigger: Int
    ) async throws {
        guard let highlighter else { return }
        try Task.checkCancellation()
        guard let result = try await highlighter.wrapped.highlight(
            code: code,
            language: language,
            colorScheme: colorScheme,
            lineLimit: lineLimit
        ) else { return }

        try await MainActor.run {
            try Task.checkCancellation()
            if targetFullSheet {
                self.fullAttributedCode = result
                self.fullAttributedCodeStyleTrigger = styleTrigger
                self.fullAttributedCodeSource = String(code.prefix(result.characters.count))
            } else {
                self.attributedCode = result
                self.attributedCodeStyleTrigger = styleTrigger
                self.attributedCodeSource = String(code.prefix(result.characters.count))
            }
        }
    }

    // MARK: - Copy button

    private var copyButton: some View {
        Button {
#if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(codeBlockConfiguration.code, forType: .string)
#elseif os(iOS) || os(visionOS)
            UIPasteboard.general.string = codeBlockConfiguration.code
#endif
            Task {
                withAnimation(.spring()) { codeCopied = true }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.spring()) { codeCopied = false }
            }
        } label: {
            Group {
                if codeCopied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.footnote)
                        .transition(.opacity.combined(with: .scale))
                } else {
                    Label("Copy", systemImage: "square.on.square")
                        .font(.footnote)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.accessory)
        .font(.callout.weight(.medium))
        .padding(.horizontal, -4)
    }
}

private struct CodeBlockLineRevealMetrics {
    private let lineStartOffsets: [Int]
    private let lineEndOffsets: [Int]
    private let totalLength: Int

    init(code: String) {
        var starts: [Int] = []
        var ends: [Int] = []
        var cursor = 0
        var index = code.startIndex

        while index < code.endIndex {
            let lineRange = code.lineRange(for: index..<index)
            starts.append(cursor)
            cursor += code[lineRange].count
            ends.append(cursor)
            index = lineRange.upperBound
        }

        lineStartOffsets = starts
        lineEndOffsets = ends
        totalLength = code.count
    }

    func startOffset(forLine index: Int) -> Int {
        lineStartOffsets[safe: index] ?? totalLength
    }

    func endOffset(afterLineCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return lineEndOffsets[safe: count - 1] ?? totalLength
    }

    func visibleLineCount(forLocalRevealCount revealCount: Int, maxLineCount: Int) -> Int {
        guard revealCount > 0, maxLineCount > 0 else { return 0 }

        var count = 0
        for index in 0..<min(maxLineCount, lineStartOffsets.count) {
            guard revealCount > lineStartOffsets[index] else { break }
            count += 1
        }
        return count
    }
}

private struct CodeBlockLineContent {
    let plainLine: String
    let attributedLine: AttributedString?

    var characterCount: Int {
        plainLine.count
    }

    func visibleCharacterCount(
        revealCount: Int?,
        offsetBase: Int,
        startOffset: Int
    ) -> Int? {
        guard let revealCount else {
            return nil
        }

        let localRevealed = revealCount - offsetBase - startOffset
        return max(0, min(characterCount, localRevealed))
    }

    func visibleText(visibleCharacterCount: Int?) -> Text {
        guard let visibleCharacterCount else {
            if let attributedLine {
                return Text(attributedLine)
            }
            return Text(verbatim: plainLine)
        }

        let clampedCount = max(0, min(characterCount, visibleCharacterCount))
        if let attributedLine {
            return Text(attributedLine.substring(from: 0, length: clampedCount))
        }

        return Text(verbatim: String(plainLine.prefix(clampedCount)))
    }
}

private struct CodeBlockLineView: View {
    let content: CodeBlockLineContent
    let visibleCharacterCount: Int?
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let bottomPadding: CGFloat
    let rowHeight: CGFloat?
    var minWidth: CGFloat?
    let wraps: Bool
    let showsInlineStripe: Bool
    let isStriped: Bool

    @ViewBuilder
    var body: some View {
        if let rowHeight {
            lineBody
                .frame(height: rowHeight, alignment: .topLeading)
        } else {
            lineBody
        }
    }

    private var lineBody: some View {
        ZStack(alignment: .topLeading) {
            lineText(Text(verbatim: content.plainLine))
                .opacity(0)
                .accessibilityHidden(true)

            lineText(content.visibleText(visibleCharacterCount: visibleCharacterCount))
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .padding(.bottom, bottomPadding)
        .frame(minWidth: minWidth, alignment: .leading)
        .background {
            Rectangle()
                .foregroundStyle(.tertiary.opacity(inlineStripeOpacity))
        }
    }

    private func lineText(_ text: Text) -> some View {
        HStack(alignment: .top) {
            if wraps {
                text
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                text
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }

    private var inlineStripeOpacity: Double {
        guard showsInlineStripe, isStriped else { return 0 }
        guard visibleCharacterCount.map({ $0 > 0 }) ?? true else { return 0 }
        return 0.1
    }
}

private struct CodeBlockRevealGate<Content: View>: View {
    let revealCount: Int?
    let startOffset: Int
    private let content: Content

    @Environment(\.markdownTextOffsetBase) private var offsetBase

    init(revealCount: Int?, startOffset: Int, @ViewBuilder content: () -> Content) {
        self.revealCount = revealCount
        self.startOffset = startOffset
        self.content = content()
    }

    var body: some View {
        let visible = revealCount.map { $0 > offsetBase + startOffset } ?? true

        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}

// MARK: - Language icon badge

private struct LanguageIcon: View {
    let language: String

    private var assetName: String? {
        switch language.lowercased() {
        case "swift":                        return "lang-swift"
        case "python", "py":                 return "lang-python"
        case "javascript", "js", "jsx":      return "lang-javascript"
        case "typescript", "ts", "tsx":      return "lang-typescript"
        case "go":                           return "lang-go"
        case "rust", "rs":                   return "lang-rust"
        case "c":                            return "lang-c"
        case "cpp", "c++", "cc", "cxx":     return "lang-cpp"
        case "java":                         return "lang-java"
        case "bash", "sh", "shell", "zsh":  return "lang-bash"
        case "html":                         return "lang-html"
        case "css":                          return "lang-css"
        case "ruby", "rb":                   return "lang-ruby"
        case "json", "jsonc":               return "lang-json"
        default:                             return nil
        }
    }

    private var fallbackInfo: (label: String, bg: Color, darkText: Bool) {
        switch language.lowercased() {
        case "javascript", "js", "jsx":
            return ("JS", Color(red: 0.969, green: 0.871, blue: 0.118), true)
        default:
            return (String(language.prefix(2)).uppercased(), Color.secondary.opacity(0.3), false)
        }
    }

    var body: some View {
        if let name = assetName {
            Image(name, bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            let info = fallbackInfo
            Text(info.label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(info.darkText ? Color.black : Color.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(info.bg))
        }
    }
}

// MARK: - Supplementary

private struct AccessoryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
#if os(macOS)
        if #available(macOS 14.0, *) {
            Button(role: configuration.role) {
                configuration.trigger()
            } label: {
                configuration.label
            }
            .buttonStyle(.accessoryBar)
        } else {
            Button(role: configuration.role) {
                configuration.trigger()
            } label: {
                configuration.label
            }
            .buttonStyle(.plain)
        }
#else
        Button(role: configuration.role) {
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(.plain)
#endif
    }
}

extension PrimitiveButtonStyle where Self == AccessoryButtonStyle {
    static fileprivate var accessory: AccessoryButtonStyle { .init() }
}
