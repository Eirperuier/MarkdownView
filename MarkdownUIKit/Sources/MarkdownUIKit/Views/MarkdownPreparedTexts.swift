//
//  MarkdownPreparedTexts.swift
//  MarkdownUIKit
//
//  Text made ahead of the rows that show it, off the main thread: parsed, attributed and laid out.
//  A row coming on screen takes what's made instead of making it within a frame, and a height is
//  known with no view at all. What's made is the same as the main thread makes; text that needs
//  the main thread (a view in a line that isn't a formula) stays with it. Text is drawn here too,
//  and code is coloured before it's drawn.
//

@_spi(MarkdownMath) import MarkdownCore
import Markdown
import UIKit

/// TextKit's three objects with text in them, and the size it comes to. Made on any thread and
/// then only read on the main one.
final class MarkdownTextStack: NSObject, NSTextLayoutManagerDelegate, @unchecked Sendable {
    let layoutManager = NSTextLayoutManager()
    /// Wraps at the width of its longest line (see `MarkdownTextHost`).
    var narrowsToText = false
    /// How far right of where its fragments say it draws: a part of a pixel.
    var shift: CGFloat = 0

    private let storage = NSTextContentStorage()
    private let container = NSTextContainer(size: .zero)
    private var measured: (width: CGFloat, size: CGSize)?

    override init() {
        super.init()
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        layoutManager.delegate = self
        storage.addTextLayoutManager(layoutManager)
    }

    func show(_ text: NSAttributedString, foregroundColor: UIColor) {
        let filled = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: filled.length)
        filled.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
            if value == nil { filled.addAttribute(.foregroundColor, value: foregroundColor, range: run) }
        }
        filled.enumerateAttribute(.font, in: range) { value, run, _ in
            if value == nil { filled.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: run) }
        }
        Self.applyIntentsAsTextViewDoes(filled, in: range)
        setStorage(filled)
    }

    private func setStorage(_ text: NSAttributedString) {
        storage.performEditingTransaction {
            storage.textStorage?.setAttributedString(text)
        }
        measured = nil
    }

    /// The same text in objects of its own, to lay out apart.
    func copy() -> MarkdownTextStack {
        let copy = MarkdownTextStack()
        copy.narrowsToText = narrowsToText
        if let text = storage.textStorage { copy.setStorage(text) }
        return copy
    }

    /// A text view takes `inlinePresentationIntent` over the font: emphasis alone on a bold font
    /// (in a heading) is the regular italic. Text in a storage of its own stays as it's given.
    static func applyIntentsAsTextViewDoes(_ text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.inlinePresentationIntent, in: range) { value, run, _ in
            guard let raw = value as? UInt, InlinePresentationIntent(rawValue: raw).contains(.emphasized),
                  !InlinePresentationIntent(rawValue: raw).contains(.stronglyEmphasized) else { return }
            text.enumerateAttribute(.font, in: run) { value, fontRun, _ in
                guard let font = value as? UIFont else { return }
                let traits = font.fontDescriptor.symbolicTraits
                guard traits.contains(.traitBold), traits.contains(.traitItalic),
                      let regular = font.fontDescriptor.withSymbolicTraits(traits.subtracting(.traitBold)) else { return }
                text.addAttribute(.font, value: UIFont(descriptor: regular, size: font.pointSize), range: fontRun)
            }
        }
    }

    func isLaidOut(atWidth width: CGFloat) -> Bool {
        measured?.width == width
    }

    /// The text's size at `width`: all of it wide, or as wide as its longest line, laid out again
    /// there, with `narrowsToText`.
    func size(forWidth width: CGFloat) -> CGSize {
        if let measured, measured.width == width { return measured.size }
        lay(atWidth: width)
        var size = CGSize(width: width, height: layoutManager.usageBoundsForTextContainer.height)
        if narrowsToText {
            let used = layoutManager.usageBoundsForTextContainer.width
            if used < width - 0.5 {
                lay(atWidth: used)
                size = CGSize(width: used, height: layoutManager.usageBoundsForTextContainer.height)
            }
        }
        // As a text view reports it: up to a pixel. A line with an attachment isn't on the grid.
        size.height = markdownPixelCeil(size.height)
        measured = (width, size)
        return size
    }

    private func lay(atWidth width: CGFloat) {
        if container.size.width != width {
            container.size = CGSize(width: width, height: 0)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    /// The text as a picture, on any thread, with its colours under `traits`. It starts at the
    /// corner of a drawn text's view; what's past the view's bottom and right edges is empty.
    func picture(scale: CGFloat, traits: UITraitCollection) -> MarkdownTextPicture? {
        guard let size = measured?.size, size.width > 0, size.height > 0 else { return nil }
        let inset = MarkdownDrawnTextView.overdraw
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let canvas = CGSize(width: (size.width + inset * 2).rounded(.up) + 1, height: (size.height + inset * 2).rounded(.up) + 1)
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
            traits.performAsCurrent {
                layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                    let frame = fragment.layoutFragmentFrame
                    // Down to the pixel grid, as a text view puts its fragment views.
                    let origin = CGPoint(x: markdownPixelFloor(frame.minX) + inset + shift, y: markdownPixelFloor(frame.minY) + inset)
                    fragment.draw(at: origin, in: renderer.cgContext)
                    for provider in fragment.textAttachmentViewProviders {
                        guard let attachment = provider.textAttachment as? MarkdownDrawnInlineAttachment else { continue }
                        attachment.draw(in: fragment.frameForTextAttachment(at: provider.location).offsetBy(dx: origin.x, dy: origin.y))
                    }
                    return true
                }
            }
        }
        return image.cgImage.map { MarkdownTextPicture(image: $0, scale: scale, traits: traits) }
    }

    /// A link looks as its own attributes have it, as in a text view with no link attributes.
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        renderingAttributesForLink link: Any,
        at location: any NSTextLocation,
        defaultAttributes renderingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any]? {
        [:]
    }
}

