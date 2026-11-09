//
//  MarkdownBlockSelectionOverlayView.swift
//  MarkdownView
//
//  The selection overlay (`MarkdownBlockSelectionOverlay`) as a UIKit view, for a list that's
//  UIKit's: laid over the list, its frame the list's, it draws the selected blocks' tint and
//  each block's and group's dot where the list has them, following its scrolls and layout.
//

#if canImport(RichText) && os(iOS)
import Observation
import SwiftUI
import UIKit

@MainActor
public final class MarkdownBlockSelectionOverlayView: UIView {
    private let controller: MarkdownBlockSelectionController
    private let accent: UIColor?
    private let topInset: (MarkdownBlockSelectionItem) -> CGFloat
    private let bottomInset: (MarkdownBlockSelectionItem) -> CGFloat
    private let highlights: (MarkdownBlockSelectionItem) -> Bool
    /// How it moves: dots filling and emptying, tints coming and going, the overlay itself.
    public var motion: MarkdownMotion = .default

    private var tints: [String: UIView] = [:]
    private var dots: [String: Dot] = [:]
    private var groupDots: [String: Dot] = [:]
    private var isShown = false

    /// - Parameters: as `MarkdownBlockSelectionOverlay`'s; `accent` nil: the view's tint.
    public init(
        controller: MarkdownBlockSelectionController,
        accent: UIColor? = nil,
        topInset: @escaping (MarkdownBlockSelectionItem) -> CGFloat = { _ in 0 },
        bottomInset: @escaping (MarkdownBlockSelectionItem) -> CGFloat = { _ in 0 },
        highlights: @escaping (MarkdownBlockSelectionItem) -> Bool = { _ in true }
    ) {
        self.controller = controller
        self.accent = accent
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.highlights = highlights
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: Self, _: UITraitCollection) in
            view.render()
        }
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func tintColorDidChange() {
        super.tintColorDidChange()
        render()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        render()
    }

    /// Drawn again as the selection, the list's layout or its scroll changes.
    private func follow() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.follow() } }
        }
    }

    private var accentColor: UIColor { accent ?? tintColor }

    private func render() {
        let state = controller.state
        let active = state.isActive && controller.layout != nil
        if active != isShown {
            isShown = active
            animate { self.alpha = active ? 1 : 0 }
        }
        guard active, let layout = controller.layout else { return }
        _ = layout.layoutVersion
        let selected = state.selectedItemIDs
        let offsetY = layout.contentOffsetY()
        let viewportHeight = (layout.visibleContentHeight() ?? layout.containerView?.bounds.height ?? 0)
            + (layout.containerView?.safeAreaInsets.top ?? 0)
        let visibleRange = (-200.0)...(viewportHeight + 200)
        let frames = controller.viewportFrames(padding: 200)
        let visible = controller.candidateItems().filter { frames[$0.id] != nil }
        let accent = accentColor
        let ring = UIColor.secondaryLabel.resolvedColor(with: traitCollection)

        var shownTints = Set<String>()
        var shownDots = Set<String>()
        for item in visible {
            guard let frame = frames[item.id] else { continue }
            let top = topInset(item)
            let contentHeight = max(0, frame.height - top - bottomInset(item))
            let isSelected = selected.contains(item.id)
            if isSelected, highlights(item) {
                shownTints.insert(item.id)
                let inset = MarkdownBlockSelectionStyle.highlightInset
                let tint = tints[item.id] ?? makeTint(item.id)
                tint.backgroundColor = accent.withAlphaComponent(MarkdownBlockSelectionStyle.highlightOpacity)
                tint.frame = CGRect(x: frame.minX + inset, y: frame.minY + top - offsetY, width: max(0, frame.width - inset * 2), height: contentHeight)
            }
            shownDots.insert(item.id)
            let size = MarkdownBlockSelectionStyle.dotSize
            let dot = dots[item.id] ?? makeDot(item.id, in: &dots, ringWidth: MarkdownBlockSelectionStyle.ringWidth)
            dot.frame = CGRect(x: frame.maxX - MarkdownBlockSelectionStyle.dotTrailing - size,
                               y: frame.minY + top - offsetY + contentHeight / 2 - size / 2, width: size, height: size)
            dot.show(fill: isSelected ? 1 : 0, ring: isSelected ? 0 : 1, accent: accent,
                     ringColor: ring.withAlphaComponent(MarkdownBlockSelectionStyle.ringOpacity), motion: motion)
        }
        var shownGroups = Set<String>()
        for group in controller.groups(frames: frames) {
            let y = group.dotAnchorFrame.midY
            guard visibleRange.contains(y) else { continue }
            shownGroups.insert(group.id)
            let count = group.itemIDs.filter { selected.contains($0) }.count
            let fill: CGFloat = count == group.itemIDs.count ? 1 : (count > 0 ? 0.35 : 0)
            let dot = groupDots[group.id] ?? makeDot(group.id, in: &groupDots, ringWidth: 1.5)
            dot.frame = CGRect(x: group.dotAnchorFrame.maxX - 32, y: y - 11, width: 22, height: 22)
            dot.show(fill: fill, ring: count == 0 ? 1 : 0, accent: accent, ringColor: ring.withAlphaComponent(0.5), motion: motion)
        }
        for (id, tint) in tints where !shownTints.contains(id) {
            tints[id] = nil
            animate({ tint.alpha = 0 }, completion: { tint.removeFromSuperview() })
        }
        for (id, dot) in dots where !shownDots.contains(id) {
            dots[id] = nil
            dot.removeFromSuperview()
        }
        for (id, dot) in groupDots where !shownGroups.contains(id) {
            groupDots[id] = nil
            dot.removeFromSuperview()
        }
    }

    private func makeTint(_ id: String) -> UIView {
        let tint = UIView()
        tint.layer.cornerRadius = MarkdownBlockSelectionStyle.highlightCornerRadius
        tint.layer.cornerCurve = .continuous
        tint.alpha = 0
        insertSubview(tint, at: 0)
        tints[id] = tint
        // It comes as the selection changes, with the selection's motion.
        animate { tint.alpha = 1 }
        return tint
    }

    private func makeDot(_ id: String, in dots: inout [String: Dot], ringWidth: CGFloat) -> Dot {
        let dot = Dot(ringWidth: ringWidth)
        addSubview(dot)
        dots[id] = dot
        return dot
    }

    private func animate(_ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        guard window != nil else {
            changes()
            completion?()
            return
        }
        Self.animate(motion.feedback, changes, completion: completion)
    }

    /// `animation` as UIKit runs it: SwiftUI's own (iOS 18 on), else its usual length eased.
    fileprivate static func animate(_ animation: Animation, _ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        if #available(iOS 18.0, *) {
            UIView.animate(animation, changes: changes, completion: completion)
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) { _ in completion?() }
        }
    }

    /// A dot: its fill and its ring, each faded in and out.
    private final class Dot: UIView {
        private let fill = UIView()
        private let ring = UIView()
        private var shown: (fill: CGFloat, ring: CGFloat)?

        init(ringWidth: CGFloat) {
            super.init(frame: .zero)
            for view in [fill, ring] {
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(view)
            }
            ring.layer.borderWidth = ringWidth
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            for view in [fill, ring] {
                view.frame = bounds
                view.layer.cornerRadius = bounds.width / 2
            }
        }

        func show(fill amount: CGFloat, ring ringAmount: CGFloat, accent: UIColor, ringColor: UIColor, motion: MarkdownMotion) {
            fill.backgroundColor = accent
            ring.layer.borderColor = ringColor.cgColor
            guard shown?.fill != amount || shown?.ring != ringAmount else { return }
            let first = shown == nil
            shown = (amount, ringAmount)
            let changes = { [fill, ring] in
                fill.alpha = amount
                ring.alpha = ringAmount
            }
            if first || window == nil { changes() } else { MarkdownBlockSelectionOverlayView.animate(motion.feedback, changes) }
        }
    }
}
#endif
