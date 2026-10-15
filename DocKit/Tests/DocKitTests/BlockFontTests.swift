import Foundation
import Testing

@testable import DocKit

@Suite
struct BlockFontTests {
    private func doc() -> Doc {
        Doc(id: fixedID(0), blocks: [
            DocBlock(id: fixedID(1), kind: .paragraph, text: DocText(string: "Hello world")),
            DocBlock(id: fixedID(2), kind: .paragraph, text: DocText(string: "Next"), font: .mono),
        ])
    }

    /// A block's font is set and undone to what it was.
    @Test
    func aBlocksFontAppliesAndUndoes() throws {
        var doc = doc()
        let applied = try doc.apply(.setFont(block: fixedID(1), font: .serif, previous: nil))
        #expect(doc.block(fixedID(1))?.font == .serif)
        try doc.validate()
        try doc.apply(applied.inverted)
        #expect(doc.block(fixedID(1))?.font == nil)
    }

    /// The block a split makes takes the font it's given; joining it away and undoing
    /// brings its own back.
    @Test
    func splitAndJoinKeepFonts() throws {
        var doc = doc()
        try doc.apply(.setFont(block: fixedID(1), font: .serif, previous: nil))
        let split = try doc.apply(.splitBlock(block: fixedID(1), at: 5, newID: fixedID(3), newKind: .paragraph, newIndent: 0, newFont: .serif))
        #expect(doc.block(fixedID(3))?.font == .serif)
        try doc.apply(split.inverted)
        #expect(doc.blocks.count == 2 && doc.block(fixedID(1))?.text.string == "Hello world")

        let join = try doc.apply(.joinBlock(block: fixedID(2), into: fixedID(1), at: 0, kind: .paragraph, indent: 0))
        guard case .joinBlock(_, _, _, _, _, _, let font) = join else { Issue.record("not a join: \(join)"); return }
        #expect(font == .mono)
        try doc.apply(join.inverted)
        #expect(doc.block(fixedID(2))?.font == .mono && doc.block(fixedID(1))?.font == .serif)
    }

    /// A font set on a block a collaborator deleted goes with it.
    @Test
    func aFontGoesWithItsBlock() {
        let set = DocStep.setFont(block: fixedID(1), font: .serif, previous: nil)
        let deleted = DocBlock(id: fixedID(1), kind: .paragraph)
        #expect(set.mapped(through: .deleteBlock(block: deleted, after: nil)) == [])
        #expect(set.mapped(through: .setFont(block: fixedID(2), font: .rounded, previous: nil)) == [set])
    }

    /// A document stored before fonts existed reads as it was; an agent reads a block's
    /// font, writes it back, and a set changes it.
    @Test
    func fontsReadAndWrite() throws {
        let block = try #require(doc().block(fixedID(1)))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any])
        #expect(json["font"] == nil)
        json.removeValue(forKey: "font")
        #expect(try JSONDecoder().decode(DocBlock.self, from: JSONSerialization.data(withJSONObject: json)) == block)

        var doc = doc()
        let read = AgentBlocks.json(try #require(doc.block(fixedID(2))), in: doc)
        #expect(read["font"] == "mono")
        var databases = doc.databases
        #expect(try AgentBlocks.block(read, id: fixedID(2), databases: &databases, results: [:]).font == .mono)
        let results = doc.agentEdit([try JSONDecoder().decode(JSONValue.self, from: Data(#"{"op": "set", "id": "\#(AgentBlocks.shortID(fixedID(1)))", "font": "rounded"}"#.utf8))])
        #expect(results[0].error == nil && doc.block(fixedID(1))?.font == .rounded)
        let refused = doc.agentEdit([try JSONDecoder().decode(JSONValue.self, from: Data(#"{"op": "set", "id": "\#(AgentBlocks.shortID(fixedID(1)))", "font": "comic"}"#.utf8))])
        #expect(refused[0].error?.contains("system or mono or serif or rounded") == true)
    }
}
