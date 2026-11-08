//
//  MarkdownImageAttachment.swift
//  MarkdownUIKit
//
//  An image in text, as DocKit draws one, in one storage character: a panel, then the picture at
//  its own size up to the width and 640 pt high, its corners rounded. A panel that failed has a
//  mark, and a tap tries again. What it can't load shows its description. A picture's size goes
//  through TextKit when it arrives. An image with text beside it has a small panel, in the line.
//

import Markdown
import MarkdownCore
import RichTextCore
import UIKit

/// Something in a block's text changed size by itself: tells the block, which tells its list.
@MainActor
final class MarkdownLateSize {
    var onChange: (() -> Void)?
    /// Pictures still on their way: until they've come, a height measured now changes.
    private(set) var waiting: Set<ObjectIdentifier> = []

    func wait(for object: AnyObject) { waiting.insert(ObjectIdentifier(object)) }
    func done(with object: AnyObject) { waiting.remove(ObjectIdentifier(object)) }
    /// What's shown went: what it waited for doesn't count.
    func reset() { waiting.removeAll() }
}

/// What a custom image renderer is given.
public struct MarkdownImageRequest {
    public let url: URL
    public let alternativeText: String?
}

/// What a directive's renderer is given.
public struct MarkdownDirectiveRequest {
    public let wrappedString: String
    public let arguments: [(name: String, value: String)]

    init(_ directive: BlockDirective) {
        wrappedString = directive.markdownWrappedString
        arguments = directive.argumentText.parseNameValueArguments().map { ($0.name, $0.value) }
    }
}

extension RichTextAttachment {
    /// Lays out what's around this again now its size changed. Not `contentSizeDidChange()`: a
    /// fitting size kept for this width has to go too, in the same turn as the block's report.
    @MainActor
    func markdownSizeDidChange(_ lateSize: MarkdownLateSize?) {
        if let textView = attachmentsHostingTextView {
            textView.invalidateFittingSizes()
            textView.invalidateTextLayout(for: self)
        }
        lateSize?.onChange?()
    }
}

/// An image's sizes, DocKit's.
enum MarkdownImageMetrics {
    static let cornerRadius: CGFloat = 8
    static let maxHeight: CGFloat = 640
    /// A panel alone in its line, its picture's shape not known yet: this high for its width.
    static let panelAspect: CGFloat = 3 / 4
    /// A panel with text beside it: as wide as this, a line high, so the text doesn't move far.
    static let inlinePanelWidth: CGFloat = 50
}

/// The picture and what stands for it, which is drawn by the view itself. A shown picture is one
/// image view, its corners its own: nothing's clipped offscreen.
@MainActor
final class MarkdownImageView: UIView {
    enum Content {
        case loading(URL)
        case loaded(MarkdownLoadedImage)
        case failed(URL)
        case text
    }

    var onSizeChange: (() -> Void)?

