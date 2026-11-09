//
//  RelativePathMarkdownImageRenderer.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2024/12/11.
//

import MarkdownCore
import SwiftUI

/// A markdown image renderer that loads a remote image from a relative url.
struct RelativePathMarkdownImageRenderer: MarkdownImageRenderer {
    var baseURL: URL
    
    func makeBody(configuration: Configuration) -> some View {
        let (url, alt) = (configuration.url, configuration.alternativeText)
        return NetworkImage(url: MarkdownImageSource.resolved(url, against: baseURL), alt: alt)
    }
}

extension MarkdownImageRenderer where Self == RelativePathMarkdownImageRenderer {
    static func relativePathImage(baseURL: URL) -> RelativePathMarkdownImageRenderer {
        RelativePathMarkdownImageRenderer(baseURL: baseURL)
    }
}
