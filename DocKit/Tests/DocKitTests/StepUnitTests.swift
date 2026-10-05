import Foundation
import Testing

@testable import DocKit

private func paragraph(_ string: String, marks: [MarkSpan] = [], id: DocBlockID = fixedID(1)) -> DocBlock {
    DocBlock(id: id, kind: .paragraph, text: DocText(string: string, marks: marks))
}

@Suite
struct StepUnitTests {
    /// Typing into the middle of a bold span splits it around the new text
    /// instead of growing over it; normalize merges it back seamlessly.
    @Test
    func insertIntoBoldDoesNotGrow() throws {
        var doc = Doc(id: fixedID(0), blocks: [
            paragraph("hello world", marks: [MarkSpan(range: 0..<11, mark: .bold)]),
        ])
        try doc.apply(.insertText(block: fixedID(1), at: 5, text: DocText(string: "!")))
        let text = doc.blocks[0].text
        #expect(text.string == "hello! world")
        #expect(text.marks == [MarkSpan(range: 0..<5, mark: .bold), MarkSpan(range: 6..<12, mark: .bold)])
    }

    /// delete → re-insert the removed slice restores the original spans.
    @Test
    func deleteThenReinsertRestores() throws {
        var doc = Doc(id: fixedID(0), blocks: [
            paragraph("0123456789", marks: [MarkSpan(range: 0..<10, mark: .bold)]),
        ])
        let resolved = try doc.apply(.deleteText(block: fixedID(1), range: 3..<5, removed: DocText()))
        #expect(doc.blocks[0].text.marks == [MarkSpan(range: 0..<8, mark: .bold)])
        try doc.apply(resolved.inverted)
        #expect(doc.blocks[0].text.marks == [MarkSpan(range: 0..<10, mark: .bold)])
        #expect(doc.blocks[0].text.string == "0123456789")
    }

