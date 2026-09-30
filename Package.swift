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
    ],
    dependencies: [
        // CJK-friendly emphasis delimiters (and the matching swift-cmark fork).
        .package(url: "https://github.com/Eirperuier/swift-markdown.git", revision: "daac37a4170ddb163eb2db53f97d0cf1ee742c18"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
        // Forks carrying the changes the selectable path and math rendering need;
        // see each fork's history on top of its upstream tag.
        .package(url: "https://github.com/techx-academy/floo-LaTeXSwiftUI.git", revision: "5f30cfed06654efce58dc8ef296ce5ec6b1e016a"),
        .package(url: "https://github.com/techx-academy/floo-RichText.git", revision: "33040f50d475362e05b989b53422ae56176afe73"),
    ],
    targets: [
        .target(
            name: "MarkdownView",
            dependencies: [
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
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarkdownViewTests",
            dependencies: ["MarkdownView"]
        ),
    ]
)
