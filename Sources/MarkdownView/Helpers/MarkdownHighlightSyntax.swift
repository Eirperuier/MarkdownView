import SwiftUI

extension MarkdownHighlightSyntax {
    /// 高亮底色(主题色按明暗混合后的实心色),nil 时不画底。
    nonisolated(unsafe) public static var backgroundColor: Color?
    /// 高亮文字色,nil 时沿用上下文前景。
    nonisolated(unsafe) public static var foregroundColor: Color?

    /// 显示用:给内部文本套底色/前景,删除两侧定界符。先打属性、再从尾部删定界符,
    /// 这样删除引起的索引位移不影响尚未处理的靠前匹配。
    static func applied(to attributed: AttributedString) -> AttributedString {
        let source = String(attributed.characters)
        let matches = matchOffsets(source)
        guard !matches.isEmpty else { return attributed }

        var result = attributed
        // 1) 先给所有内部区间打属性(此时未删除,offset 仍有效)。
        for m in matches {
            guard let range = characterRange(in: result, from: m.innerStart, to: m.innerEnd) else { continue }
            if let bg = backgroundColor { result[range].backgroundColor = bg }
            if let fg = foregroundColor { result[range].foregroundColor = fg }
        }
        // 2) 从后往前删两侧定界符,避免位移影响靠前匹配。
        for m in matches.reversed() {
            if let close = characterRange(in: result, from: m.innerEnd, to: m.end) {
                result.removeSubrange(close)
            }
            if let open = characterRange(in: result, from: m.start, to: m.innerStart) {
                result.removeSubrange(open)
            }
        }
        return result
    }
}
