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
            && lhs.tree == rhs.tree
            && lhs.listDepthOffset == rhs.listDepthOffset
            && lhs.plainOffsetBase == rhs.plainOffsetBase
            && lhs.applyEdgeInsets == rhs.applyEdgeInsets
    }

    private nonisolated let rawText: String
    /// The block as a tree a model built, in place of markdown (MarkdownTree).
    private nonisolated let tree: MarkdownTree?
    /// 列表深度偏移:per-block 场景列表项单独 re-parse 后 AST 深度归零,marker 的 •/◦ 交替
    /// 与原版 `_markerView`(按 ctx.depth)对不上 —— 调用方把 listItemContext.depth 传进来补偏移。
    private nonisolated let listDepthOffset: Int
    /// plain 坐标基准偏移:本视图只承载块内一个片段(如表格单个 cell)时,manager.revealedCount
    /// 是块级坐标 —— 传入片段起点(cell 的 blockTextOffset),内部所有 reveal 锚点变为绝对坐标,
    /// 与块级 sweep 完全同源。
    private nonisolated let plainOffsetBase: Int
    /// 文档首/尾块的视图级上下留白(heading 的 padding、段落/列表的 ±5 —— 对齐原版 per-block 视图自带
    /// 的 padding;TextKit 的 paragraphSpacing 在文档首尾是 no-op,必须视图级补)。
    /// 片段承载场景(表格 cell)关掉 —— 原版 cell 内容无竖向 padding。
    private nonisolated let applyEdgeInsets: Bool
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
    // app 侧 textView 钩子(块级选择):创建登记 + 选区变化转发,与 reveal hook 串联。
    @Environment(\.markdownSelectableTextHooks) private var externalHooks
    /// 文本级行内锚(话题气泡):按块注入,post-render 插 hosted 附件。
    @Environment(\.markdownTextInlineAnchors) private var inlineAnchors
    /// 文本区间装饰(mark 下划线):按块注入,post-render 落属性。
    @Environment(\.markdownTextRangeDecorations) private var rangeDecorations
    // 动态字型按 SwiftUI 环境解析:app 可能把 dynamicTypeSize 钉死(flowith 全局 .medium),
    // 直接用 UIFont.preferredFont 会读**系统**设置(默认 Large)→ 可选中文本比原版大一号。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The path's fonts: the app's text styles, else the standard ones.
    @Environment(\.markdownPlatformTypography) private var typography
    /// Told how much of the text is revealed, while it streams.
    @Environment(\.markdownRevealedExtent) private var revealedExtent
    #if canImport(UIKit)
    @State private var revealCoordinator = RevealCoordinator()
    #endif

    public init(
        _ text: String,
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        applyEdgeInsets: Bool = true
    ) {
        self.rawText = text
        self.tree = nil
        self.listDepthOffset = listDepthOffset
        self.plainOffsetBase = plainOffsetBase
        self.applyEdgeInsets = applyEdgeInsets
    }

    /// A block as its tree (MarkdownTree): rendered as its markdown would be, with
    /// nothing parsed and its text taken as it is.
    public init(
        tree: MarkdownTree,
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        applyEdgeInsets: Bool = true
    ) {
        self.rawText = ""
        self.tree = tree
        self.listDepthOffset = listDepthOffset
        self.plainOffsetBase = plainOffsetBase
        self.applyEdgeInsets = applyEdgeInsets
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
        .environment(\.onRichTextViewReady, textViewReadyHook(map: built.storageToPlain))
        .environment(\.onRichTextContentDidChange, contentChangeHook(map: built.storageToPlain))
        .environment(\.onRichTextStorageIsCurrent, externalHooks?.storageIsCurrent)
        .environment(\.onRichTextSelectionChanged, externalHooks?.onSelectionChanged)
        .environment(\.onRichTextEditMenu, externalHooks?.editMenu)
        .environment(\.onRichTextLinkMenu, externalHooks?.linkMenu)
        .environment(\.onRichTextLinkTap, externalHooks?.linkTap)
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
        .onAppear { revealCoordinator.resume() }
        .onDisappear { revealCoordinator.detach() }
        #endif
        // 渲染时已算出 reveal 单位数,经 preference 回传 —— 驱动方无需再单独 parse 一遍(revealUnitCount)。
        .preference(key: MarkdownRevealTotalKey.self, value: built.revealTotal)
        // 文档首/尾块的视图级上下留白(heading = 原版 MarkdownHeading padding;段落/列表 = 原版
        // visitParagraph 的 ±5):paragraph spacing 在文档首尾是 no-op,必须视图 padding。
        .padding(EdgeInsets(
            top: applyEdgeInsets ? built.topEdgeInset : 0,
            leading: 0,
            bottom: applyEdgeInsets ? built.bottomEdgeInset : 0,
            trailing: 0
        ))
    }

    #if canImport(UIKit)
    /// textView 创建回调 = reveal coordinator attach + app 侧钩子登记 + 笔迹 overlay 同步,三者串联。
    private func textViewReadyHook(map: [Int]) -> (@MainActor (PlatformTextView) -> Void)? {
        let reveal = revealHook(map: map)
        let external = externalHooks?.onTextViewReady
        let penRevealed = penMarkRevealedCheck(map: map)
        return { textView in
            // 登记 storage→plain 映射(app 侧选区换算锚点坐标用,如文本级话题)。
            MarkdownSelectableTextPlainMap.register(map, for: textView)
            reveal?(textView)
            external?(textView)
            SelectablePenMarkOverlayView.sync(on: textView, isRevealed: penRevealed)
        }
    }

    /// 笔迹 overlay 的揭示判定:mark 末字符(storage NSRange → plain 偏移)过 frontier 才画。
    /// 静态(无 streaming manager)返回 nil = 恒真。
    private func penMarkRevealedCheck(map: [Int]) -> (@MainActor (PlatformTextView, NSRange) -> Bool)? {
        guard let manager = streamingManager, fadeConfig != nil else { return nil }
        return { textView, range in
            // NSRange(UTF-16)→ 字符偏移再查 map(与 MarkdownSelectableTextPlainMap 同法)。
            guard let plain = MarkdownSelectableTextPlainMap.plainRange(for: range, in: textView) else {
                return true
            }
            return manager.revealedCount >= plain.upperBound
        }
    }

    /// reveal 模式下把底层 UITextView 交给 coordinator;静态(无 streaming/fade)时返回 nil 不挂。
    /// map = storage↔plain 映射(coordinator 把 plain frontier 换算成 textStorage 偏移)。
    private func revealHook(map: [Int]) -> (@MainActor (PlatformTextView) -> Void)? {
        guard let manager = streamingManager, let fade = fadeConfig else { return nil }
        let scheme = revealColorScheme
        let coordinator = revealCoordinator
        let extent = revealedExtent
        return { textView in
            coordinator.onRevealedExtent = extent
            coordinator.attach(
                textView,
                manager: manager,
                fade: fade,
                colorScheme: scheme,
                storageToPlain: map
            )
        }
    }

    /// 内容流式增长后(updateUIView 末尾)同帧让 coordinator 补一次色,避免露出一帧 base 色;
    /// 笔迹 overlay 也在此重扫(marks 会随内容增长出现/位移)。
    private func contentChangeHook(map: [Int]) -> (@MainActor (PlatformTextView) -> Void)? {
        let isStreaming = streamingManager != nil && fadeConfig != nil
        let coordinator = revealCoordinator
        let extent = revealedExtent
        let penRevealed = penMarkRevealedCheck(map: map)
        let external = externalHooks?.onContentChanged
        return { textView in
            MarkdownSelectableTextPlainMap.register(map, for: textView)
            if isStreaming {
                coordinator.onRevealedExtent = extent
                coordinator.contentDidChange(storageToPlain: map)
            }
            SelectablePenMarkOverlayView.sync(on: textView, isRevealed: penRevealed)
            external?(textView)
        }
    }
    #endif

    /// math 预处理 + parse + visit → 整篇 TextContent。按 rawText + manager 身份缓存(reveal/重绘复用)。
    /// **manager 身份必须入键**:附件(行内公式/块附件)的 rootView 在 visit 时烤死了 reveal 环境;
    /// manager 被修剪重建后 rawText 未变 → 只按文本哈希会命中旧内容 → 附件绑死死 manager,gate 永久失效
    ///(行内公式"有概率无 reveal"的根因)。
    private func buildContent() -> (content: TextContent, configuration: MarkdownRendererConfiguration, revealTotal: Int, storageToPlain: [Int], topEdgeInset: CGFloat, bottomEdgeInset: CGFloat) {
        var hasher = Hasher()
        hasher.combine(rawText)
        hasher.combine(tree)
        hasher.combine(listDepthOffset)
        hasher.combine(plainOffsetBase)
        hasher.combine(dynamicTypeSize)
        hasher.combine(typography)
        // config 指纹必须入键:主题色(强调/链接等)是按当前深浅色算死的静态 Color,
        // 烤进渲染结果 —— 切换外观后 env config 换了新色,rawText 却没变,不入键就会
        // 命中旧内容,颜色永远停在旧模式(动态 Color 的 description 稳定,不会误失效)。
        hasher.combine(configuration.stableFingerprint)
        hasher.combine(lineSpacing)
        hasher.combine(inlineAnchors)
        hasher.combine(rangeDecorations)
        // 话题气泡烤的是 topicPreview 闭包引用(长按才求值);hooks 从无到有时需失效重建,
        // 否则早期无 hooks 渲染会把 nil 闭包冻死在缓存里(长按永远没有预览)。
        hasher.combine(externalHooks?.topicPreview != nil)
        if let streamingManager { hasher.combine(ObjectIdentifier(streamingManager)) }
        let key = hasher.finalize()
        if cache.key == key, let content = cache.content, let config = cache.configuration, let total = cache.revealTotal {
            return (content, config, total, cache.storageToPlain, cache.topEdgeInset, cache.bottomEdgeInset)
        }
        let result = Self.render(
            rawText,
            tree: tree,
            configuration: configuration,
            blockViewCache: blockViewCache,
            streamingManager: streamingManager,
            fadeConfig: fadeConfig,
            lineSpacing: lineSpacing,
            headingPaddings: headingPaddings,
            listDepthOffset: listDepthOffset,
            plainOffsetBase: plainOffsetBase,
            openURL: openURL,
            dynamicTypeSize: dynamicTypeSize,
            typography: typography,
            inlineAnchors: inlineAnchors,
            rangeDecorations: rangeDecorations,
            topicPreview: externalHooks?.topicPreview
        )
        cache.key = key
        cache.content = result.content
        cache.configuration = result.config
        cache.revealTotal = result.revealTotal
        cache.storageToPlain = result.storageToPlain
        cache.topEdgeInset = result.topEdgeInset
        cache.bottomEdgeInset = result.bottomEdgeInset
        return (result.content, result.config, result.revealTotal, result.storageToPlain, result.topEdgeInset, result.bottomEdgeInset)
    }

    /// parse + visit:返回可选文本 content、config 与 reveal 总单位数。供 buildContent 与 revealUnitCount 复用。
    /// edge insets:文档首/尾块的视图级上下留白(heading = headingPaddings,段落/列表 = 原版
    /// visitParagraph 的 ±5)—— per-block 场景 paragraphSpacingBefore/After 在文档首尾是 no-op,视图补。
    @MainActor
    static func render(
        _ rawText: String,
        tree: MarkdownTree? = nil,
        configuration: MarkdownRendererConfiguration,
        blockViewCache: BlockViewCache? = nil,
        streamingManager: StreamingRevealManager? = nil,
        fadeConfig: MarkdownFadeRevealConfig? = nil,
        lineSpacing: CGFloat = 0,
        headingPaddings: HeadingPaddings = HeadingPaddings(),
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        openURL: OpenURLAction? = nil,
        dynamicTypeSize: DynamicTypeSize? = nil,
        typography: MarkdownPlatformTypography = .standard,
        inlineAnchors: [MarkdownTextInlineAnchor] = [],
        rangeDecorations: [MarkdownTextRangeDecoration] = [],
        topicPreview: (@MainActor (String) -> AnyView?)? = nil
    ) -> (content: TextContent, config: MarkdownRendererConfiguration, revealTotal: Int, storageToPlain: [Int], topEdgeInset: CGFloat, bottomEdgeInset: CGFloat) {
        #if DEBUG
        let __t0 = CFAbsoluteTimeGetCurrent()
        #endif
        // math:提取 $…$/$$…$$ → 占位符 + LaTeX storage,注册 @math directive renderer。
        var math = configuration.math
        math.shouldRender = true
        // A tree has its maths as nodes; markdown has it in its text.
        let prepared = tree?.prepared(math: &math)
        let processedText = tree == nil ? MathFirstMarkdownViewRenderer.preprocessMath(rawText, into: &math) : ""
        BlockDirectiveRenderers.shared.addRenderer(MathBlockDirectiveRenderer(), for: "math")
        #if DEBUG
        let __tMath = CFAbsoluteTimeGetCurrent()
        #endif

        var config = configuration
        config.math = math
        config.allowedBlockDirectiveRenderers.insert("math")

        // 内联脚注 `^[…]` 预处理(math 之后):替换成占位符,visitor 遇占位符渲染上标数字链接。
        // 仅在 app 注入了脚注上下文且本块确有内联脚注时才扫描,plain 记账与未预处理的 AST 一致。
        var footnoteText = processedText
        var inlineFootnoteTokens: [Int: MarkdownFootnoteSyntax.InlineToken] = [:]
        if tree == nil, let footnotes = config.footnotes, !footnotes.inlineNotes.isEmpty {
            let pre = MarkdownFootnoteSyntax.preprocessInlineNotes(processedText)
            footnoteText = pre.text
            inlineFootnoteTokens = pre.tokens
        }

        let document: Markdown.Document
        if let prepared {
            document = prepared
        } else {
            let mdContent = MarkdownContent(raw: .plainText(footnoteText))
            document = mdContent.parse(options: mdContent.parseOptions(allowingBlockDirectives: true))
        }
        #if DEBUG
        let __t1 = CFAbsoluteTimeGetCurrent()
        #endif
        let visitor = SelectableMarkupVisitor(
            configuration: config,
            bodyFont: typography.body.font(at: dynamicTypeSize),
            inlineMathStorage: math.inlineMathStorage ?? [:],
            inlineFootnoteTokens: inlineFootnoteTokens,
            blockViewCache: blockViewCache,
            streamingManager: streamingManager,
            fadeConfig: fadeConfig,
            lineSpacing: lineSpacing,
            headingPaddings: headingPaddings,
            listDepthOffset: listDepthOffset,
            plainOffsetBase: plainOffsetBase,
            openURL: openURL,
            dynamicTypeSize: dynamicTypeSize,
            typography: typography,
            interpretsTextSyntax: tree == nil
        )
        var result = visitor.makeTextContent(document)
        #if canImport(UIKit)
        // 区间装饰(mark 下划线)先于锚插入:装饰只改属性不改长度,用原始映射;
        // 锚插入会移动 storage 索引。
        if !rangeDecorations.isEmpty {
            result.content = applyingRangeDecorations(
                rangeDecorations,
                to: result.content,
                storageToPlain: result.storageToPlain
            )
        }
        // 文本级行内锚(话题气泡):post-render 按 plain 偏移插 hosted 附件 + 映射插桩。
        if !inlineAnchors.isEmpty {
            result = insertingInlineAnchors(
                inlineAnchors,
                into: result,
                openURL: openURL,
                streamingManager: streamingManager,
                fadeConfig: fadeConfig,
                bubbleSize: typography.body.font(at: dynamicTypeSize).pointSize,
                dynamicTypeSize: dynamicTypeSize,
                colors: configuration.colors,
                topicPreview: topicPreview
            )
        }
        #endif
        #if DEBUG
        let __t2 = CFAbsoluteTimeGetCurrent()
        let mathMs = (__tMath - __t0) * 1000, parseMs = (__t1 - __tMath) * 1000, visitMs = (__t2 - __t1) * 1000
        RichTextBenchStats.renderCount += 1
        RichTextBenchStats.renderMs += mathMs + parseMs + visitMs
        if mathMs + parseMs + visitMs > 3 {
            print("[Render] math=\(String(format: "%.1f", mathMs))ms parse=\(String(format: "%.1f", parseMs))ms visit=\(String(format: "%.1f", visitMs))ms len=\(rawText.count)")
        }
        #endif
        let children = Array(document.children)
        // Extended Heading 合并对:subtitle 实际按 level+1 渲染 → 底部视图 padding 也按降级后的层级。
        let isExtendedPair = children.count == 2
            && (children[0] as? Heading).map { t in (children[1] as? Heading)?.level == t.level } == true
        // 文档首/尾块的视图级留白:heading → headingPaddings;段落/列表 → 原版 visitParagraph 的 5。
        func edgeInset(_ block: (any Markup)?, top: Bool) -> CGFloat {
            switch block {
            case let heading as Heading:
                let level = (!top && isExtendedPair) ? min(heading.level + 1, 6) : heading.level
                return top ? headingPaddings[level].top : headingPaddings[level].bottom
            case is Paragraph, is UnorderedList, is OrderedList:
                return 5
            default:
                return 0
            }
        }
        return (
            result.content,
            config,
            result.revealTotal,
            result.storageToPlain,
            edgeInset(children.first, top: true),
            edgeInset(children.last, top: false)
        )
    }

    /// rawText 的 reveal 单位总数(= coordinator 用的 markdownRevealPlainText 序列长度,行内 math 计 1)。
    /// 流式驱动方应把 manager.revealedCount 推进到「已到达文本」的这个值,reveal 节奏才与 content offset 对齐。
    @MainActor
    public static func revealUnitCount(_ rawText: String) -> Int {
        render(rawText, configuration: MarkdownRendererConfiguration()).revealTotal
    }

    /// parse + visit 结果缓存(class:在 body 里写不触发 re-eval)。
    @MainActor
    final class TextContentCache {
        var key: Int?
        var content: TextContent?
        var configuration: MarkdownRendererConfiguration?
        var revealTotal: Int?
        var storageToPlain: [Int] = []
        var topEdgeInset: CGFloat = 0
        var bottomEdgeInset: CGFloat = 0
    }
}

