import Foundation

@testable import DocKit

/// Seeded, reproducible RNG for the property tests; every test records the
/// seed it ran with so a failure can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}

/// Deterministic ids for tests: `fixedID(1)` … `fixedID(99)` sort in order.
func fixedID<Tag>(_ n: UInt64) -> Identifier<Tag> {
    let raw = UUID(uuidString: String(format: "00000000-0000-7000-8000-%012X", n))!
    return Identifier(rawValue: raw)
}

func fixedTime(_ milliseconds: Int64) -> Timestamp {
    Timestamp(millisecondsSince1970: milliseconds)
}

extension DocText {
    /// Every offset a step may legally address.
    var boundaries: [Int] {
        (0...length).filter { isValidOffset($0) }
    }
}

enum RandomDoc {
    private static let fragments = [
        "the quick ", "brown fox ", "jumps", " over", "lazy dog",
        "中文测试", "文档", "日本語",
        "😀", "👨‍👩‍👧", "🇫🇷", "🎉",
        "let x = 1", "a²+b²", "tail",
    ]

    /// A random mark of a non-atom kind.
    static func mark(_ kind: MarkKind, using rng: inout SplitMix64) -> Mark {
        switch kind {
        case .bold: .bold
        case .italic: .italic
        case .strike: .strike
        case .code: .code
        case .link: .link(url: "https://example.com/\(rng.next() % 100)")
        case .highlight: .highlight(color: rng.next() % 2 == 0 ? "yellow" : nil)
        case .mention: .mention(kind: "person", id: "u\(rng.next() % 100)", label: "User")
        case .inlineMath: .inlineMath(latex: "x^{\(rng.next() % 10)}")
        case .cite: .cite(url: "https://ref.example.com/\(rng.next() % 100)", label: "[\(rng.next() % 10)]")
        }
    }

    static func text(allowAtoms: Bool = true, allowMarks: Bool = true, using rng: inout SplitMix64) -> DocText {
        var string = ""
        var atoms: [(offset: Int, mark: Mark)] = []
        for _ in 0..<(1 + rng.next() % 6) {
            if allowAtoms && rng.next() % 8 == 0 {
                atoms.append((string.utf16.count, atomMark(using: &rng)))
                string.append(DocText.atomCharacter)
            } else {
                string.append(fragments[Int(rng.next() % UInt64(fragments.count))])
            }
        }
        var text = DocText(string: string)
        var spans = atoms.map { MarkSpan(range: $0.offset..<($0.offset + 1), mark: $0.mark) }
        if allowMarks {
            let atomOffsets = Set(atoms.map(\.offset))
            for _ in 0..<(rng.next() % 3) {
                let kind = MarkKind.allCases.filter { !$0.isAtom }.randomElement(using: &rng)!
                let span = randomSpan(in: text.boundaries, avoiding: atomOffsets, using: &rng)
                if let span {
                    spans.append(MarkSpan(range: span, mark: mark(kind, using: &rng)))
                }
            }
        }
        text.marks = spans
        text.normalize()
        return text
    }

    private static func atomMark(using rng: inout SplitMix64) -> Mark {
        switch rng.next() % 3 {
        case 0: .mention(kind: "person", id: "u\(rng.next() % 100)", label: "User")
        case 1: .inlineMath(latex: "e^{i\\pi}")
        default: .cite(url: "https://ref.example.com/\(rng.next() % 100)", label: "ref")
        }
    }

    /// A random non-empty range on scalar boundaries that contains no atom
    /// character (marks may never cover an atom).
    static func randomSpan(in boundaries: [Int], avoiding atoms: Set<Int>, using rng: inout SplitMix64) -> Range<Int>? {
        for _ in 0..<8 {
            guard let a = boundaries.randomElement(using: &rng),
                let b = boundaries.randomElement(using: &rng), a != b
            else { continue }
            let range = min(a, b)..<max(a, b)
            if atoms.contains(where: { range.contains($0) }) { continue }
            return range
        }
        return nil
    }

