//
//  MarkdownTextShowcasePreview.swift
//  MarkdownTextKit
//
//  仅用于在 Xcode Canvas 验证「完整富渲染 + 可选中」的全特性 preview。
//  独立于 3.0 原版文件(便于后续与 upstream 同步)。
//

#if canImport(RichText) && DEBUG
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
#Preview("MarkdownText 全特性富渲染") {
    // ForkParity:开启 `==高亮==`(魔改特性,app 启动时注入;此处为 preview 模拟)
    MarkdownHighlightSyntax.isEnabled = true
    MarkdownHighlightSyntax.backgroundColor = Color.yellow.opacity(0.35)
    return ScrollView {
        MarkdownText(
            #"""
            # 一级标题 H1
            ## 二级标题 H2

            普通段落:**加粗**、*斜体*、~~删除线~~、`inline code`、
            以及[一个链接](https://flowith.net)。

            行内高亮:这是 ==被高亮标注的文本== 示例(`==高亮==` 是 3.0 没有、魔改特有的语法)。

            > 这是引用块,应当有富样式(左侧竖线 / 背景),而不是纯文本。

            - 无序列表项 A
            - 无序列表项 B
                - 嵌套项

            1. 有序列表项 1
            2. 有序列表项 2

            ```swift
            // 代码块应当有语法高亮
            func greet(_ name: String) {
                print("Hello, \(name)")
            }
            ```

            | 列 A | 列 B | 列 C |
            |------|------|------|
            | 1    | 2    | 3    |
            | foo  | bar  | baz  |

            行内公式 $E = mc^2$,以及独立公式:

            $$\int_0^1 x^2 \, dx = \frac{1}{3}$$

            ---

            结尾段落 —— 试试长按选中并跨段落连续拖选。
            """#
        )
        .padding()
    }
}
#endif
