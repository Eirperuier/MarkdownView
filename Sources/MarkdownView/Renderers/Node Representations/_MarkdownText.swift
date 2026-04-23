//
//  _MarkdownText.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/10/20.
//

import SwiftUI

extension AttributedString {
    func splitting(at characterOffset: Int) -> (AttributedString, AttributedString) {
        let count = characters.count
        let clamped = max(0, min(characterOffset, count))
        guard clamped > 0, clamped < count else {
            if clamped <= 0 { return (AttributedString(), self) }
            return (self, AttributedString())
        }
        let idx = characters.index(characters.startIndex, offsetBy: clamped)
        return (AttributedString(self[startIndex..<idx]),
                AttributedString(self[idx..<endIndex]))
    }

    /// Strip run-level colors so a view-level `.foregroundStyle(.clear)` can hide
    /// unrevealed text. Attribute-level foreground/background colors override
    /// view-level style, so they must be removed for the reveal animation.
    func clearingRunLevelColors() -> AttributedString {
        var copy = self
        for run in copy.runs {
            if run.foregroundColor != nil {
                copy[run.range].foregroundColor = nil
            }
            if run.backgroundColor != nil {
                copy[run.range].backgroundColor = nil
            }
        }
        return copy
    }

    /// Removes visual link styling while text is still hidden or only at the
    /// animation frontier, so links do not reveal their tint/underline early.
    func clearingRevealSensitiveAttributes() -> AttributedString {
        var copy = clearingRunLevelColors()
        for run in copy.runs {
            if run.underlineStyle != nil {
                copy[run.range].underlineStyle = nil
            }
            if run.link != nil {
                copy[run.range].link = nil
            }
        }
        return copy
    }

    func substring(from startOffset: Int, length: Int) -> AttributedString {
        let count = characters.count
        guard count > 0, length > 0 else { return AttributedString() }

        let clampedStart = max(0, min(startOffset, count))
        let clampedEnd = max(clampedStart, min(clampedStart + length, count))
        guard clampedStart < clampedEnd else { return AttributedString() }

        let startIndex = characters.index(characters.startIndex, offsetBy: clampedStart)
        let endIndex = characters.index(characters.startIndex, offsetBy: clampedEnd)
        return AttributedString(self[startIndex..<endIndex])
    }
}

private struct PreparedMarkdownText {
    let attributedString: AttributedString
    let characterCount: Int
}

private struct RevealAnimatedMarkdownText: View {
    private static let frontierCharacterCount = 1
    private static let frontierOpacity = 0.35

    let displayText: AttributedString
    let characterCount: Int
    let blockTextOffset: Int

    @Environment(\.markdownStreaming) private var revealManager
    @Environment(\.markdownFadeReveal) private var fadeConfig

    var body: some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *),
           let fadeConfig,
           revealManager != nil,
           characterCount > 0 {
            FadeRevealMarkdownText(
                displayText: displayText,
                characterCount: characterCount,
                blockTextOffset: blockTextOffset,
                config: fadeConfig
            )
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        Group {
            if let manager = revealManager, characterCount > 0 {
                let localRevealed = max(0, min(characterCount, manager.revealedCount - blockTextOffset))
                if localRevealed <= 0 {
                    Text(displayText.clearingRevealSensitiveAttributes()).foregroundColor(.clear)
                } else if localRevealed < characterCount {
                    let revealed = displayText.substring(from: 0, length: localRevealed)
                    let frontier = displayText.substring(
                        from: localRevealed,
                        length: Self.frontierCharacterCount
                    ).clearingRevealSensitiveAttributes()
                    let unrevealed = displayText.substring(
                        from: localRevealed + Self.frontierCharacterCount,
                        length: characterCount
                    ).clearingRevealSensitiveAttributes()

                    Text(revealed)
                        + Text(frontier).foregroundColor(.primary.opacity(Self.frontierOpacity))
                        + Text(unrevealed).foregroundColor(.clear)
                } else {
                    Text(displayText)
                }
            } else {
                Text(displayText)
            }
        }
        .contentTransition(.opacity)
    }
}

// MARK: - Fade Reveal (iOS 18+)

/// Per-character reveal timestamps backing the fade animation.
/// Stored as a growable array, indexed by character position within the block's
/// displayText. `nil` = not yet revealed; any Date = first time the renderer
/// saw that glyph.
///
/// SwiftUI calls `TextRenderer.draw` serially from the rendering pipeline, so
/// mutating this from `draw` is safe without a lock. Marked `@unchecked
/// Sendable` to satisfy Swift 6 strict concurrency when captured by the
/// value-type renderer.
private final class FadeState: @unchecked Sendable {
    var firstSeen: [Date?] = []
    var bornHue: [Double?] = []
    var initialized = false

