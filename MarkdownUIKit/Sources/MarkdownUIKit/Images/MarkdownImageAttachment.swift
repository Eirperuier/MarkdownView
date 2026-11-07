//
//  MarkdownImageAttachment.swift
//  MarkdownUIKit
//
//  An image in text, as MarkdownImage and NetworkImage draw one, in one storage character: a
//  spinner, then the picture with its caption under it, or a placeholder a tap tries again. What
//  it can't load shows its description. A picture's size goes through TextKit when it arrives:
//  a hosted view stayed at its spinner's 50 pt, its picture cut and its caption over what's next.
//

import Markdown
import MarkdownCore
import RichTextCore
import UIKit

/// Something in a block's text changed size by itself: tells the block, which tells its list.
@MainActor
final class MarkdownLateSize {
    var onChange: (() -> Void)?
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

/// The picture and what stands for it. Its views come as needed: a shown picture is one image
/// view and, with a caption, one more.
@MainActor
final class MarkdownImageView: UIView {
    enum Content {
        case loading(URL)
        case loaded(MarkdownLoadedImage)
        case failed(URL)
        case text
    }

    /// A spinner's width, kept by a placeholder so a failure doesn't move what's beside it.
    private static let waitingWidth: CGFloat = 50
    /// A VStack's room between a picture and its caption.
    private static let captionSpacing: CGFloat = 8
    private static let padding: CGFloat = 5

    var onSizeChange: (() -> Void)?

    private var content: Content
    private let caption: NSAttributedString?
    private let fallback: NSAttributedString?
    private let waitingHeight: CGFloat
    private let placeholderSize: CGFloat
    private var placeholder: MarkdownGlyphView?
    private lazy var imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleToFill
        view.isUserInteractionEnabled = false
        addSubview(view)
        return view
    }()
    private var textView: MarkdownMathSourceView?
    private var spinner: UIActivityIndicatorView?
    private var tapRecognizer: UITapGestureRecognizer?
    private var imageFrame = CGRect.zero
    private var textFrame = CGRect.zero
    private var fit: (width: CGFloat, size: CGSize)?

