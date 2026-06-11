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

    func cjkItalicCharacterRanges() -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for run in runs {
            guard run.inlinePresentationIntent?.contains(.emphasized) == true,
                  characters[run.range].contains(where: \.containsCJKScalar)
            else { continue }

            var cursor = characters.distance(from: characters.startIndex, to: run.range.lowerBound)
            var rangeStart: Int?

            for character in characters[run.range] {
                if character.containsCJKScalar {
                    rangeStart = rangeStart ?? cursor
                } else if let start = rangeStart {
                    ranges.append(start..<cursor)
                    rangeStart = nil
                }
                cursor += 1
            }

            if let start = rangeStart {
                ranges.append(start..<cursor)
            }
        }

        return ranges
    }
}

private extension Character {
    var containsCJKScalar: Bool {
        unicodeScalars.contains { $0.isCJKScalar }
    }
}

private extension Unicode.Scalar {
    var isCJKScalar: Bool {
        switch value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x2EFF,   // CJK Radicals Supplement
             0x2F00...0x2FDF,   // Kangxi Radicals
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x3100...0x312F,   // Bopomofo
             0x31A0...0x31BF,   // Bopomofo Extended
             0x31F0...0x31FF,   // Katakana Phonetic Extensions
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xA960...0xA97F,   // Hangul Jamo Extended-A
             0xAC00...0xD7AF,   // Hangul Syllables
             0xD7B0...0xD7FF,   // Hangul Jamo Extended-B
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2A6DF, // CJK Unified Ideographs extensions
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x30000...0x323AF:
            true
        default:
            false
        }
    }
}

private struct PreparedMarkdownText {
    let attributedString: AttributedString
    let characterCount: Int
    let cjkItalicRanges: [Range<Int>]
}

private struct RevealAnimatedMarkdownText: View {
    private static let frontierCharacterCount = 1
    private static let frontierOpacity = 0.35

    let displayText: AttributedString
    let characterCount: Int
    let blockTextOffset: Int
    let cjkItalicRanges: [Range<Int>]
    let revealManager: StreamingRevealManager?
    let revealCount: Int?
    let freshActivation: Bool
    let minimumInterval: TimeInterval
    var onRevealSettled: (() -> Void)? = nil

    @Environment(\.markdownFadeReveal) private var fadeConfig

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.revealAnimatedTextBodyCalls)
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *),
           let fadeConfig,
           revealCount != nil,
           characterCount > 0 {
            FadeRevealMarkdownText(
                displayText: displayText,
                characterCount: characterCount,
                blockTextOffset: blockTextOffset,
                config: fadeConfig,
                cjkItalicRanges: cjkItalicRanges,
                revealManager: revealManager,
                revealCount: revealCount,
                freshActivation: freshActivation,
                minimumInterval: minimumInterval,
                onRevealSettled: onRevealSettled
            )
        } else if #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *),
                  revealCount == nil,
                  !cjkItalicRanges.isEmpty {
            markdownTextWithInlineSymbols(displayText)
                .textRenderer(CJKItalicRenderer(ranges: cjkItalicRanges))
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        Group {
            if let revealCount, characterCount > 0 {
                let localRevealed = max(0, min(characterCount, revealCount - blockTextOffset))
                if localRevealed <= 0 {
                    markdownTextWithInlineSymbols(displayText.clearingRevealSensitiveAttributes()).foregroundColor(.clear)
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

                    markdownTextWithInlineSymbols(revealed)
                        + markdownTextWithInlineSymbols(frontier).foregroundColor(.primary.opacity(Self.frontierOpacity))
                        + markdownTextWithInlineSymbols(unrevealed).foregroundColor(.clear)
                } else {
                    markdownTextWithInlineSymbols(displayText)
                }
            } else {
                markdownTextWithInlineSymbols(displayText)
            }
        }
        .contentTransition(.opacity)
    }
}

// MARK: - Fade Reveal (iOS 18+)

struct MarkdownFadeRevealMinimumIntervalKey: EnvironmentKey {
    static let defaultValue: TimeInterval = 1.0 / 30.0
}

