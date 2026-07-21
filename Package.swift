// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PoorMansText",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "PoorMansTextCore",
            targets: ["PoorMansTextCore"]
        ),
        .executable(
            name: "poormans-text",
            targets: ["PoorMansTextCLI"]
        ),
    ],
    targets: [
        .target(
            name: "PoorMansTextCore"
        ),
        .executableTarget(
            name: "PoorMansTextCLI",
            dependencies: ["PoorMansTextCore"]
        ),
        .testTarget(
            name: "PoorMansTextCoreTests",
            dependencies: ["PoorMansTextCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