    private var content: Content
    private let isAlone: Bool
    private let fallback: NSAttributedString?
    private let lineHeight: CGFloat
    private let placeholderSize: CGFloat
    private var placeholder: MarkdownGlyphView?
    private lazy var imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = false
        view.layer.cornerRadius = MarkdownImageMetrics.cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        addSubview(view)
        return view
    }()
    private var textView: MarkdownMathSourceView?
    private var tapRecognizer: UITapGestureRecognizer?
    private var fit: (width: CGFloat, size: CGSize)?

    /// `isAlone`: nothing's beside it in its paragraph, so a panel can take the whole width.
    init(content: Content, isAlone: Bool, alternativeText: String?, fallbackText: String?, style: MarkdownStyle) {
        self.content = content
        self.isAlone = isAlone
        let body = style.typography.body.font(at: style.contentSizeCategory)
        fallback = fallbackText.map {
            NSAttributedString(string: $0, attributes: [.font: body, .foregroundColor: style.resolvedTextColor])
        }
        lineHeight = markdownPixelCeil(MarkdownMath.lastLine(body).height)
        placeholderSize = style.resolvedBodyTextSize
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = MarkdownImageMetrics.cornerRadius
        layer.cornerCurve = .continuous
        accessibilityLabel = alternativeText
        isAccessibilityElement = alternativeText != nil
        accessibilityTraits = .image
        registerForTraitChanges(MarkdownColorTraits.all) { (view: MarkdownImageView, _: UITraitCollection) in
            view.applyColors()
        }
        apply()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ content: Content) {
        let old = fit
        self.content = content
        fit = nil
        apply()
        setNeedsLayout()
        if let old, fittedSize(width: old.width) == old.size { return }
        onSizeChange?()
    }

    /// The size at `width`. Nothing's measured twice.
    func fittedSize(width: CGFloat) -> CGSize {
        if let fit, fit.width == width { return fit.size }
        let size: CGSize
        switch content {
        case .loading, .failed:
            size = isAlone
                ? CGSize(width: markdownPixelFloor(width), height: (width * MarkdownImageMetrics.panelAspect).rounded())
                : CGSize(width: MarkdownImageMetrics.inlinePanelWidth, height: lineHeight)
        case .text:
            size = measure(fallback, width: width)
        case .loaded(let loaded):
            guard loaded.size.width > 0 else {
                size = .zero
                break
            }
            // Down to a pixel: a hair over the line's room would send it to a line of its own.
            let shown = markdownPixelFloor(min(width, loaded.maxWidth))
            size = CGSize(width: shown, height: min(MarkdownImageMetrics.maxHeight, (shown * loaded.size.height / loaded.size.width).rounded()))
        }
        fit = (width, size)
        return size
    }

    private func measure(_ text: NSAttributedString?, width: CGFloat) -> CGSize {
        guard let text else { return .zero }
        let size = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
        return CGSize(width: markdownPixelCeil(size.width), height: markdownPixelCeil(size.height))
    }

    /// The views this state has; the rest go.
    private func apply() {
        var text: NSAttributedString?
        switch content {
        case .loading:
            imageView.isHidden = true
            removePlaceholder()
        case .loaded(let loaded):
            removePlaceholder()
            imageView.isHidden = false
            imageView.image = loaded.image
        case .failed:
            imageView.isHidden = true
            if placeholder == nil {
                let view = MarkdownGlyphView()
                view.color = .floo(.markdownImagePlaceholder)
                view.image = MarkdownSymbols.image("photo", pointSize: placeholderSize, scale: .large)
                addSubview(view)
                placeholder = view
            }
        case .text:
            imageView.isHidden = true
            removePlaceholder()
            text = fallback
        }
        if let text {
            let view = textView ?? MarkdownMathSourceView()
            if textView == nil {
                addSubview(view)
                textView = view
            }
            view.text = text
        } else {
            textView?.removeFromSuperview()
            textView = nil
        }
        applyColors()
    }

    private func removePlaceholder() {
        placeholder?.removeFromSuperview()
        placeholder = nil
    }

    /// A layer holds what's resolved: resolved again whenever a trait a colour reads changes.
    private func applyColors() {
        let isPanel: Bool
        switch content {
        case .loading, .failed: isPanel = true
        case .loaded, .text: isPanel = false
        }
        layer.backgroundColor = isPanel ? UIColor.floo(.markdownImageFill).resolvedColor(with: traitCollection).cgColor : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if case .loaded = content { setFrame(imageView, bounds) }
        if let textView { setFrame(textView, bounds) }
        if let placeholder, let image = placeholder.image {
            setFrame(placeholder, bounds)
            let laid = MarkdownSymbols.laidOutSize(image)
            placeholder.imageFrame = CGRect(
                x: markdownPixelRound((bounds.width - laid.width) / 2),
                y: markdownPixelRound((bounds.height - laid.height) / 2),
                width: image.size.width,
                height: image.size.height
            )
        }
    }

    private func setFrame(_ view: UIView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    /// A failed picture tries again on a tap. Nothing else takes a touch, so text around it, and
    /// a link it's in, work as they do.
    func enableRetry(_ action: @escaping () -> Void) {
        retry = action
        let recognizer = tapRecognizer ?? UITapGestureRecognizer(target: self, action: #selector(tapped))
        if tapRecognizer == nil {
            addGestureRecognizer(recognizer)
            tapRecognizer = recognizer
        }
        isUserInteractionEnabled = true
    }

    func disableRetry() {
        retry = nil
        isUserInteractionEnabled = false
    }

    private var retry: (() -> Void)?

    @objc private func tapped() { retry?() }

    // MARK: Fetching

    private weak var lateSize: MarkdownLateSize?

    /// Fetches what it shows if that's still on its way, and tries again on a tap if it failed.
    /// `lateSize` knows it's waiting until it's come.
    func fetch(lateSize: MarkdownLateSize?) {
        self.lateSize = lateSize
        switch content {
        case .loading(let url):
            lateSize?.wait(for: self)
            load(url, retrying: false)
        case .failed(let url):
            allowRetry(url)
        case .loaded, .text:
            break
        }
    }

    private func load(_ url: URL, retrying: Bool) {
        let done: @MainActor (MarkdownImageLoader.State) -> Void = { [weak self] state in
            self?.finish(url, state)
        }
        if retrying {
            MarkdownImageLoader.shared.retry(url, done: done)
        } else {
            MarkdownImageLoader.shared.load(url, done: done)
        }
    }

    private func finish(_ url: URL, _ state: MarkdownImageLoader.State) {
        lateSize?.done(with: self)
        switch state {
        case .loaded(let loaded):
            disableRetry()
            show(.loaded(loaded))
        case .failed:
            allowRetry(url)
            show(.failed(url))
        }
    }

    private func allowRetry(_ url: URL) {
        enableRetry { [weak self] in
            guard let self else { return }
            self.disableRetry()
            self.show(.loading(url))
            self.lateSize?.wait(for: self)
            self.load(url, retrying: true)
        }
    }

    /// What it shows first: the picture if it's come already.
    static func content(for url: URL?) -> Content {
        guard let url else { return .text }
        switch MarkdownImageLoader.shared.state(of: url) {
        case .loaded(let loaded): return .loaded(loaded)
        case .failed: return .failed(url)
        case nil: return .loading(url)
        }
    }
}

final class MarkdownImageAttachment: RichTextAttachment {
    private let imageView: MarkdownImageView
    private let source: String
    private let lateSize: MarkdownLateSize?
    /// Where this line starts inside the text: a list item's. TextKit proposes the whole width.
    var lineIndent: CGFloat = 0

    @MainActor
    init(id: AnyHashable, image: Markdown.Image, url: URL?, style: MarkdownStyle) {
        source = image.format()
        lateSize = style.lateSize
        imageView = MarkdownImageView(
            content: MarkdownImageView.content(for: url),
            // DocKit's rule for an image block: the only thing in its paragraph.
            isAlone: image.parent is Paragraph && image.parent?.childCount == 1,
            alternativeText: MarkdownImageSource.alternativeText(of: image),
            fallbackText: url == nil ? image.plainText : nil,
            style: style
        )
        super.init(id: id, sizing: .fittingLineFragment)
        imageView.onSizeChange = { [weak self] in
            guard let self else { return }
            self.markdownSizeDidChange(self.lateSize)
        }
        imageView.fetch(lateSize: lateSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    override var contentView: UIView { imageView }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? {
        imageView.fittedSize(width: max(0, proposal.width - lineIndent))
    }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}

/// A view a host gives for an image or a directive, at the size it says it fits.
final class MarkdownCustomViewAttachment: RichTextAttachment {
    private let view: UIView
    private let source: String
    private var fit: (width: CGFloat, size: CGSize)?

    @MainActor
    init(id: AnyHashable, view: UIView, source: String) {
        self.view = view
        self.source = source
        super.init(id: id, sizing: .fittingLineFragment)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    override var contentView: UIView { view }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? {
        if let fit, fit.width == proposal.width { return fit.size }
        let size = view.sizeThatFits(proposal)
        fit = (proposal.width, size)
        return size
    }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}

/// A thematic break: a hairline in 15 pt of room above and below.
@MainActor
final class MarkdownRuleView: UIView {
    static let height: CGFloat = 31
    private let line = MarkdownColorView(color: .floo(.markdownRule), cornerRadius: 0.5)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        line.layer.allowsEdgeAntialiasing = true
        addSubview(line)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: 0, y: 15, width: bounds.width, height: 1)
    }
}

/// A thematic break inside another block: as wide as the line.
final class MarkdownRuleAttachment: RichTextAttachment {
    private let rule = MainActor.assumeIsolated { MarkdownRuleView() }
    private let source: String

    @MainActor
    init(id: AnyHashable, source: String) {
        self.source = source
        super.init(id: id, sizing: .fittingLineFragment)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    override var contentView: UIView { rule }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? {
        CGSize(width: proposal.width, height: MarkdownRuleView.height)
    }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}
