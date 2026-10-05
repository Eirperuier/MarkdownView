//
//  MarkdownTableCellHooks.swift
//  MarkdownView
//
//  Lets a host edit a table in place: a cell reports where it is clicked, and the
//  host can put its own view (an editor) in place of a cell's rendered content. The
//  table keeps its own layout, padding and fonts, so a table being edited looks like
//  the one being read.
//

import SwiftUI

/// A table cell's position: row 0 is the header, body rows start at 1.
public struct MarkdownTableCellPosition: Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

struct MarkdownTableCellHooks {
    var onTap: (@MainActor (MarkdownTableCellPosition) -> Void)?
    var replacement: (@MainActor (MarkdownTableCellPosition) -> AnyView?)?
}

private struct MarkdownTableCellHooksKey: EnvironmentKey {
    static let defaultValue = MarkdownTableCellHooks()
}

extension EnvironmentValues {
    var markdownTableCellHooks: MarkdownTableCellHooks {
        get { self[MarkdownTableCellHooksKey.self] }
        set { self[MarkdownTableCellHooksKey.self] = newValue }
    }
}

extension View {
    /// Called with the cell a click (or tap) lands on, in tables MarkdownView renders.
    public func markdownTableCellTap(_ action: @escaping @MainActor (MarkdownTableCellPosition) -> Void) -> some View {
        transformEnvironment(\.markdownTableCellHooks) { $0.onTap = action }
    }

    /// A view to show instead of a cell's rendered content (nil keeps the content). It
    /// sits inside the cell's padding, with the cell's font.
    public func markdownTableCellReplacement(_ replacement: @escaping @MainActor (MarkdownTableCellPosition) -> AnyView?) -> some View {
        transformEnvironment(\.markdownTableCellHooks) { $0.replacement = replacement }
    }
}