extension EnvironmentValues {
    var markdownFadeRevealMinimumInterval: TimeInterval {
        get { self[MarkdownFadeRevealMinimumIntervalKey.self] }
        set { self[MarkdownFadeRevealMinimumIntervalKey.self] = newValue }
    }
}

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
    var initialized = false
    var lastDrawnRevealedCount: Int?

    func ensureCapacity(_ n: Int) {
        if firstSeen.count < n {
            firstSeen.append(contentsOf: Array(repeating: nil, count: n - firstSeen.count))
        }
    }

    /// Returns true if any stamped character is still within its fade window.
    /// Used by `FadeRevealMarkdownText` to decide when it's safe to pause the
    /// TimelineView — pausing earlier can freeze a glyph mid-fade. Pass the
    /// color settle duration, including any tint delay, so the overlay also settles.
    func hasActiveFade(duration: TimeInterval) -> Bool {
        activeFadeRemaining(duration: duration) > 0
    }

    func activeFadeRemaining(duration: TimeInterval) -> TimeInterval {
        let now = Date()
        let cutoff = now.addingTimeInterval(-duration)
        var latest: Date?
        for stamp in firstSeen {
            guard let stamp, stamp > cutoff else { continue }
            if latest == nil || stamp > latest! {
                latest = stamp
            }
        }
        guard let latest else { return 0 }
        return max(0, duration - now.timeIntervalSince(latest))
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
private enum CJKItalicGlyphSkew {
    private static let shear: CGFloat = -0.18

    static func displayPadding(for ranges: [Range<Int>]) -> EdgeInsets {
        ranges.isEmpty ? EdgeInsets() : EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 4)
    }

    static func contains(
        _ characterIndex: Int,
        in ranges: [Range<Int>],
        cursor: inout Int
    ) -> Bool {
        while cursor < ranges.count, ranges[cursor].upperBound <= characterIndex {
            cursor += 1
        }
        return cursor < ranges.count && ranges[cursor].contains(characterIndex)
    }

    static func characterOffset(
        for glyph: Text.Layout.RunSlice,
        baseIndex: inout Text.Layout.CharacterIndex?
    ) -> Int? {
        guard let firstIndex = glyph.characterIndices.first else { return nil }
        if baseIndex == nil {
            baseIndex = firstIndex
        }
        return baseIndex?.distance(to: firstIndex)
    }

    static func draw(
        _ glyph: Text.Layout.RunSlice,
        in context: inout GraphicsContext,
        skewed: Bool
    ) {
        guard skewed else {
            context.draw(glyph)
            return
        }

        var skewedContext = context
        applyTransform(to: &skewedContext, glyph: glyph)
        skewedContext.draw(glyph)
    }

    static func applyTransform(
        to context: inout GraphicsContext,
        glyph: Text.Layout.RunSlice
    ) {
        let rect = glyph.typographicBounds.rect
        context.translateBy(x: rect.midX, y: rect.midY)
        context.concatenate(CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: 0, ty: 0))
        context.translateBy(x: -rect.midX, y: -rect.midY)
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
private struct CJKItalicRenderer: TextRenderer {
    let ranges: [Range<Int>]

    var displayPadding: EdgeInsets {
        CJKItalicGlyphSkew.displayPadding(for: ranges)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var characterIndex = 0
        var baseIndex: Text.Layout.CharacterIndex?
        var rangeCursor = 0

        for line in layout {
            for run in line {
                for glyph in run {
                    let offset = CJKItalicGlyphSkew.characterOffset(
                        for: glyph,
                        baseIndex: &baseIndex
                    ) ?? characterIndex
                    let isSkewed = CJKItalicGlyphSkew.contains(
                        offset,
                        in: ranges,
                        cursor: &rangeCursor
                    )
                    CJKItalicGlyphSkew.draw(glyph, in: &context, skewed: isSkewed)
                    characterIndex += max(glyph.characterIndices.count, 1)
                }
            }
        }
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
private struct RevealFadeRenderer: TextRenderer {
    private static let hueCycleDuration: TimeInterval = 8.0

    // Color tint outlasts the opacity fade-in — the glyph reaches full
    // opacity quickly, but the colored blend lingers as it restores to the
    // natural ink color. Tuned so the color "trail" is perceptibly longer
    // than the fade-in itself.
    static let colorDurationMultiplier = MarkdownFadeRevealConfig.colorDurationMultiplier

    let revealedCount: Int
    let blockTextOffset: Int
    let characterCount: Int
    let timelineDate: Date
    let duration: TimeInterval
    let delay: TimeInterval
    let highlightColor: Color?
    let highlightStartHue: Double?
    let highlightEndHue: Double?
    let hueSaturation: Double
    let hueBrightness: Double
    let colorScheme: ColorScheme
    let state: FadeState
    let cjkItalicRanges: [Range<Int>]
    let revealManager: StreamingRevealManager?
    /// When the renderer first runs, glyphs that don't have a recorded
    /// `firstSeen` get a stamp. The default behavior (`false`) is for
    /// re-mounting a paragraph that's been streamed before — already-revealed
    /// glyphs should appear settled (`.distantPast`) so the user doesn't see
    /// them re-animate. Tables in `.active` phase override this to `true`
    /// because the cell mounts the moment the frontier crosses, so already-
    /// revealed glyphs are actually fresh and should fade in.
    let treatExistingAsFresh: Bool

    var colorDuration: TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return duration * Self.colorDurationMultiplier
    }
    var overlayOpacity: Double {
        colorScheme == .dark ? 0.35 : 0.5
    }
    var displayPadding: EdgeInsets {
        CJKItalicGlyphSkew.displayPadding(for: cjkItalicRanges)
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        guard hue.isFinite else { return 0 }
        let normalized = hue.truncatingRemainder(dividingBy: 1)
        return normalized >= 0 ? normalized : normalized + 1
    }

    private var tintColor: Color {
        if let highlightStartHue, let highlightEndHue {
            let start = Self.normalizedHue(highlightStartHue)
            let span = Self.normalizedHue(highlightEndHue - start)
            let cycleDuration = max(Self.hueCycleDuration, .leastNonzeroMagnitude)
            let progress = timelineDate
                .timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycleDuration)
                / cycleDuration
            let wave = (1 - cos(progress * 2 * .pi)) * 0.5
            return Color(
                hue: Self.normalizedHue(start + wave * span),
                saturation: hueSaturation,
                brightness: hueBrightness
            )
        }

        if let highlightStartHue {
            return Color(
                hue: Self.normalizedHue(highlightStartHue),
                saturation: hueSaturation,
                brightness: hueBrightness
            )
        }

        return highlightColor ?? .accentColor
    }

    private func runCanDrawAsSettled(
        start: Int,
        end: Int,
        now: Date,
        colorSettleDuration: TimeInterval
    ) -> Bool {
        guard start < end else { return true }
        guard cjkItalicRanges.isEmpty else { return false }
        let lastCharacterIndex = end - 1

        if lastCharacterIndex < state.firstSeen.count,
           let timestamp = state.firstSeen[lastCharacterIndex] {
            return now.timeIntervalSince(timestamp) >= colorSettleDuration
        }

        if let timestamp = revealManager?.firstSeenTimestamp(at: blockTextOffset + lastCharacterIndex) {
            return now.timeIntervalSince(timestamp) >= colorSettleDuration
        }

        // On a cold mount without a fresh-activation hint, already-revealed
        // text is intentionally treated as settled to avoid replaying old fade.
        return !state.initialized && !treatExistingAsFresh
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        MarkdownRenderProbe.increment(\.fadeRevealRendererDrawCalls)
        state.ensureCapacity(characterCount)
        // A reveal rewind (revealedCount decreased) invalidates the stamps of
        // every glyph that fell back behind the frontier. This happens when
        // the reveal catches up mid-stream (coordinator bounces to Int.max),
        // new text renders once against that stale Int.max and gets stamped,
        // then the coordinator rewinds. The user never saw those glyphs as
        // revealed, so keeping the stamps would pre-age them — by the time
        // the frontier re-reaches them the fade window has already elapsed
        // and they pop in fully settled.
        if let lastDrawn = state.lastDrawnRevealedCount, revealedCount < lastDrawn {
            let newLocal = min(max(0, revealedCount - blockTextOffset), state.firstSeen.count)
            let oldLocal = lastDrawn == Int.max
                ? state.firstSeen.count
                : min(max(newLocal, lastDrawn - blockTextOffset), state.firstSeen.count)
            for index in newLocal..<oldLocal {
                state.firstSeen[index] = nil
            }
        }
        state.lastDrawnRevealedCount = revealedCount

        // Use wall clock rather than the passed-in `now` (which comes from
        // ctx.date). When the TimelineView is paused and SwiftUI re-evaluates
        // the body for any other reason, ctx.date can stay frozen at the
        // pause moment while wall time has moved on — that's how partial
        // fades get stuck on screen. Date() always reflects reality, so any
        // later redraw computes `age` correctly and settles residual overlays.
        let now = Date()

        var charIdx = 0
        var cjkBaseIndex: Text.Layout.CharacterIndex?
        var cjkRangeCursor = 0
        let revealedLocal = max(0, revealedCount - blockTextOffset)
        let durationInv = duration.isFinite && duration > 0 ? 1.0 / duration : nil
        let colorDelay = delay.isFinite ? max(0, delay) : 0
        let colorDurationValue = colorDuration
        let colorSettleDurationValue = colorDelay + colorDurationValue
        let currentTintColor = tintColor
        var visitedGlyphs = 0

        for line in layout {
            for run in line {
                let runStart = charIdx
                let runGlyphCount = run.count
                let runEnd = runStart + runGlyphCount
                if runEnd <= revealedLocal,
                   runCanDrawAsSettled(
                    start: runStart,
                    end: runEnd,
                    now: now,
                    colorSettleDuration: colorSettleDurationValue
                   ) {
                    ctx.draw(run)
                    charIdx = runEnd
                    visitedGlyphs += runGlyphCount
                    continue
                }

                for glyph in run {
                    visitedGlyphs += 1
                    defer { charIdx += 1 }
                    if charIdx >= revealedLocal { continue }
                    let cjkCharacterOffset = CJKItalicGlyphSkew.characterOffset(
                        for: glyph,
                        baseIndex: &cjkBaseIndex
                    ) ?? charIdx
                    let isCJKItalic = CJKItalicGlyphSkew.contains(
                        cjkCharacterOffset,
                        in: cjkItalicRanges,
                        cursor: &cjkRangeCursor
                    )

                    let t0: Date
                    if charIdx < state.firstSeen.count, let recorded = state.firstSeen[charIdx] {
                        t0 = recorded
                    } else {
                        // First time we see this glyph. Three buckets:
                        //   - `state.initialized`: ongoing reveal in this view —
                        //     stamp `now` so the glyph fades in.
                        //   - `treatExistingAsFresh`: very first draw of the
                        //     view AND the caller knows this is a fresh
                        //     activation (e.g. a table cell whose frontier
                        //     just entered, possibly with `revealedLocal > 0`
                        //     because the coordinator advances >1 char/tick).
                        //     Stamp `now` so the leading chars also animate.
                        //   - Otherwise: very first draw of a paragraph that
                        //     might be re-mounted with chars already revealed
                        //     (scrolled out and back during streaming, or
                        //     re-opened finished message). Stamp `.distantPast`
                        //     so they appear settled and don't flash.
                        let absoluteIndex = blockTextOffset + charIdx
                        let managerStamp = revealManager?.firstSeenTimestamp(at: absoluteIndex)
                        let stamp = managerStamp
                            ?? ((state.initialized || treatExistingAsFresh) ? now : .distantPast)
                        // Don't cache manager stamps that are already past the
                        // settle window. They draw as settled either way, and a
                        // stale stamp can be transient: text that renders during
                        // the brief revealedCount == Int.max window inherits the
                        // old completion timestamp, but after the coordinator
                        // rewinds, the manager hands out a fresh stamp — caching
                        // would freeze the stale one and permanently skip the
                        // fade for that glyph.
                        let settledManagerStamp = managerStamp.map {
                            now.timeIntervalSince($0) >= colorSettleDurationValue
                        } ?? false
                        if charIdx < state.firstSeen.count, !settledManagerStamp {
                            state.firstSeen[charIdx] = stamp
                        }
                        t0 = stamp
                    }

                    let age = now.timeIntervalSince(t0)
                    if age >= colorSettleDurationValue {
                        CJKItalicGlyphSkew.draw(glyph, in: &ctx, skewed: isCJKItalic)
                        continue
                    }

                    let phase = durationInv.map { max(0, min(1, age * $0)) } ?? 1
                    let colorAge = max(0, age - colorDelay)
                    let colorPhase = colorDurationValue > 0
                        ? max(0, min(1, colorAge / colorDurationValue))
                        : (age >= colorDelay ? 1 : 0)

                    // Outer layer fades the glyph in via `phase` (short
                    // duration). Inner layer holds the tint for `delay`,
                    // then fades it out via `colorPhase`, so the color blend
                    // can linger before settling into the natural ink color.
                    let rect = glyph.typographicBounds.rect
                    ctx.drawLayer { outer in
                        if isCJKItalic {
                            CJKItalicGlyphSkew.applyTransform(to: &outer, glyph: glyph)
                        }
                        outer.opacity = phase
                        outer.draw(glyph)
                        outer.drawLayer { inner in
                            // Force the tint regardless of the glyph's
                            // intrinsic color: clip to glyph alpha, then fill
                            // the rect with the tint color. clipToLayer works
                            // across LCD subpixel and grayscale AA, where
                            // colorMultiply/sourceIn don't.
                            inner.opacity = (1 - colorPhase) * overlayOpacity
                            inner.clipToLayer { mask in
                                mask.draw(glyph)
                            }
                            inner.fill(Path(rect), with: .color(currentTintColor))
                        }
                    }
                }
            }
        }

        state.initialized = true
        MarkdownRenderProbe.increment(\.fadeRevealRendererGlyphVisits, by: visitedGlyphs)
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
private struct FadeRevealMarkdownText: View {
    let displayText: AttributedString
    let characterCount: Int
    let blockTextOffset: Int
    let config: MarkdownFadeRevealConfig
    let cjkItalicRanges: [Range<Int>]
    let revealManager: StreamingRevealManager?
    let revealCount: Int?
    let freshActivation: Bool
    let minimumInterval: TimeInterval
    var onRevealSettled: (() -> Void)? = nil

    @Environment(\.font) private var inheritedFont
    @Environment(\.colorScheme) private var colorScheme
    @State private var fadeState = FadeState()
    @State private var paused = true
    @State private var cleanupToken: Int = 0

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.fadeRevealTextBodyCalls)
        let revealed = revealCount ?? .max
        let fadeDuration = revealManager?.adaptiveFadeDuration(baseDuration: config.duration) ?? config.duration

        TimelineView(.animation(minimumInterval: minimumInterval, paused: paused)) { ctx in
            markdownTextWithInlineSymbols(displayText)
                .font(inheritedFont)
                .textRenderer(
                    RevealFadeRenderer(
                        revealedCount: revealed,
                        blockTextOffset: blockTextOffset,
                        characterCount: characterCount,
                        timelineDate: ctx.date,
                        duration: fadeDuration,
                        delay: config.delay,
                        highlightColor: config.highlightColor,
                        highlightStartHue: config.highlightStartHue,
                        highlightEndHue: config.highlightEndHue,
                        hueSaturation: config.hueSaturation,
                        hueBrightness: config.hueBrightness,
                        colorScheme: colorScheme,
                        state: fadeState,
                        cjkItalicRanges: cjkItalicRanges,
                        revealManager: revealManager,
                        treatExistingAsFresh: freshActivation
                    )
                )
                .id(cleanupToken)
        }
        // Unpause synchronously the moment `revealed` changes. The settle
        // logic below lives in a `.task`, whose body runs asynchronously —
        // so when a reveal advance arrives while `paused == true` (e.g. a
        // block that hadn't been reached yet settled at `revealCount == 0`
        // and paused, or an intermediate `Int.max` finished its settle), the
        // `paused = false` inside the task can land a runloop late. In that
        // gap the glyphs are already revealed but the TimelineView is still
        // paused, freezing the opacity fade — the characters appear (reveal
        // works) but never fade in. `onChange` flips `paused` in the same
        // SwiftUI transaction as the reveal, closing that window. Note that
        // `revealed == Int.max` does NOT mean the block is done: the
        // coordinator sets `Int.max` whenever `next >= entry.length`, and a
        // later plainText growth rewinds it — so we must react to every
        // change, not just intermediate values.
        .onChange(of: revealed, initial: true) { _, _ in
            paused = false
        }
        .task(id: revealed) {
            // Drive the TimelineView until every stamped glyph has aged past
            // the delayed color-trail duration, then pause to save power.
            //
            // IMPORTANT: `.task(id:)` cancels the old task when `revealed`
            // changes, but `try? await` swallows CancellationError and the
            // following lines keep executing. So we MUST re-check
            // `Task.isCancelled` after every await — otherwise `paused =
            // true` fires on every reveal tick, briefly pausing the
            // TimelineView mid-animation. Cleanup only runs when the task
            // completes naturally.
            let settleDuration = config.colorSettleDuration(adaptiveDuration: fadeDuration)
            paused = false
            await waitForDraw(revealed: revealed)
            if Task.isCancelled { return }
            while !Task.isCancelled {
                let remaining = fadeState.activeFadeRemaining(duration: settleDuration)
                guard remaining > 0 else { break }
                try? await Task.sleep(for: .seconds(min(remaining, 0.12)))
            }
            if Task.isCancelled { return }
            paused = true
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
            cleanupToken &+= 1
            if revealed == Int.max {
                onRevealSettled?()
            }
        }
    }

    private func waitForDraw(revealed: Int) async {
        var attempts = 0
        while !Task.isCancelled,
              fadeState.lastDrawnRevealedCount != revealed,
              attempts < 8 {
            attempts += 1
            try? await Task.sleep(for: .seconds(max(minimumInterval, 1.0 / 60.0)))
        }
    }
}

/// Renders a list item's bullet/number marker in sync with the streaming reveal.
/// When a `StreamingRevealManager` is present and hasn't revealed any content
/// for the block yet, the marker is drawn in clear color so it keeps its layout
/// slot but stays invisible until the first character arrives.
struct StreamingRevealMarker<Content: View>: View {
    @Environment(\.markdownTextOffsetBase) private var offsetBase
    private let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.streamingMarkerBodyCalls)
        StreamingRevealCountReader { _, revealCount in
            let visible = revealCount.map { $0 > offsetBase } ?? true
            content
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: visible)
        }
    }
}

