/// Every failure a `Doc` operation can report. Typed throws keeps the error
/// surface closed, which the TypeScript port relies on.
public enum DocError: Error, Equatable, Sendable {
    /// The step targets a block that is not in the doc.
    case blockNotFound(DocBlockID)
    /// The step targets a database that is not in the doc.
    case databaseNotFound(DatabaseID)
    /// `deleteDatabase` while a view block still references it.
    case databaseInUse(DatabaseID)
    /// The step targets a row that is not in the database.
    case rowNotFound(RowID)
    /// The step targets a column that is not in the database.
    case columnNotFound(ColumnID)
    /// The step anchors after a block that is not in the doc.
    case anchorNotFound(DocBlockID)
    /// The step anchors after a row that is not in the database.
    case rowAnchorNotFound(RowID)
    /// The step anchors after a column that is not in the database.
    case columnAnchorNotFound(ColumnID)
    /// A block, database, row, column or option id already exists.
    case duplicateID
    /// A cell's value isn't what its column holds (a finite number, one of the select's
    /// options, a link, …), or its column is gone.
    case cellNotOfColumn(RowID, ColumnID)
    /// A text offset outside `0...length`.
    case offsetOutOfRange
    /// A text offset that would split a surrogate pair.
    case notScalarBoundary
    /// Indent outside `0...DocBlock.maxIndent`.
    case invalidIndent
    /// Heading level outside `1...6`.
    case invalidHeadingLevel
    /// A kind that carries no text (divider, image, card, database view)
    /// was given non-empty text, or a text-bearing kind lost its text where
    /// the model requires it.
    case emptyTextRequired
    /// Code and math text never carries marks.
    case marksNotAllowed
    /// Mark spans are not in canonical (normalized) form.
    case marksNotNormalized
    /// Atom rules violated: each U+FFFC needs exactly one atom span of
    /// length 1, and every atom span must sit on a U+FFFC.
    case invalidAtom
    /// `setMarks` cannot write atom kinds; atoms are whole objects.
    case atomKindReadOnly
    /// `joinBlock` needs the two blocks to be adjacent.
    case nonAdjacentBlocks
    /// `joinBlock` only works between text-bearing blocks.
    case joinRequiresText
    /// `splitBlock` only works on text-bearing blocks: a text-less block has
    /// no tail to move and its inverse could never be rejoined.
    case splitRequiresText
    /// `moveBlock` cannot move a block after itself.
    case invalidMove
    /// `setMarks` spans must lie inside the edited range.
    case spanOutsideRange
}
