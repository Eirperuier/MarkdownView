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
    @Environment(\.codeHighlighter) private var injectedHighlighter

    @State private var attributedCode: AttributedString?
    @State private var fullAttributedCode: AttributedString?
    @State private var fullAttributedCodeLines: [AttributedString]? = nil
    @State private var codeHighlightTask: Task<Void, Error>?
    @State private var sheetHighlightTask: Task<Void, Error>?
    @State var showFullSheet: Bool = false
    @State private var codeCopied = false

    private var totalLineCount: Int {
        let lines = codeBlockConfiguration.code.components(separatedBy: .newlines)
        return lines.last == "" ? lines.count - 1 : lines.count
    }

    private var showMoreButton: Bool {
        totalLineCount > 15 && !codeBlockConfiguration.showFullCode
    }

    // MARK: - Main list code source (limited to 15 lines)

    var codeSource: some View {
        Group {
            if let attributedCode {
                let lines = attributedCode.splitByLines()
                let displayLines = codeBlockConfiguration.showFullCode
                    ? lines
                    : Array(lines.prefix(15))
                ForEach(displayLines.indices, id: \.self) { index in
                    if let line = displayLines[safe: index] {
                        codeLine(Text(line), index: index, total: displayLines.count)
                    }
                }
                if showMoreButton {
                    moreButton(remaining: totalLineCount - 15)
                }
            } else {
                let rawLines = codeBlockConfiguration.code
                    .components(separatedBy: .newlines)
                let lines = rawLines.last == "" ? Array(rawLines.dropLast()) : rawLines
                let displayLines = codeBlockConfiguration.showFullCode
                    ? lines
                    : Array(lines.prefix(15))
                ForEach(displayLines.indices, id: \.self) { index in
                    if let line = displayLines[safe: index] {
                        codeLine(Text(verbatim: line), index: index, total: displayLines.count)
                    }
                }
                if showMoreButton {
                    moreButton(remaining: totalLineCount - 15)
                }
            }
        }
    }

    private func codeLine(_ text: Text, index: Int, total: Int) -> some View {
        HStack(alignment: .top) {
            text
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .padding(.bottom, index == total - 1 ? 10 : 0)
        .background {
            if index % 2 != 0 {
                Rectangle().foregroundStyle(.tertiary.opacity(0.1))
            }
        }
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
                    Text("Show the Remaining \(remaining) lines")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .contentTransition(.identity)
            }
        }
    }

    // MARK: - Code block layout

    var code: some View {
        VStack(alignment: .leading, spacing: 0) {
            codeSource
        }
        .task(id: highlightTrigger) {
            debouncedHighlight(lineLimit: codeBlockConfiguration.showFullCode ? nil : 15)
        }
        .font(fontGroup.codeBlock)
    }

    @Namespace var namespace

    var body: some View {
        code
            .frame(maxWidth: .infinity, alignment: .leading)
#if os(macOS) || os(iOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        codeLanguage
                        if !codeBlockConfiguration.showFullCode {
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
                .background {
                    Rectangle().foregroundStyle(
                        colorScheme == .dark ? .gray.opacity(0.1) : .white.opacity(0.5))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .background {
                RoundedRectangle(cornerRadius: 15)
                    .foregroundStyle(colorScheme == .dark ? .gray.opacity(0.1) : .white.opacity(0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15).stroke(lineWidth: 1)
                            .foregroundStyle(.gray.opacity(0.2))
                    }
            }
#endif
            .sheet(isPresented: $showFullSheet) {
                fullCodeSheet
            }
    }

    // MARK: - Full-code sheet

    @ViewBuilder
    private var fullCodeSheet: some View {
        if #available(iOS 18.0, *) {
            NavigationStack {
                ScrollView {
                    let rawLines = codeBlockConfiguration.code
                        .components(separatedBy: .newlines)
                    let plainLines = rawLines.last == "" ? Array(rawLines.dropLast()) : rawLines
                    LazyVStack(spacing: 0) {
                        ForEach(plainLines.indices, id: \.self) { index in
                            if let atLines = fullAttributedCodeLines, index < atLines.count {
                                sheetCodeLine(Text(atLines[index]), index: index)
                            } else {
                                sheetCodeLine(Text(verbatim: plainLines[index]), index: index)
                            }
                        }
                    }
                    .font(fontGroup.codeBlock)
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

    private func sheetCodeLine(_ text: Text, index: Int) -> some View {
        HStack(alignment: .top) {
            text
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background {
            if index % 2 != 0 {
                Rectangle().foregroundStyle(.tertiary.opacity(0.1))
            }
        }
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

    private func debouncedHighlight(lineLimit: Int?, targetFullSheet: Bool = false) {
        let code = codeBlockConfiguration.code
        let language = codeBlockConfiguration.language
        let scheme = colorScheme
        let highlighter = injectedHighlighter

        let task = Task.detached(priority: .userInitiated) {
            // Debounce only for list view (streaming updates); sheet is triggered once on tap.
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
                targetFullSheet: targetFullSheet
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
        targetFullSheet: Bool
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
                self.fullAttributedCodeLines = result.splitByLines()
            } else {
                self.attributedCode = result
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