#if canImport(UIKit)
extension DynamicTypeSize {
    /// SwiftUI 动态字型档位 → UIKit 内容尺寸档位(preferredFont(compatibleWith:) 用)。
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
#endif

// MARK: - 文本级行内锚(话题气泡等)

/// 块内某个 plain 偏移处的行内附件锚:渲染时在该偏移之前的字符之后插入一个 hosted
/// 气泡附件(storage 1 字符 / plain 0 单位,不影响 reveal 计数),点击经 openURL 路由
///(app 拦截自定义 scheme)。典型 = 文本级话题的入口气泡(锚在选段末尾)。
public struct MarkdownTextInlineAnchor: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    /// 块内 plain 偏移(气泡插在此偏移处;文本级话题 = 选段末尾 = rangeStart + rangeLength)。
    public let plainOffset: Int
    public let url: URL?
    /// 长按预览菜单里"打开"项的本地化标题(app 传入;包层无本地化表)。
    public let openActionTitle: String

    public init(id: String, plainOffset: Int, url: URL?, openActionTitle: String = "Open") {
        self.id = id
        self.plainOffset = plainOffset
        self.url = url
        self.openActionTitle = openActionTitle
    }
}

/// 块内文本区间装饰(mark 下划线):post-render 把着色下划线落到 plain 区间对应的
/// storage 范围。同区间多条装饰按数组顺序依次覆盖(调用方把最新的排最后 = 显示最新色)。
public struct MarkdownTextRangeDecoration: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let plainStart: Int
    public let plainLength: Int
    public let underlineColor: Color
    /// 点击 URL(app 拦截 scheme 弹菜单);nil = 不可点。
    public let tapURL: URL?
    /// true = tapURL 只落到**尚无链接**的 run(整段可点但不覆盖内容里的真实链接,
    /// 如脚注定义整行可点、行内引用/URL 保持各自点击)。false = 整段覆盖(mark 语义)。
    public let preservesInnerLinks: Bool

    public init(
        id: String,
        plainStart: Int,
        plainLength: Int,
        underlineColor: Color,
        tapURL: URL? = nil,
        preservesInnerLinks: Bool = false
    ) {
        self.id = id
        self.plainStart = plainStart
        self.plainLength = plainLength
        self.underlineColor = underlineColor
        self.tapURL = tapURL
        self.preservesInnerLinks = preservesInnerLinks
    }
}

