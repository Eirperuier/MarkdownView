/// Inline content of a block: a string plus mark ranges. All offsets are
/// UTF-16 code units, matching TextKit and JavaScript.
///
/// Atoms (mention, inlineMath, cite) occupy exactly one U+FFFC in `string`,
/// covered by exactly one span of length 1; the atom's payload lives on the
/// mark, so the string alone stays plain.
public struct DocText: Hashable, Sendable, Codable {
    public var string: String
    public var marks: [MarkSpan]

    public init(string: String = "", marks: [MarkSpan] = []) {
        self.string = string
        self.marks = marks
    }

    /// Length in UTF-16 code units: the unit every offset uses.
    public var length: Int { string.utf16.count }

    public var isEmpty: Bool { string.isEmpty }

    /// The object replacement character every atom is stored as.
    public static let atomCharacter: Character = "\u{FFFC}"

    /// Whether `offset` may be addressed: inside `0...length` and not inside
    /// a surrogate pair. (Only lead surrogates need checking; a valid string
    /// never ends one half way through a pair.)
    public func isValidOffset(_ offset: Int) -> Bool {
        guard offset >= 0, offset <= length else { return false }
        guard offset > 0 else { return true }
        let previous = string.utf16[string.utf16.index(string.utf16.startIndex, offsetBy: offset - 1)]
        return !(0xD800...0xDBFF).contains(previous)
    }

    /// Puts `marks` into canonical form: clipped to bounds, sorted by
    /// (start, end, mark kind), same-kind overlaps resolved, equal marks
    /// that touch merged. Idempotent, so `validate` can compare against it.
    public mutating func normalize() {
        let length = self.length
        var byKind: [MarkKind: [MarkSpan]] = [:]
        for span in marks.sorted(by: MarkSpan.order) {
            let clipped = max(0, min(length, span.range.lowerBound))..<max(0, min(length, span.range.upperBound))
            guard !clipped.isEmpty else { continue }
            byKind[span.mark.kind, default: []].append(MarkSpan(range: clipped, mark: span.mark))
        }
        marks = byKind.values.flatMap(Self.resolve).sorted(by: MarkSpan.order)
    }

    /// One kind's spans, in start order: merge equal marks that touch or
    /// overlap; for different marks of the same kind the later span wins the
    /// overlap, so two same-kind spans can never overlap afterwards.
    private static func resolve(_ spans: [MarkSpan]) -> [MarkSpan] {
        var result: [MarkSpan] = []
        for span in spans {
            guard var last = result.last else {
                result.append(span)
                continue
            }
            // Atoms never merge or clip: each U+FFFC keeps its own span,
            // even when two identical atoms sit side by side.
            if span.mark.kind.isAtom {
                result.append(span)
                continue
            }
            if span.range.lowerBound <= last.range.upperBound {
                if span.mark == last.mark {
                    last.range = last.range.lowerBound..<max(last.range.upperBound, span.range.upperBound)
                    result[result.count - 1] = last
                    continue
                }
                last.range = last.range.lowerBound..<span.range.lowerBound
                if last.range.isEmpty { result.removeLast() } else { result[result.count - 1] = last }
            }
            result.append(span)
        }
        return result
    }

    /// The slice `range` as a standalone text: marks clipped to the range
    /// and rebased to 0. This is `deleteText`'s `removed` and what undo
    /// needs to put deleted text back exactly.
    public func slice(_ range: Range<Int>) -> DocText {
        let scalars = [UInt16](string.utf16)
        let string = String(decoding: scalars[range], as: UTF16.self)
        let marks = marks.compactMap { span -> MarkSpan? in
            let lower = max(range.lowerBound, span.range.lowerBound)
            let upper = min(range.upperBound, span.range.upperBound)
            guard lower < upper else { return nil }
            let clipped = lower..<upper
            return MarkSpan(range: (clipped.lowerBound - range.lowerBound)..<(clipped.upperBound - range.lowerBound), mark: span.mark)
        }
        var text = DocText(string: string, marks: marks)
        text.normalize()
        return text
    }

    /// Inserts `other` at `at`, keeping exactly `other`'s marks. An existing
    /// span strictly containing `at` is split around the new text instead of
    /// growing over it, which is what makes insert/delete exact inverses.
    mutating func insert(_ other: DocText, at: Int) {
        let shift = other.length
        var spans: [MarkSpan] = []
        for span in marks {
            let range = span.range
            if range.upperBound <= at {
                spans.append(span)
            } else if range.lowerBound >= at {
                spans.append(MarkSpan(range: (range.lowerBound + shift)..<(range.upperBound + shift), mark: span.mark))
            } else {
                spans.append(MarkSpan(range: range.lowerBound..<at, mark: span.mark))
                spans.append(MarkSpan(range: (at + shift)..<(range.upperBound + shift), mark: span.mark))
            }
        }
        for span in other.marks {
            spans.append(MarkSpan(range: (span.range.lowerBound + at)..<(span.range.upperBound + at), mark: span.mark))
        }
        var scalars = [UInt16](string.utf16)
        scalars.insert(contentsOf: [UInt16](other.string.utf16), at: at)
        string = String(decoding: scalars, as: UTF16.self)
        marks = spans
        normalize()
    }

