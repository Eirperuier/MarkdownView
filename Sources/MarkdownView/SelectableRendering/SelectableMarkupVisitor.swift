//
//  SelectableMarkupVisitor.swift
//  MarkdownView
//
//  text-based 可选中渲染的核心:照 3.0 的 MarkdownTextConverter,把 markup 整体转成 RichText
//  TextContent(text + InlineView 混合)——行内全程可连续选择,行内 math / 元素作 InlineView 嵌在文本流里。
//  样式(颜色/CJK 斜体/高亮/字体)用魔改的;block(代码块/表格/引用块/图片/列表)复用魔改 view 作 attachment。
//
//  取代旧的「整段 AttributedString + 遇 view 降级 block」做法,真正吃到 MarkdownView 3.0 的 textSelection 红利。
//

#if canImport(RichText)
import SwiftUI
import CoreText
import Markdown
import RichText
#if canImport(LaTeXSwiftUI)
import LaTeXSwiftUI
#endif

@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
@MainActor
struct SelectableMarkupVisitor: @MainActor MarkupVisitor {
    typealias Result = TextContent

    var configuration: MarkdownRendererConfiguration
    /// 正文基准字体(PlatformFont):RichText 的 UITextView 路径需要它来叠加 bold/italic trait。
    let bodyFont: PlatformFont
    /// inline math 的 LaTeX storage(来自预处理),用占位符还原公式。
    let inlineMathStorage: [String: String]
    /// 复用魔改 view 渲染 block(代码块/表格/引用块…)。visitor 只产文本/InlineView。
    var blockViewVisitor: CmarkNodeVisitor
    /// block rootView 缓存:内容未变的 block 复用同一实例 → applyAttributedStringPreservingAttachments 里
    /// updateContent 拿到相同 rootView → 不触发 SwiftUI 重新求值/测量。这是吃 3.0 stream 增量、不掉帧的关键。
    let blockViewCache: BlockViewCache?
    /// attachment(checkbox / block view)的 rootView 由 UIHostingController 托管、不继承父 environment,
    /// 必须显式注入 reveal 相关 environment,否则 StreamingRevealGate 拿不到 manager → visible 恒 true、不淡入。
    let streamingManager: StreamingRevealManager?
    let fadeConfig: MarkdownFadeRevealConfig?
    /// 正文行距(NSParagraphStyle.lineSpacing):对齐原版 flowithMarkdownPersonalized 的 `.lineSpacing(5)`。
    let lineSpacing: CGFloat
    /// 列表深度偏移(per-block 单项 re-parse 后 AST depth 归零;marker •/◦ 交替与有序 marker 深度要补上它)。
    let listDepthOffset: Int
    /// 外层的 OpenURLAction:hosting 边界不继承环境,chip 点击(flowith-linkchip:// 合成 URL 由 app
    /// OpenURLAction 拦截开 sheet)等交互附件必须显式注入。
    let openURL: OpenURLAction?
    /// InlineView attachment 的递增 id,保证 RichText identity 稳定。
    private var attachmentCounter: Int = 0
    /// textStorage 字符游标(文字每字 1、内联公式/block attachment 各 1 个 ￼、换行 1)。
    private var revealCursor: Int = 0
    /// plainText 单位游标 = descriptor.markdownRevealPlainText 的消耗量。**manager.revealedCount 在这个坐标系**
    ///(app normalize 后行内公式是 11 字符占位符、marker 不占位),与 textStorage 坐标系不同,
    /// 二者靠 storageToPlain 映射换算 —— 直接拿 plain frontier 当 storage 偏移比会在占位符/marker 处错位
    ///(公式闭合收缩 remap 时表现为已见字符被误清戳重播)。
    private var plainCursor: Int = 0
    /// storageToPlain[i] = 第 i 个 textStorage 字符的 plain 单位起点(非降)。coordinator 二分换算 frontier。
    private var storageToPlain: [Int] = []

    /// 追加一段 storage↔plain 映射:storageCount 个 textStorage 字符消耗 plainSpan 个 plain 单位。
    /// 1:1(正文/换行)逐字对应;非 1:1(占位符=1字符11单位、marker/tab=有字符0单位)整段锚在起点
    ///(frontier 越过起点即整段揭示,与原版 gate「revealedCount > offsetBase」语义一致)。
    private mutating func appendMap(storageCount: Int, plainSpan: Int) {
        if storageCount == plainSpan {
            for k in 0..<storageCount { storageToPlain.append(plainCursor + k) }
        } else {
            for _ in 0..<storageCount { storageToPlain.append(plainCursor) }
        }
        plainCursor += plainSpan
    }

    init(
        configuration: MarkdownRendererConfiguration,
        bodyFont: PlatformFont,
        inlineMathStorage: [String: String],
        blockViewCache: BlockViewCache? = nil,
        streamingManager: StreamingRevealManager? = nil,
        fadeConfig: MarkdownFadeRevealConfig? = nil,
        lineSpacing: CGFloat = 0,
        listDepthOffset: Int = 0,
        plainOffsetBase: Int = 0,
        openURL: OpenURLAction? = nil
    ) {
        self.configuration = configuration
        self.bodyFont = bodyFont
        self.inlineMathStorage = inlineMathStorage
        self.blockViewVisitor = CmarkNodeVisitor(configuration: configuration)
        self.blockViewCache = blockViewCache
        self.streamingManager = streamingManager
        self.fadeConfig = fadeConfig
        self.lineSpacing = lineSpacing
        self.listDepthOffset = listDepthOffset
        // plain 基准偏移(片段承载,如表格 cell):锚点/映射全部变绝对坐标,与块级 sweep 同源。
        self.plainCursor = plainOffsetBase
        self.openURL = openURL
    }

