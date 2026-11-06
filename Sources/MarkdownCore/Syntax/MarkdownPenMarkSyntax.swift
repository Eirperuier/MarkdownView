import Foundation

/// `:name[内容]{属性}` 行内指令语法(remark-directive 风格)—— 笔迹注记 / 线条 / 文字色。
/// 与 `==高亮==` 同一套处理哲学(MarkdownHighlightSyntax):cmark 不认,文本层处理,
/// reveal 计数(`MarkdownRevealPlainText`)与显示(`_MarkdownText.prepareDisplayText`)
/// **都**用同一个 `matchOffsets` 匹配器剥定界符,字符数严格一致,frontier 不错位。
///
/// 误触发三重闸:
/// 1. 字形:`:` 后**紧贴**注册名**紧贴** `[`,中间无任何字符;
/// 2. 白名单:名字必须是已注册 kind(`:smile[x]` 原样保留);
/// 3. 结构:同行闭合、内容非空、长度 ≤ maxInnerLength(注记只圈词/短语,不圈整段)。
///
/// 内容限制与 `==` 相同:纯文本、不跨 Markdown.Text 节点(内部不解析嵌套语法)。
///
/// 渲染:`color` 落成普通前景色 run;其余 kind 的内部文本打 `MarkdownPenMarkAttribute`,
/// 正常参与 reveal / 字体 / 换行,笔迹由绘制层按排版结果画(SwiftUI = PenMarkPainter,
/// 可选中 = SelectablePenMarkOverlay,几何同一份 PenMarkGeometry):荧光笔铺在字下,
/// 其余压在字上。流式中该 span **末字符**过 frontier 后笔迹整体淡入,像写完字才落笔。
///
/// 属性块宽松解析:认 `color` / `c`(同义)与 `style`,未知键忽略,值不合法按默认画。
public enum MarkdownPenMarkSyntax {
    /// 默认关闭,app 启动时打开(与 MarkdownHighlightSyntax 同步)。
    nonisolated(unsafe) public static var isEnabled = false

    /// 注册名表 = 白名单。新增笔迹 = 加 kind + PenMarkGeometry 加绘制分支。
    public enum Kind: String, CaseIterable, Sendable {
        case circle // 手绘圈画
        case wavy   // 手绘波浪下划线
        case box    // 手绘方框
        case marker // 荧光笔(铺在字下)
        case u      // 下划线,style = single / thick / double / dot / dash / dashdot / wavy
        case s      // 删除线,style 同上
        case color  // 文字色(普通前景色 run,不走绘制层)

        /// 绘制层:填充铺在字下,线条压在字上。
        package var isUnderlay: Bool { self == .marker }
    }

    /// 内容长度上限(字符)。圈画是词级注记,超长不匹配 —— 语法层挡掉"圈整段"。
    static let maxInnerLength = 40

    package struct Match {
        package let start: Int
        package let innerStart: Int
        package let innerEnd: Int
        /// 含可选 `{…}` 属性块的整体终点。
        package let end: Int
        package let kind: Kind
        /// `{color=…}` / `{c=…}` 的颜色 token(named / 语义 / #hex),nil = 该 kind 的默认色。
        package let color: String?
        /// `{style=…}`(u / s 的线型),nil = single。
        package let style: String?
        /// 笔迹抖动 seed = 内容 FNV 哈希:同一段文字两条管线/多次重排永远同一笔迹
        /// (字符位置做 seed 会因两管线坐标系不同而画出不同的圈)。
        package let seed: Double
    }

    /// 内容 → 确定性 seed(FNV-1a;不用 Hasher —— 它每次启动随机盐)。
    /// 取模压到小值:penNoise 里 seed 参与 sin 相位,过大丢精度。
    package static func contentSeed(_ text: String) -> Double {
        var hash: UInt32 = 2166136261
        for byte in text.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return Double(hash % 10_000)
    }

