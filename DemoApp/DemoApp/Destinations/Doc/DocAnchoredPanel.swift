//
//  DocAnchoredPanel.swift
//  DemoApp
//
//  An anchored floating panel that lives inside the window: the UIKit form of Matrix
//  HQ's `MatrixDesignAnchoredPanel` (the Composer's model panel). No arrow, our own
//  reveal (a fade and a 0.975 scale out of the corner nearest the trigger), a width
//  that follows its content, dismissal by a touch outside it, and glass.
//
//  No window or popover is presented: a hosting view is added to the trigger's window
//  above everything, placed against the trigger's frame, and it follows the trigger
//  (the document scrolls under it). A popover would be a separate presentation with an
//  arrow and its own animation, and on iPhone it turns into a sheet. A SwiftUI overlay
//  would be clipped by the row and pushed around by its layout.
//
//  Its limit, as in Matrix: it can't go past the window.
//

import SwiftUI
import UIKit

struct DocAnchoredPanelConfiguration {
    enum Edge { case above, below }
    enum HorizontalAlignment { case leading, center, trailing }

    /// The side it opens toward; it takes the other one when this side has no room.
    var preferredEdge = Edge.below
    var horizontalAlignment = HorizontalAlignment.leading
    /// Between the trigger and the panel (Matrix: `Space.sm`).
    var anchorGap: CGFloat = 8
    /// The least it keeps from the window's edges (and the keyboard) (Matrix: `Space.md`).
    var windowMargin: CGFloat = 12
    var revealDuration: TimeInterval = 0.20
    var dismissDuration: TimeInterval = 0.13
    /// A slight scale keeps the panel attached to its trigger instead of reading as a zoom.
    var transitionScale: CGFloat = 0.975
}

extension View {
    /// Presents an in-window anchored panel from this view while `isPresented`; a touch
    /// outside it (and outside this view) calls `onDismiss`.
    func docAnchoredPanel<PanelContent: View>(
        isPresented: Bool,
        configuration: DocAnchoredPanelConfiguration = .init(),
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> PanelContent
    ) -> some View {
        modifier(DocAnchoredPanelModifier(isPresented: isPresented, configuration: configuration, onDismiss: onDismiss, panelContent: content))
    }
}

private struct DocAnchoredPanelModifier<PanelContent: View>: ViewModifier {
    let isPresented: Bool
    let configuration: DocAnchoredPanelConfiguration
    let onDismiss: () -> Void
    let panelContent: () -> PanelContent

    @State private var presenter = DocAnchoredPanelPresenter()

    func body(content: Content) -> some View {
        content
            .background {
                DocAnchoredPanelAnchor { anchor in
                    presenter.anchorView = anchor
                    // Every render, not only the first: the panel hosts a snapshot of the
                    // content, and what the trigger's state changes only shows in a new one.
                    if isPresented { show() }
                }
            }
            .onChange(of: isPresented) { _, presented in
                if presented { show() } else { presenter.hide() }
            }
            .onDisappear { presenter.hide(immediately: true) }
    }

    private func show() {
        presenter.show(configuration: configuration, content: AnyView(panelContent()), onRequestDismiss: onDismiss)
    }
}

/// The trigger's view, without taking part in its layout or hit testing.
private struct DocAnchoredPanelAnchor: UIViewRepresentable {
    let onResolve: (UIView) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onResolve = onResolve
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.onResolve = onResolve
        // Deferred: resolving writes to the presenter, which mustn't happen inside
        // SwiftUI's update of the very view.
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            onResolve(view)
        }
    }

    final class AnchorView: UIView {
        var onResolve: ((UIView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onResolve?(self)
            }
        }
    }
}

/// Not observable: no view reads it, and every anchor write would invalidate the view
/// that wrote it.
@MainActor
private final class DocAnchoredPanelPresenter {
    weak var anchorView: UIView?

    private var container: DocAnchoredPanelContainer?
    private var host: UIHostingController<AnyView>?
    private var configuration = DocAnchoredPanelConfiguration()
    private var onRequestDismiss: (() -> Void)?
    private var outsideTouches: DocOutsideTouchRecognizer?
    private var follower: CADisplayLink?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var dismissGeneration = 0

