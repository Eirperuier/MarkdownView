//
//  MarkdownImageRendererModifier.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/2/9.
//

import SwiftUI

extension View {
    /// Use custom renderer to render images.
    ///
    /// - parameter renderer: The render you created to handle image loading and rendering.
    /// - parameter urlScheme: A scheme for deciding which renderer to use.
    nonisolated public func markdownImageRenderer(
        _ renderer: some MarkdownImageRenderer,
        forURLScheme urlScheme: String
    ) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            MarkdownImageRenders.shared.addRenderer(renderer, forURLScheme: urlScheme)
            configuration.allowedImageRenderers.insert(urlScheme)
        }
    }

    /// Registers a custom view-builder for images rendered inside markdown table cells.
    ///
    /// Regular markdown images keep using the normal image renderer path. This
    /// hook is only used when an image appears inside a table cell, where the
    /// caller often needs a compact thumbnail instead of a full-width image.
    nonisolated public func markdownTableImageRenderer<Content: View>(
        @ViewBuilder _ content: @escaping @MainActor @Sendable (_ configuration: MarkdownImageRendererConfiguration) -> Content
    ) -> some View {
        let erased = AnyMarkdownTableImageRenderer { configuration in
            AnyView(content(configuration))
        }
        return environment(\.markdownTableImageRenderer, erased)
    }
}
