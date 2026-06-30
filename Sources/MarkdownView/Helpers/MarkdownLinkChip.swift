import SwiftUI
@preconcurrency import Markdown

/// 标记 chip 的 favicon 占位 run(`\u{FFFC}`),值 = 站点 host;
/// Text 构建时经 `MarkdownLinkChips.iconImage` 换成图标。
public enum MarkdownLinkChipIconAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "MarkdownLinkChipIcon"
}

/// 标记 run 属于某个 chip(含图标/label/+N/内衬全部段)。Text 构建时转成
/// SwiftUI TextAttribute,渲染器据此画统一胶囊背景并整体(原子)显隐。
public enum MarkdownLinkChipSegmentAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "MarkdownLinkChipSegment"
}

/// 行内引用 chip:`[Label](https://… "cite")`(link title 显式标 "cite")渲染成
/// 带底色的可点击小标签;**普通 `[label](url)` 不受影响**,保持原有链接渲染。
/// chip 仍是 attributed run —— 在 `Text` 拼接流里换行、参与 reveal,不引入 Flow 布局。
/// 连续多个引用链接(允许其间纯空白)折叠成一个 "Label +N" chip。
/// 点击经合成的 `flowith-linkchip://chip?u=…` URL 抛给 app 的 OpenURLAction
/// (由 app 决定开 sheet),不直接进 Safari。app 启动时置 `isEnabled` 启用。
public enum MarkdownLinkChips {
    /// 默认关闭,app 启动时打开;关闭时链接维持原有下划线样式。
    nonisolated(unsafe) public static var isEnabled = false

    /// 合成 chip URL 的 scheme,app 侧 OpenURLAction 按它拦截。
    public static let scheme = "flowith-linkchip"

    /// 工具引用 chip 的 target scheme:`[Label](flowith-tool://<tool_result_id>[.<view>|.<N>] "cite")`。
    /// cite 是"最小内联引用",对网页(http/https)与工具(flowith-tool)同构。
    public static let toolScheme = "flowith-tool"

    /// chip 携带的全部目标链接(1 个或折叠的多个)。
    public static func chipURL(for urls: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "chip"
        components.queryItems = urls.map { URLQueryItem(name: "u", value: $0) }
        return components.url
    }

