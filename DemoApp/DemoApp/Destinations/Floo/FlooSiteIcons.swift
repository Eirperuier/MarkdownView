import MarkdownView
import SwiftUI
import UIKit

/// MarkdownView's site icons (before web links, `markdownLinkSiteIcons`): the sites' icons
/// as FlooFavicons has them, drawn once at text size with an icon's rounded corners.
@MainActor
enum FlooSiteIcons {
    static func install() {
        MarkdownLinkChips.iconImage = { host in mark(host).map { Image(uiImage: $0) } }
        MarkdownLinkChips.prefetchIcon = { host in _ = FlooFavicons.shared.icon(host) }
    }

    private static var marks: [String: UIImage] = [:]
    private static let side: CGFloat = 16

    private static func mark(_ host: String) -> UIImage? {
        if let mark = marks[host] { return mark }
        guard let icon = FlooFavicons.shared.icon(host) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let mark = UIGraphicsImageRenderer(size: bounds.size).image { _ in
            UIBezierPath(roundedRect: bounds, cornerRadius: side * 0.22).addClip()
            icon.draw(in: bounds)
        }
        marks[host] = mark
        return mark
    }
}