/// Text drawn: nothing about it is ever changed.
final class MarkdownTextPicture: @unchecked Sendable {
    let image: CGImage
    let scale: CGFloat
    let traits: UITraitCollection

    init(image: CGImage, scale: CGFloat, traits: UITraitCollection) {
        self.image = image
        self.scale = scale
        self.traits = traits
    }

    var byteCount: Int { image.bytesPerRow * image.height }
}

/// A table made ahead.
struct MarkdownPreparedTable {
    let content: MarkdownTableContent
    let geometry: MarkdownTableGeometry
    let width: CGFloat
}

/// Text made ahead for rows of one style. A host keeps one and sets it on the style it shows with.
public final class MarkdownPreparedTexts: @unchecked Sendable {
    enum Kind: Hashable {
        case text
        case quote
        case code(String?)
        case formula
        case table
    }

    struct Key: Hashable {
        let source: String
        let kind: Kind
        let depth: Int
        let category: UIContentSizeCategory?
    }

    struct Made {
        /// Nil: this text has to be built on the main thread.
        let text: MarkdownText?
        let stack: MarkdownTextStack?
        let picture: MarkdownTextPicture?
        var table: MarkdownPreparedTable?
        /// Colours the stack has on, for code.
        let colors: [(range: NSRange, color: UIColor)]
        let width: CGFloat
        /// The block's height in a row that wide.
        let height: CGFloat?
        var used: UInt64
    }

    private struct Request {
        let key: Key
        let block: MarkdownStreamBlock
        let style: MarkdownStyle
        let width: CGFloat
        let traits: UITraitCollection
    }

    /// The formulas a block shows, drawn ahead into the renderer's own caches: the row that shows
    /// them asks there as it does anyway.
    private struct Formulas {
        let block: MarkdownStreamBlock
        let foreground: String
        let inlineXHeight: CGFloat
        let displayXHeight: CGFloat
    }

