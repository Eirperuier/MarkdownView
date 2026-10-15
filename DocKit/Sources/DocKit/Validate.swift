extension Doc {
    /// Checks every model invariant; tests run it after every operation.
    /// Throws the first violation found.
    public func validate() throws(DocError) {
        var seen: Set<DocBlockID> = []
        for block in blocks {
            guard seen.insert(block.id).inserted else { throw .duplicateID }
            guard (0...DocBlock.maxIndent).contains(block.indent) else { throw .invalidIndent }
            if case .heading(let level) = block.kind, !(1...6).contains(level) {
                throw .invalidHeadingLevel
            }
            if !block.kind.carriesText, !block.text.isEmpty || !block.text.marks.isEmpty {
                throw .emptyTextRequired
            }
            if !block.kind.allowsMarks, !block.text.marks.isEmpty {
                throw .marksNotAllowed
            }
            try block.text.validate()
            if let id = block.kind.databaseID, databases[id] == nil {
                throw .databaseNotFound(id)
            }
        }
    }
}

extension Database {
    /// Ids are unique and every cell is what its column holds (`Column.holds`); a cell
    /// left of a column a collaborator deleted is no matter. A new database must pass.
    public func validate() throws(DocError) {
        var byID: [ColumnID: Column] = [:]
        for column in columns {
            guard byID.updateValue(column, forKey: column.id) == nil else { throw .duplicateID }
        }
        var seen: Set<RowID> = []
        for row in rows {
            guard seen.insert(row.id).inserted else { throw .duplicateID }
            for (column, value) in row.cells {
                if let owner = byID[column], !owner.holds(value) { throw .cellNotOfColumn(row.id, column) }
            }
        }
    }
}

/// The cells a local transaction wrote, checked against their columns at its end
/// (`Doc.apply(_:DocTransaction)`): in between, a field changing type holds values of
/// the old type. Only these: what concurrent edits leave elsewhere (a value of a type
/// a collaborator just changed) isn't this writer's to answer for.
struct WrittenCells {
    private struct Cell: Hashable { let row: RowID, column: ColumnID }
    private var cells: [DatabaseID: Set<Cell>] = [:]
    /// Columns whose definition changed: every cell of theirs.
    private var columns: [DatabaseID: Set<ColumnID>] = [:]

    mutating func note(_ step: DatabaseStep, in database: DatabaseID) {
        switch step {
        case .setCell(let row, let column, _, _):
            cells[database, default: []].insert(Cell(row: row, column: column))
        case .insertRow(let row, _):
            for column in row.cells.keys { cells[database, default: []].insert(Cell(row: row.id, column: column)) }
        case .insertColumn(let column, _, _), .updateColumn(let column, _):
            columns[database, default: []].insert(column.id)
        case .deleteRow, .moveRow, .deleteColumn:
            break
        }
    }

    func check(in doc: Doc) throws(DocError) {
        for (id, written) in cells {
            guard let database = doc.databases[id] else { continue }
            for cell in written {
                guard let column = database.columns.first(where: { $0.id == cell.column }),
                      let value = database.rows.first(where: { $0.id == cell.row })?.cells[cell.column] else { continue }
                if !column.holds(value) { throw .cellNotOfColumn(cell.row, cell.column) }
            }
        }
        for (id, changed) in columns {
            guard let database = doc.databases[id] else { continue }
            for column in database.columns where changed.contains(column.id) {
                for row in database.rows {
                    if let value = row.cells[column.id], !column.holds(value) { throw .cellNotOfColumn(row.id, column.id) }
                }
            }
        }
    }
}

extension DocText {
    /// Marks must be normalized, on scalar boundaries, and obey the atom
    /// rules: every U+FFFC carries exactly one atom span of length 1, and
    /// every atom span sits on a U+FFFC.
    func validate() throws(DocError) {
        var canonical = self
        canonical.normalize()
        guard canonical.marks == marks else { throw .marksNotNormalized }

        let units = [UInt16](string.utf16)
        var atomOffsets = Set<Int>()
        var covering: [Int: Int] = [:]
        for span in marks {
            guard isValidOffset(span.range.lowerBound), isValidOffset(span.range.upperBound) else {
                throw .notScalarBoundary
            }
            guard span.range.lowerBound < span.range.upperBound, span.range.upperBound <= length else {
                throw .offsetOutOfRange
            }
            for offset in span.range where units[offset] == 0xFFFC {
                covering[offset, default: 0] += 1
            }
            if span.mark.kind.isAtom {
                guard span.range.count == 1 else { throw .invalidAtom }
                atomOffsets.insert(span.range.lowerBound)
            }
        }
        for (index, unit) in units.enumerated() where unit == 0xFFFC {
            // One atom span and nothing else may cover the character.
            guard atomOffsets.contains(index), covering[index] == 1 else { throw .invalidAtom }
            atomOffsets.remove(index)
        }
        guard atomOffsets.isEmpty else { throw .invalidAtom }
    }
}