    /// 给 attachment rootView 补注入 reveal/openURL environment(host 树不继承父环境)。
    private func injectRevealEnvironment<V: View>(_ view: V) -> AnyView {
        if let openURL {
            return AnyView(
                view
                    .environment(\.markdownStreaming, streamingManager)
                    .environment(\.markdownFadeReveal, fadeConfig)
                    .environment(\.openURL, openURL)
            )
        }
        return AnyView(
            view
                .environment(\.markdownStreaming, streamingManager)
                .environment(\.markdownFadeReveal, fadeConfig)
        )
    }

    func makeTextContent(_ markup: any Markup) -> (content: TextContent, revealTotal: Int, storageToPlain: [Int]) {
        var visitor = self
        blockViewCache?.beginPass()
        let content = visitor.visit(markup)
        blockViewCache?.endPass()
        // revealTotal = plain 单位总数(与 app 的 revealPlainTextCount / manager.revealedCount 同坐标系);
        // storageToPlain 供 coordinator 把 plain frontier 换算成 textStorage 偏移。
        return (content, visitor.plainCursor, visitor.storageToPlain)
    }

    mutating func defaultVisit(_ markup: any Markup) -> TextContent {
        descendInto(markup)
    }

    /// 文档级:block 之间插 LineBreak(段落/标题/block 各自成行),块内间距靠 paragraphSpacing。
    /// 每个顶层 block 走整块缓存(NodeViewCache 思路):前缀未变的块命中、跳过 visit,只推进游标;
    /// 只有正在增长的最后一个 block 重新 visit → visit 从 O(全篇) 降到 O(尾块)。
    mutating func visitDocument(_ document: Document) -> TextContent {
        let children = Array(document.children)
        // Extended Heading(topLevelBlocks 会把相邻同级标题合成一个描述符,sourceText="title\nsubtitle"):
        // 对齐 MarkdownBlockView._extendedHeadingBlock —— subtitle 降一级 + 全 .secondary + 交界间距归零。
        if children.count == 2,
           let title = children[0] as? Heading,
           let subtitle = children[1] as? Heading,
           subtitle.level == title.level {
            var combined = headingContainer(descendInto(title), level: title.level, spacingAfterOverride: 0)
            appendMap(storageCount: 1, plainSpan: 1)  // 描述符 plainText 的 "\n"
            combined += RichText.LineBreak().textContent
            let subLevel = min(title.level + 1, 6)
            combined += headingContainer(descendInto(subtitle), level: subLevel, spacingBeforeOverride: 0)
                .mergingAttributes(AttributeContainer().foregroundColor(.secondary))
            return combined
        }

        let fingerprint = configuration.stableFingerprint
        var combined = TextContent([])
        for child in document.children {
            // 分隔 LineBreak 的映射记账必须在子块**之前**(与最终字符顺序一致)。
            // 块间 "\n" 计 1 个 plain 单位(对齐 Extended Heading 描述符的 "title\nsubtitle")。
            let isFirst = combined.fragments.isEmpty
            if !isFirst { appendMap(storageCount: 1, plainSpan: 1) }
            let content = cachedVisitTopLevel(child, configFingerprint: fingerprint)
            if content.fragments.isEmpty {
                // 空子块:回滚分隔符记账(空块不产出游标移动)。
                if !isFirst { storageToPlain.removeLast(); plainCursor -= 1 }
                continue
            }
            if !isFirst {
                combined += RichText.LineBreak().textContent
            }
            combined += content
        }
        return combined
    }

    /// 顶层 block:按(内容哈希, reveal 起点, attachment 起点, config)查缓存。命中→复用 content 并按存下的
    /// 增量推进 revealCursor / attachmentCounter(等价于重跑但零成本);未命中→visit 并连同游标增量存入。
    private mutating func cachedVisitTopLevel(_ child: any Markup, configFingerprint: Int) -> TextContent {
        guard let cache = blockViewCache else { return visit(child) }
        let key = BlockCacheKey(
            contentHash: child.stableContentHash,
            revealStart: revealCursor,
            attachStart: attachmentCounter,
            configFingerprint: configFingerprint
        )
        if let hit = cache.hitBlock(key) {
            // 命中:重放映射段(相对块首 plain 偏移 → 加上当前 plainCursor),并推进双游标。
            let plainStart = plainCursor
            for rel in hit.mapSegment { storageToPlain.append(plainStart + rel) }
            plainCursor += hit.plainDelta
            revealCursor += hit.revealDelta
            attachmentCounter += hit.attachDelta
            return hit.content
        }
        let revealBefore = revealCursor
        let plainBefore = plainCursor
        let mapBefore = storageToPlain.count
        let attachBefore = attachmentCounter
        let content = visit(child)
        cache.storeBlock(key, CachedBlock(
            content: content,
            revealDelta: revealCursor - revealBefore,
            plainDelta: plainCursor - plainBefore,
            mapSegment: storageToPlain[mapBefore...].map { $0 - plainBefore },
            attachDelta: attachmentCounter - attachBefore
        ))
        return content
    }

    // MARK: - inline

