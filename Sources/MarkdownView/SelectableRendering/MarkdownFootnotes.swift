import SwiftUI

extension View {
    /// 当前块的脚注上下文(按块注入;nil = 不做脚注变换)。仅可选中渲染路径消费。
    nonisolated public func markdownFootnotes(_ footnotes: MarkdownFootnotes?) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.footnotes = footnotes
        }
    }
}
