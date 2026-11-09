import MarkdownCore
import SwiftUI

/// 表头括号降级:把表头单元格中 `(...)` / `（...）` 连同括号本身改成更小一号
/// 的字体 + `.secondary` 色,使 "Price (USD)" 这类标注从主标题里退到次级。
/// 在 attributed string 层打属性,因此自然走 reveal / 字体 / 换行管线。
enum MarkdownTableHeaderStyling {
    /// 给所有顶层 `(...)` / `（...）` 区间(含括号)套上 font + color。
    /// 支持嵌套:按深度匹配,只在回到深度 0 时收口一个完整区间。
    static func dimmingParentheticals(
        _ attributed: AttributedString,
        font: Font,
        color: Color
    ) -> AttributedString {
        var result = attributed
        let plain = String(attributed.characters)
        for range in MarkdownTableParentheticals.ranges(in: plain) {
            let start = attributed.characters.index(attributed.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let end = attributed.characters.index(start, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            result[start..<end].font = font
            result[start..<end].foregroundColor = color
        }
        return result
    }
}

// MARK: - Environment

struct MarkdownTableHeaderDimsParentheticalsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 表头括号降级开关。app 经 `markdownTableHeaderDimsParentheticals()` 打开。
    var markdownTableHeaderDimsParentheticals: Bool {
        get { self[MarkdownTableHeaderDimsParentheticalsKey.self] }
        set { self[MarkdownTableHeaderDimsParentheticalsKey.self] = newValue }
    }
}

public extension View {
    /// 开启表头 `(...)` 降级渲染(更小字体 + secondary 色)。
    nonisolated func markdownTableHeaderDimsParentheticals(_ enabled: Bool = true) -> some View {
        environment(\.markdownTableHeaderDimsParentheticals, enabled)
    }
}
