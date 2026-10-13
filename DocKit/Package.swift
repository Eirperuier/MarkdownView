// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .treatAllWarnings(as: .error),
]

/// The document model: blocks, steps, undo and server-ordered sync.
/// Pure Swift, no UI frameworks; must also build for Linux.
let package = Package(
    name: "DocKit",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "DocKit", targets: ["DocKit"]),
        .executable(name: "doclab", targets: ["doclab"]),
    ],
    dependencies: [
        // The CJK-friendly fork MarkdownView parses with, at the same revision.
        .package(url: "https://github.com/Eirperuier/swift-markdown.git", revision: "daac37a4170ddb163eb2db53f97d0cf1ee742c18"),
    ],
    targets: [
        .target(
            name: "DocKit",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        // The agent's doc tools from the command line, for evaluating how a model writes.
        .executableTarget(name: "doclab", dependencies: ["DocKit"]),
        .testTarget(
            name: "DocKitTests",
            dependencies: ["DocKit"],
            resources: [.copy("Golden")]
        ),
    ]
)

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + swiftSettings
}