    func show(configuration: DocAnchoredPanelConfiguration, content: AnyView, onRequestDismiss: @escaping () -> Void) {
        guard let anchorView, let window = anchorView.window else { return }
        self.configuration = configuration
        self.onRequestDismiss = onRequestDismiss

        let hosted = AnyView(
            DocAnchoredPanelHostedContent(content: content) { [weak self] size in
                self?.container?.contentSizeDidChange(size)
            }
        )
        if let host, let container {
            host.rootView = hosted
            container.configuration = configuration
            // A refresh while it is on its way out cancels the dismissal.
            dismissGeneration += 1
            if host.view.layer.opacity < 1 || host.view.layer.animation(forKey: "doc.panel.opacity") != nil { reveal() }
            container.setNeedsLayout()
            return
        }

        let container = DocAnchoredPanelContainer(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.configuration = configuration
        container.anchorView = anchorView
        window.addSubview(container)

        let host = UIHostingController(rootView: hosted)
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        host.safeAreaRegions = []
        container.addSubview(host.view)
        container.panel = host.view
        self.container = container
        self.host = host

        // Revealed from its first real frame: the pivot needs the content's size.
        host.view.layer.opacity = 0
        container.onFirstMeasurement = { [weak self] in self?.reveal() }
        installObservers(window: window)
    }

    func hide(immediately: Bool = false) {
        guard let host else { return }
        removeObservers()
        guard !immediately, !UIAccessibility.isReduceMotionEnabled else { return finishHiding() }
        dismissGeneration += 1
        let generation = dismissGeneration
        animate(host.view, opacity: 0, scale: configuration.transitionScale, duration: configuration.dismissDuration, timing: .easeIn)
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.dismissDuration) { [weak self] in
            guard let self, self.dismissGeneration == generation else { return }
            self.finishHiding()
        }
    }

    private func finishHiding() {
        host?.view.removeFromSuperview()
        container?.removeFromSuperview()
        container = nil
        host = nil
        onRequestDismiss = nil
    }

    // MARK: Motion

    private func reveal() {
        guard let view = host?.view else { return }
        guard !UIAccessibility.isReduceMotionEnabled else {
            view.layer.opacity = 1
            return
        }
        view.layer.opacity = 0
        view.layer.transform = transform(scale: configuration.transitionScale, of: view)
        animate(view, opacity: 1, scale: 1, duration: configuration.revealDuration, timing: .easeOut)
    }

    /// Scales about the corner nearest the trigger, by a compensating translation (the
    /// layer's anchor point belongs to UIKit's geometry and stays put).
    private func transform(scale: CGFloat, of view: UIView) -> CATransform3D {
        let bounds = view.layer.bounds
        let unit = container?.pivot ?? CGPoint(x: 0.5, y: 0.5)
        let pivot = CGPoint(x: bounds.minX + bounds.width * unit.x, y: bounds.minY + bounds.height * unit.y)
        let anchor = CGPoint(x: bounds.minX + bounds.width * view.layer.anchorPoint.x, y: bounds.minY + bounds.height * view.layer.anchorPoint.y)
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform.m41 = (1 - scale) * (pivot.x - anchor.x)
        transform.m42 = (1 - scale) * (pivot.y - anchor.y)
        return transform
    }

    private func animate(_ view: UIView, opacity: Float, scale: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunctionName) {
        let layer = view.layer
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        let fromTransform = layer.presentation()?.transform ?? layer.transform
        let toTransform = transform(scale: scale, of: view)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        layer.transform = toTransform
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(fade, forKey: "doc.panel.opacity")
        let zoom = CABasicAnimation(keyPath: "transform")
        zoom.fromValue = NSValue(caTransform3D: fromTransform)
        zoom.toValue = NSValue(caTransform3D: toTransform)
        zoom.duration = duration
        zoom.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(zoom, forKey: "doc.panel.transform")
    }

    // MARK: Dismissal and following

    private func installObservers(window: UIWindow) {
        removeObservers()
        // A touch outside closes it, and still does what it was going to do.
        let recognizer = DocOutsideTouchRecognizer { [weak self] point in
            guard let self, let container = self.container else { return }
            if let anchor = self.anchorView, anchor.bounds.contains(anchor.convert(point, from: nil)) { return }
            if !container.panelContentRect.contains(container.convert(point, from: nil)) { self.onRequestDismiss?() }
        }
        window.addGestureRecognizer(recognizer)
        outsideTouches = recognizer
        // The trigger moves with the document; the panel goes with it.
        let link = CADisplayLink(target: DocDisplayLinkTarget { [weak self] in self?.container?.followAnchor() }, selector: #selector(DocDisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        follower = link
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let frame = name == UIResponder.keyboardWillHideNotification ? CGRect.null
                    : (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .null
                MainActor.assumeIsolated {
                    self?.container?.keyboardFrame = frame
                    self?.container?.setNeedsLayout()
                }
            })
        }
    }

    private func removeObservers() {
        if let outsideTouches { outsideTouches.view?.removeGestureRecognizer(outsideTouches) }
        outsideTouches = nil
        follower?.invalidate()
        follower = nil
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        keyboardObservers = []
    }
}

