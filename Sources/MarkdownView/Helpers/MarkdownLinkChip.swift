import SwiftUI

extension MarkdownLinkChips {
    // MARK: - 图标钩子(app 注入)

    /// 同步取 favicon(命中缓存返回已缩放好的 Image,未命中返回 nil)。key 为站点 host。
    /// 同一组钩子也供网页链接前的站点图标(`markdownLinkSiteIcons`)。
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
}
