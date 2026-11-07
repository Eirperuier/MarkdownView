//
//  ChatUIKitRow.swift
//  DemoApp
//
//  A chat row with no SwiftUI in it, under `-chatRenderer uikit`: headings, paragraphs, lists,
//  quotes and footnotes through MarkdownUIKit. Everything else stays a SwiftUI row in the same
//  list. It lays out as ChatRowView does, so the page looks the same.
//

import FlooUIKit
import MarkdownUIKit
import MarkdownView
import MessagingUI
import UIKit

/// Which renderer draws the text rows: `-chatRenderer uikit|swiftui`, on one build.
enum ChatRenderer: String {
    case swiftui, uikit

    static let current = UserDefaults.standard.string(forKey: "chatRenderer").flatMap(ChatRenderer.init(rawValue:)) ?? .swiftui
}

/// One block's row.
@MainActor
struct ChatUIKitBlock: TiledUIKitCellContent {
    let id: String
    let block: MarkdownStreamBlock
    let isStreaming: Bool
    let conversation: ChatConversation
    let renderedHeights: ChatRenderedHeights

    /// As chat's SwiftUI rows set it, the highlight going through the same hues.
    static let revealStyle = MarkdownRevealStyle(
        motion: AppMotion.streamReveal,
        highlight: .hues(
            start: MarkdownFadeRevealConfig.legacyHighlightStartHue,
            end: MarkdownFadeRevealConfig.legacyHighlightEndHue,
            saturation: Self.defaultHues.saturation,
            brightness: Self.defaultHues.brightness
        )
    )

    /// The saturation and brightness a `markdownFadeReveal(startHue:endHue:)` gets.
    private static var defaultHues: (saturation: Double, brightness: Double) {
        let config = MarkdownFadeRevealConfig(
            startHue: MarkdownFadeRevealConfig.legacyHighlightStartHue,
            endHue: MarkdownFadeRevealConfig.legacyHighlightEndHue
        )
        return (config.hueSaturation, config.hueBrightness)
    }

    /// What the page's default colours come to: the app's accent, as a catalogue fixture has it.
    static let theme = FlooTheme.system.setting(.accent, to: UIColor(named: "AccentColor") ?? .systemBlue)

    /// Once, on the window: a trait override in each row has UIKit walk the row's views at every
    /// layout pass. The SwiftUI rows don't read it.
    static func applyTheme() {
        guard ChatRenderer.current == .uikit, TiledPerf.on("windowtheme") else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.traitOverrides.flooTheme = theme }
        }
    }

    nonisolated static func draws(_ block: MarkdownStreamBlock) -> Bool {
        ChatRenderer.current == .uikit && MarkdownUIKit.MarkdownBlockView.draws(block)
    }

    /// `-chatDrawsText YES`: rows draw their text until touched. Off by default: a first click and
    /// pointer on it haven't been tried with real events.
    private static let drawsText = UserDefaults.standard.bool(forKey: "chatDrawsText")

    /// The row's style. Links open as a SwiftUI row's do; under a probe they're only told.
    static var style: MarkdownStyle {
        var style = MarkdownStyle()
        style.drawsTextUntilTouched = drawsText
        if ChatProbe.file != nil {
            style.openURL = { ChatProbe.tellLink($0) }
        }
        return style
    }

    static func makeRowView() -> ChatUIKitRowView {
        ChatUIKitRowView()
    }

    private var reveal: MarkdownReveal? {
        guard isStreaming else { return nil }
        return MarkdownReveal(manager: conversation.coordinator.ensureManager(for: block.id), style: Self.revealStyle)
    }

    func configure(_ view: ChatUIKitRowView, context: TiledUIKitCellContext) {
        view.onHeightChange = { context.heightDidChange() }
        view.show(id: id, block: block, reveal: reveal, renderedHeights: renderedHeights)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        ChatUIKitBlockViews.height(id: id, block: block, reveal: reveal, width: width, traits: traits)
    }

    static func prepareForReuse(_ view: ChatUIKitRowView) {
        view.reset()
    }
}

/// A prompt's row, as ChatRowView draws one: a bubble at the trailing edge, as wide as its text.
@MainActor
struct ChatUIKitPrompt: TiledUIKitCellContent {
    let id: String
    let text: String
    let renderedHeights: ChatRenderedHeights

    static func makeRowView() -> ChatUIKitPromptView {
        ChatUIKitPromptView()
    }

