//
//  NodeViewCache.swift
//  MarkdownView
//
//  LRU cache for rendered MarkdownNodeView instances, keyed by
//  (contentHash, configurationHash). Avoids re-visiting unchanged
//  AST nodes during incremental streaming updates.
//

import Foundation

struct NodeCacheKey: Hashable, Sendable {
    let contentHash: Int
    let configurationHash: Int
}

final class NodeViewCache: @unchecked Sendable {
    static let shared = NodeViewCache()

    private var storage: [NodeCacheKey: MarkdownNodeView] = [:]
    private var accessOrder: [NodeCacheKey] = []
    private let maxSize: Int
    private let lock = NSLock()

    private var hits: Int = 0
    private var misses: Int = 0

    init(maxSize: Int = 500) {
        self.maxSize = maxSize
    }

    func get(_ key: NodeCacheKey) -> MarkdownNodeView? {
        lock.lock()
        defer { lock.unlock() }
        guard let view = storage[key] else {
            misses += 1
            return nil
        }
        hits += 1
        _promoteInAccessOrder(key)
        return view
    }

    func set(_ key: NodeCacheKey, view: MarkdownNodeView) {
        lock.lock()
        defer { lock.unlock() }
        if storage[key] != nil {
            _promoteInAccessOrder(key)
        } else {
            accessOrder.append(key)
        }
        storage[key] = view
        _evictIfNeeded()
    }

    var hitRate: Double {
        lock.lock()
        defer { lock.unlock() }
        let total = hits + misses
        return total == 0 ? 0 : Double(hits) / Double(total)
    }

    var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        accessOrder.removeAll()
        hits = 0
        misses = 0
    }

    // MARK: - Private

    private func _promoteInAccessOrder(_ key: NodeCacheKey) {
        if let idx = accessOrder.lastIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(key)
    }

    private func _evictIfNeeded() {
        while storage.count > maxSize, !accessOrder.isEmpty {
            let evicted = accessOrder.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }
}
