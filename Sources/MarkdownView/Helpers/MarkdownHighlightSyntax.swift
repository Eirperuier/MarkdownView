import SwiftUI

/// `==高亮==` 行内语法(扩展 Markdown 的 mark)。cmark 不认 `==`,所以在文本层处理:
/// - reveal 计数(`MarkdownRevealPlainText`)与显示(`_MarkdownText.prepareDisplayText`)
///   **都**去掉两侧 `==` 定界符,只留内部文本 —— 两处用同一个 `matchOffsets` 匹配器,
///   字符数严格一致,reveal frontier 不会因删定界符而错位。
/// - 内部文本套 `backgroundColor`(+ 可选 `foregroundColor`),走普通 attributed run,
///   因此自然参与 reveal / 字体 / 换行。
///
/// app 启动时置 `isEnabled` + 颜色启用;关闭时 `==` 原样保留、不处理。
public enum MarkdownHighlightSyntax {
    nonisolated(unsafe) public static var isEnabled = false
    /// 高亮底色(主题色按明暗混合后的实心色),nil 时不画底。
    nonisolated(unsafe) public static var backgroundColor: Color?
    /// 高亮文字色,nil 时沿用上下文前景。
    nonisolated(unsafe) public static var foregroundColor: Color?

    /// 一个 `==…==` 匹配的字符偏移:`start..<innerStart` 与 `innerEnd..<end` 是两侧
    /// 定界符,`innerStart..<innerEnd` 是要高亮的内部文本。
    struct Match {
        let start: Int
        let innerStart: Int
        let innerEnd: Int
        let end: Int
    }

    /// 扫描出所有顶层 `==非空文本==`(内部不含换行;`====` 空内容跳过)。
    static func matchOffsets(_ string: String) -> [Match] {
        guard isEnabled else { return [] }
        let chars = Array(string)
        let n = chars.count
        var matches: [Match] = []
        var i = 0
        while i < n {
            // 开定界符 "==",且不是 "===" 的一部分。
            guard chars[i] == "=", i + 1 < n, chars[i + 1] == "=",
                  !(i > 0 && chars[i - 1] == "="),
                  !(i + 2 < n && chars[i + 2] == "=") else {
                i += 1
                continue
            }
            let innerStart = i + 2
            var j = innerStart
            var closed = false
            while j < n {
                if chars[j] == "\n" { break }
                if chars[j] == "=", j + 1 < n, chars[j + 1] == "=" {
                    if j > innerStart {
                        matches.append(Match(start: i, innerStart: innerStart, innerEnd: j, end: j + 2))
                        i = j + 2
                        closed = true
                        break
                    } else {
                        j += 2  // "====" 空内容,跳过
                        continue
                    }
                }
                j += 1
            }
            if !closed { i += 1 }
        }
        return matches
    }

    /// reveal 计数用:去掉定界符,只留内部文本(+ 匹配外的原文)。
    static func strippedPlainText(_ string: String) -> String {
        let matches = matchOffsets(string)
        guard !matches.isEmpty else { return string }
        let chars = Array(string)
        var result = ""
        var cursor = 0
        for m in matches {
            if m.start > cursor { result += String(chars[cursor..<m.start]) }
            result += String(chars[m.innerStart..<m.innerEnd])
            cursor = m.end
        }
        if cursor < chars.count { result += String(chars[cursor...]) }
        return result
    }

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

    private static func characterRange(
        in attributed: AttributedString,
        from start: Int,
        to end: Int
    ) -> Range<AttributedString.Index>? {
        let chars = attributed.characters
        guard let lower = chars.index(chars.startIndex, offsetBy: start, limitedBy: chars.endIndex),
              let upper = chars.index(chars.startIndex, offsetBy: end, limitedBy: chars.endIndex)
        else { return nil }
        return lower..<upper
    }
}