    static func blockKind(allowsText: Bool, using rng: inout SplitMix64) -> BlockKind {
        if !allowsText {
            switch rng.next() % 3 {
            case 0: return .divider
            case 1: return .image(image: DocImage(source: "https://img.example.com/\(rng.next() % 10)"))
            default: return .card(card: DocCard(size: "medium", view: "chart", source: "floo.chart", data: ["x": 1]))
            }
        } else {
            switch rng.next() % 8 {
            case 0, 1: return .paragraph
            case 2: return .heading(level: Int(rng.next() % 6) + 1)
            case 3: return .listItem(style: .bullet)
            case 4: return .listItem(style: .task(done: rng.next() % 2 == 0))
            case 5: return .quote
            case 6: return .code(language: rng.next() % 2 == 0 ? "swift" : nil)
            default: return .math
            }
        }
    }

    /// `allowsMarks` must follow the kind: code/math text stays bare.
    static func block(using rng: inout SplitMix64, id: DocBlockID? = nil) -> DocBlock {
        let kind = blockKind(allowsText: rng.next() % 5 > 0, using: &rng)
        let text = kind.carriesText
            ? text(allowAtoms: kind.allowsMarks, allowMarks: kind.allowsMarks, using: &rng)
            : DocText()
        return DocBlock(id: id ?? Identifier.generate(at: fixedTime(1), using: &rng), kind: kind, indent: Int(rng.next() % 7), text: text)
    }

    static func doc(using rng: inout SplitMix64) -> Doc {
        var doc = Doc(id: Identifier.generate(at: fixedTime(1), using: &rng))
        for _ in 0..<(1 + rng.next() % 10) {
            doc.blocks.append(block(using: &rng))
        }
        if rng.next() % 3 == 0 {
            let database = self.database(using: &rng)
            let view = DatabaseView.table(hidden: [], sort: [])
            doc.databases[database.id] = database
            let index = Int(rng.next() % UInt64(doc.blocks.count + 1))
            doc.blocks.insert(DocBlock(id: Identifier.generate(at: fixedTime(2), using: &rng), kind: .database(id: database.id, view: view)), at: index)
        }
        return doc
    }

    static func database(using rng: inout SplitMix64) -> Database {
        var database = Database(id: Identifier.generate(at: fixedTime(3), using: &rng))
        for _ in 0..<(1 + rng.next() % 4) {
            database.columns.append(Column(id: Identifier.generate(at: fixedTime(4), using: &rng), name: "c\(database.columns.count)", type: .text))
        }
        for _ in 0..<(rng.next() % 4) {
            var cells: [ColumnID: CellValue] = [:]
            for column in database.columns where rng.next() % 2 == 0 {
                cells[column.id] = .text(value: "v\(rng.next() % 100)")
            }
            database.rows.append(Row(id: Identifier.generate(at: fixedTime(5), using: &rng), cells: cells))
        }
        return database
    }
}

/// A step that is valid against `doc`, biased so every case comes up.
enum RandomStep {
    static func step(in doc: Doc, using rng: inout SplitMix64) -> DocStep? {
        let choice = rng.next() % 14
        switch choice {
        case 0: return insertText(in: doc, using: &rng)
        case 1: return deleteText(in: doc, using: &rng)
        case 2: return setMarks(in: doc, using: &rng)
        case 3: return split(in: doc, using: &rng)
        case 4: return join(in: doc, using: &rng)
        case 5: return .insertBlock(block: RandomDoc.block(using: &rng), after: doc.blocks.randomElement(using: &rng)?.id)
        case 6: return doc.blocks.randomElement(using: &rng).map { .deleteBlock(block: $0, after: nil) }
        case 7:
            guard let block = doc.blocks.randomElement(using: &rng) else { return nil }
            let after = doc.blocks.filter { $0.id != block.id }.randomElement(using: &rng)?.id
            return .moveBlock(block: block.id, after: after, from: nil)
        case 8: return setBlock(in: doc, using: &rng)
        case 9: return .createDatabase(database: RandomDoc.database(using: &rng))
        case 10:
            // Sorted: a dictionary's order changes from run to run, and with it the steps.
            let deletable = doc.databases.values.sorted { $0.id < $1.id }.filter { database in
                !doc.blocks.contains { $0.kind.databaseID == database.id }
            }
            return deletable.randomElement(using: &rng).map { .deleteDatabase(database: $0) }
        default: return databaseStep(in: doc, using: &rng)
        }
    }

    private static func textBlock(in doc: Doc, using rng: inout SplitMix64) -> DocBlock? {
        doc.blocks.filter { $0.kind.carriesText }.randomElement(using: &rng)
    }

