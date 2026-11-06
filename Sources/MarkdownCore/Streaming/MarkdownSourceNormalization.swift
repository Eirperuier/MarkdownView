//
//  MarkdownSourceNormalization.swift
//  MarkdownView
//
//  Source-level preprocessing for streamed model output, run before cmark sees the
//  text. Moved from ios-flowith's MessageParser (MarkdownRenderView.swift) as is;
//  only the access levels and the opted-in fence languages changed.
//

import CryptoKit
import Foundation

// MARK: - Code fence scanning

/// A fenced-code-block delimiter line — `~~~` / ` ``` ` (≥3 of either, more
/// for longer fences) as the start of a line, after up to a little leading
/// whitespace. `infoWord` is the first whitespace-separated token after the
/// run (the "language"), lowercased; empty for a bare line.
private struct CodeFenceLine {
    let char: Character   // "`" or "~"
    let length: Int       // ≥ 3
    let infoWord: String
}

private struct OpenCodeFence {
    let lineIndex: Int
    let char: Character
    let length: Int
    let infoWord: String
    var maxSameCharRunInContent: Int = 0
}

/// Recognizes a code-fence delimiter at the start of `line`, or `nil`.
private func codeFenceLine<S: StringProtocol>(_ line: S) -> CodeFenceLine? {
    let stripped = line.drop(while: { $0 == " " })
    guard let first = stripped.first, first == "`" || first == "~" else { return nil }
    let run = stripped.prefix(while: { $0 == first })
    guard run.count >= 3 else { return nil }
    let info = stripped.dropFirst(run.count)
        .split(whereSeparator: { $0 == " " || $0 == "\t" })
        .first.map { String($0).lowercased() } ?? ""
    return CodeFenceLine(char: first, length: run.count, infoWord: info)
}

private func replacingCodeFenceLength(in line: String, with length: Int, char: Character) -> String {
    let indentation = line.prefix(while: { $0 == " " })
    let stripped = line.dropFirst(indentation.count)
    let run = stripped.prefix(while: { $0 == char })
    let suffix = stripped.dropFirst(run.count)
    return String(indentation) + String(repeating: char, count: length) + String(suffix)
}

/// Lets a custom-rendered fenced code block tell whether it's still streaming.
///
/// swift-markdown / cmark don't record whether a fence was closed by the
/// source or merely ran to EOF — but `sanitizeMarkdownCodeFences` is the one
/// synthesizing the missing closer during streaming, so it can leave a trace:
/// for opted-in info words, the synthesized closer is preceded by an invisible
/// sentinel line (`line` — zero-width / word-joiner characters, survives cmark
/// verbatim as code-block content, never produced by a model). A renderer that
/// receives such content calls ``peel(_:)`` to strip the sentinel and learn
/// `incomplete`; the value flips `true → false` the instant the model emits
/// the real closing fence, giving a deterministic "this block is done" edge.
///
/// To opt a custom fence in, list its info word in
/// ``MarkdownSourceNormalizer/streamingFenceLanguages`` and call
/// `StreamingFenceMarker.peel(_:)` in its renderer / parser.
public enum StreamingFenceMarker {
    /// The sentinel line. Invisible, model-unproducible, stripped wherever the
    /// block's content is surfaced (shown / copied / re-parsed).
    public static let line = "\u{200B}\u{2060}\u{200B}\u{2060}mdv-fence-open\u{2060}\u{200B}\u{2060}\u{200B}"

    /// What to append to a streamed-but-unterminated document to close its
    /// open fence: the sentinel line (only for opted-in info words) then the
    /// closer.
    static func completionSuffix(closer: String, infoWord: String, optedIn: Set<String>) -> String {
        optedIn.contains(infoWord) ? "\n" + line + "\n" + closer : "\n" + closer
    }

    /// Strips a trailing sentinel line from a code block's `content`. Returns
    /// the cleaned content and whether the sentinel was present (⇒ the fence
    /// was auto-closed ⇒ the block is still streaming).
    public static func peel(_ content: String) -> (body: String, incomplete: Bool) {
        let trimmed = content.trimmingCharacters(in: .newlines)
        if trimmed == line { return ("", true) }
        if trimmed.hasSuffix("\n" + line) {
            return (String(trimmed.dropLast(line.count + 1)).trimmingCharacters(in: .newlines), true)
        }
        return (trimmed, false)
    }
}

