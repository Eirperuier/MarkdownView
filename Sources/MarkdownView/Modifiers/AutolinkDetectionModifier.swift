//
//  AutolinkDetectionModifier.swift
//  MarkdownView
//

import SwiftUI

extension View {
    /// Toggles automatic detection of bare URLs and email addresses inside
    /// rendered Markdown text. When enabled (the default), text spans that
    /// look like links — e.g. `https://example.com`, `www.apple.com`,
    /// `user@host.com` — are styled and made tappable even though the source
    /// did not wrap them in `<...>` or `[text](url)`. Inline code, code blocks,
    /// and explicit Markdown links are untouched.
    nonisolated public func markdownAutolinkDetectionEnabled(_ enabled: Bool) -> some View {
        environment(\.markdownRendererConfiguration.autolinkDetectionEnabled, enabled)
    }
}
