//
//  ChatJumpWatch.swift
//  DemoApp
//
//  PROBE (`-chatJumpWatch YES`): every frame, where each block on screen is in the window. A block
//  that moves by other than the scroll is a jump; each goes to /tmp/md-jump.log with the frame's
//  marks.
//

import UIKit

@MainActor
final class ChatJumpWatch: NSObject {
    static let shared = ChatJumpWatch()
    static let isOn = UserDefaults.standard.bool(forKey: "chatJumpWatch")

    private weak var list: UICollectionView?
    private var link: CADisplayLink?
    private var lastOffset: CGFloat = 0
    private var last: [String: CGRect] = [:]
    private var lastHeights: [String: CGFloat] = [:]
    private var lastContentHeight: CGFloat = 0
    private var lastPlaces: [String: String] = [:]
    private var lastItemHeights: [Int: (y: CGFloat, h: CGFloat)] = [:]
    private var frame = 0
    private let path = "/tmp/md-jump.log"

    func attach(_ list: UICollectionView) {
        guard Self.isOn, link == nil else { return }
        self.list = list
        try? "attached\n".write(toFile: path, atomically: true, encoding: .utf8)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        guard let list, let window = list.window else { return }
        frame += 1
        let offset = list.contentOffset.y
        let moved = offset - lastOffset
        var now: [String: CGRect] = [:]
        var places: [String: String] = [:]
        for cell in list.visibleCells {
            guard let row = Self.rowView(in: cell.contentView), let id = row.rowID, let block = row.blockView else { continue }
            let rect = block.convert(block.bounds, to: window)
            if !cell.isHidden, rect.intersects(window.bounds) { now[id] = rect }
            places[id] = "cell \(Int(cell.frame.minY - offset)) h \(Int(cell.frame.height)) ip \(list.indexPath(for: cell).map { "\($0.item)" } ?? "-") blockY \(Int(block.frame.minY)) rowY \(Int(row.frame.minY)) rowH \(Int(row.frame.height)) inCell \(row.isDescendant(of: cell)) cellObj \(ObjectIdentifier(cell).hashValue % 10000) sub \(Int(cell.layer.sublayerTransform.m42)) cellT \(Int(cell.transform.ty)) rowT \(Int(row.transform.ty)) contentY \(Int(cell.contentView.frame.minY)) list \(Int(list.convert(CGPoint(x: 0, y: offset), to: window).y))"
        }
        var jumps: [String] = []
        // Rows laid out off screen too: one above that changes height moves what's on screen.
        var heights: [String: CGFloat] = [:]
        for cell in list.visibleCells {
            guard let row = Self.rowView(in: cell.contentView), let id = row.rowID else { continue }
            heights[id] = cell.frame.height
            if let before = lastHeights[id], abs(before - cell.frame.height) > 0.5, now[id] == nil {
                jumps.append("offscreen \(Self.kind(id)) \(id) dh \(String(format: "%.1f", cell.frame.height - before)) cellY \(Int(cell.frame.minY - offset))")
            }
        }
        if abs(list.contentSize.height - lastContentHeight) > 0.5, lastContentHeight > 0 {
            jumps.append("contentSize dh \(String(format: "%.1f", list.contentSize.height - lastContentHeight))")
        }
        lastHeights = heights
        lastContentHeight = list.contentSize.height
        var moves = 0
        for (id, rect) in now {
            guard let before = last[id] else { continue }
            let dy = rect.minY - (before.minY - moved)
            let dh = rect.height - before.height
            if abs(dy) > 0.5 || abs(dh) > 0.5 {
                moves += 1
                jumps.append("\(Self.kind(id)) \(id) dy \(String(format: "%.1f", dy)) dh \(String(format: "%.1f", dh)) at \(Int(rect.minY)) now[\(places[id] ?? "")] before[\(lastPlaces[id] ?? "")]")
            }
        }
        lastPlaces = places
        // Rows above the screen, laid out: one that changed height pushes what's on screen.
        let items = list.indexPathsForVisibleItems.map(\.item)
        var itemHeights: [Int: (y: CGFloat, h: CGFloat)] = [:]
        if let first = items.min(), let lastItem = items.max(), list.numberOfSections > 0 {
            for item in max(0, first - 40)...lastItem where item < list.numberOfItems(inSection: 0) {
                if let attributes = list.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: item, section: 0)) {
                    itemHeights[item] = (attributes.frame.minY, attributes.frame.height)
                }
            }
        }
        if moves > 0 {
            var changed: [String] = []
            for (item, now) in itemHeights.sorted(by: { $0.key < $1.key }) {
                guard let before = lastItemHeights[item] else { continue }
                if abs(now.h - before.h) > 0.5 || abs(now.y - before.y) > 0.5 {
                    changed.append("ip \(item) y \(Int(before.y - offset))->\(Int(now.y - offset)) h \(String(format: "%.1f", before.h))->\(String(format: "%.1f", now.h))")
                }
            }
            jumps.append("ITEMS " + (changed.isEmpty ? "none changed" : changed.prefix(24).joined(separator: ", ")))
        }
        lastItemHeights = itemHeights
        if frame % 120 == 0 { jumps.append("alive offset \(Int(offset)) rows \(now.count)") }
        if !jumps.isEmpty {
            let state = "tracking \(list.isTracking) dragging \(list.isDragging) decel \(list.isDecelerating) moved \(String(format: "%.1f", moved))"
            let line = "frame \(frame) \(state) | " + jumps.joined(separator: "; ") + "\n"
            if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        }
        last = now
        lastOffset = offset
    }

    private static func kind(_ id: String) -> String {
        guard let row = ChatTextSelection.shared.conversation?.rows.first(where: { $0.id == id }), case .block(let block) = row.kind else { return "?" }
        return "\(block.descriptor.kind) <\(block.source.prefix(50).replacingOccurrences(of: "\n", with: " "))>"
    }

    private static func rowView(in view: UIView, depth: Int = 0) -> ChatUIKitRowView? {
        if let row = view as? ChatUIKitRowView { return row }
        guard depth < 3 else { return nil }
        for subview in view.subviews {
            if let row = rowView(in: subview, depth: depth + 1) { return row }
        }
        return nil
    }
}