    func configure(_ view: ChatUIKitPromptView, context: TiledUIKitCellContext) {
        view.show(id: id, text: text, renderedHeights: renderedHeights)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        ChatUIKitPromptLayout.height(of: text, width: width, traits: traits)
    }
}

extension FlooColorRole {
    /// A prompt's bubble: the accent, faint.
    static let chatPromptFill = FlooColorRole("chat.promptFill") { $0[.accent].withAlphaComponent(0.15) }
}

/// A prompt's sizes, as ChatRowView's padding.
@MainActor
enum ChatUIKitPromptLayout {
    static let top: CGFloat = 24
    static let bottom: CGFloat = 8
    static let bubbleInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    static let cornerRadius: CGFloat = 18

    private struct Key: Hashable {
        let text: String
        let width: CGFloat
        let category: UIContentSizeCategory
    }

    private static var textSizes: [Key: CGSize] = [:]
    private static let measuringLabel = {
        let label = UILabel()
        label.numberOfLines = 0
        return label
    }()

    /// The text's size in a row `width` wide.
    static func textSize(of text: String, width: CGFloat, traits: UITraitCollection) -> CGSize {
        let key = Key(text: text, width: width, category: traits.preferredContentSizeCategory)
        if let size = textSizes[key] { return size }
        let room = max(0, ChatUIKitRowLayout.textWidth(in: width) - bubbleInsets.left - bubbleInsets.right)
        measuringLabel.font = font(traits)
        measuringLabel.text = text
        let fit = measuringLabel.sizeThatFits(CGSize(width: room, height: .greatestFiniteMagnitude))
        let scale = max(1, traits.displayScale)
        let size = CGSize(width: (min(fit.width, room) * scale).rounded(.up) / scale, height: (fit.height * scale).rounded(.up) / scale)
        textSizes[key] = size
        return size
    }

    static func height(of text: String, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        top + bottom + bubbleInsets.top + bubbleInsets.bottom + textSize(of: text, width: width, traits: traits).height
    }

    static func font(_ traits: UITraitCollection) -> UIFont {
        .preferredFont(forTextStyle: .body, compatibleWith: traits)
    }
}

@MainActor
final class ChatUIKitPromptView: UIView {
    private let bubble = UIView()
    private let label = UILabel()
    private var rowID: String?
    private var text = ""
    private weak var renderedHeights: ChatRenderedHeights?

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.backgroundColor = .floo(.chatPromptFill)
        bubble.layer.cornerRadius = ChatUIKitPromptLayout.cornerRadius
        bubble.layer.cornerCurve = .continuous
        label.numberOfLines = 0
        label.textColor = .floo(.label)
        addSubview(bubble)
        bubble.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(id: String, text: String, renderedHeights: ChatRenderedHeights) {
        self.renderedHeights = renderedHeights
        rowID = id
        self.text = text
        label.text = text
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let font = ChatUIKitPromptLayout.font(traitCollection)
        if label.font != font { label.font = font }
        let insets = ChatUIKitPromptLayout.bubbleInsets
        let size = ChatUIKitPromptLayout.textSize(of: text, width: bounds.width, traits: traitCollection)
        let textWidth = ChatUIKitRowLayout.textWidth(in: bounds.width)
        let scale = max(1, traitCollection.displayScale)
        let textMaxX = ((bounds.width + textWidth) / 2 * scale).rounded() / scale
        let bubbleWidth = size.width + insets.left + insets.right
        bubble.frame = CGRect(x: textMaxX - bubbleWidth, y: ChatUIKitPromptLayout.top, width: bubbleWidth, height: size.height + insets.top + insets.bottom)
        label.frame = CGRect(x: insets.left, y: insets.top, width: size.width, height: size.height)
        if let rowID { renderedHeights?.sizes[rowID] = bounds.size }
    }
}

/// A row's room around its block, as ChatRowView's frame and padding.
enum ChatUIKitRowLayout {
    static let verticalPadding: CGFloat = 5
    static let horizontalPadding: CGFloat = 16
    static let maxTextWidth: CGFloat = 720

    static func textWidth(in width: CGFloat) -> CGFloat {
        max(0, min(maxTextWidth, width - horizontalPadding * 2))
    }
}

@MainActor
final class ChatUIKitRowView: UIView {
    private var blockView: MarkdownUIKit.MarkdownBlockView?
    private var rowID: String?
    private weak var renderedHeights: ChatRenderedHeights?
    var onHeightChange: (() -> Void)?

