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

    /// A row shown out of a window (the list makes rows before it puts them in) isn't laid
    /// out there, and goes in with nothing asking for it: it's laid out as it goes in.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        setNeedsLayout()
        content.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row else { return }
        let frames = Self.frames(of: row, width: bounds.width, contentHeight: contentHeight(forWidth: Self.contentWidth(of: row, width: bounds.width)))
        content.frame = frames.content
        box.isHidden = frames.box == nil
        if let rect = frames.box {
            box.frame = rect
            let ends = Self.boxEnds(of: row)
            var corners: CACornerMask = []
            if ends.first { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
            if ends.last { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
            box.layer.cornerRadius = Box.cornerRadius
            box.layer.maskedCorners = corners
        }
    }

    /// Whether the row's part of its box is the box's top and its bottom: a card's or a
    /// gallery image's box is a whole one of its own.
    static func boxEnds(of row: DocRow) -> (first: Bool, last: Bool) {
        let own = row.box != nil && row.run?.kind != nil
        return (own || row.box?.isFirst == true, own || row.box?.isLast == true)
    }

    /// Where the content and its box go in a row `width` wide, with content `contentHeight` tall.
    ///
    /// A link, file or image's row (one with a run) is where the list placed it across the
    /// page (DocMediaLayout.place): its content takes the row's width, in by the box's inset
    /// only when the box is its own; a box it shares with rows above and below reaches past
    /// it to the page's edges, as a text row's does.
    static func frames(of row: DocRow, width: CGFloat, contentHeight: CGFloat) -> (content: CGRect, box: CGRect?, height: CGFloat) {
        let boxed = row.box != nil
        let (first, last) = boxEnds(of: row)
        // Above the box (or the content), then the box's own padding: in a box below its
        // first row, the space between rows is inside the box.
        let above = !boxed || first ? row.spacingAbove : 0
        let topPadding = !boxed ? 0 : first ? Box.padding : row.spacingAbove
        let bottomPadding = boxed && last ? Box.padding : 0
        let height = above + topPadding + contentHeight + bottomPadding + row.spacingBelow
        let boxHeight = topPadding + contentHeight + bottomPadding
        if let run = row.run {
            let own = boxed && run.kind != nil
            let inset = own ? Box.inset : 0
            let content = CGRect(x: inset, y: above + topPadding, width: max(0, width - inset * 2), height: contentHeight)
            let reach = own ? 0 : run.inset + Box.outset
            let boxRect = boxed ? CGRect(x: -reach, y: above, width: width + reach * 2, height: boxHeight) : nil
            return (content, boxRect, height)
        }
        let left = DocBlockController.pageLeft(inWidth: width) + DocBlockController.indentWidth(row.indent)
        let pageWidth = max(0, DocBlockController.pageWidth(inWidth: width) - DocBlockController.indentWidth(row.indent))
        let inset = boxed ? Box.inset : 0
        let content = CGRect(x: left + inset, y: above + topPadding, width: max(0, pageWidth - inset * 2), height: contentHeight)
        let boxRect = boxed ? CGRect(x: left - Box.outset, y: above, width: pageWidth + Box.outset * 2, height: boxHeight) : nil
        return (content, boxRect, height)
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
            let progress = Self.progress(of: dials[index], at: layer.timeOffset)
            let done = progress == nil || now - started > Self.longest
            context.reportAnimationProgress(done ? 1 : progress!)
            if done { dials[index].running = nil }
        }
        if dials.allSatisfy({ $0.running == nil }) { finish() }
    }

    /// How far a dial's update has gone at the row's layer time `time`; nil once it's done.
    ///
    /// Worked out from its spring at that time, not read from its presentation: what's
    /// presented is the layer time last committed, a frame behind the one the row's content
    /// shows once this frame commits, and the rows round it would follow a frame late.
    private static func progress(of dial: Dial, at time: CFTimeInterval) -> CGFloat? {
        let layer = dial.view.layer
        guard let keys = layer.animationKeys(), !keys.isEmpty else { return nil }
        let shown = (layer.presentation() ?? layer).frame.minX / travel
        let presented = dial.target == 1 ? shown : 1 - shown
        guard let spring = keys.lazy.compactMap({ layer.animation(forKey: $0) as? CASpringAnimation }).first, spring.beginTime > 0 else {
            return presented
        }
        let elapsed = time - spring.beginTime
        guard elapsed < spring.settlingDuration else { return nil }
        return max(0, Self.springStep(spring, at: max(0, elapsed)))
    }

    /// A spring's way from its start (0) to its end (1) `t` seconds in.
    private static func springStep(_ spring: CASpringAnimation, at t: CFTimeInterval) -> CGFloat {
        let (mass, stiffness, damping) = (Double(spring.mass), Double(spring.stiffness), Double(spring.damping))
        let omega = (stiffness / mass).squareRoot()
        let zeta = damping / (2 * (stiffness * mass).squareRoot())
        // The initial velocity is toward the end, in ends per second.
        let velocity = Double(spring.initialVelocity)
        let x0 = -1.0
        let offset: Double
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let b = (velocity + zeta * omega * x0) / wd
            offset = exp(-zeta * omega * t) * (x0 * cos(wd * t) + b * sin(wd * t))
        } else if zeta == 1 {
            offset = exp(-omega * t) * (x0 + (velocity + omega * x0) * t)
        } else {
            let root = (zeta * zeta - 1).squareRoot()
            let (r1, r2) = (-omega * (zeta - root), -omega * (zeta + root))
            let c2 = (velocity - r1 * x0) / (r2 - r1)
            offset = (x0 - c2) * exp(r1 * t) + c2 * exp(r2 * t)
        }
        return CGFloat(1 + offset)
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
