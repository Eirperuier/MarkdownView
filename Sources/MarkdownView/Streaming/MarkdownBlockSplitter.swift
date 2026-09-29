//
//  MarkdownBlockSplitter.swift
//  MarkdownView
//
//  Splits streamed markdown into top-level blocks whose ids survive re-parses, so a
//  list can diff cells and a StreamingRevealCoordinator can keep one manager per block.
//  Moved from ios-flowith's MessageParser.splitMarkdownViaAST; the message-specific
//  parts (thinking, tool calls, search references, image generation) stay in the app.
//

import Foundation

/// Source-level preprocessing applied before cmark parses streamed model output.
public struct MarkdownSourceNormalizer: Sendable {
    /// Fence info words (lowercased) whose auto-closed blocks carry
    /// ``StreamingFenceMarker/line``, so their renderers can tell a fence is still open.
    public var streamingFenceLanguages: Set<String>
    /// Runs after `\n` unescaping and before math and fence handling; for app rewrites
    /// such as turning `[Source 3]` into links.
    public var rewrite: (@Sendable (String) -> String)?

    public init(
        streamingFenceLanguages: Set<String> = [],
        rewrite: (@Sendable (String) -> String)? = nil
    ) {
        self.streamingFenceLanguages = streamingFenceLanguages
        self.rewrite = rewrite
    }

    /// Unescapes `\n` outside math and code, separates standalone display math into
    /// its own blocks, repairs code fences, converts `$…$` to `\(…\)` and escapes
    /// footnote definitions so cmark keeps them.
    public func normalize(_ text: String) -> String {
        var normalized = replaceEscapedNewlinesOutsideMathAndCode(text)
        if let rewrite {
            normalized = rewrite(normalized)
        }
        normalized = separateStandaloneDisplayMathBlocks(normalized)
        normalized = sanitizeMarkdownCodeFences(normalized, streamingFenceLanguages: streamingFenceLanguages)
        normalized = convertInlineDollarMath(normalized)
        normalized = escapeFootnoteDefinitions(normalized)
        return normalized
    }

    /// Matches an unclosed link or image at the end of the text: `[label`, `[label]`,
    /// `[label](url…` (and the `![` forms); `(?<!\\)` leaves `\[` display math alone.
    private static let streamingTailPartialLinkRegex = try? NSRegularExpression(
        pattern: "(?<!\\\\)!?\\[[^\\]\\n]*(?:\\](?:\\([^)\\n]*)?)?$",
        options: []
    )

    /// Drops a half-streamed link from the tail so chips and links appear in their
    /// final form instead of flashing raw source. Only for text that is still growing;
    /// finished text is never trimmed.
    public static func trimmingStreamingTailPartialLink(_ text: String) -> String {
        guard let regex = streamingTailPartialLinkRegex else { return text }
        // Inside an unclosed fence the tail is code, not prose. Single-line card JSON
        // such as `…"images":[{…` would otherwise be eaten from the `[` onwards.
        if endsInsideOpenCodeFence(text) { return text }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text, options: [], range: NSRange(location: 0, length: nsText.length)
        ) else { return text }
        return nsText.substring(to: match.range.location)
    }

    /// Whether the text ends inside an unclosed ``` / ~~~ fence (fence lines toggle,
    /// the last line counts even without a trailing newline).
    private static func endsInsideOpenCodeFence(_ text: String) -> Bool {
        var inFence = false
        text.enumerateLines { line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                inFence.toggle()
            }
        }
        return inFence
    }
}

/// One top-level block of a streamed markdown document.
public struct MarkdownStreamBlock: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Rendered by `MarkdownBlockView` / `MarkdownSelectableText` from ``content`` and ``descriptor``.
        case markdown
        /// A fenced code block whose info word the app renders itself; ``source`` is the whole fence.
        case customFence(language: String)
    }

    /// Stable across re-parses while the block keeps its position (or, for a new
    /// position, its content).
    public let id: UUID
    public let kind: Kind
    public let source: String
    /// The parsed document the descriptor points into; shared by every block of one parse.
    public let content: MarkdownContent
    public let descriptor: MarkdownBlockDescriptor
    public let inlineMathStorage: [String: String]?
    public let displayMathStorage: [UUID: String]?
    /// The block's length in reveal units, for ``StreamingRevealCoordinator/syncBlocks(_:generation:force:)``.
    public let revealPlainTextCount: Int
}

