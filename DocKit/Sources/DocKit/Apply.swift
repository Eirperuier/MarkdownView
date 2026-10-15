extension Doc {
    /// Applies one step, reading every recorded field from the doc rather
    /// than trusting the caller. Returns the resolved step — the only form
    /// `inverted`, `mapped` and the history may see.
    @discardableResult
    public mutating func apply(_ step: DocStep) throws(DocError) -> DocStep {
        switch step {
        case .insertText(let block, let at, let text):
            return try applyInsertText(block: block, at: at, text: text)
        case .deleteText(let block, let range, _):
            return try applyDeleteText(block: block, range: range)
        case .setMarks(let block, let range, let kind, let spans, _):
            return try applySetMarks(block: block, range: range, kind: kind, spans: spans)
        case .splitBlock(let block, let at, let newID, let newKind, let newIndent, let newDecoration):
            return try applySplit(block: block, at: at, newID: newID, newKind: newKind, newIndent: newIndent, newDecoration: newDecoration)
        case .joinBlock(let block, let into, _, _, _, _):
            return try applyJoin(block: block, into: into)
        case .insertBlock(let block, let after):
            // A view block needs its database (an undo can bring one back after a
            // collaborator deleted the database).
            if let id = block.kind.databaseID, databases[id] == nil { throw .databaseNotFound(id) }
            return try applyInsertBlock(block: block, after: after)
        case .deleteBlock(let block, _):
            return try applyDeleteBlock(id: block.id)
        case .moveBlock(let block, let after, _):
            return try applyMoveBlock(id: block, after: after)
        case .setBlock(let block, let kind, let indent, _, _):
            if let id = kind.databaseID, databases[id] == nil { throw .databaseNotFound(id) }
            return try applySetBlock(id: block, kind: kind, indent: indent)
        case .setDecoration(let block, let decoration, _):
            let index = try blockIndex(block)
            let previous = blocks[index].decoration
            blocks[index].decoration = decoration
            return .setDecoration(block: block, decoration: decoration, previous: previous)
        case .createDatabase(let database):
            guard databases[database.id] == nil else { throw .duplicateID }
            try database.validate()
            databases[database.id] = database
            return step
        case .deleteDatabase(let database):
            // Refuse while a view block still points at the database: the
            // step can't be inverted and the block would dangle.
            try require(!blocks.contains { $0.kind.databaseID == database.id }, .databaseInUse(database.id))
            guard let existing = databases.removeValue(forKey: database.id) else {
                throw .databaseNotFound(database.id)
            }
            return .deleteDatabase(database: existing)
        case .database(let id, let inner):
            guard var database = databases[id] else { throw .databaseNotFound(id) }
            let resolved = try database.apply(inner)
            databases[id] = database
            return .database(id: id, step: resolved)
        }
    }

    /// Applies a whole transaction atomically: on any error the doc is left
    /// untouched. Returns the transaction with every step resolved. The cells it
    /// wrote must be what their columns hold at its end (`WrittenCells`).
    @discardableResult
    public mutating func apply(_ transaction: DocTransaction) throws(DocError) -> DocTransaction {
        var copy = self
        var resolved: [DocStep] = []
        var written = WrittenCells()
        for step in transaction.steps {
            resolved.append(try copy.apply(step))
            if case .database(let id, let inner) = step { written.note(inner, in: id) }
        }
        try written.check(in: copy)
        self = copy
        return DocTransaction(
            steps: resolved,
            selectionBefore: transaction.selectionBefore,
            selectionAfter: transaction.selectionAfter,
            author: transaction.author,
            time: transaction.time
        )
    }

    private func blockIndex(_ id: DocBlockID) throws(DocError) -> Int {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { throw .blockNotFound(id) }
        return index
    }

    private func require(_ condition: Bool, _ error: DocError) throws(DocError) {
        if !condition { throw error }
    }

    /// The checks a kind+indent+text combination must pass, shared by
    /// `insertBlock`, `setBlock` and `splitBlock`'s new block.
    private func checkBlock(kind: BlockKind, indent: Int, text: DocText) throws(DocError) {
        try require((0...DocBlock.maxIndent).contains(indent), .invalidIndent)
        if case .heading(let level) = kind {
            try require((1...6).contains(level), .invalidHeadingLevel)
        }
        try require(kind.carriesText || text.isEmpty, .emptyTextRequired)
        try require(kind.allowsMarks || text.marks.isEmpty, .marksNotAllowed)
        try text.validate()
    }

    private func checkedTextIndex(_ id: DocBlockID) throws(DocError) -> Int {
        let index = try blockIndex(id)
        try require(blocks[index].kind.carriesText, .emptyTextRequired)
        return index
    }

    private mutating func applyInsertText(block: DocBlockID, at: Int, text: DocText) throws(DocError) -> DocStep {
        let index = try checkedTextIndex(block)
        try require(at >= 0 && at <= blocks[index].text.length, .offsetOutOfRange)
        try require(blocks[index].text.isValidOffset(at), .notScalarBoundary)
        try require(blocks[index].kind.allowsMarks || text.marks.isEmpty, .marksNotAllowed)
        var edited = blocks[index].text
        edited.insert(text, at: at)
        try edited.validate()
        blocks[index].text = edited
        return .insertText(block: block, at: at, text: text)
    }

    private mutating func applyDeleteText(block: DocBlockID, range: Range<Int>) throws(DocError) -> DocStep {
        let index = try checkedTextIndex(block)
        let text = blocks[index].text
        try require(range.lowerBound >= 0 && range.upperBound <= text.length, .offsetOutOfRange)
        try require(text.isValidOffset(range.lowerBound) && text.isValidOffset(range.upperBound), .notScalarBoundary)
        let removed = text.slice(range)
        var edited = text
        edited.delete(range)
        try edited.validate()
        blocks[index].text = edited
        return .deleteText(block: block, range: range, removed: removed)
    }

    private mutating func applySetMarks(
        block: DocBlockID, range: Range<Int>, kind: MarkKind, spans: [MarkSpan]
    ) throws(DocError) -> DocStep {
        try require(!kind.isAtom, .atomKindReadOnly)
        let index = try checkedTextIndex(block)
        try require(blocks[index].kind.allowsMarks, .marksNotAllowed)
        let text = blocks[index].text
        try require(range.lowerBound >= 0 && range.upperBound <= text.length, .offsetOutOfRange)
        try require(text.isValidOffset(range.lowerBound) && text.isValidOffset(range.upperBound), .notScalarBoundary)
        for span in spans {
            try require(range.contains(span.range.lowerBound) && span.range.upperBound <= range.upperBound, .spanOutsideRange)
            try require(span.mark.kind == kind, .marksNotNormalized)
        }
        var edited = text
        let previous = edited.setMarks(kind, in: range, to: spans)
        try edited.validate()
        blocks[index].text = edited
        return .setMarks(block: block, range: range, kind: kind, spans: spans, previous: previous)
    }

    private mutating func applySplit(
        block: DocBlockID, at: Int, newID: DocBlockID, newKind: BlockKind, newIndent: Int, newDecoration: BlockDecoration?
    ) throws(DocError) -> DocStep {
        let index = try blockIndex(block)
        try require(blocks[index].kind.carriesText, .splitRequiresText)
        try require(self.block(newID) == nil, .duplicateID)
        let text = blocks[index].text
        try require(at >= 0 && at <= text.length, .offsetOutOfRange)
        try require(text.isValidOffset(at), .notScalarBoundary)
        let tail = text.slice(at..<text.length)
        try checkBlock(kind: newKind, indent: newIndent, text: tail)
        var head = text
        head.delete(at..<text.length)
        let newBlock = DocBlock(id: newID, kind: newKind, indent: newIndent, text: tail, decoration: newDecoration)
        blocks[index].text = head
        blocks.insert(newBlock, at: index + 1)
        return .splitBlock(block: block, at: at, newID: newID, newKind: newKind, newIndent: newIndent, newDecoration: newDecoration)
    }

    private mutating func applyJoin(block: DocBlockID, into: DocBlockID) throws(DocError) -> DocStep {
        let blockIndex = try self.blockIndex(block)
        let intoIndex = try self.blockIndex(into)
        try require(intoIndex + 1 == blockIndex, .nonAdjacentBlocks)
        try require(blocks[intoIndex].kind.carriesText && blocks[blockIndex].kind.carriesText, .joinRequiresText)
        // The joined block keeps `into`'s kind, so the other block's marks
        // must be allowed there too (joining marked text into code).
        try require(blocks[intoIndex].kind.allowsMarks || blocks[blockIndex].text.marks.isEmpty, .marksNotAllowed)
        let at = blocks[intoIndex].text.length
        var joined = blocks[intoIndex].text
        joined.insert(blocks[blockIndex].text, at: at)
        try joined.validate()
        blocks[intoIndex].text = joined
        let removed = blocks.remove(at: blockIndex)
        return .joinBlock(block: block, into: into, at: at, kind: removed.kind, indent: removed.indent, decoration: removed.decoration)
    }

    private func afterIndex(_ after: DocBlockID?) throws(DocError) -> Int {
        guard let after else { return 0 }
        return try blockIndex(after) + 1
    }

    private mutating func applyInsertBlock(block: DocBlock, after: DocBlockID?) throws(DocError) -> DocStep {
        try require(self.block(block.id) == nil, .duplicateID)
        try checkBlock(kind: block.kind, indent: block.indent, text: block.text)
        let index = try afterIndex(after)
        blocks.insert(block, at: index)
        return .insertBlock(block: block, after: after)
    }

    private mutating func applyDeleteBlock(id: DocBlockID) throws(DocError) -> DocStep {
        let index = try blockIndex(id)
        let after = index > 0 ? blocks[index - 1].id : nil
        let removed = blocks.remove(at: index)
        return .deleteBlock(block: removed, after: after)
    }

    private mutating func applyMoveBlock(id: DocBlockID, after: DocBlockID?) throws(DocError) -> DocStep {
        let index = try blockIndex(id)
        try require(after != id, .invalidMove)
        if let after { _ = try blockIndex(after) }  // validate before mutating
        let from = index > 0 ? blocks[index - 1].id : nil
        let block = blocks.remove(at: index)
        blocks.insert(block, at: try afterIndex(after))
        return .moveBlock(block: id, after: after, from: from)
    }

    private mutating func applySetBlock(id: DocBlockID, kind: BlockKind, indent: Int) throws(DocError) -> DocStep {
        let index = try blockIndex(id)
        try checkBlock(kind: kind, indent: indent, text: blocks[index].text)
        let previous = blocks[index]
        blocks[index].kind = kind
        blocks[index].indent = indent
        return .setBlock(
            block: id, kind: kind, indent: indent,
            previousKind: previous.kind, previousIndent: previous.indent
        )
    }
}

