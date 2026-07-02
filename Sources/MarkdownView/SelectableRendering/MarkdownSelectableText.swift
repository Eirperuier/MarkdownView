//
//  MarkdownSelectableText.swift
//  MarkdownView
//
//  text-based 可选中渲染入口。核心在 SelectableMarkupVisitor(markup → RichText TextContent)。
//  这里负责:math 预处理(占位符 + LaTeX storage)、缓存、把整篇 TextContent 交给 RichText TextView 渲染。
//
//  reveal:body 暂为静态;逐字 reveal 后续由 coordinator 直接改 textStorage 渐变窗口颜色(零 re-layout)接入。
//

#if canImport(RichText)
import SwiftUI
import Markdown
import RichText

@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
public struct MarkdownSelectableText: View, Equatable {
    // reveal 时 manager.revealedCount 变会让上层 body 重算;靠 Equatable 让 SwiftUI 跳过本 view 的重算
    // (rawText 不变即等价),避免 TextView updateUIView 把 coordinator 改的 textStorage 颜色刷回 base。
    public nonisolated static func == (lhs: MarkdownSelectableText, rhs: MarkdownSelectableText) -> Bool {
        lhs.rawText == rhs.rawText
            && lhs.listDepthOffset == rhs.listDepthOffset
            && lhs.plainOffsetBase == rhs.plainOffsetBase
    }

    private nonisolated let rawText: String
    /// 列表深度偏移:per-block 场景列表项单独 re-parse 后 AST 深度归零,marker 的 •/◦ 交替
    /// 与原版 `_markerView`(按 ctx.depth)对不上 —— 调用方把 listItemContext.depth 传进来补偏移。
    private nonisolated let listDepthOffset: Int
    /// plain 坐标基准偏移:本视图只承载块内一个片段(如表格单个 cell)时,manager.revealedCount
    /// 是块级坐标 —— 传入片段起点(cell 的 blockTextOffset),内部所有 reveal 锚点变为绝对坐标,
    /// 与块级 sweep 完全同源。
    private nonisolated let plainOffsetBase: Int
    @Environment(\.markdownRendererConfiguration) private var configuration
    // 正文基准字体(Font):注入 RichText 作 base font;visitor 侧另取 PlatformFont 设 AttributedString。
    @Environment(\.markdownFontGroup.body) private var bodyFont
    @State private var cache = TextContentCache()
    @State private var blockViewCache = BlockViewCache()
    @Environment(\.markdownStreaming) private var streamingManager
    @Environment(\.markdownFadeReveal) private var fadeConfig
    @Environment(\.colorScheme) private var revealColorScheme
    // 正文行距:对齐原版 flowithMarkdownPersonalized 的 `.lineSpacing(5)`(SwiftUI 环境值)。
    // UITextView 路径不自动吃 SwiftUI lineSpacing,需读出来落到 NSParagraphStyle.lineSpacing。
    @Environment(\.lineSpacing) private var lineSpacing
    // heading 上下 padding:对齐原版 MarkdownHeading 的 `.padding(paddings[level])`(同一环境值,吃 app 覆写)。
    @Environment(\.headingPaddings) private var headingPaddings
    // chip 点击的合成 URL 由 app 的 OpenURLAction 拦截(开 sheet);hosting 边界不继承,显式穿进附件。
    @Environment(\.openURL) private var openURL
    #if canImport(UIKit)
    @State private var revealCoordinator = RevealCoordinator()
    #endif

    public init(_ text: String, listDepthOffset: Int = 0, plainOffsetBase: Int = 0) {
        self.rawText = text
        self.listDepthOffset = listDepthOffset
        self.plainOffsetBase = plainOffsetBase
    }

