//
//  DocBlocks.swift
//  DemoApp
//
//  Blocks as wholes, the way Craft handles them. On the Mac a handle shows beside the
//  block under the pointer: a click selects the block (⇧ extends, ⌘ adds), a drag
//  moves it. On a phone, as in flowith's Composer, a long press lifts the block: drag
//  it to move it, or let go to start selecting blocks (tap to add or remove). A list
//  item moves with the items nested under it; a move is one transaction of moveBlock
//  steps, undone in one go.
//
//  The handle, the selection, the drop line and the dimmed source rows are views in
//  the list's own scroll view (content coordinates), so they scroll with the rows.
//

import SwiftUI
import DocKit
import MessagingUI

@MainActor
@Observable
final class DocBlockController: NSObject, UIGestureRecognizerDelegate {
    #if targetEnvironment(macCatalyst)
    nonisolated static let usesHandles = true
    #else
    nonisolated static let usesHandles = false
    #endif
    /// The page's side margins; on the Mac they leave room for the handle.
    nonisolated static let gutter: CGFloat = usesHandles ? 40 : 16

    @ObservationIgnored private let demo: DocDemo
    @ObservationIgnored unowned let editor: DocEditor
    /// The selected blocks, in document order (a list item's nested items included).
    private(set) var selected: [DocBlockID] = []
    /// The phone's selection mode (Composer's batch editing): taps select, the text
    /// isn't edited, a bar offers what to do with the blocks.
    private(set) var isSelecting = false

