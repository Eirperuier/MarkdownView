//
//  CmarkFirstMarkdownViewRenderer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/12.
//

import SwiftUI
import Markdown

struct CmarkFirstMarkdownViewRenderer: MarkdownViewRenderer {
    func makeBody(
        content: MarkdownContent,
        configuration: MarkdownRendererConfiguration
    ) -> some View {
        _makeAndCacheBody(
            content: content,
            configuration: configuration
        )
        
    }
    
    private func _makeAndCacheBody(
        content: MarkdownContent,
        configuration: MarkdownRendererConfiguration
    ) -> some View {
        if let cached = CacheStorage.shared.withCacheIfAvailable(
            content,
            type: Cache.self
        ), cached.configuration == configuration {
            return AnyView(cached.renderedView)
            
        }
        
        let parseOptions = content.parseOptions(
            allowingBlockDirectives: !configuration.allowedBlockDirectiveRenderers.isEmpty
        )
        
        let document = content.parse(options: parseOptions)
        let configFingerprint = configuration.stableFingerprint
        let nodeCache = NodeViewCache.shared

        var visitor = CmarkNodeVisitor(configuration: configuration)
        var nodeViews = [MarkdownNodeView]()
        nodeViews.reserveCapacity(document.childCount)

        for child in document.children {
            let hash = child.stableContentHash
            let cacheKey = NodeCacheKey(contentHash: hash, configurationHash: configFingerprint)

            if let cached = nodeCache.get(cacheKey) {
                nodeViews.append(cached)
            } else {
                let rendered = visitor.visit(child)
                nodeCache.set(cacheKey, view: rendered)
                nodeViews.append(rendered)
            }
        }

        let composedView = MarkdownNodeView(nodeViews, layoutPolicy: .linebreak)
        let renderedView = composedView
            .environment(\.markdownRendererConfiguration, configuration)
            .erasedToAnyView()
        
        CacheStorage.shared.addCache(
            Cache(
                markdownContent: content,
                configuration: configuration,
                renderedView: renderedView
            )
        )
        
        return renderedView
    }
}

extension CmarkFirstMarkdownViewRenderer {
    struct Cache: Cacheable {
        var markdownContent: MarkdownContent
        var configuration: MarkdownRendererConfiguration
        var renderedView: any View
        
        var cacheKey: some Hashable { markdownContent }
    }
}
