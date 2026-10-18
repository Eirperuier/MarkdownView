//
//  MarkdownBlockQuoteDecoration.swift
//  MarkdownView
//
//  A block quote's look round text that may or may not be a quote (an editor's block,
//  whose kind changes): SelectableBlockQuote's colours and decoration (padding 8/20, a
//  0.1 tint ground, a 4 pt bar at its edge, corners of 3), laid out the same whether
//  it's on or off. A block that becomes a quote keeps its view, and its text view, and
//  goes to the quote's shape with the change's animation.
//

#if canImport(RichText)
import SwiftUI

extension View {
    /// The block quote's look when `isOn`, nothing when not; the view stays the same view.
    public func markdownBlockQuote(_ isOn: Bool) -> some View {
        modifier(MarkdownBlockQuoteDecoration(isOn: isOn))
    }
}

private struct MarkdownBlockQuoteDecoration: ViewModifier {
    let isOn: Bool

    @Environment(\.markdownRendererConfiguration) private var configuration
    private var tint: Color { configuration.painted(configuration.blockQuoteTintColor) }

    func body(content: Content) -> some View {
        content
            // Black and white inside, as SelectableBlockQuote's content.
            .transformEnvironment(\.markdownRendererConfiguration) { [isOn] configuration in
                guard isOn else { return }
                configuration.preferredColor = .primary
                configuration.linkTintColor = .primary
            }
            .padding(.vertical, isOn ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isOn ? 20 : 0)
            // The ground and the bar have the corners; the content isn't clipped.
            .background {
                tint.opacity(isOn ? 0.1 : 0)
                    .overlay(alignment: .leading) {
                        tint.frame(width: 4).opacity(isOn ? 1 : 0)
                    }
                    .clipShape(.rect(cornerRadius: 3))
            }
    }
}
#endif
