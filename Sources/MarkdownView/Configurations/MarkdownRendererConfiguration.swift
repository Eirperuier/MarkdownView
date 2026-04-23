//
//  MarkdownRendererConfiguration.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2024/12/11.
//

import Foundation
import SwiftUI

struct MarkdownRendererConfiguration: Equatable, AllowingModifyThroughKeyPath, Sendable {
    var preferredBaseURL: URL?
    var componentSpacing: CGFloat = 10
    
    var math: Math = Math()
    var table: Table = Table()
    
    var linkTintColor: Color = .blue
    var inlineCodeTintColor: Color = .gray
    var blockQuoteTintColor: Color = .accentColor
    var preferredColor: Color = .accentColor
    
    var showFullCode: Bool = false
    
    var listConfiguration: MarkdownListConfiguration = MarkdownListConfiguration()
    
    var allowedImageRenderers: Set<String> = ["https", "http"]
    var allowedBlockDirectiveRenderers: Set<String> = []
    
    var highlightedStrings: [String] = []
    var highlightedColor: Color = .white
    var highlightedBackgroundColor: Color = .yellow

    /// Lightweight fingerprint for node-level cache keys.
    /// Captures the fields most likely to affect block-level rendering.
    var stableFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(preferredBaseURL)
        hasher.combine(componentSpacing)
        hasher.combine(showFullCode)
        hasher.combine(math)
        hasher.combine(table.scrollable)
        hasher.combine(table.cellMaxWidth)
        hasher.combine(listConfiguration)
        hasher.combine(allowedImageRenderers)
        hasher.combine(allowedBlockDirectiveRenderers)
        hasher.combine(highlightedStrings)
        hasher.combine(linkTintColor.description)
        hasher.combine(inlineCodeTintColor.description)
        hasher.combine(blockQuoteTintColor.description)
        hasher.combine(preferredColor.description)
        hasher.combine(highlightedColor.description)
        hasher.combine(highlightedBackgroundColor.description)
        return hasher.finalize()
    }
}

// MARK: - Table Configuration

extension MarkdownRendererConfiguration {
    /// Configuration for markdown table rendering.
    struct Table: Equatable, Sendable {
        /// Whether the table should be horizontally scrollable.
        var scrollable: Bool = false
        
        /// The maximum width for each table cell when scrollable is enabled.
        var cellMaxWidth: CGFloat = 300
    }
}

// MARK: - SwiftUI Environment

struct MarkdownRendererConfigurationKey: EnvironmentKey {
    static let defaultValue: MarkdownRendererConfiguration = .init()
}

extension EnvironmentValues {
    var markdownRendererConfiguration: MarkdownRendererConfiguration {
        get { self[MarkdownRendererConfigurationKey.self] }
        set { self[MarkdownRendererConfigurationKey.self] = newValue }
    }
}

// MARK: - Streaming Environment (kept separate to avoid cache invalidation)

/// Holds the character-by-character reveal count for streaming text.
/// Driven externally by `StreamingRevealCoordinator`.
/// When not injected into the environment (nil), `_MarkdownText` shows full text.
@Observable @MainActor
public final class StreamingRevealManager {
    public var revealedCount: Int = 0
    public init() {}
}

struct MarkdownStreamingKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: StreamingRevealManager? = nil
}

extension EnvironmentValues {
    var markdownStreaming: StreamingRevealManager? {
        get { self[MarkdownStreamingKey.self] }
        set { self[MarkdownStreamingKey.self] = newValue }
    }
}

// MARK: - Fade Reveal Configuration

public struct MarkdownFadeRevealConfig: Equatable, Sendable {
    public var duration: TimeInterval
    public var highlightColor: Color

    public init(duration: TimeInterval = 0.4, highlightColor: Color = .accentColor) {
        self.duration = duration
        self.highlightColor = highlightColor
    }
}

struct MarkdownFadeRevealKey: EnvironmentKey {
    static let defaultValue: MarkdownFadeRevealConfig? = nil
}

extension EnvironmentValues {
    var markdownFadeReveal: MarkdownFadeRevealConfig? {
        get { self[MarkdownFadeRevealKey.self] }
        set { self[MarkdownFadeRevealKey.self] = newValue }
    }
}

extension View {
    /// Enable per-character fade-in animation during streaming reveal.
    /// Requires iOS 18+; on older OS this is a no-op.
    nonisolated public func markdownFadeReveal(
        duration: TimeInterval = 0.4,
        highlightColor: Color = .accentColor
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(duration: duration, highlightColor: highlightColor)
        )
    }
}
