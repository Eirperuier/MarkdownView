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
import QuickLook
import DocKit
import MessagingUI

@MainActor
@Observable
final class DocBlockController: NSObject, UIGestureRecognizerDelegate, QLPreviewControllerDataSource {
    #if targetEnvironment(macCatalyst)
    nonisolated static let usesHandles = true
    #else
    nonisolated static let usesHandles = false
    #endif
    /// The page's side margins: on the Mac room for the handle on the left, on a phone
    /// for the selection's circles on the right (Craft's).
    nonisolated static let leadingGutter: CGFloat = usesHandles ? 40 : 20
    nonisolated static let trailingGutter: CGFloat = usesHandles ? 40 : 34

    @ObservationIgnored private let demo: DocDemo
    @ObservationIgnored unowned let editor: DocEditor
    /// The selected blocks, in document order (a list item's nested items included).
    private(set) var selected: [DocBlockID] = []
    /// The phone's selection mode (Composer's batch editing): taps select, the text
    /// isn't edited, a bar offers what to do with the blocks.
    private(set) var isSelecting = false
    /// The panel shows the selected media's layouts instead of the actions.
    var isChoosingLayout = false

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
    /// The phone's selection mode: a circle beside every block, filled when it's selected.
    @ObservationIgnored private var checks: [DocBlockCheck] = []
    /// The circles fading out after the mode ended: laid out until they're gone.
    @ObservationIgnored private var checksLeaving = false
    @ObservationIgnored private var dimmers: [UIView] = []
    /// The block under the pointer (its handle is shown), and where the pointer is in
    /// the list's frame, to find it again after a scroll.
    @ObservationIgnored private(set) var hovered: DocBlockID?
    @ObservationIgnored private var hoverPoint: CGPoint?
    @ObservationIgnored private var press: (block: DocBlockID, start: CGPoint)?
    @ObservationIgnored private var drag: Drag?
    @ObservationIgnored private var link: CADisplayLink?
    /// A click on a row outside its text (DocEditor.click), and the phone's tap that
    /// picks blocks while selecting.
    @ObservationIgnored private var rowClick: UITapGestureRecognizer?
    @ObservationIgnored private var selectTap: UITapGestureRecognizer?
    /// A double click on a link, image or file opens it (a single one selects it).
    @ObservationIgnored private var mediaOpen: UITapGestureRecognizer?
    /// Where a link opens (the browser; the edit tests catch it).
    @ObservationIgnored var opensURL: (URL) -> Void = { UIApplication.shared.open($0) }
    /// The image Quick Look shows.
    @ObservationIgnored private var previewing: URL?
    /// Pieces flying to their rows: the selection shows once they're down.
    @ObservationIgnored private var landings = 0
    /// Members of a row of several whose pieces are landing: hidden until they're down.
    private(set) var hiddenMembers: Set<DocBlockID> = []

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
            selectTap = tap
        }
        // On the list, not in the rows: SwiftUI's hit testing doesn't always pass a click
        // through a row's content to a view behind it.
        let click = UITapGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        click.delegate = self
        list.addGestureRecognizer(click)
        rowClick = click
        // It only takes touches on links and images, so elsewhere nothing waits for it.
        // A click doesn't wait for it either: the first click selects at once (the
        // system's double-click time would hold every click back), the second opens.
        // The phone's selecting tap waits, or a double tap would toggle twice.
        let open = UITapGestureRecognizer(target: self, action: #selector(mediaDoubleClicked(_:)))
        open.numberOfTapsRequired = 2
        open.delegate = self
        list.addGestureRecognizer(open)
        mediaOpen = open
        selectTap?.require(toFail: open)
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

    /// The row a block is in (its own, or the row it shares with others).
    private func rowFrame(_ id: DocBlockID) -> CGRect? {
        reader?.frame(forItem: demo.places[id]?.row ?? id.description)
    }

    /// The page's part of a block's row: less the page's margins (at most 720 wide,
    /// centred) and the space above and below it.
    private func pageFrame(_ id: DocBlockID) -> CGRect? {
        let rowID = demo.places[id]?.row ?? id.description
        guard let row = reader?.frame(forItem: rowID) else { return nil }
        let room = max(0, row.width - Self.leadingGutter - Self.trailingGutter)
        let width = min(720, room)
        let above = demo.spacingAbove[rowID] ?? 0
        let below = demo.rows.last?.id == rowID ? DocTypography.pageBottom : 0
        return CGRect(x: row.minX + Self.leadingGutter + (room - width) / 2, y: row.minY + above, width: width, height: max(0, row.height - above - below))
    }

    /// The block itself: its row's page part, or its place among the row's members.
    private func contentFrame(_ id: DocBlockID) -> CGRect? {
        guard let page = pageFrame(id) else { return nil }
        guard let place = demo.places[id], let row = demo.rows.first(where: { $0.id == place.row }) else {
            // A link, file or image alone: its own box, at the page's left.
            guard let kind = demo.doc.block(id)?.kind, DocMediaView.draws(kind), let box = DocMediaLayout.boxSize(kind, width: page.width) else { return page }
            return CGRect(x: page.minX, y: page.minY, width: min(box.width, page.width), height: page.height)
        }
        let frames = DocMediaLayout.memberFrames(row.members.map(\.kind), width: page.width)
        guard frames.indices.contains(place.index) else { return page }
        return frames[place.index].offsetBy(dx: page.minX, dy: page.minY)
    }

    /// The committed block at a point (list coordinates): the row's block, or in a row
    /// of several, the member under the point (or nearest it).
    private func block(at point: CGPoint) -> DocBlockID? {
        guard let list, let reader else { return nil }
        let hits = reader.contentFrames(intersecting: CGRect(x: 0, y: point.y, width: list.bounds.width, height: 1))
        guard let id = hits.first(where: { $0.value.minY <= point.y && point.y < $0.value.maxY })?.key ?? hits.first?.key,
            let row = demo.rows.first(where: { $0.id == id })
        else { return nil }
        guard !row.members.isEmpty else { return row.block }
        let frames = row.members.compactMap { member in contentFrame(member.id).map { (member.id, $0) } }
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        return frames.min { distance($0.1) < distance($1.1) }?.0 ?? row.block
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
        // Craft's: a light tint with a tinted outline, a little outside the blocks.
        // Links, files and images outline themselves, hugging their box (DocMediaView).
        let text = selected.filter { demo.doc.block($0).map { !DocMediaView.draws($0.kind) } ?? false }
        highlights = place(landings > 0 ? [] : runs(of: text).map { $0.insetBy(dx: 0, dy: -4) }, in: highlights, outset: 6) {
            let view = UIView()
            view.backgroundColor = UIColor.tintColor.withAlphaComponent(0.08)
            view.layer.borderColor = UIColor.tintColor.withAlphaComponent(0.45).cgColor
            view.layer.borderWidth = 1
            view.layer.cornerRadius = 10
            view.layer.cornerCurve = .continuous
            view.layer.zPosition = 5
            return view
        }
        layoutChecks()
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

    /// A circle at the right edge of every block, level with its middle, while selecting.
    private func layoutChecks() {
        guard let list else { return }
        // Links, files and images draw theirs inside their box (DocMediaView).
        let ids = isSelecting || checksLeaving ? demo.doc.blocks.filter { !DocMediaView.draws($0.kind) }.map(\.id) : []
        let chosen = Set(selected)
        let frames = reader?.contentFrames(forItems: ids.map(\.description)) ?? [:]
        while checks.count < ids.count {
            let check = DocBlockCheck()
            check.layer.zPosition = 9
            list.addSubview(check)
            checks.append(check)
        }
        for (index, check) in checks.enumerated() {
            guard index < ids.count, let row = frames[ids[index].description], let content = contentFrame(ids[index]) else {
                check.isHidden = true
                continue
            }
            let size = DocBlockCheck.size
            check.frame = CGRect(x: row.maxX - 10 - size, y: content.midY - size / 2, width: size, height: size)
            check.isOn = chosen.contains(ids[index])
            check.isHidden = false
        }
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
                view.frame = rects[index].insetBy(dx: -outset, dy: 0)
                view.isHidden = false
            } else {
                view.isHidden = true
            }
        }
        return views
    }

    private func layoutHandle() {
        guard Self.usesHandles else { return }
        guard drag == nil, !demo.isAgentWriting, let hovered, let content = contentFrame(hovered) else {
            handle.isHidden = true
            return
        }
        let size = DocBlockHandleView.size
        // One column for every block, nested or not: the handles line up.
        let left = pageFrame(hovered)?.minX ?? content.minX
        handle.frame = CGRect(x: left - size.width - 6, y: firstLineMidY(hovered, row: content) - size.height / 2,
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
        let next = hoverPoint.flatMap { block(at: list.convert($0, from: list.superview)) }
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
        if recognizer === selectTap { return isSelecting }
        if recognizer === mediaOpen {
            guard drag == nil, let list, let id = block(at: touch.location(in: list)) else { return false }
            return opens(id)
        }
        if recognizer === rowClick {
            guard !isSelecting, drag == nil else { return false }
            return rowClickTakes(touch.view)
        }
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

    /// Whether a click on this view is the row's. Text views and controls take their
    /// own clicks; the handle takes its own too: the row's would put the caret in the
    /// block's text, and the text taking the focus clears the selection the handle
    /// just made (it happens with it, as a table cell's own tap does).
    private func rowClickTakes(_ view: UIView?) -> Bool {
        !sequence(first: view, next: { $0?.superview }).contains { $0 is UITextView || $0 is UIControl || $0 === handle }
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard let list else { return }
        let point = recognizer.location(in: list)
        switch recognizer.state {
        case .began:
            guard let id = block(at: point) else { return }
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

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // A table cell's own tap and the row's click both happen.
        recognizer === rowClick
    }

    @objc private func rowClicked(_ recognizer: UITapGestureRecognizer) {
        guard let list else { return }
        click(atWindowPoint: list.convert(recognizer.location(in: list), to: nil))
    }

    /// A click at a point of the window outside any text: the block whose row it is in
    /// takes it. A link, file or image is selected by it (and opened by a second).
    func click(atWindowPoint point: CGPoint) {
        guard let list, let id = block(at: list.convert(point, from: nil)) else { return }
        guard let kind = demo.doc.block(id)?.kind, DocMediaView.draws(kind) else { return editor.click(id, at: point) }
        if Self.usesHandles {
            click(id)
        } else if !isSelecting {
            beginSelecting(id)
        }
    }

    @objc private func mediaDoubleClicked(_ recognizer: UITapGestureRecognizer) {
        guard let list, let id = block(at: recognizer.location(in: list)) else { return }
        open(id)
    }

    /// Whether a double click opens this block: a link, an image, a file that has
    /// somewhere to open from.
    private func opens(_ id: DocBlockID) -> Bool {
        switch demo.doc.block(id)?.kind {
        case .link?, .image?: true
        case .file(let file)?: URL(string: file.source).map { $0.isFileURL || $0.scheme?.hasPrefix("http") == true } ?? false
        default: false
        }
    }

    /// A link in the browser; an image in Quick Look; a file in either.
    func open(_ id: DocBlockID) {
        switch demo.doc.block(id)?.kind {
        case .link(let link)?:
            if let url = URL(string: link.url) { opensURL(url) }
        case .image(let image)?:
            if let picture = DocMediaLayout.asset(image.source), let data = picture.jpegData(compressionQuality: 0.95) {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent((image.alt.isEmpty ? String(localized: "Image") : image.alt) + ".jpg")
                guard (try? data.write(to: file)) != nil else { return }
                quickLook(file)
            } else if let url = URL(string: image.source), url.scheme?.hasPrefix("http") == true {
                opensURL(url)
            }
        case .file(let file)?:
            // A file on the web opens in the browser, one on disk in Quick Look. A blob
            // has nowhere to come from yet: attachments aren't stored (Docs/doc.md §3.4.1).
            guard let url = URL(string: file.source) else { return }
            if url.isFileURL { quickLook(url) } else if url.scheme?.hasPrefix("http") == true { opensURL(url) }
        default:
            break
        }
    }

    private func quickLook(_ file: URL) {
        previewing = file
        let preview = QLPreviewController()
        preview.dataSource = self
        list?.window?.rootViewController.map { root in
            var top = root
            while let presented = top.presentedViewController { top = presented }
            top.present(preview, animated: true)
        }
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (previewing ?? URL(fileURLWithPath: "/")) as NSURL }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard isSelecting, let list, let id = block(at: recognizer.location(in: list)) else { return }
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
        fadeChecks(in: true)
    }

    func endSelecting() {
        isSelecting = false
        isChoosingLayout = false
        editor.panels.sheetPage = nil
        editor.isEditable = !demo.isAgentWriting
        anchor = nil
        head = nil
        fadeChecks(in: false)
        setSelection([])
    }

    /// The circles come and go with the mode, faded.
    private func fadeChecks(in showing: Bool) {
        if showing { checks.forEach { $0.alpha = 0 } } else { checksLeaving = true }
        UIView.animate(FlooDesignTokens.Motion.feedbackCurve) { [checks] in
            checks.forEach { $0.alpha = showing ? 1 : 0 }
        } completion: { [weak self] in
            guard let self, !showing, !self.isSelecting else { return }
            self.checksLeaving = false
            self.layoutChecks()
            self.checks.forEach { $0.alpha = 1 }
        }
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
        UIView.animate(.spring(FlooDesignTokens.Motion.layoutSpring)) {
            for piece in pieces { piece.view.frame = piece.slot }
            if !Self.usesHandles { preview.transform = CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 1.03, y: 1.03) }
        } completion: {
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
        UIView.animate(FlooDesignTokens.Motion.feedbackCurve) {
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
        let point = list.convert(drag.point, from: list.superview)
        let gap = memberGap(at: point, moving: drag.moving) ?? gap(atY: point.y).map { ($0, nil as CGRect?) }
        let target = gap.flatMap { destination(gap: $0.index, moving: drag.moving) }
        if !Self.usesHandles, target != drag.target, drag.target != nil { UISelectionFeedbackGenerator().selectionChanged() }
        drag.target = target
        self.drag = drag
        guard let gap, target != nil else {
            indicator.isHidden = true
            return
        }
        if let line = gap.line {
            indicator.frame = line
        } else if let lineY = lineY(gap: gap.index), let content = contentFrame(drag.tops[0]) {
            indicator.frame = CGRect(x: content.minX - 6, y: lineY - 1, width: content.width + 12, height: 2)
        } else {
            indicator.isHidden = true
            return
        }
        indicator.isHidden = false
    }

    /// Over a row of cards or a gallery that the moving blocks would join, the gap
    /// between two of its members nearest the point, shown by an upright line between
    /// them (Craft's). Nil elsewhere, or for blocks that wouldn't join it.
    private func memberGap(at point: CGPoint, moving: [DocBlockID]) -> (index: Int, line: CGRect?)? {
        guard let reader,
            let hit = reader.contentFrames(intersecting: CGRect(x: 0, y: point.y, width: 1, height: 1).insetBy(dx: -10_000, dy: 0)).first,
            hit.value.minY <= point.y, point.y < hit.value.maxY,
            let row = demo.rows.first(where: { $0.id == hit.key }), let first = row.members.first,
            let run = DocMediaLayout.run(first.kind),
            moving.allSatisfy({ id in demo.doc.block(id).map { DocMediaLayout.run($0.kind) == run } ?? false })
        else { return nil }
        let frames = row.members.compactMap { member in contentFrame(member.id).map { (member.id, $0) } }
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        guard let (id, frame) = frames.min(by: { distance($0.1) < distance($1.1) }),
            let index = demo.doc.blocks.firstIndex(where: { $0.id == id })
        else { return nil }
        let isAfter = point.x > frame.midX
        let x = (isAfter ? frame.maxX : frame.minX) + (isAfter ? 1 : -1) * DocMediaLayout.gap / 2
        return (isAfter ? index + 1 : index, CGRect(x: x - 1, y: frame.minY, width: 2, height: frame.height))
    }

    /// The gap between blocks (an index into the document's blocks) nearest `y`.
    private func gap(atY y: CGFloat) -> Int? {
        guard let list, let reader else { return nil }
        // Rows by their first block's place in the document (a row of several has an id
        // of its own).
        let places = Dictionary(uniqueKeysWithValues: demo.doc.blocks.enumerated().map { ($1.id, $0) })
        let index = Dictionary(demo.rows.compactMap { row in row.block.flatMap { places[$0] }.map { (row.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let spans = Dictionary(demo.rows.filter { !$0.members.isEmpty }.map { ($0.id, $0.members.count) }, uniquingKeysWith: { a, _ in a })
        // A row of several is one gap before it and one after its last member.
        let frames = reader.contentFrames(intersecting: list.bounds.insetBy(dx: 0, dy: -400))
            .compactMap { id, frame in index[id].map { (first: $0, end: $0 + (spans[id] ?? 1), frame: frame) } }
            .sorted { $0.first < $1.first }
        guard let first = frames.first, let last = frames.last else { return nil }
        if y < first.frame.minY { return first.first }
        for row in frames where y < row.frame.maxY {
            return y < row.frame.midY ? row.first : row.end
        }
        return last.end
    }

    /// The drop line: halfway through the space above the block after the gap, or under
    /// the last block.
    private func lineY(gap: Int) -> CGFloat? {
        let blocks = demo.doc.blocks
        if blocks.indices.contains(gap), let frame = rowFrame(blocks[gap].id) {
            let row = demo.places[blocks[gap].id]?.row ?? blocks[gap].id.description
            return frame.minY + (demo.spacingAbove[row] ?? 0) / 2
        }
        if blocks.indices.contains(gap - 1), let frame = contentFrame(blocks[gap - 1].id) { return frame.maxY + 6 }
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
    /// In a row of several only the member goes (`hiddenMembers`), not its neighbours.
    private func hide(_ ids: [DocBlockID]) -> [UIView] {
        let members = ids.filter { demo.places[$0] != nil }
        hiddenMembers.formUnion(members)
        let rows = cells(of: ids.filter { demo.places[$0] == nil }).flatMap(\.contentView.subviews).filter { $0.alpha != 0 }
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
        let version = reader?.version
        // The moving rows stay hidden until their pieces land on them (the list slides
        // the other rows into place meanwhile).
        var hidden = rows
        func hide() { hidden += self.hide(drag.moving) }
        landings += 1
        layoutOverlays()
        func show() {
            for row in hidden { row.alpha = 1 }
            self.hiddenMembers.subtract(drag.moving)
            self.landings -= 1
            self.layoutOverlays()
        }
        hide()
        Task { [weak self] in
            // A move shows once the list has laid the rows out in their new order (a row
            // of several reordered in place stays where it is: the list's update says so).
            for _ in 0..<30 {
                guard let self, moved, self.rowFrame(first) == before, self.reader?.version == version else { break }
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
            card.clipsToBounds = false
            Self.animate(preview.layer, "shadowOpacity", to: 0)
            Self.animate(card.layer, "borderColor", to: UIColor.clear.cgColor)
            UIView.animate(.spring(FlooDesignTokens.Motion.layoutSpring)) {
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
            } completion: {
                preview.removeFromSuperview()
                show()
            }
            self.followHover()
        }
    }

    /// A layer's own property (UIKit's animations don't reach it) with the layout spring.
    private static func animate(_ layer: CALayer, _ keyPath: String, to value: Any) {
        let spring = FlooDesignTokens.Motion.layoutSpring
        let animation = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
        animation.keyPath = keyPath
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = animation.settlingDuration
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
    /// are the rows themselves, so they land on them without a seam. After pending screen
    /// updates: a selection made just now is in the picture.
    private func snapshot() -> (image: CGImage, bounds: CGRect, scale: CGFloat)? {
        guard let list, list.bounds.width > 0, list.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: list.bounds.size)
        let image = renderer.image { _ in
            list.drawHierarchy(in: CGRect(origin: .zero, size: list.bounds.size), afterScreenUpdates: true)
        }
        return image.cgImage.map { ($0, list.bounds, image.scale) }
    }

    // MARK: Reshaping

    /// Makes a change that reshapes blocks (a layout, an image's size, a kind): each block
    /// changes to its new shape and the rows around it go to their new places together,
    /// with the layout motion (the rows are TiledView's to move, a block's content its own).
    func reshape(_ change: () -> Void) {
        withAnimation(FlooDesignTokens.Motion.layout) { change() }
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

    // MARK: Media

    /// What the selected links, files and images are set to (several values: mixed).
    var selectedLayouts: Set<DocLayout> { Set(media(selected).compactMap(\.layout)) }
    var selectedImageFits: Set<DocImage.Fit> { Set(media(selected).compactMap(\.image?.fit)) }
    var selectedImageSizes: Set<DocImage.Size> { Set(media(selected).compactMap(\.image?.size)) }

    private func media(_ ids: [DocBlockID]) -> [(layout: DocLayout?, image: DocImage?)] {
        let chosen = Set(ids)
        return demo.doc.blocks.filter { chosen.contains($0.id) }.compactMap { block in
            switch block.kind {
            case .link(let link): (link.layout, nil)
            case .file(let file): (file.layout, nil)
            case .image(let image): (nil, image)
            default: nil
            }
        }
    }

    /// Links and files among these blocks (the selection by default) take `layout`,
    /// in one transaction.
    func setLayout(_ layout: DocLayout, of ids: [DocBlockID]? = nil) {
        reshape { change(ids ?? selected) { kind in
            switch kind {
            case .link(var link): link.layout = layout; return .link(link: link)
            case .file(var file): file.layout = layout; return .file(file: file)
            default: return nil
            }
        } }
    }

    func setImage(fit: DocImage.Fit? = nil, size: DocImage.Size? = nil, of ids: [DocBlockID]? = nil) {
        reshape { change(ids ?? selected) { kind in
            guard case .image(var image) = kind else { return nil }
            image.fit = fit ?? image.fit
            image.size = size ?? image.size
            return .image(image: image)
        } }
    }

    private func change(_ ids: [DocBlockID], _ transform: (BlockKind) -> BlockKind?) {
        let chosen = Set(ids)
        let steps: [DocStep] = demo.doc.blocks.filter { chosen.contains($0.id) }.compactMap { block in
            guard let kind = transform(block.kind), kind != block.kind else { return nil }
            return .setBlock(block: block.id, kind: kind, indent: block.indent, previousKind: block.kind, previousIndent: block.indent)
        }
        guard !steps.isEmpty else { return }
        demo.edit(steps, before: editor.selection, after: editor.selection)
    }

    /// The selected blocks of text become `kind` (as the slash menu turns one), in one
    /// transaction; the rest stay as they are.
    func turnSelection(into kind: BlockKind) {
        reshape { editor.setKind(kind, of: selected) }
    }

    /// A copy of the selected blocks right after the last of them, in order; a table's
    /// copy gets a database of its own. The copies become the selection.
    func duplicateSelection() {
        let ids = Set(selected)
        let originals = demo.doc.blocks.filter { ids.contains($0.id) }
        guard let last = originals.last else { return }
        var steps: [DocStep] = []
        var copies: [DocBlockID] = []
        var after = last.id
        for original in originals {
            var copy = original
            copy.id = demo.newBlockID()
            if case .database(let id, let view) = original.kind, var database = demo.doc.databases[id] {
                database.id = demo.newID()
                steps.append(.createDatabase(database: database))
                copy.kind = .database(id: database.id, view: view)
            }
            steps.append(.insertBlock(block: copy, after: after))
            after = copy.id
            copies.append(copy.id)
        }
        guard demo.edit(steps, before: editor.selection, after: editor.selection) != nil else { return }
        setSelection(copies)
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
    func testDrag(_ id: DocBlockID, toY y: CGFloat, x: CGFloat? = nil) {
        guard let list, let frame = contentFrame(id) else { return }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        lift(id, at: start)
        startMoving()
        moveDrag(to: list.convert(CGPoint(x: x ?? start.x, y: y), to: list.superview))
        drop()
    }
    var testIndicatorFrame: CGRect? { indicator.isHidden ? nil : indicator.frame }

    func testContentFrame(_ id: DocBlockID) -> CGRect? { contentFrame(id) }

    /// A click at the middle of a block, as the list's click takes it.
    func testClick(_ id: DocBlockID) {
        guard let list, let frame = contentFrame(id) else { return }
        click(atWindowPoint: list.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil))
    }
    func testBlock(at point: CGPoint) -> DocBlockID? { block(at: point) }

    var testRowFrame: (DocBlockID) -> CGRect? { { [weak self] in self?.rowFrame($0) } }

    /// Scrolls a block's row to the middle of the list.
    func testCenter(_ id: DocBlockID) {
        reader?.scrollTo(id: demo.places[id]?.row ?? id.description, anchor: .center, animated: false)
    }

    /// Where a block's row shows right now, moving included (list coordinates).
    func testShownRowFrame(_ id: DocBlockID) -> CGRect? {
        guard let list, let frame = rowFrame(id) else { return nil }
        // Its place without its transform (a row on its way has one).
        let cell = list.visibleCells.first { abs($0.center.y - $0.bounds.height / 2 - frame.minY) < 0.5 && abs($0.bounds.height - frame.height) < 0.5 }
        // A row on its way shows its contents shifted (TiledView's row moves).
        return cell.map { cell in
            let shown = cell.layer.presentation() ?? cell.layer
            return shown.frame.offsetBy(dx: 0, dy: shown.sublayerTransform.m42)
        }
    }

    /// How far down a block's row draws its box right now, moving included (list
    /// coordinates): the bottom of the lowest layer in it that clips or has a border (a
    /// card's box, an image's frame), as SwiftUI lays them out frame by frame.
    func testShownBoxBottom(_ id: DocBlockID) -> CGFloat? {
        guard let list, let frame = rowFrame(id),
              let cell = list.visibleCells.first(where: { abs($0.center.y - $0.bounds.height / 2 - frame.minY) < 0.5 }) else { return nil }
        let root = cell.layer.presentation() ?? cell.layer
        var bottom: CGFloat?
        func visit(_ layer: CALayer, depth: Int) {
            let shown = layer.presentation() ?? layer
            if depth > 0, shown.masksToBounds || shown.borderWidth > 0, shown.bounds.width < cell.bounds.width - 1 {
                let box = shown.convert(shown.bounds, to: root)
                bottom = max(bottom ?? -.infinity, root.frame.minY + root.sublayerTransform.m42 + box.maxY)
            }
            for sublayer in layer.sublayers ?? [] { visit(sublayer, depth: depth + 1) }
        }
        visit(cell.layer, depth: 0)
        return bottom
    }
    var testHighlightFrames: [CGRect] { highlights.filter { !$0.isHidden }.map(\.frame) }
    var testHandleFrame: CGRect? { Self.usesHandles && !handle.isHidden ? handle.frame : nil }

    /// Whether the row's click takes a click on the handle (it mustn't).
    var testRowClickTakesHandle: Bool { rowClickTakes(handle) }

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
        addInteraction(UIToolTipInteraction(defaultToolTip: String(localized: "Click to select, drag to move")))
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Block handle")
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

/// The circle beside a block while selecting: a gray ring, or a tinted dot when the
/// block is selected (Craft's).
final class DocBlockCheck: UIView {
    static let size: CGFloat = 18
    private let ring = CAShapeLayer()

    var isOn = false {
        didSet { if isOn != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        if isOn {
            ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).cgPath
            ring.fillColor = tintColor.cgColor
            ring.strokeColor = nil
        } else {
            ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75)).cgPath
            ring.fillColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
            ring.strokeColor = UIColor.systemGray3.resolvedColor(with: traitCollection).cgColor
            ring.lineWidth = 1.5
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsLayout()
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

/// The phone's actions on the selected blocks, as Craft's panel: a floating glass
/// panel of tiles, each its own color, its symbol over its name. Layout turns it into
/// the layouts of the selected links, files and images.
struct DocBlockSelectionBar: View {
    let blocks: DocBlockController

    var body: some View {
        VStack {
            if blocks.isSelecting {
                let formatting = blocks.editor.panels.sheetPage != nil
                let radius = formatting ? FlooDesignTokens.Component.FormatSheet.cornerRadius : 26
                Group {
                    if blocks.isChoosingLayout {
                        layouts
                    } else if formatting {
                        DocFormatSheet(editor: blocks.editor) { blocks.editor.panels.sheetPage = nil }
                    } else {
                        actions
                    }
                }
                .padding(formatting ? 0 : 8)
                .background(.regularMaterial, in: .rect(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(FlooDesignTokens.Motion.layout, value: blocks.isSelecting)
        .animation(FlooDesignTokens.Motion.layout, value: blocks.isChoosingLayout)
        .animation(FlooDesignTokens.Motion.layout, value: blocks.editor.panels.sheetPage == nil)
    }

    private var hasMedia: Bool {
        !blocks.selectedLayouts.isEmpty || !blocks.selectedImageFits.isEmpty
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                blocks.editor.panels.sheetPage = .main
            } label: {
                DocSelectionTile(title: String(localized: "Style"), symbol: "textformat", color: Color(red: 0.42, green: 0.13, blue: 0.78))
            }
            .accessibilityIdentifier("selection-style")
            if hasMedia {
                Button {
                    blocks.isChoosingLayout = true
                } label: {
                    DocSelectionTile(title: String(localized: "Layout"), symbol: "rectangle.split.2x1", color: Color(red: 0.2, green: 0.27, blue: 0.36))
                }
            }
            Menu {
                Button("Copy", systemImage: "doc.on.doc") {
                    blocks.copySelection()
                    blocks.endSelecting()
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { blocks.duplicateSelection() }
            } label: {
                DocSelectionTile(title: String(localized: "Actions"), symbol: "square.and.arrow.up", color: Color(red: 0.2, green: 0.27, blue: 0.36))
            }
            Button {
                blocks.deleteSelection()
            } label: {
                DocSelectionTile(title: String(localized: "Delete"), symbol: "trash", color: Color(red: 0.82, green: 0.06, blue: 0.13))
            }
        }
        .buttonStyle(.plain)
    }

    /// Craft's layout sheet: a grabber (tap or pull down to go back), then the options.
    private var layouts: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 14)
                .contentShape(Rectangle())
                .onTapGesture { blocks.isChoosingLayout = false }
            if !blocks.selectedImageFits.isEmpty {
                HStack(spacing: 8) {
                    DocLayoutSection(title: String(localized: "Image Display")) {
                        option(String(localized: "Fit"), symbol: "arrow.down.and.line.horizontal.and.arrow.up", on: blocks.selectedImageFits == [.fit]) { blocks.setImage(fit: .fit) }
                        option(String(localized: "Fill"), symbol: "square.arrowtriangle.4.outward", on: blocks.selectedImageFits == [.fill]) { blocks.setImage(fit: .fill) }
                    }
                    DocLayoutSection(title: String(localized: "Image Size")) {
                        option(String(localized: "Auto"), symbol: "rectangle.center.inset.filled", on: blocks.selectedImageSizes == [.auto]) { blocks.setImage(size: .auto) }
                        option(String(localized: "Large"), symbol: "rectangle", on: blocks.selectedImageSizes == [.large]) { blocks.setImage(size: .large) }
                    }
                }
            }
            if !blocks.selectedLayouts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(DocLayout.allCases, id: \.self) { layout in
                        Button {
                            blocks.setLayout(layout)
                        } label: {
                            DocLayoutOption(title: layout.title, isOn: blocks.selectedLayouts == [layout]) {
                                DocLayoutIllustration(layout: layout)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .gesture(DragGesture(minimumDistance: 12).onEnded { if $0.translation.height > 30 { blocks.isChoosingLayout = false } })
    }

    private func option(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DocLayoutOption(title: title, isOn: on) {
                Image(systemName: symbol).font(.system(size: 18))
            }
        }
    }

}

extension DocLayout {
    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .regular: String(localized: "Regular")
        case .card: String(localized: "Card")
        }
    }
}

/// A titled group of options (the image's fit, its size).
private struct DocLayoutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) { content() }
        }
    }
}

/// One layout option: its picture over its name, outlined in the tint when chosen.
private struct DocLayoutOption<Picture: View>: View {
    let title: String
    let isOn: Bool
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        VStack(spacing: 6) {
            picture()
                .frame(height: 30)
            Text(title)
                .font(.system(size: 13))
        }
        .foregroundStyle(isOn ? Color.accentColor : .primary)
        .frame(maxWidth: .infinity, minHeight: 70)
        .padding(.horizontal, 6)
        .background(isOn ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            if isOn { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5) }
        }
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
    }
}

/// Craft's little pictures of the layouts: a warm thumbnail and lines of text.
struct DocLayoutIllustration: View {
    let layout: DocLayout

    var body: some View {
        switch layout {
        case .small:
            HStack(spacing: 3) {
                thumbnail.frame(width: 12, height: 9)
                line(width: 18)
            }
            .padding(4)
            .background(.background, in: .rect(cornerRadius: 3))
        case .regular:
            HStack(spacing: 4) {
                thumbnail.frame(width: 18, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    line(width: 22)
                    line(width: 14)
                }
            }
            .padding(4)
            .background(.background, in: .rect(cornerRadius: 3))
        case .card:
            VStack(alignment: .leading, spacing: 3) {
                thumbnail.frame(width: 34, height: 14)
                line(width: 22).padding(.leading, 2)
            }
            .padding(.bottom, 3)
            .background(.background, in: .rect(cornerRadius: 3))
        }
    }

    private var thumbnail: some View {
        LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.3), Color(red: 0.62, green: 0.36, blue: 0.3)], startPoint: .top, endPoint: .bottom)
            .clipShape(.rect(cornerRadius: 2))
    }

    private func line(width: CGFloat) -> some View {
        Capsule().fill(Color(.systemGray3)).frame(width: width, height: 2.5)
    }
}

/// One of the panel's tiles: its color's symbol over its name, on a wash of the color.
private struct DocSelectionTile: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(height: 26)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(color.opacity(0.7))
        }
        .foregroundStyle(color)
        .frame(width: 64, height: 66)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
    }
}