    /// 从 chip URL 还原目标链接;非 chip URL 返回 nil。
    public static func urls(from url: URL) -> [String]? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let urls = items.filter { $0.name == "u" }.compactMap(\.value)
        return urls.isEmpty ? nil : urls
    }

    // MARK: - 渲染

    // MARK: - 图标钩子(app 注入)

    /// 同步取 favicon(命中缓存返回已缩放好的 Image,未命中返回 nil)。key 为站点 host。
    nonisolated(unsafe) public static var iconImage: (@MainActor (_ host: String) -> SwiftUI.Image?)?
    /// favicon 未命中时的占位图。app 应提供与 favicon **同尺寸**的 template 位图,
    /// 使两个分支对齐方式完全一致、替换瞬间不跳。
    nonisolated(unsafe) public static var placeholderIcon: (@MainActor () -> SwiftUI.Image?)?
    /// 异步预取 favicon;载完后 app 应 bump `iconRevision` 触发重渲。
    nonisolated(unsafe) public static var prefetchIcon: (@MainActor (_ host: String) -> Void)?

    /// favicon 载入完成的修订号;含图标 chip 的文本视图观察它以便缓存命中后重建 Text。
    @Observable
    @MainActor
    public final class IconRevision {
        public private(set) var value = 0
        public func bump() { value += 1 }
        nonisolated init() {}
    }
    public static let iconRevision = IconRevision()

    /// chip 的 attributed run,三段:favicon 占位符 + `.secondary` label + 小号 "+N"。
    /// 背景 gray 0.1 落在文本段(图标段是 Text(Image),带不了背景属性;胶囊统一
    /// 背景待 TextRenderer 方案)。全部字符间插 WORD JOINER(U+2060)、空格换
    /// NBSP —— UAX-14 对 WJ 前后都禁断行,整个 chip 是不可分割的排版簇:
    /// 放不下整体换行,绝不从中间断开(CJK label 每字都是断点,必须逐字粘)。
    static func chipRun(label: String, urls: [String], tint: Color) -> AttributedString {
        var displayLabel = label
        if displayLabel.count > 28 {
            displayLabel = String(displayLabel.prefix(27)) + "…"
        }
        let chipURL = chipURL(for: urls)
        let background = Color.gray.opacity(0.1)
        // 工具引用:icon key 用完整 `flowith-tool://…` url(app 据 scheme 解析出工具图标);
        // 网页:用 host(favicon 仍按 host 缓存/去重)。
        let host = urls[0].lowercased().hasPrefix("\(toolScheme)://")
            ? urls[0]
            : (URL(string: urls[0])?.host() ?? urls[0])

        // 左内衬:让图标不顶住胶囊左缘。
        var lead = AttributedString("\u{00A0}\u{2060}")
        lead[MarkdownLinkChipSegmentAttribute.self] = true
        lead.font = .subheadline
        lead.backgroundColor = background
        if let chipURL { lead.link = chipURL }

        // 图标段:占位字符 + host 属性,Text 构建时换成 favicon 图。
        var icon = AttributedString("\u{FFFC}")
        icon[MarkdownLinkChipIconAttribute.self] = host
        icon[MarkdownLinkChipSegmentAttribute.self] = true
        if let chipURL { icon.link = chipURL }

        // label 段:.secondary 前景、比正文小一号。首字符前置 WJ 与图标段粘合。
        var labelRun = AttributedString(unbreakable("\u{2060}\u{00A0}\(displayLabel)"))
        labelRun[MarkdownLinkChipSegmentAttribute.self] = true
        labelRun.font = .subheadline
        labelRun.foregroundColor = .secondary
        labelRun.backgroundColor = background
        if let chipURL { labelRun.link = chipURL }

        // 胶囊前置一个断点(ZWSP):lead 段以 NBSP(\u{00A0},UAX-14 GL 类,禁止前后断行)开头,
        // 否则 chip 会和紧邻的前一个字粘成不可断单元——空间不足时把那个字一起拖到下一行
        //(如 CJK "…30 日[chip]" 把"日"拖走)。ZWSP 让断点落在 chip 之前,前文留在原行。
        var chip = AttributedString("\u{200B}")
        chip += lead + icon + labelRun

        // "+N" 段:小一号、更淡;基线上抬使其与 label 视觉居中
        // (小字号在共享基线上会显得沉底)。
        if urls.count > 1 {
            var more = AttributedString(unbreakable("\u{2060}\u{2009}+\(urls.count - 1)"))
            more[MarkdownLinkChipSegmentAttribute.self] = true
            more.font = .caption
            more.foregroundColor = .secondary.opacity(0.7)
            more.backgroundColor = background
            more.baselineOffset = 1
            if let chipURL { more.link = chipURL }
            chip += more
        }

        var tail = AttributedString("\u{2060}\u{00A0}")
        tail[MarkdownLinkChipSegmentAttribute.self] = true
        tail.font = .subheadline
        tail.backgroundColor = background
        if let chipURL { tail.link = chipURL }
        chip += tail
        return chip
    }

    /// 空格换 NBSP + 逐字符插 WORD JOINER,把整段粘成不可断行簇。
    private static func unbreakable(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
            .map(String.init)
            .joined(separator: "\u{2060}")
    }

    // MARK: - 连续链接折叠

    struct ChipGroup {
        let label: String
        let urls: [String]
        /// 组之后下一个待访问的 child 下标。
        let nextIndex: Int
    }

    /// 从 `start` 开始匹配一串可 chip 化的链接(链接之间允许纯空白文本)。
    /// 首链接的文字作为 chip label(为空时退化为 host)。
    static func consecutiveChipLinks(in children: [any Markup], from start: Int) -> ChipGroup? {
        guard isEnabled,
              let first = children[start] as? Markdown.Link,
              let firstURL = chippableDestination(first) else { return nil }

        var urls = [firstURL]
        var index = start + 1
        while index < children.count {
            if let link = children[index] as? Markdown.Link,
               let url = chippableDestination(link) {
                urls.append(url)
                index += 1
                continue
            }
            // 纯空白文本只在后面紧跟另一个链接时才吞进组里,
            // 否则它属于正文,留给正常渲染。
            if let text = children[index] as? Markdown.Text,
               !text.plainText.isEmpty,
               text.plainText.allSatisfy(\.isWhitespace),
               index + 1 < children.count,
               let link = children[index + 1] as? Markdown.Link,
               let url = chippableDestination(link) {
                urls.append(url)
                index += 2
                continue
            }
            break
        }

        let rawLabel = first.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = rawLabel.isEmpty ? (URL(string: firstURL)?.host() ?? firstURL) : rawLabel
        return ChipGroup(label: label, urls: urls, nextIndex: index)
    }

    /// 只 chip 化显式标了引用记号的链接:`[Label](https://… "cite")`(CommonMark
    /// link title 为 "cite")。普通 `[label](url)` 不受影响,保持原有链接渲染。
    private static func chippableDestination(_ link: Markdown.Link) -> String? {
        guard link.title?.lowercased() == "cite",
              let destination = link.destination else { return nil }
        // 用字符串前缀判 scheme,避开 URL(string:) 对 tool_result_id 里下划线/host 的解析坑。
        let lower = destination.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || lower.hasPrefix("\(toolScheme)://") else { return nil }
        return destination
    }
}
