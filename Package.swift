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
        // A CMS site's running record as a Live Activity: the attributes and the
        // ready-made widget a host's widget extension lists. No dependencies, so an
        // extension links this alone. `RipulAgent` starts, updates and ends it.
        .library(name: "RipulLiveActivity", targets: ["RipulLiveActivity"]),
        // The theme for a host that changes none of its source: a build-tool plug-in a
        // host switches on for its app target. Opt-in; a host that does not is untouched.
        .plugin(name: "RipulThemeRedirect", targets: ["RipulThemeRedirect"]),
    ],
    dependencies: [
        // See docs/native-chat-markdown.md and the fork's RIPUL.md.
        .package(url: "https://github.com/ripulio/swift-markdown-ui.git", exact: "2.4.2-ripul.5"),
        // Share MarkdownUI's parser when locating display-only context mentions.
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.4.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
        .package(url: "https://github.com/2389-research/MermaidKit.git", exact: "2.9.0"),
        // 0.2.0 added the frame limit the voice orb needs (VoiceModeOverlay.swift).
        .package(url: "https://github.com/ripulio/thinking-orbs-swift.git", from: "0.2.0"),
        .package(url: "https://github.com/appstefan/HighlightSwift.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "CmsQuickJS",
            exclude: ["LICENSE", "VERSION"],
            publicHeadersPath: "include",
            cSettings: [
                .define("CONFIG_VERSION", to: "\"2025-09-13\""),
                .define("_GNU_SOURCE", to: "1"),
            ]
        ),
        .target(
            name: "RipulAgent",
            dependencies: [
                "CmsQuickJS",
                "RipulThemeKit",
                "RipulLiveActivity",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "MermaidRender", package: "MermaidKit"),
                .product(name: "MermaidLayout", package: "MermaidKit"),
                .product(name: "ThinkingOrbs", package: "thinking-orbs-swift"),
                .product(name: "HighlightSwift", package: "HighlightSwift"),
            ],
            resources: [
                .process("Resources/providers.json"),
                .copy("Resources/SwiftMath-LICENSE.txt"),
                .copy("Resources/MermaidKit-LICENSE.txt"),
                .process("Resources/InspectorEngine.js"),
                .process("Resources/RipulBranding.xcassets"),
            ]
        ),
        .testTarget(
            name: "RipulAgentTests",
            dependencies: ["RipulAgent"]
        ),
        .target(name: "RipulCommands"),
        .target(name: "RipulLiveActivity"),
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
