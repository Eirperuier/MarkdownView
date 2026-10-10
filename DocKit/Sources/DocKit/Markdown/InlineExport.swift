extension DocText {
    /// This text as inline markdown, in the dialect MarkdownView renders:
    /// `**bold**`, `*italic*`, `~~strike~~`, `==highlight==`, `` `code` ``,
    /// `[link](url)`, `$math$`, `[label](url "cite")`; a colour, a coloured
    /// highlight and a pen mark as `^[text](color: red)`, `^[text](highlight: yellow)`,
    /// `^[text](pen: circle, ink: blue)`.
    ///
    /// Lossy on purpose where markdown can't say it: whitespace at a mark's
    /// edge moves outside it, leading spaces of a line go, a mention becomes
    /// its label.
    /// `singleLine` (headings, table cells) turns line breaks into spaces.
    /// `preservingWhitespace` (the editing style) writes spaces and tabs at a
    /// line's edges as entities, which markdown would otherwise drop.
    func markdown(singleLine: Bool = false, escapingPipes: Bool = false, preservingWhitespace: Bool = false) -> String {
        var writer = InlineWriter(text: self, singleLine: singleLine, escapingPipes: escapingPipes, preservesWhitespace: preservingWhitespace)
        let output = writer.write()
        return preservingWhitespace ? Self.entitizingLineEdges(output) : output
    }

    /// Leading and trailing spaces/tabs of every line as `&#32;`/`&#9;`.
    private static func entitizingLineEdges(_ markdown: String) -> String {
        func entity(_ character: Character) -> String { character == "\t" ? "&#9;" : "&#32;" }
        func isBlank(_ character: Character) -> Bool { character == " " || character == "\t" }
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let leading = line.prefix(while: isBlank)
            let rest = line.dropFirst(leading.count)
            let trailing = rest.reversed().prefix(while: isBlank)
            let middle = rest.dropLast(trailing.count)
            return leading.map(entity).joined() + middle + trailing.reversed().map(entity).joined()
        }.joined(separator: "\n")
    }
}

private struct InlineWriter {
    let units: [UInt16]
    let singleLine: Bool
    let escapingPipes: Bool
    let preservesWhitespace: Bool
    /// Non-atom spans as emitted: no boundary falls inside a code span.
    let spans: [MarkSpan]
    let atoms: [Int: Mark]
    var output = ""
    var stack: [MarkSpan] = []
    var atLineStart = true

    init(text: DocText, singleLine: Bool, escapingPipes: Bool, preservesWhitespace: Bool = false) {
        units = Array(text.string.utf16)
        self.singleLine = singleLine
        self.escapingPipes = escapingPipes
        self.preservesWhitespace = preservesWhitespace
        var atoms: [Int: Mark] = [:]
        for span in text.marks where span.mark.kind.isAtom {
            atoms[span.range.lowerBound] = span.mark
        }
        self.atoms = atoms
        spans = Self.emittable(text.marks, units: units, atoms: Set(atoms.keys))
    }

    /// Code spans are cut at atoms; other marks' edges are pushed out of
    /// code (a code span can't be interrupted); a highlight is cut at line
    /// breaks (MarkdownView matches `==` within a line); marks over
    /// whitespace alone are dropped.
    private static func emittable(_ marks: [MarkSpan], units: [UInt16], atoms: Set<Int>) -> [MarkSpan] {
        let newline: UInt16 = 0x0A
        var code: [Range<Int>] = []
        for span in marks where span.mark == .code {
            code += span.range.split { atoms.contains($0) }
        }
        var result = code.map { MarkSpan(range: $0, mark: .code) }
        for span in marks where !span.mark.kind.isAtom && span.mark != .code {
            var lower = span.range.lowerBound
            var upper = span.range.upperBound
            for range in code {
                if range.lowerBound < lower, lower < range.upperBound { lower = range.lowerBound }
                if range.lowerBound < upper, upper < range.upperBound { upper = range.upperBound }
            }
            let pieces = span.mark == .highlight(color: nil)
                ? (lower..<upper).split { units[$0] == newline }
                : [lower..<upper]
            for piece in pieces where piece.contains(where: { !Self.isSpace(units[$0]) }) {
                result.append(MarkSpan(range: piece, mark: span.mark))
            }
        }
        return result
    }