/// Fades a non-text block in once its per-block `StreamingRevealManager` has
/// started advancing. Used for content that can't participate in the per-char
/// `_MarkdownText` fade (code blocks, images, LaTeX/math, HTML, dividers,
/// tables). When no streaming manager is in scope, the block shows
/// immediately.
///
/// Mirrors `StreamingRevealMarker`: gate on `revealedCount > 0` with an
/// `.animation(value:)` transition, so the fade runs when the coordinator
/// advances the frontier onto this block.
private struct StreamingRevealFadeInModifier: ViewModifier {
    @Environment(\.markdownTextOffsetBase) private var offsetBase
    @Environment(\.markdownFadeReveal) private var fadeConfig

    func body(content: Content) -> some View {
        StreamingRevealCountReader { revealManager, revealCount in
            let visible = revealCount.map { $0 > offsetBase } ?? true
            let baseDuration = fadeConfig?.duration ?? 0.3
            let duration = revealManager?.adaptiveFadeDuration(baseDuration: baseDuration) ?? baseDuration
            content
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: duration), value: visible)
        }
    }
}

extension View {
    func streamingRevealFadeIn() -> some View {
        modifier(StreamingRevealFadeInModifier())
    }
}

struct StreamingRevealCountReader<Content: View>: View {
    @Environment(\.markdownStreaming) private var revealManager
    @State private var revealCount: Int?
    @State private var subscribedManager: StreamingRevealManager?
    @State private var listenerID: UUID?
    private let content: (StreamingRevealManager?, Int?) -> Content

