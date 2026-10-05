import Foundation
import Testing

@testable import DocKit

@Suite
struct StepPropertyTests {
    /// Random valid doc + random valid step of every kind: apply must keep
    /// the doc valid, the inverse must restore it exactly, and the resolved
    /// step must be re-applicable and self-inverting.
    @Test
    func applyValidateInvert() throws {
        for iteration in 0..<300 {
            let seed = UInt64(iteration) &+ 0xD0C1_7E57
            var rng = SplitMix64(seed: seed)
            var doc = RandomDoc.doc(using: &rng)
            try doc.validate()
            guard let step = RandomStep.step(in: doc, using: &rng) else { continue }
            let original = doc
            let resolved = try doc.apply(step)
            try doc.validate()

            var reverted = doc
            try reverted.apply(resolved.inverted)
            #expect(reverted == original, "seed \(seed): \(resolved) did not invert")
            #expect(resolved.inverted.inverted == resolved, "seed \(seed)")

            var replay = original
            try replay.apply(resolved)
            #expect(replay == doc, "seed \(seed): resolved step is not idempotent")
        }
    }

    /// Several steps in one transaction: still atomic, still invertible as a
    /// whole through the history-style reverse-inverse.
    @Test
    func transactionSequence() throws {
        for iteration in 0..<300 {
            let seed = UInt64(iteration) &+ 0xBEEF_0000
            var rng = SplitMix64(seed: seed)
            var doc = RandomDoc.doc(using: &rng)
            let original = doc
            // Each step is generated against the doc the previous steps
            // left behind, so the transaction is valid as a whole.
            var scratch = doc
            var steps: [DocStep] = []
            for _ in 0..<(1 + rng.next() % 4) {
                if let step = RandomStep.step(in: scratch, using: &rng), (try? scratch.apply(step)) != nil {
                    steps.append(step)
                }
            }
            guard !steps.isEmpty else { continue }
            let resolved = try doc.apply(
                DocTransaction(steps: steps, author: .person(client: fixedID(1)), time: fixedTime(100))
            )
            try doc.validate()
            var reverted = doc
            for step in resolved.steps.reversed() {
                try reverted.apply(step.inverted)
            }
            #expect(reverted == original, "seed \(seed)")
        }
    }
}

@Suite
struct CodableTests {
    @Test
    func docRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for iteration in 0..<300 {
            let seed = UInt64(iteration) &+ 0xCAFE_0001
            var rng = SplitMix64(seed: seed)
            let doc = RandomDoc.doc(using: &rng)
            let first = try encoder.encode(doc)
            let second = try encoder.encode(doc)
            #expect(first == second, "seed \(seed): encoding is not deterministic")
            #expect(try decoder.decode(Doc.self, from: first) == doc, "seed \(seed)")
        }
    }

    @Test
    func stepRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        var rng = SplitMix64(seed: 42)
        var doc = RandomDoc.doc(using: &rng)
        for _ in 0..<50 {
            guard let step = RandomStep.step(in: doc, using: &rng) else { continue }
            guard let resolved = try? doc.apply(step) else { continue }
            let data = try encoder.encode(resolved)
            #expect(try decoder.decode(DocStep.self, from: data) == resolved)
        }
    }
}
