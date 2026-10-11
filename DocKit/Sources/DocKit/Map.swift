extension DocStep {
    /// Maps a position through this step; nil when its block is gone.
    /// Positions are addressed by block id, so steps on other blocks are
    /// always the identity.
    public func map(_ position: DocPosition, bias: DocBias = .after) -> DocPosition? {
        switch self {
        case .insertText(let block, let at, let text):
            guard position.block == block else { return position }
            if position.offset > at || (position.offset == at && bias == .after) {
                return DocPosition(block: block, offset: position.offset + text.length)
            }
            return position
        case .deleteText(let block, let range, _):
            guard position.block == block else { return position }
            if position.offset <= range.lowerBound { return position }
            if position.offset >= range.upperBound {
                return DocPosition(block: block, offset: position.offset - range.count)
            }
            return DocPosition(block: block, offset: range.lowerBound)
        case .splitBlock(let block, let at, let newID, _, _, _):
            guard position.block == block else { return position }
            if position.offset > at || (position.offset == at && bias == .after) {
                return DocPosition(block: newID, offset: position.offset - at)
            }
            return position
        case .joinBlock(let block, let into, let at, _, _, _):
            guard position.block == block else { return position }
            return DocPosition(block: into, offset: at + position.offset)
        case .deleteBlock(let block, _):
            return position.block == block.id ? nil : position
        case .setMarks, .insertBlock, .moveBlock, .setBlock, .setDecoration,
            .createDatabase, .deleteDatabase, .database:
            return position
        }
    }

    /// Rebase: this step expressed against a doc that `other` was applied
    /// to. Empty means the step is dropped; two steps come out when a
    /// text range straddles `other`'s split point.
    /// `otherFirst` decides position ties: true when `other` is ordered
    /// before this step (server order); false means this step was there
    /// first, so its insertion points stay put.
    public func mapped(through other: DocStep, otherFirst: Bool = true) -> [DocStep] {
        let pointBias: DocBias = otherFirst ? .after : .before
        switch self {
        case .insertText(let block, let at, let text):
            guard let mapped = other.map(DocPosition(block: block, offset: at), bias: pointBias) else { return [] }
            return [.insertText(block: mapped.block, at: mapped.offset, text: text)]
        case .deleteText(let block, let range, let removed):
            return range.mapped(block: block, through: other).map {
                .deleteText(block: $0.block, range: $0.range, removed: removed)
            }
        case .setMarks(let block, let range, let kind, let spans, let previous):
            return range.mapped(block: block, through: other).map { segment in
                let segmentSpans = spans.compactMap { span -> MarkSpan? in
                    guard let piece = span.range.mappedPiece(block: block, in: segment.block, through: other) else {
                        return nil
                    }
                    let lower = max(piece.lowerBound, segment.range.lowerBound)
                    let upper = min(piece.upperBound, segment.range.upperBound)
                    return lower < upper ? MarkSpan(range: lower..<upper, mark: span.mark) : nil
                }
                return .setMarks(block: segment.block, range: segment.range, kind: kind, spans: segmentSpans, previous: previous)
            }
        case .splitBlock(let block, let at, let newID, let newKind, let newIndent, let newDecoration):
            guard let mapped = other.map(DocPosition(block: block, offset: at), bias: pointBias) else { return [] }
            return [.splitBlock(block: mapped.block, at: mapped.offset, newID: newID, newKind: newKind, newIndent: newIndent, newDecoration: newDecoration)]
        case .joinBlock(let block, let into, let at, let kind, let indent, let decoration):
            guard !other.removes(block), let into = other.stayingAnchor(into) else { return [] }
            return [.joinBlock(block: block, into: into, at: at, kind: kind, indent: indent, decoration: decoration)]
        case .insertBlock(let block, let after):
            // A view of a database that is gone goes with it.
            if let id = block.kind.databaseID, other.deletesDatabase(id) { return [] }
            return [.insertBlock(block: block, after: other.movingAnchor(after))]
        case .deleteBlock(let block, let after):
            guard !other.removes(block.id) else { return [] }
            return [.deleteBlock(block: block, after: other.movingAnchor(after))]
        case .moveBlock(let block, let after, let from):
            guard !other.removes(block) else { return [] }
            return [.moveBlock(block: block, after: other.movingAnchor(after), from: from)]
        case .setBlock(let block, let kind, _, _, _):
            guard !other.removes(block) else { return [] }
            if let id = kind.databaseID, other.deletesDatabase(id) { return [] }
            return [self]
        case .setDecoration(let block, _, _):
            guard !other.removes(block) else { return [] }
            return [self]
        case .createDatabase:
            return [self]
        case .deleteDatabase(let database):
            if other.deletesDatabase(database.id) { return [] }
            // A collaborator shows it again: it stays.
            if other.showsDatabase(database.id) { return [] }
            return [self]
        case .database(let id, let step):
            switch other {
            case .deleteDatabase(let database) where database.id == id:
                return []
            case .database(let otherID, let otherStep) where otherID == id:
                return step.mapped(through: otherStep, otherFirst: otherFirst).map { .database(id: id, step: $0) }
            default:
                return [self]
            }
        }
    }

    private func deletesDatabase(_ id: DatabaseID) -> Bool {
        if case .deleteDatabase(let database) = self { return database.id == id }
        return false
    }

    /// Whether this step makes a block a view of database `id`.
    private func showsDatabase(_ id: DatabaseID) -> Bool {
        switch self {
        case .insertBlock(let block, _): block.kind.databaseID == id
        case .setBlock(_, let kind, _, _, _): kind.databaseID == id
        default: false
        }
    }

    /// Whether this step makes `id` stop addressing a block: deleted, or
    /// joined away into its predecessor.
    private func removes(_ id: DocBlockID) -> Bool {
        switch self {
        case .deleteBlock(let block, _): return block.id == id
        case .joinBlock(let block, _, _, _, _, _): return block == id
        default: return false
        }
    }

    /// Maps an `after:` anchor: a deleted anchor moves to that delete's own
    /// recorded `after`, a joined-away anchor to `into`.
    private func movingAnchor(_ id: DocBlockID?) -> DocBlockID? {
        guard let id else { return nil }
        switch self {
        case .deleteBlock(let block, let after): return block.id == id ? after : id
        case .joinBlock(let block, let into, _, _, _, _): return block == id ? into : id
        default: return id
        }
    }

    /// Maps an anchor that must keep existing (join's `into`): nil when this
    /// step removed it. A split of `into` inserts `newID` right after it, so
    /// `newID` is what now sits directly before the joining block.
    private func stayingAnchor(_ id: DocBlockID) -> DocBlockID? {
        switch self {
        case .deleteBlock(let block, _) where block.id == id: return nil
        case .joinBlock(let block, let into, _, _, _, _) where block == id: return into
        case .splitBlock(let block, _, let newID, _, _, _) where block == id: return newID
        default: return id
        }
    }
}