    init(content: Content, alternativeText: String?, fallbackText: String?, style: MarkdownStyle) {
        self.content = content
        let category = style.contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) }
        caption = alternativeText.map {
            NSAttributedString(string: $0, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .callout, compatibleWith: category),
                .foregroundColor: UIColor.floo(.markdownImageCaption),
            ])
        }
        let body = style.typography.body.font(at: style.contentSizeCategory)
        fallback = fallbackText.map {
            NSAttributedString(string: $0, attributes: [.font: body, .foregroundColor: style.resolvedTextColor])
        }
        waitingHeight = markdownPixelCeil(MarkdownMath.lastLine(body).height)
        placeholderSize = style.resolvedBodyTextSize
        super.init(frame: .zero)
        isUserInteractionEnabled = false
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

    /// The size at `width`, working out where things go in it. Nothing's measured twice.
    func fittedSize(width: CGFloat) -> CGSize {
        if let fit, fit.width == width { return fit.size }
        let size: CGSize
        switch content {
        case .loading, .failed:
            size = CGSize(width: Self.waitingWidth, height: waitingHeight)
            textFrame = .zero
            imageFrame = .zero
        case .text:
            let text = measure(fallback, width: width)
            size = text
            imageFrame = .zero
            textFrame = CGRect(origin: .zero, size: text)
        case .loaded(let loaded):
            let shownWidth = min(width, loaded.maxWidth)
            let picture = loaded.size.width > 0
                // Down to a pixel: a hair over the line's room would send it to a line of its own.
                ? CGSize(width: markdownPixelFloor(shownWidth), height: markdownPixelRound(shownWidth * loaded.size.height / loaded.size.width))
                : .zero
            let text = measure(caption, width: width)
            let total = max(picture.width, text.width)
            imageFrame = CGRect(x: markdownPixelRound((total - picture.width) / 2), y: 0, width: picture.width, height: picture.height)
            guard caption != nil else {
                textFrame = .zero
                size = picture
                break
            }
            textFrame = CGRect(x: markdownPixelRound((total - text.width) / 2), y: picture.height + Self.captionSpacing, width: text.width, height: text.height)
            size = CGSize(width: total, height: textFrame.maxY)
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
            if spinner == nil {
                let view = UIActivityIndicatorView(style: .medium)
                view.isUserInteractionEnabled = false
                addSubview(view)
                spinner = view
            }
            spinner?.startAnimating()
        case .loaded(let loaded):
            removeSpinner()
            removePlaceholder()
            imageView.isHidden = false
            imageView.image = loaded.image
            text = caption
        case .failed:
            removeSpinner()
            imageView.isHidden = true
            if placeholder == nil {
                let view = MarkdownGlyphView()
                view.color = .floo(.markdownImagePlaceholder)
                let box = CGRect(x: 0, y: 0, width: Self.waitingWidth, height: waitingHeight)
                // At its natural size, as a hosted image is: a view, centred on the pixel grid.
                if let image = MarkdownSymbols.image("photo", pointSize: placeholderSize, scale: .large) {
                    let laid = MarkdownSymbols.laidOutSize(image)
                    view.image = image
                    view.imageFrame = CGRect(
                        x: markdownPixelRound((box.width - laid.width) / 2),
                        y: markdownPixelRound((box.height - laid.height) / 2),
                        width: image.size.width,
                        height: image.size.height
                    )
                }
                addSubview(view)
                placeholder = view
            }
        case .text:
            removeSpinner()
            imageView.isHidden = true
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

    private func removeSpinner() {
        spinner?.stopAnimating()
        spinner?.removeFromSuperview()
        spinner = nil
    }

    /// A layer holds what's resolved: resolved again whenever a trait a colour reads changes.
    private func applyColors() {
        spinner?.color = UIColor.floo(.markdownImageSpinner).resolvedColor(with: traitCollection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = fittedSize(width: fit?.width ?? bounds.width)
        if let placeholder { setFrame(placeholder, bounds) }
        if imageView.image != nil { setFrame(imageView, imageFrame) }
        if let textView { setFrame(textView, textFrame) }
        if let spinner {
            let size = spinner.intrinsicContentSize
            setFrame(spinner, CGRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
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
}

final class MarkdownImageAttachment: RichTextAttachment {
    private let imageView: MarkdownImageView
    private let source: String
    private let url: URL?
    private let lateSize: MarkdownLateSize?
    /// Where this line starts inside the text: a list item's. TextKit proposes the whole width.
    var lineIndent: CGFloat = 0

    @MainActor
    init(id: AnyHashable, image: Markdown.Image, url: URL?, style: MarkdownStyle) {
        source = image.format()
        self.url = url
        lateSize = style.lateSize
        let content: MarkdownImageView.Content
        if let url {
            switch MarkdownImageLoader.shared.state(of: url) {
            case .loaded(let loaded): content = .loaded(loaded)
            case .failed: content = .failed(url)
            case nil: content = .loading(url)
            }
        } else {
            content = .text
        }
        imageView = MarkdownImageView(
            content: content,
            alternativeText: MarkdownImageSource.alternativeText(of: image),
            fallbackText: url == nil ? image.plainText : nil,
            style: style
        )
        super.init(id: id, sizing: .fittingLineFragment)
        imageView.onSizeChange = { [weak self] in
            guard let self else { return }
            self.markdownSizeDidChange(self.lateSize)
        }
        switch content {
        case .loading: load()
        case .failed: allowRetry()
        case .loaded, .text: break
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    private func load(retrying: Bool = false) {
        guard let url else { return }
        let done: @MainActor (MarkdownImageLoader.State) -> Void = { [weak self] state in
            self?.finish(state)
        }
        if retrying {
            MarkdownImageLoader.shared.retry(url, done: done)
        } else {
            MarkdownImageLoader.shared.load(url, done: done)
        }
    }

    @MainActor
    private func finish(_ state: MarkdownImageLoader.State) {
        switch state {
        case .loaded(let loaded):
            imageView.disableRetry()
            imageView.show(.loaded(loaded))
        case .failed:
            allowRetry()
            if let url { imageView.show(.failed(url)) }
        }
    }

    @MainActor
    private func allowRetry() {
        imageView.enableRetry { [weak self] in
            guard let self, let url = self.url else { return }
            self.imageView.disableRetry()
            self.imageView.show(.loading(url))
            self.load(retrying: true)
        }
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