    init(@ViewBuilder content: @escaping (StreamingRevealManager?, Int?) -> Content) {
        self.content = content
    }

    private var managerID: ObjectIdentifier? {
        revealManager.map(ObjectIdentifier.init)
    }

    @ViewBuilder
    var body: some View {
        if let revealManager,
           revealManager.revealedCount != Int.max
            || (subscribedManager === revealManager && revealCount != nil) {
            content(revealManager, revealCount ?? revealManager.revealedCount)
                .onChange(of: managerID, initial: true) { _, _ in
                    subscribe(to: revealManager)
                }
                .onDisappear {
                    unsubscribe()
                }
        } else {
            content(revealManager, nil)
        }
    }

    @MainActor
    private func subscribe(to manager: StreamingRevealManager?) {
        if subscribedManager.map(ObjectIdentifier.init) == manager.map(ObjectIdentifier.init) {
            return
        }

        unsubscribe()

        guard let manager else {
            revealCount = nil
            return
        }

        revealCount = manager.revealedCount
        subscribedManager = manager
        listenerID = manager.addListener { value in
            revealCount = value
        }
    }

    @MainActor
    private func unsubscribe() {
        if let listenerID, let subscribedManager {
            subscribedManager.removeListener(listenerID)
        }
        listenerID = nil
        subscribedManager = nil
    }
}

