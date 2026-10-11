extension DocStep {
    /// The inverse of a resolved step. Applying it to the doc the step was
    /// resolved against restores the previous state exactly.
    public var inverted: DocStep {
        switch self {
        case .insertText(let block, let at, let text):
            return .deleteText(block: block, range: at..<(at + text.length), removed: text)
        case .deleteText(let block, let range, let removed):
            return .insertText(block: block, at: range.lowerBound, text: removed)
        case .setMarks(let block, let range, let kind, let spans, let previous):
            return .setMarks(block: block, range: range, kind: kind, spans: previous, previous: spans)
        case .splitBlock(let block, let at, let newID, let newKind, let newIndent, let newDecoration):
            return .joinBlock(block: newID, into: block, at: at, kind: newKind, indent: newIndent, decoration: newDecoration)
        case .joinBlock(let block, let into, let at, let kind, let indent, let decoration):
            return .splitBlock(block: into, at: at, newID: block, newKind: kind, newIndent: indent, newDecoration: decoration)
        case .insertBlock(let block, let after):
            return .deleteBlock(block: block, after: after)
        case .deleteBlock(let block, let after):
            return .insertBlock(block: block, after: after)
        case .moveBlock(let block, let after, let from):
            return .moveBlock(block: block, after: from, from: after)
        case .setBlock(let block, let kind, let indent, let previousKind, let previousIndent):
            return .setBlock(
                block: block, kind: previousKind, indent: previousIndent,
                previousKind: kind, previousIndent: indent
            )
        case .setDecoration(let block, let decoration, let previous):
            return .setDecoration(block: block, decoration: previous, previous: decoration)
        case .createDatabase(let database):
            return .deleteDatabase(database: database)
        case .deleteDatabase(let database):
            return .createDatabase(database: database)
        case .database(let id, let step):
            return .database(id: id, step: step.inverted)
        }
    }
}

extension DatabaseStep {
    var inverted: DatabaseStep {
        switch self {
        case .setCell(let row, let column, let value, let previous):
            return .setCell(row: row, column: column, value: previous, previous: value)
        case .insertRow(let row, let after):
            return .deleteRow(row: row, after: after)
        case .deleteRow(let row, let after):
            return .insertRow(row: row, after: after)
        case .moveRow(let row, let after, let from):
            return .moveRow(row: row, after: from, from: after)
        case .insertColumn(let column, let after, let cells):
            return .deleteColumn(column: column, after: after, cells: cells)
        case .deleteColumn(let column, let after, let cells):
            return .insertColumn(column: column, after: after, cells: cells)
        case .updateColumn(let column, let previous):
            return .updateColumn(column: previous, previous: column)
        }
    }
}