    mutating func visitText(_ text: Markdown.Text) -> TextContent {
        let plain = text.plainText
        // 行内 math:占位符还原成 InlineView(replacement=LaTeX,周围文字照样可选)。内部按段标 offset + 累积。
        if !inlineMathStorage.isEmpty,
           plain.contains(MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix) {
            return inlineMathTextContent(plain: plain)
        }
        // 自动链接识别(对齐原版 visitText):裸 URL/邮箱(www.x.com 等 cmark autolink 漏掉的形态)
        // 加 .link+下划线+链接色;字符 1:1,reveal 记账不变。
        if configuration.autolinkDetectionEnabled,
           let autolinked = MarkdownAutolinkDetector.attributedString(
               from: plain,
               linkTintColor: configuration.linkTintColor
           ) {
            var attr = autolinked
            #if canImport(UIKit)
            attr.uiKit.font = bodyFont
            #elseif canImport(AppKit)
            attr.appKit.font = bodyFont
            #endif
            let n = attr.characters.count
            appendMap(storageCount: n, plainSpan: n)
            revealCursor += n
            return TextContent(.attributedString(attr))
        }
        let attr = markRevealOffsets(baseAttributed(plain), start: revealCursor)
        let n = attr.characters.count
        appendMap(storageCount: n, plainSpan: n)  // 正文 1:1(高亮定界符两侧同步剥除)
        revealCursor += n
        return TextContent(.attributedString(attr))
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> TextContent {
        appendMap(storageCount: 1, plainSpan: 1)  // markdownRevealPlainText 把 softBreak 计为 "\n"
        revealCursor += 1
        return RichText.Space(1).textContent
    }

    mutating func visitLineBreak(_ lineBreak: Markdown.LineBreak) -> TextContent {
        appendMap(storageCount: 1, plainSpan: 1)
        revealCursor += 1
        return RichText.LineBreak(1).textContent
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> TextContent {
        var attributed = baseAttributed(inlineCode.code)
        let tint = configuration.inlineCodeTintColor
        attributed.foregroundColor = tint
        attributed.backgroundColor = tint.opacity(0.1)
        let content = TextContent(.attributedString(markRevealOffsets(attributed, start: revealCursor)))
        appendMap(storageCount: attributed.characters.count, plainSpan: inlineCode.markdownRevealPlainText.count)
        revealCursor += attributed.characters.count
        return content
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> TextContent {
        let content = TextContent(.attributedString(markRevealOffsets(baseAttributed(inlineHTML.rawHTML), start: revealCursor)))
        appendMap(storageCount: inlineHTML.rawHTML.count, plainSpan: inlineHTML.markdownRevealPlainText.count)
        revealCursor += inlineHTML.rawHTML.count
        return content
    }

    mutating func visitEmphasis(_ emphasis: Markdown.Emphasis) -> TextContent {
        applyingCJKObliqueness(
            mergeInlinePresentationIntent(.emphasized, children: Array(emphasis.children))
        )
    }

    mutating func visitStrong(_ strong: Strong) -> TextContent {
        // 加粗带 emphasis 主题色(同魔改 visitStrong:.foregroundColor(preferredColor))。
        mergeInlinePresentationIntent(.stronglyEmphasized, children: Array(strong.children))
            .mergingAttributes(AttributeContainer().foregroundColor(configuration.preferredColor))
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> TextContent {
        mergeInlinePresentationIntent(.strikethrough, children: Array(strikethrough.children))
    }

    mutating func visitLink(_ link: Markdown.Link) -> TextContent {
        // 链接:魔改链接色 + 下划线 + `.link`(可点击)。textView.linkTextAttributes 已置空字典,
        // 样式由这里的前景色/下划线决定,不会被 tintColor 覆写;点击经 onRichTextOpenLink 路由
        // 到 SwiftUI OpenURLAction(与原版 Text 路径同语义)。
        var attributes = AttributeContainer().foregroundColor(configuration.linkTintColor)
        attributes.underlineStyle = .single
        if let destination = link.destination, let url = URL(string: destination) {
            attributes.link = url
        }
        return TextContent(
            .attributedString(
                descendInto(link).attributedStringValue().mergingAttributes(attributes)
            )
        )
    }

    // MARK: - block

    mutating func visitParagraph(_ paragraph: Paragraph) -> TextContent {
        paragraphContainer(descendInto(paragraph))
    }

    mutating func visitHeading(_ heading: Heading) -> TextContent {
        headingContainer(descendInto(heading), level: heading.level)
    }

    // 纯 block:复用魔改 view 作 block attachment(渲染 + reveal 自带)。
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> TextContent { blockAttachment(codeBlock) }
    mutating func visitTable(_ table: Markdown.Table) -> TextContent { blockAttachment(table) }
    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> TextContent {
        // 嵌套在其他块内的引用:仍走原版 view attachment(黑白覆写)。
        // 顶层引用块由调用方用 SelectableBlockQuote(原版装饰 + 可选中内容)渲染。
        blockAttachment(blockQuote) { config in
            config.preferredColor = .primary
            config.linkTintColor = .primary
        }
    }
    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) -> TextContent { blockAttachment(htmlBlock) }
    mutating func visitImage(_ image: Markdown.Image) -> TextContent { blockAttachment(image) }
    mutating func visitBlockDirective(_ blockDirective: BlockDirective) -> TextContent { blockAttachment(blockDirective) }
    mutating func visitUnorderedList(_ list: UnorderedList) -> TextContent {
        renderList(list, baseIndent: configuration.listConfiguration.leadingIndentation)
    }
    mutating func visitOrderedList(_ list: OrderedList) -> TextContent {
        renderList(list, baseIndent: configuration.listConfiguration.leadingIndentation)
    }
    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> TextContent { blockAttachment(thematicBreak) }

    // MARK: - 组合

    mutating func descendInto(_ markup: any Markup) -> TextContent {
        var combined = TextContent([])
        let children = Array(markup.children)
        var index = 0
        while index < children.count {
            // 连续 "cite" 链接(允许其间纯空白)折叠成一个行内引用 chip ——
            // 与原版 CmarkNodeVisitor.descendInto 同语义(检测/折叠/label 规则全复用 MarkdownLinkChips)。
            if let group = MarkdownLinkChips.consecutiveChipLinks(in: children, from: index) {
                let plainSpan = (index..<group.nextIndex).reduce(0) {
                    $0 + children[$1].markdownRevealPlainText.count
                }
                combined += chipTextContent(group: group, plainSpan: plainSpan)
                index = group.nextIndex
                continue
            }
            let content = visit(children[index])
            if !content.fragments.isEmpty { combined += content }
            index += 1
        }
        return combined
    }

    /// emphasis / strong / strikethrough:给子内容的 AttributedString 套 inlinePresentationIntent。
    mutating func mergeInlinePresentationIntent(
        _ intent: InlinePresentationIntent,
        children: [any Markup]
    ) -> TextContent {
        var attributed = AttributedString()
        for child in children {
            let childAttr = visit(child).attributedStringValue()
            guard !childAttr.characters.isEmpty else { continue }
            let existing = childAttr.inlinePresentationIntent ?? []
            attributed += childAttr.mergingAttributes(
                AttributeContainer().inlinePresentationIntent(existing.union(intent))
            )
        }
        return TextContent(.attributedString(attributed))
    }

    // MARK: - Helpers

    /// 基准 inline AttributedString:套正文 PlatformFont(RichText 叠 trait 用)+ 处理 ==高亮==。
    private func baseAttributed(_ string: String) -> AttributedString {
        var attributed = AttributedString(string)
        #if canImport(UIKit)
        attributed.uiKit.font = bodyFont
        #elseif canImport(AppKit)
        attributed.appKit.font = bodyFont
        #endif
        return MarkdownHighlightSyntax.applied(to: attributed)
    }

    /// 段落容器:块间距(componentSpacing)+ 正文行距(对齐原版 .lineSpacing(5))。
    private func paragraphContainer(_ content: TextContent) -> TextContent {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = configuration.componentSpacing
        style.lineSpacing = lineSpacing
        return content.mergingAttributes(
            AttributeContainer([.paragraphStyle: style as NSParagraphStyle])
        )
    }

    /// 标题容器:字号/字重 + 上下 padding。对齐原版 MarkdownHeading 的 `.padding(HeadingPaddings[level])`
    ///(h1 上12下6、h2 上10下5、h3 上8下4、h4 上6下3、h5 上4下2、h6 上2下1)。
    /// spacing 覆写供 Extended Heading 交界间距归零。
    private func headingContainer(
        _ content: TextContent,
        level: Int,
        spacingBeforeOverride: CGFloat? = nil,
        spacingAfterOverride: CGFloat? = nil
    ) -> TextContent {
        let padding = HeadingPaddings()[min(max(level, 1), 6)]
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBeforeOverride ?? padding.top
        style.paragraphSpacing = spacingAfterOverride ?? padding.bottom
        style.lineSpacing = lineSpacing
        var container = AttributeContainer([.paragraphStyle: style as NSParagraphStyle])
        #if canImport(UIKit)
        container.uiKit.font = headingFont(level)
        #elseif canImport(AppKit)
        container.appKit.font = headingFont(level)
        #endif
        return content.mergingAttributes(container)
    }

    private func headingFont(_ level: Int) -> PlatformFont {
        let scales: [CGFloat] = [1.6, 1.4, 1.25, 1.1, 1.0, 0.9]
        let size = bodyFont.pointSize * scales[min(max(level, 1), 6) - 1]
        #if canImport(UIKit)
        let weight: UIFont.Weight = level <= 1 ? .heavy : level <= 2 ? .bold : level <= 3 ? .semibold : .medium
        return UIFont.systemFont(ofSize: size, weight: weight)
        #elseif canImport(AppKit)
        let weight: NSFont.Weight = level <= 1 ? .heavy : level <= 2 ? .bold : level <= 3 ? .semibold : .medium
        return NSFont.systemFont(ofSize: size, weight: weight)
        #endif
    }

    /// block → InlineView attachment:复用魔改 view。configOverride 可给该 block 改 config(如引用块换黑白色)。
    private mutating func blockAttachment(
        _ markup: any Markup,
        configOverride: ((inout MarkdownRendererConfiguration) -> Void)? = nil
    ) -> TextContent {
        // block attachment = 1 个 ￼ textStorage 字符。offsetBase = 块起始 offset,块自身淡入由 streamingRevealFadeIn gate
        //(revealCount > offsetBase)驱动。offsetBase 用 **plain 坐标**(manager.revealedCount 的坐标系)。
        let blockStart = plainCursor
        appendMap(storageCount: 1, plainSpan: markup.markdownRevealPlainText.count)  // 1 个 ￼ 锚在块首
        revealCursor += 1
        let id = attachmentCounter
        attachmentCounter += 1

        // 按 block 内容 + 起始 offset + 是否 override + manager 身份作缓存键。前缀未变的 block 命中缓存、
        // 复用同一 rootView 实例,updateContent 就不会重新求值/测量;当前正在增长的 block 键会变、重建。
        // manager 身份必须入键:rootView 烤死了 reveal 环境,manager 被修剪重建后旧缓存绑死死实例 → gate 失效。
        let blockMgrKey = streamingManager.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "nil"
        let cacheKey = "\(markup.format())\u{1}\(blockStart)\u{1}\(id)\u{1}\(configOverride != nil)\u{1}\(blockMgrKey)"
        if let cache = blockViewCache, let hit = cache.hitContent(cacheKey) {
            return hit
        }

        let base = blockViewVisitor.visit(markup).body
        let view: AnyView
        if let configOverride {
            var overridden = configuration
            configOverride(&overridden)
            view = injectRevealEnvironment(
                base
                    .environment(\.markdownRendererConfiguration, overridden)
                    .environment(\.markdownTextOffsetBase, blockStart)
            )
        } else {
            view = injectRevealEnvironment(base.environment(\.markdownTextOffsetBase, blockStart))
        }
        let content = TextContent {
            InlineView(id: SelectableInlineViewID(index: id), sizing: .fittingLineFragment) { view }
        }
        blockViewCache?.storeContent(cacheKey, content)
        return content
    }

    /// 行内 math:把占位符段落拆成 text + InlineView(公式) + text,公式作 inline attachment(可选)。
    private mutating func inlineMathTextContent(plain: String) -> TextContent {
        var content = TextContent([])
        var search = plain.startIndex..<plain.endIndex
        while let match = firstInlineMath(in: plain, range: search) {
            if search.lowerBound < match.range.lowerBound {
                let attr = markRevealOffsets(baseAttributed(String(plain[search.lowerBound..<match.range.lowerBound])), start: revealCursor)
                let n = attr.characters.count
                appendMap(storageCount: n, plainSpan: n)
                content += TextContent(.attributedString(attr))
                revealCursor += n
            }
            let latex = match.latex
            let id = attachmentCounter
            attachmentCounter += 1
            // 行内公式 = 1 个 ￼ textStorage 字符,但 plain 里是完整占位符(⸨imath:ID⸩,≈11 单位)——
            // 映射整段锚在起点,frontier 越过起点即公式原子出现(对齐原版 gate 语义)。
            let mathPlainStart = plainCursor
            let mathUnits = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            appendMap(storageCount: 1, plainSpan: mathUnits)
            revealCursor += 1
            // 缓存公式 attachment(键 = id + latex + 锚点 + manager 身份):流式时正在增长的块每次 append 都重
            // visit,命中缓存复用同一 attachment 实例(===)→ reuse 前缀不断、updateContent 跳过重测。
            // manager 身份必须入键:attachment rootView 烤死了 reveal 环境,manager 被修剪重建后旧缓存会
            // 绑死死实例 → gate 永久失效。
            let mgrKey = streamingManager.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "nil"
            let mathKey = "imath\u{1}\(id)\u{1}\(latex)\u{1}\(mathPlainStart)\u{1}\(mgrKey)"
            let mathContent: TextContent
            if let cache = blockViewCache, let hit = cache.hitContent(mathKey) {
                mathContent = hit
            } else {
                // hosting 边界不继承 SwiftUI 环境:必须显式注入 reveal 环境 + plain 锚点,
                // 否则 InlineTextWithMath 的 reader 拿到 nil manager → 永远常显,无 reveal 无 fade。
                let mathView = injectRevealEnvironment(
                    InlineTextWithMath(segments: [.math(latex, revealUnits: mathUnits)])
                        .environment(\.markdownTextOffsetBase, mathPlainStart)
                )
                mathContent = TextContent {
                    InlineView(
                        id: SelectableInlineViewID(index: id),
                        replacement: AttributedString(latex),
                        sizing: .fittingLineFragment
                    ) {
                        mathView
                    }
                }
                blockViewCache?.storeContent(mathKey, mathContent)
            }
            content += mathContent
            search = match.range.upperBound..<plain.endIndex
        }
        if search.lowerBound < plain.endIndex {
            let attr = markRevealOffsets(baseAttributed(String(plain[search])), start: revealCursor)
            let n = attr.characters.count
            appendMap(storageCount: n, plainSpan: n)
            content += TextContent(.attributedString(attr))
            revealCursor += n
        }
        return content
    }

    // MARK: - 链接引用 chip(InlineView attachment:整体一个 ￼ 单位)

    /// chip 作 attachment 而非文字流:**选择原子性**(整个 chip 一个单位,复制得 replacement=label,
    /// 不会截到 NBSP/WJ 隐形簇)、胶囊统一背景直接对齐原版 iOS18 样式(而非 <18 的矩形降级)、
    /// iconRevision 由托管视图 @Observable 自观察(favicon 载入即自刷,零缓存键穿线)。
    /// 检测/折叠/label 语义仍全在 MarkdownLinkChips(consecutiveChipLinks);
    /// 外部自定义走原版同一组钩子(iconImage/placeholderIcon/prefetchIcon + iconRevision)。
    /// reveal:锚在 plain 起点,streamingRevealFadeIn gate 原子淡入(同 marker/代码块管线)。
    private mutating func chipTextContent(group: MarkdownLinkChips.ChipGroup, plainSpan: Int) -> TextContent {
        let plainStart = plainCursor
        appendMap(storageCount: 1, plainSpan: plainSpan)
        revealCursor += 1
        let id = attachmentCounter
        attachmentCounter += 1

        let mgrKey = streamingManager.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "nil"
        let cacheKey = "chip\u{1}\(group.label)\u{1}\(group.urls.joined(separator: "\u{2}"))\u{1}\(plainStart)\u{1}\(id)\u{1}\(mgrKey)"
        if let cache = blockViewCache, let hit = cache.hitContent(cacheKey) {
            return hit
        }
        let view = injectRevealEnvironment(
            SelectableLinkChipView(label: group.label, urls: group.urls)
                .environment(\.markdownTextOffsetBase, plainStart)
        )
        let content = TextContent {
            InlineView(
                id: SelectableInlineViewID(index: id),
                replacement: AttributedString(group.label),
                sizing: .fittingLineFragment
            ) {
                view
            }
        }
        blockViewCache?.storeContent(cacheKey, content)
        return content
    }

    private func firstInlineMath(
        in text: String,
        range: Range<String.Index>
    ) -> (range: Range<String.Index>, latex: String)? {
        inlineMathStorage
            .compactMap { id, latex -> (Range<String.Index>, String)? in
                let placeholder = MarkdownRendererConfiguration.Math.inlinePlaceholderPrefix
                    + id
                    + MarkdownRendererConfiguration.Math.inlinePlaceholderSuffix
                guard let r = text.range(of: placeholder, range: range) else { return nil }
                return (r, latex)
            }
            .min { $0.0.lowerBound < $1.0.lowerBound }
    }

    /// emphasis 内的 CJK 字符:斜体倾斜(同魔改 CJK 斜体,幅度 0.18)。
    /// 不能用 NSObliqueness 属性 —— **TextKit 2 忽略 obliqueness/expansion**(TextKit 1 才支持),
    /// 而本渲染路径为 reveal 强制 textKit2。改为把倾斜矩阵烤进字体(font matrix 属于字体本身,
    /// 布局/绘制/选区全链路生效)。resolve 阶段叠加 trait 时 CTFont 会保留矩阵(CJK 无 italic trait 则原样)。
    private func applyingCJKObliqueness(_ content: TextContent) -> TextContent {
        TextContent(content.fragments.map { fragment -> TextContent.Fragment in
            guard case .attributedString(let attr) = fragment else { return fragment }
            var result = attr
            var idx = result.characters.startIndex
            while idx < result.characters.endIndex {
                let next = result.characters.index(after: idx)
                if result[idx..<next].inlinePresentationIntent?.contains(.emphasized) == true,
                   result.characters[idx].isCJKForItalic {
                    #if canImport(UIKit)
                    let base = result[idx..<next].uiKit.font ?? bodyFont
                    result[idx..<next].uiKit.font = Self.obliqueFont(base)
                    #elseif canImport(AppKit)
                    let base = result[idx..<next].appKit.font ?? bodyFont
                    result[idx..<next].appKit.font = Self.obliqueFont(base)
                    #endif
                    // 关键:摘掉 .emphasized —— CJK 无 italic trait,intent 对它无用;留着反而让 RichText
                    // resolve 阶段对该 run 做 CTFont 拷贝+加 trait,可能把烤好的 font matrix 重置冲掉。
                    var intent = result[idx..<next].inlinePresentationIntent ?? []
                    intent.remove(.emphasized)
                    result[idx..<next].inlinePresentationIntent = intent.isEmpty ? nil : intent
                }
                idx = next
            }
            return .attributedString(result)
        })
    }

    /// 同 (font, 0.18 skew) 的斜体矩阵字体,缓存复用(逐字调用,别每字新建)。
    /// 必须走 CoreText:`UIFont(descriptor: …withMatrix…)` 不应用矩阵(UIKit 已知行为),
    /// CTFontCreateCopyWithAttributes 显式传矩阵才真生效;CTFont 与 UIFont/NSFont toll-free 桥接。
    /// RichText resolve 阶段的 NULL-matrix 拷贝/trait 叠加都保留原矩阵,不会冲掉倾斜。
    nonisolated(unsafe) private static var obliqueFontCache: [PlatformFont: PlatformFont] = [:]
    private static func obliqueFont(_ font: PlatformFont) -> PlatformFont {
        if let hit = obliqueFontCache[font] { return hit }
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.18, d: 1, tx: 0, ty: 0)
        let ct: CTFont = font
        let skewed: PlatformFont = CTFontCreateCopyWithAttributes(ct, font.pointSize, &matrix, nil)
        obliqueFontCache[font] = skewed
        return skewed
    }

    /// 有意不设 per-char RevealOffsetAttribute:该属性在 RichText 里仅定义、无任何消费者;本渲染路径的
    /// RevealFadeFragment 直接用 textStorage 字符偏移算 reveal 窗口,不读它。设它只会把 AttributedString
    /// 碎成 N 个 run(toAttr O(N))白白掉帧。保留此包装是为了留住语义/调用点,实际是恒等返回。
    private func markRevealOffsets(_ attr: AttributedString, start: Int) -> AttributedString {
        return attr
    }

    // MARK: - list 文本化(内部 inline 可选,对齐 3.0 renderListItem + 魔改 marker 奇偶样式)

    private mutating func renderList(_ list: any ListItemContainer & Markup, baseIndent: CGFloat) -> TextContent {
        var combined = TextContent([])
        for listItem in list.listItems {
            // 项间 LineBreak 的映射记账在 item **之前**(与字符顺序一致);plain 不含项间分隔 → 0 单位。
            let isFirst = combined.fragments.isEmpty
            if !isFirst { appendMap(storageCount: 1, plainSpan: 0) }
            let content = renderListItem(listItem, baseIndent: baseIndent)
            if content.fragments.isEmpty {
                if !isFirst { storageToPlain.removeLast() }
                continue
            }
            if !isFirst {
                combined += RichText.LineBreak().textContent
            }
            combined += content
        }
        return combined
    }

    private mutating func renderListItem(_ listItem: ListItem, baseIndent: CGFloat) -> TextContent {
        let spacing: CGFloat = 8  // 同魔改 list HStack 默认 spacing
        // marker 随内容首字符揭示:marker/tab 占 storage 字符但 0 plain 单位(锚在内容首字符的 plain 起点)。
        let (marker, markerWidth) = makeListMarker(listItem, revealOffset: plainCursor)
        let markerStorageCount = marker.fragments.reduce(0) { $0 + $1.asAttributedString().characters.count }
        appendMap(storageCount: markerStorageCount, plainSpan: 0)
        appendMap(storageCount: 1, plainSpan: 0)  // "\t"
        revealCursor += markerStorageCount + 1
        let contentIndent = baseIndent + markerWidth + spacing

        let itemStyle = NSMutableParagraphStyle()
        itemStyle.firstLineHeadIndent = baseIndent          // marker 起始
        itemStyle.headIndent = contentIndent                // wrap 内容缩进对齐
        itemStyle.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
        itemStyle.paragraphSpacing = configuration.componentSpacing
        itemStyle.lineSpacing = lineSpacing
        let paragraphOnly = AttributeContainer([.paragraphStyle: itemStyle as NSParagraphStyle])
        var itemAttrs = paragraphOnly
        setFont(&itemAttrs, bodyFont)

        // leading = item 首段(inline,可选);trailing = 嵌套 list / 其他 block。
        // 注意映射顺序:leading 先 visit(记账),trailing 的 "\n" 分隔在其内容 visit **之前**记账。
        var leadingContent = TextContent([])
        var trailingContent = TextContent([])
        var trailingSeparatorPending = false
        for child in listItem.children {
            if child is Paragraph {
                leadingContent += descendInto(child)
            } else {
                if !trailingContent.fragments.isEmpty {
                    appendMap(storageCount: 1, plainSpan: 0)
                    revealCursor += 1
                    trailingContent += RichText.LineBreak().textContent
                } else if !trailingSeparatorPending {
                    // trailing 与 leading 之间的 "\n"(TextContent 组装时插入)。
                    appendMap(storageCount: 1, plainSpan: 0)
                    revealCursor += 1
                    trailingSeparatorPending = true
                }
                // 嵌套 list:baseIndent 推进到内容缩进(对齐魔改"嵌套在父内容里")。
                if let nested = child as? UnorderedList {
                    trailingContent += renderList(nested, baseIndent: contentIndent)
                } else if let nested = child as? OrderedList {
                    trailingContent += renderList(nested, baseIndent: contentIndent)
                } else {
                    trailingContent += visit(child)
                }
            }
        }
        if trailingSeparatorPending, trailingContent.fragments.isEmpty {
            storageToPlain.removeLast()
            revealCursor -= 1
        }

        return TextContent {
            marker.mergingAttributes(paragraphOnly)        // marker 保留灰色/字体,只加段落样式
            AttributedString("\t", attributes: itemAttrs)  // tab → contentIndent
            if !leadingContent.fragments.isEmpty {
                leadingContent.mergingAttributes(itemAttrs)
            }
            if !trailingContent.fragments.isEmpty {
                AttributedString("\n", attributes: itemAttrs)
                trailingContent
            }
        }
    }

    /// marker:无序 •/◦、有序数字(secondary 灰),任务列表用 SF Symbol(checkmark.circle.fill/circle)。
    /// 返回 (marker 内容, 测量宽度) —— 宽度用于算内容缩进 tabStop。
    private mutating func makeListMarker(_ listItem: ListItem, revealOffset: Int) -> (TextContent, CGFloat) {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked
            let size = bodyFont.pointSize
            // checkbox 不再用 SwiftUI host attachment(host 晚挂载、gate 拿不到淡入起点)。改成文字流里的
            // image NSTextAttachment:它是 super.draw 系统绘制的一部分,RevealFadeFragment 的遮罩会像对文字
            // 一样按 firstSeen age 降它的 opacity → 与文字同步淡入、无挂载时序、无 gate。
            return (Self.checkboxImageContent(checked: checked, size: size, descender: bodyFont.descender), size)
        }
        let markerText: String
        let monospaced: Bool
        if let unordered = listItem.parent as? UnorderedList {
            let m = configuration.listConfiguration.unorderedListMarker
            // depth 补偏移:单项 re-parse 后 AST depth 归零,•/◦ 交替(原版按 ctx.depth)靠 listDepthOffset 还原。
            markerText = m.marker(listDepth: unordered.listDepth + listDepthOffset)
            monospaced = m.monospaced
        } else if let ordered = listItem.parent as? OrderedList {
            let m = configuration.listConfiguration.orderedListMarker
            // 用列表起始序号(startIndex,标准 markdown `3.` 从 3 开始)+ 项内位置,而不是仅 indexInParent。
            // 关键:expandListItems 后每个有序项被单独 re-parse 成一个「startIndex=N 的单项列表」,
            // 此时 indexInParent 恒为 0,只有 startIndex 才带着真实序号 → 否则序号全渲染成 1。
            let ordinal = Int(ordered.startIndex) - 1 + listItem.indexInParent
            markerText = m.marker(at: max(0, ordinal), listDepth: ordered.listDepth + listDepthOffset)
            monospaced = m.monospaced
        } else {
            return (TextContent([]), 0)
        }
        let markerFont = monospaced ? monospacedFont(ofSize: bodyFont.pointSize) : bodyFont
        let width = (markerText as NSString).size(withAttributes: [.font: markerFont]).width
        var attrs = AttributeContainer().foregroundColor(.secondary)
        setFont(&attrs, markerFont)
        // 数字/bullet 是真文本,随内容一起被 coordinator 按 textStorage 偏移逐字淡入(不需 RevealOffsetAttribute,
        // 该属性无消费者,见 markRevealOffsets 说明)。revealOffset 参数保留以对齐语义。
        let attr = AttributedString(markerText, attributes: attrs)
        _ = revealOffset
        return (TextContent(.attributedString(attr)), width)
    }

    /// checkbox → image NSTextAttachment(SF Symbol)。checked 用 template(随 textView.tintColor 染 accent),
    /// unchecked 用 secondaryLabel。作为文字流的 image「字」,自动走 super.draw + reveal 遮罩,与文字同步淡入。
    /// 相同(checked,size)复用同一 attachment 实例 → AttributedString 相等,前缀增量复用不被 checkbox 断链。
    nonisolated(unsafe) private static var checkboxContentCache: [String: TextContent] = [:]
    static func checkboxImageContent(checked: Bool, size: CGFloat, descender: CGFloat) -> TextContent {
        let cacheKey = "\(checked)_\(Int(size.rounded()))_\(Int(descender.rounded()))"
        if let hit = checkboxContentCache[cacheKey] { return hit }
        let content = buildCheckboxImageContent(checked: checked, size: size, descender: descender)
        checkboxContentCache[cacheKey] = content
        return content
    }

    private static func buildCheckboxImageContent(checked: Bool, size: CGFloat, descender: CGFloat) -> TextContent {
        #if canImport(UIKit)
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let symbol = checked ? "checkmark.circle.fill" : "circle"
        let attachment = NSTextAttachment()
        // 都用 template:模板图跟随前景色 → reveal 的 rendering-attr(alpha=phase)能让勾选框随文字一起逐字淡入,
        // 而不是 attachment 图直接满不透明地"啪"出现。checked 交给 textView.tintColor(主题色),unchecked 显式
        // 设 secondaryLabel(定型后即恢复该内容色,淡入过程走 reveal 的前景色)。
        attachment.image = UIImage(systemName: symbol, withConfiguration: cfg)?.withRenderingMode(.alwaysTemplate)
        attachment.bounds = CGRect(x: 0, y: descender, width: size, height: size)
        let ns = NSMutableAttributedString(attachment: attachment)
        if !checked {
            ns.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(location: 0, length: ns.length))
        }
        return TextContent(.attributedString(AttributedString(ns)))
        #else
        return TextContent(.string(checked ? "☑" : "☐"))
        #endif
    }

