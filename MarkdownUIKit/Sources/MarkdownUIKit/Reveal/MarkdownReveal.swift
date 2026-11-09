//
//  MarkdownReveal.swift
//  MarkdownUIKit
//
//  What a streaming reveal is given: who keeps its count, and how it looks. The count lives in
//  MarkdownCore's StreamingRevealManager, which a coordinator drives.
//

import FlooUIKit
import MarkdownCore
import UIKit

public extension FlooMotion {
    /// A streamed character fading in. Text keeps fading a little past this, in the highlight's
    /// colour (`MarkdownRevealStyle.colorDurationMultiplier`). A fade moves nothing, so Reduce
    /// Motion leaves it.
    static let markdownReveal = FlooMotion(duration: 0.5, curve: .easeOut, reduced: .same)
    /// A reveal's highlight going once through its hues and back.
    static let markdownRevealHue = FlooMotion(duration: 8, curve: .linear, reduced: .same)
}

public extension FlooColorRole {
    /// What a character being revealed is tinted with. A theme sets it to name one colour; left
    /// unset a reveal may go through hues of its own (`MarkdownRevealStyle.Highlight.hues`).
    static let markdownRevealHighlight = FlooColorRole("markdown.revealHighlight") { $0[.accent] }
}

/// How a reveal looks. Its times come from a motion token.
public struct MarkdownRevealStyle {
    public enum Highlight {
        /// A colour, normally a role's.
        case color(UIColor)
        /// From `start` to `end` and back over `FlooMotion.markdownRevealHue`, hues from 0 to 1,
        /// unless the theme sets `markdownRevealHighlight`, which wins.
        case hues(start: Double, end: Double, saturation: Double, brightness: Double)
    }

    /// The colour stays on this much longer than the opacity takes to arrive.
    public static let colorDurationMultiplier = 1.8

    public var motion: FlooMotion
    public var delay: TimeInterval
    public var highlight: Highlight

    public init(
        motion: FlooMotion = .markdownReveal,
        delay: TimeInterval = 0,
        highlight: Highlight = .color(.floo(.markdownRevealHighlight))
    ) {
        self.motion = motion
        self.delay = max(0, delay)
        self.highlight = highlight
    }
}

/// A reveal over a block's text.
public struct MarkdownReveal {
    public let manager: StreamingRevealManager
    public let style: MarkdownRevealStyle

    public init(manager: StreamingRevealManager, style: MarkdownRevealStyle = MarkdownRevealStyle()) {
        self.manager = manager
        self.style = style
    }
}

/// Whether a thing that appears whole (a quote's ground, a formula on its own) has been reached
/// yet, told when that changes. Only a crossing just now fades: one crossed long ago is there.
@MainActor
final class MarkdownRevealGate {
    private var manager: StreamingRevealManager?
    private var listenerID: UUID?
    private var isOpen: Bool?
    private let threshold: Int
    private let apply: @MainActor (_ isOpen: Bool, _ fades: Bool) -> Void

    init(threshold: Int = 0, apply: @escaping @MainActor (_ isOpen: Bool, _ fades: Bool) -> Void) {
        self.threshold = threshold
        self.apply = apply
    }

    /// Nil: nothing to wait for, it's there.
    func follow(_ manager: StreamingRevealManager?) {
        guard manager !== self.manager || manager == nil else { return }
        stop()
        self.manager = manager
        guard let manager else {
            isOpen = true
            apply(true, false)
            return
        }
        isOpen = nil
        listenerID = manager.addListener { [weak self] count in
            MainActor.assumeIsolated { self?.update(count) }
        }
    }

    func stop() {
        if let listenerID { manager?.removeListener(listenerID) }
        listenerID = nil
        manager = nil
    }

    private func update(_ count: Int) {
        let open = count == Int.max || count > threshold
        guard open != isOpen else { return }
        let isFirst = isOpen == nil
        isOpen = open
        // First told, it was reached before this view came: it fades only if that was just now.
        let fades = open && (!isFirst || Self.isFresh(manager?.firstSeenTimestamp(at: threshold)))
        if fades { apply(false, false) }
        apply(open, fades)
    }

    /// As a late view sees a thing that crossed a moment ago: still fading.
    static func isFresh(_ stamp: Date?) -> Bool {
        stamp.map { MarkdownRevealClock.now.timeIntervalSince($0) < 0.6 } ?? false
    }
}