/// Tracks the currently-open fenced code block while scanning markdown.
/// A fence opened with N backticks (or tildes) is only closed by a line that
/// is a fence of the *same character* with *≥ N* of them — which is exactly
/// what lets a ` ````writing ` block contain ordinary ` ``` ` code blocks
/// (the matching here intentionally stays lenient about an info string on the
/// closing line, mirroring the previous behavior for `` ```py … ```bash `` ).
private struct CodeFenceTracker {
    private(set) var open: (char: Character, length: Int, infoWord: String)?

    var isInsideFence: Bool { open != nil }

    enum Transition { case none, opened, closed }

    /// Feeds one line; returns whether it opened/closed a fence.
    @discardableResult
    mutating func consume<S: StringProtocol>(line: S) -> Transition {
        guard let fence = codeFenceLine(line) else { return .none }
        if let cur = open {
            if fence.char == cur.char, fence.length >= cur.length {
                open = nil
                return .closed
            }
            return .none   // shorter / different-char fence inside the open block ⇒ content
        }
        open = (fence.char, fence.length, fence.infoWord)
        return .opened
    }

    /// The closer string + the open fence's info word, if a block is still
    /// open at the end (for streaming completion); `nil` when balanced.
    var unterminatedFence: (closer: String, infoWord: String)? {
        open.map { (String(repeating: $0.char, count: $0.length), $0.infoWord) }
    }
}

/// Ensures code fences are safe before cmark sees them. Nested examples often
/// need to display a fence as literal content, e.g. a ` ````writing ` block
/// that contains a markdown snippet with its own ` ```` ` line. We first scan
/// with exact-length closing and a small nested-fence stack, then upgrade any
/// ambiguous opener/closer to a longer run so cmark preserves the intended
/// content. If a block is still open, we append a matching closer; opted-in
/// fences also get a sentinel so downstream can tell they are mid-stream.
func sanitizeMarkdownCodeFences(_ text: String, streamingFenceLanguages: Set<String>) -> String {
    var lines = text.components(separatedBy: "\n")
    var stack: [OpenCodeFence] = []
    var replacementLengths: [Int: Int] = [:]

    func noteContentFence(_ fence: CodeFenceLine) {
        guard let lastIndex = stack.indices.last,
              stack[lastIndex].char == fence.char else { return }
        stack[lastIndex].maxSameCharRunInContent = max(
            stack[lastIndex].maxSameCharRunInContent,
            fence.length
        )
    }

    func closeTopFence(at lineIndex: Int) {
        let entry = stack.removeLast()
        let replacementLength = max(entry.length, entry.maxSameCharRunInContent + 1)
        if replacementLength != entry.length {
            replacementLengths[entry.lineIndex] = replacementLength
            replacementLengths[lineIndex] = replacementLength
        }
        if let parentIndex = stack.indices.last,
           stack[parentIndex].char == entry.char {
            stack[parentIndex].maxSameCharRunInContent = max(
                stack[parentIndex].maxSameCharRunInContent,
                replacementLength
            )
        }
    }

    for (index, line) in lines.enumerated() {
        guard let fence = codeFenceLine(line) else { continue }

        if let current = stack.last {
            let closesCurrent = fence.char == current.char
                && fence.length == current.length
                && fence.infoWord.isEmpty

            if closesCurrent {
                closeTopFence(at: index)
            } else if fence.char != current.char || fence.length < current.length {
                noteContentFence(fence)
                stack.append(OpenCodeFence(
                    lineIndex: index,
                    char: fence.char,
                    length: fence.length,
                    infoWord: fence.infoWord
                ))
            } else {
                noteContentFence(fence)
            }
        } else {
            stack.append(OpenCodeFence(
                lineIndex: index,
                char: fence.char,
                length: fence.length,
                infoWord: fence.infoWord
            ))
        }
    }

    var completionSuffix = ""
    while !stack.isEmpty {
        let entry = stack.removeLast()
        let replacementLength = max(entry.length, entry.maxSameCharRunInContent + 1)
        if replacementLength != entry.length {
            replacementLengths[entry.lineIndex] = replacementLength
        }
        let closer = String(repeating: entry.char, count: replacementLength)
        completionSuffix += StreamingFenceMarker.completionSuffix(
            closer: closer,
            infoWord: entry.infoWord,
            optedIn: streamingFenceLanguages
        )
        if let parentIndex = stack.indices.last,
           stack[parentIndex].char == entry.char {
            stack[parentIndex].maxSameCharRunInContent = max(
                stack[parentIndex].maxSameCharRunInContent,
                replacementLength
            )
        }
    }

    guard !replacementLengths.isEmpty || !completionSuffix.isEmpty else { return text }

    for (index, length) in replacementLengths {
        guard let fence = codeFenceLine(lines[index]) else { continue }
        lines[index] = replacingCodeFenceLength(
            in: lines[index],
            with: length,
            char: fence.char
        )
    }

    return lines.joined(separator: "\n") + completionSuffix
}