    /// What's kept: a screen holds a few dozen rows. A text a row shows stays with the row too.
    private static let capacity = 512
    /// Pictures take far more room than the rest: about ten screens of text.
    private static let pictureBytes = 128 * 1024 * 1024
    /// A fast scroll asks ahead of what can be made: what it asked for long ago is past.
    private static let pendingCapacity = 64

    private let lock = NSLock()
    private var made: [Key: Made] = [:]
    private var bytesInPictures = 0
    private var pending: [Request] = []
    private var pendingFormulas: [Formulas] = []
    /// Blocks whose pictures were asked for, by their source.
    private var imagesAsked: Set<Int> = []
    private var isWorking = false
    private var working: Key?
    private var clock: UInt64 = 0
    private let queue = DispatchQueue(label: "dev.floo.markdown.prepare", qos: .userInitiated)

    public init() {}

    /// A block that may show soon, in a row `width` wide. Does nothing if it's made already.
    @MainActor
    public func request(_ block: MarkdownStreamBlock, style: MarkdownStyle, width: CGFloat, traits: UITraitCollection) {
        requestFormulas(of: block, style: style, traits: traits)
        requestImages(of: block, style: style)
        guard let job = Self.job(for: block, style: style) else { return }
        let key = Key(source: job.source, kind: job.kind, depth: job.depth, category: style.contentSizeCategory)
        lock.lock()
        defer { lock.unlock() }
        if let known = made[key], known.width == width,
           known.picture.map({ MarkdownColorTraits.resolveAlike($0.traits, traits) }) ?? true { return }
        guard !pending.contains(where: { $0.key == key && $0.width == width }) else { return }
        pending.append(Request(key: key, block: block, style: style, width: width, traits: traits))
        if pending.count > Self.pendingCapacity { pending.removeFirst() }
        guard !isWorking else { return }
        isWorking = true
        queue.async { [self] in work() }
    }

    @MainActor
    private func requestFormulas(of block: MarkdownStreamBlock, style: MarkdownStyle, traits: UITraitCollection) {
        guard block.inlineMathStorage?.isEmpty == false || MarkdownBlockView.displayFormula(of: block) != nil else { return }
        let request = Formulas(
            block: block,
            foreground: MarkdownMath.foreground(in: traits),
            inlineXHeight: MarkdownMath.font(style.inlineMathTextStyle, style: style).xHeight,
            displayXHeight: MarkdownMath.font(style.displayMathTextStyle, style: style).xHeight
        )
        lock.lock()
        defer { lock.unlock() }
        pendingFormulas.append(request)
        if pendingFormulas.count > Self.pendingCapacity { pendingFormulas.removeFirst() }
        guard !isWorking else { return }
        isWorking = true
        queue.async { [self] in work() }
    }