    private func setFont(_ container: inout AttributeContainer, _ font: PlatformFont) {
        #if canImport(UIKit)
        container.uiKit.font = font
        #elseif canImport(AppKit)
        container.appKit.font = font
        #endif
    }

    private func monospacedFont(ofSize size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
    }
}

private struct SelectableInlineViewID: Hashable {
    let index: Int
}

private extension Character {
    /// CJK(汉/假名)字符:斜体走 obliqueness 倾斜,西文走 trait italic。
    var isCJKForItalic: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)   // CJK Unified Ideographs
            || (0x3040...0x30FF).contains(scalar.value) // Hiragana + Katakana
            || (0x3400...0x4DBF).contains(scalar.value) // CJK Ext A
            || (0xF900...0xFAFF).contains(scalar.value) // CJK Compatibility
        }
    }
}

/// block rootView 缓存(跨 buildContent 持久)。key = block 内容+起始 offset+是否 override。
/// 每轮 makeTextContent: beginPass 清 used → 渲染中 hit/store 标 used → endPass 淘汰本轮没命中的(内容已变的旧 block)。
/// 前缀未变的 block 因 key 稳定而命中、复用同一 AnyView 实例 → attachment.updateContent 拿到相同 rootView →
/// 不触发 SwiftUI 重新求值/测量,吃到 3.0 的 stream 增量,不再每次整段重测。
@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
@MainActor
final class BlockViewCache {
    private var storage: [String: TextContent] = [:]
    private var used: Set<String> = []