/// Char-scanner companion to `CodeFenceTracker`: at `index`, recognizes a
/// backtick code-fence run (≥3) and updates `openLength` (the length of the
/// currently-open fence, `nil` if none). A longer fence isn't closed by a
/// shorter run, so an inner ` ``` ` doesn't end an outer ` ```` ` block.
/// Returns the run's range when it was a fence, else `nil`.
private func scanBacktickFence(
    in text: String,
    at index: String.Index,
    openLength: inout Int?
) -> Range<String.Index>? {
    guard text[index] == "`" else { return nil }
    let run = text[index...].prefix(while: { $0 == "`" }).count
    guard run >= 3 else { return nil }
    if let open = openLength {
        if run >= open { openLength = nil }
        // else: shorter run inside the open fence ⇒ literal content
    } else {
        openLength = run
    }
    return index..<text.index(index, offsetBy: run)
}

/// Converts `$...$` inline math delimiters to `\(...\)` format that the
/// existing MathParser already supports.  Uses heuristics modeled after the
/// CommonMark math extension to avoid false-positive matches on currency
/// amounts, code spans, and incomplete streaming fragments.
func convertInlineDollarMath(_ text: String) -> String {
    guard text.contains("$") else { return text }

    var result = ""
    result.reserveCapacity(text.count)
    var i = text.startIndex
    var openFenceLength: Int? = nil
    var inInlineCode = false

    while i < text.endIndex {
        let c = text[i]

        // ── Code-fence tracking (longer fences aren't closed by shorter runs) ──
        if let range = scanBacktickFence(in: text, at: i, openLength: &openFenceLength) {
            result.append(contentsOf: text[range])
            i = range.upperBound
            continue
        }

        // ── Inline-code tracking (single `) ──
        if c == "`" && openFenceLength == nil {
            inInlineCode.toggle()
            result.append(c)
            i = text.index(after: i)
            continue
        }

        // Pass through anything inside code verbatim.
        if openFenceLength != nil || inInlineCode {
            result.append(c)
            i = text.index(after: i)
            continue
        }

        // ── Escaped dollar: \$ ──
        if c == "\\" {
            let next = text.index(after: i)
            if next < text.endIndex && text[next] == "$" {
                result.append(contentsOf: "\\$")
                i = text.index(after: next)
                continue
            }
        }

        // ── Double dollar ($$) – already supported, skip both chars ──
        if c == "$" {
            let next = text.index(after: i)
            if next < text.endIndex && text[next] == "$" {
                result.append("$")
                result.append("$")
                i = text.index(after: next)
                continue
            }
        }

        // ── Try to match a single-dollar pair $...$ ──
        if c == "$" {
            if let close = inlineDollarMathClose(in: text, openingAt: i) {
                let afterOpen = text.index(after: i)
                let afterClose = text.index(after: close)
                result.append(contentsOf: "\\(")
                result.append(contentsOf: text[afterOpen..<close])
                result.append(contentsOf: "\\)")
                i = afterClose
                continue
            }

            // No valid match – keep the literal $
            result.append(c)
            i = text.index(after: i)
            continue
        }

        result.append(c)
        i = text.index(after: i)
    }
    return result
}

