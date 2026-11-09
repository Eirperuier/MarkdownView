//
//  DocRowUIKit.swift
//  DemoApp
//
//  What every UIKit row of the page is: its content in the page's text column, in from the
//  page's left by its block's level, in its decoration box when it has one; taking clicks
//  when the block controller lets it, hidden while a block dropped on it lands. The layout
//  DocRowView and DocRowBoxing had, in frames.
//

import DocKit
import MessagingUI
import Observation
import UIKit

@MainActor
class DocRowUIKitView: UIView {
    /// What the row shows, laid out in the text column.
    let content: UIView
    private let box = UIView()
    private(set) var row: DocRow?
    private(set) var context: TiledUIKitCellContext?

    private typealias Box = DocTokens.Component.DecorationBox

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        box.backgroundColor = .floo(.markdownBlockDecoration)
        box.layer.cornerCurve = .continuous
        box.isUserInteractionEnabled = false
        addSubview(box)
        addSubview(content)
        clock = DocRowMoveClock(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The row it shows now, and how it takes clicks and lands.
    func take(_ row: DocRow, blocks: DocBlockController, context: TiledUIKitCellContext) {
        self.row = row
        self.context = context
        if let block = row.block { follow(blocks, block: block) }
        setNeedsLayout()
    }

    /// Lays out what it shows now: in the layout motion when the row showed this item
    /// already in an animated update (a reshape), its content going to its new place with
    /// the rows round it.
    ///
    /// The row drives the rows' moves (`drivesRowMoves`). Its content goes in Core
    /// Animation's spring of the layout motion, its layer's time held and moved on by the
    /// row each frame; each frame it reports how far the update has gone at that moment, and
    /// the list moves the rows in the same frame: the content and the rows round it are drawn
    /// at one moment of the motion, however many updates overlap.
    func layOutShown() {
        guard let context, context.animation != nil else {
            setNeedsLayout()
            return
        }
        guard context.showsSameItem, window != nil else {
            setNeedsLayout()
            context.reportAnimationProgress(1)
            return
        }
        clock.hold()
        setNeedsLayout()
        let turnDial = clock.start(context)
        let spring = DocTokens.Motion.layoutSpring
        let enabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce, options: [.allowUserInteraction]) {
            self.layoutIfNeeded()
            self.content.layoutIfNeeded()
            turnDial()
        }
        UIView.setAnimationsEnabled(enabled)
    }

    private var clock: DocRowMoveClock!

    /// The content's height at a width (the text column's).
    func contentHeight(forWidth width: CGFloat) -> CGFloat { 0 }

    /// The content's height changed: the list is told the row's.
    func contentHeightChanged() {
        guard let row, bounds.width > 0 else { return }
        let height = Self.frames(of: row, width: bounds.width, contentHeight: contentHeight(forWidth: Self.contentWidth(of: row, width: bounds.width))).height
        context?.heightDidChange(to: height)
        setNeedsLayout()
    }

    func reset() {
        clock.finish()
        row = nil
        context = nil
        alpha = 1
        content.isUserInteractionEnabled = true
    }

