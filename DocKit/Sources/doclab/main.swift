// The agent's doc tools from the command line, for evaluating how a model writes (Docs/doc.md §9):
// `doclab new DOC.json`                           writes an empty document
// `doclab read DOC.json [--full ID,ID]`            prints it as the agent reads it
// `doclab edit DOC.json OPS.json [--results R.json]` applies the operations (a JSON array),
//   writes the document back and prints each operation's result; R.json maps result names to data
// `doclab guide`                                  prints what the tools tell a model of blocks and text
import DocKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func load<T: Decodable>(_ type: T.Type, _ path: String) -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        fail("\(path): \(error)")
    }
}

func print(json: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try! encoder.encode(json), as: UTF8.self))
}

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "guide" {
    print(json: AgentGuide.json)
    exit(0)
}
guard let command = arguments.first, arguments.count >= 2 else { fail("usage: doclab new|read|edit DOC.json …, or doclab guide") }
let path = arguments[arguments.startIndex + 1]

switch command {
case "new":
    try! JSONEncoder().encode(Doc(id: .generate())).write(to: URL(fileURLWithPath: path))
case "read":
    let doc = load(Doc.self, path)
    var full: Set<DocBlockID> = []
    for name in option("--full")?.split(separator: ",") ?? [] {
        do { full.insert(try doc.agentBlock(String(name))) } catch { fail(error.message) }
    }
    print(json: doc.agentRead(full: full))
case "edit":
    guard arguments.count >= 3 else { fail("usage: doclab edit DOC.json OPS.json [--results R.json]") }
    var doc = load(Doc.self, path)
    let operations = load([JSONValue].self, arguments[arguments.startIndex + 2])
    let results = option("--results").map { load([String: JSONValue].self, $0) } ?? [:]
    let answers = doc.agentEdit(operations, results: results)
    try! JSONEncoder().encode(doc).write(to: URL(fileURLWithPath: path))
    print(json: JSONValue.array(answers.map(\.json)))
default:
    fail("unknown command \(command)")
}