private func inlineDollarMathClose(
    in text: String,
    openingAt open: String.Index
) -> String.Index? {
    guard text[open] == "$" else { return nil }
    if open > text.startIndex, text[text.index(before: open)] == "\\" {
        return nil
    }

    let afterOpen = text.index(after: open)
    guard afterOpen < text.endIndex,
          !text[afterOpen].isWhitespace,
          !text[afterOpen].isNewline,
          text[afterOpen] != "$"
    else {
        return nil
    }

    var index = afterOpen
    while index < text.endIndex && !text[index].isNewline {
        if isInlineDollarMathClose(in: text, at: index) {
            return index
        }
        index = text.index(after: index)
    }

    return nil
}

private func isInlineDollarMathClose(
    in text: String,
    at index: String.Index
) -> Bool {
    guard text[index] == "$" else { return false }
    if index > text.startIndex, text[text.index(before: index)] == "\\" {
        return false
    }

    let beforeClose = text.index(before: index)
    if text[beforeClose].isWhitespace {
        return false
    }

    let afterClose = text.index(after: index)
    if afterClose < text.endIndex, text[afterClose].isNumber {
        return false
    }

    return true
}

func replaceEscapedNewlinesOutsideMathAndCode(_ text: String) -> String {
    guard text.contains("\\n") else { return text }

    var result = ""
    result.reserveCapacity(text.count)
    var i = text.startIndex
    var openFenceLength: Int? = nil
    var inInlineCode = false
    var mathTerminator: String?

    while i < text.endIndex {
        if let range = scanBacktickFence(in: text, at: i, openLength: &openFenceLength) {
            result.append(contentsOf: text[range])
            i = range.upperBound
            continue
        }

        let c = text[i]

        if c == "`", openFenceLength == nil {
            inInlineCode.toggle()
            result.append(c)
            i = text.index(after: i)
            continue
        }

        if openFenceLength == nil, !inInlineCode {
            if let terminator = mathTerminator {
                if terminator == "$", isInlineDollarMathClose(in: text, at: i) {
                    result.append("$")
                    i = text.index(after: i)
                    mathTerminator = nil
                    continue
                } else if terminator != "$", text[i...].hasPrefix(terminator) {
                    result.append(contentsOf: terminator)
                    i = text.index(i, offsetBy: terminator.count)
                    mathTerminator = nil
                    continue
                }
            } else if text[i...].hasPrefix("$$") {
                result.append("$$")
                i = text.index(i, offsetBy: 2)
                mathTerminator = "$$"
                continue
            } else if text[i...].hasPrefix("\\[") {
                result.append("\\[")
                i = text.index(i, offsetBy: 2)
                mathTerminator = "\\]"
                continue
            } else if text[i...].hasPrefix("\\(") {
                result.append("\\(")
                i = text.index(i, offsetBy: 2)
                mathTerminator = "\\)"
                continue
            } else if c == "$", inlineDollarMathClose(in: text, openingAt: i) != nil {
                result.append("$")
                i = text.index(after: i)
                mathTerminator = "$"
                continue
            }
        }

        if mathTerminator == nil,
           openFenceLength == nil,
           !inInlineCode,
           text[i...].hasPrefix("\\n") {
            result.append("\n")
            i = text.index(i, offsetBy: 2)
            continue
        }

        result.append(c)
        i = text.index(after: i)
    }

    return result
}

func separateStandaloneDisplayMathBlocks(_ text: String) -> String {
    guard text.contains("$$") || text.contains("\\[") else { return text }

    let lines = text.components(separatedBy: "\n")
    var result: [String] = []
    result.reserveCapacity(lines.count + 4)

    var fences = CodeFenceTracker()
    var inDisplayMath: DisplayMathDelimiter?
    var needsBlankAfterDisplayMath = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if needsBlankAfterDisplayMath {
            if !trimmed.isEmpty, !(result.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                result.append("")
            }
            needsBlankAfterDisplayMath = false
        }

        if inDisplayMath == nil, codeFenceLine(trimmed) != nil {
            result.append(line)
            fences.consume(line: trimmed)
            continue
        }

        guard !fences.isInsideFence else {
            result.append(line)
            continue
        }

        if let delimiter = inDisplayMath {
            result.append(line)
            if closesDisplayMathLine(trimmed, delimiter: delimiter) {
                inDisplayMath = nil
                needsBlankAfterDisplayMath = true
            }
            continue
        }

        if let delimiter = displayMathOpeningDelimiter(in: trimmed) {
            if !(result.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                result.append("")
            }

            result.append(line)
            if closesDisplayMathLine(trimmed, delimiter: delimiter, openingLine: true) {
                needsBlankAfterDisplayMath = true
            } else {
                inDisplayMath = delimiter
            }
            continue
        }

        result.append(line)
    }

    return result.joined(separator: "\n")
}