    /// The pictures a block shows, fetched ahead as Telegram knows a photo's size before its row
    /// shows: the row then has its height at once, and nothing below it moves when they come.
    @MainActor
    private func requestImages(of block: MarkdownStreamBlock, style: MarkdownStyle) {
        let source = block.descriptor.sourceText
        guard style.inlineImage == nil, source.contains("![") else { return }
        lock.lock()
        let isNew = imagesAsked.insert(source.hashValue).inserted
        if imagesAsked.count > Self.capacity * 4 { imagesAsked.removeAll() }
        lock.unlock()
        guard isNew else { return }
        nonisolated(unsafe) let style = style
        DispatchQueue.global(qos: .utility).async {
            let written = MarkdownImageSources.written(in: source)
            guard !written.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for url in written.compactMap(style.fetchedImageURL) { MarkdownImageLoader.shared.prefetch(url) }
                }
            }
        }
    }

    private static func draw(_ formulas: Formulas) {
        let block = formulas.block
        if let latex = MarkdownBlockView.displayFormula(of: block) {
            _ = MarkdownMath.piece(latex: latex, kind: .displayEquation, xHeight: formulas.displayXHeight, foreground: formulas.foreground)
        }
        let source = block.descriptor.sourceText
        for (id, latex) in block.inlineMathStorage ?? [:]
        where source.contains(MarkdownInlineMathPlaceholder.prefix + id + MarkdownInlineMathPlaceholder.suffix) {
            _ = MarkdownMath.piece(latex: latex, kind: .inlineEquation, xHeight: formulas.inlineXHeight, foreground: formulas.foreground)
        }
    }

    /// Whether this block is on its way off the main thread: measuring it there would be for nothing.
    @MainActor
    public func isPending(_ block: MarkdownStreamBlock, style: MarkdownStyle, width: CGFloat) -> Bool {
        guard let job = Self.job(for: block, style: style) else { return false }
        let key = Key(source: job.source, kind: job.kind, depth: job.depth, category: style.contentSizeCategory)
        lock.lock()
        defer { lock.unlock() }
        return made[key]?.width != width && (working == key || pending.contains { $0.key == key && $0.width == width })
    }

    /// What's made for this text, whatever its width.
    @MainActor
    func ready(_ source: String, kind: Kind = .text, depth: Int, category: UIContentSizeCategory?) -> Made? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(source: source, kind: kind, depth: depth, category: category)
        guard var entry = made[key] else { return nil }
        clock += 1
        entry.used = clock
        made[key] = entry
        return entry
    }

    /// The table made for this source, in a content of the view's own to change from now on.
    @MainActor
    func takeTable(_ source: String, category: UIContentSizeCategory?) -> MarkdownPreparedTable? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(source: source, kind: .table, depth: 0, category: category)
        guard let table = made[key]?.table else { return nil }
        return MarkdownPreparedTable(content: table.content.copy(), geometry: table.geometry, width: table.width)
    }

    /// The height a block comes to in a row `width` wide; nil unless it's made for that.
    @MainActor
    public func height(of block: MarkdownStreamBlock, style: MarkdownStyle, width: CGFloat) -> CGFloat? {
        guard let job = Self.job(for: block, style: style),
              let entry = ready(job.source, kind: job.kind, depth: job.depth, category: style.contentSizeCategory),
              entry.width == width else { return nil }
        return entry.height
    }

    /// A nested item re-parsed alone has depth 0: its 20 pt a level.
    nonisolated static func leading(depth: Int) -> CGFloat {
        CGFloat(depth) * 20
    }

    /// What can be made ahead for a block, if anything (`MarkdownBlockView.apply`).
    nonisolated private static func job(for block: MarkdownStreamBlock, style: MarkdownStyle) -> (source: String, kind: Kind, depth: Int)? {
        let descriptor = block.descriptor
        let depth = descriptor.listItemContext?.depth ?? 0
        switch descriptor.kind {
        case .paragraph, .heading, .orderedList, .unorderedList:
            return (descriptor.sourceText, .text, depth)
        case .blockQuote:
            return (descriptor.sourceText, .quote, 0)
        case .table:
            return (descriptor.sourceText, .table, 0)
        case .codeBlock(let language):
            guard style.codeBlock.custom == nil, style.codeBlock.usesBox(for: language) else { return nil }
            return (descriptor.plainText, .code(language), 0)
        default:
            return MarkdownBlockView.displayFormula(of: block).map { ($0, .formula, 0) }
        }
    }

    private func work() {
        while true {
            lock.lock()
            if !pendingFormulas.isEmpty {
                let formulas = pendingFormulas.removeFirst()
                lock.unlock()
                autoreleasepool { Self.draw(formulas) }
                continue
            }
            guard !pending.isEmpty else {
                isWorking = false
                lock.unlock()
                return
            }
            let request = pending.removeFirst()
            working = request.key
            lock.unlock()
            let made = autoreleasepool {
                var made = Result()
                // What's resolved as it's built, a formula's colour, is resolved for these traits.
                request.traits.performAsCurrent { made = Self.make(request) }
                return made
            }
            lock.lock()
            clock += 1
            working = nil
            forget(request.key)
            self.made[request.key] = Made(text: made.text, stack: made.stack, picture: made.picture, table: made.table, colors: made.colors, width: request.width, height: made.height, used: clock)
            bytesInPictures += made.picture?.byteCount ?? 0
            while self.made.count > Self.capacity || bytesInPictures > Self.pictureBytes,
                  let oldest = self.made.min(by: { $0.value.used < $1.value.used }) {
                forget(oldest.key)
            }
            lock.unlock()
        }
    }

    private func forget(_ key: Key) {
        bytesInPictures -= made[key]?.picture?.byteCount ?? 0
        made[key] = nil
    }

    private struct Result {
        var text: MarkdownText?
        var stack: MarkdownTextStack?
        var picture: MarkdownTextPicture?
        var table: MarkdownPreparedTable?
        var colors: [(range: NSRange, color: UIColor)] = []
        var height: CGFloat?
    }

    private static func make(_ request: Request) -> Result {
        switch request.key.kind {
        case .text: makeText(request)
        case .quote: makeQuote(request)
        case .code(let language): makeCode(request, language: language)
        case .formula: makeFormula(request)
        case .table: makeTable(request)
        }
    }

    private static func drawn(_ text: MarkdownText, style: MarkdownStyle, width: CGFloat, request: Request, shift: CGFloat = 0) -> (stack: MarkdownTextStack, height: CGFloat)? {
        guard style.drawsTextUntilTouched, style.layoutDirection != .rightToLeft,
              style.typography.paragraphAlignment == .left || style.typography.paragraphAlignment == .natural,
              MarkdownTextHost.isDrawable(text.attributed, allowingInlineViews: true) else {
            return nil
        }
        let stack = MarkdownTextStack()
        stack.shift = shift
        stack.narrowsToText = MarkdownTextHost.hasHangingIndent(text.attributed)
        stack.show(text.attributed, foregroundColor: style.resolvedTextColor)
        return (stack, stack.size(forWidth: width).height)
    }

    private static func picture(of stack: MarkdownTextStack, request: Request) -> MarkdownTextPicture? {
        stack.picture(scale: request.traits.displayScale, traits: request.traits)
    }

    private static func makeText(_ request: Request) -> Result {
        let style = request.style
        let depth = request.key.depth
        // Those draw otherwise (`MarkdownBlockView.apply`).
        guard !MarkdownBlockView.drawsApart(request.block.descriptor),
              let text = MarkdownTextBuilder.buildOffMain(markdown: request.key.source, style: style, listDepthOffset: depth, inlineMath: request.block.inlineMathStorage, displayMath: request.block.displayMathStorage) else {
            return Result()
        }
        guard let drawn = drawn(text, style: style, width: request.width - leading(depth: depth), request: request) else {
            return Result(text: text)
        }
        let edges = style.addsEdgeInsets ? text.topEdgeInset + text.bottomEdgeInset : 0
        return Result(text: text, stack: drawn.stack, picture: picture(of: drawn.stack, request: request), height: drawn.height + edges)
    }

    private static func makeQuote(_ request: Request) -> Result {
        let style = request.style
        let inner = MarkdownQuoteView.strippingQuoteMarkers(request.key.source)
        let split = MarkdownCallout.split(innerMarkdown: inner)
        guard let text = MarkdownTextBuilder.buildOffMain(markdown: split?.body ?? inner, style: style.quoted, listDepthOffset: 0, inlineMath: request.block.inlineMathStorage, displayMath: request.block.displayMathStorage) else {
            return Result()
        }
        let padding = MarkdownQuoteView.padding
        guard let drawn = drawn(text, style: style, width: max(0, request.width - padding.horizontal * 2), request: request) else {
            return Result(text: text)
        }
        let insets = MarkdownQuoteView.insets(of: text, style: style)
        // A callout's header is a view's to measure.
        let height = split?.callout == nil ? drawn.height + insets.top + insets.bottom + padding.vertical * 2 : nil
        return Result(text: text, stack: drawn.stack, picture: picture(of: drawn.stack, request: request), height: height)
    }

    private static func makeCode(_ request: Request, language: String?) -> Result {
        let style = request.style
        let code = request.key.source
        let lines = MarkdownCodeLines(code: code)
        let metrics = MarkdownCodeBoxMetrics(bodySize: style.resolvedBodyTextSize)
        var result = Result(height: metrics.height(lines: lines.count))
        guard style.drawsTextUntilTouched, lines.count <= MarkdownCodeBoxView.drawnLineLimit else { return result }
        let text = MarkdownCodeBoxView.text(lines: lines, code: code, metrics: metrics)
        let stack = MarkdownTextStack()
        stack.shift = MarkdownCodeBoxView.codeOverhang(lines: lines, metrics: metrics)
        stack.show(text.attributed, foregroundColor: style.resolvedTextColor)
        _ = stack.size(forWidth: MarkdownCodeBoxView.longestLine(lines: lines, metrics: metrics))
        if let tokens = tokens(code: code, language: language, highlighter: style.codeBlock.highlighter) {
            result.colors = MarkdownCodeTokenColors.runs(tokens, upTo: text.attributed.length)
            MarkdownCodeRenderingColors.set(result.colors, on: stack.layoutManager)
        }
        result.text = text
        result.stack = stack
        result.picture = picture(of: stack, request: request)
        return result
    }

    /// Waits here for the tokens, on this queue: a highlighter's asynchronous only for its caller.
    private static func tokens(code: String, language: String?, highlighter: (any MarkdownCodeHighlighter)?) -> MarkdownCodeTokens? {
        guard let highlighter else { return nil }
        if let tokens = highlighter.cachedTokens(code: code, language: language) { return tokens }
        final class Box: @unchecked Sendable { var tokens: MarkdownCodeTokens? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.tokens = await highlighter.tokens(code: code, language: language)
            done.signal()
        }
        return done.wait(timeout: .now() + .seconds(1)) == .success ? box.tokens : nil
    }

    private static func makeTable(_ request: Request) -> Result {
        var style = request.style
        style.drawsTextUntilTouched = false
        let options = style.table
        // What a host puts in a table is on the main thread, and in views.
        guard options.replacement == nil, options.imageRenderer == nil, options.decoration == nil else { return Result() }
        let content = MarkdownTableContent()
        guard content.update(source: request.key.source, style: style, inlineMath: request.block.inlineMathStorage, displayMath: request.block.displayMathStorage),
              !content.gate.needsMainThread, !content.flat.contains(where: \.needsTextView) else {
            return Result()
        }
        let geometry = MarkdownTableMeasure.geometry(
            content: content,
            options: options,
            metrics: MarkdownTableMetrics(options: options),
            width: request.width,
            isRightToLeft: style.layoutDirection == .rightToLeft,
            host: { _ in nil },
            replaced: { _ in nil }
        )
        return Result(table: MarkdownPreparedTable(content: content, geometry: geometry, width: request.width), height: geometry.contentSize.height)
    }

    private static func makeFormula(_ request: Request) -> Result {
        let style = request.style
        let font = MarkdownMath.font(style.displayMathTextStyle, style: style)
        let piece = MarkdownMath.piece(latex: request.key.source, kind: .displayEquation, xHeight: font.xHeight, foreground: MarkdownMath.foreground(in: UITraitCollection.current))
        guard let metrics = piece.metrics, piece.image != nil else {
            return Result()
        }
        let content = MarkdownDisplayMathView.contentHeight(image: metrics.imageSize, font: font)
        return Result(height: max(MarkdownDisplayMathHeight.reserved(for: request.key.source), content))
    }
}

/// The images a block's markdown writes, by the URL as written.
enum MarkdownImageSources {
    static func written(in markdown: String) -> [URL] {
        var walker = Walker()
        walker.visit(Document(parsing: markdown))
        return walker.urls
    }

    private struct Walker: MarkupWalker {
        var urls: [URL] = []

        mutating func visitImage(_ image: Markdown.Image) {
            if let url = image.source.flatMap({ URL(string: $0) }) { urls.append(url) }
            descendInto(image)
        }
    }
}
