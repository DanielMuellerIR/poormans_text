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
        .executable(
            name: "PoorMansTextApp",
            targets: ["PoorMansTextApp"]
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
        .executableTarget(
            name: "PoorMansTextApp",
            dependencies: ["PoorMansTextAppSupport", "PoorMansTextCore"]
        ),
        .target(
            name: "PoorMansTextAppSupport",
            dependencies: ["PoorMansTextCore"]
        ),
        .testTarget(
            name: "PoorMansTextCoreTests",
            dependencies: ["PoorMansTextAppSupport", "PoorMansTextCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
