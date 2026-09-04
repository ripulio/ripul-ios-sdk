// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RipulAgent",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RipulAgent", targets: ["RipulAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
        .package(url: "https://github.com/ripulio/thinking-orbs-swift.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "RipulAgent",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "ThinkingOrbs", package: "thinking-orbs-swift"),
            ],
            resources: [
                .process("Resources/providers.json"),
                .process("Resources/RipulBranding.xcassets"),
            ]
        ),
        .testTarget(
            name: "RipulAgentTests",
            dependencies: ["RipulAgent"]
        ),
    ]
)
