//
//  MarkdownFootnoteIndex.swift
//  MarkdownView
//
//  Document-wide footnote numbering across the blocks of one streamed document.
//  Moved from ios-flowith (Views/Components/MessageFootnotes.swift); blocks are keyed
//  by MarkdownStreamBlock.ID and the click URLs come from the caller.
//

import Foundation

/// Footnotes of one document: definition contents plus document-wide numbers.
/// Standard footnotes are numbered by first reference and inline footnotes by
/// appearance, in one sequence; ids defined but never referenced come last.
public struct MarkdownFootnoteIndex: Sendable {
    public typealias BlockID = MarkdownStreamBlock.ID

    public struct StandardNote: Sendable {
        public let number: Int
        /// The definition's markdown source, continuation lines included.
        public let content: String
        /// The block holding the definition (navigation target).
        public let definitionBlock: BlockID
        /// The block holding the first reference (target for jumping back from the definition).
        public let firstReferenceBlock: BlockID?
    }

    public struct InlineNote: Sendable {
        public let number: Int
        public let content: String
    }

    public internal(set) var standard: [String: StandardNote] = [:]
    /// Each block's inline footnotes in order; they match the preprocessing placeholders one to one.
    public internal(set) var inlineByBlock: [BlockID: [InlineNote]] = [:]
    /// Number → inline footnote content, for a popover.
    public internal(set) var inlineContents: [Int: String] = [:]

    public var isEmpty: Bool { standard.isEmpty && inlineContents.isEmpty }

    public init() {}

    /// Code, HTML, math and rules are not scanned: `[^…]` inside them is not a footnote.
    static func isScannable(_ block: MarkdownStreamBlock) -> Bool {
        guard case .markdown = block.kind else { return false }
        switch block.descriptor.kind {
        case .codeBlock, .htmlBlock, .mathBlock, .thematicBreak:
            return false
        default:
            return true
        }
    }

    /// Matches a definition line, `[^id]: content` at the start of a line (escaped as
    /// `\[^id]:` after normalization); returns (id, first-line content).
    public static func definitionLine(_ line: String) -> (id: String, content: String)? {
        let ns = line as NSString
        guard let match = definitionRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let id = ns.substring(with: match.range(at: 1))
        let content = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        return (id, content)
    }

    private static let definitionRegex = try! NSRegularExpression(
        pattern: #"^\\?\[\^([^\]\s\[]+)\]:[ \t]*(.*)$"#
    )
    /// A reference, `[^id]` not followed by `:` (which would make it a definition marker).
    private static let referenceRegex = try! NSRegularExpression(
        pattern: #"\[\^([^\]\s\[]+)\](?!:)"#
    )

    public static func build(blocks: [MarkdownStreamBlock]) -> MarkdownFootnoteIndex {
        let blocks = blocks.filter(isScannable)

        // Pass 1: collect definitions (id → content and block; the first of duplicates wins).
        var defOrder: [(id: String, content: String, block: BlockID)] = []
        var defIndexById: [String: Int] = [:]
        for block in blocks {
            let lines = block.source.components(separatedBy: "\n")
            var i = 0
            while i < lines.count {
                guard let def = definitionLine(lines[i]) else { i += 1; continue }
                var content = def.content
                var j = i + 1
                // Continuation: an indented non-empty line that isn't a definition itself.
                while j < lines.count,
                      definitionLine(lines[j]) == nil,
                      let first = lines[j].first, first == " " || first == "\t",
                      !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    content += "\n" + lines[j].trimmingCharacters(in: .whitespaces)
                    j += 1
                }
                if defIndexById[def.id] == nil {
                    defIndexById[def.id] = defOrder.count
                    defOrder.append((def.id, content, block.id))
                }
                i = j
            }
        }

