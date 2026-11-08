//
//  MarkdownTableView.swift
//  MarkdownUIKit
//
//  A table, measured by the frame as chat's rows are. It's drawn as one picture: grounds, lines
//  and all the text, with no view per cell. A big one is a few tiles, only those near the screen
//  held. Only what needs a text view has one:
//
//   - a cell touched, or under a moving pointer, so selecting and links are a text view's own;
//   - a cell a reveal is passing through, for its letters to fade in;
//   - a cell holding what only a text view shows (a formula, an image).
//
//  The rest is measured from its string, and its text drawn from it, by string drawing: no layout
//  objects for text that's only looked at.
//

import Markdown
import MarkdownCore
import RichTextCore
import UIKit

@MainActor
public final class MarkdownTableView: UIView, UIGestureRecognizerDelegate {
    /// The table changed height by itself: an image came in.
    var onHeightChange: (() -> Void)?

    private var content = MarkdownTableContent()
    private var style = MarkdownStyle()
    private var options: MarkdownTableOptions { style.table }
    private var metrics: MarkdownTableMetrics?
    private var nextPrepared: MarkdownPreparedTable?
    private var geometries: [CGFloat: MarkdownTableGeometry] = [:]
    private var shown: MarkdownTableGeometry?

    private let canvas = Canvas()
    private var scroller: MarkdownCodeScrollView?
    private var tiles: [TileKey: Tile] = [:]
    private var tileRect = CGRect.zero
    private var hosts: [MarkdownTableCellPosition: CellHost] = [:]
    /// Cells with a text view for being touched, oldest first.
    private var touched: [MarkdownTableCellPosition] = []
    private var replacedViews: [MarkdownTableCellPosition: UIView] = [:]
    /// Drawn cells' text laid out for a selection, while the cell and where it's drawn stay.
    private var drawnSelectables: [MarkdownTableCellPosition: (cell: MarkdownTableCell, rect: CGRect, text: MarkdownSelectableText)] = [:]
    private var decoration: UIView?
    private var pageObservation: NSKeyValueObservation?
    private var tapRecognizer: UITapGestureRecognizer?

    // Reveal.
    private var reveal: MarkdownReveal?
    private var listener: UUID?
    private var startedCount = Int.max
    private var settledCount = Int.max
    private var revealing: Set<MarkdownTableCellPosition> = []
    private var settleTask: Task<Void, Never>?
    private var toldExtent: CGSize??
    /// From this row on, cells changed: they draw again at the next layout.
    private var pendingChangedRow: Int?

    private struct TileKey: Hashable {
        let column: Int
        let row: Int
    }

    /// A cell's text view, and why it's there.
    @MainActor
    private final class CellHost {
        let host: MarkdownTextHost
        let placement: MarkdownTextPlacement?
        var cell: MarkdownTableCell

        /// The table goes on drawing its underlines under this text view.
        let leavesUnderlines: Bool

        var text: MarkdownText { leavesUnderlines ? cell.textWithoutUnderlines : cell.text }

        init(cell: MarkdownTableCell, reveal: MarkdownReveal?) {
            self.cell = cell
            leavesUnderlines = cell.hasUnderlines && reveal == nil
            // What a table draws gives way to this text and takes over again: it lands the same.
            // A cell always in a text view has nothing to match.
            placement = cell.needsHost ? nil : MarkdownTextPlacement()
            // A cell placing views is drawn text, as it was measured.
            let drawsViews = cell.drawsInlineViews && reveal == nil
            host = MarkdownTextHost(textView: !drawsViews, placement: placement)
            var style = cell.style
            style.drawsTextUntilTouched = drawsViews
            host.apply(text, style: style, reveal: reveal, prepared: drawsViews ? cell.inlineStack : nil)
        }
    }