    // 顶层 block(段落/标题/列表/attachment 全部)整块缓存:照搬 3.0 的 NodeViewCache 思路 ——
    // 内容未变的 block 命中缓存,只有正在增长的最后一个 block 重新 visit → visit O(尾块) 而非 O(全篇)。
    // 缓存 content 之外还存该块消耗的 revealCursor / attachmentCounter 增量,命中时直接推进游标、免重跑。
    private var blockStorage: [BlockCacheKey: CachedBlock] = [:]
    private var blockUsed: Set<BlockCacheKey> = []

    func hitContent(_ key: String) -> TextContent? {
        guard let v = storage[key] else { return nil }
        used.insert(key)
        return v
    }

    func storeContent(_ key: String, _ content: TextContent) {
        storage[key] = content
        used.insert(key)
    }

    func hitBlock(_ key: BlockCacheKey) -> CachedBlock? {
        guard let v = blockStorage[key] else { return nil }
        blockUsed.insert(key)
        return v
    }

    func storeBlock(_ key: BlockCacheKey, _ block: CachedBlock) {
        blockStorage[key] = block
        blockUsed.insert(key)
    }

    func beginPass() { used.removeAll(); blockUsed.removeAll() }
    func endPass() {
        storage = storage.filter { used.contains($0.key) }
        blockStorage = blockStorage.filter { blockUsed.contains($0.key) }
    }
}

/// 顶层 block 缓存键:内容哈希 + 该块起始 revealCursor / attachmentCounter + config 指纹。
/// 流式追加时前缀 block 的这四项都稳定 → 命中;最后一个正在长的块内容变 → key 变 → 重 visit。
struct BlockCacheKey: Hashable {
    let contentHash: Int
    let revealStart: Int
    let attachStart: Int
    let configFingerprint: Int
}

/// 缓存的一个顶层 block:产出的 TextContent + 它消耗掉的 reveal / attachment 游标增量。
struct CachedBlock {
    let content: TextContent
    /// textStorage 字符增量。
    let revealDelta: Int
    /// plain 单位增量(manager.revealedCount 坐标系)。
    let plainDelta: Int
    /// storage↔plain 映射段(相对块首 plain 偏移,长度 = 本块 storage 字符数)。命中时平移重放。
    let mapSegment: [Int]
    let attachDelta: Int
}
#endif
