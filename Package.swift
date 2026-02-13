// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RipulAgent",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "RipulAgent", targets: ["RipulAgent"]),
    ],
    targets: [
        .target(name: "RipulAgent"),
    ]
)
