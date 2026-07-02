//
//  SelectableBlockQuote.swift
//  MarkdownView
//
//  顶层引用块的可选中版本:装饰结构**逐行照抄 DefaultBlockQuoteView**(同一段 SwiftUI 代码,
//  padding 8/20、tint 0.1 全宽底色、4pt 左条、圆角 3、decorationVisible 原子淡入),
//  内容槽换成 MarkdownSelectableText(内部黑白覆写,同魔改引用块语义)。
//  输入是引用块的 sourceText("> …" 形式),内部剥掉行首引用标记后作为独立 markdown 渲染。
//

#if canImport(RichText)
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
public struct SelectableBlockQuote: View {
    private let innerMarkdown: String

    @Environment(\.markdownFontGroup.blockQuote) private var font
    @Environment(\.markdownRendererConfiguration.blockQuoteTintColor) private var tint
    @Environment(\.markdownTextOffsetBase) private var offsetBase
    @State private var decorationHeight: CGFloat?

    /// - Parameter quoteSource: 引用块源码("> …" 形式);逐行剥 `>` 标记得到内部 markdown。
    public init(quoteSource: String) {
        self.innerMarkdown = Self.strippingQuoteMarkers(quoteSource)
    }

    private func decorationVisible(revealCount: Int?) -> Bool {
        revealCount.map { $0 > offsetBase } ?? true
    }

    public var body: some View {
        StreamingRevealCountReader { _, revealCount in
            let visible = decorationVisible(revealCount: revealCount)
            MarkdownSelectableText(innerMarkdown)
                // 引用块内部黑白(同魔改覆写:不带 theme 色)。
                .preferredColor(.primary)
                .tint(.primary, for: .link)
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

    /// 逐行剥引用标记(`>` 可带至多 3 空格缩进、后随可选空格),嵌套 `> >` 只剥一层。
    private static func strippingQuoteMarkers(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { line -> String in
                var s = Substring(line)
                var indent = 0
                while indent < 3, s.first == " " { s = s.dropFirst(); indent += 1 }
                guard s.first == ">" else { return line }
                s = s.dropFirst()
                if s.first == " " { s = s.dropFirst() }
                return String(s)
            }
            .joined(separator: "\n")
    }
}
#endif