    func ensureCapacity(_ n: Int) {
        if firstSeen.count < n {
            firstSeen.append(contentsOf: Array(repeating: nil, count: n - firstSeen.count))
        }
        if bornHue.count < n {
            bornHue.append(contentsOf: Array(repeating: nil, count: n - bornHue.count))
        }
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
private struct RevealFadeRenderer: TextRenderer {
    // Long hue wheel between orange (30°) and cyan (180°) — the "long way"
    // around, sweeping orange → red → magenta → purple → blue → cyan. Each new
    // character samples its born hue from an oscillating phase, and that hue
    // is frozen in FadeState — the glyph never shifts color after first draw.
    private static let orangeHue: Double = 30.0 / 360.0
    private static let cyanHue: Double = 180.0 / 360.0
    private static let huePeriod: TimeInterval = 4.0

    let revealedCount: Int
    let blockTextOffset: Int
    let characterCount: Int
    let now: Date
    let duration: TimeInterval
    let state: FadeState

    private static func hueAt(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate / huePeriod
        let wave = (sin(t * 2 * .pi) + 1) * 0.5
        let longSpan = 1.0 - (cyanHue - orangeHue)
        var h = orangeHue - wave * longSpan
        if h < 0 { h += 1 }
        return h
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        state.ensureCapacity(characterCount)

        // Use wall clock rather than the passed-in `now` (which comes from
        // ctx.date). When the TimelineView is paused and SwiftUI re-evaluates
        // the body for any other reason, ctx.date can stay frozen at the
        // pause moment while wall time has moved on — that's how partial
        // fades get stuck on screen. Date() always reflects reality, so any
        // later redraw computes `age` correctly and settles residual overlays.
        let now = Date()

        var charIdx = 0
        let revealedLocal = max(0, revealedCount - blockTextOffset)
        let durationInv = duration > 0 ? 1.0 / duration : .greatestFiniteMagnitude

        for line in layout {
            for run in line {
                for glyph in run {
                    defer { charIdx += 1 }
                    if charIdx >= revealedLocal { continue }

                    let t0: Date
                    if charIdx < state.firstSeen.count, let recorded = state.firstSeen[charIdx] {
                        t0 = recorded
                    } else {
                        // Treat pre-existing visible chars as long-settled on first
                        // draw, so re-opening a finished message doesn't flash.
                        let stamp = state.initialized ? now : .distantPast
                        if charIdx < state.firstSeen.count {
                            state.firstSeen[charIdx] = stamp
                        }
                        t0 = stamp
                    }

                    let age = now.timeIntervalSince(t0)
                    if age >= duration {
                        ctx.draw(glyph) // settled: fast path, no overlay
                        continue
                    }

                    // Freeze the tint hue at first sight, matching the char's
                    // birth moment in the oscillating wheel.
                    let hue: Double
                    if charIdx < state.bornHue.count, let recorded = state.bornHue[charIdx] {
                        hue = recorded
                    } else {
                        let sampled = state.initialized ? Self.hueAt(now) : Self.hueAt(t0)
                        if charIdx < state.bornHue.count {
                            state.bornHue[charIdx] = sampled
                        }
                        hue = sampled
                    }
                    let tint = Color(hue: hue, saturation: 0.9, brightness: 0.95)

                    let phase = max(0, min(1, age * durationInv))

                    // Compose base glyph + tint overlay inside one layer, then
                    // fade the whole composition in via the outer layer's
                    // opacity. Fading base and tint separately would make the
                    // early phase show tint-only (no base blend) and look
                    // fully colored — wrapping both in a single layer keeps
                    // the mixture proportionate throughout the fade-in.
                    let rect = glyph.typographicBounds.rect
                    ctx.drawLayer { outer in
                        outer.opacity = phase
                        outer.draw(glyph)
                        outer.drawLayer { inner in
                            // Force the tint regardless of the glyph's
                            // intrinsic color: clip to glyph alpha, then fill
                            // the rect with the tint color. clipToLayer works
                            // across LCD subpixel and grayscale AA, where
                            // colorMultiply/sourceIn don't.
                            inner.opacity = (1 - phase) * 0.5
                            inner.clipToLayer { mask in
                                mask.draw(glyph)
                            }
                            inner.fill(Path(rect), with: .color(tint))
                        }
                    }
                }
            }
        }

        state.initialized = true
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
private struct FadeRevealMarkdownText: View {
    let displayText: AttributedString
    let characterCount: Int
    let blockTextOffset: Int
    let config: MarkdownFadeRevealConfig

    @Environment(\.markdownStreaming) private var revealManager
    @State private var fadeState = FadeState()
    @State private var paused = true
    @State private var cleanupToken: Int = 0

    var body: some View {
        let revealed = revealManager?.revealedCount ?? .max

        TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: paused)) { ctx in
            Text(displayText)
                .textRenderer(
                    RevealFadeRenderer(
                        revealedCount: revealed,
                        blockTextOffset: blockTextOffset,
                        characterCount: characterCount,
                        now: ctx.date,
                        duration: config.duration,
                        state: fadeState
                    )
                )
                .id(cleanupToken)
        }
        .task(id: revealed) {
            // Any reveal advance wakes the timeline; it re-pauses after the
            // fade window drains so static messages cost nothing. Buffer is
            // generous because a char's firstSeen is only stamped on the
            // next TimelineView tick after `revealed` changes, and frame
            // jitter/layout-prepare delays can push the actual birth time
            // several frames later. If we pause too early, the final frame
            // snapshots an overlay whose age hasn't yet reached `duration`
            // and SwiftUI freezes that residual tint on screen. After
            // pausing we nudge a cleanup render so the final drawn frame
            // re-samples wall-clock `now` and clears any leftover overlay.
            paused = false
            try? await Task.sleep(for: .seconds(config.duration + 0.6))
            paused = true
            try? await Task.sleep(for: .milliseconds(80))
            cleanupToken &+= 1
        }
    }
}

/// Renders a list item's bullet/number marker in sync with the streaming reveal.
/// When a `StreamingRevealManager` is present and hasn't revealed any content
/// for the block yet, the marker is drawn in clear color so it keeps its layout
/// slot but stays invisible until the first character arrives.
struct StreamingRevealMarker<Content: View>: View {
    @Environment(\.markdownStreaming) private var revealManager
    private let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let visible = revealManager.map { $0.revealedCount > 0 } ?? true
        content
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: visible)
    }
}

