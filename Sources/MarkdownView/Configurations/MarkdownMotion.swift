//
//  MarkdownMotion.swift
//  MarkdownView
//

import SwiftUI

/// How rendered Markdown moves, by role, so an app can give it the same motion as the
/// rest of it. Set it with ``SwiftUICore/View/markdownMotion(_:)``.
public struct MarkdownMotion: Sendable {
    /// A control answering: a mode switch, a copied mark, a selection's dots and overlay.
    public var feedback: Animation
    /// Content taking a new size: a code block or a formula settling, a quote's bar.
    public var layout: Animation
    /// Streamed content appearing. Its length comes from the reveal's pacing when that
    /// sets one, else `revealDuration`.
    public var revealCurve: UnitCurve
    public var revealDuration: TimeInterval

    public init(
        feedback: Animation = .smooth(duration: 0.2),
        layout: Animation = .smooth(duration: 0.25),
        revealCurve: UnitCurve = .easeOut,
        revealDuration: TimeInterval = 0.2
    ) {
        self.feedback = feedback
        self.layout = layout
        self.revealCurve = revealCurve
        self.revealDuration = revealDuration
    }

    public static let `default` = MarkdownMotion()

    /// Content appearing over `duration`, else over `revealDuration`.
    public func reveal(duration: TimeInterval? = nil) -> Animation {
        .timingCurve(revealCurve, duration: duration ?? revealDuration)
    }
}

extension EnvironmentValues {
    @Entry public var markdownMotion: MarkdownMotion = .default
}

extension View {
    /// Sets how the Markdown inside moves.
    nonisolated public func markdownMotion(_ motion: MarkdownMotion) -> some View {
        environment(\.markdownMotion, motion)
    }
}
