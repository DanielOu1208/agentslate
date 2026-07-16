// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HerdrRemoteClient",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "HerdrRemoteClient", targets: ["HerdrRemoteClient"]),
    ],
    targets: [
        .target(name: "HerdrRemoteClient"),
        .testTarget(name: "HerdrRemoteClientTests", dependencies: ["HerdrRemoteClient"]),
    ]
)
