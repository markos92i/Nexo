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
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.20.0"),
    ],
    targets: [
        .target(
            name: "Nexo",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
            ]),
        .testTarget(
            name: "NexoTests",
            dependencies: ["Nexo"],
            exclude: [
                "Fixtures/NexoTestIdentity.pem"
            ],
            resources: [
                .copy("Fixtures/NexoTestIdentity.p12")
            ]
        ),
    ]
)
