//
//  MarkdownCodeDisplay.swift
//  MarkdownUIKit
//
//  What a code block's two looks share: the view a block asks for, the highlight coming in off
//  the main thread, and following a reveal by lines.
//

import FlooUIKit
import MarkdownCore
import RichTextCore
import UIKit

/// A code block's view, whichever look it draws.
@MainActor
protocol MarkdownCodeDisplay: UIView {
    /// The block changed height by itself.
    var onHeightChange: (() -> Void)? { get set }
    /// The text view inside, if the code is in one.
    var textView: UITextView? { get }
    /// The code as laid out, for a selection across blocks.
    var selectableText: MarkdownSelectableText? { get }
    func configure(code: String, language: String?, style: MarkdownStyle, reveal: MarkdownReveal?)
    func setReveal(_ reveal: MarkdownReveal?)
    func prepareForReuse()
    func height(forWidth width: CGFloat) -> CGFloat
}

extension MarkdownCodeBlockStyle {
    /// The box has no place for a Preview/Code switch or an editor: those keep the header.
    func usesBox(for language: String?) -> Bool {
        look == .box && renderer(for: language) == nil && replacement == nil
    }

    @MainActor
    func makeDisplay(for language: String?) -> any MarkdownCodeDisplay {
        usesBox(for: language) ? MarkdownCodeBoxView() : MarkdownCodeBlockView()
    }

    @MainActor
    func isDisplay(_ view: any MarkdownCodeDisplay, for language: String?) -> Bool {
        usesBox(for: language) == (view is MarkdownCodeBoxView)
    }
}

/// Colours coming to code: at once if they're at hand, else off the main thread a moment later.
/// Only the latest of a stream is worth it. What it gives lays nothing out.
@MainActor
final class MarkdownCodeHighlightLoader {
    /// Gives the tokens to the text; false if it can't take them.
    var apply: ((MarkdownCodeTokens) -> Bool)?

    private var task: Task<Void, Never>?
    private var code = ""
    private var highlighted: String?

    func show(code: String, language: String?, highlighter: (any MarkdownCodeHighlighter)?, isOnWindow: Bool) {
        self.code = code
        guard let highlighter, highlighted != code else { return }
        if let tokens = highlighter.cachedTokens(code: code, language: language) {
            cancel()
            give(tokens, for: code)
            return
        }
        guard isOnWindow else { return }
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let tokens = await highlighter.tokens(code: code, language: language) else { return }
            await self?.arrived(tokens, for: code)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// This code is coloured already.
    func didShow(_ code: String) {
        self.code = code
        highlighted = code
    }

    func reset() {
        cancel()
        highlighted = nil
    }

    private func arrived(_ tokens: MarkdownCodeTokens, for code: String) {
        guard !Task.isCancelled, self.code.hasPrefix(code) else { return }
        give(tokens, for: code)
    }

    private func give(_ tokens: MarkdownCodeTokens, for code: String) {
        guard tokens.string == code || code.hasPrefix(tokens.string) || tokens.string.hasPrefix(code), apply?(tokens) == true else { return }
        highlighted = code
    }

    isolated deinit {
        task?.cancel()
    }
}

/// A reveal reaching a code block: the block appears when it's reached, then line by line.
@MainActor
final class MarkdownCodeLineReveal {
    private weak var view: UIView?
    private var listener: UUID?
    private(set) var manager: StreamingRevealManager?
    private var metrics = MarkdownCodeRevealMetrics(code: "")
    /// A new line was reached.
    var onChange: (() -> Void)?

    private lazy var gate = MarkdownRevealGate { [weak self] isOpen, fades in
        guard let self else { return }
        let change: () -> Void = { self.view?.alpha = isOpen ? 1 : 0 }
        if fades, let manager = self.manager {
            var motion = FlooMotion.markdownBlockReveal
            motion.duration = manager.adaptiveFadeDuration(baseDuration: motion.duration)
            motion.animate(change)
        } else {
            change()
        }
    }

    init(view: UIView) {
        self.view = view
    }

    /// Lines going by a reveal, or all of them shown.
    var isRevealing: Bool {
        guard let manager else { return false }
        return manager.revealedCount != Int.max
    }

    func measure(_ code: String) {
        metrics = MarkdownCodeRevealMetrics(code: code)
    }

    func follow(_ manager: StreamingRevealManager?) {
        gate.follow(manager)
        guard manager !== self.manager else { return }
        stopFollowingLines()
        self.manager = manager
        if let manager {
            listener = manager.addListener { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
    }

    func stop() {
        gate.stop()
        stopFollowingLines()
    }

    private func stopFollowingLines() {
        if let listener { manager?.removeListener(listener) }
        listener = nil
        manager = nil
    }

    /// How many of the first `limit` lines have started, and whether all of them have ended.
    func visibleLines(limit: Int) -> (count: Int, allEnded: Bool) {
        guard let manager, manager.revealedCount != Int.max else { return (limit, true) }
        let revealed = manager.revealedCount
        return (metrics.visibleLineCount(revealed: revealed, limit: limit), revealed > metrics.end(afterLineCount: limit))
    }
}
