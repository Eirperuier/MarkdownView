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
    private static let spareLimit = 24
    /// The keys rows show now.
    private static var showing: Set<String> = []

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
        Self.showing.insert(key)
        self.context = context
        host?.rootView = Self.rooted(content, key: key, in: self)
        setNeedsLayout()
    }

    /// At its own height, top first: a change in it (a card prepared) is told to the row
    /// showing it. The same views made ahead and shown: shown, only what's told changes.
    private static func rooted(_ content: some View, key: String, in row: HostedRowView?) -> AnyView {
        AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak row] size in
                    MainActor.assumeIsolated { row?.contentSizeChanged(size, key: key) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }

    // MARK: Made ahead

    /// `content`, which a row will show soon, made and laid out at `width` in the stage while
    /// the main thread has nothing to do (AheadWork): shown, its views are there, drawn.
    static func prepare(_ content: some View, key: String, width: CGFloat) {
        counts.asked += 1
        let work = "hosted|\(key)"
        guard width > 0, !showing.contains(key), !spare.contains(where: { $0.key == key }), !AheadWork.isWaiting(work) else { return }
        let root = rooted(content, key: key, in: nil)
        AheadWork.add(work) {
            guard !showing.contains(key), !spare.contains(where: { $0.key == key }) else { return }
            let host = host(for: "")
            host.rootView = root
            let height = heights[key]?[width] ?? host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            AheadWork.stage?.addSubview(host.view)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            spare.append((key, host))
            counts.madeAhead += 1
            if spare.count > spareLimit { spare.removeFirst().host.view.removeFromSuperview() }
        }
    }

    /// Under the bench: hosts made ahead, asked for, and taken up again.
    static var counts = (asked: 0, madeAhead: 0, kept: 0, made: 0)

    /// The host kept for `key`, else the longest kept one's, else a new one.
    private static func host(for key: String) -> UIHostingController<AnyView> {
        if let index = spare.lastIndex(where: { $0.key == key }) {
            counts.kept += 1
            return spare.remove(at: index).host
        }
        if !key.isEmpty { counts.made += 1 }
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
        guard let key else { return host.view.removeFromSuperview() }
        // Kept in the window, out of sight, as it is.
        if let stage = AheadWork.stage { stage.addSubview(host.view) } else { host.view.removeFromSuperview() }
        Self.showing.remove(key)
        for kept in Self.spare where kept.key == key { kept.host.view.removeFromSuperview() }
        Self.spare.removeAll { $0.key == key }
        Self.spare.append((key, host))
        if Self.spare.count > Self.spareLimit { Self.spare.removeFirst().host.view.removeFromSuperview() }
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
