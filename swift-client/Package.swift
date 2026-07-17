// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSlateClient",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "AgentSlateClient", targets: ["AgentSlateClient"]),
    ],
    targets: [
        .target(name: "AgentSlateClient"),
        .testTarget(name: "AgentSlateClientTests", dependencies: ["AgentSlateClient"]),
    ]
)