private struct MarkdownTextInheritedRevealGate: View {
    let prepared: PreparedMarkdownText
    let blockTextOffset: Int

    @Environment(\.markdownStreaming) private var revealManager
    @State private var animatedManagerID: ObjectIdentifier?
    @State private var settledManagerID: ObjectIdentifier?

    private var managerID: ObjectIdentifier? {
        revealManager.map(ObjectIdentifier.init)
    }

    private var shouldUseRevealReader: Bool {
        guard let revealManager else { return false }
        let id = ObjectIdentifier(revealManager)
        return revealManager.revealedCount != Int.max
            || (animatedManagerID == id && settledManagerID != id)
    }

    var body: some View {
        if shouldUseRevealReader {
            MarkdownTextInheritedRevealReader(
                prepared: prepared,
                blockTextOffset: blockTextOffset,
                onRevealSettled: {
                    markRevealSettled()
                }
            )
            .onAppear {
                markAnimatedManagerIfNeeded()
            }
            .onChange(of: managerID) { _, _ in
                markAnimatedManagerIfNeeded()
            }
        } else {
            MarkdownTextStaticRevealBody(
                prepared: prepared,
                blockTextOffset: blockTextOffset
            )
        }
    }

    @MainActor
    private func markAnimatedManagerIfNeeded() {
        guard let revealManager, revealManager.revealedCount != Int.max else { return }
        let id = ObjectIdentifier(revealManager)
        animatedManagerID = id
        if settledManagerID == id {
            settledManagerID = nil
        }
    }