    public var body: some View {
        let built = buildContent()
        TextView {
            built.content
        }
        .environment(\.markdownRendererConfiguration, built.configuration)
        .font(bodyFont)
        .textLayoutEngine(.textKit2)  // reveal 走 NSTextLayoutManager 渲染层 → 需 TextKit 2
        #if canImport(UIKit)
        .environment(\.onRichTextViewReady, revealHook(map: built.storageToPlain))
        .environment(\.onRichTextContentDidChange, contentChangeHook(map: built.storageToPlain))
        // `.link` 点击路由到 SwiftUI OpenURLAction(app 可拦截;与原版 Text 路径同语义),
        // 不再由 UITextView 直接开 Safari。
        .environment(\.onRichTextOpenLink, { url in openURL(url) })
        // manager 实例更换但内容未变(空块 manager 被 sync 修剪、正文到达后重建):attach 只在 textView
        // 创建时触发一次,textView 若恰在死 manager 窗口期创建会永远订着 rc=0 的死实例 → 整块不显示。
        // 显式监听 manager 身份变化重绑。
        .onChange(of: streamingManager.map(ObjectIdentifier.init)) { _, _ in
            guard let manager = streamingManager, let fade = fadeConfig else { return }
            revealCoordinator.rebind(manager: manager, fade: fade, colorScheme: revealColorScheme)
        }
        .onDisappear { revealCoordinator.detach() }
        #endif
        // 渲染时已算出 reveal 单位数,经 preference 回传 —— 驱动方无需再单独 parse 一遍(revealUnitCount)。
        .preference(key: MarkdownRevealTotalKey.self, value: built.revealTotal)
        // heading 上下 padding(视图级,同原版 MarkdownHeading):文档首/尾顶层块是 heading 才加。
        // per-block 场景 heading 是独立 textStorage 的唯一段落,paragraph spacing 在文档首尾是 no-op,必须视图 padding。
        .padding(EdgeInsets(
            top: built.topHeadingLevel.map { headingPaddings[$0].top } ?? 0,
            leading: 0,
            bottom: built.bottomHeadingLevel.map { headingPaddings[$0].bottom } ?? 0,
            trailing: 0
        ))
    }

    #if canImport(UIKit)
    /// reveal 模式下把底层 UITextView 交给 coordinator;静态(无 streaming/fade)时返回 nil 不挂。
    /// map = storage↔plain 映射(coordinator 把 plain frontier 换算成 textStorage 偏移)。
    private func revealHook(map: [Int]) -> (@MainActor (PlatformTextView) -> Void)? {
        guard let manager = streamingManager, let fade = fadeConfig else { return nil }
        let scheme = revealColorScheme
        let coordinator = revealCoordinator
        return { textView in
            coordinator.attach(
                textView,
                manager: manager,
                fade: fade,
                colorScheme: scheme,
                storageToPlain: map
            )
        }
    }

    /// 内容流式增长后(updateUIView 末尾)同帧让 coordinator 补一次色,避免露出一帧 base 色。
    private func contentChangeHook(map: [Int]) -> (@MainActor (PlatformTextView) -> Void)? {
        guard streamingManager != nil, fadeConfig != nil else { return nil }
        let coordinator = revealCoordinator
        return { _ in coordinator.contentDidChange(storageToPlain: map) }
    }
    #endif

    /// math 预处理 + parse + visit → 整篇 TextContent。按 rawText + manager 身份缓存(reveal/重绘复用)。
    /// **manager 身份必须入键**:附件(行内公式/块附件)的 rootView 在 visit 时烤死了 reveal 环境;
    /// manager 被修剪重建后 rawText 未变 → 只按文本哈希会命中旧内容 → 附件绑死死 manager,gate 永久失效
    ///(行内公式"有概率无 reveal"的根因)。
    private func buildContent() -> (content: TextContent, configuration: MarkdownRendererConfiguration, revealTotal: Int, storageToPlain: [Int], topHeadingLevel: Int?, bottomHeadingLevel: Int?) {
        var hasher = Hasher()
        hasher.combine(rawText)
        hasher.combine(listDepthOffset)
        hasher.combine(plainOffsetBase)
        if let streamingManager { hasher.combine(ObjectIdentifier(streamingManager)) }
        let key = hasher.finalize()
        if cache.key == key, let content = cache.content, let config = cache.configuration, let total = cache.revealTotal {
            return (content, config, total, cache.storageToPlain, cache.topHeadingLevel, cache.bottomHeadingLevel)
        }
        let result = Self.render(
            rawText,
            configuration: configuration,
            blockViewCache: blockViewCache,
            streamingManager: streamingManager,
            fadeConfig: fadeConfig,
            lineSpacing: lineSpacing,
            listDepthOffset: listDepthOffset,
            plainOffsetBase: plainOffsetBase,
            openURL: openURL
        )
        cache.key = key
        cache.content = result.content
        cache.configuration = result.config
        cache.revealTotal = result.revealTotal
        cache.storageToPlain = result.storageToPlain
        cache.topHeadingLevel = result.topHeadingLevel
        cache.bottomHeadingLevel = result.bottomHeadingLevel
        return (result.content, result.config, result.revealTotal, result.storageToPlain, result.topHeadingLevel, result.bottomHeadingLevel)
    }

