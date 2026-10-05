import Foundation
import Testing

@testable import DocKit

/// Table tests for `map` (position through a step) and `mapped(through:)`
/// (a step rebased over another).
@Suite
struct MapTests {
    private func p(_ offset: Int, block: DocBlockID = fixedID(1)) -> DocPosition {
        DocPosition(block: block, offset: offset)
    }

    @Test
    func insertTextPositions() {
        let step = DocStep.insertText(block: fixedID(1), at: 5, text: DocText(string: "abc"))
        #expect(step.map(p(3)) == p(3))
        #expect(step.map(p(5), bias: .before) == p(5))
        #expect(step.map(p(5), bias: .after) == p(8))
        #expect(step.map(p(9)) == p(12))
        #expect(step.map(p(9, block: fixedID(2))) == p(9, block: fixedID(2)))
    }

    @Test
    func deleteTextPositions() {
        let step = DocStep.deleteText(block: fixedID(1), range: 2..<6, removed: DocText(string: "abcd"))
        #expect(step.map(p(1)) == p(1))
        #expect(step.map(p(2)) == p(2))
        #expect(step.map(p(4)) == p(2))
        #expect(step.map(p(6)) == p(2))
        #expect(step.map(p(9)) == p(5))
    }

    @Test
    func splitBlockPositions() {
        let step = DocStep.splitBlock(block: fixedID(1), at: 5, newID: fixedID(9), newKind: .paragraph, newIndent: 0)
        #expect(step.map(p(4)) == p(4))
        #expect(step.map(p(5), bias: .before) == p(5))
        #expect(step.map(p(5), bias: .after) == p(0, block: fixedID(9)))
        #expect(step.map(p(8)) == p(3, block: fixedID(9)))
    }

    @Test
    func joinBlockPositions() {
        let step = DocStep.joinBlock(block: fixedID(2), into: fixedID(1), at: 5, kind: .paragraph, indent: 0)
        #expect(step.map(p(3, block: fixedID(2))) == p(8))
        #expect(step.map(p(3)) == p(3))
    }

    @Test
    func deleteBlockDropsPositions() {
        let block = DocBlock(id: fixedID(1), kind: .paragraph)
        #expect(DocStep.deleteBlock(block: block, after: nil).map(p(3)) == nil)
        #expect(DocStep.deleteBlock(block: block, after: nil).map(p(3, block: fixedID(2))) == p(3, block: fixedID(2)))
    }

    @Test
    func insertTextThroughInsertText() {
        let ours = DocStep.insertText(block: fixedID(1), at: 8, text: DocText(string: "X"))
        let theirs = DocStep.insertText(block: fixedID(1), at: 3, text: DocText(string: "ab"))
        #expect(ours.mapped(through: theirs) == [.insertText(block: fixedID(1), at: 10, text: DocText(string: "X"))])
    }

    @Test
    func insertTextAtSameOffsetKeepsOrder() {
        // The remote insert wins the shared offset: local text lands after it.
        let ours = DocStep.insertText(block: fixedID(1), at: 4, text: DocText(string: "L"))
        let theirs = DocStep.insertText(block: fixedID(1), at: 4, text: DocText(string: "R"))
        #expect(ours.mapped(through: theirs) == [.insertText(block: fixedID(1), at: 5, text: DocText(string: "L"))])
    }

    @Test
    func deleteTextRangeShrinksAroundRemoteInsert() {
        let ours = DocStep.deleteText(block: fixedID(1), range: 2..<8, removed: DocText())
        // An insert inside the range extends it: the range still covers the
        // original characters plus what landed between them.
        let insertedInside = DocStep.insertText(block: fixedID(1), at: 4, text: DocText(string: "xy"))
        #expect(ours.mapped(through: insertedInside) == [.deleteText(block: fixedID(1), range: 2..<10, removed: DocText())])
        let insertedBefore = DocStep.insertText(block: fixedID(1), at: 1, text: DocText(string: "xy"))
        #expect(ours.mapped(through: insertedBefore) == [.deleteText(block: fixedID(1), range: 4..<10, removed: DocText())])
    }

