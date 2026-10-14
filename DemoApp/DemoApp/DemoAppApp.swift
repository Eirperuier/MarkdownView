//
//  DemoAppApp.swift
//  DemoApp
//
//  Created by LiYanan2004 on 2024/10/23.
//

import SwiftUI
import MarkdownView
import MessagingUI
import FlooDesign

@main
struct DemoAppApp: App {
    init() {
        prewarmMarkdownMathRenderer()
        TrackpadScrollMomentum.install()
        // `==highlight==` and `:circle[…]` pen marks, on as the app does at launch.
        MarkdownHighlightSyntax.isEnabled = true
        MarkdownHighlightSyntax.backgroundColor = MarkdownColorToken.highlight("yellow")
        MarkdownPenMarkSyntax.isEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .markdownMotion(FlooDesignTokens.Motion.markdown)
                .tiledMotion(FlooDesignTokens.Motion.tiled)
        }
        .commands { DocCommands() }
    }
}
