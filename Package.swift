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
        // Command maps: sentence → an app's own actions, via the on-device
        // model and rules. Deliberately dependency-free and separate from
        // RipulAgent, so an app can adopt it without the agent stack — and so
        // nothing Ripul-specific can leak in.
        .library(name: "RipulCommands", targets: ["RipulCommands"]),
        // The theme layer alone: the roles, the accessors, the root, the document loader
        // and where the redirect plug-in's generated file lands. No dependencies, and one
        // resource (its privacy manifest), so a host can theme its shipping app without
        // the agent stack.
        // `RipulAgent` re-exports it: a host that links the whole SDK writes nothing new.
        .library(name: "RipulThemeKit", targets: ["RipulThemeKit"]),
        // The theme for a host that changes none of its source: a build-tool plug-in a
        // host switches on for its app target. Opt-in; a host that does not is untouched.
        .plugin(name: "RipulThemeRedirect", targets: ["RipulThemeRedirect"]),
    ],
    dependencies: [
        // See docs/native-chat-markdown.md and the fork's RIPUL.md.
        .package(url: "https://github.com/ripulio/swift-markdown-ui.git", exact: "2.4.2-ripul.3"),
        // 0.2.0 added the frame limit the voice orb needs (VoiceModeOverlay.swift).
        .package(url: "https://github.com/ripulio/thinking-orbs-swift.git", from: "0.2.0"),
        .package(url: "https://github.com/appstefan/HighlightSwift.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "RipulAgent",
            dependencies: [
                "RipulThemeKit",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "ThinkingOrbs", package: "thinking-orbs-swift"),
                .product(name: "HighlightSwift", package: "HighlightSwift"),
            ],
            resources: [
                .process("Resources/providers.json"),
                .process("Resources/InspectorEngine.js"),
                .process("Resources/RipulBranding.xcassets"),
            ]
        ),
        .testTarget(
            name: "RipulAgentTests",
            dependencies: ["RipulAgent"]
        ),
        .target(name: "RipulCommands"),
        .target(
            name: "RipulThemeKit",
            // The theme keeps the person's choice of theme in UserDefaults, and says so.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "RipulThemeKitTests",
            dependencies: ["RipulThemeKit"]
        ),
        .plugin(name: "RipulThemeRedirect", capability: .buildTool()),
        .testTarget(
            name: "RipulCommandsTests",
            dependencies: ["RipulCommands"]
        ),
    ]
)
