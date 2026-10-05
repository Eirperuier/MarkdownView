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
    ],
    targets: [
        .target(name: "DocKit"),
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
