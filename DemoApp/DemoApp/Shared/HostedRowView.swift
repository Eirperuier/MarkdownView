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
    private var host: UIHostingController<AnyView>?
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

    /// Hosts of rows scrolled away, by key, the most recent last: a row coming back takes its
    /// own, its views built and laid out already (a chart, a card), as Telegram keeps a node's.
    private static var spare: [(key: String, host: UIHostingController<AnyView>)] = []
    private static let spareLimit = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
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
        if self.key != key || host == nil {
            putHostAway()
            take(Self.host(for: key))
        }
        self.key = key
        self.context = context
        // At its own height, top first: a change in it (a card prepared) is told to the list.
        host?.rootView = AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    MainActor.assumeIsolated { self?.contentSizeChanged(size, key: key) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
        )
        setNeedsLayout()
    }

    /// The host kept for `key`, else the longest kept one's, else a new one.
    private static func host(for key: String) -> UIHostingController<AnyView> {
        if let index = spare.lastIndex(where: { $0.key == key }) { return spare.remove(at: index).host }
        if spare.count >= spareLimit { return spare.removeFirst().host }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        return host
    }

    private func take(_ host: UIHostingController<AnyView>) {
        self.host = host
        host.view.frame = bounds
        addSubview(host.view)
    }

    /// Its host off the row and kept for its key.
    private func putHostAway() {
        guard let host else { return }
        self.host = nil
        host.view.removeFromSuperview()
        guard let key else { return }
        Self.spare.removeAll { $0.key == key }
        Self.spare.append((key, host))
        if Self.spare.count > Self.spareLimit { Self.spare.removeFirst() }
    }

    private func contentSizeChanged(_ size: CGSize, key shownKey: String) {
        // At the row's width only: a reused row shows its new content at the last one's
        // width for a moment, a height that isn't this row's at any width it's laid out at.
        // A host put away reports to no row.
        guard let key, key == shownKey, host != nil, size.width > 0, size.height > 0, abs(size.width - bounds.width) < 0.5 else { return }
        onSize?(size)
        let known = Self.heights[key]?[size.width]
        guard known.map({ abs($0 - size.height) > 0.5 }) ?? true else { return }
        Self.heights[key, default: [:]][size.width] = size.height
        // The list asks again, at whatever width it lays the row out.
        context?.heightDidChange()
    }

    func reset() {
        putHostAway()
        key = nil
        context = nil
        onSize = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host?.view.frame = bounds
    }
}
