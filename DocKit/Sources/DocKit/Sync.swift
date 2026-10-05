/// One entry in the server's step log: the client's steps plus the seq the
/// server assigned. The server never reads `steps` — payload could be
/// ciphertext.
public struct DocLogEntry: Hashable, Sendable, Codable {
    public var seq: Int
    public var opID: DocOperationID
    public var client: DocClientID
    public var author: DocAuthor
    public var time: Timestamp
    public var steps: [DocStep]

    public init(seq: Int, opID: DocOperationID, client: DocClientID, author: DocAuthor, time: Timestamp, steps: [DocStep]) {
        self.seq = seq
        self.opID = opID
        self.client = client
        self.author = author
        self.time = time
        self.steps = steps
    }
}

/// What a client sends: its pending steps plus the last seq it saw (`base`).
public struct DocSubmission: Hashable, Sendable, Codable {
    public var base: Int
    public var opID: DocOperationID
    public var client: DocClientID
    public var author: DocAuthor
    public var time: Timestamp
    public var steps: [DocStep]

    public init(base: Int, opID: DocOperationID, client: DocClientID, author: DocAuthor, time: Timestamp, steps: [DocStep]) {
        self.base = base
        self.opID = opID
        self.client = client
        self.author = author
        self.time = time
        self.steps = steps
    }
}

public enum DocSubmitResult: Hashable, Sendable {
    case accepted(seq: Int)
    case behind(missing: [DocLogEntry])
}

/// The server-ordered log, in memory. Does exactly one thing: `base == head`
/// appends with the next seq, anything else returns the missing entries.
/// Duplicate opIDs get the original seq back, so retries are safe.
public struct InMemoryDocServer: Sendable {
    public private(set) var head: Int
    private var log: [DocLogEntry] = []

    public init() {
        head = 0
    }

    public mutating func submit(_ submission: DocSubmission) -> DocSubmitResult {
        if let existing = log.first(where: { $0.opID == submission.opID }) {
            return .accepted(seq: existing.seq)
        }
        guard submission.base == head else {
            return .behind(missing: entries(after: submission.base))
        }
        let entry = DocLogEntry(
            seq: head + 1,
            opID: submission.opID,
            client: submission.client,
            author: submission.author,
            time: submission.time,
            steps: submission.steps
        )
        log.append(entry)
        head = entry.seq
        return .accepted(seq: head)
    }

    public func entries(after seq: Int) -> [DocLogEntry] {
        log.filter { $0.seq > seq }
    }
}

/// One client's side of the protocol: a confirmed view (everything up to
/// `seq`), the local steps on top of it (`pending`), and the one submission
/// currently in flight.
public struct DocClient: Sendable {
    public private(set) var doc: Doc
    public private(set) var confirmed: Doc
    public private(set) var seq: Int
    public private(set) var pending: [DocStep]
    public private(set) var inflight: DocSubmission?
    public private(set) var history: DocHistory
    public let client: DocClientID
    public let author: DocAuthor

    public init(doc: Doc, seq: Int, client: DocClientID, author: DocAuthor) {
        self.doc = doc
        confirmed = doc
        self.seq = seq
        pending = []
        inflight = nil
        history = DocHistory()
        self.client = client
        self.author = author
    }

    /// Applies a transaction locally, queues its steps for submission and
    /// records it for undo.
    public mutating func apply(_ transaction: DocTransaction, merge key: DocHistory.MergeKey? = nil) throws(DocError) {
        let resolved = try doc.apply(transaction)
        pending += resolved.steps
        history.record(resolved, merge: key)
    }

    /// Both undo and redo produce ordinary steps that go into `pending` like
    /// any local edit.
    public mutating func undo() -> Bool {
        guard let transaction = history.undo(&doc) else { return false }
        pending += transaction.steps
        return true
    }

    public mutating func redo() -> Bool {
        guard let transaction = history.redo(&doc) else { return false }
        pending += transaction.steps
        return true
    }

    /// Packages all pending steps for submission; nil while another
    /// submission is in flight or nothing is pending.
    public mutating func submission(opID: DocOperationID, time: Timestamp) -> DocSubmission? {
        guard !pending.isEmpty, inflight == nil else { return nil }
        let submission = DocSubmission(
            base: seq, opID: opID, client: client, author: author, time: time, steps: pending
        )
        inflight = submission
        return submission
    }

    /// The server accepted the in-flight submission: its steps are now part
    /// of `confirmed`.
    public mutating func acknowledge(seq: Int) {
        guard let submission = inflight else { return }
        for step in submission.steps {
            _ = try? confirmed.apply(step)
        }
        pending.removeFirst(min(submission.steps.count, pending.count))
        inflight = nil
        self.seq = seq
    }

    /// Takes in log entries the client was behind on. An entry carrying the
    /// in-flight opID is the acknowledgement; anything else is remote and
    /// rebases the local pending steps prosemirror-collab style. Returns the
    /// pending steps that did not survive the rebase.
    @discardableResult
    public mutating func receive(_ entries: [DocLogEntry]) -> [DocStep] {
        var dropped: [DocStep] = []
        for entry in entries {
            if let submission = inflight, submission.opID == entry.opID {
                acknowledge(seq: entry.seq)
                continue
            }
            for step in entry.steps {
                _ = try? confirmed.apply(step)
            }
            inflight = nil
            dropped += rebase(through: entry.steps)
            seq = entry.seq
        }
        return dropped
    }

    /// Transforms `pending` against the remote sequence and re-applies the
    /// survivors on top of the new `confirmed`. History is mapped through
    /// the remote steps *as transformed into current-doc coordinates*, which
    /// is where its entries live.
    private mutating func rebase(through remote: [DocStep]) -> [DocStep] {
        let (groups, remotePrime) = DocStep.transformGrouped(pending, over: remote)
        var kept: [DocStep] = []
        var dropped: [DocStep] = []
        doc = confirmed
        for (original, mapped) in zip(pending, groups) {
            var applied = false
            for step in mapped {
                if let resolved = try? doc.apply(step) {
                    applied = true
                    kept.append(resolved)
                }
            }
            // Each original step is reported at most once: when it
            // transformed to nothing or everything it became failed.
            if !applied {
                dropped.append(original)
            }
        }
        pending = kept
        for step in remotePrime {
            history.map(through: step)
        }
        return dropped
    }
}
