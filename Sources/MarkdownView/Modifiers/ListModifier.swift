//
//  ListModifier.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/2/9.
//

import SwiftUI

extension View {
    nonisolated public func markdownListIndent(_ indent: CGFloat) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.listConfiguration.leadingIndentation = indent
        }
    }
    
    nonisolated public func markdownUnorderedListMarker(_ marker: some UnorderedListMarkerProtocol) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.listConfiguration.unorderedListMarker = AnyUnorderedListMarkerProtocol(marker)
        }
    }
    
    nonisolated public func markdownOrderedListMarker(_ marker: some OrderedListMarkerProtocol) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.listConfiguration.orderedListMarker = AnyOrderedListMarkerProtocol(marker)
        }
    }
    
    nonisolated public func markdownComponentSpacing(_ spacing: CGFloat) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.componentSpacing = spacing
        }
    }
    nonisolated public func preferredColor(_ color: Color) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.preferredColor = color
            configuration.linkTintColor = color
        }
    }
    nonisolated public func showFullCodeBlock(_ show: Bool) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.showFullCode = show
        }
    }
    nonisolated public func search(_ texts: [String], foreground: Color, background: Color) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.highlightedStrings = texts
            configuration.highlightedColor = foreground
            configuration.highlightedBackgroundColor = background
        }
    }
    
    @MainActor
    public func markdownStreaming(_ manager: StreamingRevealManager?) -> some View {
        modifier(MarkdownStreamingModifier(manager: manager))
    }

    /// Disable per-character streaming reveal for the wrapped subtree by clearing
    /// the inherited `markdownStreaming` manager.
    nonisolated public func markdownStreamingRevealDisabled() -> some View {
        environment(\.markdownStreaming, nil)
    }


}

private struct MarkdownStreamingModifier: ViewModifier {
    let manager: StreamingRevealManager?

    func body(content: Content) -> some View {
        content
            .environment(\.markdownStreaming, manager)
    }
}
