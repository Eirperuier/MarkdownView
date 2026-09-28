//
//  DemoAppApp.swift
//  DemoApp
//
//  Created by LiYanan2004 on 2024/10/23.
//

import SwiftUI
import MarkdownView

@main
struct DemoAppApp: App {
    init() {
        prewarmMarkdownMathRenderer()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
