/// Every change to a doc is a step: a closed enum carrying enough recorded
/// content to invert itself. Undo, sync rebase and version history are all
/// built on steps.
///
/// Some fields are *recorded*, not input: `apply` ignores what the caller
/// put there, reads the real values from the doc and returns the resolved
/// step. That way a step mapped during rebase never needs its recorded
/// content fixed up. Recorded fields: `removed`, `previous`, join's
/// `at`/`kind`/`indent`/`decoration`, `setBlock`'s and `setDecoration`'s previous values, `deleteBlock`'s
/// content and `after`, `moveBlock`'s `from`, `deleteDatabase`'s content,
/// and the database steps' equivalents.
public enum DocStep: Hashable, Sendable, Codable {
    /// `text`'s spans are relative to offset 0.
    case insertText(block: DocBlockID, at: Int, text: DocText)
    case deleteText(block: DocBlockID, range: Range<Int>, removed: DocText)
    /// Within `range`, marks of `kind` become exactly `spans` (absolute
    /// offsets, inside the range); `previous` records what was there.
    case setMarks(block: DocBlockID, range: Range<Int>, kind: MarkKind, spans: [MarkSpan], previous: [MarkSpan])
    /// The tail of `block` from `at` moves into a new block placed right
    /// after it.
    case splitBlock(block: DocBlockID, at: Int, newID: DocBlockID, newKind: BlockKind, newIndent: Int, newDecoration: BlockDecoration? = nil)
    /// `block` is appended onto its predecessor `into` and removed.
    case joinBlock(block: DocBlockID, into: DocBlockID, at: Int, kind: BlockKind, indent: Int, decoration: BlockDecoration? = nil)
    /// `after` nil inserts at the start of the doc.
    case insertBlock(block: DocBlock, after: DocBlockID?)
    /// Content and predecessor are recorded for undo.
    case deleteBlock(block: DocBlock, after: DocBlockID?)
    case moveBlock(block: DocBlockID, after: DocBlockID?, from: DocBlockID?)
    case setBlock(block: DocBlockID, kind: BlockKind, indent: Int, previousKind: BlockKind, previousIndent: Int)
    case setDecoration(block: DocBlockID, decoration: BlockDecoration?, previous: BlockDecoration?)
    case createDatabase(database: Database)
    /// Content recorded for undo.
    case deleteDatabase(database: Database)
    case database(id: DatabaseID, step: DatabaseStep)
}

public enum DatabaseStep: Hashable, Sendable, Codable {
    /// `value` nil clears the cell.
    case setCell(row: RowID, column: ColumnID, value: CellValue?, previous: CellValue?)
    /// `after` nil inserts at the start.
    case insertRow(row: Row, after: RowID?)
    case deleteRow(row: Row, after: RowID?)
    case moveRow(row: RowID, after: RowID?, from: RowID?)
    /// `cells` restores the deleted column's values; empty on a fresh insert.
    case insertColumn(column: Column, after: ColumnID?, cells: [RowID: CellValue])
    /// The column's per-row values are recorded for undo.
    case deleteColumn(column: Column, after: ColumnID?, cells: [RowID: CellValue])
    case updateColumn(column: Column, previous: Column)
}
