import Foundation
import Testing

@testable import DocKit

/// Golden JSON cases shared with the future TypeScript port: an initial doc,
/// the step list, the resolved steps and the final doc, all with fixed ids
/// and times. `DOCKIT_RECORD_GOLDEN=1` rewrites the files.
@Suite
struct GoldenTests {
    struct Case: Codable {
        var doc: Doc
        var steps: [DocStep]
        var resolved: [DocStep]
        var final: Doc
    }

    private static let names = [
        "text-edits", "marks", "split-join", "block-ops", "block-ops-2", "databases",
    ]

    @Test(arguments: names)
    func golden(name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()

        if ProcessInfo.processInfo.environment["DOCKIT_RECORD_GOLDEN"] == "1" {
            let seed = (try? recorded(name)).flatMap { try? decoder.decode(Case.self, from: $0) } ?? GoldenSeed.make()[name]!
            var doc = seed.doc
            var resolved: [DocStep] = []
            for step in seed.steps {
                resolved.append(try doc.apply(step))
            }
            let output = Case(doc: seed.doc, steps: seed.steps, resolved: resolved, final: doc)
            try encoder.encode(output).write(to: goldenURL(name), options: .atomic)
            return
        }

        let expected = try decoder.decode(Case.self, from: recorded(name))
        var doc = expected.doc
        var resolved: [DocStep] = []
        for step in expected.steps {
            resolved.append(try doc.apply(step))
        }
        #expect(resolved == expected.resolved)
        #expect(doc == expected.final)
    }

    /// The canned inputs live in the same JSON files; the `steps`/`doc`
    /// fields are authoritative, `resolved`/`final` get re-recorded.
    private func recorded(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func goldenURL(_ name: String) -> URL {
        // #filePath → Tests/DocKitTests/GoldenTests.swift → Golden/<name>.json
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Golden/\(name).json")
    }
}
