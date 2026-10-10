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
    /// 内联脚注 `^[…]` 的预处理占位符 storage(K → 内容/plainSpan;来自
    /// MarkdownFootnoteSyntax.preprocessInlineNotes,与 configuration.footnotes.inlineNotes 按序对应)。
    let inlineFootnoteTokens: [Int: MarkdownFootnoteSyntax.InlineToken]
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
    /// heading 上下 padding(环境值,吃 app 覆写):headingContainer 的段落间距按它记账。
    let headingPaddings: HeadingPaddings
    /// SwiftUI 环境的动态字型档位:标题字号解析、hosted 附件环境注入都按它
    ///(app 可能钉死档位,系统 preferredFont 会差一号)。
    let dynamicTypeSize: DynamicTypeSize?
    /// The path's fonts: headings and inline code (the body arrives resolved as `bodyFont`).
    let typography: MarkdownPlatformTypography
    /// 列表深度偏移(per-block 单项 re-parse 后 AST depth 归零;marker •/◦ 交替与有序 marker 深度要补上它)。
    let listDepthOffset: Int
    /// 外层的 OpenURLAction:hosting 边界不继承环境,chip 点击(flowith-linkchip:// 合成 URL 由 app
    /// OpenURLAction 拦截开 sheet)等交互附件必须显式注入。
    let openURL: OpenURLAction?
    /// Whether text is read for MarkdownView's text-level syntax (`==highlight==`,
    /// `:circle[…]`): yes for markdown, no for a tree a model built (MarkdownTree),
    /// whose text is the person's own and whose highlights and pens are nodes.
    let interpretsTextSyntax: Bool
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
        inlineFootnoteTokens: [Int: MarkdownFootnoteSyntax.InlineToken] = [:],
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
        interpretsTextSyntax: Bool = true
    ) {
        self.interpretsTextSyntax = interpretsTextSyntax
        self.configuration = configuration
        self.bodyFont = bodyFont
        self.inlineMathStorage = inlineMathStorage
        self.inlineFootnoteTokens = inlineFootnoteTokens
        self.blockViewVisitor = CmarkNodeVisitor(configuration: configuration)
        self.blockViewCache = blockViewCache
        self.streamingManager = streamingManager
        self.fadeConfig = fadeConfig
        self.lineSpacing = lineSpacing
        self.headingPaddings = headingPaddings
        self.dynamicTypeSize = dynamicTypeSize
        self.typography = typography
        self.listDepthOffset = listDepthOffset
        // plain 基准偏移(片段承载,如表格 cell):锚点/映射全部变绝对坐标,与块级 sweep 同源。
        self.plainCursor = plainOffsetBase
        self.openURL = openURL
    }

    /// 给 attachment rootView 补注入 reveal/openURL/动态字型 environment(host 树不继承父环境)。
    private func injectRevealEnvironment<V: View>(_ view: V) -> AnyView {
        var injected = AnyView(
            view
                .environment(\.markdownStreaming, streamingManager)
                .environment(\.markdownFadeReveal, fadeConfig)
        )
        if let openURL {
            injected = AnyView(injected.environment(\.openURL, openURL))
        }
        if let dynamicTypeSize {
            injected = AnyView(injected.environment(\.dynamicTypeSize, dynamicTypeSize))
        }
        return injected
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
    mutating func visitDocument(_ document: Markdown.Document) -> TextContent {
        let children = Array(document.children)
        // Extended Heading(topLevelBlocks 会把相邻同级标题合成一个描述符,sourceText="title\nsubtitle"):
        // 对齐 MarkdownBlockView._extendedHeadingBlock —— subtitle 降一级 + 全 .secondary + 交界间距归零。
        if children.count == 2,
           let title = children[0] as? Heading,
           let subtitle = children[1] as? Heading,
           subtitle.level == title.level {
            // 交界完全归零(原版 VStack spacing 0 + 相向 padding 归零):paragraphSpacing/Before 归 0 外,
            // 两个标题的 lineSpacing 也要归 0 —— TextKit2 的段落交界会加**下一段**样式的 lineSpacing
            //(实测 subtitle 片段内行起点 y=lineSpacing;title 归零只管 title 内部)。
            var combined = headingContainer(
                descendInto(title),
                level: title.level,
                spacingAfterOverride: 0,
                lineSpacingOverride: 0
            )
            appendMap(storageCount: 1, plainSpan: 1)  // 描述符 plainText 的 "\n"
            combined += RichText.LineBreak().textContent
            let subLevel = min(title.level + 1, 6)
            combined += headingContainer(
                descendInto(subtitle),
                level: subLevel,
                spacingBeforeOverride: 0,
                lineSpacingOverride: 0
            )
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
        // 脚注(标准引用/定义标记/内联占位符)→ 上标数字链接;无脚注上下文时零开销直通。
        return footnoteAwareTextContent(plain, isNodeStart: true)
    }

    /// 纯文本片段(自动链接识别 + 基准样式 + 映射记账)。脚注/数学切分后的正文段都走这里。
    private mutating func plainTextPiece(_ plain: String) -> TextContent {
        guard !plain.isEmpty else { return TextContent([]) }
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
            #elseif os(macOS)
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

    // MARK: - 脚注(标准引用 [^id] / 定义标记 [^id]: / 内联占位符)

    private enum FootnoteToken {
        case reference(id: String)
        case definition(id: String)
        case inlineNote(index: Int)
    }

    /// 把文本按脚注 token 切分:token → 上标数字链接,间隙 → plainTextPiece。
    /// 无脚注上下文 / 文本无相关标记时零切分直通。
    /// isNodeStart:定义标记 `[^id]:` 仅在 Text 节点起始处生效(= 段首或 softbreak 后的行首)。
    private mutating func footnoteAwareTextContent(_ plain: String, isNodeStart: Bool) -> TextContent {
        guard let footnotes = configuration.footnotes, !footnotes.isEmpty else {
            return plainTextPiece(plain)
        }
        let mayHaveStandard = !footnotes.references.isEmpty && plain.contains("[^")
        let mayHaveInline = !inlineFootnoteTokens.isEmpty
            && plain.contains(MarkdownFootnoteSyntax.inlinePlaceholderPrefix)
        guard mayHaveStandard || mayHaveInline else { return plainTextPiece(plain) }

        var content = TextContent([])
        var cursor = plain.startIndex
        while cursor < plain.endIndex {
            guard let (token, range) = nextFootnoteToken(
                in: plain,
                from: cursor,
                allowDefinition: isNodeStart && cursor == plain.startIndex,
                footnotes: footnotes
            ) else { break }
            if range.lowerBound > cursor {
                content += plainTextPiece(String(plain[cursor..<range.lowerBound]))
            }
            content += footnotePiece(token, sourceText: String(plain[range]), footnotes: footnotes)
            cursor = range.upperBound
        }
        if cursor < plain.endIndex {
            content += plainTextPiece(String(plain[cursor...]))
        }
        return content
    }

    /// 从 cursor 起找最近的脚注 token(标准引用/定义标记/内联占位符),无则 nil。
    /// 无定义的 `[^x]` 不算 token(保持字面),继续向后扫。
    private func nextFootnoteToken(
        in plain: String,
        from cursor: String.Index,
        allowDefinition: Bool,
        footnotes: MarkdownFootnotes
    ) -> (FootnoteToken, Range<String.Index>)? {
        var search = cursor
        var standard: (FootnoteToken, Range<String.Index>)? = nil
        while search < plain.endIndex, standard == nil,
              let open = plain.range(of: "[^", range: search..<plain.endIndex) {
            // id = `[^` 后到 `]` 的非空、无空白/中括号字符序列。
            var idEnd = open.upperBound
            while idEnd < plain.endIndex {
                let c = plain[idEnd]
                if c == "]" { break }
                if c.isWhitespace || c == "[" { idEnd = plain.endIndex; break }
                idEnd = plain.index(after: idEnd)
            }
            guard idEnd < plain.endIndex, plain[idEnd] == "]", idEnd > open.upperBound else {
                search = open.upperBound
                continue
            }
            let id = String(plain[open.upperBound..<idEnd])
            let afterBracket = plain.index(after: idEnd)
            guard footnotes.references[id] != nil else {
                search = afterBracket
                continue
            }
            if afterBracket < plain.endIndex, plain[afterBracket] == ":" {
                // 定义标记只认节点起始(行首);其他位置的 `[^id]:` 保持字面。
                if allowDefinition, open.lowerBound == plain.startIndex {
                    standard = (.definition(id: id), open.lowerBound..<plain.index(after: afterBracket))
                } else {
                    search = plain.index(after: afterBracket)
                    continue
                }
            } else {
                standard = (.reference(id: id), open.lowerBound..<afterBracket)
            }
        }

        var inline: (FootnoteToken, Range<String.Index>)? = nil
        if !inlineFootnoteTokens.isEmpty,
           let prefixRange = plain.range(
               of: MarkdownFootnoteSyntax.inlinePlaceholderPrefix,
               range: cursor..<plain.endIndex
           ),
           let suffixRange = plain.range(
               of: MarkdownFootnoteSyntax.inlinePlaceholderSuffix,
               range: prefixRange.upperBound..<plain.endIndex
           ),
           let index = Int(plain[prefixRange.upperBound..<suffixRange.lowerBound]) {
            inline = (.inlineNote(index: index), prefixRange.lowerBound..<suffixRange.upperBound)
        }

        switch (standard, inline) {
        case (nil, nil): return nil
        case (let s?, nil): return s
        case (nil, let i?): return i
        case (let s?, let i?): return s.1.lowerBound <= i.1.lowerBound ? s : i
        }
    }

    /// token → 上标数字链接片段。映射记账:storage = 显示字符数,plainSpan = 源文本的
    /// plain 单位数(整段锚在起点,与占位符/marker 同语义)→ 块级 plain 坐标系不变,
    /// reveal frontier / mark 锚点与字面渲染完全同源。
    private mutating func footnotePiece(
        _ token: FootnoteToken,
        sourceText: String,
        footnotes: MarkdownFootnotes
    ) -> TextContent {
        var display: AttributedString
        let plainSpan: Int
        switch token {
        case .reference(let id):
            guard let ref = footnotes.references[id] else { return plainTextPiece(sourceText) }
            display = AttributedString(MarkdownFootnoteSyntax.superscriptDigits(ref.number))
            var attrs = AttributeContainer().foregroundColor(configuration.linkTintColor)
            setFont(&attrs, bodyFont)
            display.mergeAttributes(attrs)
            if let url = ref.referenceURL { display.link = url }
            plainSpan = sourceText.count
        case .definition(let id):
            guard let ref = footnotes.references[id] else { return plainTextPiece(sourceText) }
            display = AttributedString("\(ref.number).")
            var attrs = AttributeContainer().foregroundColor(configuration.linkTintColor)
            setFont(&attrs, mediumWeightFont(ofSize: bodyFont.pointSize))
            display.mergeAttributes(attrs)
            if let url = ref.definitionURL { display.link = url }
            plainSpan = sourceText.count
        case .inlineNote(let index):
            let note = index < footnotes.inlineNotes.count ? footnotes.inlineNotes[index] : nil
            display = AttributedString(MarkdownFootnoteSyntax.superscriptDigits(note?.number ?? 0))
            var attrs = AttributeContainer().foregroundColor(configuration.linkTintColor)
            setFont(&attrs, bodyFont)
            display.mergeAttributes(attrs)
            if let url = note?.url { display.link = url }
            // plainSpan = 源 `^[…]` 的 plain 计数(预处理时算好);驱动方按未预处理 AST 记账。
            plainSpan = inlineFootnoteTokens[index]?.plainSpan ?? sourceText.count
        }
        let n = display.characters.count
        appendMap(storageCount: n, plainSpan: plainSpan)
        revealCursor += n
        return TextContent(.attributedString(display))
    }

    private func mediumWeightFont(ofSize size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        UIFont.systemFont(ofSize: size, weight: .medium)
        #else
        NSFont.systemFont(ofSize: size, weight: .medium)
        #endif
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> TextContent {
        appendMap(storageCount: 1, plainSpan: 1)  // markdownRevealPlainText 把 softBreak 计为 "\n"
        revealCursor += 1
        return RichText.Space(1).textContent
    }

    /// A hard break inside a paragraph is a line separator (U+2028), not a newline: a
    /// newline would start a new paragraph and add the paragraph spacing, where the
    /// break only ends a line.
    mutating func visitLineBreak(_ lineBreak: Markdown.LineBreak) -> TextContent {
        appendMap(storageCount: 1, plainSpan: 1)
        revealCursor += 1
        return TextContent(.attributedString(AttributedString("\u{2028}")))
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> TextContent {
        var attributed = baseAttributed(inlineCode.code)
        if let style = typography.inlineCode {
            #if canImport(UIKit)
            attributed.uiKit.font = style.font(at: dynamicTypeSize, monospaced: true)
            #elseif os(macOS)
            attributed.appKit.font = style.font(at: dynamicTypeSize, monospaced: true)
            #endif
        }
        let tint = configuration.inlineCodeTintColor
        attributed.foregroundColor = tint
        attributed.backgroundColor = tint.opacity(0.1)
        let content = TextContent(.attributedString(markRevealOffsets(attributed, start: revealCursor)))
        appendMap(storageCount: attributed.characters.count, plainSpan: inlineCode.markdownRevealPlainText.count)
        revealCursor += attributed.characters.count
        return content
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> TextContent {
        // 对齐原版 CmarkNodeVisitor.visitInlineHTML:<br> → 换行,其余显示原文。
        // replacement 与 markdownRevealPlainText 同源(MarkdownInlineHTML),plain 记账天然一致。
        let display = MarkdownInlineHTML.replacementText(for: inlineHTML.rawHTML) ?? inlineHTML.rawHTML
        let content = TextContent(.attributedString(markRevealOffsets(baseAttributed(display), start: revealCursor)))
        appendMap(storageCount: display.count, plainSpan: inlineHTML.markdownRevealPlainText.count)
        revealCursor += display.count
        return content
    }

    /// `^[…](color: red)` 一类的行内样式(MarkdownInlineStyle):子内容照常渲染,再合并文字色/
    /// 高亮底色;笔迹打 RichText scope 的 PenMarkAttribute(SelectablePenMarkOverlay 据此绘制)。
    /// 节点本身不占字符,storage/plain 记账由子节点完成。
    mutating func visitInlineAttributes(_ attributes: InlineAttributes) -> TextContent {
        let content = descendInto(attributes)
        guard let style = MarkdownInlineStyle(attributes: attributes.attributes) else { return content }
        var container = style.colorAttributes()
        if let pen = style.pen {
            let seed = MarkdownPenMarkSyntax.contentSeed(attributes.plainText)
            container[AttributeScopes.RichTextAttributes.PenMarkAttribute.self] =
                MarkdownPenMarkSyntax.encodeAttributeValue(kind: pen, color: style.ink, seed: seed)
        }
        return content.mergingAttributes(container)
    }

    mutating func visitEmphasis(_ emphasis: Markdown.Emphasis) -> TextContent {
        applyingCJKObliqueness(
            mergeInlinePresentationIntent(.emphasized, children: Array(emphasis.children))
        )
    }

    mutating func visitStrong(_ strong: Strong) -> TextContent {
        // 加粗带 emphasis 主题色(同魔改 visitStrong),但不能整段盖前景:
        // `**==高亮==**` 时高亮底色=主题色,文字再涂主题色就隐形了 ——
        // 只给不带高亮底色的 run 上色,高亮 run 保留自己的反色前景。
        let content = mergeInlinePresentationIntent(.stronglyEmphasized, children: Array(strong.children))
        return TextContent(content.fragments.map { fragment in
            guard case .attributedString(var attr) = fragment else { return fragment }
            let plainRanges = attr.runs.compactMap { run in
                run.backgroundColor == nil ? run.range : nil
            }
            for range in plainRanges {
                attr[range].foregroundColor = configuration.preferredColor
            }
            return .attributedString(attr)
        })
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> TextContent {
        mergeInlinePresentationIntent(.strikethrough, children: Array(strikethrough.children))
    }

    mutating func visitLink(_ link: Markdown.Link) -> TextContent {
        // App 注入的自定义行内链接(MarkdownInlineLinkRenderers:本地文件引用 = 文件类型
        // 图标 + 文件名)—— 原版在 CmarkNodeVisitor.visitLink 消费同一钩子;不接的话
        // 可选择管线里文件链接的前置图标整个丢失。
        if let custom = customInlineLinkContent(link) {
            return custom
        }
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

    /// builder(App 注入)返回的 AttributedString 拆两类 run 重组进可选文本流:
    /// - inlineSymbol run(\u{FFFC} 占位)→ hosted InlineView 图标。铁律:TextKit2 的 image
    ///   附件由独立子视图渲染,fragment 逐字 alpha 管不到 → 须 StreamingRevealGate 原子淡入;
    ///   原版符号与文本间的 NBSP 烤成图标视图 trailing 留白,文本侧剥掉,保持 1:1 映射。
    /// - 其余文本 run → 正文字体 + builder 的 link/前景/下划线,per-glyph 参与 reveal
    ///   (与源 plain 计数一致时逐字映射;不一致时整段锚在起点,余量在尾部收口)。
    private mutating func customInlineLinkContent(_ link: Markdown.Link) -> TextContent? {
        guard MarkdownInlineLinkRenderers.shared.builder != nil,
              let destination = link.destination else { return nil }
        let tint = configuration.linkTintColor
        let plainLabel = link.plainText
        // visitor 由 @MainActor 的 render 驱动(builder 本身 @MainActor)。
        let built = MainActor.assumeIsolated {
            MarkdownInlineLinkRenderers.shared.builder?(destination, plainLabel, tint)
        }
        guard let built else { return nil }

        // 预扫:文本总字数(剥一次符号后的前导 NBSP,它单独记账)决定 1:1 还是锚定映射。
        var totalTextCount = 0
        var probeSawSymbol = false
        var probeStripped = false
        for run in built.runs {
            if run[MarkdownInlineSymbolAttribute.self] != nil {
                probeSawSymbol = true
                continue
            }
            var text = String(built[run.range].characters)
            if probeSawSymbol, !probeStripped, text.hasPrefix("\u{00A0}") {
                text.removeFirst()
                probeStripped = true
            }
            totalTextCount += text.count
        }
        guard probeSawSymbol || totalTextCount > 0 else { return nil }
        let plainTotal = link.markdownRevealPlainText.count
        let oneToOne = totalTextCount == plainTotal

        var content = TextContent([])
        var plainRemaining = plainTotal
        var sawSymbol = false
        var handledNBSP = false
        for run in built.runs {
            if let symbol = run[MarkdownInlineSymbolAttribute.self] {
                sawSymbol = true
                content += inlineLinkSymbolPiece(
                    symbol: symbol,
                    url: run.link,
                    color: run.foregroundColor ?? tint,
                    destination: destination
                )
                continue
            }
            let text = String(built[run.range].characters)
            guard !text.isEmpty else { continue }
            // 符号后的前导 NBSP **保留为真实文本**:NBSP 是 UAX14 GL 类(前后都禁断行),
            // 把图标 attachment 和文件名粘成一个换行单元 —— 剥掉换成图标 trailing 留白的话,
            // attachment 占位符后就是合法断点,文件名稍长就把图标孤在行尾。与原版同语义
            //(原版 label 就含 NBSP,复制行为也一致);映射单独记账 storage 1 / plain 0。
            let leadingNBSP = sawSymbol && !handledNBSP && text.hasPrefix("\u{00A0}")
            if leadingNBSP { handledNBSP = true }
            var attr = AttributedString(text)
            var attrs = AttributeContainer()
            setFont(&attrs, bodyFont)
            attr.mergeAttributes(attrs)
            if let color = run.foregroundColor { attr.foregroundColor = color }
            if let url = run.link { attr.link = url }
            if run.underlineStyle != nil { attr.underlineStyle = .single }
            attr = markRevealOffsets(attr, start: revealCursor)
            let n = text.count
            if leadingNBSP {
                appendMap(storageCount: 1, plainSpan: 0)  // NBSP:锚在链接起点,随图标揭示
                let rest = n - 1
                let span = oneToOne ? rest : min(rest, plainRemaining)
                appendMap(storageCount: rest, plainSpan: span)
                plainRemaining -= span
            } else {
                let span = oneToOne ? n : min(n, plainRemaining)
                appendMap(storageCount: n, plainSpan: span)
                plainRemaining -= span
            }
            revealCursor += n
            content += TextContent(.attributedString(attr))
        }
        // plain 余量收口(builder 文本比源 plain 短,如 label 空时用文件名):
        // 0 storage 消耗剩余 plain,保证后续节点的 plain 锚点不漂。
        if plainRemaining > 0 {
            appendMap(storageCount: 0, plainSpan: plainRemaining)
        }
        return content
    }

    /// 文件链接前置图标:hosted InlineView(1 storage 字符、0 plain 单位,锚在链接起点,
    /// frontier 过起点即随文淡现)。缓存键含 id/锚点/manager 身份,同 chip/checkbox 管线。
    private mutating func inlineLinkSymbolPiece(
        symbol: String,
        url: URL?,
        color: Color,
        destination: String
    ) -> TextContent {
        let plainStart = plainCursor
        appendMap(storageCount: 1, plainSpan: 0)
        revealCursor += 1
        let id = attachmentCounter
        attachmentCounter += 1
        let mgrKey = streamingManager.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "nil"
        // config 指纹入键:图标颜色(linkTint,按深浅色算死的静态色)烤在 hosted 视图里,
        // 不失效的话切换外观后文名文本换新色、图标停旧色。
        let key = "ilsym\u{1}\(symbol)\u{1}\(destination)\u{1}\(plainStart)\u{1}\(id)\u{1}\(mgrKey)\u{1}\(configuration.stableFingerprint)"
        if let cache = blockViewCache, let hit = cache.hitContent(key) { return hit }
        let view = injectRevealEnvironment(
            SelectableInlineLinkSymbol(
                systemName: symbol,
                size: bodyFont.pointSize,
                color: color,
                url: url
            )
            .environment(\.markdownTextOffsetBase, plainStart)
        )
        let piece = TextContent {
            // 纯装饰图标不参与复制:replacement 空串,copy 时整个附件被干净移除。
            InlineView(
                id: SelectableInlineViewID(index: id),
                replacement: AttributedString(),
                sizing: .fittingLineFragment
            ) {
                view
            }
        }
        blockViewCache?.storeContent(key, piece)
        return piece
    }

    // MARK: - block

    mutating func visitParagraph(_ paragraph: Paragraph) -> TextContent {
        let hlStart = storageToPlain.count
        return paragraphContainer(applyingCrossNodeHighlight(descendInto(paragraph), storageStart: hlStart))
    }

    mutating func visitHeading(_ heading: Heading) -> TextContent {
        let hlStart = storageToPlain.count
        return headingContainer(applyingCrossNodeHighlight(descendInto(heading), storageStart: hlStart), level: heading.level)
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

    /// 跨 node 高亮:`baseAttributed` 逐 text-node 处理 `==高亮==`,单个 node 里只有半个 `==`
    /// 的情况(高亮内含行内代码/加粗/链接等,把 span 劈成多个 node)匹配不上 —— 在段落/标题/
    /// 列表项**内容组装完**后再扫一遍整段:补套底色/前景 + 删两侧 `==`,并同步修 storageToPlain
    /// 尾段(删的 `==` 各占 1 storage/1 plain,后续 plain 值下移;reveal 计数侧本就已 strip)。
    /// storageStart = descendInto 前的 storageToPlain.count(本段内容在映射表尾部,1:1 对应扁平字符)。
    private mutating func applyingCrossNodeHighlight(_ content: TextContent, storageStart: Int) -> TextContent {
        guard MarkdownHighlightSyntax.isEnabled, interpretsTextSyntax else { return content }
        // 扁平化成字符串(view 附件 = 1 个 ￼,与 storage/映射 1:1)。
        var flat = ""
        for f in content.fragments {
            switch f {
            case .string(let s): flat += s
            case .attributedString(let a): flat += String(a.characters)
            case .view: flat.append("\u{FFFC}")
            }
        }
        let matches = MarkdownHighlightSyntax.matchOffsets(flat)
        guard !matches.isEmpty else { return content }

        var removeSet = Set<Int>()
        var styleRanges: [Range<Int>] = []
        for m in matches {
            for o in m.start..<m.innerStart { removeSet.insert(o) }
            for o in m.innerEnd..<m.end { removeSet.insert(o) }
            styleRanges.append(m.innerStart..<m.innerEnd)
        }
        func styled(_ o: Int) -> Bool { styleRanges.contains { $0.contains(o) } }
        let bg = MarkdownHighlightSyntax.backgroundColor
        let fg = MarkdownHighlightSyntax.foregroundColor

        // 重建 fragments:未触及的整段透传;触及的逐字重建(删定界符 + 套高亮属性)。
        var newFragments: [TextContent.Fragment] = []
        var offset = 0
        for f in content.fragments {
            let len: Int
            switch f {
            case .string(let s): len = s.count
            case .attributedString(let a): len = a.characters.count
            case .view: len = 1
            }
            let frange = offset..<(offset + len)
            let touched = removeSet.contains { frange.contains($0) }
                || styleRanges.contains { $0.overlaps(frange) }
            if !touched {
                newFragments.append(f)
                offset += len
                continue
            }
            switch f {
            case .view:
                // 附件不含 `==`,不会被删;若落在 inner 区间也无法套底色 → 原样保留。
                newFragments.append(f)
                offset += 1
            case .string(let s):
                var rebuilt = AttributedString()
                var any = false
                for ch in s {
                    if !removeSet.contains(offset) {
                        var piece = AttributedString(String(ch))
                        #if canImport(UIKit)
                        piece.uiKit.font = bodyFont
                        #elseif os(macOS)
                        piece.appKit.font = bodyFont
                        #endif
                        if styled(offset) {
                            if let bg { piece.backgroundColor = bg }
                            if let fg { piece.foregroundColor = fg }
                        }
                        rebuilt += piece; any = true
                    }
                    offset += 1
                }
                if any { newFragments.append(.attributedString(rebuilt)) }
            case .attributedString(let a):
                var rebuilt = AttributedString()
                var any = false
                var idx = a.characters.startIndex
                while idx < a.characters.endIndex {
                    let next = a.characters.index(after: idx)
                    if !removeSet.contains(offset) {
                        var piece = AttributedString(a[idx..<next])  // 保留原 run 属性
                        if styled(offset) {
                            if let bg { piece.backgroundColor = bg }
                            if let fg { piece.foregroundColor = fg }
                        }
                        rebuilt += piece; any = true
                    }
                    idx = next; offset += 1
                }
                if any { newFragments.append(.attributedString(rebuilt)) }
            }
        }

        // 修 storageToPlain 尾段:删掉定界符位置,后续 plain 值按前面已删数下移。
        if storageStart <= storageToPlain.count {
            var newTail: [Int] = []
            var removedBefore = 0
            for (i, plainVal) in storageToPlain[storageStart...].enumerated() {
                if removeSet.contains(i) { removedBefore += 1 }
                else { newTail.append(plainVal - removedBefore) }
            }
            storageToPlain.replaceSubrange(storageStart..., with: newTail)
            plainCursor -= removedBefore
            revealCursor -= removedBefore
        }
        return TextContent(newFragments)
    }

    /// 基准 inline AttributedString:套正文 PlatformFont(RichText 叠 trait 用)+ 处理 ==高亮==。
    private func baseAttributed(_ string: String) -> AttributedString {
        var attributed = AttributedString(string)
        #if canImport(UIKit)
        attributed.uiKit.font = bodyFont
        #elseif os(macOS)
        attributed.appKit.font = bodyFont
        #endif
        // 基础正文字色(ThinkingView 等宿主的 secondary):不落 run 时 UITextView 恒画
        // label 黑。先于高亮处理:高亮区间的反色前景在 applied(to:) 里覆盖。
        if let baseTextColor = configuration.baseTextColor {
            attributed.foregroundColor = baseTextColor
        }
        // 笔迹注记:剥定界符 + PenMarkAttribute 进 storage(reveal 计数两侧同链已对齐),
        // 笔迹由 SelectablePenMarkOverlay 绘制。
        guard interpretsTextSyntax else { return attributed }
        return MarkdownPenMarkSyntax.appliedSelectable(
            to: MarkdownHighlightSyntax.applied(to: attributed)
        )
    }

    /// 段落容器:对齐原版 visitParagraph 的 `.padding(.vertical, 5)` + 块间 VStack(componentSpacing)。
    /// TextKit 侧:上 5 落 paragraphSpacingBefore(文档首段 no-op,由视图级 edge inset 补);
    /// 下 5 + componentSpacing 落 paragraphSpacing —— 扣掉 TextKit 在段落末行后自动加的
    /// lineSpacing(行距在段落交界也生效),净 junction = 5 + componentSpacing + 5,与原版一致。
    private func paragraphContainer(_ content: TextContent) -> TextContent {
        // CJK 行盒补偿:TextKit2 行高 = max(行内各 run 字体 ascent+descent),CJK 字符落
        // fallback(PingFang 16pt ≈ 22.0)比主字体(SF ≈ 20.29)高 ~1.7pt/行;原版 SwiftUI
        // Text 始终按主字体 metrics 取行高 → 逐行累积偏大。min/maximumLineHeight 被 TextKit2
        // 无视(实测钉 20.29 行高仍 22.0),样式层唯一杠杆 = 含 CJK 的段落把 lineSpacing 减去
        // 该差值:基线 pitch 与原版一致(20.29+5),残差收敛为段首一次性 +Δ(行盒加高在
        // 首行上方,不再逐行累积)。junction 公式用同一 effective 值,段落交界净距不变。
        let spacing = effectiveLineSpacing(for: content)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 5
        style.paragraphSpacing = max(0, 5 + configuration.componentSpacing - spacing)
        style.lineSpacing = spacing
        return content.mergingAttributes(
            AttributeContainer([.paragraphStyle: style as NSParagraphStyle])
        )
    }

    /// 含 CJK 字符的内容:行距减去 CJK fallback 行盒与主字体行盒的差值(见 paragraphContainer 注)。
    private func effectiveLineSpacing(for content: TextContent) -> CGFloat {
        guard lineSpacing > 0 else { return lineSpacing }
        let delta = Self.cjkLineBoxDelta(for: bodyFont)
        guard delta > 0 else { return lineSpacing }
        let hasCJK = content.fragments.contains { fragment in
            guard case .attributedString(let attr) = fragment else { return false }
            return attr.characters.contains { $0.triggersCJKLineBox }
        }
        guard hasCJK else { return lineSpacing }
        return max(0, lineSpacing - delta)
    }

    /// CJK fallback(PingFang)与主字体的行盒(ascent+descent)差值,按字号缓存。
    private static var cjkLineBoxDeltaCache: [CGFloat: CGFloat] = [:]
    private static func cjkLineBoxDelta(for font: PlatformFont) -> CGFloat {
        if let cached = cjkLineBoxDeltaCache[font.pointSize] { return cached }
        let primary = font.ascender - font.descender
        var fallback = primary
        #if canImport(UIKit)
        if let pingfang = UIFont(name: "PingFangSC-Regular", size: font.pointSize) {
            fallback = pingfang.ascender - pingfang.descender
        }
        #elseif os(macOS)
        if let pingfang = NSFont(name: "PingFangSC-Regular", size: font.pointSize) {
            fallback = pingfang.ascender - pingfang.descender
        }
        #endif
        let delta = max(0, fallback - primary)
        cjkLineBoxDeltaCache[font.pointSize] = delta
        return delta
    }

    /// 标题容器:字号/字重 + 上下 padding。对齐原版 MarkdownHeading 的 `.padding(HeadingPaddings[level])`
    ///(h1 上12下6、h2 上10下5、h3 上8下4、h4 上6下3、h5 上4下2、h6 上2下1)。
    /// spacing 覆写供 Extended Heading 交界间距归零。
    private func headingContainer(
        _ content: TextContent,
        level: Int,
        spacingBeforeOverride: CGFloat? = nil,
        spacingAfterOverride: CGFloat? = nil,
        lineSpacingOverride: CGFloat? = nil
    ) -> TextContent {
        let padding = headingPaddings[min(max(level, 1), 6)]
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBeforeOverride ?? padding.top
        // 后随块的 junction = 本级 bottom padding + 块间 componentSpacing(扣掉 TextKit 自动加的 lineSpacing);
        // 文档末块 no-op(由视图级 edge inset 补 bottom padding)。
        style.paragraphSpacing = spacingAfterOverride
            ?? max(0, padding.bottom + configuration.componentSpacing - lineSpacing)
        style.lineSpacing = lineSpacingOverride ?? lineSpacing
        var container = AttributeContainer([.paragraphStyle: style as NSParagraphStyle])
        #if canImport(UIKit)
        container.uiKit.font = headingFont(level)
        #elseif os(macOS)
        container.appKit.font = headingFont(level)
        #endif
        return content.mergingAttributes(container)
    }

    /// 对齐原版 MarkdownHeading:字号/字重来自 typography(standard = title/title2/title3/headline,
    /// h1 .heavy / h2 .bold / h3 .semibold / h4-6 .medium),按环境动态字型档位解析。
    /// 不能用 bodyFont×倍率推导 —— 字号与原版明显不一致(h2 23.8 vs 22 等)。
    private func headingFont(_ level: Int) -> PlatformFont {
        typography.heading(level).font(at: dynamicTypeSize)
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
        // config 指纹入键:rootView 在这里把 env config(含按深浅色算死的主题色)烤进
        // AnyView,切换外观后不失效的话块附件(代码块/表格等)颜色停在旧模式。
        let cacheKey = "\(markup.format())\u{1}\(blockStart)\u{1}\(id)\u{1}\(configOverride != nil)\u{1}\(blockMgrKey)\u{1}\(configuration.stableFingerprint)"
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
            // 块附件参与复制,内容 = 块源文(代码围栏/表格等原 markdown)。
            InlineView(
                id: SelectableInlineViewID(index: id),
                replacement: AttributedString(markup.format()),
                sizing: .fittingLineFragment
            ) { view }
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
                // 公式间的正文段:走脚注感知切分(同一 Text 节点可同时含公式与脚注 token)。
                content += footnoteAwareTextContent(
                    String(plain[search.lowerBound..<match.range.lowerBound]),
                    isNodeStart: search.lowerBound == plain.startIndex
                )
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
                        // $…$ 包裹:粘贴回输入框/markdown 编辑器可还原公式(裸 LaTeX 不可)。
                        replacement: AttributedString("$\(latex)$"),
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
            content += footnoteAwareTextContent(
                String(plain[search]),
                isNodeStart: search.lowerBound == plain.startIndex
            )
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
                    #elseif os(macOS)
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
        // 自定义 bullet 标记:内容渲染用剥掉 `{token}` 前缀的副本(标记本身由 makeListMarker 呈现);
        // 且不要行首 leadingIndentation(顶格;嵌套缩进由外层 padding 承担)。
        let contentItem = listItem.strippingCustomMarker()
        let effectiveBaseIndent = listItem.customListMarkerMatch != nil ? 0 : baseIndent
        // marker 随内容首字符揭示:marker/tab 占 storage 字符但 0 plain 单位(锚在内容首字符的 plain 起点)。
        let (marker, markerWidth) = makeListMarker(listItem, revealOffset: plainCursor)
        let markerStorageCount = marker.fragments.reduce(0) { $0 + $1.asAttributedString().characters.count }
        appendMap(storageCount: markerStorageCount, plainSpan: 0)
        appendMap(storageCount: 2, plainSpan: 0)  // "\t" + WORD JOINER(见下)
        revealCursor += markerStorageCount + 2
        let contentIndent = effectiveBaseIndent + markerWidth + spacing

        // leading = item 首段(inline,可选);trailing = 嵌套 list / 其他 block。
        // 注意映射顺序:leading 先 visit(记账),trailing 的 "\n" 分隔在其内容 visit **之前**记账。
        var leadingContent = TextContent([])
        var trailingContent = TextContent([])
        var trailingSeparatorPending = false
        for child in contentItem.children {
            if child is Paragraph {
                let hlStart = storageToPlain.count
                leadingContent += applyingCrossNodeHighlight(descendInto(child), storageStart: hlStart)
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

        // style 在内容 visit 之后构造:CJK 行盒补偿要看 leading 文本(见 paragraphContainer 注)。
        let itemStyle = NSMutableParagraphStyle()
        itemStyle.firstLineHeadIndent = effectiveBaseIndent // marker 起始(自定义 bullet 顶格 → 0)
        itemStyle.headIndent = contentIndent                // wrap 内容缩进对齐
        itemStyle.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
        // 原版 list row 内容也是 visitParagraph 产物(.padding(.vertical,5))+ 行间 VStack(componentSpacing):
        // 与 paragraphContainer 同一套上 5 / 下 5+componentSpacing−lineSpacing 记账。
        let itemLineSpacing = effectiveLineSpacing(for: leadingContent)
        itemStyle.paragraphSpacingBefore = 5
        itemStyle.paragraphSpacing = max(0, 5 + configuration.componentSpacing - itemLineSpacing)
        itemStyle.lineSpacing = itemLineSpacing

        let paragraphOnly = AttributeContainer([.paragraphStyle: itemStyle as NSParagraphStyle])
        var itemAttrs = paragraphOnly
        setFont(&itemAttrs, bodyFont)

        return TextContent {
            marker.mergingAttributes(paragraphOnly)        // marker 保留灰色/字体,只加段落样式
            // tab → contentIndent;tab 后跟 WORD JOINER(U+2060,UAX14 LB11 前后禁断):
            // 原版 list 是 HStack 双列,marker 永不与内容分行;文本流模拟里 tab 后是合法
            // 断点,内容首单元过宽(典型 = 文件链接的图标+NBSP+长文件名整体粘连)会被
            // 整体断到下一行,marker 孤在首行。WJ 把 tab 与首单元粘死,过宽 token 只能
            // 走行内 emergency break(长文件名行中折断),与原版双列观感一致。
            AttributedString("\t\u{2060}", attributes: itemAttrs)
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
            // checkbox = hosted InlineView + StreamingRevealGate(与 chip 同管线,gate 的
            // fresh-activation/首帧判定现成)—— 对齐原版 _markerView 的 StreamingRevealMarker 语义。
            // 曾试 image NSTextAttachment:TextKit2 把 image 附件交给独立子视图渲染(allowsTextAttachmentView
            // 关掉也不可靠),fragment 的逐字 alpha 管不到 → 无淡入。
            let checked = checkbox == .checked
            let size = bodyFont.pointSize
            let id = attachmentCounter
            attachmentCounter += 1
            let anchor = plainCursor  // marker 随内容首字符揭示
            let mgrKey = streamingManager.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "nil"
            let key = "checkbox\u{1}\(checked)\u{1}\(anchor)\u{1}\(id)\u{1}\(mgrKey)"
            if let cache = blockViewCache, let hit = cache.hitContent(key) { return (hit, size) }
            let view = injectRevealEnvironment(
                SelectableTaskCheckbox(checked: checked, size: size)
                    .environment(\.markdownTextOffsetBase, anchor)
            )
            let content = TextContent {
                InlineView(
                    id: SelectableInlineViewID(index: id),
                    replacement: AttributedString(checked ? "[x]" : "[ ]"),
                    sizing: .fittingLineFragment
                ) {
                    view
                }
            }
            blockViewCache?.storeContent(key, content)
            return (content, size)
        }
        // 自定义 bullet:emoji 用文字 marker(inline,不破坏 tab 布局);SF Symbol 用 hosted
        // InlineView(高亮圆底白字)。symbol 上报宽度 = 实际圆直径,否则会吃掉与内容的间距。
        if let match = listItem.customListMarkerMatch {
            switch match.marker {
            case .emoji(let e):
                var attrs = AttributeContainer()
                setFont(&attrs, bodyFont)
                let attr = AttributedString(e, attributes: attrs)
                let width = (e as NSString).size(withAttributes: [.font: bodyFont]).width
                return (TextContent(.attributedString(attr)), width)
            case .symbol(let name):
                let diameter = bodyFont.pointSize * 1.2
                let id = attachmentCounter
                attachmentCounter += 1
                let anchor = plainCursor
                let mgrKey = streamingManager.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "nil"
                let key = "listsym\u{1}\(name)\u{1}\(anchor)\u{1}\(id)\u{1}\(mgrKey)"
                if let cache = blockViewCache, let hit = cache.hitContent(key) { return (hit, diameter) }
                let view = injectRevealEnvironment(
                    SelectableListSymbolMarker(systemName: name, diameter: diameter)
                        .environment(\.markdownTextOffsetBase, anchor)
                )
                let content = TextContent {
                    InlineView(
                        id: SelectableInlineViewID(index: id),
                        replacement: AttributedString("- "),  // 复制退回标准 bullet
                        sizing: .fittingLineFragment
                    ) {
                        view
                    }
                }
                blockViewCache?.storeContent(key, content)
                return (content, diameter)
            }
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

    private func setFont(_ container: inout AttributeContainer, _ font: PlatformFont) {
        #if canImport(UIKit)
        container.uiKit.font = font
        #elseif os(macOS)
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

// MARK: - 文本级行内锚插入(话题气泡)

#if canImport(UIKit)
extension MarkdownSelectableText {
    /// 把 hosted 气泡附件按 plain 偏移插进已渲染内容(post-render):
    /// 附件 = storage 1 字符 / plain 0 单位(映射插桩,revealTotal 不变),
    /// 气泡随锚点末字符揭示(StreamingRevealGate,阈值 = plainOffset-1)。
    /// 从 plain 偏移降序处理,先插靠后的,前面的 storage 索引保持有效。
    @MainActor
    static func insertingInlineAnchors(
        _ anchors: [MarkdownTextInlineAnchor],
        into result: (content: TextContent, revealTotal: Int, storageToPlain: [Int]),
        openURL: OpenURLAction?,
        streamingManager: StreamingRevealManager?,
        fadeConfig: MarkdownFadeRevealConfig?,
        bubbleSize: CGFloat,
        dynamicTypeSize: DynamicTypeSize?,
        topicPreview: (@MainActor (String) -> AnyView?)? = nil
    ) -> (content: TextContent, revealTotal: Int, storageToPlain: [Int]) {
        var fragments = result.content.fragments
        var map = result.storageToPlain

        for (seq, anchor) in anchors.sorted(by: { $0.plainOffset > $1.plainOffset }).enumerated() {
            // storage 插入点 = 第一个 plain 起点 >= offset 的字符位置(lowerBound 二分)。
            var lo = 0, hi = map.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if map[mid] < anchor.plainOffset { lo = mid + 1 } else { hi = mid }
            }
            let storagePos = lo

            // preview 闭包只烤引用不烤结果:渲染可能早于控制器挂接(singleFlowVM 尚 nil),
            // 急切求值会把 nil 烤死进渲染缓存;长按弹菜单那一刻才解析。
            let anchorId = anchor.id
            var previewProvider: (@MainActor () -> AnyView?)? = nil
            if let tp = topicPreview {
                previewProvider = { tp(anchorId) }
            }
            var view = AnyView(
                SelectableTopicBubble(
                    size: bubbleSize,
                    url: anchor.url,
                    openActionTitle: anchor.openActionTitle,
                    previewProvider: previewProvider
                )
                .environment(\.markdownStreaming, streamingManager)
                .environment(\.markdownFadeReveal, fadeConfig)
                .environment(\.markdownTextOffsetBase, max(0, anchor.plainOffset - 1))
            )
            if let openURL { view = AnyView(view.environment(\.openURL, openURL)) }
            if let dynamicTypeSize { view = AnyView(view.environment(\.dynamicTypeSize, dynamicTypeSize)) }
            let bubble = TextContent {
                // 话题气泡是导航示能不是内容:不参与复制(replacement 空串)。
                InlineView(
                    id: SelectableInlineViewID(index: 1_000_000 + seq),
                    replacement: AttributedString(),
                    sizing: .fittingLineFragment
                ) {
                    view
                }
            }
            guard let bubbleFragment = bubble.fragments.first else { continue }

            // fragment 定位;落在片段内部时切开再插。
            var cursor = 0
            var idx = 0
            var inserted = false
            while idx < fragments.count {
                let count = fragmentLength(fragments[idx])
                if storagePos <= cursor {
                    fragments.insert(bubbleFragment, at: idx)
                    inserted = true
                    break
                }
                if storagePos < cursor + count {
                    let local = storagePos - cursor
                    let (head, tail) = splitFragment(fragments[idx], at: local)
                    fragments.replaceSubrange(idx...idx, with: [head, bubbleFragment, tail].compactMap { $0 })
                    inserted = true
                    break
                }
                cursor += count
                idx += 1
            }
            if !inserted { fragments.append(bubbleFragment) }

            map.insert(anchor.plainOffset, at: min(storagePos, map.count))
        }

        return (TextContent(fragments), result.revealTotal, map)
    }

    /// 区间装饰(mark 下划线):把着色下划线属性落到 plain 区间对应的 storage 范围。
    /// 只改属性不改长度,映射不动;按数组顺序覆盖(调用方把最新的排最后 = 显示最新色)。
    static func applyingRangeDecorations(
        _ decorations: [MarkdownTextRangeDecoration],
        to content: TextContent,
        storageToPlain map: [Int]
    ) -> TextContent {
        guard !map.isEmpty else { return content }
        var fragments = content.fragments

        func lowerBound(_ plain: Int) -> Int {
            var lo = 0, hi = map.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if map[mid] < plain { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        for deco in decorations {
            let s = lowerBound(deco.plainStart)
            let e = lowerBound(deco.plainStart + deco.plainLength)
            guard e > s else { continue }

            var cursor = 0
            for idx in fragments.indices {
                let length = fragmentLength(fragments[idx])
                let fragmentStart = cursor
                let fragmentEnd = cursor + length
                cursor = fragmentEnd
                guard fragmentEnd > s, fragmentStart < e,
                      case .attributedString(var attr) = fragments[idx] else { continue }
                let localStart = max(0, s - fragmentStart)
                let localEnd = min(length, e - fragmentStart)
                let chars = attr.characters
                guard let li = chars.index(chars.startIndex, offsetBy: localStart, limitedBy: chars.endIndex),
                      let ui = chars.index(chars.startIndex, offsetBy: localEnd, limitedBy: chars.endIndex),
                      ui > li else { continue }
                // 只落 underlineColor **不落 underlineStyle**:系统下划线紧贴文本下沿且
                // 位置不可调;InlineAttachmentTextView 布局后按「有色无 style」的区间自绘
                // 分离式下划线条(同厚度、下移出间隙)。
                // link 让区间可点(空 linkTextAttributes → 不改样式),点击弹浮动菜单。
                attr[li..<ui].uiKit.underlineColor = UIColor(deco.underlineColor)
                if let url = deco.tapURL {
                    if deco.preservesInnerLinks {
                        // 只给尚无链接的 run 挂 tapURL:整段可点,但内容里的真实链接保持各自点击。
                        // 先收集 range 再赋值,避免边遍历 runs 边改属性。
                        let gapRanges = attr[li..<ui].runs.compactMap { run in
                            run.link == nil ? run.range : nil
                        }
                        for range in gapRanges {
                            attr[range].link = url
                        }
                    } else {
                        attr[li..<ui].link = url  // .link 在 foundation 作用域,非 uiKit
                    }
                }
                fragments[idx] = .attributedString(attr)
            }
        }
        return TextContent(fragments)
    }

    private static func fragmentLength(_ fragment: TextContent.Fragment) -> Int {
        switch fragment {
        case .string(let s): return s.count
        case .attributedString(let a): return a.characters.count
        case .view: return 1
        }
    }

    /// 在片段内部第 local 个字符前切开(边界侧返回 nil,由调用方 compactMap 收掉)。
    private static func splitFragment(
        _ fragment: TextContent.Fragment,
        at local: Int
    ) -> (TextContent.Fragment?, TextContent.Fragment?) {
        switch fragment {
        case .string(let s):
            let i = s.index(s.startIndex, offsetBy: min(local, s.count))
            let head = String(s[..<i]), tail = String(s[i...])
            return (head.isEmpty ? nil : .string(head), tail.isEmpty ? nil : .string(tail))
        case .attributedString(let a):
            let chars = a.characters
            guard let i = chars.index(chars.startIndex, offsetBy: local, limitedBy: chars.endIndex),
                  i > a.startIndex, i < a.endIndex else {
                return local <= 0 ? (nil, .attributedString(a)) : (.attributedString(a), nil)
            }
            return (
                .attributedString(AttributedString(a[a.startIndex..<i])),
                .attributedString(AttributedString(a[i..<a.endIndex]))
            )
        case .view:
            // 附件 1 字符不可切;local 只能是 0(上游 storagePos <= cursor 已处理)。
            return (nil, fragment)
        }
    }
}

/// 文本级话题入口气泡(hosted InlineView rootView):选段末尾的小胶囊图标,
/// 点击经 openURL 路由(app 拦截 flowith-topic scheme);StreamingRevealGate 原子淡入。
@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
private struct SelectableTopicBubble: View {
    let size: CGFloat
    let url: URL?
    var openActionTitle: String = "Open"
    var previewProvider: (@MainActor () -> AnyView?)? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        StreamingRevealGate { _, visible in
            bubble
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: visible)
        }
    }

    private var bubble: some View {
        Image(systemName: "ellipsis.bubble")
            .font(.system(size: size * 0.72))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color.gray.opacity(0.12)))
            .padding(.leading, 3)
            // SwiftUI 手势 / .contextMenu 在 textView 附件宿主里装不上交互
            //(长按会落到外层块级菜单),tap + 长按预览统一走最深处的 UIKit 交互桥。
            .overlay {
                TopicBubbleInteractionBridge(
                    openActionTitle: openActionTitle,
                    previewProvider: previewProvider
                ) {
                    if let url { openURL(url) }
                }
            }
    }
}

/// 话题气泡的 UIKit 交互桥:UIContextMenuInteraction(长按预览)+ UITapGestureRecognizer(打开)。
/// 挂在附件子视图最深处,长按判定优先于外层块级 contextMenu。
@available(iOS 17.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
private struct TopicBubbleInteractionBridge: UIViewRepresentable {
    let openActionTitle: String
    let previewProvider: (@MainActor () -> AnyView?)?
    let onOpen: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        view.addGestureRecognizer(
            UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap))
        )
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: TopicBubbleInteractionBridge
        init(_ parent: TopicBubbleInteractionBridge) { self.parent = parent }

        @objc func didTap() { parent.onOpen() }

        nonisolated func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            MainActor.assumeIsolated {
                // 长按此刻才解析预览:渲染期烤结果会把控制器挂接前的 nil 冻死在缓存里。
                let preview = parent.previewProvider?()
                let title = parent.openActionTitle
                let onOpen = parent.onOpen
                return UIContextMenuConfiguration(identifier: nil) {
                    guard let preview else { return nil }
                    let host = UIHostingController(rootView: preview)
                    host.preferredContentSize = CGSize(width: 360, height: 520)
                    return host
                } actionProvider: { _ in
                    UIMenu(children: [
                        UIAction(
                            title: title,
                            image: UIImage(systemName: "arrow.up.forward")
                        ) { _ in onOpen() }
                    ])
                }
            }
        }
    }
}
#endif

/// 任务列表勾选框(hosted InlineView 的 rootView):对齐原版 _markerView —— checked 用
/// checkmark.circle.fill 随 tint,unchecked 用 circle secondary;StreamingRevealGate 原子淡入
///(阈值 = 内容首字符 plain 锚点,经 markdownTextOffsetBase 注入)。
@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
private struct SelectableTaskCheckbox: View {
    let checked: Bool
    let size: CGFloat

    var body: some View {
        StreamingRevealGate { _, visible in
            Group {
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: size))
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: visible)
        }
    }
}

/// 自定义 SF Symbol bullet(hosted InlineView rootView):高亮色圆底 + 白前景,
/// 直径 = diameter(= 上报的 markerWidth);StreamingRevealGate 原子淡入(同 checkbox 管线)。
private struct SelectableListSymbolMarker: View {
    let systemName: String
    let diameter: CGFloat
    @Environment(\.markdownRendererConfiguration) private var configuration

    var body: some View {
        StreamingRevealGate { _, visible in
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(configuration.preferredColor))
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: visible)
        }
    }
}

/// 自定义行内链接的前置 SF Symbol(hosted InlineView rootView):对齐原版
/// `AttributedString.inlineSymbol` 的 Text 内联符号 —— 尺寸随正文字号、颜色随链接 tint;
/// 与文件名的间距由后随 NBSP 文本承担(兼作断行胶水,不在这里加 padding);
/// 点击走注入的 openURL(与文本段同路由);
/// StreamingRevealGate 原子淡入(阈值 = 链接起点 plain 锚,经 markdownTextOffsetBase 注入)。
@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
private struct SelectableInlineLinkSymbol: View {
    let systemName: String
    let size: CGFloat
    let color: Color
    let url: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        StreamingRevealGate { _, visible in
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(color)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let url { openURL(url) }
                }
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: visible)
        }
    }
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

    /// 会把 TextKit2 行盒抬到 CJK fallback 字体(PingFang 等)metrics 的字符:
    /// 汉字/假名/谚文/全角标点(,。「」等 CJK 标点同样走 fallback 字体渲染)。
    var triggersCJKLineBox: Bool {
        unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value)      // 部首/CJK 标点/假名/注音/统一表意
            || (0x3400...0x4DBF).contains(scalar.value)   // Ext A
            || (0xAC00...0xD7AF).contains(scalar.value)   // Hangul 音节
            || (0xF900...0xFAFF).contains(scalar.value)   // 兼容表意
            || (0xFF00...0xFFEF).contains(scalar.value)   // 全角/半角形
            || (0x20000...0x2FFFF).contains(scalar.value) // Ext B+
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
