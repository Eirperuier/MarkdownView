//
//  MarkdownRendererConfiguration.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2024/12/11.
//

import Foundation
import SwiftUI

struct MarkdownRendererConfiguration: Equatable, AllowingModifyThroughKeyPath, Sendable {
    var preferredBaseURL: URL?
    var componentSpacing: CGFloat = 10
    
    var math: Math = Math()
    var table: Table = Table()
    var codeBlock: CodeBlock = CodeBlock()
    
    /// Links are in the app's accent colour (underlined), as bold text and block quotes are.
    var linkTintColor: Color = .accentColor
    var inlineCodeTintColor: Color = .gray
    var blockQuoteTintColor: Color = .accentColor
    var preferredColor: Color = .accentColor
    /// 基础正文字色:UITextView 路径(可选中渲染)不吃 SwiftUI `.foregroundStyle` 级联,
    /// 需显式传入(如 ThinkingView 宿主的 secondary)。原版 Text 路径不受影响。
    var baseTextColor: Color? = nil
    /// The colors everything is drawn in, from what it's drawn on (`markdownColors(_:)`); nil
    /// for the system's.
    var colors: MarkdownColors? = nil

    var showFullCode: Bool = false
    
    var listConfiguration: MarkdownListConfiguration = MarkdownListConfiguration()
    
    var allowedImageRenderers: Set<String> = ["https", "http"]
    var allowedBlockDirectiveRenderers: Set<String> = []

    var autolinkDetectionEnabled: Bool = true
    /// Whether a web link shows its site's icon before it (`markdownLinkSiteIcons(_:)`).
    var linkSiteIcons: Bool = false

    var highlightedStrings: [String] = []
    var highlightedColor: Color = .white
    var highlightedBackgroundColor: Color = .yellow

    /// 当前块的脚注上下文(app 经 `markdownFootnotes(_:)` 按块注入;nil = 不做脚注变换)。
    /// 仅可选中渲染路径(SelectableMarkupVisitor)消费,原版 Text 路径不读它。
    var footnotes: MarkdownFootnotes? = nil

    /// Whether `==highlight==` and `:circle[…]` in text are read as marks. Off for a tree
    /// (MarkdownTree): its text is text, its marks are nodes.
    var interpretsTextSyntax = true

    /// Lightweight fingerprint for node-level cache keys.
    /// Captures the fields most likely to affect block-level rendering.
    var stableFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(preferredBaseURL)
        hasher.combine(componentSpacing)
        hasher.combine(showFullCode)
        hasher.combine(math)
        hasher.combine(table.scrollable)
        hasher.combine(table.cellMaxWidth)
        hasher.combine(table.columnWidthBuckets)
        hasher.combine(codeBlock.scrollable)
        hasher.combine(listConfiguration)
        hasher.combine(allowedImageRenderers)
        hasher.combine(allowedBlockDirectiveRenderers)
        hasher.combine(autolinkDetectionEnabled)
        hasher.combine(linkSiteIcons)
        hasher.combine(highlightedStrings)
        // Colors hash as themselves: an asset color's `description` reflects on its bundle, and this
        // runs for every block on every render.
        hasher.combine(linkTintColor)
        hasher.combine(inlineCodeTintColor)
        hasher.combine(blockQuoteTintColor)
        hasher.combine(preferredColor)
        hasher.combine(baseTextColor)
        hasher.combine(colors)
        hasher.combine(highlightedColor)
        hasher.combine(highlightedBackgroundColor)
        // 脚注上下文(编号/URL)入指纹:流式期间定义陆续到达 → 编号表变化必须失效缓存重渲染。
        hasher.combine(footnotes)
        hasher.combine(interpretsTextSyntax)
        return hasher.finalize()
    }
}

// MARK: - Table Configuration

extension MarkdownRendererConfiguration {
    /// Configuration for markdown table rendering.
    struct Table: Equatable, Sendable {
        /// Whether the table should be horizontally scrollable.
        var scrollable: Bool = false
        
        /// The maximum width for each table cell when scrollable is enabled.
        var cellMaxWidth: CGFloat = 300

        /// Fixed width buckets used to stabilize scrollable table column widths.
        var columnWidthBuckets: [CGFloat] = [80, 120, 160, 220, 300]
    }