    /// A range that straddles the remote split point becomes two steps.
    @Test
    func rangeAcrossSplitBecomesTwoSteps() {
        let ours = DocStep.deleteText(block: fixedID(1), range: 2..<9, removed: DocText())
        let split = DocStep.splitBlock(block: fixedID(1), at: 5, newID: fixedID(9), newKind: .paragraph, newIndent: 0)
        #expect(ours.mapped(through: split) == [
            .deleteText(block: fixedID(1), range: 2..<5, removed: DocText()),
            .deleteText(block: fixedID(9), range: 0..<4, removed: DocText()),
        ])
    }

    @Test
    func setMarksAcrossSplitKeepsSpansPerBlock() {
        let span = MarkSpan(range: 2..<9, mark: .bold)
        let ours = DocStep.setMarks(block: fixedID(1), range: 2..<9, kind: .bold, spans: [span], previous: [])
        let split = DocStep.splitBlock(block: fixedID(1), at: 5, newID: fixedID(9), newKind: .paragraph, newIndent: 0)
        #expect(ours.mapped(through: split) == [
            .setMarks(
                block: fixedID(1), range: 2..<5, kind: .bold,
                spans: [MarkSpan(range: 2..<5, mark: .bold)], previous: []
            ),
            .setMarks(
                block: fixedID(9), range: 0..<4, kind: .bold,
                spans: [MarkSpan(range: 0..<4, mark: .bold)], previous: []
            ),
        ])
    }

    @Test
    func stepsOnRemovedBlocksDrop() {
        let deleted = DocBlock(id: fixedID(1), kind: .paragraph)
        let delete = DocStep.deleteBlock(block: deleted, after: nil)
        #expect(DocStep.setBlock(block: fixedID(1), kind: .quote, indent: 0, previousKind: .paragraph, previousIndent: 0).mapped(through: delete) == [])
        let join = DocStep.joinBlock(block: fixedID(1), into: fixedID(0), at: 3, kind: .paragraph, indent: 0)
        // Text addresses follow the join; other edits drop.
        #expect(DocStep.insertText(block: fixedID(1), at: 2, text: DocText(string: "x")).mapped(through: join) == [
            .insertText(block: fixedID(0), at: 5, text: DocText(string: "x")),
        ])
        #expect(DocStep.setBlock(block: fixedID(1), kind: .quote, indent: 0, previousKind: .paragraph, previousIndent: 0).mapped(through: join) == [])
    }

    @Test
    func anchorsFollowDeletedAndJoinedBlocks() {
        let newBlock = DocBlock(id: fixedID(5), kind: .paragraph)
        let delete = DocStep.deleteBlock(block: DocBlock(id: fixedID(2), kind: .paragraph), after: fixedID(1))
        #expect(DocStep.insertBlock(block: newBlock, after: fixedID(2)).mapped(through: delete) == [
            .insertBlock(block: newBlock, after: fixedID(1)),
        ])
        let join = DocStep.joinBlock(block: fixedID(2), into: fixedID(1), at: 4, kind: .paragraph, indent: 0)
        #expect(DocStep.moveBlock(block: fixedID(3), after: fixedID(2), from: nil).mapped(through: join) == [
            .moveBlock(block: fixedID(3), after: fixedID(1), from: nil),
        ])
    }

    /// A join whose `into` was split retargets the split's new block: that
    /// is what now sits directly before the joining block.
    @Test
    func joinRetargetsSplitInto() {
        let join = DocStep.joinBlock(block: fixedID(2), into: fixedID(1), at: 0, kind: .paragraph, indent: 0)
        let split = DocStep.splitBlock(block: fixedID(1), at: 3, newID: fixedID(9), newKind: .paragraph, newIndent: 0)
        #expect(join.mapped(through: split) == [
            .joinBlock(block: fixedID(2), into: fixedID(9), at: 0, kind: .paragraph, indent: 0),
        ])
    }

    @Test
    func databaseStepsDropWithTheirRowOrColumn() {
        let drop: DocStep = .database(id: fixedID(1), step: .deleteRow(row: Row(id: fixedID(7)), after: nil))
        #expect(
            DocStep.database(id: fixedID(1), step: .setCell(row: fixedID(7), column: fixedID(2), value: nil, previous: nil))
                .mapped(through: drop) == []
        )
        #expect(
            DocStep.database(id: fixedID(1), step: .insertRow(row: Row(id: fixedID(8)), after: fixedID(7)))
                .mapped(through: drop)
                == [.database(id: fixedID(1), step: .insertRow(row: Row(id: fixedID(8)), after: nil))]
        )
        #expect(
            DocStep.database(id: fixedID(1), step: .setCell(row: fixedID(9), column: fixedID(2), value: nil, previous: nil))
                .mapped(through: .deleteDatabase(database: Database(id: fixedID(1)))) == []
        )
    }
}
