//
//  ASTDiffer.swift
//  MarkdownView
//
//  Efficient O(n) diff of top-level AST children between two Documents.
//  Used by the incremental renderer to skip re-rendering unchanged nodes.
//

@preconcurrency import Markdown

enum ASTChangeType: Sendable {
    case unchanged
    case modified
    case inserted
    case removed
}

struct ASTChange: Sendable {
    let type: ASTChangeType
    let oldIndex: Int?
    let newIndex: Int?
    let contentHash: Int?
}

struct ASTDiffResult: Sendable {
    let changes: [ASTChange]
    let unchangedNewIndices: Set<Int>

    var cacheHitRate: Double {
        guard !changes.isEmpty else { return 1.0 }
        let unchanged = changes.filter { $0.type == .unchanged }.count
        return Double(unchanged) / Double(changes.count)
    }
}

enum ASTDiffer {
    /// O(n) diff comparing top-level children of two Documents by content hash.
    ///
    /// Algorithm: match from the head (common prefix) and from the tail (common suffix),
    /// then mark the middle segment as modified/inserted/removed.
    static func diff(old: Document?, new: Document) -> ASTDiffResult {
        guard let old else {
            let newChildren = Array(new.children)
            let changes = newChildren.enumerated().map { idx, child in
                ASTChange(type: .inserted, oldIndex: nil, newIndex: idx, contentHash: child.stableContentHash)
            }
            return ASTDiffResult(changes: changes, unchangedNewIndices: [])
        }

        let oldHashes = old.children.map(\.stableContentHash)
        let newHashes = new.children.map(\.stableContentHash)

        let oldCount = oldHashes.count
        let newCount = newHashes.count

        if oldHashes == newHashes {
            let changes = (0..<newCount).map { idx in
                ASTChange(type: .unchanged, oldIndex: idx, newIndex: idx, contentHash: newHashes[idx])
            }
            return ASTDiffResult(changes: changes, unchangedNewIndices: Set(0..<newCount))
        }

        var prefixLen = 0
        let minCount = min(oldCount, newCount)
        while prefixLen < minCount && oldHashes[prefixLen] == newHashes[prefixLen] {
            prefixLen += 1
        }

        var suffixLen = 0
        while suffixLen < (minCount - prefixLen)
            && oldHashes[oldCount - 1 - suffixLen] == newHashes[newCount - 1 - suffixLen]
        {
            suffixLen += 1
        }

        var changes = [ASTChange]()
        changes.reserveCapacity(max(oldCount, newCount))
        var unchangedIndices = Set<Int>()

        for i in 0..<prefixLen {
            changes.append(ASTChange(type: .unchanged, oldIndex: i, newIndex: i, contentHash: newHashes[i]))
            unchangedIndices.insert(i)
        }

        let oldMiddleEnd = oldCount - suffixLen
        let newMiddleEnd = newCount - suffixLen

        for i in prefixLen..<oldMiddleEnd {
            if i < newMiddleEnd && i < newCount {
                changes.append(ASTChange(type: .modified, oldIndex: i, newIndex: i, contentHash: newHashes[i]))
            } else {
                changes.append(ASTChange(type: .removed, oldIndex: i, newIndex: nil, contentHash: oldHashes[i]))
            }
        }

        for i in max(prefixLen, oldMiddleEnd)..<newMiddleEnd {
            changes.append(ASTChange(type: .inserted, oldIndex: nil, newIndex: i, contentHash: newHashes[i]))
        }

        for s in 0..<suffixLen {
            let oi = oldCount - suffixLen + s
            let ni = newCount - suffixLen + s
            changes.append(ASTChange(type: .unchanged, oldIndex: oi, newIndex: ni, contentHash: newHashes[ni]))
            unchangedIndices.insert(ni)
        }

        return ASTDiffResult(changes: changes, unchangedNewIndices: unchangedIndices)
    }
}