    static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A
    }

    mutating func write() -> String {
        var cuts = Set([0, units.count])
        for span in spans { cuts.formUnion([span.range.lowerBound, span.range.upperBound]) }
        for offset in atoms.keys { cuts.formUnion([offset, offset + 1]) }
        let bounds = cuts.sorted()
        for (lower, upper) in zip(bounds, bounds.dropFirst()) {
            let active = spans.filter { $0.range.lowerBound <= lower && upper <= $0.range.upperBound }
            close(keeping: active)
            let opening = active.filter { span in !stack.contains(span) && span.mark != .code }
                .sorted { ($0.range.upperBound, -$0.mark.kind.sortOrder) > ($1.range.upperBound, -$1.mark.kind.sortOrder) }
            if let atom = atoms[lower] {
                open(opening)
                writeAtom(atom, at: lower)
            } else if active.contains(where: { $0.mark == .code }) {
                open(opening)
                writeCode(lower..<upper)
            } else {
                writeText(lower..<upper, opening: opening)
            }
        }
        close(keeping: [])
        return output
    }

    /// Closes every open mark above the first one no longer active, so the
    /// delimiters nest; the survivors above it are reopened by the caller.
    private mutating func close(keeping active: [MarkSpan]) {
        guard let first = stack.firstIndex(where: { !active.contains($0) }) else { return }
        var closers = ""
        for span in stack[first...].reversed() { closers += Self.closer(span.mark) }
        stack.removeSubrange(first...)
        // Closers go before trailing whitespace: `**a** b`, not `**a **b`.
        let trailing = output.reversed().prefix { $0 == " " || $0 == "\t" || $0 == "\n" }.count
        output.insert(contentsOf: closers, at: output.index(output.endIndex, offsetBy: -trailing))
    }

    private mutating func open(_ spans: [MarkSpan]) {
        guard !spans.isEmpty else { return }
        for span in spans {
            output += Self.opener(span.mark)
            stack.append(span)
        }
        atLineStart = false
    }

    private static func opener(_ mark: Mark) -> String {
        switch mark {
        case .bold: "**"
        case .italic: "*"
        case .strike: "~~"
        case .highlight(nil): "=="
        case .highlight, .color, .pen: "^["
        case .link: "["
        case .code, .mention, .inlineMath, .cite: ""
        }
    }

    /// A colour, a coloured highlight and a pen mark are inline attributes,
    /// `^[text](color: red)`, which MarkdownView renders (MarkdownInlineStyle).
    private static func closer(_ mark: Mark) -> String {
        switch mark {
        case .link(let url): "](\(InlineEscaping.destination(url)))"
        case .highlight(let color?): "](highlight: \(token(color)))"
        case .color(let color): "](color: \(token(color)))"
        case .pen(let kind, let color): "](pen: \(token(kind))\(color.map { ", ink: \(token($0))" } ?? ""))"
        case .code, .mention, .inlineMath, .cite: ""
        default: opener(mark)
        }
    }

    /// A colour token or pen kind as an attribute value: letters, digits, `#` and `-`.
    private static func token(_ value: String) -> String {
        String(value.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "#" || $0 == "-") })
    }

    private mutating func writeAtom(_ mark: Mark, at offset: Int) {
        switch mark {
        case .inlineMath(let latex):
            // A digit right after the closing `$` reads as currency.
            let digitFollows = offset + 1 < units.count && (0x30...0x39).contains(units[offset + 1])
            let dollarSafe = !latex.isEmpty && !latex.contains("$") && !digitFollows
                && latex.first?.isWhitespace == false && latex.last?.isWhitespace == false
            output += dollarSafe ? "$\(latex)$" : "\\(\(latex)\\)"
        case .cite(let url, let label):
            output += "[\(InlineEscaping.escaped(label, escapingPipes: escapingPipes, inLink: true))](\(InlineEscaping.destination(url)) \"cite\")"
        case .mention(_, _, let label):
            output += InlineEscaping.escaped(label, escapingPipes: escapingPipes)
        default:
            break
        }
        atLineStart = false
    }

    private mutating func writeCode(_ range: Range<Int>) {
        var content = String(decoding: units[range], as: UTF16.self)
        if singleLine { content = content.replacing("\n", with: " ") }
        var longest = 0
        var run = 0
        for character in content {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = content.hasPrefix("`") || content.hasSuffix("`")
            || (content.hasPrefix(" ") && content.hasSuffix(" ") && content.contains { $0 != " " })
        let inner = pad ? " \(content) " : content
        output += escapingPipes ? "\(fence)\(inner.replacing("|", with: "\\|"))\(fence)" : "\(fence)\(inner)\(fence)"
        atLineStart = false
    }

    /// Plain text, escaped. Openers go after the segment's leading
    /// whitespace so they always touch a word.
    private mutating func writeText(_ range: Range<Int>, opening: [MarkSpan]) {
        let text = String(decoding: units[range], as: UTF16.self)
        let leading = text.prefix { $0 == " " || $0 == "\t" }
        // At a line start the spaces are kept only in the editing style, where
        // the line-edge pass turns them into entities.
        if !atLineStart || preservesWhitespace { output += leading }
        if preservesWhitespace, !leading.isEmpty { atLineStart = false }
        open(opening)
        var line = Substring(text.dropFirst(leading.count))
        while !line.isEmpty {
            let end = line.firstIndex(of: "\n") ?? line.endIndex
            writeLine(line[..<end])
            guard end < line.endIndex else { break }
            // The editing style shows every line break: a soft break could render as
            // a space, so it is written hard.
            output += singleLine ? " " : (preservesWhitespace ? "\\\n" : "\n")
            atLineStart = !singleLine
            line = line[line.index(after: end)...]
        }
    }

    private mutating func writeLine(_ line: Substring) {
        var line = line
        if atLineStart, preservesWhitespace, let first = line.first, first == " " || first == "\t" {
            let blanks = line.prefix { $0 == " " || $0 == "\t" }
            output += blanks
            line = line.dropFirst(blanks.count)
            atLineStart = false
        }
        if atLineStart {
            line = line.drop { $0 == " " || $0 == "\t" }
            guard let first = line.first else { return }
            if "#>-+=".contains(first) {
                output += "\\"
            } else if first == "[", ["[ ]", "[x]", "[X]"].contains(where: line.hasPrefix) {
                // Would read as a task box at the start of a list item.
                output += "&#91;"
                line = line.dropFirst()
            } else if first.isASCII, first.isNumber {
                let digits = line.prefix { $0.isASCII && $0.isNumber }
                let rest = line.dropFirst(digits.count)
                if let mark = rest.first, mark == "." || mark == ")" {
                    output += digits
                    output += "\\"
                    line = rest
                }
            }
        }
        // Inside a link's or inline attributes' brackets a `[` would open another.
        let inLink = stack.contains { Self.opener($0.mark).hasSuffix("[") }
        output += InlineEscaping.escaped(line, escapingPipes: escapingPipes, inLink: inLink, literalPunctuation: preservesWhitespace)
        atLineStart = false
    }
}

