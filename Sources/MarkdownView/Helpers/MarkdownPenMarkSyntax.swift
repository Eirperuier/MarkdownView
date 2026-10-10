import SwiftUI
#if canImport(RichText)
import RichText
#endif

/// `:name[内容]` 行内指令语法(remark-directive 风格)—— 手绘笔迹注记层。
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
/// 渲染:内部文本打 `MarkdownPenMarkAttribute`(kind),正常参与 reveal / 字体 / 换行;
/// 笔迹本身由 TextRenderer 层(PenMarkPainter)在文字之上绘制 —— 流式中文字逐字出现,
/// 该 span **末字符**过 frontier 后笔迹整体淡入,像写完字才落笔画圈。
public enum MarkdownPenMarkSyntax {
    /// 默认关闭,app 启动时打开(与 MarkdownHighlightSyntax 同步)。
    nonisolated(unsafe) public static var isEnabled = false

    /// 注册名表 = 白名单。新增笔迹 = 加 kind + PenMarkPainter 加绘制分支。
    public enum Kind: String, CaseIterable, Sendable {
        case circle // 手绘圈画
        case wavy   // 手绘波浪下划线
    }

    /// 内容长度上限(字符)。圈画是词级注记,超长不匹配 —— 语法层挡掉"圈整段"。
    static let maxInnerLength = 40

    struct Match {
        let start: Int
        let innerStart: Int
        let innerEnd: Int
        /// 含可选 `{…}` 属性块的整体终点。
        let end: Int
        let kind: Kind
        /// `{color=…}` 的颜色 token(named / #hex),nil = 默认红笔。
        let color: String?
        /// 笔迹抖动 seed = 内容 FNV 哈希:同一段文字两条管线/多次重排永远同一笔迹
        /// (字符位置做 seed 会因两管线坐标系不同而画出不同的圈)。
        let seed: Double
    }

    /// 内容 → 确定性 seed(FNV-1a;不用 Hasher —— 它每次启动随机盐)。
    /// 取模压到小值:penNoise 里 seed 参与 sin 相位,过大丢精度。
    static func contentSeed(_ text: String) -> Double {
        var hash: UInt32 = 2166136261
        for byte in text.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return Double(hash % 10_000)
    }

