//
//  FlooDesignTokens+App.swift
//  DemoApp
//
//  What the app adds to FlooDesign's tokens: the packages' motion, built from the
//  tokens' roles (`markdown`, `tiled`, applied at the app's root). The document's
//  own surfaces are in Destinations/Doc/DocTokens.swift.
//

import SwiftUI
import FlooDesign
import MarkdownView
import MessagingUI

extension FlooDesignTokens.Motion {
    static var markdown: MarkdownMotion {
        MarkdownMotion(feedback: feedbackCurve, layout: .spring(layoutSpring), revealCurve: .easeOut, revealDuration: revealDuration)
    }

    static var tiled: TiledMotion {
        TiledMotion(layout: TiledSelfSizingAnimation(.spring(layoutSpring)), scroll: scrollSpring, feedback: feedbackCurve,
                    revealDuration: revealDuration)
    }
}