    @ObservationIgnored private var anchor: DocBlockID?
    @ObservationIgnored private var head: DocBlockID?
    @ObservationIgnored private weak var reader: TiledViewReader<String>?
    @ObservationIgnored private weak var list: UICollectionView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private lazy var handle = DocBlockHandleView()
    @ObservationIgnored private lazy var keys = DocBlockKeyView()
    @ObservationIgnored private lazy var indicator: UIView = {
        let view = UIView()
        view.backgroundColor = .tintColor
        view.layer.cornerRadius = 1
        view.layer.zPosition = 7
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()
    @ObservationIgnored private var highlights: [UIView] = []
    @ObservationIgnored private var dimmers: [UIView] = []
    /// The block under the pointer (its handle is shown), and where the pointer is in
    /// the list's frame, to find it again after a scroll.
    @ObservationIgnored private(set) var hovered: DocBlockID?
    @ObservationIgnored private var hoverPoint: CGPoint?
    @ObservationIgnored private var press: (block: DocBlockID, start: CGPoint)?
    @ObservationIgnored private var drag: Drag?
    @ObservationIgnored private var link: CADisplayLink?
    /// Pieces flying to their rows: the selection shows once they're down.
    @ObservationIgnored private var landings = 0

    private struct Drag {
        /// The blocks picked up (the selection, or the one grabbed), and with them the
        /// items nested under them: what moves.
        var tops: [DocBlockID]
        var moving: [DocBlockID]
        var preview: UIView
        /// The card in the preview and, on it, each moving block's row as an image.
        var card: UIView
        var pieces: [Piece]
        /// From the pointer to the preview's centre, in the list's frame.
        var offset: CGPoint
        /// The pointer, in the list's frame (stays put while the list scrolls under it).
        var point: CGPoint
        /// Whether it has moved yet: a phone's lifted block can still be let go as a tap.
        var isMoving: Bool
        /// Where the blocks would go: after this block (nil: the top), or nowhere new.
        var target: DocBlockID??
    }

    /// One block's row in the preview, and where it sits on the card.
    private struct Piece {
        var block: DocBlockID
        var view: UIImageView
        var slot: CGRect
    }

    init(demo: DocDemo, editor: DocEditor) {
        self.demo = demo
        self.editor = editor
        super.init()
    }

    // MARK: Attaching

    /// Puts the handle, the gestures and the key responder on the list once it exists.
    func attach(_ reader: TiledViewReader<String>) {
        self.reader = reader
        guard list == nil || list?.window == nil, let container = reader.containerView,
            let list = Self.collectionView(in: container)
        else { return }
        self.list = list
        list.addSubview(indicator)
        list.addSubview(keys)
        keys.controller = self
        if Self.usesHandles {
            list.addSubview(handle)
            handle.isHidden = true
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            list.addGestureRecognizer(hover)
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePressed(_:)))
            press.minimumPressDuration = 0
            press.allowableMovement = .greatestFiniteMagnitude
            handle.addGestureRecognizer(press)
        } else {
            let lift = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            lift.minimumPressDuration = 0.35
            lift.delegate = self
            list.addGestureRecognizer(lift)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delegate = self
            list.addGestureRecognizer(tap)
        }
        observations = [
            list.observe(\.contentSize) { [weak self] _, _ in MainActor.assumeIsolated { self?.layoutOverlays() } },
            list.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.followHover() } },
        ]
    }

    private static func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for subview in view.subviews {
            if let list = collectionView(in: subview) { return list }
        }
        return nil
    }

    // MARK: Geometry

    private func rowFrame(_ id: DocBlockID) -> CGRect? {
        reader?.frame(forItem: id.description)
    }

    /// The row less its margins: the page is at most 720 wide, centred.
    private func contentFrame(_ id: DocBlockID) -> CGRect? {
        guard let row = rowFrame(id) else { return nil }
        let width = max(0, min(720, row.width - 2 * Self.gutter))
        return CGRect(x: row.midX - width / 2, y: row.minY, width: width, height: row.height)
    }

    /// The committed block whose row is at `y` (list coordinates).
    private func block(atY y: CGFloat) -> DocBlockID? {
        guard let list, let reader else { return nil }
        let hits = reader.contentFrames(intersecting: CGRect(x: 0, y: y, width: list.bounds.width, height: 1))
        guard let id = hits.first(where: { $0.value.minY <= y && y < $0.value.maxY })?.key ?? hits.first?.key else { return nil }
        return demo.rows.first { $0.id == id }?.block
    }

    /// Where a block's first line is, for the handle: the text's first line, or near
    /// the top of a code block, a table, an image.
    private func firstLineMidY(_ id: DocBlockID, row: CGRect) -> CGFloat {
        if let list, let textView = editor.textView(for: id), textView.window != nil {
            let line = textView.convert(textView.caretRect(for: textView.beginningOfDocument), to: list)
            if line.height > 0, line.midY > row.minY, line.midY < row.maxY { return line.midY }
        }
        return row.height < 48 ? row.midY : row.minY + 20
    }

    // MARK: Overlays

    /// Lays the handle, the selection and a drag's marks out on the rows as they are now.
    func layoutOverlays() {
        guard let list else { return }
        let existing = Set(demo.doc.blocks.map(\.id))
        if selected.contains(where: { !existing.contains($0) }) {
            selected.removeAll { !existing.contains($0) }
            if selected.isEmpty, isSelecting { endSelecting() }
        }
        highlights = place(landings > 0 ? [] : runs(of: selected), in: highlights, outset: 6) {
            let view = UIView()
            view.backgroundColor = UIColor.tintColor.withAlphaComponent(0.13)
            view.layer.cornerRadius = 6
            view.layer.cornerCurve = .continuous
            view.layer.zPosition = 5
            return view
        }
        dimmers = place(drag.map { $0.isMoving ? runs(of: $0.moving) : [] } ?? [], in: dimmers, outset: 6) {
            let view = UIView()
            view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.65)
            view.layer.zPosition = 6
            return view
        }
        for view in highlights + dimmers where view.superview !== list { list.addSubview(view) }
        layoutHandle()
        if drag?.isMoving == true { updateTarget() }
    }

    /// The list's cells showing these blocks (by where the layout puts them).
    private func cells(of ids: [DocBlockID]) -> [UICollectionViewCell] {
        guard let list else { return [] }
        let frames = ids.compactMap(rowFrame)
        return list.visibleCells.filter { cell in
            frames.contains { abs($0.minY - cell.frame.minY) < 0.5 && abs($0.height - cell.frame.height) < 0.5 }
        }
    }

    /// Runs of rows next to each other in the document, as one rectangle each.
    private func runs(of ids: [DocBlockID]) -> [CGRect] {
        let chosen = Set(ids)
        var rects: [CGRect] = []
        var current: CGRect?
        for block in demo.doc.blocks {
            guard chosen.contains(block.id), let frame = contentFrame(block.id) else {
                if let run = current { rects.append(run) }
                current = nil
                continue
            }
            current = current.map { $0.union(frame) } ?? frame
        }
        if let run = current { rects.append(run) }
        return rects
    }

    private func place(_ rects: [CGRect], in views: [UIView], outset: CGFloat, make: () -> UIView) -> [UIView] {
        var views = views
        while views.count < rects.count { views.append(make()) }
        for (index, view) in views.enumerated() {
            view.isUserInteractionEnabled = false
            if index < rects.count {
                view.frame = rects[index].insetBy(dx: -outset, dy: 1)
                view.isHidden = false
            } else {
                view.isHidden = true
            }
        }
        return views
    }

    private func layoutHandle() {
        guard Self.usesHandles else { return }
        guard drag == nil, !demo.isAgentWriting, let hovered, let row = rowFrame(hovered), let content = contentFrame(hovered) else {
            handle.isHidden = true
            return
        }
        let size = DocBlockHandleView.size
        // One column for every block, nested or not: the handles line up.
        handle.frame = CGRect(x: content.minX - size.width - 6, y: firstLineMidY(hovered, row: row) - size.height / 2,
                              width: size.width, height: size.height)
        handle.layer.zPosition = 8
        handle.isHidden = false
    }

    // MARK: Mac: the handle

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard let list else { return }
        switch recognizer.state {
        case .began, .changed:
            hoverPoint = list.convert(recognizer.location(in: list), to: list.superview)
        default:
            // Leaving the list hides the handle, but not while it is being used.
            guard press == nil else { return }
            hoverPoint = nil
        }
        followHover()
    }

    /// The block under the pointer, again: the pointer moved or the rows did.
    private func followHover() {
        guard Self.usesHandles, let list, press == nil, drag == nil else { return }
        let next = hoverPoint.flatMap { block(atY: list.convert($0, from: list.superview).y) }
        if next != hovered { hovered = next }
        layoutHandle()
    }

    @objc private func handlePressed(_ recognizer: UILongPressGestureRecognizer) {
        guard let list else { return }
        let point = recognizer.location(in: list)
        switch recognizer.state {
        case .began:
            guard let hovered, !demo.isAgentWriting else { return }
            press = (hovered, point)
        case .changed:
            guard let press else { return }
            if drag == nil, hypot(point.x - press.start.x, point.y - press.start.y) > 4 {
                // Craft selects what it picks up, unless it is already in the selection.
                if !selected.contains(press.block) { select([press.block]) }
                lift(press.block, at: point)
                startMoving()
            }
            moveDrag(to: list.convert(point, to: list.superview))
        case .ended:
            guard let press else { return }
            self.press = nil
            if drag != nil {
                drop()
            } else {
                click(press.block, modifiers: recognizer.modifierFlags)
            }
        default:
            press = nil
            cancelDrag()
        }
    }

    /// A click on a block's handle: it becomes the selection; ⇧ extends the selection
    /// to it, ⌘ adds or removes it.
    func click(_ id: DocBlockID, modifiers: UIKeyModifierFlags = []) {
        if modifiers.contains(.shift), let anchor {
            extend(from: anchor, to: id)
        } else if modifiers.contains(.command) {
            let group = Set(groups([id]).flatMap { $0 })
            if selected.contains(id) {
                setSelection(selected.filter { !group.contains($0) })
            } else {
                setSelection(selected + group)
            }
            anchor = id
            head = id
        } else {
            select([id])
        }
        focusKeys()
    }

    // MARK: Selection

    /// Selects these blocks and the items nested under them.
    func select(_ tops: [DocBlockID]) {
        setSelection(groups(tops).flatMap { $0 })
        anchor = tops.first
        head = tops.last
    }

    private func setSelection(_ ids: [DocBlockID]) {
        let chosen = Set(ids)
        selected = demo.doc.blocks.map(\.id).filter { chosen.contains($0) }
        layoutOverlays()
    }

    /// Everything from `anchor` to `target`, in document order.
    private func extend(from anchor: DocBlockID, to target: DocBlockID) {
        let ids = demo.doc.blocks.map(\.id)
        guard let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: target) else { return }
        let range = min(from, to)...max(from, to)
        setSelection(groups(Array(ids[range])).flatMap { $0 })
        head = target
    }

    func clear() {
        guard !selected.isEmpty || isSelecting else { return }
        anchor = nil
        head = nil
        if isSelecting { endSelecting() }
        setSelection([])
    }

    /// Typing again (a text view took the focus): the blocks aren't selected any more.
    func textEditingBegan() {
        guard !isSelecting else { return }
        clear()
    }

    /// The block before or after the selection (↑ ↓); with ⇧ the selection grows to it.
    func step(_ direction: Int, extending: Bool) {
        let ids = demo.doc.blocks.map(\.id)
        guard let current = head ?? selected.last, let index = ids.firstIndex(of: current) else { return }
        var next = index + direction
        // Down from a list item skips the items nested under it (they're selected with it).
        if direction > 0, !extending, let last = selected.last, let lastIndex = ids.firstIndex(of: last) { next = max(next, lastIndex + 1) }
        guard ids.indices.contains(next) else { return }
        if extending, let anchor {
            extend(from: anchor, to: ids[next])
        } else {
            select([ids[next]])
        }
        if let list, let frame = rowFrame(ids[next]) {
            list.scrollRectToVisible(frame.insetBy(dx: 0, dy: -24), animated: true)
        }
    }

    /// Return: edit the selected block's text, the cursor at its end.
    func editSelection() {
        guard let first = selected.first, let block = demo.doc.block(first) else { return }
        clear()
        if block.kind.carriesText { editor.place(DocPosition(block: block.id, offset: block.text.length)) }
    }

    private func focusKeys() {
        guard Self.usesHandles, keys.window != nil else { return }
        editor.tables.endEditing()
        editor.sources.endEditing()
        keys.becomeFirstResponder()
    }

    /// The key responder lost the focus (a click into the text, a cell, another field).
    fileprivate func keysResigned() {
        guard drag == nil else { return }
        clear()
    }

    // MARK: Phone: lift, select

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer is UITapGestureRecognizer { return isSelecting }
        guard !demo.isAgentWriting, drag == nil else { return false }
        var view = touch.view
        while let current = view, current !== list {
            if current is UIControl { return false }
            // The text being typed in keeps its own long press (the loupe, selecting).
            if current.isFirstResponder { return false }
            view = current.superview
        }
        return true
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard let list else { return }
        let point = recognizer.location(in: list)
        switch recognizer.state {
        case .began:
            guard let id = block(atY: point.y) else { return }
            press = (id, point)
            list.window?.endEditing(true)
            lift(id, at: point)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard let press else { return }
            if drag?.isMoving == false, hypot(point.x - press.start.x, point.y - press.start.y) > 10 { startMoving() }
            if drag?.isMoving == true { moveDrag(to: list.convert(point, to: list.superview)) }
        case .ended:
            guard let press else { return }
            self.press = nil
            if drag?.isMoving == true {
                drop()
            } else {
                cancelDrag()
                // Let go where it was lifted: select it (Composer's batch editing).
                if !isSelecting { beginSelecting(press.block) }
            }
        default:
            press = nil
            cancelDrag()
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard isSelecting, let list, let id = block(atY: recognizer.location(in: list).y) else { return }
        let group = Set(groups([id]).flatMap { $0 })
        if selected.contains(id) {
            setSelection(selected.filter { !group.contains($0) })
            if selected.isEmpty { endSelecting() }
        } else {
            setSelection(selected + group)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func beginSelecting(_ id: DocBlockID) {
        isSelecting = true
        editor.isEditable = false
        select([id])
    }

    func endSelecting() {
        isSelecting = false
        editor.isEditable = !demo.isAgentWriting
        anchor = nil
        head = nil
        if !selected.isEmpty { setSelection([]) }
    }

    // MARK: Dragging

    /// Picks the block up: the selection if the block is in it, else the block alone.
    /// The preview shows every block that moves, in document order, as they will stand
    /// after the drop; blocks that aren't next to the grabbed one fly into place on it.
    private func lift(_ id: DocBlockID, at point: CGPoint) {
        guard let list, let container = list.superview else { return }
        let tops = selected.contains(id) ? topsOfSelection() : [id]
        let moving = groups(tops).flatMap { $0 }
        guard let (preview, card, pieces) = makePreview(of: moving, grabbed: id) else { return }
        container.addSubview(preview)
        let at = list.convert(point, to: container)
        drag = Drag(tops: tops, moving: moving, preview: preview, card: card, pieces: pieces,
                    offset: CGPoint(x: preview.center.x - at.x, y: preview.center.y - at.y),
                    point: at, isMoving: false, target: nil)
        handle.isHidden = true
        // Each piece starts on its own row and goes to its place on the card.
        let scattered = pieces.contains { $0.view.frame != $0.slot }
        if scattered { card.clipsToBounds = false }
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            for piece in pieces { piece.view.frame = piece.slot }
            if !Self.usesHandles { preview.transform = CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 1.03, y: 1.03) }
        } completion: { _ in
            card.clipsToBounds = true
        }
    }

    private func startMoving() {
        guard var drag, !drag.isMoving else { return }
        drag.isMoving = true
        self.drag = drag
        editor.tables.endEditing()
        editor.sources.endEditing()
        let preview = drag.preview
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            // On a phone the finger covers the block: it shrinks so the line where it
            // will go stays in sight (Composer's).
            preview.transform = Self.usesHandles ? .identity : CGAffineTransform(translationX: 0, y: -2).scaledBy(x: 0.5, y: 0.5)
            preview.alpha = Self.usesHandles ? 0.92 : 1
        }
        link = CADisplayLink(target: self, selector: #selector(autoscroll(_:)))
        link?.add(to: .main, forMode: .common)
        layoutOverlays()
    }

    private func moveDrag(to point: CGPoint) {
        guard var drag, drag.isMoving else { return }
        drag.point = point
        drag.preview.center = CGPoint(x: point.x + drag.offset.x, y: point.y + drag.offset.y)
        self.drag = drag
        updateTarget()
    }

    /// Where the blocks would land under the pointer, and the line that shows it.
    private func updateTarget() {
        guard var drag, let list else { return }
        let y = list.convert(drag.point, from: list.superview).y
        let gap = gap(atY: y)
        let target = gap.flatMap { destination(gap: $0, moving: drag.moving) }
        if !Self.usesHandles, target != drag.target, drag.target != nil { UISelectionFeedbackGenerator().selectionChanged() }
        drag.target = target
        self.drag = drag
        guard let gap, target != nil, let lineY = lineY(gap: gap), let content = contentFrame(drag.tops[0]) else {
            indicator.isHidden = true
            return
        }
        indicator.frame = CGRect(x: content.minX - 6, y: lineY - 1, width: content.width + 12, height: 2)
        indicator.isHidden = false
    }

    /// The gap between blocks (an index into the document's blocks) nearest `y`.
    private func gap(atY y: CGFloat) -> Int? {
        guard let list, let reader else { return nil }
        let index = Dictionary(uniqueKeysWithValues: demo.doc.blocks.enumerated().map { ($1.id.description, $0) })
        let frames = reader.contentFrames(intersecting: list.bounds.insetBy(dx: 0, dy: -400))
            .compactMap { id, frame in index[id].map { ($0, frame) } }
            .sorted { $0.0 < $1.0 }
        guard let first = frames.first, let last = frames.last else { return nil }
        if y < first.1.minY { return first.0 }
        for (index, frame) in frames where y < frame.maxY {
            return y < frame.midY ? index : index + 1
        }
        return last.0 + 1
    }

    private func lineY(gap: Int) -> CGFloat? {
        let blocks = demo.doc.blocks
        if blocks.indices.contains(gap), let frame = rowFrame(blocks[gap].id) { return frame.minY }
        if blocks.indices.contains(gap - 1), let frame = rowFrame(blocks[gap - 1].id) { return frame.maxY }
        return nil
    }

    /// The block the moving blocks would follow if dropped in `gap`; nil when they'd
    /// stay where they are.
    private func destination(gap: Int, moving: [DocBlockID]) -> DocBlockID?? {
        let blocks = demo.doc.blocks.map(\.id)
        let movingSet = Set(moving)
        var before = min(gap, blocks.count) - 1
        while before >= 0, movingSet.contains(blocks[before]) { before -= 1 }
        let after = before >= 0 ? blocks[before] : nil
        var order = blocks.filter { !movingSet.contains($0) }
        let at = after.flatMap { order.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        order.insert(contentsOf: moving, at: at)
        return order == blocks ? nil : .some(after)
    }

    private func drop() {
        guard let drag = endDrag() else { return }
        // Their rows go before the move: from the next frame on they'd be found elsewhere.
        let rows = hide(drag.moving)
        var moved = false
        if case .some(let after) = drag.target, move(drag.tops, after: after) {
            moved = true
            if Self.usesHandles || isSelecting { select(drag.tops) }
            if Self.usesHandles { focusKeys() }
        }
        land(drag, moved: moved, hidden: rows)
    }

    private func cancelDrag() {
        guard let drag = endDrag() else { return }
        land(drag, moved: false, hidden: hide(drag.moving))
    }

    /// Hides these blocks' rows: what the cells host, not the cells or their content
    /// views, whose alpha the list sets itself (a move is a delete and an insert, faded).
    private func hide(_ ids: [DocBlockID]) -> [UIView] {
        let rows = cells(of: ids).flatMap(\.contentView.subviews).filter { $0.alpha != 0 }
        for row in rows { row.alpha = 0 }
        return rows
    }

    /// Stops following the pointer; the preview stays up for the landing.
    private func endDrag() -> Drag? {
        guard let drag else { return nil }
        self.drag = nil
        link?.invalidate()
        link = nil
        indicator.isHidden = true
        layoutOverlays()
        return drag
    }

    /// Each block's row goes from where it floats on the card to where the block is
    /// now (moved, or back where it was) and gives way to the row there. Until they
    /// land their rows are hidden, so no block is shown twice.
    private func land(_ drag: Drag, moved: Bool, hidden rows: [UIView]) {
        let preview = drag.preview, card = drag.card, pieces = drag.pieces
        let first = drag.moving[0]
        let before = rowFrame(first)
        // The moving rows stay hidden until their pieces land on them (the list slides
        // the other rows into place meanwhile).
        var hidden = rows
        func hide() { hidden += self.hide(drag.moving) }
        landings += 1
        layoutOverlays()
        func show() {
            for row in hidden { row.alpha = 1 }
            self.landings -= 1
            self.layoutOverlays()
        }
        hide()
        Task { [weak self] in
            // A move shows once the list has laid the rows out in their new order.
            for _ in 0..<30 {
                guard let self, moved, self.rowFrame(first) == before else { break }
                try? await Task.sleep(for: .milliseconds(16))
                hide()
            }
            guard let self, let list = self.list, let container = list.superview else {
                preview.removeFromSuperview()
                show()
                return
            }
            list.layoutIfNeeded()
            hide()
            let targets = pieces.map { piece in
                self.contentFrame(piece.block).map { list.convert($0.insetBy(dx: -6, dy: 0), to: container) }
            }
            // The preview comes to rest unscaled at the first piece's row; every piece
            // goes to its own row from there.
            guard let anchor = zip(pieces, targets).first(where: { $0.1 != nil }) else {
                preview.removeFromSuperview()
                show()
                return
            }
            let origin = CGPoint(x: anchor.1!.minX - anchor.0.slot.minX, y: anchor.1!.minY - anchor.0.slot.minY)
            let duration = 0.36
            card.clipsToBounds = false
            Self.animate(preview.layer, "shadowOpacity", to: 0, duration: duration)
            Self.animate(card.layer, "borderColor", to: UIColor.clear.cgColor, duration: duration)
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                preview.transform = .identity
                preview.center = CGPoint(x: origin.x + preview.bounds.width / 2, y: origin.y + preview.bounds.height / 2)
                preview.alpha = 1
                card.backgroundColor = .clear
                for (piece, target) in zip(pieces, targets) {
                    if let target {
                        piece.view.frame = target.offsetBy(dx: -origin.x, dy: -origin.y)
                    } else {
                        piece.view.alpha = 0
                    }
                }
                for view in preview.subviews where view !== card { view.alpha = 0 }
            } completion: { _ in
                preview.removeFromSuperview()
                show()
            }
            self.followHover()
        }
    }

    private static func animate(_ layer: CALayer, _ keyPath: String, to value: Any, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.setValue(value, forKeyPath: keyPath)
        layer.add(animation, forKey: keyPath)
    }

    /// Near the top or bottom edge the list scrolls, faster the closer the pointer is.
    @objc private func autoscroll(_ link: CADisplayLink) {
        guard let drag, drag.isMoving, let list else { return }
        let y = list.convert(drag.point, from: list.superview).y
        let visible = DocScrolling.visible(in: list)
        let edge: CGFloat = 56
        let speed: CGFloat = if y < visible.minY + edge {
            -min(1, (visible.minY + edge - y) / edge) * 14
        } else if y > visible.maxY - edge {
            min(1, (y - (visible.maxY - edge)) / edge) * 14
        } else { 0 }
        guard speed != 0 else { return }
        let top = -list.adjustedContentInset.top
        let bottom = max(top, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height)
        let offset = min(max(list.contentOffset.y + speed, top), bottom)
        guard abs(offset - list.contentOffset.y) > 0.1 else { return }
        list.contentOffset.y = offset
        updateTarget()
    }

    /// The moving blocks' rows on one card, one under the other; at most `maxHeight`
    /// of it shows (around the grabbed block), with the count when some is cut off.
    /// Each piece's view starts where its row is, for the lift to bring it in.
    private func makePreview(of moving: [DocBlockID], grabbed: DocBlockID) -> (UIView, UIView, [Piece])? {
        guard let list, let container = list.superview else { return nil }
        let maxHeight: CGFloat = 360
        var pieces: [Piece] = []
        var rows: [CGRect] = []
        var y: CGFloat = 0
        guard let shot = snapshot() else { return nil }
        for id in moving {
            // Rows off screen have nothing to show; they move all the same.
            guard let frame = contentFrame(id)?.insetBy(dx: -6, dy: 0), frame.intersects(list.bounds) else { continue }
            let pixels = frame.offsetBy(dx: -shot.bounds.minX, dy: -shot.bounds.minY)
                .applying(CGAffineTransform(scaleX: shot.scale, y: shot.scale)).integral
            guard let image = shot.image.cropping(to: pixels) else { continue }
            let view = UIImageView(image: UIImage(cgImage: image, scale: shot.scale, orientation: .up))
            view.contentMode = .top
            view.clipsToBounds = true
            pieces.append(Piece(block: id, view: view, slot: CGRect(x: 0, y: y, width: frame.width, height: frame.height)))
            rows.append(frame)
            y += frame.height
        }
        guard let grabbedIndex = pieces.firstIndex(where: { $0.block == grabbed }) else { return nil }
        // A long selection shows the part with the grabbed block in it.
        let grabbedSlot = pieces[grabbedIndex].slot
        let shift = max(0, grabbedSlot.maxY - maxHeight)
        for index in pieces.indices { pieces[index].slot.origin.y -= shift }
        let size = CGSize(width: pieces.map(\.slot.width).max() ?? 0, height: min(y, maxHeight))
        // The grabbed block's piece sits over its row.
        let grabbedRow = rows[grabbedIndex]
        let origin = CGPoint(x: grabbedRow.minX, y: grabbedRow.minY - pieces[grabbedIndex].slot.minY)
        let preview = UIView(frame: list.convert(CGRect(origin: origin, size: size), to: container))
        preview.isUserInteractionEnabled = false
        let card = UIView(frame: preview.bounds)
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 8
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
        card.clipsToBounds = true
        preview.addSubview(card)
        for (piece, row) in zip(pieces, rows) {
            piece.view.frame = row.offsetBy(dx: -origin.x, dy: -origin.y)
            card.addSubview(piece.view)
        }
        preview.layer.shadowColor = UIColor.black.cgColor
        preview.layer.shadowOpacity = 0.16
        preview.layer.shadowRadius = 12
        preview.layer.shadowOffset = CGSize(width: 0, height: 6)
        if y > maxHeight {
            let badge = UILabel(frame: CGRect(x: 6, y: 6, width: 24, height: 20))
            badge.text = "\(groups(moving).count)"
            badge.font = .systemFont(ofSize: 12, weight: .semibold)
            badge.textColor = .white
            badge.textAlignment = .center
            badge.backgroundColor = .tintColor
            badge.layer.cornerRadius = 10
            badge.clipsToBounds = true
            preview.addSubview(badge)
        }
        return (preview, card, pieces)
    }

    /// What the list shows now, as an image to cut the rows out of: a preview's pieces
    /// are the rows themselves, so they land on them without a seam.
    private func snapshot() -> (image: CGImage, bounds: CGRect, scale: CGFloat)? {
        guard let list, list.bounds.width > 0, list.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: list.bounds.size)
        // After updates: a selection made just now is in the picture.
        let image = renderer.image { _ in
            list.drawHierarchy(in: CGRect(origin: .zero, size: list.bounds.size), afterScreenUpdates: true)
        }
        return image.cgImage.map { ($0, list.bounds, image.scale) }
    }

    // MARK: Model

    /// Each block with the items nested under it (a list item's deeper items), in
    /// document order; a block nested under another one given is part of that one.
    func groups(_ tops: [DocBlockID]) -> [[DocBlockID]] {
        let chosen = Set(tops)
        let blocks = demo.doc.blocks
        var result: [[DocBlockID]] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            index += 1
            guard chosen.contains(block.id) else { continue }
            var group = [block.id]
            if case .listItem = block.kind {
                while index < blocks.count, blocks[index].indent > block.indent {
                    group.append(blocks[index].id)
                    index += 1
                }
            }
            result.append(group)
        }
        return result
    }

    /// The selection's outermost blocks (those not nested in another selected one).
    private func topsOfSelection() -> [DocBlockID] {
        groups(selected).map { $0[0] }
    }

    /// Moves blocks (with their nested items) to follow `after` (nil: the top), as one
    /// transaction. A block can't land nested deeper than where it goes allows: it and
    /// its items come out by as many levels as needed.
    @discardableResult
    func move(_ tops: [DocBlockID], after: DocBlockID?) -> Bool {
        let groups = groups(tops)
        let moving = groups.flatMap { $0 }
        guard !moving.isEmpty, after.map({ !moving.contains($0) }) ?? true else { return false }
        var steps: [DocStep] = []
        var previous = after
        for id in moving {
            steps.append(.moveBlock(block: id, after: previous, from: nil))
            previous = id
        }
        var before = after.flatMap { demo.doc.block($0) }.map { (kind: $0.kind, indent: $0.indent) }
        for group in groups {
            guard let top = demo.doc.block(group[0]) else { continue }
            let limit = before.map { if case .listItem = $0.kind { $0.indent + 1 } else { $0.indent } } ?? 0
            let shift = min(0, limit - top.indent)
            for id in group {
                guard let block = demo.doc.block(id) else { continue }
                let indent = max(0, block.indent + shift)
                if indent != block.indent {
                    steps.append(.setBlock(block: id, kind: block.kind, indent: indent, previousKind: block.kind, previousIndent: block.indent))
                }
                before = (block.kind, indent)
            }
        }
        return demo.edit(steps, before: editor.selection, after: editor.selection) != nil
    }

    /// Deletes the selected blocks (a table's database with it). The cursor goes to
    /// the end of the text before them.
    func deleteSelection() {
        let ids = Set(selected)
        let blocks = demo.doc.blocks
        guard !ids.isEmpty else { return }
        var steps: [DocStep] = []
        for block in blocks.reversed() where ids.contains(block.id) {
            steps.append(.deleteBlock(block: block, after: nil))
            if let database = block.kind.databaseID.flatMap({ demo.doc.databases[$0] }) {
                steps.append(.deleteDatabase(database: database))
            }
        }
        // A document keeps one line to type in.
        let remaining = blocks.filter { !ids.contains($0.id) }
        var caret: DocPosition?
        if remaining.isEmpty {
            let line = DocBlock(id: demo.newBlockID(), kind: .paragraph)
            steps.append(.insertBlock(block: line, after: nil))
            caret = DocPosition(block: line.id, offset: 0)
        } else if let first = blocks.firstIndex(where: { ids.contains($0.id) }),
            let previous = blocks[..<first].last(where: { $0.kind.carriesText }) {
            caret = DocPosition(block: previous.id, offset: previous.text.length)
        }
        let after = caret.map { DocSelection(anchor: $0, head: $0) }
        let wasSelecting = isSelecting
        clear()
        guard demo.edit(steps, before: editor.selection, after: after) != nil else { return }
        if let after, !wasSelecting { editor.place(after) }
    }

    /// The selected blocks as markdown, on the pasteboard.
    func copySelection() {
        let ids = Set(selected)
        let blocks = demo.doc.blocks.filter { ids.contains($0.id) }
        guard !blocks.isEmpty else { return }
        UIPasteboard.general.string = Doc(id: demo.doc.id, blocks: blocks, databases: demo.doc.databases).markdown
    }

    // MARK: Tests

    /// A drag as the handle or a long press would do it, for the edit tests: picks the
    /// block up, moves to `y` (list coordinates), drops.
    func testDrag(_ id: DocBlockID, toY y: CGFloat) {
        guard let list, let frame = rowFrame(id) else { return }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        lift(id, at: start)
        startMoving()
        moveDrag(to: list.convert(CGPoint(x: start.x, y: y), to: list.superview))
        drop()
    }

    var testRowFrame: (DocBlockID) -> CGRect? { { [weak self] in self?.rowFrame($0) } }
    var testHighlightFrames: [CGRect] { highlights.filter { !$0.isHidden }.map(\.frame) }
    var testHandleFrame: CGRect? { Self.usesHandles && !handle.isHidden ? handle.frame : nil }

    func testHover(_ id: DocBlockID) {
        guard let list, let frame = rowFrame(id) else { return }
        hoverPoint = list.convert(CGPoint(x: frame.midX, y: frame.midY), to: list.superview)
        followHover()
    }

    /// The key window as a PNG at `path`, for screenshots without screen recording.
    static func drawWindow(to path: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: path))
    }
}

