import MarkdownView
import SwiftUI
import UIKit
import Wire

/// MarkdownView's site icons (before web links, `markdownLinkSiteIcons`): the sites' icons
/// as FlooFavicons has them, drawn once at text size with an icon's rounded corners.
@MainActor
enum FlooSiteIcons {
    static func install() {
        MarkdownLinkChips.isEnabled = true
        MarkdownLinkChips.iconImage = { key in icon(key).map { Image(uiImage: $0) } }
        MarkdownLinkChips.prefetchIcon = { key in
            if let host = host(of: key) { _ = FlooFavicons.shared.icon(host) }
        }
    }

    /// The result chips shown (FlooLive), by their chip link: what a tool chip's icon and tap go by.
    static var cites: [String: AnswerCite] = [:]

    /// A chip's icon: a web one's site; a result one's, its link's site if it has one, else its
    /// service's symbol.
    private static func icon(_ key: String) -> UIImage? {
        if let host = host(of: key) { return mark(host) }
        guard let cite = cites[key] else { return nil }
        let symbol = switch cite.tool.split(separator: "_").first.map(String.init) ?? "" {
        case "mail", "gmail": "envelope"
        case "calendar": "calendar"
        case "contacts": "person.crop.circle"
        case "health": "heart"
        case "weather", "rain", "air": "cloud.sun"
        case "notes": "note.text"
        case "files", "read", "search": "doc.text"
        default: "square.grid.2x2"
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.8, weight: .medium)
        return UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
    }

    /// The site a chip's key names: a web chip's host, or a result chip's own link's.
    private static func host(of key: String) -> String? {
        if key.hasPrefix("\(MarkdownLinkChips.toolScheme)://") {
            return cites[key]?.url.flatMap { URL(string: $0)?.host() }
        }
        return key.contains("://") ? URL(string: key)?.host() : key
    }

    /// A tapped chip opens its first link: a web page in the browser; a result by its own link,
    /// if it has one.
    static func open(_ url: URL) -> OpenURLAction.Result {
        guard let links = MarkdownLinkChips.urls(from: url), let first = links.first else { return .systemAction }
        let target = first.hasPrefix("\(MarkdownLinkChips.toolScheme)://") ? cites[first]?.url : first
        guard let target, let opened = URL(string: target) else { return .discarded }
        return .systemAction(opened)
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