    @MainActor
    private func markRevealSettled() {
        guard let revealManager,
              revealManager.revealedCount == Int.max,
              animatedManagerID == ObjectIdentifier(revealManager)
        else { return }
        settledManagerID = ObjectIdentifier(revealManager)
    }
}

private struct MarkdownTextInheritedRevealReader: View {
    let prepared: PreparedMarkdownText
    let blockTextOffset: Int
    var onRevealSettled: (() -> Void)? = nil

    @Environment(\.markdownTextOffsetBase) private var offsetBase
    @Environment(\.markdownStreamingFreshActivation) private var freshActivation
    @Environment(\.markdownFadeRevealMinimumInterval) private var minimumInterval

    var body: some View {
        StreamingRevealCountReader { revealManager, revealCount in
            RevealAnimatedMarkdownText(
                displayText: prepared.attributedString,
                characterCount: prepared.characterCount,
                blockTextOffset: offsetBase + blockTextOffset,
                cjkItalicRanges: prepared.cjkItalicRanges,
                revealManager: revealManager,
                revealCount: revealCount,
                freshActivation: freshActivation,
                minimumInterval: minimumInterval,
                onRevealSettled: onRevealSettled
            )
        }
    }
}

private struct MarkdownTextTableActiveRevealReader: View {
    let prepared: PreparedMarkdownText
    let offsetBase: Int
    let blockTextOffset: Int
    let freshActivation: Bool
    let minimumInterval: TimeInterval