/// The escaping rules inline export shares with image alt text and
/// link destinations.
enum InlineEscaping {
    static func destination(_ url: String) -> String {
        let plain = !url.isEmpty && !url.contains { " <>()\n\t".contains($0) }
        if plain { return url }
        return "<" + url.replacing("<", with: "\\<").replacing(">", with: "\\>") + ">"
    }

    /// Backslash escapes, except `[`: MarkdownView lifts `\[…\]` out as
    /// display math before cmark runs, so an escaped bracket would turn
    /// into a formula. A lone `[` can't start a link while every `]` is
    /// escaped; inside link text, where it could pair with the link's own
    /// `]`, it becomes `&#91;`.
    /// `literalPunctuation` (the editing style) also escapes what the renderer's smart
    /// punctuation would turn typographic: quotes, and `--` / `...` runs.
    static func escaped(_ text: some StringProtocol, escapingPipes: Bool = false, inLink: Bool = false, literalPunctuation: Bool = false) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if literalPunctuation, character == "'" || character == "\"" || ((character == "-" || character == ".") && isRun(of: character, at: index, in: text)) {
                result += "\\"
                result.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "[" {
                result += inLink ? "&#91;" : "["
                index = text.index(after: index)
                continue
            }
            // `^[` would open inline attributes (a colour, a pen mark).
            if character == "^", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "[" {
                result += "\\"
            }
            if "\\`*_]<~$".contains(character) || (escapingPipes && character == "|") {
                result.append("\\")
            } else if character == "&", isEntity(text[text.index(after: index)...]) {
                result.append("\\")
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// The character next to `index` (either side) is the same one.
    private static func isRun<S: StringProtocol>(of character: Character, at index: S.Index, in text: S) -> Bool {
        let next = text.index(after: index)
        if next < text.endIndex, text[next] == character { return true }
        return index > text.startIndex && text[text.index(before: index)] == character
    }

    /// `&` followed by `name;` or `#123;` would be read as an entity.
    private static func isEntity(_ rest: some StringProtocol) -> Bool {
        let body = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "#") }
        return !body.isEmpty && rest.dropFirst(body.count).first == ";"
    }
}

extension Range<Int> {
    /// The maximal sub-ranges whose offsets don't satisfy `isSeparator`.
    func split(_ isSeparator: (Int) -> Bool) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = lowerBound
        for offset in self where isSeparator(offset) {
            if start < offset { pieces.append(start..<offset) }
            start = offset + 1
        }
        if start < upperBound { pieces.append(start..<upperBound) }
        return pieces
    }
}