private enum DisplayMathDelimiter {
    case dollars
    case brackets
}

private func displayMathOpeningDelimiter(in trimmedLine: String) -> DisplayMathDelimiter? {
    if trimmedLine.hasPrefix("$$") {
        return .dollars
    }
    if trimmedLine.hasPrefix("\\[") {
        return .brackets
    }
    return nil
}

private func closesDisplayMathLine(
    _ trimmedLine: String,
    delimiter: DisplayMathDelimiter,
    openingLine: Bool = false
) -> Bool {
    switch delimiter {
    case .dollars:
        if openingLine {
            return trimmedLine.count > 2 && trimmedLine.dropFirst(2).contains("$$")
        }
        return trimmedLine.hasSuffix("$$")
    case .brackets:
        if openingLine {
            return trimmedLine.dropFirst(2).contains("\\]")
        }
        return trimmedLine.hasSuffix("\\]")
    }
}

/// Pre-extracts standalone display math (`\[ … \]`, `$$ … $$`,
/// `\begin{equation}…\end{equation}` and bare `[ … ]` blocks that carry a
/// LaTeX signal character) BEFORE cmark sees the source. Each match is
/// replaced with a `@math(uuid:UUID)` block directive line whose payload
/// is resolved at render time via `markdownDisplayMathStorage(_:)`.
///
/// Why: cmark consumes `\[` / `\]` as CommonMark backslash escapes — by
/// the time `MarkdownBlockView` reaches `MathParser.standaloneDisplayMath`
/// the delimiters are already gone from `paragraph.plainText` /
/// `paragraph.format()`, so any post-cmark detection silently misses
/// canonical block math. Mirroring `MathFirstMarkdownViewRenderer`'s
/// pre-extraction approach (one principled path; bare brackets are
/// pre-rewritten to `\[ … \]` so they share the same handler).
public func extractDisplayMathStorage(from text: String) -> (processed: String, storage: [UUID: String]) {
    let prepared = rewriteBareBracketBlockMath(in: text)
    guard prepared.contains("\\[")
            || prepared.contains("$$")
            || prepared.contains("\\begin") else {
        return (prepared, [:])
    }

    // Math is looked for between code fences only, as MathFirstMarkdownViewRenderer does:
    // code's own delimiters (`\(` in a Swift string) would open a formula that swallows the
    // real ones after it.
    var outside: [Range<String.Index>] = []
    var start = prepared.startIndex
    for code in fencedCodeRanges(in: prepared) {
        if start < code.lowerBound { outside.append(start..<code.lowerBound) }
        start = max(start, code.upperBound)
    }
    if start < prepared.endIndex { outside.append(start..<prepared.endIndex) }
    let maths = outside.flatMap { MathParser(text: prepared[$0]).mathRepresentations }
    var storage: [UUID: String] = [:]
    var rawText = prepared

    for math in maths.reversed() where !math.kind.inline {
        guard isStandaloneDisplayMathRange(math.range, in: prepared) else { continue }

        let latex = String(prepared[math.range])
        // Content-derived UUID keeps the AST node's stableContentHash
        // identical across streaming re-extractions, so the AST that
        // backs `MarkdownBlockView` doesn't churn while the closing
        // delimiter is still landing. Without this, every stream tick
        // would produce a fresh `MarkdownDisplayMath` and reset its
        // `@State` (locked height, in-flight measurement, etc.).
        let id = displayMathStableUUID(forLatex: latex)
        storage[id] = latex

        // Preserve the indentation of the line holding `\[` so the
        // directive stays a child of whatever container the math was in
        // (list item, blockquote, nested list). Without this, the
        // substituted `@math(uuid:…)` ends up at column 0 and CommonMark
        // treats it as a sibling of the list, breaking the indent /
        // marker relationship the user authored.
        let indent = leadingIndent(forRangeStart: math.range.lowerBound, in: prepared)
        rawText.replaceSubrange(
            math.range,
            with: "\n\(indent)@math(uuid:\(id.uuidString))\n\(indent)"
        )
    }

    return (rawText, storage)
}