    /// The most text views kept for touches; a cell past that goes back to being drawn.
    private static let touchedCapacity = 8
    /// The most kept for a reveal: a table all parsed at once doesn't take one per cell.
    private static let revealingCapacity = 12
    private static let tileSize = CGSize(width: 1024, height: 768)
    /// A streaming table's tile grows by this: a tile changing size is drawn again whole.
    private static let growthStep: CGFloat = 256

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        canvas.owner = self
        addSubview(canvas)
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownTableView, _: UITraitCollection) in
            view.tiles.values.forEach { $0.setNeedsDisplay() }
        }
        if UIDevice.current.userInterfaceIdiom != .phone {
            canvas.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        stopFollowing()
        hosts.values.forEach { $0.host.release() }
    }

    // MARK: Content

    /// Shows the table in `source`. The same table grown adds what's new. False if it isn't one.
    @discardableResult
    public func configure(source: String, style: MarkdownStyle, reveal: MarkdownReveal? = nil, inlineMath: [String: String]? = nil, displayMath: [UUID: String]? = nil) -> Bool {
        var given = style
        given.drawsTextUntilTouched = false
        let oldKey = self.style.table.textKey
        let prepared = takePrepared()
        if let prepared { content = prepared.content }
        guard content.update(source: source, style: given, inlineMath: inlineMath, displayMath: displayMath) else { return false }
        self.style = given
        metrics = MarkdownTableMetrics(options: given.table)
        if oldKey != given.table.textKey { replacedViews.values.forEach { $0.removeFromSuperview() }; replacedViews.removeAll() }
        // A table made ahead is new here: all of it is drawn again.
        let changed = prepared != nil ? 0 : content.firstChangedRow
        if changed != nil || geometries.isEmpty {
            geometries.removeAll()
            syncReplaced()
            syncHosts()
        }
        if let prepared { geometries[prepared.width] = prepared.geometry }
        placeScroller()
        tapRecognizerUpdate()
        follow(reveal)
        canvas.invalidateAccessibility()
        setNeedsLayout()
        if let changed { pendingChangedRow = min(pendingChangedRow ?? changed, changed) }
        return true
    }

    /// Whether it shows this source already.
    func shows(_ source: String) -> Bool {
        content.source == source
    }

    /// What the next `configure` starts from.
    func willConfigure(prepared: MarkdownPreparedTable?) {
        nextPrepared = prepared
    }

    private func takePrepared() -> MarkdownPreparedTable? {
        defer { nextPrepared = nil }
        return nextPrepared
    }

    /// A reveal coming to or leaving what shows, with no relayout.
    public func setReveal(_ reveal: MarkdownReveal?) {
        follow(reveal)
        setNeedsLayout()
    }

    /// The text views go back to the pool.
    public func prepareForReuse() {
        stopFollowing()
        reveal = nil
        hosts.values.forEach {
            $0.host.release()
            $0.host.view.removeFromSuperview()
        }
        hosts.removeAll()
        touched.removeAll()
        revealing.removeAll()
    }

    /// The text views inside, for a host's selection and hooks.
    public var textViews: [UITextView] { hosts.values.compactMap(\.host.existingTextView) }

    /// Its cells' text where it's drawn, row by row, for a selection across blocks: a tab
    /// between a row's cells, a newline after the row. Every cell counts, shown yet or not, so a
    /// row's text stays the same as a reveal goes on.
    public var selectableTexts: [MarkdownSelectableText] {
        guard let geometry = shown else { return [] }
        var texts: [MarkdownSelectableText] = []
        for (row, cells) in content.rows.enumerated() where geometry.textFrames.indices.contains(row) {
            let frames = geometry.textFrames[row]
            var rowTexts: [MarkdownSelectableText] = []
            for (index, cell) in cells.enumerated() where frames.indices.contains(index) {
                rowTexts.append(selectableText(of: cell, frame: frames[index]).separated(by: "\t"))
            }
            if !rowTexts.isEmpty { rowTexts[rowTexts.count - 1] = rowTexts[rowTexts.count - 1].separated(by: "\n") }
            texts += rowTexts
        }
        return texts
    }

    private func selectableText(of cell: MarkdownTableCell, frame: CGRect) -> MarkdownSelectableText {
        if let view = replacedViews[cell.position] {
            return MarkdownSelectableText(whole: cell.string.string, frame: view.frame, in: canvas)
        }
        // Only a text view shows it: its layout.
        if cell.needsHost, let text = hosts[cell.position]?.host.selectableText { return text }
        // Drawn, or in a text view that lands where it's drawn.
        let inner = cell.tag == nil ? frame : frame.insetBy(dx: MarkdownTableMetrics.tagPadding.width, dy: MarkdownTableMetrics.tagPadding.height)
        var rect = inner
        if let fit = cell.hairOverFit(width: inner.width, scale: traitCollection.displayScale) {
            rect.origin.x += fit.offset
            rect.size.width = fit.width + 0.001
        }
        if let known = drawnSelectables[cell.position], known.cell === cell, known.rect == rect { return known.text }
        let text = MarkdownSelectableText(drawn: cell.string, frame: rect, in: canvas)
        drawnSelectables[cell.position] = (cell, rect, text)
        return text
    }

    /// The cell at a point in the view; nil outside the cells. A point between two columns is
    /// the nearer one's.
    public func position(at point: CGPoint) -> MarkdownTableCellPosition? {
        guard let geometry = shown else { return nil }
        let inner = convert(point, to: canvas)
        guard let row = geometry.rows(from: inner.y, to: inner.y).first else { return nil }
        let half = (metrics?.columnSpacing ?? 0) / 2
        for (column, x) in geometry.columnX.enumerated() where x - half <= inner.x && inner.x < x + geometry.columnWidths[column] + half {
            return MarkdownTableCellPosition(row: row, column: column)
        }
        return nil
    }

    /// What's in a cell changed size by itself.
    func textSizeDidChange() {
        for cell in content.flat where cell.needsTextView {
            cell.natural = nil
            cell.wrapped = nil
        }
        hosts.values.forEach { $0.host.textSizeDidChange() }
        geometries.removeAll()
        setNeedsLayout()
    }

    private func tapRecognizerUpdate() {
        if options.onCellTap != nil, tapRecognizer == nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            canvas.addGestureRecognizer(tap)
            tapRecognizer = tap
        } else if options.onCellTap == nil, let tapRecognizer {
            canvas.removeGestureRecognizer(tapRecognizer)
            self.tapRecognizer = nil
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let position = position(at: recognizer.location(in: self)) else { return }
        options.onCellTap?(position)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    private func placeScroller() {
        if options.scrollsSideways {
            let scroller = self.scroller ?? MarkdownCodeScrollView()
            if self.scroller == nil {
                // What's past the edges shows, as far as the row goes.
                scroller.clipsToBounds = false
                scroller.delegate = canvas
                addSubview(scroller)
                scroller.addSubview(canvas)
                self.scroller = scroller
            }
        } else if let scroller {
            addSubview(canvas)
            scroller.removeFromSuperview()
            self.scroller = nil
        }
    }

    // MARK: Size

    private func geometry(forWidth width: CGFloat) -> MarkdownTableGeometry {
        if let known = geometries[width] { return known }
        guard let metrics else { return MarkdownTableGeometry() }
        let made = MarkdownTableMeasure.geometry(
            content: content,
            options: options,
            metrics: metrics,
            width: width,
            isRightToLeft: style.layoutDirection == .rightToLeft,
            host: { [unowned self] in self.host(for: $0)?.host },
            replaced: { [unowned self] in self.replacedViews[$0.position] }
        )
        if geometries.count >= 3 { geometries.removeAll() }
        geometries[width] = made
        return made
    }

    /// The height at `width`, the same on or off a window.
    public func height(forWidth width: CGFloat) -> CGFloat {
        geometry(forWidth: width).contentSize.height
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: height(forWidth: size.width))
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let geometry = geometry(forWidth: bounds.width)
        let old = shown
        shown = geometry
        if let scroller {
            if scroller.frame != bounds { scroller.frame = bounds }
            let size = CGSize(width: geometry.contentSize.width, height: bounds.height)
            if scroller.contentSize != size { scroller.contentSize = size }
        }
        let frame = CGRect(origin: .zero, size: geometry.contentSize)
        if canvas.frame != frame { canvas.frame = frame }
        placeHosts(geometry)
        placeDecoration(geometry)
        updateTiles()
        if let old, !Self.sameLayout(old, geometry) {
            tiles.values.forEach { $0.setNeedsDisplay() }
        } else if let row = pendingChangedRow, row < geometry.rowY.count {
            let y = geometry.rowY[row]
            setCanvasNeedsDisplay(CGRect(x: tileRect.minX, y: y - 1, width: tileRect.width, height: tileRect.maxY - y + 1))
        }
        pendingChangedRow = nil
        canvas.invalidateAccessibility()
        tellExtent()
    }

    /// Whether what's on both is where it was: rows added at the end move nothing.
    private static func sameLayout(_ old: MarkdownTableGeometry, _ new: MarkdownTableGeometry) -> Bool {
        guard old.columnX == new.columnX, old.columnWidths == new.columnWidths, old.rowY.count <= new.rowY.count else { return false }
        for index in old.rowY.indices.dropLast() where old.rowY[index] != new.rowY[index] || old.rowHeights[index] != new.rowHeights[index] {
            return false
        }
        return true
    }

    private func setCanvasNeedsDisplay(_ rect: CGRect) {
        for tile in tiles.values where tile.frame.intersects(rect) {
            tile.setNeedsDisplay(tile.convert(rect, from: canvas))
        }
    }

    private func setCellNeedsDisplay(_ cell: MarkdownTableCell) {
        guard let shown else { return }
        setCanvasNeedsDisplay(shown.cellRect(cell).insetBy(dx: -MarkdownTableView.overdraw, dy: -MarkdownTableView.overdraw))
    }

    // MARK: Tiles

    /// How far past its text a drawing goes: what a first letter overhangs, half a line.
    fileprivate static let overdraw: CGFloat = 4

    private func canvasMargins() -> UIEdgeInsets {
        let outset = metrics?.groundOutset ?? (leading: 0, trailing: 0)
        let side = Self.overdraw
        return UIEdgeInsets(top: side, left: max(side, outset.leading), bottom: side, right: max(side, outset.trailing))
    }

    private func updateTiles() {
        let size = canvas.bounds.size
        guard window != nil, size.width > 0, size.height > 0 else { return }
        let margins = canvasMargins()
        var area = CGRect(origin: .zero, size: size).inset(by: UIEdgeInsets(top: -margins.top, left: -margins.left, bottom: -margins.bottom, right: -margins.right))
        // While it grows, a little more room: a tile drawn again whole is what costs.
        if reveal != nil {
            area.size.height = (area.height / Self.growthStep).rounded(.up) * Self.growthStep
        }
        tileRect = area
        let tile = Self.tileSize
        let across = max(1, Int((area.width / tile.width).rounded(.up)))
        let down = max(1, Int((area.height / tile.height).rounded(.up)))
        var wanted = Set<TileKey>()
        if across * down == 1 {
            wanted.insert(TileKey(column: 0, row: 0))
            pageObservation = nil
        } else {
            let visible = canvas.convert(window?.bounds ?? .zero, from: window).insetBy(dx: -tile.width / 2, dy: -tile.height / 2).intersection(area)
            if !visible.isNull {
                let columns = Int((visible.minX - area.minX) / tile.width)...min(across - 1, Int((visible.maxX - area.minX) / tile.width))
                let rows = Int((visible.minY - area.minY) / tile.height)...min(down - 1, Int((visible.maxY - area.minY) / tile.height))
                for column in columns {
                    for row in rows { wanted.insert(TileKey(column: column, row: row)) }
                }
            }
            observePageIfNeeded()
        }
        for (key, view) in tiles where !wanted.contains(key) {
            view.removeFromSuperview()
            tiles[key] = nil
        }
        for key in wanted {
            let frame = CGRect(x: area.minX + CGFloat(key.column) * tile.width, y: area.minY + CGFloat(key.row) * tile.height,
                               width: min(tile.width, area.width - CGFloat(key.column) * tile.width),
                               height: min(tile.height, area.height - CGFloat(key.row) * tile.height))
            if let shown = tiles[key] {
                if shown.frame != frame { shown.frame = frame }
            } else {
                let view = Tile(owner: self)
                view.frame = frame
                canvas.insertSubview(view, at: 0)
                tiles[key] = view
            }
        }
    }

    /// Scrolling the page moves a tall table past the screen with no layout here.
    private func observePageIfNeeded() {
        guard pageObservation == nil else { return }
        var view = superview
        while let current = view {
            if let page = current as? UIScrollView, page !== scroller {
                pageObservation = page.observe(\.contentOffset, options: []) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.updateTiles() }
                }
                return
            }
            view = current.superview
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        pageObservation = nil
        if window != nil {
            updateTiles()
        } else {
            releaseUntouchedHosts()
        }
    }

    fileprivate func canvasDidScroll() {
        updateTiles()
    }

    // MARK: Drawing

    fileprivate func draw(_ rect: CGRect, in context: CGContext) {
        guard let geometry = shown, let metrics else { return }
        let rows = geometry.rows(from: rect.minY - Self.overdraw, to: rect.maxY + Self.overdraw)
        guard !rows.isEmpty else { return }
        let cells = content.rows
        let scrolls = options.scrollsSideways

        // Grounds.
        for row in rows where rowHasStarted(row) {
            let rowRect = CGRect(x: 0, y: geometry.rowY[row], width: geometry.contentSize.width, height: geometry.rowHeights[row])
            if let ground = rowGround(row) {
                ground.setFill()
                context.fill(rowRect.markdownPixelAligned())
            }
            if scrolls, row > 0, !row.isMultiple(of: 2), let stripe = stripeColor {
                let outset = metrics.groundOutset
                let shape = CGRect(x: rowRect.minX - outset.leading, y: rowRect.minY, width: rowRect.width + outset.leading + outset.trailing, height: rowRect.height)
                stripe.setFill()
                UIBezierPath(roundedRect: shape, cornerRadius: MarkdownTableMetrics.groundCornerRadius).fill()
            }
            for cell in cells[row] where cell.fill != nil {
                drawFill(of: cell, geometry: geometry, metrics: metrics)
            }
        }

        // Lines between rows.
        if metrics.separator > 0 {
            UIColor.floo(.markdownTableSeparator).setFill()
            for row in rows where row > 0 && rowHasStarted(row) {
                let line = CGRect(x: 0, y: geometry.rowY[row] - metrics.separator, width: geometry.contentSize.width, height: metrics.separator)
                context.fill(line)
            }
        }

        // Text.
        for row in rows {
            let frames = geometry.textFrames[row]
            for (index, cell) in cells[row].enumerated() where frames.indices.contains(index) {
                let frame = frames[index]
                guard frame.maxX + Self.overdraw >= rect.minX, frame.minX - Self.overdraw <= rect.maxX, !isHidden(cell) else { continue }
                if let tag = cell.tag {
                    tag.markdownOpacity(0.15).setFill()
                    UIBezierPath(roundedRect: frame, cornerRadius: MarkdownTableMetrics.tagCornerRadius).fill()
                }
                guard replacedViews[cell.position] == nil else { continue }
                let inner = cell.tag == nil ? frame : frame.insetBy(dx: MarkdownTableMetrics.tagPadding.width, dy: MarkdownTableMetrics.tagPadding.height)
                if let host = hosts[cell.position] {
                    if host.leavesUnderlines { drawUnderlines(of: cell, in: inner, context: context) }
                    continue
                }
                // At least its natural width: a hair over its box mustn't wrap it.
                var rect = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height + 100)
                // A hair too wide for its box stays on its line, over the box's far edge.
                if let fit = cell.hairOverFit(width: inner.width, scale: traitCollection.displayScale) {
                    rect.origin.x += fit.offset
                    rect.size.width = fit.width + 0.001
                }
                cell.drawing.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
                drawUnderlines(of: cell, in: inner, context: context)
            }
        }

        drawLines(rows: rows, geometry: geometry, in: context)
        if let overlay = options.cellOverlay {
            for row in rows {
                for cell in cells[row] { overlay(geometry.cellRect(cell)) }
            }
        }
    }

    private func drawUnderlines(of cell: MarkdownTableCell, in rect: CGRect, context: CGContext) {
        guard cell.hasUnderlines else { return }
        for bar in cell.underlineBars(width: rect.width) {
            bar.color.setFill()
            context.fill(bar.rect.offsetBy(dx: rect.minX, dy: rect.minY))
        }
    }

    /// Lines round cells, once each however many cells share them.
    private func drawLines(rows: Range<Int>, geometry: MarkdownTableGeometry, in context: CGContext) {
        let color: UIColor
        switch options.look {
        case .github: color = .floo(.markdownTableGitHubBorder)
        case .grid: color = .floo(.markdownTableGridBorder)
        case .plain: return
        }
        guard !options.scrollsSideways else { return }
        let width = geometry.contentSize.width
        let pixel = 1 / markdownPixelScale
        let path = CGMutablePath()
        let top = geometry.rowY[rows.lowerBound]
        let bottom = geometry.rowY[rows.upperBound - 1] + geometry.rowHeights[rows.upperBound - 1]
        for row in rows {
            let y = markdownPixelRound(geometry.rowY[row])
            path.addRect(CGRect(x: 0, y: y - pixel, width: width, height: pixel * 2))
        }
        path.addRect(CGRect(x: 0, y: markdownPixelRound(bottom) - pixel, width: width, height: pixel * 2))
        for x in geometry.columnX + [width] {
            let snapped = markdownPixelRound(x)
            path.addRect(CGRect(x: snapped - pixel, y: top - pixel, width: pixel * 2, height: bottom - top + pixel * 2))
        }
        // One path: where lines cross, the colour counts once.
        context.addPath(path)
        color.setFill()
        context.fillPath(using: .winding)
    }

    private var stripeColor: UIColor? {
        switch options.appearance.stripe {
        case .standard: .floo(.markdownTableStripe)
        case .none: nil
        case .color(let color): color
        }
    }

    private func rowGround(_ row: Int) -> UIColor? {
        if let background = options.rowBackground { return background }
        guard case .github = options.look, !options.scrollsSideways else { return nil }
        return row == 0 || (row - 1).isMultiple(of: 2) ? .floo(.markdownTableGitHubRow) : .floo(.markdownTableGitHubAlternateRow)
    }

    /// A ground out to the middle of the space to its neighbours; square where it meets one of the
    /// same colour, so a run of them is one block.
    private func drawFill(of cell: MarkdownTableCell, geometry: MarkdownTableGeometry, metrics: MarkdownTableMetrics) {
        guard let fill = cell.fill else { return }
        let position = cell.position
        func same(_ row: Int, _ column: Int) -> Bool {
            guard content.rows.indices.contains(row), content.rows[row].indices.contains(column),
                  let other = content.rows[row][column].fill else { return false }
            return other.isEqual(fill)
        }
        let top = same(position.row - 1, position.column), bottom = same(position.row + 1, position.column)
        let leading = same(position.row, position.column - 1), trailing = same(position.row, position.column + 1)
        var corners = UIRectCorner()
        if !top, !leading { corners.insert(.topLeft) }
        if !bottom, !leading { corners.insert(.bottomLeft) }
        if !bottom, !trailing { corners.insert(.bottomRight) }
        if !top, !trailing { corners.insert(.topRight) }
        let rect = geometry.cellRect(cell)
        // On whole pixels, so neighbours meet without a blended column between them.
        let scale = max(traitCollection.displayScale, 1)
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snapped(rect.minX - metrics.groundOutset.leading), maxX = snapped(rect.maxX + metrics.groundOutset.trailing)
        let minY = snapped(rect.minY), maxY = snapped(rect.maxY)
        let shape = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let radius = MarkdownTableMetrics.groundCornerRadius
        fill.setFill()
        UIBezierPath(roundedRect: shape, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).fill()
    }

    // MARK: Text views

    /// The cell's text view, if it has or must have one.
    private func host(for cell: MarkdownTableCell) -> CellHost? {
        if let known = hosts[cell.position] { return known }
        guard cell.needsHost else { return nil }
        return makeHost(cell, reveal: revealing.contains(cell.position) ? reveal : nil)
    }

    private func makeHost(_ cell: MarkdownTableCell, reveal: MarkdownReveal?) -> CellHost {
        let made = CellHost(cell: cell, reveal: reveal)
        made.host.view.isUserInteractionEnabled = options.cellsSelectable || cell.hasLink || cell.needsHost
        hosts[cell.position] = made
        canvas.addSubview(made.host.view)
        if let shown, cell.position.row < shown.textFrames.count, cell.position.column < shown.textFrames[cell.position.row].count {
            place(made, in: shown)
        }
        return made
    }

    private func place(_ host: CellHost, in geometry: MarkdownTableGeometry) {
        let position = host.cell.position
        guard geometry.textFrames.indices.contains(position.row), geometry.textFrames[position.row].indices.contains(position.column) else { return }
        var frame = geometry.textFrames[position.row][position.column]
        if host.cell.tag != nil { frame = frame.insetBy(dx: MarkdownTableMetrics.tagPadding.width, dy: MarkdownTableMetrics.tagPadding.height) }
        // A hair too wide for its box stays on its line, where it's drawn.
        let fit = host.cell.hairOverFit(width: frame.width, scale: traitCollection.displayScale)
        if let fit { frame.size.width = fit.width + 0.01 }
        // The hair's room a drawing gives it counts too.
        let exact = fit.map { $0.offset + (host.cell.alignment == .center ? 0.0005 : host.cell.alignment == .trailing ? 0.001 : 0) }
        if host.placement?.exactOffset != exact {
            host.placement?.exactOffset = exact
            host.host.existingTextView?.setNeedsDisplay()
        }
        host.host.place(frame)
        if let textView = host.host.existingTextView { MarkdownPenOverlayView.sync(on: textView) }
    }

    private func placeHosts(_ geometry: MarkdownTableGeometry) {
        hosts.values.forEach { place($0, in: geometry) }
        for (position, view) in replacedViews where geometry.textFrames.indices.contains(position.row) && geometry.textFrames[position.row].indices.contains(position.column) {
            let frame = geometry.textFrames[position.row][position.column]
            if view.frame != frame { view.frame = frame }
        }
    }

    /// Hosts follow the cells: what's gone goes, what changed takes its new text.
    private func syncHosts() {
        for (position, cellHost) in hosts {
            guard content.rows.indices.contains(position.row), content.rows[position.row].indices.contains(position.column) else {
                cellHost.host.release()
                cellHost.host.view.removeFromSuperview()
                hosts[position] = nil
                continue
            }
            let cell = content.rows[position.row][position.column]
            if cell !== cellHost.cell {
                cellHost.cell = cell
                cellHost.host.update(cellHost.text, style: cell.style, reveal: revealing.contains(position) ? reveal : nil)
                cellHost.host.textSizeDidChange()
            }
        }
        for cell in content.flat where cell.needsHost && hosts[cell.position] == nil {
            _ = makeHost(cell, reveal: revealing.contains(cell.position) ? reveal : nil)
        }
        touched.removeAll { hosts[$0] == nil }
    }

    private func syncReplaced() {
        guard let replacement = options.replacement else { return }
        for position in options.replacedCells where replacedViews[position] == nil {
            guard let view = replacement(position) else { continue }
            replacedViews[position] = view
            canvas.addSubview(view)
        }
    }

    /// The text view for a touch at `point` in the canvas, nil if there's no text under it.
    fileprivate func takeTextView(at point: CGPoint) -> UITextView? {
        guard let geometry = shown, let cell = cell(at: point, in: geometry), replacedViews[cell.position] == nil, !isHidden(cell) else { return nil }
        if let known = hosts[cell.position] {
            markTouched(cell.position)
            return known.host.textView
        }
        guard options.cellsSelectable || cell.hasLink else { return nil }
        let made = makeHost(cell, reveal: nil)
        MarkdownDrawnTextStats.upgrades += 1
        markTouched(cell.position)
        // It takes over during a hit test: what's under the finger is asked of it at once.
        let view = made.host.textView
        view.layoutIfNeeded()
        if let manager = view.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
        setCellNeedsDisplay(cell)
        return view
    }

    /// The cell whose text `point` is on, or close to.
    private func cell(at point: CGPoint, in geometry: MarkdownTableGeometry) -> MarkdownTableCell? {
        guard let row = geometry.rows(from: point.y, to: point.y).first else { return nil }
        for (index, frame) in geometry.textFrames[row].enumerated() where frame.insetBy(dx: -6, dy: -6).contains(point) {
            return content.rows[row][index]
        }
        return nil
    }

    private func markTouched(_ position: MarkdownTableCellPosition) {
        touched.removeAll { $0 == position }
        touched.append(position)
        guard touched.count > Self.touchedCapacity else { return }
        // Not one in use: its selection would go.
        guard let oldest = touched.dropLast().first(where: { !isInUse($0) }) else { return }
        touched.removeAll { $0 == oldest }
        dropHost(oldest)
    }

    private func isInUse(_ position: MarkdownTableCellPosition) -> Bool {
        guard let view = hosts[position]?.host.existingTextView else { return false }
        return view.selectedRange.length > 0 || view.isFirstResponder
    }

    private func dropHost(_ position: MarkdownTableCellPosition) {
        guard let cellHost = hosts[position], !cellHost.cell.needsHost else { return }
        cellHost.host.release()
        cellHost.host.view.removeFromSuperview()
        hosts[position] = nil
        setCellNeedsDisplay(cellHost.cell)
    }

    private func releaseUntouchedHosts() {
        for position in touched where !isInUse(position) { dropHost(position) }
        touched.removeAll { hosts[$0] == nil }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        // `.began` also comes as a row scrolls under a resting pointer: only a move counts.
        guard recognizer.state == .changed else { return }
        _ = takeTextView(at: recognizer.location(in: canvas))
    }

    /// Every cell in a text view: a check that nothing moves when one takes over.
    public func showAllCellsInTextViews() {
        layoutIfNeeded()
        for cell in content.flat where hosts[cell.position] == nil && replacedViews[cell.position] == nil {
            _ = makeHost(cell, reveal: nil)
        }
        tiles.values.forEach { $0.setNeedsDisplay() }
    }

    // MARK: Reveal

    private func follow(_ new: MarkdownReveal?) {
        guard new?.manager !== reveal?.manager || (new == nil && startedCount != Int.max) else {
            if reveal != nil { refresh() }
            return
        }
        stopFollowing()
        reveal = new
        if let manager = new?.manager {
            startedCount = 0
            settledCount = 0
            listener = manager.addListener { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        } else {
            let wasRevealing = revealing
            revealing.removeAll()
            startedCount = Int.max
            settledCount = Int.max
            for position in wasRevealing {
                if hosts[position]?.cell.needsHost == true {
                    hosts[position]?.host.setReveal(nil)
                } else {
                    dropHost(position)
                }
            }
            tiles.values.forEach { $0.setNeedsDisplay() }
            toldExtent = nil
            tellExtent()
        }
    }

    private func stopFollowing() {
        settleTask?.cancel()
        settleTask = nil
        if let listener { reveal?.manager.removeListener(listener) }
        listener = nil
    }

    /// Where the frontier is now. Only the cells it's near are looked at: at a thousand cells the
    /// work per tick is still a handful.
    private func refresh() {
        guard let reveal else { return }
        let manager = reveal.manager
        let flat = content.flat
        guard let last = flat.last else { return }
        let revealed = manager.revealedCount
        let frontier = revealed == Int.max ? last.span.end : revealed
        let spans = content.spans

        // A frontier gone back (a stream's text grew past a catch-up) starts again from there.
        if settledCount > 0, settledCount <= flat.count, frontier < flat[settledCount - 1].span.end {
            settledCount = MarkdownTableRevealSearch.firstCell(endingAfter: frontier, in: spans)
        }
        let oldStarted = startedCount
        startedCount = (MarkdownTableRevealSearch.lastCell(startingAtOrBefore: frontier, in: spans) ?? -1) + 1

        let base = manager.adaptiveFadeDuration(baseDuration: reveal.style.motion.duration)
        let settle = base * MarkdownRevealStyle.colorDurationMultiplier + reveal.style.delay
        let now = Date()
        var active: [MarkdownTableCell] = []
        var nextExpiry: Date?
        var contiguous = true
        var index = min(settledCount, flat.count)
        var newSettled = index
        while index < min(startedCount, flat.count) {
            let cell = flat[index]
            var isSettled = cell.span.count == 0
            if !isSettled, frontier >= cell.span.end {
                if let stamp = manager.firstSeenTimestamp(at: cell.span.end - 1), stamp.addingTimeInterval(settle) > now {
                    let expiry = stamp.addingTimeInterval(settle)
                    nextExpiry = nextExpiry.map { min($0, expiry) } ?? expiry
                } else {
                    isSettled = true
                }
            }
            if isSettled {
                if contiguous { newSettled = index + 1 }
            } else {
                contiguous = false
                active.append(cell)
            }
            index += 1
        }
        settledCount = newSettled

        let wanted = active.suffix(Self.revealingCapacity)
        let wantedPositions = Set(wanted.map(\.position))
        for position in revealing where !wantedPositions.contains(position) {
            if hosts[position]?.cell.needsHost == true {
                hosts[position]?.host.setReveal(nil)
            } else {
                dropHost(position)
            }
        }
        for cell in wanted where !revealing.contains(cell.position) {
            if let known = hosts[cell.position] {
                known.host.setReveal(reveal)
            } else {
                _ = makeHost(cell, reveal: reveal)
            }
            setCellNeedsDisplay(cell)
        }
        revealing = wantedPositions

        // Rows whose first cell the frontier just reached: their grounds and lines.
        if startedCount != oldStarted, shown != nil {
            let from = min(oldStarted, startedCount), to = max(oldStarted, startedCount)
            if from < flat.count {
                let first = flat[from].position.row
                let lastRow = flat[min(to, flat.count) - 1].position.row
                if let shown, first < shown.rowY.count, lastRow < shown.rowY.count {
                    let y0 = shown.rowY[first] - 1, y1 = shown.rowY[lastRow] + shown.rowHeights[lastRow] + 1
                    setCanvasNeedsDisplay(CGRect(x: tileRect.minX, y: y0, width: tileRect.width, height: y1 - y0))
                }
            }
            tellExtent()
        }

        settleTask?.cancel()
        settleTask = nil
        if let nextExpiry {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.01, nextExpiry.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    fileprivate func isHidden(_ cell: MarkdownTableCell) -> Bool {
        guard reveal != nil, let flatIndex = flatIndex(of: cell) else { return false }
        return flatIndex >= startedCount
    }

    private func flatIndex(of cell: MarkdownTableCell) -> Int? {
        let columns = content.columnCount
        guard columns > 0 else { return nil }
        return cell.position.row * columns + cell.position.column
    }

    private func rowHasStarted(_ row: Int) -> Bool {
        guard reveal != nil, content.columnCount > 0 else { return true }
        return row * content.columnCount < startedCount
    }

    private func tellExtent() {
        guard let report = options.onRevealedExtent, let shown else { return }
        let extent: CGSize?
        if let manager = reveal?.manager, manager.revealedCount != Int.max {
            let started = min(startedCount, content.flat.count)
            if started == 0 {
                extent = .zero
            } else {
                let row = min(content.flat[started - 1].position.row, shown.rowY.count - 1)
                extent = CGSize(width: (shown.columnX.last ?? 0) + (shown.columnWidths.last ?? 0), height: shown.rowY[row] + shown.rowHeights[row])
            }
        } else {
            extent = nil
        }
        guard toldExtent != .some(extent) else { return }
        toldExtent = .some(extent)
        report(extent)
    }

    // MARK: Decoration

    private func placeDecoration(_ geometry: MarkdownTableGeometry) {
        guard let make = options.decoration else {
            decoration?.removeFromSuperview()
            decoration = nil
            return
        }
        guard let metrics else { return }
        var frames: [MarkdownTableCellPosition: CGRect] = [:]
        for cell in content.flat {
            let rect = geometry.cellRect(cell)
            frames[cell.position] = CGRect(x: rect.minX - metrics.groundOutset.leading, y: rect.minY, width: rect.width + metrics.groundOutset.leading + metrics.groundOutset.trailing, height: rect.height)
        }
        decoration?.removeFromSuperview()
        decoration = make(frames)
        if let decoration {
            decoration.isUserInteractionEnabled = false
            decoration.frame = CGRect(origin: .zero, size: CGSize(width: (geometry.columnX.last ?? 0) + (geometry.columnWidths.last ?? 0), height: geometry.contentSize.height))
            canvas.addSubview(decoration)
        }
    }

    // MARK: Accessibility

    fileprivate func accessibilityCells(in container: UIView) -> [Any] {
        guard let shown else { return [] }
        var elements: [Any] = []
        elements.reserveCapacity(content.flat.count)
        for (rowIndex, row) in content.rows.enumerated() {
            for (index, cell) in row.enumerated() where shown.textFrames.indices.contains(rowIndex) && shown.textFrames[rowIndex].indices.contains(index) {
                if let host = hosts[cell.position] {
                    elements.append(host.host.view)
                } else if !isHidden(cell) {
                    let element = UIAccessibilityElement(accessibilityContainer: container)
                    element.accessibilityLabel = cell.string.string
                    element.accessibilityTraits = cell.isHeader ? [.staticText, .header] : .staticText
                    element.accessibilityFrameInContainerSpace = shown.textFrames[rowIndex][index]
                    elements.append(element)
                }
            }
        }
        return elements
    }

    // MARK: Parts

    /// All the table's parts: finds the text under a touch.
    private final class Canvas: UIView, UIScrollViewDelegate {
        weak var owner: MarkdownTableView?
        private var elements: [Any]?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = nil
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
            // A text view or a host's view first: a selection's handles go past its bounds.
            for view in subviews.reversed() where !(view is Tile) && view.isUserInteractionEnabled {
                if let hit = view.hitTest(convert(point, to: view), with: event) { return hit }
            }
            guard self.point(inside: point, with: event) else { return nil }
            // A scroll hit-tests every row under a resting pointer: only a touch takes a text view.
            guard event?.type == .touches, let textView = owner?.takeTextView(at: point) else { return self }
            return textView.hitTest(convert(point, to: textView), with: event) ?? self
        }

        override var accessibilityElements: [Any]? {
            get {
                if let elements { return elements }
                let made = owner?.accessibilityCells(in: self) ?? []
                elements = made
                return made
            }
            set { elements = newValue }
        }

        func invalidateAccessibility() {
            elements = nil
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            owner?.canvasDidScroll()
        }
    }

    /// A piece of the picture.
    private final class Tile: UIView {
        private unowned let owner: MarkdownTableView

        init(owner: MarkdownTableView) {
            self.owner = owner
            super.init(frame: .zero)
            isOpaque = false
            backgroundColor = nil
            contentMode = .redraw
            isUserInteractionEnabled = false
            layer.drawsAsynchronously = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.translateBy(x: -frame.minX, y: -frame.minY)
            owner.draw(rect.offsetBy(dx: frame.minX, dy: frame.minY), in: context)
        }
    }
}

/// A table inside text: in a quote, or a list's item.
final class MarkdownTableAttachment: RichTextAttachment {
    private let view: MarkdownTableView
    private let source: String

    @MainActor
    init(id: AnyHashable, table: Markdown.Table, style: MarkdownStyle, inlineMath: [String: String], displayMath: [UUID: String]) {
        source = table.format()
        view = MarkdownTableView()
        super.init(id: id, sizing: .fittingLineFragment)
        var inner = style
        inner.nestedBlock = nil
        view.configure(source: source, style: inner, inlineMath: inlineMath, displayMath: displayMath)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    override var contentView: UIView { view }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? {
        CGSize(width: proposal.width, height: view.height(forWidth: proposal.width))
    }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}