/// A view that displays parsed HTML asynchronously.
///
/// Convert HTML into  `AttributedString` asynchronously to avoid `AttributeGraph` crash.
/// Supports streaming reveal animation via `StreamingRevealManager` from Environment.
struct _MarkdownText: View {
    
    var text: AttributedString
    var blockTextOffset: Int = 0
    @State private var preparedText: PreparedMarkdownText?
    
    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownStreaming) private var revealManager
    
    init(_ text: AttributedString, blockTextOffset: Int = 0) {
        self.text = text
        self.blockTextOffset = blockTextOffset
    }
    
    private var fallbackPreparedText: PreparedMarkdownText {
        PreparedMarkdownText(
            attributedString: text,
            characterCount: text.characters.count
        )
    }
    
    private static func prepareDisplayText(
        from text: AttributedString,
        configuration: MarkdownRendererConfiguration
    ) -> PreparedMarkdownText {
        var processed = text
        
        for run in text.runs.reversed() where (run.isHTML ?? false) {
            let range = run.range
            let originalHTML = String(text.characters[range])
            
            if let htmlAttrString = try? AttributedString(
                NSAttributedString(
                    data: Data(originalHTML.utf8),
                    options: [
                        .documentType: NSAttributedString.DocumentType.html
                    ],
                    documentAttributes: nil
                )
            ) {
                let parsedText = String(htmlAttrString.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if parsedText.isEmpty {
                    processed.replaceSubrange(range, with: AttributedString(originalHTML))
                } else {
                    processed.replaceSubrange(range, with: htmlAttrString)
                }
            } else {
                processed.replaceSubrange(range, with: AttributedString(originalHTML))
            }
        }
        
        for string in configuration.highlightedStrings {
            if let range = processed.range(of: string) {
                processed[range].font?.weight(.bold)
                processed[range].backgroundColor = configuration.highlightedBackgroundColor
                processed[range].foregroundColor = configuration.highlightedColor
            }
        }
        
        return PreparedMarkdownText(
            attributedString: processed,
            characterCount: processed.characters.count
        )
    }
    
    var body: some View {
        let prepared: PreparedMarkdownText = {
            if let p = preparedText, p.characterCount == text.characters.count {
                return p
            }
            return fallbackPreparedText
        }()

        RevealAnimatedMarkdownText(
            displayText: prepared.attributedString,
            characterCount: prepared.characterCount,
            blockTextOffset: blockTextOffset
        )
        .task(id: text) {
            let prepared = Self.prepareDisplayText(from: text, configuration: configuration)
            self.preparedText = prepared
        }
    }
}