    @Environment(\.markdownStreaming) private var revealManager
    @Environment(\.markdownFadeReveal) private var fadeConfig

    var body: some View {
        // Fast path for iOS 18+ with fade enabled: skip
        // `StreamingRevealCountReader` (it adds a listener-driven `@State
        // revealCount` to every active cell — at N≈1000 cells that fan-out
        // dominated the cost). The TimelineView inside
        // `TableCellFadeRevealText` polls `revealManager.revealedCount`
        // directly on each tick, so we still see frontier movement without a
        // per-cell listener subscription or a per-tick body re-eval cascade.
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *),
           let fadeConfig,
           prepared.characterCount > 0,
           let revealManager
        {
            TableCellFadeRevealText(
                prepared: prepared,
                offsetBase: offsetBase,
                blockTextOffset: blockTextOffset,
                freshActivation: freshActivation,
                minimumInterval: minimumInterval,
                revealManager: revealManager,
                fadeConfig: fadeConfig
            )
        } else {
            // Fallback: legacy / non-fade path keeps the original
            // listener-driven reader so the static substring-fade still
            // animates on iOS < 18.
            StreamingRevealCountReader { manager, revealCount in
                RevealAnimatedMarkdownText(
                    displayText: prepared.attributedString,
                    characterCount: prepared.characterCount,
                    blockTextOffset: offsetBase + blockTextOffset,
                    cjkItalicRanges: prepared.cjkItalicRanges,
                    revealManager: manager,
                    revealCount: revealCount,
                    freshActivation: freshActivation,
                    minimumInterval: minimumInterval
                )
            }
        }
    }
}