struct MarkdownTextRangeDecorationsKey: EnvironmentKey {
    static let defaultValue: [MarkdownTextRangeDecoration] = []
}

extension EnvironmentValues {
    /// 当前块的文本区间装饰列表(按块注入;空 = 无装饰)。
    public var markdownTextRangeDecorations: [MarkdownTextRangeDecoration] {
        get { self[MarkdownTextRangeDecorationsKey.self] }
        set { self[MarkdownTextRangeDecorationsKey.self] = newValue }
    }
}

struct MarkdownTextInlineAnchorsKey: EnvironmentKey {
    static let defaultValue: [MarkdownTextInlineAnchor] = []
}

extension EnvironmentValues {
    /// 当前块的行内锚列表(按块注入;空 = 无行内附件)。
    public var markdownTextInlineAnchors: [MarkdownTextInlineAnchor] {
        get { self[MarkdownTextInlineAnchorsKey.self] }
        set { self[MarkdownTextInlineAnchorsKey.self] = newValue }
    }
}

#if canImport(UIKit)
/// app 侧查询:textView 的 storage→plain 映射(选区换算锚点坐标用)。
/// textView 创建/内容更新时由 MarkdownSelectableText 登记(associated object)。
public enum MarkdownSelectableTextPlainMap {
    /// 仅作 associated object 的地址锚,从不读写值。
    private nonisolated(unsafe) static var associatedKey: UInt8 = 0

