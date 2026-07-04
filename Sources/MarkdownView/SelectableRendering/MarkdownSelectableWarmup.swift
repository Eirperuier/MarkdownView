//
//  MarkdownSelectableWarmup.swift
//  MarkdownView
//
//  可选中渲染管线的启动预热:首条消息渲染实测有 ~200ms 量级的一次性成本(TextKit 2 栈、
//  SF 标题字号/字重 + CJK fallback 字体缓存、visitor/RichText 首用)。在启动空闲期用一小段
//  覆盖性内容把整条真实链路(render → TextView → TextKit 布局)跑一遍,把冷启从首条消息挪走。
//

#if canImport(UIKit) && canImport(RichText)
import SwiftUI
import UIKit
import RichText

@available(iOS 17.0, *)
@MainActor
public enum MarkdownSelectableWarmup {
    private static var done = false

    /// 覆盖:Extended Heading 对(28 heavy + 22 bold)、正文 CJK 混排、粗斜体(CJK 斜体走
    /// CTFont 矩阵)、行内 code 底色、链接 + autolink(NSDataDetector 首建)、列表 marker、
    /// 行内公式(LaTeX 引擎首渲实测 ~200ms,是冷启最大单项)。
    public static func run() {
        guard !done else { return }
        done = true
        RichTextViewPool.prewarm()
        let sample = #"""
        # 预热标题速览
        # Warm Subtitle Line

        预热正文 body 混排,**加粗 bold**、*斜体 italic*、*预热斜体*、`inline code`、[链接](https://example.com) 与 https://example.com,公式 $E = mc^2$ 与 $\gamma = \frac{1}{\sqrt{1 - x^2}}$ 收尾。

        - 列表项 marker 预热
        """#
        let host = UIHostingController(rootView: MarkdownSelectableText(sample))
        let size = host.sizeThatFits(in: CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
    }
}
#endif
