import Foundation
import Testing

@testable import DocKit

private func makeDoc(_ texts: [String]) -> Doc {
    Doc(id: fixedID(0), blocks: texts.enumerated().map {
        DocBlock(id: fixedID(UInt64($0.offset + 1)), kind: .paragraph, text: DocText(string: $0.element))
    })
}

private func tx(_ steps: [DocStep], client: DocClientID = fixedID(1), time: Int64 = 0) -> DocTransaction {
    DocTransaction(steps: steps, author: .person(client: client), time: fixedTime(time))
}

@Suite
struct SyncTests {
    /// Three clients, one server, a random interleaving of local edits,
    /// submissions, behind/receive cycles and pulls — then a full drain.
    /// Everyone must land on the same doc, equal to replaying the log.
    @Test
    func convergence() throws {
        let iterations = ProcessInfo.processInfo.environment["DOCKIT_CONVERGENCE_ITERATIONS"].flatMap(Int.init) ?? 300
        for iteration in 0..<iterations {
            let seed = UInt64(iteration) &+ 0x51AC_0000
            var rng = SplitMix64(seed: seed)
            let initial = RandomDoc.doc(using: &rng)
            var server = InMemoryDocServer()
            var clients = (0..<3).map {
                DocClient(
                    doc: initial, seq: 0,
                    client: Identifier.generate(at: fixedTime(10 + Int64($0)), using: &rng),
                    author: .person(client: fixedID(UInt64($0 + 1)))
                )
            }

            for _ in 0..<60 {
                let index = Int(rng.next() % 3)
                switch rng.next() % 6 {
                case 0, 1, 2:
                    // A local transaction of 1-3 random steps, each valid
                    // against the doc the previous ones leave behind.
                    var scratch = clients[index].doc
                    var steps: [DocStep] = []
                    for _ in 0..<(1 + rng.next() % 3) {
                        if let step = RandomStep.step(in: scratch, using: &rng), (try? scratch.apply(step)) != nil {
                            steps.append(step)
                        }
                    }
                    if !steps.isEmpty {
                        try? clients[index].apply(tx(steps, client: clients[index].client, time: Int64(rng.next() % 1000)))
                    }
                case 3:
                    _ = rng.next() % 2 == 0 ? clients[index].undo() : clients[index].redo()
                case 4:
                    submit(&clients[index], to: &server, using: &rng)
                default:
                    clients[index].receive(server.entries(after: clients[index].seq))
                }
            }

            // Drain: submit and deliver until nothing moves anymore.
            for _ in 0..<200 {
                var moved = false
                for index in clients.indices {
                    if !clients[index].pending.isEmpty { moved = true }
                    submit(&clients[index], to: &server, using: &rng)
                    let missing = server.entries(after: clients[index].seq)
                    if !missing.isEmpty {
                        clients[index].receive(missing)
                        moved = true
                    }
                }
                if !moved { break }
            }

            var replay = initial
            var seq = 0
            while true {
                let entries = server.entries(after: seq)
                guard let entry = entries.first else { break }
                for step in entry.steps {
                    do {
                        try replay.apply(step)
                    } catch {
                        Issue.record("seed \(seed) replay seq \(entry.seq) failed: \(error) step \(step)")
                        throw error
                    }
                }
                seq = entry.seq
            }

            for (index, client) in clients.enumerated() {
                #expect(client.pending.isEmpty, "seed \(seed) client \(index) still pending")
                #expect(client.doc == replay, "seed \(seed) client \(index) diverged")
                #expect(client.confirmed == replay, "seed \(seed) client \(index) confirmed diverged")
                do {
                    try client.doc.validate()
                } catch {
                    Issue.record("seed \(seed) client \(index) invalid: \(error) doc \(client.doc)")
                    throw error
                }
            }
        }
    }

