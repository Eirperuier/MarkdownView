/// One client's undo stack, owned by the doc session rather than global, so
/// two open editors never share history. Remote steps only map through it,
/// they never clear it.
///
/// Each entry stores the transaction's inverse steps in application order
/// (last step's inverse first), plus the selection to restore.
public struct DocHistory: Sendable {
    /// What decides whether consecutive transactions merge into one undo
    /// step. The caller picks the key: typing in one block keeps it, moving
    /// the cursor or switching blocks breaks it.
    public struct MergeKey: Hashable, Sendable {
        public var block: DocBlockID
        public var session: UInt64

        public init(block: DocBlockID, session: UInt64) {
            self.block = block
            self.session = session
        }
    }

    fileprivate struct Entry: Sendable {
        var inverseSteps: [DocStep]
        var selectionBefore: DocSelection?
        var selectionAfter: DocSelection?
        var mergeKey: MergeKey?
        var author: DocAuthor
        var time: Timestamp
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private let mergeInterval: Int64

    public init(mergeInterval milliseconds: Int64 = 1500) {
        mergeInterval = milliseconds
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    /// Entries on the undo stack: a record that merged into the last one leaves it
    /// unchanged, so callers mirroring the stack (a system UndoManager) can tell.
    public var undoDepth: Int { undoStack.count }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Records a resolved transaction. Any local record clears the redo
    /// stack; remote steps go through `map(through:)` instead.
    public mutating func record(_ resolved: DocTransaction, merge key: MergeKey?) {
        redoStack.removeAll()
        let inverses = resolved.steps.map(\.inverted).reversed()
        if let key, let last = undoStack.last, last.mergeKey == key,
            resolved.time.millisecondsSince1970 - last.time.millisecondsSince1970 <= mergeInterval
        {
            undoStack[undoStack.count - 1].inverseSteps.insert(contentsOf: inverses, at: 0)
            undoStack[undoStack.count - 1].time = resolved.time
            undoStack[undoStack.count - 1].selectionAfter = resolved.selectionAfter
            return
        }
        undoStack.append(
            Entry(
                inverseSteps: Array(inverses),
                selectionBefore: resolved.selectionBefore,
                selectionAfter: resolved.selectionAfter,
                mergeKey: key,
                author: resolved.author,
                time: resolved.time
            )
        )
    }

    /// Maps every stored step and selection through a step that landed
    /// meanwhile — used when remote changes arrive. Clears nothing.
    public mutating func map(through step: DocStep) {
        undoStack = undoStack.map { $0.mapped(through: step) }
        redoStack = redoStack.map { $0.mapped(through: step) }
    }

    /// Undoes the most recent of *this* client's transactions. Inverse steps
    /// whose target is meanwhile gone are dropped; an entry that loses every
    /// step is skipped. Returns the transaction it applied, carrying the
    /// recorded `selectionBefore`.
    public mutating func undo(_ doc: inout Doc) -> DocTransaction? {
        Self.run(&undoStack, filling: &redoStack, on: &doc)
    }

    public mutating func redo(_ doc: inout Doc) -> DocTransaction? {
        Self.run(&redoStack, filling: &undoStack, on: &doc)
    }

    private static func run(
        _ source: inout [Entry], filling sink: inout [Entry], on doc: inout Doc
    ) -> DocTransaction? {
        while let entry = source.popLast() {
            var applied: [DocStep] = []
            for step in entry.inverseSteps {
                if let resolved = try? doc.apply(step) { applied.append(resolved) }
            }
            guard !applied.isEmpty else { continue }
            sink.append(
                Entry(
                    inverseSteps: applied.reversed().map(\.inverted),
                    selectionBefore: entry.selectionAfter,
                    selectionAfter: entry.selectionBefore,
                    mergeKey: nil,
                    author: entry.author,
                    time: entry.time
                )
            )
            return DocTransaction(
                steps: applied,
                selectionBefore: entry.selectionBefore,
                selectionAfter: entry.selectionAfter,
                author: entry.author,
                time: entry.time
            )
        }
        return nil
    }
}

extension DocHistory.Entry {
    /// Maps stored inverse steps through `step`; selections follow their
    /// positions and disappear with their block.
    func mapped(through step: DocStep) -> Self {
        var copy = self
        copy.inverseSteps = inverseSteps.flatMap { $0.mapped(through: step) }
        copy.selectionBefore = selectionBefore?.mapped(through: step)
        copy.selectionAfter = selectionAfter?.mapped(through: step)
        return copy
    }
}

extension DocSelection {
    func mapped(through step: DocStep) -> DocSelection? {
        guard let anchor = step.map(anchor, bias: .after), let head = step.map(head, bias: .after) else { return nil }
        return DocSelection(anchor: anchor, head: head)
    }
}
