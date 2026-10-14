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

/// Where a scrolling table's cells are, all of them (also those scrolled out of sight),
/// for a host drawing at the table's edges.
public struct MarkdownTableBoundsKey: PreferenceKey {
    public static let defaultValue: Anchor<CGRect>? = nil

    public static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct MarkdownTableCellHooks {
    var onTap: (@MainActor (MarkdownTableCellPosition) -> Void)?
    var replacement: (@MainActor (MarkdownTableCellPosition) -> AnyView?)?
}

/// The hooks a table's cells call: one per table, holding the latest the host gave. The
/// environment's are new closures on each of the host's renders, and every cell reading
/// them would render again (a whole table's on each keystroke in one of its cells).
@MainActor final class MarkdownTableCellHookBox {
    var hooks = MarkdownTableCellHooks()
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
