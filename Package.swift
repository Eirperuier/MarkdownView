// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MarkdownView",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "MarkdownView", targets: ["MarkdownView"]),
        // 3.0 textSelection 路径,与魔改 MarkdownView 并存隔离,主 app 单独 link
        .library(name: "MarkdownTextKit", targets: ["MarkdownTextKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Eirperuier/swift-markdown.git", branch: "cjk-friendly-emphasis"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
        .package(path: "../LaTeXSwiftUI"),
        // 3.0 文本路径(可选中)依赖:纯文本渲染包,零外部依赖,仅 iOS/macOS
        // 复用主 app 已引入的本地 RichText-main(与 flowith.xcodeproj 同一物理包,避免重复)
        .package(path: "../RichText-main"),
        // 3.0 完整渲染依赖:math 渲染(原生 CoreText,非 WebView)
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
    ],
    targets: [
        .target(
            name: "MarkdownView",
            dependencies: [
                .product(
                    name: "Markdown",
                    package: "swift-markdown"
                ),
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
                // text-based 可选中渲染路径:做进本 module 以复用全部 block 渲染 + reveal;仅 iOS/macOS
                .product(
                    name: "RichText",
                    package: "RichText-main",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // MARK: - MarkdownTextKit(完整 3.0 / 含 textSelection)
        // 独立 target,与魔改 MarkdownView 隔离:整体搬入纯净完整的 3.0 渲染栈
        // (view-based 富渲染 + 文本可选中渲染),共享 swift-markdown(CJK fork)。
        .target(
            name: "MarkdownTextKit",
            dependencies: [
                .product(
                    name: "Markdown",
                    package: "swift-markdown"
                ),
                .product(
                    name: "RichText",
                    package: "RichText-main",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
                .product(
                    name: "Highlightr",
                    package: "Highlightr",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
                .product(
                    name: "SwiftMath",
                    package: "SwiftMath",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // 开启 math 富渲染(SwiftMath);3.0 用此 flag gate math 路径
                .define("ENABLE_MATH_RENDERING"),
            ]
        ),
        .testTarget(
            name: "MarkdownViewTests",
            dependencies: [
                "MarkdownView",
            ]
        ),
    ]
)
