//
//  BlockQuoteStyle.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/17.
//

import SwiftUI
import Markdown

/// A type that applies a custom style to all block quotes within a MarkdownView.
///
/// Think of this type as a SwiftUI View wrapper.
///
/// Don't directly access view dependencies (e.g. `@Environment`), use a separate view instead.
@preconcurrency
@MainActor
public protocol BlockQuoteStyle {
    /// A view that represents the current block quote.
    associatedtype Body: View
    /// Creates the view that represents the current block quote.
    @preconcurrency
    @MainActor
    @ViewBuilder
    func makeBody(configuration: Configuration) -> Body
    /// The properties of a block quote.
    typealias Configuration = BlockQuoteStyleConfiguration
}

/// The properties of a block quote.
public struct BlockQuoteStyleConfiguration {
    /// The content of a block quote.
    public var content: Content
    
    /// A type-erased content of a block quote
    public struct Content: View {
        private var blockQuote: BlockQuote
        @Environment(\.markdownRendererConfiguration) private var configuration
        @Environment(\.markdownTextOffsetBase) private var offsetBase
        
        init(blockQuote: BlockQuote) {
            self.blockQuote = blockQuote
        }
        
        @_documentation(visibility: internal)
        public var body: some View {
            let children = Array(blockQuote.children)
            let childOffsets = Self.offsets(for: children)

            VStack(alignment: .leading, spacing: configuration.componentSpacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    CmarkNodeVisitor(configuration: configuration)
                        .makeBody(for: child)
                        .environment(\.markdownTextOffsetBase, offsetBase + childOffsets[index])
                }
            }
        }

        private static func offsets(for children: [any Markup]) -> [Int] {
            var result: [Int] = []
            result.reserveCapacity(children.count)
            var runningOffset = 0
            for child in children {
                result.append(runningOffset)
                runningOffset += child.markdownRevealPlainText.count
            }
            return result
        }
    }
}

@available(*, unavailable)
extension BlockQuoteStyleConfiguration: Sendable {
    
}

// MARK: - Environment Value

struct BlockQuoteStyleKey: @preconcurrency EnvironmentKey {
    @MainActor static var defaultValue: any BlockQuoteStyle = DefaultBlockQuoteStyle()
}

extension EnvironmentValues {
    package var blockQuoteStyle: any BlockQuoteStyle {
        get { self[BlockQuoteStyleKey.self] }
        set { self[BlockQuoteStyleKey.self] = newValue }
    }
}