    @MainActor
    static func register(_ map: [Int], for textView: PlatformTextView) {
        objc_setAssociatedObject(textView, &associatedKey, map, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 每个 storage 字符(Character,不是 UTF-16)对应的 plain 偏移。编辑场景用它在 storage 光标
    /// 与模型偏移之间换算。
    @MainActor
    public static func storageToPlain(for textView: PlatformTextView) -> [Int]? {
        objc_getAssociatedObject(textView, &associatedKey) as? [Int]
    }

    /// 选区(UTF-16 NSRange)→ 块内 plain 区间。无映射/越界返回 nil。
    @MainActor
    public static func plainRange(for range: NSRange, in textView: PlatformTextView) -> Range<Int>? {
        guard let map = objc_getAssociatedObject(textView, &associatedKey) as? [Int],
              !map.isEmpty else { return nil }
        let text = textView.text ?? ""
        guard let sRange = Range(range, in: text) else { return nil }
        let charStart = text.distance(from: text.startIndex, to: sRange.lowerBound)
        let charEnd = text.distance(from: text.startIndex, to: sRange.upperBound)
        guard charStart >= 0, charStart < map.count, charEnd > charStart else { return nil }
        let start = map[charStart]
        let end: Int
        if charEnd < map.count {
            end = max(map[charEnd], start + 1)
        } else {
            end = max(map[map.count - 1] + 1, start + 1)
        }
        return start..<end
    }
}
#endif

// MARK: - app 侧 textView 钩子(块级选择等)

/// app 注入的底层 textView 钩子:创建时拿到 UITextView(登记归属)+ 选区变化转发
///(跟踪原生选择手柄拖拽,供块级选择模式做越界接管判定)。
/// 环境按 cell 注入(闭包捕获 cell/块 id),表格 cell 等块内多 textView 会各自回调。
/// class + 身份 Equatable:调用方必须按 id 缓存复用实例 —— env 每次换新实例会被判定为
/// 环境变化,把所有 cell 的 MarkdownSelectableText 无谓重渲染。
public final class MarkdownSelectableTextHooks: Equatable, Sendable {
    public let onTextViewReady: @MainActor (PlatformTextView) -> Void
    public let onSelectionChanged: @MainActor (PlatformTextView) -> Void
    #if canImport(UIKit)
    /// 可选:自定义文本选区 edit menu(全选本块/引用所选等)。
    /// 参数 = (textView, 选区 NSRange, 系统建议项);返回 nil = 系统默认菜单。
    public let editMenu: (@MainActor (PlatformTextView, NSRange, [UIMenuElement]) -> UIMenu?)?
    /// 可选:点击 `.link`(如 mark 下划线)在链接位置弹浮动菜单;返回 nil = 该链接走默认点击。
    public let linkMenu: (@MainActor (URL) -> [UIMenuElement]?)?
    /// 可选:链接点击最先回调(textView, URL, 链接 rect);返回 true = 已处理
    /// (如脚注引用在链接位置弹悬浮面板),false = 继续 linkMenu → openURL 链。
    public let linkTap: (@MainActor (PlatformTextView, URL, CGRect) -> Bool)?
    /// 可选:话题气泡长按预览(id = rootMessageId → 预览视图;nil = 无预览)。
    public let topicPreview: (@MainActor (String) -> AnyView?)?
    /// 可选:内容落进 textStorage 之后(updateUIView 末尾)回调。编辑场景在这里按新映射还原光标。
    public let onContentChanged: (@MainActor (PlatformTextView) -> Void)?
    /// 可选:编辑场景会抢在渲染前直接改 textStorage;内容未变的渲染来时问这里 storage 是否仍显示模型。
    public let storageIsCurrent: (@MainActor (PlatformTextView) -> Bool)?
    #endif

    #if canImport(UIKit)
    public init(
        onTextViewReady: @escaping @MainActor (PlatformTextView) -> Void,
        onSelectionChanged: @escaping @MainActor (PlatformTextView) -> Void,
        editMenu: (@MainActor (PlatformTextView, NSRange, [UIMenuElement]) -> UIMenu?)? = nil,
        linkMenu: (@MainActor (URL) -> [UIMenuElement]?)? = nil,
        linkTap: (@MainActor (PlatformTextView, URL, CGRect) -> Bool)? = nil,
        topicPreview: (@MainActor (String) -> AnyView?)? = nil,
        onContentChanged: (@MainActor (PlatformTextView) -> Void)? = nil,
        storageIsCurrent: (@MainActor (PlatformTextView) -> Bool)? = nil
    ) {
        self.onTextViewReady = onTextViewReady
        self.onSelectionChanged = onSelectionChanged
        self.editMenu = editMenu
        self.linkMenu = linkMenu
        self.linkTap = linkTap
        self.topicPreview = topicPreview
        self.onContentChanged = onContentChanged
        self.storageIsCurrent = storageIsCurrent
    }
    #else
    public init(
        onTextViewReady: @escaping @MainActor (PlatformTextView) -> Void,
        onSelectionChanged: @escaping @MainActor (PlatformTextView) -> Void
    ) {
        self.onTextViewReady = onTextViewReady
        self.onSelectionChanged = onSelectionChanged
    }
    #endif

    public static func == (lhs: MarkdownSelectableTextHooks, rhs: MarkdownSelectableTextHooks) -> Bool {
        lhs === rhs
    }
}

struct MarkdownSelectableTextHooksKey: EnvironmentKey {
    static let defaultValue: MarkdownSelectableTextHooks? = nil
}

extension EnvironmentValues {
    public var markdownSelectableTextHooks: MarkdownSelectableTextHooks? {
        get { self[MarkdownSelectableTextHooksKey.self] }
        set { self[MarkdownSelectableTextHooksKey.self] = newValue }
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
