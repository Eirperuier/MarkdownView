//
//  LinkSiteIconsModifier.swift
//  MarkdownView
//

import SwiftUI

extension View {
    /// Shows each web link's site icon before it: the app's, through the link chips' icon
    /// hooks (`MarkdownLinkChips.iconImage`, asked for with `prefetchIcon`), and a globe
    /// until one comes or where there is none.
    nonisolated public func markdownLinkSiteIcons(_ enabled: Bool = true) -> some View {
        environment(\.markdownRendererConfiguration.linkSiteIcons, enabled)
    }
}

/// Marks a placeholder run (`\u{FFFC}`) drawn as a web link's site icon; the value is the
/// site's host.
public enum MarkdownSiteIconAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "MarkdownSiteIcon"
}

enum MarkdownSiteIcons {
    /// The host whose icon a link shows: a web page's only.
    static func host(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return host
    }
}

extension AttributedString {
    /// The text with its web links' site icons before them: a placeholder run each (drawn by
    /// `markdownTextWithInlineSymbols` with its own even room on both sides), held to the
    /// link by a word joiner so a line never ends on an icon.
    func withSiteIcons() -> AttributedString {
        var result = AttributedString()
        var previous: URL?
        for run in runs {
            if let url = run.link, url != previous, let host = MarkdownSiteIcons.host(of: url) {
                var icon = AttributedString("\u{FFFC}", attributes: run.attributes)
                icon[MarkdownSiteIconAttribute.self] = host
                icon.underlineStyle = nil
                var glue = AttributedString("\u{2060}", attributes: run.attributes)
                glue.underlineStyle = nil
                result += icon + glue
            }
            previous = run.link
            result += AttributedString(self[run.range])
        }
        return result
    }

    /// Whether any run is a site icon's placeholder.
    var hasSiteIcon: Bool {
        runs.contains { $0[MarkdownSiteIconAttribute.self] != nil }
    }
}
