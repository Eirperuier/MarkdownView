//
//  MarkdownCodeSheetController.swift
//  MarkdownUIKit
//
//  All of a block's code on a sheet, with Copy. An open sheet keeps up with a stream. Its text
//  scrolls in one text view; each row draws its own stripe, so only what's on screen does.
//

import FlooUIKit
import MarkdownCore
import RichTextCore
import UIKit

@MainActor
final class MarkdownCodeSheetController: UIViewController {
    private var code: String
    private let language: String?
    private let style: MarkdownStyle
    private let textView: InlineAttachmentTextView
    private let stripes = MarkdownCodeSheetStripes()
    private var highlightTask: Task<Void, Never>?
    private var copiedTask: Task<Void, Never>?
    private var outer: UIScrollView?

    private static let horizontalPadding: CGFloat = 5
    private static let verticalPadding: CGFloat = 3
    private static let rowHeight: CGFloat = 24

    init(code: String, language: String?, style: MarkdownStyle) {
        self.code = code
        self.language = language
        self.style = style
        textView = InlineAttachmentTextView(usingTextLayoutManager: true)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        highlightTask?.cancel()
        copiedTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .floo(.background)
        navigationItem.rightBarButtonItem = copyItem(copied: false)
        textView.configureForDisplay()
        textView.textContainerInset = UIEdgeInsets(top: Self.verticalPadding, left: Self.horizontalPadding, bottom: Self.verticalPadding, right: Self.horizontalPadding)
        textView.textLayoutManager?.delegate = stripes
        textView.accessibilityIdentifier = "markdown.code.sheet"
        if style.codeBlock.scrollsSideways {
            let outer = UIScrollView(frame: view.bounds)
            outer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            outer.addSubview(textView)
            view.addSubview(outer)
            self.outer = outer
        } else {
            textView.isScrollEnabled = true
            textView.alwaysBounceVertical = true
            textView.frame = view.bounds
            textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(textView)
        }
        show()
        registerForTraitChanges(MarkdownColorTraits.all) { (controller: MarkdownCodeSheetController, _: UITraitCollection) in
            controller.textView.setNeedsDisplay()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let outer else { return }
        let font = codeFont()
        let widest = MarkdownCodeLines(code: code).lines.reduce(CGFloat(0)) { max($0, ($1 as NSString).size(withAttributes: [.font: font]).width) }
        let lines = MarkdownCodeLines(code: code).count
        let size = CGSize(width: max(view.bounds.width, widest + Self.horizontalPadding * 2 + 1), height: CGFloat(lines) * Self.rowHeight + Self.verticalPadding * 2)
        textView.frame = CGRect(origin: .zero, size: size)
        outer.contentSize = size
    }

    func update(code: String) {
        guard code != self.code else { return }
        self.code = code
        guard isViewLoaded else { return }
        show()
        view.setNeedsLayout()
    }

    private func codeFont() -> UIFont {
        style.codeBlock.font.font(at: style.contentSizeCategory, monospaced: true)
    }

    private func show() {
        let scrolls = style.codeBlock.scrollsSideways
        let text = MarkdownCodeLines(code: code).lines.joined(separator: "\n")
        var attributes = MarkdownCodeBlockView.attributes(font: codeFont(), line: style.codeBlock.font.lineHeight(at: style.contentSizeCategory), scrolls: scrolls, rowHeight: Self.rowHeight, rowPadding: Self.verticalPadding * 2)
        attributes[.foregroundColor] = UIColor.floo(.markdownCodeText)
        stripes.update(text: text, rowInset: Self.verticalPadding, sideInset: Self.horizontalPadding)
        if textView.replaceTail(NSMutableAttributedString(string: text, attributes: attributes), nsPrefixLength: 0) == nil {
            textView.applyContent(NSMutableAttributedString(string: text, attributes: attributes))
        }
        highlight(text)
    }

    /// As the block's: off the main thread, cached, with no layout when it comes.
    private func highlight(_ text: String) {
        guard let highlighter = style.codeBlock.highlighter else { return }
        highlightTask?.cancel()
        let code = self.code, language = self.language
        if let tokens = highlighter.cachedTokens(code: code, language: language) {
            apply(tokens, length: (text as NSString).length)
            return
        }
        highlightTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let tokens = await highlighter.tokens(code: code, language: language), !Task.isCancelled else { return }
            await self?.apply(tokens, length: (text as NSString).length)
        }
    }

