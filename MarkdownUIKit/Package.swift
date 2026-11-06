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
        .package(path: "../../markdown-uikit-deps/floo-RichText"),
        .package(path: "../../floo-uikit"),
    ],
    targets: [
        .target(
            name: "MarkdownUIKit",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownView"),
                .product(name: "RichTextCore", package: "floo-RichText"),
                .product(name: "FlooUIKit", package: "floo-uikit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarkdownUIKitTests",
            dependencies: ["MarkdownUIKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
