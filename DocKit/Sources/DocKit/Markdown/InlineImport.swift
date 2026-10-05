#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif
import Markdown

/// Formulas lifted out of the source before cmark sees it, as MarkdownView
/// does (`MathFirstMarkdownViewRenderer.preprocessMath`): cmark would eat
/// the backslashes of `\(…\)` and the underscores inside `$…$`. Code blocks
/// and code spans are left alone. Display math standing on its own line
/// becomes a placeholder paragraph; inline math a placeholder in the text.
struct MathExtraction {
    static let displayOpen: Character = "\u{E000}"
    static let displayClose: Character = "\u{E001}"
    static let inlineOpen: Character = "\u{E002}"
    static let inlineClose: Character = "\u{E003}"

    private(set) var source: String
    private(set) var display: [String] = []
    private(set) var inline: [String] = []

    init(_ markdown: String) {
        source = markdown
        guard markdown.contains("$") || markdown.contains("\\") else { return }
        var excluded = CodeRanges()
        excluded.visit(Document(parsing: markdown))
        let segments = excluded.allowedRanges(in: markdown)
        for segment in segments.reversed() {
            for match in MathScanner.matches(in: source[segment]).reversed() {
                replace(match)
            }
        }
    }

    private mutating func replace(_ match: MathScanner.Match) {
        let latex = MathScanner.latex(of: match, in: source)
        if !match.kind.isInline {
            guard isStandalone(match.range) else { return }
            source.replaceSubrange(match.range, with: "\n\(Self.displayOpen)\(display.count)\(Self.displayClose)\n")
            display.append(latex)
            return
        }
        // Pandoc's currency rule: `$10/$50` is money, not a formula.
        if match.kind == .inlineDollar, match.range.upperBound < source.endIndex,
            source[match.range.upperBound].isNumber
        {
            return
        }
        source.replaceSubrange(match.range, with: "\(Self.inlineOpen)\(inline.count)\(Self.inlineClose)")
        inline.append(latex)
    }