/// Turns markdown text into ``MarkdownStreamBlock``s, reusing ids from its previous run.
///
/// A value type: keep one per document, call ``split(_:isStreaming:)`` on each update.
/// Parsing is synchronous; run it off the main actor for long documents.
public struct MarkdownBlockSplitter: Sendable {
    public struct Heading: Hashable, Sendable {
        public let level: Int
        public let text: String
        public let blockIndex: Int
    }

    public var normalizer: MarkdownSourceNormalizer
    /// Fenced code blocks whose info word returns non-nil become ``MarkdownStreamBlock/Kind/customFence(language:)``.
    /// `false` holds the block back while its content can't render yet (incomplete JSON,
    /// say), so it enters the list at its real height instead of growing from zero.
    public var customFence: (@Sendable (_ language: String, _ source: String) -> Bool?)?

    public private(set) var headings: [Heading] = []
    private var cache: [String: MarkdownStreamBlock] = [:]

    public init(
        normalizer: MarkdownSourceNormalizer = MarkdownSourceNormalizer(),
        customFence: (@Sendable (_ language: String, _ source: String) -> Bool?)? = nil
    ) {
        self.normalizer = normalizer
        self.customFence = customFence
    }

    /// - Parameter isStreaming: the text is still growing; trims a half-written link at its tail.
    public mutating func split(_ text: String, isStreaming: Bool = false) -> [MarkdownStreamBlock] {
        headings = []
        var nextCache: [String: MarkdownStreamBlock] = [:]
        defer { cache = nextCache }

        let effectiveText = isStreaming ? MarkdownSourceNormalizer.trimmingStreamingTailPartialLink(text) : text
        let normalized = normalizer.normalize(effectiveText)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // Display math is extracted first so its body is captured verbatim, not
        // polluted by inline-math placeholders.
        let (afterDisplay, displayMathRaw) = extractDisplayMathStorage(from: normalized)
        let (processed, inlineMathStorage) = extractInlineParenMath(from: afterDisplay)
        let content = MarkdownContent(processed)
        let descriptors = content.topLevelBlocks(parseBlockDirectives: true, expandListItems: true)

        let inlineStorage = inlineMathStorage.isEmpty ? nil : inlineMathStorage
        let displayStorage = displayMathRaw.isEmpty ? nil : displayMathRaw

        return descriptors.compactMap { descriptor in
            var key: String
            if let context = descriptor.listItemContext {
                let path = context.indexPath.map(String.init).joined(separator: ".")
                key = "ast_\(context.parentTopLevelIndex).\(path)"
            } else {
                key = "ast_\(descriptor.topLevelIndex)"
            }

            var kind = MarkdownStreamBlock.Kind.markdown
            var revealCount = Self.revealPlainTextCount(for: descriptor)
            // A custom fence is a stable code block node from its first line, so it
            // never merges with the prose around it while streaming. It takes one
            // reveal tick and fades in whole when the frontier reaches it.
            if case .codeBlock(let language?) = descriptor.kind,
               let renderable = customFence?(language, descriptor.sourceText) {
                guard renderable else { return nil }
                key += "_fence"
                kind = .customFence(language: language)
                revealCount = 1
            }

            if case .heading(let level) = descriptor.kind {
                // An extended heading's plain text is "title\nsubtitle"; the outline takes the title.
                headings.append(Heading(
                    level: level,
                    text: descriptor.childPlainTexts.first ?? descriptor.plainText,
                    blockIndex: headings.count
                ))
            }

            let previous = cache[key]
            // An unchanged block is its previous value, document and all: views keyed on it
            // don't re-render, and comparing it with the last parse is cheap (same storage).
            if let previous, previous.source == descriptor.sourceText, previous.descriptor == descriptor,
               previous.kind == kind, previous.revealPlainTextCount == revealCount {
                nextCache[key] = previous
                return previous
            }
            let block = MarkdownStreamBlock(
                id: previous?.id ?? UUID(),
                kind: kind,
                source: descriptor.sourceText,
                content: content,
                descriptor: descriptor,
                inlineMathStorage: inlineStorage,
                displayMathStorage: displayStorage,
                revealPlainTextCount: revealCount
            )
            nextCache[key] = block
            return block
        }
    }

    public mutating func reset() {
        cache = [:]
        headings = []
    }

    static func revealPlainTextCount(for descriptor: MarkdownBlockDescriptor) -> Int {
        switch descriptor.kind {
        case .paragraph, .heading, .blockQuote, .htmlBlock,
             .orderedList, .unorderedList, .table:
            return descriptor.plainText.count
        case .codeBlock:
            return max(descriptor.plainText.count, 1)
        default:
            // Non-text blocks (thematic break, image, math, block directive) take one
            // tick so they fade in on cue with the text around them.
            return 1
        }
    }
}
