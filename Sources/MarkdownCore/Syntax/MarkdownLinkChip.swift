import Foundation
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

    // MARK: - 连续链接折叠

    public struct ChipGroup {
        public let label: String
        public let urls: [String]
        /// 组之后下一个待访问的 child 下标。
        public let nextIndex: Int
    }

    /// 从 `start` 开始匹配一串可 chip 化的链接(链接之间允许纯空白文本)。
    /// 首链接的文字作为 chip label(为空时退化为 host)。
    public static func consecutiveChipLinks(in children: [any Markup], from start: Int) -> ChipGroup? {
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
