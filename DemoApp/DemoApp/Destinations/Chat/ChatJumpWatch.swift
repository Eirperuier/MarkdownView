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
        for cell in list.visibleCells {
            guard let row = Self.rowView(in: cell.contentView), let id = row.rowID, let block = row.blockView else { continue }
            let rect = block.convert(block.bounds, to: window)
            if !cell.isHidden, rect.intersects(window.bounds) { now[id] = rect }
        }
        var jumps: [String] = []
        for (id, rect) in now {
            guard let before = last[id] else { continue }
            let dy = rect.minY - (before.minY - moved)
            let dh = rect.height - before.height
            if abs(dy) > 0.5 || abs(dh) > 0.5 { jumps.append("\(Self.kind(id)) \(id) dy \(String(format: "%.1f", dy)) dh \(String(format: "%.1f", dh)) at \(Int(rect.minY))") }
        }
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
