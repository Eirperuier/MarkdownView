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

/// Where a table's cells are, as their fills draw them (across to the middle of the space
/// to the next column, down to their row's edges), in the space of its cells
/// (MarkdownTableBoundsKey's): what a host's decoration draws by (`markdownTableDecoration`).
public typealias MarkdownTableCellFrames = [MarkdownTableCellPosition: CGRect]

/// Each cell's place, for the decoration.
struct MarkdownTableCellFramesKey: PreferenceKey {
    static let defaultValue: [MarkdownTableCellPosition: Anchor<CGRect>] = [:]

    static func reduce(value: inout [MarkdownTableCellPosition: Anchor<CGRect>], nextValue: () -> [MarkdownTableCellPosition: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Laid out wherever SwiftUI lays the table out (off the main thread too, when it renders
/// asynchronously), read on the main thread: its places are behind a lock.
public final class MarkdownTableGrid: Equatable, @unchecked Sendable {
    private struct Places {
        var columnOffsets: [CGFloat] = []
        var columnWidths: [CGFloat] = []
        var rowOffsets: [CGFloat] = []
        var rowHeights: [CGFloat] = []
        var spacing: CGFloat = 0
    }

    private let lock = NSLock()
    private var places = Places()

    public init() {}

    /// The cell at `point` (in the bounds' space; a point between two columns is the
    /// nearer one's), nil outside the cells.
    public func position(at point: CGPoint) -> MarkdownTableCellPosition? {
        let places = lock.withLock { self.places }
        guard point.x >= 0, let row = places.rowOffsets.lastIndex(where: { $0 <= point.y }),
              point.y < places.rowOffsets[row] + places.rowHeights[row],
              let column = places.columnOffsets.lastIndex(where: { $0 - places.spacing / 2 <= point.x }),
              point.x < places.columnOffsets[column] + places.columnWidths[column] + places.spacing / 2
        else { return nil }
        return MarkdownTableCellPosition(row: row, column: column)
    }

    /// Each row's top and bottom, and how wide the columns reach.
    func rowsAndWidth() -> (rows: [(minY: CGFloat, maxY: CGFloat)], width: CGFloat) {
        let places = lock.withLock { self.places }
        let rows = zip(places.rowOffsets, places.rowHeights).map { (minY: $0, maxY: $0 + $1) }
        let width = zip(places.columnOffsets, places.columnWidths).map { $0 + $1 }.max() ?? 0
        return (rows, width)
    }

    func update(columnOffsets: [CGFloat], columnWidths: [CGFloat], rowOffsets: [CGFloat], rowHeights: [CGFloat], spacing: CGFloat) {
        lock.withLock {
            places = Places(columnOffsets: columnOffsets, columnWidths: columnWidths, rowOffsets: rowOffsets, rowHeights: rowHeights, spacing: spacing)
        }
    }

    public static func == (lhs: MarkdownTableGrid, rhs: MarkdownTableGrid) -> Bool { lhs === rhs }
}

/// The host's hooks, in the environment. The same as long as the host's hooks are there
/// and replace the same cells: the closures are new on each of the host's renders, and
/// an environment changing on each would have every view in the table look at it again.
struct MarkdownTableCellHooks: Equatable, Sendable {
    var onTap: MarkdownTableCellHook<MarkdownTableCellPosition, Void>?
    var replacement: MarkdownTableCellHook<MarkdownTableCellPosition, AnyView?>?
    /// The cells `replacement` shows a view in.
    var replaced: Set<MarkdownTableCellPosition> = []
    /// Drawn over the cells, by where they are.
    var decoration: MarkdownTableCellHook<MarkdownTableCellFrames, AnyView>?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.onTap === rhs.onTap && lhs.replacement === rhs.replacement && lhs.replaced == rhs.replaced
            && lhs.decoration === rhs.decoration
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

private struct MarkdownTableDecorationModifier: ViewModifier {
    var decoration: (@MainActor (MarkdownTableCellFrames) -> AnyView)?
    @State private var hook = MarkdownTableCellHook<MarkdownTableCellFrames, AnyView> { _ in AnyView(EmptyView()) }
    @Environment(\.markdownTableCellHooks) private var hooks

    func body(content: Content) -> some View {
        let _ = decoration.map { hook.call = $0 }
        content.environment(\.markdownTableCellHooks, with(hooks) { $0.decoration = decoration == nil ? nil : hook })
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

    /// A view drawn over tables MarkdownView renders, given where their cells are (as
    /// their fills draw them); it scrolls with a table that scrolls, and draws past its
    /// edges too (a column's name above it, a row's number before it). Touches go through
    /// it to the table. Nil draws nothing, and the cells don't tell where they are (a host
    /// that decorates for a while keeps the modifier and its table's views).
    public func markdownTableDecoration(_ decoration: (@MainActor (MarkdownTableCellFrames) -> AnyView)?) -> some View {
        modifier(MarkdownTableDecorationModifier(decoration: decoration))
    }
}