/// Rewrites standalone bare-bracket pairs into canonical `\[ … \]` so the
/// same `MathParser` pass handles them. Only fires when `[` and `]` each
/// occupy their own line and the body carries a LaTeX signal character
/// (`\`, `^`, `_`, `{`) — avoids `[link](url)` / `[1]` / reference
/// definitions, which never put the bracket alone on a line.
private func rewriteBareBracketBlockMath(in text: String) -> String {
    guard text.contains("[") && text.contains("]") else { return text }

    let lines = text.components(separatedBy: "\n")
    var result = lines
    var fences = CodeFenceTracker()
    var inProperDisplayMath: DisplayMathDelimiter? = nil
    var openIndex: Int? = nil
    var hasLatexSignal = false
    let latexSignals: Set<Character> = ["\\", "^", "_", "{"]

    for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if codeFenceLine(trimmed) != nil {
            openIndex = nil
            hasLatexSignal = false
            fences.consume(line: trimmed)
            continue
        }
        if fences.isInsideFence { continue }

        if let delim = inProperDisplayMath {
            if closesDisplayMathLine(trimmed, delimiter: delim) {
                inProperDisplayMath = nil
            }
            continue
        }
        if let delim = displayMathOpeningDelimiter(in: trimmed) {
            if !closesDisplayMathLine(trimmed, delimiter: delim, openingLine: true) {
                inProperDisplayMath = delim
            }
            openIndex = nil
            hasLatexSignal = false
            continue
        }

        if let open = openIndex {
            if trimmed == "]" {
                if hasLatexSignal {
                    result[open] = lines[open].replacingOccurrences(of: "[", with: "\\[")
                    result[idx] = line.replacingOccurrences(of: "]", with: "\\]")
                }
                openIndex = nil
                hasLatexSignal = false
                continue
            }
            if !hasLatexSignal, trimmed.contains(where: { latexSignals.contains($0) }) {
                hasLatexSignal = true
            }
            continue
        }

        if trimmed == "[" {
            openIndex = idx
            hasLatexSignal = false
        }
    }

    return result.joined(separator: "\n")
}

/// Returns ranges in `text` covered by fenced code blocks. Math
/// representations that start inside any of these ranges are skipped
/// during extraction.
private func fencedCodeRanges(in text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var fences = CodeFenceTracker()
    var fenceStart: String.Index? = nil
    var idx = text.startIndex

    while idx < text.endIndex {
        let lineEnd = text[idx...].firstIndex(of: "\n") ?? text.endIndex
        let trimmed = text[idx..<lineEnd].trimmingCharacters(in: .whitespaces)
        let transition = fences.consume(line: trimmed)

        switch transition {
        case .opened:
            fenceStart = idx
        case .closed:
            if let start = fenceStart {
                ranges.append(start..<lineEnd)
                fenceStart = nil
            }
        case .none:
            break
        }

        idx = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
    }

    if let start = fenceStart {
        ranges.append(start..<text.endIndex)
    }

    return ranges
}

/// Captures the leading whitespace of the line that contains the given
/// position — used by the display-math extractor to indent the
/// substituted `@math(uuid:…)` directive to the same column as the
/// original `\[`, so the directive stays a child of any list item /
/// blockquote / nested container the math was authored inside.
private func leadingIndent(
    forRangeStart position: String.Index,
    in text: String
) -> String {
    let lineStart = text[..<position].lastIndex(of: "\n").map {
        text.index(after: $0)
    } ?? text.startIndex
    // `isStandaloneDisplayMathRange` already guarantees this slice is
    // whitespace-only, so the substring is a clean indent string.
    return String(text[lineStart..<position])
}