    func show(id: String, block: MarkdownStreamBlock, reveal: MarkdownReveal?, renderedHeights: ChatRenderedHeights) {
        self.renderedHeights = renderedHeights
        if rowID != id { reset() }
        rowID = id
        let view = ChatUIKitBlockViews.view(id: id, block: block, reveal: reveal, traits: traitCollection)
        view.onHeightChange = { [weak self] in
            self?.setNeedsLayout()
            self?.onHeightChange?()
        }
        if view.superview !== self {
            addSubview(view)
            blockView = view
        }
        setNeedsLayout()
    }

    func reset() {
        blockView?.onHeightChange = nil
        blockView?.setReveal(nil)
        blockView?.removeFromSuperview()
        blockView = nil
        rowID = nil
        onHeightChange = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textWidth = ChatUIKitRowLayout.textWidth(in: bounds.width)
        if let blockView {
            let scale = max(1, traitCollection.displayScale)
            let x = ((bounds.width - textWidth) / 2 * scale).rounded() / scale
            blockView.frame = CGRect(x: x, y: ChatUIKitRowLayout.verticalPadding, width: textWidth, height: blockView.height(forWidth: textWidth))
        }
        if let rowID { renderedHeights?.sizes[rowID] = bounds.size }
    }
}

/// Blocks' views by row, with their text in and laid out, off any window or in a row. A height is
/// asked of the view that will show it, so a row is built and laid out once. A row coming back
/// finds its view as it left it.
@MainActor
enum ChatUIKitBlockViews {
    private struct Entry {
        let view: MarkdownUIKit.MarkdownBlockView
        var source: String
        var used: UInt64
    }

    private struct HeightKey: Hashable {
        let id: String
        let source: String
        let width: CGFloat
        let category: UIContentSizeCategory
    }

    private static let capacity = 96
    private static var entries: [String: Entry] = [:]
    private static var heights: [HeightKey: CGFloat] = [:]
    private static var clock: UInt64 = 0

    /// A conversation's rows went: as the list's hosts go with their items, these go with them.
    static func dropViews(keepingHeights: Bool) {
        for entry in entries.values where entry.view.superview == nil { entry.view.prepareForReuse() }
        entries.removeAll()
        if !keepingHeights { heights.removeAll() }
    }

    /// The row's view, showing `block`.
    static func view(id: String, block: MarkdownStreamBlock, reveal: MarkdownReveal?, traits: UITraitCollection) -> MarkdownUIKit.MarkdownBlockView {
        clock += 1
        if var entry = entries[id] {
            entry.used = clock
            if entry.source == block.source {
                entry.view.setReveal(reveal)
            } else {
                // Grown: the view replaces what changed at its end.
                entry.view.configure(block, style: style(traits), reveal: reveal)
                entry.source = block.source
            }
            entries[id] = entry
            return entry.view
        }
        let view = MarkdownUIKit.MarkdownBlockView()
        view.configure(block, style: style(traits), reveal: reveal)
        entries[id] = Entry(view: view, source: block.source, used: clock)
        evict()
        return view
    }

    static func height(id: String, block: MarkdownStreamBlock, reveal: MarkdownReveal?, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let key = HeightKey(id: id, source: block.source, width: width, category: traits.preferredContentSizeCategory)
        if let height = heights[key] { return height }
        let inner = view(id: id, block: block, reveal: reveal, traits: traits).height(forWidth: ChatUIKitRowLayout.textWidth(in: width))
        let scale = max(1, traits.displayScale)
        let height = ((inner + ChatUIKitRowLayout.verticalPadding * 2) * scale).rounded(.up) / scale
        // An image's height comes late: the block keeps it, and knows when it's changed.
        if !block.source.contains("![") { heights[key] = height }
        return height
    }

    private static func style(_ traits: UITraitCollection) -> MarkdownStyle {
        var style = ChatUIKitBlock.style
        if traits.preferredContentSizeCategory != .unspecified {
            style.contentSizeCategory = traits.preferredContentSizeCategory
        }
        return style
    }

    /// The oldest that isn't in a row goes, and its text view back to the pool.
    private static func evict() {
        guard entries.count > capacity else { return }
        let oldest = entries.filter { $0.value.view.superview == nil }.min { $0.value.used < $1.value.used }
        guard let oldest else { return }
        oldest.value.view.prepareForReuse()
        entries[oldest.key] = nil
    }
}
