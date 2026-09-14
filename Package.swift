// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Nexo",
    platforms: [
       .macOS(.v26), .iOS(.v26),
    ],
    products: [
        .library(
            name: "Nexo",
            targets: ["Nexo"]),
    ],
    targets: [
        .target(
            name: "Nexo"),
        .testTarget(
            name: "NexoTests",
            dependencies: ["Nexo"]
        ),
    ]
)
