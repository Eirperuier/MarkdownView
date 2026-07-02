//
//  SelectableLinkChipView.swift
//  MarkdownView
//
//  可选中渲染路径的链接引用 chip 托管视图(InlineView attachment 的 rootView)。
//  视觉对齐原版 iOS18 的统一胶囊样式(icon + label + "+N",Capsule 灰底);
//  图标走原版同一组外部自定义钩子(MarkdownLinkChips.iconImage/placeholderIcon/prefetchIcon),
//  favicon 载入后 app bump iconRevision(@Observable)→ 本视图自动重渲换真图。
//  reveal 用 streamingRevealFadeIn gate(与 marker/代码块同管线):frontier 越过
//  markdownTextOffsetBase(chip 的 plain 锚点,由 visitor 注入)即整体原子淡入。
//

#if canImport(RichText) && canImport(UIKit)
import SwiftUI

@available(iOS 17.0, *)
struct SelectableLinkChipView: View {
    let label: String
    let urls: [String]

    /// 由 visitor 经 injectRevealEnvironment 显式注入(hosting 边界不继承外层环境)。
    /// 点击抛合成 URL(flowith-linkchip://chip?u=…),app 的 OpenURLAction 按 scheme 拦截开 sheet —— 与原版 Text 路径 .link 同语义。
    @Environment(\.openURL) private var openURL

    /// favicon 的缓存 key:工具引用用完整 url(app 按 scheme 解析工具图标),网页用 host。
    /// 同原版 chipRun 的 host 规则。
    private var iconHost: String {
        guard let first = urls.first else { return "" }
        if first.lowercased().hasPrefix("\(MarkdownLinkChips.toolScheme)://") { return first }
        return URL(string: first)?.host() ?? first
    }

    var body: some View {
        // 读 revision 注册 @Observable 依赖:favicon 载入 bump 后自动重渲。
        let _ = MarkdownLinkChips.iconRevision.value
        HStack(spacing: 3) {
            iconView
                .frame(width: 11, height: 11)
            Text(label.count > 28 ? String(label.prefix(27)) + "…" : label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if urls.count > 1 {
                Text("+\(urls.count - 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 7)
        // 定高压进正文行盒(body 17pt 行高 ~20.3):attachment 超高会撑大整行行距。
        .frame(height: 18)
        .background(Capsule().fill(Color.gray.opacity(0.1)))
        .contentShape(Capsule())
        .onTapGesture {
            if let url = MarkdownLinkChips.chipURL(for: urls) {
                openURL(url)
            }
        }
        .streamingRevealFadeIn()
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = MarkdownLinkChips.iconImage?(iconHost) {
            image
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else if let placeholder = MarkdownLinkChips.placeholderIcon?() {
            let _ = MarkdownLinkChips.prefetchIcon?(iconHost)
            placeholder
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        } else {
            let _ = MarkdownLinkChips.prefetchIcon?(iconHost)
            Image(systemName: "globe")
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