/// Lightweight fade-reveal view for table cells in the `.active` phase.
///
/// **Why this exists**: every active cell otherwise goes through
/// `StreamingRevealCountReader` → `RevealAnimatedMarkdownText` →
/// `FadeRevealMarkdownText`. The first link subscribes to the manager
/// listener and writes `@State revealCount` on every notify — at N≈1000
/// active cells (real tables), the notify fan-out hits every reader's
/// `@State` and cascades a body re-eval down the full chain ≈ 1000 times per
/// second. This view bypasses that: the TimelineView inside reads
/// `revealManager.revealedCount` synchronously on each draw tick (~30Hz),
/// so we still get the live frontier value without ever subscribing the
/// view to the manager's listener queue. Cell phase transitions are owned
/// by `AdaptiveTableCellPhaseHolder`, so when the cell becomes `.past` the
/// whole view unmounts and the TimelineView naturally stops.
@available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
private struct TableCellFadeRevealText: View {
    let prepared: PreparedMarkdownText
    let offsetBase: Int
    let blockTextOffset: Int
    let freshActivation: Bool
    let minimumInterval: TimeInterval
    let revealManager: StreamingRevealManager
    let fadeConfig: MarkdownFadeRevealConfig

    @Environment(\.font) private var inheritedFont
    @Environment(\.colorScheme) private var colorScheme
    @State private var fadeState = FadeState()

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.fadeRevealTextBodyCalls)
        let fadeDuration = revealManager.adaptiveFadeDuration(baseDuration: fadeConfig.duration)
        let absoluteOffset = offsetBase + blockTextOffset

        TimelineView(.animation(minimumInterval: minimumInterval, paused: false)) { ctx in
            let revealed = revealManager.revealedCount
            markdownTextWithInlineSymbols(prepared.attributedString)
                .font(inheritedFont)
                .textRenderer(
                    RevealFadeRenderer(
                        revealedCount: revealed,
                        blockTextOffset: absoluteOffset,
                        characterCount: prepared.characterCount,
                        timelineDate: ctx.date,
                        duration: fadeDuration,
                        delay: fadeConfig.delay,
                        highlightColor: fadeConfig.highlightColor,
                        highlightStartHue: fadeConfig.highlightStartHue,
                        highlightEndHue: fadeConfig.highlightEndHue,
                        hueSaturation: fadeConfig.hueSaturation,
                        hueBrightness: fadeConfig.hueBrightness,
                        colorScheme: colorScheme,
                        state: fadeState,
                        cjkItalicRanges: prepared.cjkItalicRanges,
                        revealManager: revealManager,
                        treatExistingAsFresh: freshActivation
                    )
                )
        }
    }
}

private struct MarkdownTextStaticRevealBody: View {
    let prepared: PreparedMarkdownText
    let blockTextOffset: Int

    var body: some View {
        RevealAnimatedMarkdownText(
            displayText: prepared.attributedString,
            characterCount: prepared.characterCount,
            blockTextOffset: blockTextOffset,
            cjkItalicRanges: prepared.cjkItalicRanges,
            revealManager: nil,
            revealCount: nil,
            freshActivation: false,
            minimumInterval: 1.0 / 30.0
        )
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
    @Environment(\.markdownTableRevealTextContext) private var tableRevealContext
    
    init(_ text: AttributedString, blockTextOffset: Int = 0) {
        self.text = text
        self.blockTextOffset = blockTextOffset
    }
    
    private var fallbackPreparedText: PreparedMarkdownText {
        PreparedMarkdownText(
            attributedString: text,
            characterCount: text.characters.count,
            cjkItalicRanges: text.cjkItalicCharacterRanges()
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
            characterCount: processed.characters.count,
            cjkItalicRanges: processed.cjkItalicCharacterRanges()
        )
    }

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.markdownTextBodyCalls)
        let prepared: PreparedMarkdownText = {
            if let p = preparedText, p.characterCount == text.characters.count {
                return p
            }
            return fallbackPreparedText
        }()

        Group {
            switch tableRevealContext {
            case .inherited:
                MarkdownTextInheritedRevealGate(
                    prepared: prepared,
                    blockTextOffset: blockTextOffset
                )
            case .hidden, .past:
                MarkdownTextStaticRevealBody(
                    prepared: prepared,
                    blockTextOffset: blockTextOffset
                )
            case let .active(offsetBase, freshActivation, minimumInterval):
                MarkdownTextTableActiveRevealReader(
                    prepared: prepared,
                    offsetBase: offsetBase,
                    blockTextOffset: blockTextOffset,
                    freshActivation: freshActivation,
                    minimumInterval: minimumInterval
                )
            }
        }
        // Inline SF Symbols (e.g. local-file link icons) render one step
        // smaller than the surrounding text. Regular markdown images are
        // extracted upstream, so this only affects inline symbol glyphs.
        .imageScale(.small)
        .task(id: text) {
            let prepared = Self.prepareDisplayText(from: text, configuration: configuration)
            self.preparedText = prepared
        }
    }
}