    /// Configuration for markdown code block rendering.
    struct CodeBlock: Equatable, Sendable {
        /// Whether code blocks should use a horizontal scroll view instead of wrapping.
        var scrollable: Bool = false
    }
}

// MARK: - SwiftUI Environment

struct MarkdownRendererConfigurationKey: EnvironmentKey {
    static let defaultValue: MarkdownRendererConfiguration = .init()
}

extension EnvironmentValues {
    var markdownRendererConfiguration: MarkdownRendererConfiguration {
        get { self[MarkdownRendererConfigurationKey.self] }
        set { self[MarkdownRendererConfigurationKey.self] = newValue }
    }
}

// MARK: - Streaming Environment (kept separate to avoid cache invalidation)

public struct MarkdownStreamingKey: EnvironmentKey {
    nonisolated(unsafe) public static let defaultValue: StreamingRevealManager? = nil
}

struct MarkdownStreamingRevealCountKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// The per-block streaming reveal manager, if this subtree is being
    /// revealed (set via ``markdownStreaming(_:)``). `nil` for loaded /
    /// non-streaming content. Read it to learn whether the surrounding
    /// markdown block is currently mid-stream — e.g. a custom code-block
    /// renderer that wants to mirror the host's reveal behavior.
    public var markdownStreaming: StreamingRevealManager? {
        get { self[MarkdownStreamingKey.self] }
        set { self[MarkdownStreamingKey.self] = newValue }
    }

    var markdownStreamingRevealCount: Int? {
        get { self[MarkdownStreamingRevealCountKey.self] }
        set { self[MarkdownStreamingRevealCountKey.self] = newValue }
    }
}

// MARK: - Block-relative text offset for nested reveal

/// Anchors a subtree's text into the parent block's plainText. Tables push
/// each cell's start offset here so `_MarkdownText` inside the cell can map
/// its local indices into the block's reveal frontier.
struct MarkdownTextOffsetBaseKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var markdownTextOffsetBase: Int {
        get { self[MarkdownTextOffsetBaseKey.self] }
        set { self[MarkdownTextOffsetBaseKey.self] = newValue }
    }
}

/// Tells `RevealFadeRenderer` to treat already-revealed glyphs on its very
/// first `draw` as freshly-revealed (stamp them as `now`, animate them in)
/// instead of as long-settled (`.distantPast`, snap-in static).
///
/// Set by table cells transitioning into `.active` phase, where the cell is
/// being mounted right as the frontier crosses its window — `revealedLocal`
/// can already be > 0 because the streaming coordinator advances multiple
/// chars per tick. Without this, the first 1–2 chars of every cell snap in.
///
/// Default `false` preserves the existing single-block behavior: a paragraph
/// re-mounting mid-stream (e.g. scrolled out and back) doesn't re-animate the
/// glyphs the user has already seen.
struct MarkdownStreamingFreshActivationKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var markdownStreamingFreshActivation: Bool {
        get { self[MarkdownStreamingFreshActivationKey.self] }
        set { self[MarkdownStreamingFreshActivationKey.self] = newValue }
    }
}

enum MarkdownTableRevealTextContext: Equatable, Sendable {
    case inherited
    case hidden
    case active(offsetBase: Int, freshActivation: Bool, minimumInterval: TimeInterval)
    case past
}

struct MarkdownTableRevealTextContextKey: EnvironmentKey {
    static let defaultValue: MarkdownTableRevealTextContext = .inherited
}

extension EnvironmentValues {
    var markdownTableRevealTextContext: MarkdownTableRevealTextContext {
        get { self[MarkdownTableRevealTextContextKey.self] }
        set { self[MarkdownTableRevealTextContextKey.self] = newValue }
    }
}

// MARK: - Fade Reveal Configuration

public struct MarkdownFadeRevealConfig: Equatable, Sendable {
    public static let legacyHighlightStartHue: Double = 30.0 / 360.0
    public static let legacyHighlightEndHue: Double = 270.0 / 360.0
    public static let legacyHighlightHue: Double = legacyHighlightStartHue
    public static let colorDurationMultiplier: Double = 1.8

    public var duration: TimeInterval
    public var delay: TimeInterval
    public var highlightColor: Color?
    public var highlightStartHue: Double?
    public var highlightEndHue: Double?
    public var hueSaturation: Double
    public var hueBrightness: Double

