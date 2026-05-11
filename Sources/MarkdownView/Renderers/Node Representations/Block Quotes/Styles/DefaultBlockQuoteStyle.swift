//
//  DefaultBlockQuoteStyle.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/17.
//

import SwiftUI

/// Default block quote style that applies to a MarkdownView.
public struct DefaultBlockQuoteStyle: BlockQuoteStyle {
    public func makeBody(configuration: Configuration) -> some View {
        DefaultBlockQuoteView(configuration: configuration)
    }
}

extension BlockQuoteStyle where Self == DefaultBlockQuoteStyle {
    /// Default block quote style.
    static public var `default`: DefaultBlockQuoteStyle { .init() }
}

fileprivate struct DefaultBlockQuoteView: View {
    var configuration: BlockQuoteStyleConfiguration
    @Environment(\.markdownFontGroup.blockQuote) private var font
    @Environment(\.markdownRendererConfiguration.blockQuoteTintColor) private var tint
    @Environment(\.markdownTextOffsetBase) private var offsetBase
    @State private var decorationHeight: CGFloat?

    private func decorationVisible(revealCount: Int?) -> Bool {
        revealCount.map { $0 > offsetBase } ?? true
    }

    var body: some View {
        StreamingRevealCountReader { _, revealCount in
            let visible = decorationVisible(revealCount: revealCount)
            configuration.content
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(font)
                .padding(.horizontal, 20)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    let height = proxy.size.height
                    guard height.isFinite else { return 0 }
                    return (height * 2).rounded() / 2
                } action: { height in
                    updateDecorationHeight(height)
                }
                .background(alignment: .topLeading) {
                    tint.opacity(0.1)
                        .frame(maxWidth: .infinity)
                        .frame(height: decorationHeight)
                        .opacity(visible ? 1 : 0)
                        .animation(.smooth(duration: 0.24), value: decorationHeight)
                        .animation(.easeOut(duration: 0.3), value: visible)
                }
                .overlay(alignment: .topLeading) {
                    tint
                        .frame(width: 4, height: decorationHeight)
                        .opacity(visible ? 1 : 0)
                        .animation(.smooth(duration: 0.24), value: decorationHeight)
                        .animation(.easeOut(duration: 0.3), value: visible)
                }
                .clipShape(.rect(cornerRadius: 3))
        }
    }

    private func updateDecorationHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        if let decorationHeight, abs(decorationHeight - height) < 0.5 {
            return
        }

        decorationHeight = height
    }
}