    private func apply(_ tokens: MarkdownCodeTokens, length: Int) {
        guard let manager = textView.textLayoutManager else { return }
        MarkdownCodeRenderingColors.set(MarkdownCodeTokenColors.runs(tokens, upTo: min(length, textView.textStorage.length)), on: manager)
        textView.setNeedsDisplay()
    }

    private func copyItem(copied: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: copied ? "Copied" : "Copy",
            image: UIImage(systemName: copied ? "checkmark" : "square.on.square"),
            target: self,
            action: #selector(copyCode)
        )
        return item
    }

    @objc private func copyCode() {
        UIPasteboard.general.string = code
        style.codeBlock.didCopy?(code)
        navigationItem.rightBarButtonItem = copyItem(copied: true)
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.navigationItem.rightBarButtonItem = self.copyItem(copied: false)
        }
    }
}

/// Puts colours over text as rendering attributes: no layout comes of it.
enum MarkdownCodeRenderingColors {
    @MainActor
    static func set(_ runs: [(range: NSRange, color: UIColor)], on manager: NSTextLayoutManager) {
        guard let content = manager.textContentManager else { return }
        let start = content.documentRange.location
        manager.setRenderingAttributes([:], for: content.documentRange)
        for run in runs {
            guard let from = content.location(start, offsetBy: run.range.location),
                  let to = content.location(from, offsetBy: run.range.length),
                  let range = NSTextRange(location: from, end: to) else { continue }
            manager.addRenderingAttribute(.foregroundColor, value: run.color, for: range)
        }
    }
}

/// Makes each row's fragment draw its row's stripe.
final class MarkdownCodeSheetStripes: NSObject, NSTextLayoutManagerDelegate {
    private let lock = NSLock()
    private var lineStarts: [Int] = [0]
    private var rowInset: CGFloat = 0
    private var sideInset: CGFloat = 0

    func update(text: String, rowInset: CGFloat, sideInset: CGFloat) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lock.lock()
        lineStarts = starts
        self.rowInset = rowInset
        self.sideInset = sideInset
        lock.unlock()
    }

    fileprivate func isStriped(offset: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low % 2 != 0
    }

    fileprivate var insets: (row: CGFloat, side: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        return (rowInset, sideInset)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = MarkdownCodeSheetFragment(textElement: textElement, range: textElement.elementRange)
        fragment.owner = self
        return fragment
    }
}

final class MarkdownCodeSheetFragment: NSTextLayoutFragment {
    nonisolated(unsafe) weak var owner: MarkdownCodeSheetStripes?

    /// As wide as anything a sheet's row is.
    private static let farBeyond: CGFloat = 100_000

    private var stripeRect: CGRect? {
        guard let owner, let manager = textLayoutManager, let content = manager.textContentManager else { return nil }
        let offset = content.offset(from: content.documentRange.location, to: rangeInElement.location)
        guard owner.isStriped(offset: offset) else { return nil }
        let insets = owner.insets
        let frame = layoutFragmentFrame
        return CGRect(x: -frame.minX - insets.side, y: -insets.row, width: Self.farBeyond, height: frame.height)
    }

    override var renderingSurfaceBounds: CGRect {
        guard let stripeRect else { return super.renderingSurfaceBounds }
        return super.renderingSurfaceBounds.union(stripeRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let stripeRect {
            context.saveGState()
            context.setFillColor(UIColor.floo(.markdownCodeStripe).resolvedColor(with: UITraitCollection.current).cgColor)
            context.fill(stripeRect.offsetBy(dx: point.x, dy: point.y))
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}
