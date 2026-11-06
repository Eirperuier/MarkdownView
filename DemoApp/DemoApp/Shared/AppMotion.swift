//
//  AppMotion.swift
//  DemoApp
//
//  The app's motion, from floo's tokens (`FlooMotion`): what its pages animate with, and
//  the packages' own (`markdown`, `tiled`, applied at the app's root).
//

import FlooUIKit
import SwiftUI
import MarkdownView
import MessagingUI

@MainActor
enum AppMotion {
    nonisolated static let layoutSpring = Spring(duration: FlooMotion.listLayout.duration, bounce: 0)
    nonisolated static let scrollSpring = Spring(duration: FlooMotion.listScroll.duration, bounce: 0)
    nonisolated static var feedbackCurve: Animation { FlooMotion.press.swiftUI ?? .linear(duration: 0) }
    nonisolated static var revealDuration: TimeInterval { FlooMotion.appear.duration }

    static var layout: Animation? { FlooMotion.listLayout.swiftUI }
    static var step: Animation? { FlooMotion.floatingResize.swiftUI }
    static var feedback: Animation? { FlooMotion.press.swiftUI }
    static var pulse: Animation? { FlooMotion.pulse.swiftUI?.repeatForever(autoreverses: true) }

    nonisolated static var markdown: MarkdownMotion {
        MarkdownMotion(feedback: feedbackCurve, layout: .spring(layoutSpring), revealCurve: .easeOut, revealDuration: revealDuration)
    }

    nonisolated static var tiled: TiledMotion {
        TiledMotion(layout: TiledSelfSizingAnimation(.spring(layoutSpring)), scroll: scrollSpring, feedback: feedbackCurve,
                    revealDuration: revealDuration)
    }
}