    /// 扫描 `:name[非空内容]{可选属性}`(同行、白名单名、长度受限;
    /// 属性块 = remark 指令的 `{key=value}` 扩展位,当前只认 `color`)。
    static func matchOffsets(_ string: String) -> [Match] {
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
                            color: attrs?.color,
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

    /// `]` 之后紧贴的 `{…}` 属性块:同行闭合、长度受限,解析 `color=<token>`。
    /// 不合法(无 `{`/未闭合/超长)→ nil,`{…}` 保留为正文。
    private static func parseAttributeBlock(_ chars: [Character], after index: Int) -> (end: Int, color: String?)? {
        let n = chars.count
        guard index < n, chars[index] == "{" else { return nil }
        var k = index + 1
        while k < n, k - index <= 48 {
            if chars[k] == "\n" { return nil }
            if chars[k] == "}" {
                let body = String(chars[(index + 1)..<k])
                var color: String?
                for pair in body.split(separator: " ") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "color" {
                        let token = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
                        if !token.isEmpty { color = token }
                    }
                }
                return (end: k + 1, color: color)
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

    /// 显示用:内容打 kind 属性、删定界符。先打属性、再从尾部删,与高亮同套路。
    static func applied(to attributed: AttributedString) -> AttributedString {
        let source = String(attributed.characters)
        let matches = matchOffsets(source)
        guard !matches.isEmpty else { return attributed }

        var result = attributed
        for m in matches {
            guard let range = characterRange(in: result, from: m.innerStart, to: m.innerEnd) else { continue }
            result[range][MarkdownPenMarkAttribute.self] =
                encodeAttributeValue(kind: m.kind, color: m.color, seed: m.seed)
        }
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

    /// 可选中管线(UITextView)形态:同样剥定界符,kind 打 RichText scope 的
    /// PenMarkAttribute(scope 内的键才会桥接进 textStorage),笔迹由
    /// SelectablePenMarkOverlay 按 storage range 定位绘制。
    static func appliedSelectable(to attributed: AttributedString) -> AttributedString {
        let source = String(attributed.characters)
        let matches = matchOffsets(source)
        guard !matches.isEmpty else { return attributed }

        var result = attributed
        for m in matches {
            guard let range = characterRange(in: result, from: m.innerStart, to: m.innerEnd) else { continue }
            #if canImport(RichText)
            result[range][AttributeScopes.RichTextAttributes.PenMarkAttribute.self] =
                encodeAttributeValue(kind: m.kind, color: m.color, seed: m.seed)
            #endif
        }
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

    /// run 属性值编码:`kind|colorToken|seed`(color 可空;桥进 NSAttributedString
    /// 只能是简单值,两侧用 decodeAttributeValue 解)。
    static func encodeAttributeValue(kind: Kind, color: String?, seed: Double) -> String {
        "\(kind.rawValue)|\(color ?? "")|\(Int(seed))"
    }

    static func decodeAttributeValue(_ value: String) -> (kind: Kind, color: String?, seed: Double)? {
        let parts = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard let first = parts.first, let kind = Kind(rawValue: String(first)) else { return nil }
        let color = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        let seed = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
        return (kind, color, seed)
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

/// 标记 run 属于某个笔迹注记,值 = Kind.rawValue。文本本身照常渲染/换行/reveal,
/// 笔迹由 TextRenderer 按此定位绘制。
public enum MarkdownPenMarkAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "MarkdownPenMark"
}

extension AttributedString {
    /// 是否含笔迹注记 run(渲染分支据此挂 TextRenderer)。
    var hasPenMark: Bool {
        runs.contains { $0[MarkdownPenMarkAttribute.self] != nil }
    }
}

// MARK: - 笔迹绘制(iOS 18+ TextRenderer 层)

/// Text.Layout run 上的笔迹标记(TextAttribute 实例带 kind + 颜色 token,
/// PenMarkPainter 从 run 读回实例取值)。
@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
struct PenMarkTextAttribute: TextAttribute {
    let kind: MarkdownPenMarkSyntax.Kind
    let colorToken: String?
    /// 内容哈希 seed(MarkdownPenMarkSyntax.contentSeed):跨管线/重排稳定。
    let seed: Double
}

/// 与 app 侧 HandDrawnAccents.handDrawnNoise 同款三层正弦伪噪声
///(此处是包内绘制层的本地副本,参数一致,同 seed 同笔迹)。
private func penNoise(_ t: Double, seed: Double) -> Double {
    sin(t * 3.1 + seed * 12.9) * 0.55
        + sin(t * 7.3 + seed * 4.7) * 0.3
        + sin(t * 13.7 + seed * 7.1) * 0.15
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
enum PenMarkPainter {
    static let lineWidth: CGFloat = 1.8

    /// 笔迹越出文字排版框的绘制余量(圈画外扩 5 + 收尾渐松 + 波浪下探 + 线宽)。
    /// SwiftUI 把 TextRenderer 的绘制裁到 Text bounds + displayPadding —— 含笔迹的
    /// 文本必须上报这个余量,否则行首/行尾/首末行的笔迹被切。
    static let displayPadding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)

    /// 与其他来源的 displayPadding(如 CJK 斜体)合并:逐边取最大。
    static func mergedDisplayPadding(_ base: EdgeInsets, hasPenMark: Bool) -> EdgeInsets {
        guard hasPenMark else { return base }
        return EdgeInsets(
            top: max(base.top, displayPadding.top),
            leading: max(base.leading, displayPadding.leading),
            bottom: max(base.bottom, displayPadding.bottom),
            trailing: max(base.trailing, displayPadding.trailing)
        )
    }

    struct Span {
        let charRange: Range<Int>
        let rect: CGRect
        let kind: MarkdownPenMarkSyntax.Kind
        let colorToken: String?
        let seed: Double
    }

    /// 扫描一行,把相邻同标记(kind+色+seed)的笔迹 run 合并成 span(与 ChipCapsulePainter 同构)。
    static func spans(in line: Text.Layout.Line, startingCharIndex: Int) -> [Span] {
        var spans: [Span] = []
        var charIdx = startingCharIndex
        var current: (start: Int, rect: CGRect, mark: PenMarkTextAttribute)?

        func flush(at index: Int) {
            if let existing = current {
                spans.append(Span(
                    charRange: existing.start..<index,
                    rect: existing.rect,
                    kind: existing.mark.kind,
                    colorToken: existing.mark.colorToken,
                    seed: existing.mark.seed
                ))
                current = nil
            }
        }

        for run in line {
            if let mark = run[PenMarkTextAttribute.self] {
                let rect = run.typographicBounds.rect
                if let existing = current,
                   existing.mark.kind == mark.kind,
                   existing.mark.colorToken == mark.colorToken,
                   existing.mark.seed == mark.seed {
                    current = (existing.start, existing.rect.union(rect), mark)
                } else {
                    flush(at: charIdx)
                    current = (charIdx, rect, mark)
                }
            } else {
                flush(at: charIdx)
            }
            charIdx += run.count
        }
        flush(at: charIdx)
        return spans
    }

    /// 颜色 token → 笔色(named 色板 / #hex,默认红笔;统一 0.72 透明度保持"笔"感)。
    /// `accent` 用 SwiftUI accentColor(GraphicsContext 按环境解析)。
    static func ink(for token: String?) -> Color {
        let base: Color
        switch token {
        case "blue": base = .blue
        case "green": base = .green
        case "orange": base = .orange
        case "purple": base = .purple
        case "gray", "grey": base = .gray
        case "accent": base = .accentColor
        case let hex? where hex.hasPrefix("#"):
            base = Self.hexColor(hex) ?? .red
        case let name?:
            base = MarkdownColorToken.text(name) ?? .red
        default: base = .red
        }
        return base.opacity(0.72)
    }

    static func hexColor(_ token: String) -> Color? {
        var hex = String(token.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// 画笔迹。seed = 内容哈希(随 span 携带)—— 同一段文字跨管线/重排永远同一笔迹。
    static func draw(_ span: Span, opacity: Double, in ctx: inout GraphicsContext) {
        guard opacity > 0 else { return }
        let seed = span.seed
        var path = Path()
        switch span.kind {
        case .wavy:
            // 贴 baseline 下方的波浪线(参数对齐 app 侧 handDrawnUnderline)。
            let y0 = span.rect.maxY + 1.5
            var x = span.rect.minX
            var first = true
            while x <= span.rect.maxX {
                let y = y0 + 1.4 * sin(x / 9 * 2 * .pi + seed)
                    + 0.7 * penNoise(Double(x) / 6, seed: seed)
                if first { path.move(to: CGPoint(x: x, y: y)); first = false }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 2.5
            }
        case .circle:
            // 手绘椭圆(参数对齐 app 侧 HandDrawnEllipseShape):左上起笔、
            // 一圈多 ~40° 重叠、半径抖动且越画越松。外扩把字包进去。
            let rect = span.rect.insetBy(dx: -5, dy: -2.5)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let a = rect.width / 2
            let b = rect.height / 2
            let start = -Double.pi * 0.75
            let end = start + 2 * .pi + .pi * 0.22
            let samples = 84
            for i in 0...samples {
                let progress = Double(i) / Double(samples)
                let t = start + (end - start) * progress
                let radiusScale = 1
                    + 0.045 * penNoise(t * 1.9, seed: seed)
                    + 0.06 * progress
                let point = CGPoint(
                    x: center.x + a * radiusScale * CGFloat(cos(t)),
                    y: center.y + b * radiusScale * CGFloat(sin(t))
                )
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        ctx.stroke(
            path,
            with: .color(ink(for: span.colorToken).opacity(opacity)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }
}
