//
//  DemoAppApp.swift
//  DemoApp
//
//  Created by LiYanan2004 on 2024/10/23.
//

import SwiftUI
import MarkdownView
import MessagingUI
import FlooUIKit
import CardUI
import CardModel

@main
struct DemoAppApp: App {
    init() {
        ExtensionsDestination.enableSyntax()
        prewarmMarkdownMathRenderer()
        // The cards' view packages as this build last compiled them, before any is asked for.
        Catalog.keepCompiled(in: .cachesDirectory.appending(
            path: "\(Bundle.main.bundleIdentifier ?? "DemoApp")/compiled-views", directoryHint: .isDirectory))
        DocMediaLayout.prewarm()
        TrackpadScrollMomentum.install()
        // `==highlight==` and `:circle[…]` pen marks, on as the app does at launch.
        MarkdownHighlightSyntax.isEnabled = true
        MarkdownHighlightSyntax.backgroundColor = MarkdownColorToken.highlight("yellow")
        MarkdownPenMarkSyntax.isEnabled = true
        FlooSiteIcons.install()
        // Pictures of things and services' icons come from the floo server until a stage is played.
        Assets.server = URL(string: "https://\(FlooOnline.server)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .markdownMotion(AppMotion.markdown)
                .tiledMotion(AppMotion.tiled)
        }
        .commands { DocCommands() }
    }
}