    /// A text-only step (insertText, deleteText or setMarks) confined to
    /// one of `ids` — used by the disjoint-block intent property, where two
    /// clients each own a set of blocks.
    static func textStep(in doc: Doc, restrictedTo ids: Set<DocBlockID>, using rng: inout SplitMix64) -> DocStep? {
        guard let block = doc.blocks.filter({ ids.contains($0.id) }).randomElement(using: &rng) else { return nil }
        switch rng.next() % 3 {
        case 0:
            return insertText(in: block, using: &rng)
        case 1:
            return deleteText(in: block, using: &rng) ?? insertText(in: block, using: &rng)
        default:
            guard block.kind.allowsMarks else { return insertText(in: block, using: &rng) }
            return setMarks(in: block, using: &rng) ?? insertText(in: block, using: &rng)
        }
    }

    private static func insertText(in doc: Doc, using rng: inout SplitMix64) -> DocStep? {
        guard let block = textBlock(in: doc, using: &rng) else { return nil }
        return insertText(in: block, using: &rng)
    }

    private static func insertText(in block: DocBlock, using rng: inout SplitMix64) -> DocStep {
        let at = block.text.boundaries.randomElement(using: &rng)!
        let text = RandomDoc.text(allowAtoms: block.kind.allowsMarks, allowMarks: block.kind.allowsMarks, using: &rng)
        return .insertText(block: block.id, at: at, text: text)
    }

    private static func deleteText(in doc: Doc, using rng: inout SplitMix64) -> DocStep? {
        guard let block = textBlock(in: doc, using: &rng) else { return nil }
        return deleteText(in: block, using: &rng)
    }

    private static func deleteText(in block: DocBlock, using rng: inout SplitMix64) -> DocStep? {
        let atoms = atomOffsets(in: block.text)
        guard let range = RandomDoc.randomSpan(in: block.text.boundaries, avoiding: atoms, using: &rng) else { return nil }
        return .deleteText(block: block.id, range: range, removed: DocText())
    }

    private static func setMarks(in doc: Doc, using rng: inout SplitMix64) -> DocStep? {
        let markable = doc.blocks.filter { $0.kind.allowsMarks }
        guard let block = markable.randomElement(using: &rng) else { return nil }
        return setMarks(in: block, using: &rng)
    }

    private static func setMarks(in block: DocBlock, using rng: inout SplitMix64) -> DocStep? {
        let atoms = atomOffsets(in: block.text)
        guard let range = RandomDoc.randomSpan(in: block.text.boundaries, avoiding: atoms, using: &rng) else { return nil }
        let kind = MarkKind.allCases.filter { !$0.isAtom }.randomElement(using: &rng)!
        let spans = rng.next() % 2 == 0 ? [] : [MarkSpan(range: range, mark: RandomDoc.mark(kind, using: &rng))]
        return .setMarks(block: block.id, range: range, kind: kind, spans: spans, previous: [])
    }

    private static func split(in doc: Doc, using rng: inout SplitMix64) -> DocStep? {
        guard let block = textBlock(in: doc, using: &rng) else { return nil }
        guard let at = block.text.boundaries.randomElement(using: &rng) else { return nil }
        let tail = block.text.slice(at..<block.text.length)
        let newKind = tail.isEmpty ? RandomDoc.blockKind(allowsText: true, using: &rng) : randomTextKind(marks: tail.marks, using: &rng)
        return .splitBlock(
            block: block.id, at: at,
            newID: Identifier.generate(at: fixedTime(6), using: &rng),
            newKind: newKind, newIndent: Int(rng.next() % 7)
        )
    }

    private static func join(in doc: Doc, using rng: inout SplitMix64) -> DocStep? {
        let indices = doc.blocks.indices.filter { index in
            index > 0 && doc.blocks[index].kind.carriesText && doc.blocks[index - 1].kind.carriesText
                && (doc.blocks[index - 1].kind.allowsMarks || doc.blocks[index].text.marks.isEmpty)
        }
        guard let index = indices.randomElement(using: &rng) else { return nil }
        return .joinBlock(
            block: doc.blocks[index].id, into: doc.blocks[index - 1].id,
            at: 0, kind: .paragraph, indent: 0
        )
    }

