// swift-tools-version: 6.0

import PackageDescription

/// Markdown drawn with UIKit and TextKit, no SwiftUI, in floo-uikit's colours: iOS and Mac
/// Catalyst. A package of its own, as FlooUIKit asks for iOS 18 and MarkdownView still serves
/// iOS 17, tvOS and watchOS.
let package = Package(
    name: "MarkdownUIKit",
    platforms: [.iOS(.v18), .macCatalyst(.v18), .macOS(.v15)],
    products: [
        .library(name: "MarkdownUIKit", targets: ["MarkdownUIKit"]),
    ],
    dependencies: [
        .package(path: ".."),
        // MarkdownView's fork of it: a visitor reads its nodes.
        .package(url: "https://github.com/Eirperuier/swift-markdown.git", revision: "daac37a4170ddb163eb2db53f97d0cf1ee742c18"),
        .package(path: "../../markdown-uikit-deps/floo-RichText"),
        // Formulas: KaTeX's layout in Swift, CJK from the system's fonts.
        .package(url: "https://github.com/PhraseHQ/SwaTex.git", revision: "153738a2bcdcb62450ead9ab292989e3de0a449f"),
        .package(path: "../../markdown-uikit-deps/floo-SwiftDraw"),
        .package(path: "../../floo-uikit"),
    ],
    targets: [
        .target(
            name: "MarkdownUIKit",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownView"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "RichTextCore", package: "floo-RichText"),
                .product(name: "SwaTexRender", package: "SwaTex"),
                .product(name: "SwiftDrawCore", package: "floo-SwiftDraw"),
                .product(name: "FlooUIKit", package: "floo-uikit"),
                .product(name: "FlooColor", package: "floo-uikit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarkdownUIKitTests",
            dependencies: ["MarkdownUIKit", .product(name: "FlooColor", package: "floo-uikit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
