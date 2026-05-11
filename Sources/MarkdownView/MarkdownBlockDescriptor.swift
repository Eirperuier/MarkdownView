//
//  MarkdownBlockDescriptor.swift
//  MarkdownView
//

import Foundation
@preconcurrency import Markdown

/// Lightweight descriptor for a top-level AST block.
/// App layer holds this instead of the raw AST node.
public struct MarkdownBlockDescriptor: Hashable, Sendable, Identifiable {

    public enum Kind: Hashable, Sendable {
        case heading(level: Int)
        case paragraph
        case codeBlock(language: String?)
        case blockQuote
        case orderedList
        case unorderedList
        case table
        case mathBlock
        case thematicBreak
        case htmlBlock
        case blockDirective(name: String)
        case unknown
    }

    /// Context for descriptors that represent a single list item
    /// (produced when `expandListItems` is true).
    public struct ListItemContext: Hashable, Sendable {
        public enum ListType: Hashable, Sendable { case ordered, unordered }
        public let listType: ListType
        public let itemIndex: Int
        public let depth: Int
        public let checkbox: Checkbox?
        public let parentTopLevelIndex: Int
        /// Full path from the top-level list root to this item.
        /// e.g. [0] for the first top-level item, [1, 2] for the 3rd sub-item of the 2nd item.
        public let indexPath: [Int]
    }

    /// Stable identity.
    /// Top-level blocks: "topLevelIndex_stableHash"
    /// List items:       "parentIndex.path_stableHash" where path = "0.1.2" etc.
    public var id: String {
        if let ctx = listItemContext {
            let pathStr = ctx.indexPath.map(String.init).joined(separator: ".")
            return "\(ctx.parentTopLevelIndex).\(pathStr)_\(stableHash)"
        }
        return "\(topLevelIndex)_\(stableHash)"
    }

    public let kind: Kind
    public let topLevelIndex: Int
    public let stableHash: Int
    public let sourceText: String
    public let plainText: String

    /// Per-child plain texts for compound blocks.
    /// For lists: one entry per list item.  For all others: `[plainText]`.
    public let childPlainTexts: [String]

    /// Non-nil when this descriptor represents a single list item.
    public let listItemContext: ListItemContext?
}