    /// parse + visit:返回可选文本 content、config 与 reveal 总单位数。供 buildContent 与 revealUnitCount 复用。
    /// edgeHeadingLevels:文档首/尾顶层块若是 heading,其 level(供 body 加原版 MarkdownHeading 的视图 padding ——
    /// per-block 场景 heading 是独立 textStorage 里唯一段落,paragraphSpacingBefore/After 在文档首尾是 no-op)。
    @MainActor
    static func render(
        _ rawText: String,
        configuration: MarkdownRendererConfiguration,
        blockViewCache: BlockViewCache? = nil,
        streamingManager: StreamingRevealManager? = nil,
        fadeConfig: MarkdownFadeRevealConfig? = nil,
        lineSpacing: CGFloat = 0,
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        openURL: OpenURLAction? = nil
    ) -> (content: TextContent, config: MarkdownRendererConfiguration, revealTotal: Int, storageToPlain: [Int], topHeadingLevel: Int?, bottomHeadingLevel: Int?) {
        #if DEBUG
        let __t0 = CFAbsoluteTimeGetCurrent()
        #endif
        // math:提取 $…$/$$…$$ → 占位符 + LaTeX storage,注册 @math directive renderer。
        var math = configuration.math
        math.shouldRender = true
        let processedText = MathFirstMarkdownViewRenderer.preprocessMath(rawText, into: &math)
        BlockDirectiveRenderers.shared.addRenderer(MathBlockDirectiveRenderer(), for: "math")
        #if DEBUG
        let __tMath = CFAbsoluteTimeGetCurrent()
        #endif

        var config = configuration
        config.math = math
        config.allowedBlockDirectiveRenderers.insert("math")

        let mdContent = MarkdownContent(raw: .plainText(processedText))
        let document = mdContent.parse(options: mdContent.parseOptions(allowingBlockDirectives: true))
        #if DEBUG
        let __t1 = CFAbsoluteTimeGetCurrent()
        #endif
        let visitor = SelectableMarkupVisitor(
            configuration: config,
            bodyFont: bodyPlatformFont,
            inlineMathStorage: math.inlineMathStorage ?? [:],
            blockViewCache: blockViewCache,
            streamingManager: streamingManager,
            fadeConfig: fadeConfig,
            lineSpacing: lineSpacing,
            listDepthOffset: listDepthOffset,
            plainOffsetBase: plainOffsetBase,
            openURL: openURL
        )
        let result = visitor.makeTextContent(document)
        #if DEBUG
        let __t2 = CFAbsoluteTimeGetCurrent()
        let mathMs = (__tMath - __t0) * 1000, parseMs = (__t1 - __tMath) * 1000, visitMs = (__t2 - __t1) * 1000
        if mathMs + parseMs + visitMs > 3 {
            print("[Render] math=\(String(format: "%.1f", mathMs))ms parse=\(String(format: "%.1f", parseMs))ms visit=\(String(format: "%.1f", visitMs))ms len=\(rawText.count)")
        }
        #endif
        let children = Array(document.children)
        // Extended Heading 合并对:subtitle 实际按 level+1 渲染 → 底部视图 padding 也按降级后的层级。
        let isExtendedPair = children.count == 2
            && (children[0] as? Heading).map { t in (children[1] as? Heading)?.level == t.level } == true
        let bottomLevel: Int? = isExtendedPair
            ? (children.last as? Heading).map { min($0.level + 1, 6) }
            : (children.last as? Heading)?.level
        return (
            result.content,
            config,
            result.revealTotal,
            result.storageToPlain,
            (children.first as? Heading)?.level,
            bottomLevel
        )
    }

