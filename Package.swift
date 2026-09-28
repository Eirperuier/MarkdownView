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
        .package(url: "https://github.com/Eirperuier/LaTeXSwiftUI.git", revision: "8ceff0dfea469dba36c21a7691082200477a203f"),
        .package(url: "https://github.com/Eirperuier/RichText.git", revision: "5367ac323aea59e60ca5d55887456fbe03f8087b"),
    ],
    targets: [
        .target(
            name: "MarkdownView",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(
                    name: "Highlightr",
                    package: "Highlightr",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
                .product(
                    name: "LaTeXSwiftUI",
                    package: "LaTeXSwiftUI",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
                // Text-based selectable rendering reuses every block renderer and the reveal; iOS and macOS only.
                .product(
                    name: "RichText",
                    package: "RichText",
                    condition: .when(platforms: [.iOS, .macOS])
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
