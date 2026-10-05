/// Who made a change. History is per-author: you only undo your own.
public enum DocAuthor: Hashable, Sendable, Codable {
    case person(client: DocClientID)
    case agent(client: DocClientID)
}

/// A position inside a block, addressed by block id so remote edits to other
/// blocks never shift it.
public struct DocPosition: Hashable, Sendable, Codable {
    public var block: DocBlockID
    /// UTF-16 offset inside the block's text.
    public var offset: Int

    public init(block: DocBlockID, offset: Int) {
        self.block = block
        self.offset = offset
    }
}

/// Which side of an insertion a mapped position ends up on.
public enum DocBias: Hashable, Sendable {
    case before
    case after
}

/// A collapsed selection: anchor plus head.
public struct DocSelection: Hashable, Sendable, Codable {
    public var anchor: DocPosition
    public var head: DocPosition

    public init(anchor: DocPosition, head: DocPosition) {
        self.anchor = anchor
        self.head = head
    }
}

/// One user or agent action: the steps it produced plus the selection around
/// it, for undo to restore. The unit history stores and sync submits.
public struct DocTransaction: Hashable, Sendable, Codable {
    public var steps: [DocStep]
    public var selectionBefore: DocSelection?
    public var selectionAfter: DocSelection?
    public var author: DocAuthor
    public var time: Timestamp

    public init(
        steps: [DocStep],
        selectionBefore: DocSelection? = nil,
        selectionAfter: DocSelection? = nil,
        author: DocAuthor,
        time: Timestamp
    ) {
        self.steps = steps
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.author = author
        self.time = time
    }
}
