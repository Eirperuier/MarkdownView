//
//  MarkdownCodeBlockReplacement.swift
//  MarkdownView
//
//  Lets a host edit a code block in place: its view (an editor) goes where the code
//  lines are, inside the block's own header, background and corners.
//

import SwiftUI

struct MarkdownCodeBlockReplacementKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> AnyView?)? = nil
}

extension EnvironmentValues {
    var markdownCodeBlockReplacement: (@MainActor () -> AnyView?)? {
        get { self[MarkdownCodeBlockReplacementKey.self] }
        set { self[MarkdownCodeBlockReplacementKey.self] = newValue }
    }
}

extension View {
    /// A view to show instead of the code lines of code blocks (nil keeps them).
    public func markdownCodeBlockReplacement(_ replacement: @escaping @MainActor () -> AnyView?) -> some View {
        environment(\.markdownCodeBlockReplacement, replacement)
    }
}
