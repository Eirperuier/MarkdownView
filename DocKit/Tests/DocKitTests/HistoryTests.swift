import Foundation
import Testing

@testable import DocKit

private let clientA = DocClientID(rawValue: UUID(uuidString: "00000000-0000-7000-8000-0000000000AA")!)

private func makeDoc(_ texts: [String]) -> Doc {
    Doc(id: fixedID(0), blocks: texts.enumerated().map {
        DocBlock(id: fixedID(UInt64($0.offset + 1)), kind: .paragraph, text: DocText(string: $0.element))
    })
}

private func type(_ client: inout DocClient, _ text: String, block: UInt64, at offset: Int, time: Int64, session: UInt64 = 1) throws {
    try client.apply(
        DocTransaction(
            steps: [.insertText(block: fixedID(block), at: offset, text: DocText(string: text))],
            author: .person(client: clientA), time: fixedTime(time)
        ),
        merge: DocHistory.MergeKey(block: fixedID(block), session: session)
    )
}

@Suite
struct HistoryTests {
    @Test
    func undoRedoRestoreExactDocs() throws {
        var client = DocClient(doc: makeDoc(["ab"]), seq: 0, client: clientA, author: .person(client: clientA))
        let original = client.doc
        try type(&client, "X", block: 1, at: 1, time: 0)
        try type(&client, "Y", block: 1, at: 2, time: 2000, session: 2)
        let edited = client.doc
        let didUndo1 = client.undo()
        #expect(didUndo1)
        #expect(client.doc.blocks[0].text.string == "aXb")
        let didUndo2 = client.undo()
        #expect(didUndo2)
        #expect(client.doc == original)
        let didRedo13 = client.redo()
        #expect(didRedo13)
        let didRedo14 = client.redo()
        #expect(didRedo14)
        #expect(client.doc == edited)
        let didRedo15 = client.redo()
        #expect(!didRedo15)
    }

    /// Same merge key inside the interval collapses into one undo entry.
    @Test
    func merging() throws {
        var client = DocClient(doc: makeDoc([""]), seq: 0, client: clientA, author: .person(client: clientA))
        try type(&client, "a", block: 1, at: 0, time: 0)
        try type(&client, "b", block: 1, at: 1, time: 1000)
        try type(&client, "c", block: 1, at: 2, time: 1499)
        let didUndo3 = client.undo()
        #expect(didUndo3)
        #expect(client.doc.blocks[0].text.string == "")
        let didUndo11 = client.undo()
        #expect(!didUndo11)
    }

    @Test
    func noMergeAcrossKeysOrInterval() throws {
        var client = DocClient(doc: makeDoc(["", ""]), seq: 0, client: clientA, author: .person(client: clientA))
        try type(&client, "a", block: 1, at: 0, time: 0)
        try type(&client, "b", block: 1, at: 1, time: 2000)  // interval exceeded
        try type(&client, "c", block: 2, at: 0, time: 2001)  // different block
        let didUndo4 = client.undo()
        #expect(didUndo4)
        #expect(client.doc.blocks[0].text.string == "ab")
        let didUndo5 = client.undo()
        #expect(didUndo5)
        #expect(client.doc.blocks[0].text.string == "a")
        let didUndo6 = client.undo()
        #expect(didUndo6)
        #expect(client.doc.blocks[0].text.string == "")
    }

    /// A remote change maps history instead of clearing the redo stack;
    /// a local change clears it.
    @Test
    func redoClearedLocallyNotRemotely() throws {
        var client = DocClient(doc: makeDoc(["ab", "cd"]), seq: 0, client: clientA, author: .person(client: clientA))
        try type(&client, "X", block: 1, at: 0, time: 0)
        let didUndo7 = client.undo()
        #expect(didUndo7)
        #expect(client.history.canRedo)
        client.receive([
            DocLogEntry(
                seq: 1, opID: fixedID(99), client: fixedID(2),
                author: .person(client: fixedID(2)), time: fixedTime(1),
                steps: [.insertText(block: fixedID(2), at: 0, text: DocText(string: "R"))]
            ),
        ])
        #expect(client.history.canRedo)
        try type(&client, "Y", block: 1, at: 0, time: 10)
        #expect(!client.history.canRedo)
    }

    /// Undo reverts only the local change; the remote one stays.
    @Test
    func undoAfterRemoteEditInOtherBlock() throws {
        var client = DocClient(doc: makeDoc(["mine", "theirs"]), seq: 0, client: clientA, author: .person(client: clientA))
        try type(&client, "!", block: 1, at: 4, time: 0)
        client.receive([
            DocLogEntry(
                seq: 1, opID: fixedID(99), client: fixedID(2),
                author: .person(client: fixedID(2)), time: fixedTime(1),
                steps: [.insertText(block: fixedID(2), at: 0, text: DocText(string: "R"))]
            ),
        ])
        let didUndo8 = client.undo()
        #expect(didUndo8)
        #expect(client.doc.blocks[0].text.string == "mine")
        #expect(client.doc.blocks[1].text.string == "Rtheirs")
    }

    /// When the block an undo entry pointed at is deleted remotely, the
    /// entry is skipped and the previous one undoes instead.
    @Test
    func entryOnRemotelyDeletedBlockIsSkipped() throws {
        var client = DocClient(doc: makeDoc(["first", "second"]), seq: 0, client: clientA, author: .person(client: clientA))
        try type(&client, "a", block: 1, at: 0, time: 0)
        try type(&client, "b", block: 2, at: 0, time: 2000, session: 2)
        client.receive([
            DocLogEntry(
                seq: 1, opID: fixedID(99), client: fixedID(2),
                author: .person(client: fixedID(2)), time: fixedTime(1),
                steps: [.deleteBlock(block: DocBlock(id: fixedID(2), kind: .paragraph), after: nil)]
            ),
        ])
        // The "b" insert's inverse can't apply: the entry is skipped.
        let didUndo9 = client.undo()
        #expect(didUndo9)
        #expect(client.doc.blocks[0].text.string == "first")
        let didUndo12 = client.undo()
        #expect(!didUndo12)
    }

    /// Undo produces ordinary pending steps that sync like local edits.
    @Test
    func undoGoesIntoPending() throws {
        var client = DocClient(doc: makeDoc(["x"]), seq: 0, client: clientA, author: .person(client: clientA))
        try type(&client, "y", block: 1, at: 1, time: 0)
        let pendingAfterEdit = client.pending.count
        let didUndo10 = client.undo()
        #expect(didUndo10)
        #expect(client.pending.count == pendingAfterEdit + 1)
    }
}
