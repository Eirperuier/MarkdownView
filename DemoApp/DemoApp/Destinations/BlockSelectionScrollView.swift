//
//  BlockSelectionScrollView.swift
//  DemoApp
//
//  A UIKit scroll view around SwiftUI content, exposed to MarkdownBlockSelectionController
//  as a MarkdownBlockSelectionLayout. Item frames come from SwiftUI through
//  `blockSelectionItem(_:)`, in the content's coordinates, which are the scroll view's.
//

import SwiftUI
import UIKit
import MarkdownView

@MainActor
@Observable
final class BlockSelectionScrollLayout: MarkdownBlockSelectionLayout {
    private(set) var layoutVersion: UInt = 0
    @ObservationIgnored private(set) weak var containerView: UIView?
    @ObservationIgnored fileprivate weak var scrollView: UIScrollView?
    @ObservationIgnored private var frames: [String: CGRect] = [:]
    @ObservationIgnored private var offsetObservation: NSKeyValueObservation?

    fileprivate func attach(container: UIView, scrollView: UIScrollView) {
        containerView = container
        self.scrollView = scrollView
        offsetObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.layoutVersion &+= 1 }
        }
    }

    fileprivate func setFrame(_ frame: CGRect?, forItem id: String) {
        guard frames[id] != frame else { return }
        frames[id] = frame
        layoutVersion &+= 1
    }

    func contentOffsetY() -> CGFloat {
        scrollView?.contentOffset.y ?? 0
    }

    func visibleContentHeight() -> CGFloat? {
        guard let scrollView else { return nil }
        let inset = scrollView.adjustedContentInset
        return scrollView.bounds.height - inset.top - inset.bottom
    }

    func frame(forItem id: String) -> CGRect? {
        frames[id]
    }

    func contentFrames(intersecting rect: CGRect) -> [String: CGRect] {
        frames.filter { $0.value.intersects(rect) }
    }

    func scrollToContentOffsetY(_ y: CGFloat) {
        guard let scrollView else { return }
        let inset = scrollView.adjustedContentInset
        let maxY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        scrollView.contentOffset.y = min(max(y, -inset.top), maxY)
    }
}

private let contentSpace = "BlockSelectionScrollView.content"

extension View {
    /// Reports this view's frame to the layout as the item `id`.
    func blockSelectionItem(_ id: String, in layout: BlockSelectionScrollLayout) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(contentSpace)) } action: {
            layout.setFrame($0, forItem: id)
        }
        .onDisappear { layout.setFrame(nil, forItem: id) }
    }
}

/// Scrolls `content` vertically inside a plain container view, which is what the
/// controller hit-tests against and what its overlay covers.
struct BlockSelectionScrollView<Content: View>: UIViewControllerRepresentable {
    let layout: BlockSelectionScrollLayout
    @ViewBuilder let content: Content

    func makeUIViewController(context: Context) -> Controller {
        Controller(layout: layout, rootView: rooted)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.host.rootView = rooted
    }

    private var rooted: AnyView {
        AnyView(content.coordinateSpace(.named(contentSpace)))
    }

    final class Controller: UIViewController {
        let host: UIHostingController<AnyView>
        private let layout: BlockSelectionScrollLayout
        private let scrollView = UIScrollView()

        init(layout: BlockSelectionScrollLayout, rootView: AnyView) {
            self.layout = layout
            host = UIHostingController(rootView: rootView)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            scrollView.alwaysBounceVertical = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scrollView)

            host.sizingOptions = .intrinsicContentSize
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            scrollView.addSubview(host.view)
            host.didMove(toParent: self)

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: view.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            ])
            layout.attach(container: view, scrollView: scrollView)
        }
    }
}
