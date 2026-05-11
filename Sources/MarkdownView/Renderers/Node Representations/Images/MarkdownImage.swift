//
//  MarkdownImage.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/2/22.
//

import Markdown
import SwiftUI

struct MarkdownImage: View {
    var image: Markdown.Image
    private var url: URL? {
        if let source = image.source {
            return URL(string: source)
        }
        return nil
    }
    private var alternativeText: String? {
        if !(image.parent is Markdown.Link) {
            if let title = image.title, !title.isEmpty {
                return title
            } else {
                return image.plainText.isEmpty ? nil : image.plainText
            }
        } else {
            // If the image is inside a link, then ignore the alternative text
            return nil
        }
    }
    @Environment(\.markdownRendererConfiguration.preferredBaseURL) private var baseURL
    @Environment(\.markdownRendererConfiguration.allowedImageRenderers) private var allowedRenderer
    @Environment(\.markdownImageIsInTableCell) private var isInTableCell
    @Environment(\.markdownTableImageRenderer) private var tableImageRenderer
    
    var body: some View {
        Group {
            if let url {
                let configuration = MarkdownImageRendererConfiguration(
                    url: url,
                    alternativeText: alternativeText
                )
                if isInTableCell, let tableImageRenderer {
                    tableImageRenderer
                        .makeBody(configuration: configuration)
                } else if let scheme = url.scheme, allowedRenderer.contains(scheme),
                   let renderer = MarkdownImageRenders.named(scheme) {
                    renderer
                        .makeBody(configuration: configuration)
                        .erasedToAnyView()
                } else if let baseURL {
                    RelativePathMarkdownImageRenderer(baseURL: baseURL)
                        .makeBody(configuration: configuration)
                        .erasedToAnyView()
                } else {
                    fallbackView
                }
            } else {
                fallbackView
            }
        }
        .streamingRevealFadeIn()
    }
    
    private var fallbackView: some View {
        MarkdownNodeView(image.plainText)
    }
}