    @Test
    func splitInsideSurrogatePairThrows() throws {
        var doc = Doc(id: fixedID(0), blocks: [paragraph("a😀b")])
        // "a😀b" is 4 UTF-16 units; offset 2 splits the emoji's surrogate pair.
        #expect(throws: DocError.notScalarBoundary) {
            try doc.apply(.splitBlock(block: fixedID(1), at: 2, newID: fixedID(2), newKind: .paragraph, newIndent: 0))
        }
        #expect(throws: DocError.notScalarBoundary) {
            try doc.apply(.insertText(block: fixedID(1), at: 2, text: DocText(string: "x")))
        }
    }

    @Test
    func splitJoinRoundTripWithCrossingMarks() throws {
        var doc = Doc(id: fixedID(0), blocks: [
            paragraph("hello world", marks: [MarkSpan(range: 3..<9, mark: .bold)], id: fixedID(1)),
        ])
        let split = try doc.apply(.splitBlock(block: fixedID(1), at: 6, newID: fixedID(2), newKind: .paragraph, newIndent: 0))
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0].text.string == "hello ")
        #expect(doc.blocks[0].text.marks == [MarkSpan(range: 3..<6, mark: .bold)])
        #expect(doc.blocks[1].text.string == "world")
        #expect(doc.blocks[1].text.marks == [MarkSpan(range: 0..<3, mark: .bold)])
        try doc.apply(split.inverted)
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].text.string == "hello world")
        #expect(doc.blocks[0].text.marks == [MarkSpan(range: 3..<9, mark: .bold)])
    }

    @Test
    func joinRequiresAdjacency() throws {
        var doc = Doc(id: fixedID(0), blocks: [
            paragraph("a", id: fixedID(1)), paragraph("b", id: fixedID(2)), paragraph("c", id: fixedID(3)),
        ])
        #expect(throws: DocError.nonAdjacentBlocks) {
            try doc.apply(.joinBlock(block: fixedID(3), into: fixedID(1), at: 0, kind: .paragraph, indent: 0))
        }
    }

    @Test
    func joinRequiresTextKinds() throws {
        var doc = Doc(id: fixedID(0), blocks: [
            DocBlock(id: fixedID(1), kind: .divider),
            paragraph("b", id: fixedID(2)),
        ])
        #expect(throws: DocError.joinRequiresText) {
            try doc.apply(.joinBlock(block: fixedID(2), into: fixedID(1), at: 0, kind: .paragraph, indent: 0))
        }
    }

    @Test
    func moveAfterItselfThrows() throws {
        var doc = Doc(id: fixedID(0), blocks: [paragraph("a"), paragraph("b", id: fixedID(2))])
        #expect(throws: DocError.invalidMove) {
            try doc.apply(.moveBlock(block: fixedID(1), after: fixedID(1), from: nil))
        }
    }

    @Test
    func setBlockDividerOnNonEmptyTextThrows() throws {
        var doc = Doc(id: fixedID(0), blocks: [paragraph("text")])
        #expect(throws: DocError.emptyTextRequired) {
            try doc.apply(.setBlock(block: fixedID(1), kind: .divider, indent: 0, previousKind: .paragraph, previousIndent: 0))
        }
    }

    @Test
    func marksOnCodeBlockThrow() throws {
        var doc = Doc(id: fixedID(0), blocks: [DocBlock(id: fixedID(1), kind: .code(language: "swift"), text: DocText(string: "let x = 1"))])
        // A marked paragraph can't become code: code never carries marks.
        var marked = Doc(id: fixedID(0), blocks: [paragraph("let x = 1", marks: [MarkSpan(range: 0..<3, mark: .bold)])])
        #expect(throws: DocError.marksNotAllowed) {
            try marked.apply(.setBlock(block: fixedID(1), kind: .code(language: nil), indent: 0, previousKind: .paragraph, previousIndent: 0))
        }
        #expect(throws: DocError.marksNotAllowed) {
            try doc.apply(
                .setMarks(block: fixedID(1), range: 0..<3, kind: .bold, spans: [MarkSpan(range: 0..<3, mark: .bold)], previous: [])
            )
        }
    }

    @Test
    func setMarksAtomKindThrows() throws {
        var doc = Doc(id: fixedID(0), blocks: [paragraph("text")])
        #expect(throws: DocError.atomKindReadOnly) {
            try doc.apply(
                .setMarks(
                    block: fixedID(1), range: 0..<2, kind: .mention,
                    spans: [MarkSpan(range: 0..<1, mark: .mention(kind: "p", id: "1", label: "x"))], previous: []
                )
            )
        }
    }

    @Test
    func failedTransactionLeavesDocUnchanged() throws {
        var doc = Doc(id: fixedID(0), blocks: [paragraph("a", id: fixedID(1)), paragraph("b", id: fixedID(2))])
        let original = doc
        let transaction = DocTransaction(
            steps: [
                .insertText(block: fixedID(1), at: 1, text: DocText(string: "x")),
                .insertText(block: fixedID(9), at: 0, text: DocText(string: "y")),
            ],
            author: .person(client: fixedID(1)), time: fixedTime(1)
        )
        #expect(throws: DocError.self) { try doc.apply(transaction) }
        #expect(doc == original)
    }

    /// The inclusivity table: bold-family extends at both edges, code/link/
    /// atoms only strictly inside.
    @Test
    func marksForInsertionTable() {
        let text = DocText(string: "0123456789", marks: [
            MarkSpan(range: 1..<4, mark: .bold),
            MarkSpan(range: 4..<6, mark: .code),
            MarkSpan(range: 6..<8, mark: .link(url: "u")),
        ])
        #expect(text.marksForInsertion(at: 1) == [.bold])
        #expect(text.marksForInsertion(at: 2) == [.bold])
        #expect(text.marksForInsertion(at: 4) == [.bold])
        #expect(text.marksForInsertion(at: 5) == [.code])
        #expect(text.marksForInsertion(at: 6) == [])
        #expect(text.marksForInsertion(at: 7) == [.link(url: "u")])
        #expect(text.marksForInsertion(at: 8) == [])
    }

    /// Every U+FFFC must carry its atom span and nothing else.
    @Test
    func atomValidation() throws {
        var text = DocText(string: "a\u{FFFC}b")
        #expect(throws: DocError.invalidAtom) { try text.validate() }
        text.marks = [MarkSpan(range: 1..<2, mark: .inlineMath(latex: "x"))]
        try text.validate()
        text.marks.append(MarkSpan(range: 0..<3, mark: .bold))
        #expect(throws: DocError.self) { try text.validate() }
    }

    /// A view of a database a collaborator deleted can't come back (an undo of the
    /// view's deletion, say): it would point at nothing. And a database a collaborator
    /// shows again isn't deleted.
    @Test
    func viewsOfDeletedDatabases() throws {
        let database = Database(id: fixedID(70), columns: [Column(id: fixedID(71), name: "a", type: .text)])
        let view = DocBlock(id: fixedID(72), kind: .database(id: database.id, view: .table(hidden: [], sort: [])))
        let insert = DocStep.insertBlock(block: view, after: nil)
        let delete = DocStep.deleteDatabase(database: database)
        #expect(insert.mapped(through: delete).isEmpty)
        #expect(delete.mapped(through: insert).isEmpty)
        #expect(DocStep.setBlock(block: fixedID(73), kind: view.kind, indent: 0, previousKind: .paragraph, previousIndent: 0).mapped(through: delete).isEmpty)
        var doc = Doc(id: fixedID(0))
        #expect(throws: DocError.self) { try doc.apply(insert) }
        try doc.apply(.createDatabase(database: database))
        try doc.apply(insert)
    }
}
