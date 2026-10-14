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

/// Where a scrolling table's rows and columns are, in the space of its bounds
/// (MarkdownTableBoundsKey): the cell a point falls in, for a host taking a click the
/// table doesn't (a right-click). The same object while the table is there; its layout
/// keeps it up to date.
public struct MarkdownTableGridKey: PreferenceKey {
    public static let defaultValue: MarkdownTableGrid? = nil

    public static func reduce(value: inout MarkdownTableGrid?, nextValue: () -> MarkdownTableGrid?) {
        value = value ?? nextValue()
    }
}

@MainActor public final class MarkdownTableGrid: Equatable {
    private var columnOffsets: [CGFloat] = []
    private var columnWidths: [CGFloat] = []
    private var rowOffsets: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var spacing: CGFloat = 0

    /// The cell at `point` (in the bounds' space; a point between two columns is the
    /// nearer one's), nil outside the cells.
    public func position(at point: CGPoint) -> MarkdownTableCellPosition? {
        guard point.x >= 0, let row = rowOffsets.lastIndex(where: { $0 <= point.y }),
              point.y < rowOffsets[row] + rowHeights[row],
              let column = columnOffsets.lastIndex(where: { $0 - spacing / 2 <= point.x }),
              point.x < columnOffsets[column] + columnWidths[column] + spacing / 2
        else { return nil }
        return MarkdownTableCellPosition(row: row, column: column)
    }

    func update(columnOffsets: [CGFloat], columnWidths: [CGFloat], rowOffsets: [CGFloat], rowHeights: [CGFloat], spacing: CGFloat) {
        self.columnOffsets = columnOffsets
        self.columnWidths = columnWidths
        self.rowOffsets = rowOffsets
        self.rowHeights = rowHeights
        self.spacing = spacing
    }

    nonisolated public static func == (lhs: MarkdownTableGrid, rhs: MarkdownTableGrid) -> Bool { lhs === rhs }
}

/// The host's hooks, in the environment. The same as long as the host's hooks are there
/// and replace the same cells: the closures are new on each of the host's renders, and
/// an environment changing on each would have every view in the table look at it again.
struct MarkdownTableCellHooks: Equatable, Sendable {
    var onTap: MarkdownTableCellHook<MarkdownTableCellPosition, Void>?
    var replacement: MarkdownTableCellHook<MarkdownTableCellPosition, AnyView?>?
    /// The cells `replacement` shows a view in.
    var replaced: Set<MarkdownTableCellPosition> = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.onTap === rhs.onTap && lhs.replacement === rhs.replacement && lhs.replaced == rhs.replaced
    }
}

/// A host's closure, the latest it gave, held for as long as its modifier is there.
@MainActor final class MarkdownTableCellHook<Input, Output> {
    var call: @MainActor (Input) -> Output

    init(_ call: @escaping @MainActor (Input) -> Output) {
        self.call = call
    }
}

/// What a table's cells call: the hooks, and where the rows are now (by their
/// identities, MarkdownTableCellIdentity). One per table, the same while it's there,
/// so a cell rendered once calls the latest.
@MainActor final class MarkdownTableCellHookBox {
    var hooks = MarkdownTableCellHooks()
    var rows: [Int: Int] = [:]
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

private struct MarkdownTableCellTapModifier: ViewModifier {
    var action: @MainActor (MarkdownTableCellPosition) -> Void
    @State private var hook = MarkdownTableCellHook<MarkdownTableCellPosition, Void> { _ in }
    @Environment(\.markdownTableCellHooks) private var hooks

    func body(content: Content) -> some View {
        let _ = hook.call = action
        content.environment(\.markdownTableCellHooks, with(hooks) { $0.onTap = hook })
    }
}

private struct MarkdownTableCellReplacementModifier: ViewModifier {
    var cells: Set<MarkdownTableCellPosition>
    var replacement: @MainActor (MarkdownTableCellPosition) -> AnyView?
    @State private var hook = MarkdownTableCellHook<MarkdownTableCellPosition, AnyView?> { _ in nil }
    @Environment(\.markdownTableCellHooks) private var hooks

    func body(content: Content) -> some View {
        let _ = hook.call = replacement
        content.environment(\.markdownTableCellHooks, with(hooks) {
            $0.replacement = hook
            $0.replaced = cells
        })
    }
}

private func with<Value>(_ value: Value, _ change: (inout Value) -> Void) -> Value {
    var value = value
    change(&value)
    return value
}

extension View {
    /// Called with the cell a click (or tap) lands on, in tables MarkdownView renders.
    public func markdownTableCellTap(_ action: @escaping @MainActor (MarkdownTableCellPosition) -> Void) -> some View {
        modifier(MarkdownTableCellTapModifier(action: action))
    }

    /// Views to show instead of these cells' rendered content (nil keeps the content).
    /// Each sits inside the cell's padding, with the cell's font. A cell's view is asked
    /// for when the cells change, and when the table renders again.
    public func markdownTableCellReplacement(
        _ cells: Set<MarkdownTableCellPosition>,
        _ replacement: @escaping @MainActor (MarkdownTableCellPosition) -> AnyView?
    ) -> some View {
        modifier(MarkdownTableCellReplacementModifier(cells: cells, replacement: replacement))
    }
}