/// The six dots beside a block (Craft's): darker, on a soft background, under the pointer.
final class DocBlockHandleView: UIView {
    static let size = CGSize(width: 18, height: 24)
    private let dots = CAShapeLayer()
    private var isHovered = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        layer.addSublayer(dots)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        addInteraction(UIToolTipInteraction(defaultToolTip: "点击选中，拖动移动"))
        isAccessibilityElement = true
        accessibilityLabel = "块把手"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Two columns of three dots, centred.
    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter: CGFloat = 3, pitch: CGFloat = 5
        let origin = CGPoint(x: bounds.midX - (pitch + diameter) / 2, y: bounds.midY - (2 * pitch + diameter) / 2)
        let path = UIBezierPath()
        for column in 0..<2 {
            for row in 0..<3 {
                path.append(UIBezierPath(ovalIn: CGRect(x: origin.x + CGFloat(column) * pitch, y: origin.y + CGFloat(row) * pitch,
                                                        width: diameter, height: diameter)))
            }
        }
        dots.frame = bounds
        dots.path = path.cgPath
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        backgroundColor = isHovered ? .quaternarySystemFill : .clear
        dots.fillColor = (isHovered ? UIColor.secondaryLabel : .tertiaryLabel).resolvedColor(with: traitCollection).cgColor
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        isHovered = recognizer.state == .began || recognizer.state == .changed
        updateColors()
    }
}