@MainActor
private final class DocDisplayLinkTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

/// Sees every touch in the window and never takes one: it fails at once, so nothing
/// it watches is delayed or cancelled.
private final class DocOutsideTouchRecognizer: UIGestureRecognizer {
    private let onTouch: (CGPoint) -> Void

    init(onTouch: @escaping (CGPoint) -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { onTouch(touch.location(in: nil)) }
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// The content at its own size, reporting it (the panel's only size authority).
private struct DocAnchoredPanelHostedContent: View {
    let content: AnyView
    let onContentSizeChange: (CGSize) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: true, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onContentSizeChange($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A window-sized, pass-through host for one panel: it answers touches only on the panel.
private final class DocAnchoredPanelContainer: UIView {
    weak var panel: UIView?
    weak var anchorView: UIView?
    var configuration = DocAnchoredPanelConfiguration()
    var keyboardFrame = CGRect.null
    var onFirstMeasurement: (() -> Void)?
    private var contentSize: CGSize?
    private var placedAnchor = CGRect.null
    /// The corner the panel grows from, in unit coordinates of its frame.
    private(set) var pivot = CGPoint(x: 0, y: 0)

    func contentSizeDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let first = contentSize == nil
        contentSize = size
        setNeedsLayout()
        layoutIfNeeded()
        if first {
            let callback = onFirstMeasurement
            onFirstMeasurement = nil
            callback?()
        }
    }

    func followAnchor() {
        guard let anchorView, anchorView.window != nil else { return }
        if anchorView.convert(anchorView.bounds, to: self) != placedAnchor { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let panel, let anchorView, let size = contentSize else { return }
        let anchor = anchorView.convert(anchorView.bounds, to: self)
        placedAnchor = anchor
        let margin = configuration.windowMargin
        var area = bounds.inset(by: safeAreaInsets)
        if !keyboardFrame.isNull {
            let keyboard = convert(keyboardFrame, from: nil)
            if keyboard.minY < area.maxY { area.size.height = max(0, keyboard.minY - area.minY) }
        }
        area = area.insetBy(dx: margin, dy: margin)
        let width = min(size.width, area.width)
        let height = size.height

        let x: CGFloat = switch configuration.horizontalAlignment {
        case .leading: anchor.minX
        case .center: anchor.midX - width / 2
        case .trailing: anchor.maxX - width
        }
        let below = anchor.maxY + configuration.anchorGap
        let above = anchor.minY - configuration.anchorGap - height
        let fitsBelow = below + height <= area.maxY
        let fitsAbove = above >= area.minY
        let opensBelow = configuration.preferredEdge == .below ? (fitsBelow || !fitsAbove) : !(fitsAbove || !fitsBelow)
        var frame = CGRect(x: x, y: opensBelow ? below : above, width: width, height: height)
        // Slides back inside by the overhang, no more.
        frame.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - width))
        frame.origin.y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - height))
        pivot = CGPoint(
            x: configuration.horizontalAlignment == .leading ? 0 : configuration.horizontalAlignment == .center ? 0.5 : 1,
            y: opensBelow ? 0 : 1
        )
        if panel.frame != frame {
            // Moved without the reveal's transform getting in the way.
            let transform = panel.layer.transform
            panel.layer.transform = CATransform3DIdentity
            panel.frame = frame
            panel.layer.transform = transform
        }
    }

    var panelContentRect: CGRect { panel?.frame ?? .zero }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let panel, panel.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The standard surface: glass where the system has it (iOS 26), else the regular
/// material with a hairline and a soft shadow. 16-point corners, Matrix's insets.
struct DocFloatingPanelSurface<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var contentInset = EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            content
                .padding(contentInset)
                .clipShape(shape)
                // Matrix's regular glass, tinted toward the page: over a document's
                // text, untinted glass lets the lines behind it read through.
                .glassEffect(.regular.tint(Color(uiColor: .systemBackground).opacity(0.55)), in: shape)
        } else {
            content
                .padding(contentInset)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        }
    }
}
