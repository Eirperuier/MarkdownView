// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MarkdownView",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "MarkdownView", targets: ["MarkdownView"]),
        .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
    ],
    dependencies: [
        // CJK-friendly emphasis delimiters (and the matching swift-cmark fork).
        .package(url: "https://github.com/Eirperuier/swift-markdown.git", revision: "daac37a4170ddb163eb2db53f97d0cf1ee742c18"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
        // Forks carrying the changes the selectable path and math rendering need; each on its
        // fork's floo branch.
        .package(url: "https://github.com/techx-academy/floo-LaTeXSwiftUI.git", revision: "1f710d85c22e92c8c8e38f368d5db0ba02a8611d"),
        .package(url: "https://github.com/techx-academy/floo-RichText.git", revision: "7ba20965389b550c49fc960e0d8727ee42143a69"),
    ],
    targets: [
        // What parses and holds markdown, with no drawing in it.
        .target(
            name: "MarkdownCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(
                    name: "Highlightr",
                    package: "Highlightr",
                    condition: .when(platforms: [.iOS, .macCatalyst, .macOS])
                ),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarkdownView",
            dependencies: [
                "MarkdownCore",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(
                    name: "Highlightr",
                    package: "Highlightr",
                    condition: .when(platforms: [.iOS, .macCatalyst, .macOS])
                ),
                .product(
                    name: "LaTeXSwiftUI",
                    package: "floo-LaTeXSwiftUI",
                    condition: .when(platforms: [.iOS, .macCatalyst, .macOS])
                ),
                // Text-based selectable rendering reuses every block renderer and the reveal; iOS and macOS only.
                .product(
                    name: "RichText",
                    package: "floo-RichText",
                    condition: .when(platforms: [.iOS, .macCatalyst, .macOS])
                ),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarkdownViewTests",
            dependencies: ["MarkdownView"]
        ),
    ]
)
