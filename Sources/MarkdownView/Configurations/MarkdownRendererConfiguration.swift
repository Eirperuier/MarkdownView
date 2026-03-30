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