/// Takes the keys while blocks are selected on the Mac: Delete, Esc, ↑ ↓ (⇧ extends),
/// Return to edit, ⌘C ⌘X; ⌘Z stays the document's.
final class DocBlockKeyView: UIView {
    weak var controller: DocBlockController?

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        alpha = 0.01
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { controller?.keysResigned() }
        return resigned
    }

    override var undoManager: UndoManager? { controller?.editor.undoManager }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(deleteBlocks)),
            UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(deleteBlocks)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(edit)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .shift, action: #selector(extendUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: .shift, action: #selector(extendDown)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) || action == #selector(cut(_:)) || action == #selector(delete(_:)) {
            return !(controller?.selected.isEmpty ?? true)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) { controller?.copySelection() }

    override func cut(_ sender: Any?) {
        controller?.copySelection()
        controller?.deleteSelection()
    }

    override func delete(_ sender: Any?) { controller?.deleteSelection() }

    @objc private func deleteBlocks() { controller?.deleteSelection() }
    @objc private func escape() { controller?.clear() }
    @objc private func edit() { controller?.editSelection() }
    @objc private func up() { controller?.step(-1, extending: false) }
    @objc private func down() { controller?.step(1, extending: false) }
    @objc private func extendUp() { controller?.step(-1, extending: true) }
    @objc private func extendDown() { controller?.step(1, extending: true) }
}

/// The phone's bar while blocks are selected (Composer's batch editing).
struct DocBlockSelectionBar: View {
    let blocks: DocBlockController

    var body: some View {
        VStack {
            if blocks.isSelecting { bar }
        }
        .animation(.smooth(duration: 0.25), value: blocks.isSelecting)
    }

    private var bar: some View {
        HStack(spacing: 16) {
            Text("已选 \(blocks.selected.count) 块")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("复制", systemImage: "doc.on.doc") {
                blocks.copySelection()
                blocks.endSelecting()
            }
            Button("删除", systemImage: "trash", role: .destructive) { blocks.deleteSelection() }
            Button("完成") { blocks.endSelecting() }
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