        // Pass 2: number referenced standard footnotes and inline footnotes in document order.
        enum Token { case reference(id: String); case inlineNote(content: String) }
        var index = MarkdownFootnoteIndex()
        var number = 0
        for block in blocks {
            var tokens: [(offset: Int, token: Token)] = []
            let ns = block.source as NSString
            referenceRegex.enumerateMatches(
                in: block.source, range: NSRange(location: 0, length: ns.length)
            ) { match, _, _ in
                guard let match else { return }
                let id = ns.substring(with: match.range(at: 1))
                tokens.append((match.range.location, .reference(id: id)))
            }
            for occ in MarkdownFootnoteSyntax.inlineOccurrences(in: block.source) {
                let offset = occ.range.lowerBound.utf16Offset(in: block.source)
                tokens.append((offset, .inlineNote(content: occ.content)))
            }
            tokens.sort { $0.offset < $1.offset }
            for (_, token) in tokens {
                switch token {
                case .reference(let id):
                    guard let defIdx = defIndexById[id], index.standard[id] == nil else { continue }
                    number += 1
                    let def = defOrder[defIdx]
                    index.standard[id] = StandardNote(
                        number: number,
                        content: def.content,
                        definitionBlock: def.block,
                        firstReferenceBlock: block.id
                    )
                case .inlineNote(let content):
                    number += 1
                    index.inlineByBlock[block.id, default: []].append(
                        InlineNote(number: number, content: content)
                    )
                    index.inlineContents[number] = content
                }
            }
        }

        // Pass 3: defined but never referenced ids go last (the marker stays tappable and numbered).
        for def in defOrder where index.standard[def.id] == nil {
            number += 1
            index.standard[def.id] = StandardNote(
                number: number,
                content: def.content,
                definitionBlock: def.block,
                firstReferenceBlock: nil
            )
        }
        return index
    }

    /// The context to inject into one block with `markdownFootnotes(_:)`; nil when it has none.
    public func footnotes(
        for block: BlockID,
        referenceURL: (_ footnoteID: String) -> URL?,
        definitionURL: (_ footnoteID: String) -> URL?,
        inlineURL: (_ number: Int) -> URL?
    ) -> MarkdownFootnotes? {
        guard !isEmpty else { return nil }
        var references: [String: MarkdownFootnotes.Reference] = [:]
        for (id, note) in standard {
            references[id] = MarkdownFootnotes.Reference(
                number: note.number,
                referenceURL: referenceURL(id),
                definitionURL: definitionURL(id)
            )
        }
        let inlineNotes = (inlineByBlock[block] ?? []).map {
            MarkdownFootnotes.InlineNote(number: $0.number, url: inlineURL($0.number))
        }
        guard !references.isEmpty || !inlineNotes.isEmpty else { return nil }
        return MarkdownFootnotes(references: references, inlineNotes: inlineNotes)
    }
}

/// Rebuilds a document's ``MarkdownFootnoteIndex`` only when its blocks change.
/// Every block looks it up while rendering, so a hit must be cheap.
@MainActor
public final class MarkdownFootnoteIndexCache {
    private var fingerprint: Int?
    private var cached = MarkdownFootnoteIndex()

    public init() {}

    public func index(for blocks: [MarkdownStreamBlock]) -> MarkdownFootnoteIndex {
        var hasher = Hasher()
        hasher.combine(blocks.count)
        for block in blocks {
            hasher.combine(block.id)
            hasher.combine(block.source.count)
        }
        // While streaming only the tail changes and lengths can collide: hash its full text.
        if let last = blocks.last { hasher.combine(last.source) }
        let fingerprint = hasher.finalize()
        if fingerprint == self.fingerprint { return cached }

        // Fast path: no footnote syntax anywhere means an empty index without scanning.
        let mayHaveFootnotes = blocks.contains { $0.source.contains("[^") || $0.source.contains("^[") }
        cached = mayHaveFootnotes ? MarkdownFootnoteIndex.build(blocks: blocks) : MarkdownFootnoteIndex()
        self.fingerprint = fingerprint
        return cached
    }
}