    /// Submits the client's inflight package (creating one from pending if
    /// needed), resolving `.behind` by catching up and resubmitting.
    private func submit(_ client: inout DocClient, to server: inout InMemoryDocServer, using rng: inout SplitMix64) {
        while let submission = client.inflight ?? client.submission(
            opID: Identifier.generate(at: fixedTime(1), using: &rng), time: fixedTime(2)
        ) {
            switch server.submit(submission) {
            case .accepted:
                return
            case .behind(let missing):
                client.receive(missing)
            }
        }
    }

    @Test
    func typingInDifferentBlocksKeepsBoth() throws {
        var server = InMemoryDocServer()
        var a = DocClient(doc: makeDoc(["alpha", "beta"]), seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
        var b = DocClient(doc: makeDoc(["alpha", "beta"]), seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

        try a.apply(tx([.insertText(block: fixedID(1), at: 5, text: DocText(string: "!"))], client: fixedID(1)))
        try b.apply(tx([.insertText(block: fixedID(2), at: 0, text: DocText(string: ">"))], client: fixedID(2)))

        let subA = try submission(from: &a, opID: fixedID(10), time: fixedTime(1))
        _ = try accepted(server.submit(subA))
        let subB = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        let missing = try behind(server.submit(subB))
        b.receive(missing)
        let retry = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        _ = try accepted(server.submit(retry))

        a.receive(server.entries(after: a.seq))
        b.receive(server.entries(after: b.seq))
        #expect(a.doc == b.doc)
        #expect(a.doc.blocks[0].text.string == "alpha!")
        #expect(a.doc.blocks[1].text.string == ">beta")
    }

    /// Two inserts at the same offset come out in server (log) order.
    @Test
    func concurrentInsertsSameOffset() throws {
        var server = InMemoryDocServer()
        var a = DocClient(doc: makeDoc(["ab"]), seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
        var b = DocClient(doc: makeDoc(["ab"]), seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

        try a.apply(tx([.insertText(block: fixedID(1), at: 1, text: DocText(string: "A"))], client: fixedID(1)))
        try b.apply(tx([.insertText(block: fixedID(1), at: 1, text: DocText(string: "B"))], client: fixedID(2)))

        let subA = try submission(from: &a, opID: fixedID(10), time: fixedTime(1))
        _ = try accepted(server.submit(subA))
        let subB = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        let missing = try behind(server.submit(subB))
        b.receive(missing)
        let retry = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        _ = try accepted(server.submit(retry))

        a.receive(server.entries(after: a.seq))
        b.receive(server.entries(after: b.seq))
        // A landed first in the log, so B's insert mapped after it.
        #expect(a.doc.blocks[0].text.string == "aABb")
        #expect(b.doc.blocks[0].text.string == "aABb")
    }

    /// A local edit to a block deleted remotely is dropped and reported.
    @Test
    func editOnDeletedBlockDrops() throws {
        var server = InMemoryDocServer()
        var a = DocClient(doc: makeDoc(["keep", "gone"]), seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
        var b = DocClient(doc: makeDoc(["keep", "gone"]), seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

        try a.apply(tx([.insertText(block: fixedID(2), at: 0, text: DocText(string: "x"))], client: fixedID(1)))
        try b.apply(tx([.deleteBlock(block: DocBlock(id: fixedID(2), kind: .paragraph), after: nil)], client: fixedID(2)))
        let subB = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        _ = try accepted(server.submit(subB))

        let dropped = a.receive(server.entries(after: a.seq))
        #expect(dropped.count == 1)
        #expect(a.doc.blocks.count == 1)
        #expect(a.pending.isEmpty)
    }

    /// A remote split of the block being typed in moves the local insert
    /// into the new block.
    @Test
    func typingFollowsRemoteSplit() throws {
        var server = InMemoryDocServer()
        var a = DocClient(doc: makeDoc(["helloworld"]), seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
        var b = DocClient(doc: makeDoc(["helloworld"]), seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

        try a.apply(tx([.insertText(block: fixedID(1), at: 8, text: DocText(string: "!"))], client: fixedID(1)))
        try b.apply(tx([.splitBlock(block: fixedID(1), at: 5, newID: fixedID(9), newKind: .paragraph, newIndent: 0)], client: fixedID(2)))
        let subB = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        _ = try accepted(server.submit(subB))

        a.receive(server.entries(after: a.seq))
        #expect(a.doc.blocks.count == 2)
        #expect(a.doc.blocks[0].text.string == "hello")
        #expect(a.doc.blocks[1].text.string == "wor!ld")
    }

    /// A remote delete straddling a local split becomes two pieces; the
    /// local step after the split must cross them as a sequence, once —
    /// not once per piece, which would insert its text twice.
    @Test
    func localStepCrossesSplitDeleteOnce() throws {
        var server = InMemoryDocServer()
        var a = DocClient(doc: makeDoc(["helloworld"]), seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
        var b = DocClient(doc: makeDoc(["helloworld"]), seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

        try a.apply(tx([
            .splitBlock(block: fixedID(1), at: 5, newID: fixedID(9), newKind: .paragraph, newIndent: 0),
            .insertText(block: fixedID(9), at: 0, text: DocText(string: "!")),
        ], client: fixedID(1)))
        try b.apply(tx([.deleteText(block: fixedID(1), range: 3..<8, removed: DocText())], client: fixedID(2)))
        let subB = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        _ = try accepted(server.submit(subB))
        a.receive(server.entries(after: a.seq))
        #expect(a.doc.blocks.map(\.text.string) == ["hel", "!ld"])

        let subA = try submission(from: &a, opID: fixedID(10), time: fixedTime(1))
        _ = try accepted(server.submit(subA))
        b.receive(server.entries(after: b.seq))
        #expect(a.doc == b.doc)
    }

    /// Type-then-backspace under the transform rebase: the pending delete
    /// addresses text the pending insert created, which the inverse-based
    /// rebase used to lose. The deleted "b" must stay deleted.
    @Test
    func typeThenBackspaceSurvivesRebase() throws {
        var server = InMemoryDocServer()
        var a = DocClient(doc: makeDoc(["0123456789"]), seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
        var b = DocClient(doc: makeDoc(["0123456789"]), seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

        try a.apply(tx([
            .insertText(block: fixedID(1), at: 5, text: DocText(string: "ab")),
            .deleteText(block: fixedID(1), range: 6..<7, removed: DocText()),
        ], client: fixedID(1)))
        try b.apply(tx([.insertText(block: fixedID(1), at: 0, text: DocText(string: "X"))], client: fixedID(2)))

        let subB = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        _ = try accepted(server.submit(subB))
        a.receive(server.entries(after: a.seq))
        #expect(a.doc.blocks[0].text.string == "X01234a56789")

        let subA = try submission(from: &a, opID: fixedID(10), time: fixedTime(1))
        _ = try accepted(server.submit(subA))
        b.receive(server.entries(after: b.seq))
        #expect(a.doc == b.doc)
        #expect(b.doc.blocks[0].text.string == "X01234a56789")
    }

    /// Undo after rebase: the history entry lives in current-doc
    /// coordinates, so it must be mapped through the remote steps *as
    /// transformed*, not the raw remote steps.
    @Test
    func undoAfterRemoteInsertRebases() throws {
        var server = InMemoryDocServer()
        var a = DocClient(doc: makeDoc(["0123456789"]), seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
        var b = DocClient(doc: makeDoc(["0123456789"]), seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

        try a.apply(tx([.insertText(block: fixedID(1), at: 5, text: DocText(string: "ab"))], client: fixedID(1)))
        try b.apply(tx([.insertText(block: fixedID(1), at: 6, text: DocText(string: "XYZ"))], client: fixedID(2)))

        let subB = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        _ = try accepted(server.submit(subB))
        a.receive(server.entries(after: a.seq))
        #expect(a.doc.blocks[0].text.string == "01234ab5XYZ6789")

        let didUndo = a.undo()
        #expect(didUndo)
        #expect(a.doc.blocks[0].text.string == "012345XYZ6789")

        // The undo itself is an ordinary submission and converges.
        let subA = try submission(from: &a, opID: fixedID(10), time: fixedTime(1))
        _ = try accepted(server.submit(subA))
        b.receive(server.entries(after: b.seq))
        #expect(a.doc == b.doc)
        #expect(b.doc.blocks[0].text.string == "012345XYZ6789")
    }

    /// A remote insert at the same offset as a pending local split is
    /// server-ordered first, so it lands inside the head block.
    @Test
    func remoteInsertBeforeLocalSplit() throws {
        var server = InMemoryDocServer()
        var a = DocClient(doc: makeDoc(["abcdef"]), seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
        var b = DocClient(doc: makeDoc(["abcdef"]), seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

        try a.apply(tx([.splitBlock(block: fixedID(1), at: 3, newID: fixedID(9), newKind: .paragraph, newIndent: 0)], client: fixedID(1)))
        try b.apply(tx([.insertText(block: fixedID(1), at: 3, text: DocText(string: "XY"))], client: fixedID(2)))

        let subB = try submission(from: &b, opID: fixedID(11), time: fixedTime(2))
        _ = try accepted(server.submit(subB))
        a.receive(server.entries(after: a.seq))
        // "XY" is ordered before the split point: it ends up in the head.
        #expect(a.doc.blocks.map(\.text.string) == ["abcXY", "def"])

        let subA = try submission(from: &a, opID: fixedID(10), time: fixedTime(1))
        _ = try accepted(server.submit(subA))
        b.receive(server.entries(after: b.seq))
        #expect(a.doc == b.doc)
        #expect(b.doc.blocks.map(\.text.string) == ["abcXY", "def"])
    }

    /// Two clients edit disjoint sets of blocks, then sync once: the
    /// transform must preserve every intent — nothing dropped, each block
    /// exactly its owner's version, both docs equal.
    @Test
    func disjointBlocksIntent() throws {
        let iterations = ProcessInfo.processInfo.environment["DOCKIT_CONVERGENCE_ITERATIONS"].flatMap(Int.init) ?? 300
        for iteration in 0..<iterations {
            let seed = UInt64(iteration) &+ 0xD150_0000
            var rng = SplitMix64(seed: seed)
            let initial = RandomDoc.doc(using: &rng)
            var server = InMemoryDocServer()
            var a = DocClient(doc: initial, seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
            var b = DocClient(doc: initial, seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

            let textBlocks = initial.blocks.filter { $0.kind.carriesText }.map(\.id)
            guard textBlocks.count >= 2 else { continue }
            let split = textBlocks.count / 2
            let aBlocks = Set(textBlocks[..<split])
            let bBlocks = Set(textBlocks[split...])

            for _ in 0..<(1 + rng.next() % 4) {
                var scratch = a.doc
                var steps: [DocStep] = []
                for _ in 0..<(1 + rng.next() % 3) {
                    if let step = RandomStep.textStep(in: scratch, restrictedTo: aBlocks, using: &rng),
                        (try? scratch.apply(step)) != nil
                    {
                        steps.append(step)
                    }
                }
                if !steps.isEmpty { try? a.apply(tx(steps, client: a.client)) }
            }
            for _ in 0..<(1 + rng.next() % 4) {
                var scratch = b.doc
                var steps: [DocStep] = []
                for _ in 0..<(1 + rng.next() % 3) {
                    if let step = RandomStep.textStep(in: scratch, restrictedTo: bBlocks, using: &rng),
                        (try? scratch.apply(step)) != nil
                    {
                        steps.append(step)
                    }
                }
                if !steps.isEmpty { try? b.apply(tx(steps, client: b.client)) }
            }

            // Each owner's pre-sync version of its blocks.
            let aLocal = Dictionary(uniqueKeysWithValues: a.doc.blocks.filter { aBlocks.contains($0.id) }.map { ($0.id, $0) })
            let bLocal = Dictionary(uniqueKeysWithValues: b.doc.blocks.filter { bBlocks.contains($0.id) }.map { ($0.id, $0) })

            // B lands first; A catches up, rebases and submits; B catches up.
            submit(&b, to: &server, using: &rng)
            let dropped = a.receive(server.entries(after: a.seq))
            submit(&a, to: &server, using: &rng)
            b.receive(server.entries(after: b.seq))

            #expect(a.doc == b.doc, "seed \(seed)")
            #expect(dropped.isEmpty, "seed \(seed) dropped \(dropped)")
            for block in a.doc.blocks {
                if aBlocks.contains(block.id) {
                    #expect(block == aLocal[block.id], "seed \(seed)")
                } else if bBlocks.contains(block.id) {
                    #expect(block == bLocal[block.id], "seed \(seed)")
                }
            }
        }
    }

    /// A types in one block while B edits others; after they sync, A's
    /// undo must revert only A's text and leave B's edits alone.
    @Test
    func undoAfterConcurrentSync() throws {
        for iteration in 0..<100 {
            let seed = UInt64(iteration) &+ 0x9D00_0000
            var rng = SplitMix64(seed: seed)
            let initial = RandomDoc.doc(using: &rng)
            var server = InMemoryDocServer()
            var a = DocClient(doc: initial, seq: 0, client: fixedID(1), author: .person(client: fixedID(1)))
            var b = DocClient(doc: initial, seq: 0, client: fixedID(2), author: .person(client: fixedID(2)))

            let textBlocks = initial.blocks.filter { $0.kind.carriesText }
            guard textBlocks.count >= 2 else { continue }
            let target = textBlocks.randomElement(using: &rng)!
            let bBlocks = Set(textBlocks.map(\.id)).subtracting([target.id])

            for _ in 0..<(1 + rng.next() % 3) {
                var scratch = a.doc
                var steps: [DocStep] = []
                for _ in 0..<(1 + rng.next() % 2) {
                    if let step = RandomStep.textStep(in: scratch, restrictedTo: [target.id], using: &rng),
                        (try? scratch.apply(step)) != nil
                    {
                        steps.append(step)
                    }
                }
                if !steps.isEmpty { try? a.apply(tx(steps, client: a.client)) }
            }
            for _ in 0..<(1 + rng.next() % 3) {
                var scratch = b.doc
                var steps: [DocStep] = []
                for _ in 0..<(1 + rng.next() % 2) {
                    if let step = RandomStep.textStep(in: scratch, restrictedTo: bBlocks, using: &rng),
                        (try? scratch.apply(step)) != nil
                    {
                        steps.append(step)
                    }
                }
                if !steps.isEmpty { try? b.apply(tx(steps, client: b.client)) }
            }

            // Sync: A first this time — either order must work.
            submit(&a, to: &server, using: &rng)
            b.receive(server.entries(after: b.seq))
            submit(&b, to: &server, using: &rng)
            a.receive(server.entries(after: a.seq))
            #expect(a.doc == b.doc, "seed \(seed)")

            // B's edits as they stood after the sync.
            let bVersions = Dictionary(uniqueKeysWithValues: a.doc.blocks.filter { bBlocks.contains($0.id) }.map { ($0.id, $0) })

            while a.history.canUndo { _ = a.undo() }

            let undone = a.doc.blocks.first { $0.id == target.id }
            #expect(undone?.text == target.text, "seed \(seed)")
            for block in a.doc.blocks where bBlocks.contains(block.id) {
                #expect(block == bVersions[block.id], "seed \(seed)")
            }
        }
    }
}