    /// Deletes `range`; spans clipped at the edges rejoin through
    /// `normalize`, so re-inserting the removed slice restores the original.
    mutating func delete(_ range: Range<Int>) {
        var scalars = [UInt16](string.utf16)
        scalars.removeSubrange(range)
        string = String(decoding: scalars, as: UTF16.self)
        let length = range.count
        marks = marks.compactMap { span in
            let lower = span.range.lowerBound <= range.lowerBound
                ? span.range.lowerBound
                : max(range.lowerBound, span.range.lowerBound - length)
            let upper = span.range.upperBound <= range.lowerBound
                ? span.range.upperBound
                : max(range.lowerBound, span.range.upperBound - length)
            let clipped = lower..<upper
            return clipped.isEmpty ? nil : MarkSpan(range: clipped, mark: span.mark)
        }
        normalize()
    }

    /// Replaces the marks of `kind` within `range` by `spans` (of that kind, inside
    /// the range); a mark reaching past the range keeps its parts outside. Returns
    /// the marks it took away, clipped to the range: what undo puts back.
    @discardableResult
    public mutating func setMarks(_ kind: MarkKind, in range: Range<Int>, to spans: [MarkSpan]) -> [MarkSpan] {
        var kept: [MarkSpan] = []
        var previous: [MarkSpan] = []
        for span in marks where span.mark.kind == kind {
            if span.range.upperBound <= range.lowerBound || span.range.lowerBound >= range.upperBound {
                kept.append(span)
            } else {
                if span.range.lowerBound < range.lowerBound {
                    kept.append(MarkSpan(range: span.range.lowerBound..<range.lowerBound, mark: span.mark))
                }
                if span.range.upperBound > range.upperBound {
                    kept.append(MarkSpan(range: range.upperBound..<span.range.upperBound, mark: span.mark))
                }
                let clipped = max(span.range.lowerBound, range.lowerBound)..<min(span.range.upperBound, range.upperBound)
                previous.append(MarkSpan(range: clipped, mark: span.mark))
            }
        }
        marks = marks.filter { $0.mark.kind != kind } + kept + spans
        normalize()
        return previous
    }

    /// The marks new text typed at `at` should get (editor helper; steps
    /// don't use it). Bold, italic, strike and highlight extend at their
    /// edges; code, link and atoms only apply strictly inside.
    public func marksForInsertion(at offset: Int) -> [Mark] {
        marks.compactMap { span in
            let range = span.range
            if span.mark.kind.extendsAtEdges {
                return range.lowerBound <= offset && offset <= range.upperBound ? span.mark : nil
            }
            return range.lowerBound < offset && offset < range.upperBound ? span.mark : nil
        }
    }
}

public struct MarkSpan: Hashable, Sendable, Codable {
    public var range: Range<Int>
    public var mark: Mark

    public init(range: Range<Int>, mark: Mark) {
        self.range = range
        self.mark = mark
    }

    /// Canonical order: position first, mark kind as tiebreak.
    static func order(_ a: MarkSpan, _ b: MarkSpan) -> Bool {
        if a.range.lowerBound != b.range.lowerBound { return a.range.lowerBound < b.range.lowerBound }
        if a.range.upperBound != b.range.upperBound { return a.range.upperBound < b.range.upperBound }
        return a.mark.kind.sortOrder < b.mark.kind.sortOrder
    }
}

public enum Mark: Hashable, Sendable, Codable {
    case bold
    case italic
    case strike
    case code
    case link(url: String)
    case highlight(color: String?)
    case mention(kind: String, id: String, label: String)
    case inlineMath(latex: String)
    case cite(url: String, label: String)
    /// Text in a colour: a palette name (`red`, `blue`, …) or `#RRGGBB`, the
    /// renderer's colour tokens (MarkdownView's `MarkdownColorToken`).
    case color(String)
    /// A hand-drawn mark over the text (MarkdownView's pen marks): `circle` or
    /// `wavy`, in a colour token (nil: the red pen).
    case pen(kind: String, color: String?)

    public var kind: MarkKind {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .strike: .strike
        case .code: .code
        case .link: .link
        case .highlight: .highlight
        case .mention: .mention
        case .inlineMath: .inlineMath
        case .cite: .cite
        case .color: .color
        case .pen: .pen
        }
    }
}

/// String raw values: the wire format must not silently change when cases
/// are reordered.
public enum MarkKind: String, Hashable, Sendable, Codable, CaseIterable {
    case bold
    case italic
    case strike
    case code
    case link
    case highlight
    case mention
    case inlineMath
    case cite
    case color
    case pen

    /// Sort position inside a span list; declaration order is canonical.
    var sortOrder: Int { Self.allCases.firstIndex(of: self)! }

    /// Atoms are whole objects: `setMarks` can't paint them on.
    public var isAtom: Bool {
        switch self {
        case .mention, .inlineMath, .cite: true
        case .bold, .italic, .strike, .code, .link, .highlight, .color, .pen: false
        }
    }

    /// Typing at the span's edge continues the mark.
    var extendsAtEdges: Bool {
        switch self {
        case .bold, .italic, .strike, .highlight, .color: true
        case .code, .link, .mention, .inlineMath, .cite, .pen: false
        }
    }
}