    public init(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        highlightColor: Color = .accentColor
    ) {
        self.duration = duration
        self.delay = Self.nonnegativeTime(delay)
        self.highlightColor = highlightColor
        self.highlightStartHue = nil
        self.highlightEndHue = nil
        self.hueSaturation = 0.9
        self.hueBrightness = 0.95
    }

    /// Creates a static reveal highlight color from a SwiftUI-style hue in the `0...1` range.
    public init(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        hue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) {
        self.duration = duration
        self.delay = Self.nonnegativeTime(delay)
        self.highlightColor = Color(
            hue: Self.normalizedHue(hue),
            saturation: saturation,
            brightness: brightness
        )
        self.highlightStartHue = nil
        self.highlightEndHue = nil
        self.hueSaturation = saturation
        self.hueBrightness = brightness
    }

    /// Creates a reveal highlight trail between two SwiftUI-style hues in the `0...1` range.
    public init(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        startHue: Double,
        endHue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) {
        self.duration = duration
        self.delay = Self.nonnegativeTime(delay)
        self.highlightColor = nil
        self.highlightStartHue = Self.normalizedHue(startHue)
        self.highlightEndHue = Self.normalizedHue(endHue)
        self.hueSaturation = saturation
        self.hueBrightness = brightness
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        guard hue.isFinite else { return 0 }
        let normalized = hue.truncatingRemainder(dividingBy: 1)
        return normalized >= 0 ? normalized : normalized + 1
    }

    private static func nonnegativeTime(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }

    func colorSettleDuration(adaptiveDuration: TimeInterval? = nil) -> TimeInterval {
        let effectiveDuration = Self.nonnegativeTime(adaptiveDuration ?? duration)
        return delay + effectiveDuration * Self.colorDurationMultiplier
    }
}

struct MarkdownFadeRevealKey: EnvironmentKey {
    static let defaultValue: MarkdownFadeRevealConfig? = nil
}

extension EnvironmentValues {
    var markdownFadeReveal: MarkdownFadeRevealConfig? {
        get { self[MarkdownFadeRevealKey.self] }
        set { self[MarkdownFadeRevealKey.self] = newValue }
    }
}

extension View {
    /// 基础正文字色注入(可选中/UITextView 路径专用):
    /// UITextView 不吃 SwiftUI `.foregroundStyle` 级联,必须显式传入;
    /// 原版 Text 路径不受影响(继续走 foregroundStyle)。
    nonisolated public func markdownBaseTextColor(_ color: Color?) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.baseTextColor = color
        }
    }

    /// Enable per-character fade-in animation during streaming reveal.
    /// Requires iOS 18+; on older OS this is a no-op.
    nonisolated public func markdownFadeReveal(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        highlightColor: Color = .accentColor
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(duration: duration, delay: delay, highlightColor: highlightColor)
        )
    }

    /// Enable per-character fade-in animation with a caller-provided hue.
    /// The hue follows SwiftUI's `Color(hue:saturation:brightness:)` convention: `0...1`.
    nonisolated public func markdownFadeReveal(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        hue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(
                duration: duration,
                delay: delay,
                hue: hue,
                saturation: saturation,
                brightness: brightness
            )
        )
    }

    /// Enable per-character fade-in animation with a caller-provided hue range.
    /// The hues follow SwiftUI's `Color(hue:saturation:brightness:)` convention: `0...1`.
    nonisolated public func markdownFadeReveal(
        duration: TimeInterval = 0.4,
        delay: TimeInterval = 0,
        startHue: Double,
        endHue: Double,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) -> some View {
        environment(
            \.markdownFadeReveal,
            MarkdownFadeRevealConfig(
                duration: duration,
                delay: delay,
                startHue: startHue,
                endHue: endHue,
                saturation: saturation,
                brightness: brightness
            )
        )
    }
}

extension MarkdownRendererConfiguration {
    /// A color MarkdownView names, in the colors it's drawn in (`MarkdownColors.recolored`).
    func painted(_ color: Color) -> Color {
        colors?.recolored(color) ?? color
    }

    /// What words without a color of their own are drawn in: the base color set, or the
    /// colors' primary; nil for the text view's own.
    var textColor: Color? {
        baseTextColor.map(painted) ?? colors?.primary
    }
}