    /// rawText 的 reveal 单位总数(= coordinator 用的 markdownRevealPlainText 序列长度,行内 math 计 1)。
    /// 流式驱动方应把 manager.revealedCount 推进到「已到达文本」的这个值,reveal 节奏才与 content offset 对齐。
    @MainActor
    public static func revealUnitCount(_ rawText: String) -> Int {
        render(rawText, configuration: MarkdownRendererConfiguration()).revealTotal
    }

    private static var bodyPlatformFont: PlatformFont {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .body)
        #else
        NSFont.preferredFont(forTextStyle: .body) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #endif
    }

    /// parse + visit 结果缓存(class:在 body 里写不触发 re-eval)。
    @MainActor
    final class TextContentCache {
        var key: Int?
        var content: TextContent?
        var configuration: MarkdownRendererConfiguration?
        var revealTotal: Int?
        var storageToPlain: [Int] = []
        var topHeadingLevel: Int?
        var bottomHeadingLevel: Int?
    }
}

// MARK: - 表格 cell 可选中开关

struct MarkdownTableCellsSelectableKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var markdownTableCellsSelectable: Bool {
        get { self[MarkdownTableCellsSelectableKey.self] }
        set { self[MarkdownTableCellsSelectableKey.self] = newValue }
    }
}

extension View {
    /// 表格 body cell 的内容改用可选中文本渲染(per-cell 选中,不跨 cell;表头保持原渲染)。
    /// reveal 坐标经 cell 的 blockTextOffset 接入块级 sweep,节奏与原版逐 cell 扫过一致。
    nonisolated public func markdownTableCellsSelectable(_ enabled: Bool = true) -> some View {
        environment(\.markdownTableCellsSelectable, enabled)
    }
}

/// 渲染后的 reveal 单位总数,经 preference 由 `MarkdownSelectableText` 向上回传。
/// 流式驱动方 `onPreferenceChange` 拿到即可推进 reveal frontier,无需再单独 parse 整篇算长度。
public struct MarkdownRevealTotalKey: PreferenceKey {
    public static let defaultValue: Int = 0
    public static func reduce(value: inout Int, nextValue: () -> Int) {
        value = max(value, nextValue())
    }
}

// MARK: - 共享 types(SelectableMarkupVisitor 也用)
// CJK 斜体的 obliqueness key 已移入 RichText 的 RichTextAttributes scope(ObliquenessAttribute):
// 只有 scope 内的 key 才会被 NSAttributedString(including: \.richText) 桥接进 textStorage。

extension TextContent {
    /// 给所有 fragment 合并属性。移植自 MarkdownTextKit:view fragment 转 "\u{FFFC}"+attachment 再合并,
    /// inlineHostingAttachment 不被 font/paragraphStyle 覆盖,所以行内 view(math 等)不丢。
    func mergingAttributes(_ attributes: AttributeContainer) -> TextContent {
        TextContent(
            fragments.map { fragment in
                switch fragment {
                case .string(let string):
                    .attributedString(AttributedString(string, attributes: attributes))
                case .attributedString(let attributedString):
                    .attributedString(attributedString.mergingAttributes(attributes))
                case .view:
                    .attributedString(fragment.asAttributedString().mergingAttributes(attributes))
                }
            }
        )
    }

    /// 拼出所有 fragment 的 AttributedString(view → "\u{FFFC}"+attachment)。用于 emphasis/strong 合并。
    func attributedStringValue() -> AttributedString {
        fragments.reduce(into: AttributedString()) { $0 += $1.asAttributedString() }
    }
}
#endif