extension Database {
    /// Same recorded-field rules as `Doc.apply`, scoped to one database.
    @discardableResult
    mutating func apply(_ step: DatabaseStep) throws(DocError) -> DatabaseStep {
        switch step {
        case .setCell(let row, let column, let value, _):
            return try applySetCell(row: row, column: column, value: value)
        case .insertRow(let row, let after):
            guard rows.allSatisfy({ $0.id != row.id }) else { throw .duplicateID }
            let index = try rowAfterIndex(after)
            rows.insert(row, at: index)
            return step
        case .deleteRow(let row, _):
            guard let index = rows.firstIndex(where: { $0.id == row.id }) else { throw .rowNotFound(row.id) }
            let after = index > 0 ? rows[index - 1].id : nil
            return .deleteRow(row: rows.remove(at: index), after: after)
        case .moveRow(let row, let after, _):
            guard let index = rows.firstIndex(where: { $0.id == row }) else { throw .rowNotFound(row) }
            if after == row { throw .invalidMove }
            if let after { _ = try rowAfterIndex(after) }  // validate before mutating
            let from = index > 0 ? rows[index - 1].id : nil
            let element = rows.remove(at: index)
            rows.insert(element, at: try rowAfterIndex(after))
            return .moveRow(row: row, after: after, from: from)
        case .insertColumn(let column, let after, let cells):
            guard columns.allSatisfy({ $0.id != column.id }) else { throw .duplicateID }
            columns.insert(column, at: try columnAfterIndex(after))
            for (row, value) in cells {
                if let index = rows.firstIndex(where: { $0.id == row }) {
                    rows[index].cells[column.id] = value
                }
            }
            return .insertColumn(column: column, after: after, cells: cells)
        case .deleteColumn(let column, _, _):
            guard let index = columns.firstIndex(where: { $0.id == column.id }) else {
                throw .columnNotFound(column.id)
            }
            let after = index > 0 ? columns[index - 1].id : nil
            var cells: [RowID: CellValue] = [:]
            for rowIndex in rows.indices {
                cells[rows[rowIndex].id] = rows[rowIndex].cells.removeValue(forKey: column.id)
            }
            return .deleteColumn(column: columns.remove(at: index), after: after, cells: cells)
        case .updateColumn(let column, _):
            guard let index = columns.firstIndex(where: { $0.id == column.id }) else {
                throw .columnNotFound(column.id)
            }
            let previous = columns[index]
            columns[index] = column
            return .updateColumn(column: column, previous: previous)
        }
    }

    private mutating func applySetCell(row: RowID, column: ColumnID, value: CellValue?) throws(DocError) -> DatabaseStep {
        guard columns.contains(where: { $0.id == column }) else { throw .columnNotFound(column) }
        guard let index = rows.firstIndex(where: { $0.id == row }) else { throw .rowNotFound(row) }
        let previous = rows[index].cells[column]
        rows[index].cells[column] = value
        return .setCell(row: row, column: column, value: value, previous: previous)
    }

    private func rowAfterIndex(_ after: RowID?) throws(DocError) -> Int {
        guard let after else { return 0 }
        guard let index = rows.firstIndex(where: { $0.id == after }) else { throw .rowAnchorNotFound(after) }
        return index + 1
    }

    private func columnAfterIndex(_ after: ColumnID?) throws(DocError) -> Int {
        guard let after else { return 0 }
        guard let index = columns.firstIndex(where: { $0.id == after }) else { throw .columnAnchorNotFound(after) }
        return index + 1
    }
}