/// Deterministic UUID derived from the LaTeX source, shaped per RFC 4122
/// version 5 (name-based, with SHA-256 truncated to 16 bytes instead of
/// SHA-1 — close enough for our content-addressing purposes). Same input
/// LaTeX always yields the same UUID, which keeps the resulting block
/// directive node's `stableContentHash` constant across re-extractions.
private func displayMathStableUUID(forLatex latex: String) -> UUID {
    let digest = SHA256.hash(data: Data(latex.utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

/// Mirrors the standalone-range check used by `MathFirstMarkdownViewRenderer`:
/// the range must occupy its surrounding line(s) entirely with no other
/// non-whitespace content.
private func isStandaloneDisplayMathRange(
    _ range: Range<String.Index>,
    in text: String
) -> Bool {
    let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map {
        text.index(after: $0)
    } ?? text.startIndex
    let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex

    let prefix = text[lineStart..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    let suffix = text[range.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces)
    return prefix.isEmpty && suffix.isEmpty
}

/// What marks inline maths in the text between preprocessing and drawing: `⸨imath:ID⸩`.
package enum MarkdownInlineMathPlaceholder {
    package static let prefix = "\u{2E28}imath:"
    package static let suffix = "\u{2E29}"
}

/// Extracts `\(...\)` inline math spans BEFORE cmark parsing so that the
/// backslash-paren delimiters aren't consumed as CommonMark escapes.
///
/// Mirrors the internal placeholder format used by `MarkdownView`
/// (`⸨imath:ID⸩`) so that `markdownInlineMathStorage(_:)` can resolve them
/// at render time. Uses index-based IDs for cache stability across renders.
public func extractInlineParenMath(from text: String) -> (processed: String, storage: [String: String]) {
    guard text.contains("\\(") else { return (text, [:]) }

    let prefix = MarkdownInlineMathPlaceholder.prefix
    let suffix = MarkdownInlineMathPlaceholder.suffix

    var result = ""
    result.reserveCapacity(text.count)
    var storage: [String: String] = [:]
    var counter = 0
    var i = text.startIndex
    var openFenceLength: Int? = nil
    var inInlineCode = false

    while i < text.endIndex {
        let c = text[i]

        if let range = scanBacktickFence(in: text, at: i, openLength: &openFenceLength) {
            result.append(contentsOf: text[range])
            i = range.upperBound
            continue
        }

        if c == "`" && openFenceLength == nil {
            inInlineCode.toggle()
            result.append(c)
            i = text.index(after: i)
            continue
        }

        if openFenceLength != nil || inInlineCode {
            result.append(c)
            i = text.index(after: i)
            continue
        }

        if c == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "(" {
            var j = text.index(i, offsetBy: 2)
            var closeStart: String.Index? = nil
            while j < text.endIndex {
                if text[j] == "\n" { break }
                if text[j] == "\\" {
                    let nxt = text.index(after: j)
                    if nxt < text.endIndex && text[nxt] == ")" {
                        closeStart = j
                        break
                    }
                }
                j = text.index(after: j)
            }
            if let endStart = closeStart {
                let mathEnd = text.index(endStart, offsetBy: 2)
                let full = String(text[i..<mathEnd])
                let id = "m\(counter)"
                counter += 1
                storage[id] = full
                result.append(prefix)
                result.append(id)
                result.append(suffix)
                i = mathEnd
                continue
            }
        }

        result.append(c)
        i = text.index(after: i)
    }

    return (result, storage)
}

/// Escapes a footnote definition marker at the start of a line (`[^id]:` → `\[^id]:`)
/// outside code fences. `[^a]: Note` is also a valid link reference definition, which
/// cmark would drop from the document; escaped, the text reaches the AST as `[^a]: Note`.
func escapeFootnoteDefinitions(_ text: String) -> String {
    guard text.contains("[^") else { return text }
    var fences = CodeFenceTracker()
    var changed = false
    let lines = text.components(separatedBy: "\n").map { line -> String in
        let trimmed = line.drop(while: { $0 == " " })
        if codeFenceLine(trimmed) != nil {
            fences.consume(line: trimmed)
            return line
        }
        guard !fences.isInsideFence,
              trimmed.hasPrefix("[^"),
              let close = trimmed.firstIndex(of: "]"),
              trimmed[trimmed.index(after: close)...].hasPrefix(":")
        else { return line }
        changed = true
        return String(line.prefix(line.count - trimmed.count)) + "\\" + trimmed
    }
    return changed ? lines.joined(separator: "\n") : text
}
