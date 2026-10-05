/// The math delimiters MarkdownView recognises, ported from its
/// `MathParser` (itself from colinc86/LaTeXSwiftUI) so that import finds
/// exactly the formulas the renderer draws. UI-free; keep the two in step.
enum MathScanner {
    enum Kind: CaseIterable {
        case namedNoNumberEquation, namedEquation, blockEquation, texEquation, inlineParentheses, inlineDollar

        var left: String {
            switch self {
            case .inlineDollar: "$"
            case .inlineParentheses: "\\("
            case .texEquation: "$$"
            case .blockEquation: "\\["
            case .namedEquation: "\\begin{equation}"
            case .namedNoNumberEquation: "\\begin{equation*}"
            }
        }

        var right: String {
            switch self {
            case .inlineDollar: "$"
            case .inlineParentheses: "\\)"
            case .texEquation: "$$"
            case .blockEquation: "\\]"
            case .namedEquation: "\\end{equation}"
            case .namedNoNumberEquation: "\\end{equation*}"
            }
        }

        var isInline: Bool { self == .inlineDollar || self == .inlineParentheses }

        /// `$…$` may not have whitespace just inside its delimiters (the
        /// KaTeX rule that keeps "$5 and $10" from pairing up).
        func hasContent(_ text: Substring) -> Bool {
            let inner = text.dropFirst(left.count).dropLast(right.count)
            guard let first = inner.first, let last = inner.last else { return false }
            if self == .inlineDollar, first.isWhitespace || last.isWhitespace { return false }
            return !inner.allSatisfy { $0.isWhitespace || $0.isNewline }
        }
    }

    struct Match {
        var kind: Kind
        var range: Range<String.Index>
    }

    /// Top-level formulas in `text`, in order. Order of `Kind.allCases` is
    /// match priority: `$$` before `$`.
    static func matches(in text: Substring) -> [Match] {
        var stack: [Kind] = []
        var index = text.startIndex
        var start = index
        var result: [Match] = []
        scan: while index < text.endIndex {
            let remaining = text[index...]
            let escaped = index > text.startIndex && text[text.index(before: index)] == "\\"
            if !stack.isEmpty {
                for kind in Kind.allCases where remaining.hasPrefix(kind.right) {
                    if escaped {
                        index = text.index(index, offsetBy: kind.right.count)
                        continue scan
                    }
                    let end = text.index(index, offsetBy: kind.right.count)
                    if stack.last == kind {
                        stack.removeLast()
                        if stack.isEmpty, kind.hasContent(text[start..<end]) {
                            result.append(Match(kind: kind, range: start..<end))
                        }
                    }
                    index = end
                    continue scan
                }
            }
            for kind in Kind.allCases where remaining.hasPrefix(kind.left) {
                if escaped {
                    index = text.index(index, offsetBy: kind.left.count)
                    continue scan
                }
                if stack.isEmpty { start = index }
                stack.append(kind)
                index = text.index(index, offsetBy: kind.left.count)
                continue scan
            }
            index = text.index(after: index)
        }
        return result
    }

    /// The LaTeX a match stores: delimiters stripped for `$`, `$$`, `\(`
    /// and `\[`; a named environment keeps its `\begin…\end`, which numbering
    /// depends on.
    static func latex(of match: Match, in text: some StringProtocol) -> String {
        let source = text[match.range]
        switch match.kind {
        case .namedEquation, .namedNoNumberEquation:
            return String(source)
        case .texEquation, .blockEquation:
            return String(source.dropFirst(match.kind.left.count).dropLast(match.kind.right.count).trimmed())
        case .inlineDollar, .inlineParentheses:
            return String(source.dropFirst(match.kind.left.count).dropLast(match.kind.right.count))
        }
    }
}

extension StringProtocol {
    /// Without leading and trailing whitespace and newlines. (Foundation's
    /// `trimmingCharacters` isn't in FoundationEssentials on Linux.)
    func trimmed() -> SubSequence {
        let start = firstIndex { !$0.isWhitespace } ?? endIndex
        let end = lastIndex { !$0.isWhitespace }.map(index(after:)) ?? start
        return self[start..<end]
    }
}