    /// Clicks and taps reach the content when the block controller lets them (on the Mac a
    /// click first selects the block), and a block dropped shows once what flies to it is down.
    private func follow(_ blocks: DocBlockController, block: DocBlockID) {
        guard let row else { return }
        let (editsText, takesClicks, scrollsAcross) = (row.editsText, row.takesClicks, row.scrollsAcross)
        withObservationTracking {
            content.isUserInteractionEnabled = blocks.blockTakes(block, editsText: editsText, takesClicks: takesClicks)
                || (DocBlockController.usesHandles && scrollsAcross)
            alpha = blocks.isLanding(block) ? 0 : 1
        } onChange: { [weak self, weak blocks] in
            DispatchQueue.main.async {
                guard let self, let blocks, self.row?.block == block else { return }
                self.follow(blocks, block: block)
            }
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row else { return }
        let frames = Self.frames(of: row, width: bounds.width, contentHeight: contentHeight(forWidth: Self.contentWidth(of: row, width: bounds.width)))
        content.frame = frames.content
        box.isHidden = frames.box == nil
        if let rect = frames.box {
            box.frame = rect
            var corners: CACornerMask = []
            if row.box?.isFirst == true { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
            if row.box?.isLast == true { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
            box.layer.cornerRadius = Box.cornerRadius
            box.layer.maskedCorners = corners
        }
    }

    /// Where the content and its box go in a row `width` wide, with content `contentHeight` tall.
    static func frames(of row: DocRow, width: CGFloat, contentHeight: CGFloat) -> (content: CGRect, box: CGRect?, height: CGFloat) {
        let boxed = row.box != nil
        let first = row.box?.isFirst == true
        let last = row.box?.isLast == true
        let left = DocBlockController.pageLeft(inWidth: width) + DocBlockController.indentWidth(row.indent)
        let pageWidth = max(0, DocBlockController.pageWidth(inWidth: width) - DocBlockController.indentWidth(row.indent))
        // Above the box (or the content), then the box's own padding: in a box below its
        // first row, the space between rows is inside the box.
        let above = !boxed || first ? row.spacingAbove : 0
        let topPadding = !boxed ? 0 : first ? Box.padding : row.spacingAbove
        let bottomPadding = boxed && last ? Box.padding : 0
        let inset = boxed ? Box.inset : 0
        let content = CGRect(x: left + inset, y: above + topPadding, width: max(0, pageWidth - inset * 2), height: contentHeight)
        let boxRect = boxed
            ? CGRect(x: left - Box.outset, y: above, width: pageWidth + Box.outset * 2, height: topPadding + contentHeight + bottomPadding)
            : nil
        return (content, boxRect, above + topPadding + contentHeight + bottomPadding + row.spacingBelow)
    }

    static func contentWidth(of row: DocRow, width: CGFloat) -> CGFloat {
        frames(of: row, width: width, contentHeight: 0).content.width
    }
}

/// A row's clock for the moves it drives. While a move runs the row's layer time is held
/// and moved on each frame by the clock: its content's animations, and its dials, are at
/// that moment until the next frame. Each update's progress is a dial going from one end to
/// the other in the update's animation; each frame it's read and reported, and the list
/// moves the rows in that frame. Updates that overlap each have their own dial.
///
/// The dials stay in the row: UIKit animates a view from the value it has, so each goes
/// from where it rests to the other end.
@MainActor
final class DocRowMoveClock {
    @MainActor
    private struct Dial {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        var target: CGFloat = 0
        var running: (context: TiledUIKitCellContext, started: CFTimeInterval)?
    }

    private weak var row: UIView?
    private var dials: [Dial]
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    /// How far a dial goes.
    private static let travel: CGFloat = 100

    /// Past this an update lands, whatever its dial shows.
    private static let longest: CFTimeInterval = 2

    init(in row: UIView) {
        self.row = row
        // As many as the list has slots for a row's updates.
        dials = (0..<4).map { _ in Dial() }
        for dial in dials {
            dial.view.isUserInteractionEnabled = false
            dial.view.backgroundColor = .clear
            row.addSubview(dial.view)
        }
    }

    /// Holds the row's layer time where it is (the clock moves it on from here each frame).
    func hold() {
        guard let layer = row?.layer, layer.speed != 0 else { return }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = now
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Starts `context`'s update: call what it returns in the update's animation.
    func start(_ context: TiledUIKitCellContext) -> () -> Void {
        // The longest running lands when every dial is taken.
        let index = dials.firstIndex { $0.running == nil }
            ?? dials.indices.min { dials[$0].running!.started < dials[$1].running!.started }!
        if let old = dials[index].running { old.context.reportAnimationProgress(1) }
        let target: CGFloat = dials[index].target == 0 ? 1 : 0
        dials[index].target = target
        dials[index].running = (context, CACurrentMediaTime())
        context.reportAnimationProgress(0)
        let view = dials[index].view
        return { view.frame.origin.x = target * Self.travel }
    }

    /// The updates still going land, and the row's layer time runs again.
    func finish() {
        link?.invalidate()
        link = nil
        for index in dials.indices {
            dials[index].running?.context.reportAnimationProgress(1)
            dials[index].running = nil
        }
        guard let layer = row?.layer, layer.speed == 0 else { return }
        let held = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - held
    }

    private func tick() {
        guard let layer = row?.layer else { return }
        let now = CACurrentMediaTime()
        layer.timeOffset += now - lastTick
        lastTick = now
        for index in dials.indices {
            guard let (context, started) = dials[index].running else { continue }
            let dial = dials[index]
            let moving = !(dial.view.layer.animationKeys()?.isEmpty ?? true)
            let shown = (dial.view.layer.presentation() ?? dial.view.layer).frame.minX / Self.travel
            let progress = dial.target == 1 ? shown : 1 - shown
            let done = !moving || now - started > Self.longest
            context.reportAnimationProgress(done ? 1 : progress)
            if done { dials[index].running = nil }
        }
        if dials.allSatisfy({ $0.running == nil }) { finish() }
    }

    /// Holds the clock weakly: a display link keeps its target.
    @MainActor
    private final class Target: NSObject {
        weak var clock: DocRowMoveClock?
        init(_ clock: DocRowMoveClock) { self.clock = clock }
        @objc func tick() { clock?.tick() }
    }
}

/// Heights a kind of row measured, by row and width, for what it showed.
@MainActor
struct DocRowHeights<Shown: Equatable> {
    private var entries: [String: (shown: Shown, row: DocRow, byWidth: [CGFloat: CGFloat])] = [:]

    mutating func height(of row: DocRow, showing shown: Shown, width: CGFloat, content: (CGFloat) -> CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        if let known = entries[row.id], known.shown == shown, known.row == row, let height = known.byWidth[width] { return height }
        let height = DocRowUIKitView.frames(of: row, width: width, contentHeight: content(DocRowUIKitView.contentWidth(of: row, width: width))).height
        var entry = entries[row.id].flatMap { $0.shown == shown && $0.row == row ? $0 : nil } ?? (shown: shown, row: row, byWidth: [:])
        entry.byWidth[width] = height
        entries[row.id] = entry
        return height
    }

    mutating func forget(_ id: String) {
        entries[id] = nil
    }
}
