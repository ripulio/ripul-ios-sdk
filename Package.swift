// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RipulAgent",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RipulAgent", targets: ["RipulAgent"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RipulAgent",
            dependencies: []
        ),
    ]
)