    private func isStandalone(_ range: Range<String.Index>) -> Bool {
        let lineStart = source[..<range.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let lineEnd = source[range.upperBound...].firstIndex(of: "\n") ?? source.endIndex
        return source[lineStart..<range.lowerBound].allSatisfy { $0 == " " || $0 == "\t" }
            && source[range.upperBound..<lineEnd].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The LaTeX of a paragraph that is nothing but a display placeholder.
    func displayLatex(_ paragraph: String) -> String? {
        let trimmed = paragraph.trimmed()
        guard trimmed.first == Self.displayOpen, trimmed.last == Self.displayClose,
            let index = Int(trimmed.dropFirst().dropLast()), display.indices.contains(index)
        else { return nil }
        return display[index]
    }
}

/// Code blocks and code spans, as source ranges to keep math out of.
private struct CodeRanges: MarkupWalker {
    private var ranges: [SourceRange] = []

    mutating func defaultVisit(_ markup: any Markup) {
        descendInto(markup)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        if let range = codeBlock.range { ranges.append(range) }
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        if let range = inlineCode.range { ranges.append(range) }
    }

    func allowedRanges(in text: String) -> [Range<String.Index>] {
        let excluded = ranges.map { $0.lowerBound.index(in: text)..<max($0.lowerBound.index(in: text), $0.upperBound.index(in: text)) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var allowed: [Range<String.Index>] = []
        var start = text.startIndex
        for range in excluded {
            if start < range.lowerBound { allowed.append(start..<range.lowerBound) }
            start = max(start, range.upperBound)
        }
        if start < text.endIndex { allowed.append(start..<text.endIndex) }
        return allowed
    }
}

extension SourceLocation {
    /// cmark's 1-based line and UTF-8 column, as an index into `text`.
    fileprivate func index(in text: String) -> String.Index {
        var index = text.startIndex
        var currentLine = 1
        while currentLine < line, index < text.endIndex {
            if text[index] == "\n" { currentLine += 1 }
            index = text.index(after: index)
        }
        let utf8 = text.utf8
        let target = utf8.index(index, offsetBy: column - 1, limitedBy: utf8.endIndex) ?? utf8.endIndex
        return target.samePosition(in: text) ?? text.endIndex
    }
}

/// Builds a block's `DocText` from cmark's inline tree: marks from the
/// containers, atoms from placeholders and cite links, then `==highlight==`
/// matched on the finished text the way MarkdownView matches it.
struct InlineBuilder {
    let inlineMath: [String]
    private var string = ""
    private var length = 0
    private var spans: [MarkSpan] = []

    init(inlineMath: [String]) {
        self.inlineMath = inlineMath
    }

    /// Drops the characters the model reserves: U+FFFC (atoms) and the
    /// math placeholders.
    static func cleaned(_ text: String) -> String {
        text.filter { $0 != DocText.atomCharacter && !("\u{E000}"..."\u{E003}").contains($0) }
    }

    private mutating func append(_ text: String, marks: [Mark]) {
        let text = Self.cleaned(text)
        let count = text.utf16.count
        guard count > 0 else { return }
        for mark in marks { spans.append(MarkSpan(range: length..<(length + count), mark: mark)) }
        string += text
        length += count
    }

    /// Atoms carry no other marks.
    private mutating func appendAtom(_ mark: Mark) {
        spans.append(MarkSpan(range: length..<(length + 1), mark: mark))
        string.append(DocText.atomCharacter)
        length += 1
    }

    mutating func walk(_ markup: any Markup, marks: [Mark]) {
        switch markup {
        case let text as Text:
            appendText(text.string, marks: marks)
        case is Emphasis:
            for child in markup.children { walk(child, marks: marks + [.italic]) }
        case is Strong:
            for child in markup.children { walk(child, marks: marks + [.bold]) }
        case is Strikethrough:
            for child in markup.children { walk(child, marks: marks + [.strike]) }
        case let code as InlineCode:
            append(code.code, marks: marks + [.code])
        case let link as Link:
            if link.title == "cite" {
                appendAtom(.cite(url: link.destination ?? "", label: Self.cleaned(link.plainText)))
            } else {
                for child in markup.children { walk(child, marks: marks + [.link(url: link.destination ?? "")]) }
            }
        case let image as Image:
            append(image.plainText, marks: marks)
        case is SoftBreak, is LineBreak:
            append("\n", marks: marks)
        case let html as InlineHTML:
            append(html.rawHTML, marks: marks)
        default:
            if markup.childCount > 0 {
                for child in markup.children { walk(child, marks: marks) }
            } else if let plain = markup as? any PlainTextConvertibleMarkup {
                append(plain.plainText, marks: marks)
            }
        }
    }

    /// Text with inline-math placeholders turned into atoms.
    private mutating func appendText(_ text: String, marks: [Mark]) {
        var rest = Substring(text)
        while let open = rest.firstIndex(of: MathExtraction.inlineOpen),
            let close = rest[open...].firstIndex(of: MathExtraction.inlineClose)
        {
            append(String(rest[..<open]), marks: marks)
            if let index = Int(rest[rest.index(after: open)..<close]), inlineMath.indices.contains(index) {
                appendAtom(.inlineMath(latex: inlineMath[index]))
            }
            rest = rest[rest.index(after: close)...]
        }
        append(String(rest), marks: marks)
    }

    func finish() -> DocText {
        var text = DocText(string: string, marks: spans)
        text.normalize()
        text.applyHighlightSyntax()
        return text
    }
}

extension DocText {
    /// Turns `==text==` into highlight marks with MarkdownView's matcher
    /// (`MarkdownHighlightSyntax.matchOffsets`): within one line, not part
    /// of `===`, non-empty. Delimiters inside code spans stay literal.
    fileprivate mutating func applyHighlightSyntax() {
        guard string.contains("==") else { return }
        let characters = Array(string)
        var utf16Offsets = [0]
        var running = 0
        for character in characters {
            running += character.utf16.count
            utf16Offsets.append(running)
        }
        let code = marks.filter { $0.mark == .code }.map(\.range)
        func inCode(_ offset: Int) -> Bool { code.contains { $0.contains(offset) } }
        for match in Self.highlightMatches(characters).reversed() {
            let open = utf16Offsets[match.start]..<utf16Offsets[match.innerStart]
            let close = utf16Offsets[match.innerEnd]..<utf16Offsets[match.end]
            guard !(open.contains(where: inCode) || close.contains(where: inCode)) else { continue }
            delete(close)
            delete(open)
            // Atoms carry no other marks: the highlight goes around them.
            let atoms = Set(marks.filter { $0.mark.kind.isAtom }.map(\.range.lowerBound))
            for piece in (open.lowerBound..<(close.lowerBound - open.count)).split(atoms.contains) {
                marks.append(MarkSpan(range: piece, mark: .highlight(color: nil)))
            }
            normalize()
        }
    }

    private static func highlightMatches(_ chars: [Character]) -> [(start: Int, innerStart: Int, innerEnd: Int, end: Int)] {
        let n = chars.count
        var matches: [(start: Int, innerStart: Int, innerEnd: Int, end: Int)] = []
        var i = 0
        while i < n {
            guard chars[i] == "=", i + 1 < n, chars[i + 1] == "=",
                !(i > 0 && chars[i - 1] == "="), !(i + 2 < n && chars[i + 2] == "=")
            else {
                i += 1
                continue
            }
            let innerStart = i + 2
            var j = innerStart
            var closed = false
            while j < n, chars[j] != "\n" {
                if chars[j] == "=", j + 1 < n, chars[j + 1] == "=" {
                    if j > innerStart {
                        matches.append((i, innerStart, j, j + 2))
                        i = j + 2
                        closed = true
                        break
                    }
                    j += 2
                    continue
                }
                j += 1
            }
            if !closed { i += 1 }
        }
        return matches
    }
}