    /// 扫描 `:name[非空内容]{可选属性}`(同行、白名单名、长度受限;
    /// 属性块 = remark 指令的 `{key=value}` 扩展位)。
    package static func matchOffsets(_ string: String) -> [Match] {
        guard isEnabled, string.contains(":") else { return [] }
        let chars = Array(string)
        let n = chars.count
        var matches: [Match] = []
        var i = 0
        while i < n {
            guard chars[i] == ":" else { i += 1; continue }
            // 避开 "::"(指令块/时间戳等)。
            if i > 0, chars[i - 1] == ":" { i += 1; continue }
            // 名字:紧贴的小写字母串。
            var j = i + 1
            while j < n, chars[j].isLowercase, chars[j].isLetter { j += 1 }
            guard j > i + 1, j < n, chars[j] == "[",
                  let kind = Kind(rawValue: String(chars[(i + 1)..<j]))
            else { i += 1; continue }
            // 内容:同行、非空、长度受限、首个 "]" 闭合。
            let innerStart = j + 1
            var k = innerStart
            var closed = false
            while k < n, k - innerStart <= maxInnerLength {
                if chars[k] == "\n" { break }
                if chars[k] == "]" {
                    if k > innerStart {
                        let attrs = parseAttributeBlock(chars, after: k + 1)
                        matches.append(Match(
                            start: i,
                            innerStart: innerStart,
                            innerEnd: k,
                            end: attrs?.end ?? (k + 1),
                            kind: kind,
                            color: attrs?.values["color"] ?? attrs?.values["c"],
                            style: attrs?.values["style"],
                            seed: contentSeed(String(chars[innerStart..<k]))
                        ))
                        i = attrs?.end ?? (k + 1)
                        closed = true
                    }
                    break
                }
                k += 1
            }
            if !closed { i += 1 }
        }
        return matches
    }

    /// `]` 之后紧贴的 `{…}` 属性块:同行闭合、长度受限,解析空格分隔的 `key=value`
    /// (键值小写、去引号;无 `=` 的片段忽略)。不合法(无 `{`/未闭合/超长)→ nil,`{…}` 保留为正文。
    private static func parseAttributeBlock(_ chars: [Character], after index: Int) -> (end: Int, values: [String: String])? {
        let n = chars.count
        guard index < n, chars[index] == "{" else { return nil }
        var k = index + 1
        while k < n, k - index <= 48 {
            if chars[k] == "\n" { return nil }
            if chars[k] == "}" {
                let body = String(chars[(index + 1)..<k])
                var values: [String: String] = [:]
                for pair in body.split(whereSeparator: { $0 == " " || $0 == "," }) {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = parts[0].lowercased()
                    let value = parts[1]
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                        .lowercased()
                    if !key.isEmpty, !value.isEmpty { values[key] = value }
                }
                return (end: k + 1, values: values)
            }
            k += 1
        }
        return nil
    }

    /// reveal 计数用:去掉 `:name[` 与 `]`,只留内容(+ 匹配外的原文)。
    public static func strippedPlainText(_ string: String) -> String {
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

    /// 解码后的 run 属性值。
    package struct Mark: Hashable, Sendable {
        package let kind: Kind
        package let color: String?
        package let style: String?
        package let seed: Double

        package init(kind: Kind, color: String?, style: String?, seed: Double) {
            self.kind = kind
            self.color = color
            self.style = style
            self.seed = seed
        }
    }

    /// run 属性值编码:`kind|colorToken|seed|style`(color/style 可空;桥进 NSAttributedString
    /// 只能是简单值,两侧用 decodeAttributeValue 解)。
    package static func encodeAttributeValue(_ m: Match) -> String {
        encodeAttributeValue(kind: m.kind, color: m.color, style: m.style, seed: m.seed)
    }

    package static func encodeAttributeValue(kind: Kind, color: String?, style: String? = nil, seed: Double) -> String {
        "\(kind.rawValue)|\(color ?? "")|\(Int(seed))|\(style ?? "")"
    }

    package static func decodeAttributeValue(_ value: String) -> Mark? {
        let parts = value.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard let first = parts.first, let kind = Kind(rawValue: String(first)) else { return nil }
        let color = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        let seed = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
        let style = parts.count > 3 && !parts[3].isEmpty ? String(parts[3]) : nil
        return Mark(kind: kind, color: color, style: style, seed: seed)
    }

    package static func characterRange(
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

/// 标记 run 属于某个笔迹注记,值 = encodeAttributeValue 的编码串。文本本身照常渲染/换行/reveal,
/// 笔迹由 TextRenderer 按此定位绘制。
public enum MarkdownPenMarkAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "MarkdownPenMark"
}

extension AttributedString {
    /// 是否含笔迹注记 run(渲染分支据此挂 TextRenderer)。
    package var hasPenMark: Bool {
        runs.contains { $0[MarkdownPenMarkAttribute.self] != nil }
    }
}