extension Range<Int> {
    /// Maps a text range: lower bound with `.after`, upper with `.before`.
    /// An empty result is dropped; when `other` splits the block inside the
    /// range, the two pieces on either side of the split both come out.
    func mapped(block: DocBlockID, through other: DocStep) -> [(block: DocBlockID, range: Range<Int>)] {
        guard let lower = other.map(DocPosition(block: block, offset: lowerBound), bias: .after),
            let upper = other.map(DocPosition(block: block, offset: upperBound), bias: .before)
        else { return [] }
        if lower.block == upper.block {
            return lower.offset < upper.offset ? [(lower.block, lower.offset..<upper.offset)] : []
        }
        guard case .splitBlock(let splitBlock, let at, let newID, _, _, _) = other,
            lower.block == splitBlock, upper.block == newID
        else { return [] }
        var segments: [(block: DocBlockID, range: Range<Int>)] = []
        if lower.offset < at { segments.append((splitBlock, lower.offset..<at)) }
        if upper.offset > 0 { segments.append((newID, 0..<upper.offset)) }
        return segments
    }

    /// Maps a mark span's range for `setMarks`, restricted to `block` — the
    /// half on the other side of a split belongs to the sibling step.
    func mappedPiece(block: DocBlockID, in target: DocBlockID, through other: DocStep) -> Range<Int>? {
        mapped(block: block, through: other).first { $0.block == target }?.range
    }
}

extension DatabaseStep {
    /// Row and column addresses follow the same anchor rules as blocks:
    /// targets drop when `other` removed them, anchors move to the removed
    /// element's recorded predecessor.
    /// `otherFirst` is accepted for symmetry with `DocStep.mapped`; database
    /// steps carry no text offsets, so no tie can arise.
    func mapped(through other: DatabaseStep, otherFirst _: Bool = true) -> [DatabaseStep] {
        switch self {
        case .setCell(let row, let column, _, _):
            if other.removes(row: row) || other.removes(column: column) { return [] }
            return [self]
        case .insertRow(let row, let after):
            return [.insertRow(row: row, after: other.movingAnchor(after))]
        case .deleteRow(let row, let after):
            if other.removes(row: row.id) { return [] }
            return [.deleteRow(row: row, after: other.movingAnchor(after))]
        case .moveRow(let row, let after, let from):
            if other.removes(row: row) { return [] }
            return [.moveRow(row: row, after: other.movingAnchor(after), from: from)]
        case .insertColumn(let column, let after, let cells):
            return [.insertColumn(column: column, after: other.movingAnchor(after), cells: cells)]
        case .deleteColumn(let column, let after, let cells):
            if other.removes(column: column.id) { return [] }
            return [.deleteColumn(column: column, after: other.movingAnchor(after), cells: cells)]
        case .updateColumn(let column, _):
            if other.removes(column: column.id) { return [] }
            return [self]
        }
    }

    private func removes(row id: RowID) -> Bool {
        if case .deleteRow(let row, _) = self { return row.id == id }
        return false
    }

    private func removes(column id: ColumnID) -> Bool {
        if case .deleteColumn(let column, _, _) = self { return column.id == id }
        return false
    }

    private func movingAnchor(_ id: RowID?) -> RowID? {
        guard let id else { return nil }
        if case .deleteRow(let row, let after) = self, row.id == id { return after }
        return id
    }

    private func movingAnchor(_ id: ColumnID?) -> ColumnID? {
        guard let id else { return nil }
        if case .deleteColumn(let column, let after, _) = self, column.id == id { return after }
        return id
    }
}