    private static func setBlock(in doc: Doc, using rng: inout SplitMix64) -> DocStep? {
        guard let block = doc.blocks.randomElement(using: &rng) else { return nil }
        let kind = block.text.isEmpty
            ? RandomDoc.blockKind(allowsText: rng.next() % 4 > 0, using: &rng)
            : randomTextKind(marks: block.text.marks, using: &rng)
        if case .database = kind { return nil }
        return .setBlock(block: block.id, kind: kind, indent: Int(rng.next() % 7), previousKind: .paragraph, previousIndent: 0)
    }

    /// A text-bearing kind compatible with the given marks.
    private static func randomTextKind(marks: [MarkSpan], using rng: inout SplitMix64) -> BlockKind {
        if marks.isEmpty && rng.next() % 4 == 0 {
            return rng.next() % 2 == 0 ? .code(language: "swift") : .math
        }
        switch rng.next() % 4 {
        case 0: return .paragraph
        case 1: return .heading(level: Int(rng.next() % 6) + 1)
        case 2: return .listItem(style: .numbered)
        default: return .quote
        }
    }

    private static func atomOffsets(in text: DocText) -> Set<Int> {
        Set(text.string.utf16.enumerated().compactMap { $0.element == 0xFFFC ? $0.offset : nil })
    }

    private static func databaseStep(in doc: Doc, using rng: inout SplitMix64) -> DocStep? {
        guard let database = doc.databases.values.sorted(by: { $0.id < $1.id }).randomElement(using: &rng) else { return nil }
        switch rng.next() % 7 {
        case 0:
            guard let row = database.rows.randomElement(using: &rng),
                let column = database.columns.randomElement(using: &rng)
            else { return nil }
            let value = rng.next() % 3 == 0 ? nil : CellValue.text(value: "x\(rng.next() % 50)")
            return .database(id: database.id, step: .setCell(row: row.id, column: column.id, value: value, previous: nil))
        case 1:
            let row = Row(id: Identifier.generate(at: fixedTime(7), using: &rng))
            return .database(id: database.id, step: .insertRow(row: row, after: database.rows.randomElement(using: &rng)?.id))
        case 2:
            guard let row = database.rows.randomElement(using: &rng) else { return nil }
            return .database(id: database.id, step: .deleteRow(row: row, after: nil))
        case 3:
            guard let row = database.rows.randomElement(using: &rng) else { return nil }
            let after = database.rows.filter { $0.id != row.id }.randomElement(using: &rng)?.id
            return .database(id: database.id, step: .moveRow(row: row.id, after: after, from: nil))
        case 4:
            let column = Column(id: Identifier.generate(at: fixedTime(8), using: &rng), name: "new", type: .number)
            return .database(
                id: database.id,
                step: .insertColumn(column: column, after: database.columns.randomElement(using: &rng)?.id, cells: [:])
            )
        case 5:
            guard let column = database.columns.randomElement(using: &rng) else { return nil }
            return .database(id: database.id, step: .deleteColumn(column: column, after: nil, cells: [:]))
        default:
            guard let column = database.columns.randomElement(using: &rng) else { return nil }
            var renamed = column
            renamed.name = "renamed-\(rng.next() % 10)"
            return .database(id: database.id, step: .updateColumn(column: renamed, previous: column))
        }
    }
}

/// The wrong `DocSubmitResult` case reached a test helper.
struct UnexpectedSubmitResult: Error {}

/// Unwraps `.accepted` or throws, so tests can `try accepted(...)`.
func accepted(_ result: DocSubmitResult) throws -> Int {
    guard case .accepted(let seq) = result else { throw UnexpectedSubmitResult() }
    return seq
}

/// Unwraps `.behind` or throws, so tests can `try behind(...)`.
func behind(_ result: DocSubmitResult) throws -> [DocLogEntry] {
    guard case .behind(let missing) = result else { throw UnexpectedSubmitResult() }
    return missing
}

/// `submission` is mutating, which `#require` can't wrap — this helper
/// unwraps and throws instead.
func submission(from client: inout DocClient, opID: DocOperationID, time: Timestamp) throws -> DocSubmission {
    guard let submission = client.submission(opID: opID, time: time) else { throw UnexpectedSubmitResult() }
    return submission
}
