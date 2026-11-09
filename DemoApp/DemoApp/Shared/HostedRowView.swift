//
//  HostedRowView.swift
//  DemoApp
//
//  A UIKit list row whose content is SwiftUI by nature (a card): a UIKit row hosting it, at
//  its own height, measured once per key and width and told to the list when it changes.
//  The chat's card rows and the document's both.
//

import MessagingUI
import SwiftUI
import UIKit

@MainActor
final class HostedRowView: UIView {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var key: String?
    private var context: TiledUIKitCellContext?
    /// Told the size the content renders at, each time it changes.
    var onSize: ((CGSize) -> Void)?

    /// Heights the content reported, by key and width.
    private static var heights: [String: [CGFloat: CGFloat]] = [:]
    private static let sizingHost: UIHostingController<AnyView> = {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        return host
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `content`'s height at `width`: what it last reported for `key`, else measured. `key`
    /// names the content as it is (another content, another key).
    static func height(of content: some View, key: String, width: CGFloat) -> CGFloat {
        if let known = heights[key]?[width] { return known }
        sizingHost.rootView = AnyView(content)
        let height = sizingHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        heights[key, default: [:]][width] = height
        return height
    }

    func show(_ content: some View, key: String, context: TiledUIKitCellContext) {
        self.key = key
        self.context = context
        // At its own height, top first: a change in it (a card prepared) is told to the list.
        host.rootView = AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    MainActor.assumeIsolated { self?.contentSizeChanged(size) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
        )
        setNeedsLayout()
    }

    private func contentSizeChanged(_ size: CGSize) {
        // At the row's width only: a reused row shows its new content at the last one's
        // width for a moment, a height that isn't this row's at any width it's laid out at.
        guard let key, size.width > 0, size.height > 0, abs(size.width - bounds.width) < 0.5 else { return }
        onSize?(size)
        let known = Self.heights[key]?[size.width]
        guard known.map({ abs($0 - size.height) > 0.5 }) ?? true else { return }
        Self.heights[key, default: [:]][size.width] = size.height
        // The list asks again, at whatever width it lays the row out.
        context?.heightDidChange()
    }

    func reset() {
        key = nil
        context = nil
        onSize = nil
        host.rootView = AnyView(EmptyView())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }
}
