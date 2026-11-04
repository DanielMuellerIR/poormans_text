// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [
    .library(name: "PoorMansTextCore", targets: ["PoorMansTextCore"]),
    .executable(name: "poormans-text", targets: ["PoorMansTextCLI"]),
]
var dependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
var targets: [Target] = []

#if os(Linux)
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.2.0"))
coreDependencies += [.product(name: "Crypto", package: "swift-crypto"), "CPMTLinux", "zlib"]
products.append(.executable(name: "poormans-text-process-guard", targets: ["PoorMansTextProcessGuard"]))
targets += [
    .target(name: "CPMTLinux", linkerSettings: [.linkedLibrary("png16")]),
    .systemLibrary(name: "zlib", path: "Sources/CZlib", pkgConfig: "zlib",
                   providers: [.apt(["zlib1g-dev"])]),
    .executableTarget(name: "PoorMansTextProcessGuard", linkerSettings: [.unsafeFlags(["-static-stdlib"])]),
]
#else
// Der Updater bleibt exakt gepinnt und außerhalb des Linux-Abhängigkeitsbaums.
dependencies += [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"),
]
products.append(.executable(name: "PoorMansTextApp", targets: ["PoorMansTextApp"]))
targets += [
    .executableTarget(
        name: "PoorMansTextApp",
        dependencies: ["PoorMansTextAppSupport", "PoorMansTextCore"],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])]
    ),
    .target(
        name: "PoorMansTextAppSupport",
        dependencies: [
            "PoorMansTextCore",
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "Markdown", package: "swift-markdown"),
        ]
    ),
    .testTarget(name: "PoorMansTextCoreTests",
                dependencies: ["PoorMansTextAppSupport", "PoorMansTextCore"],
                resources: [.copy("Fixtures")]),
]
#endif

targets += [
    .target(name: "PoorMansTextCore", dependencies: coreDependencies),
    .executableTarget(name: "PoorMansTextCLI", dependencies: ["PoorMansTextCore"]),
    .testTarget(name: "PoorMansTextPortableTests", dependencies: ["PoorMansTextCore"]),
]
#if os(Linux)
targets.append(.testTarget(name: "PoorMansTextLinuxTests", dependencies: ["PoorMansTextCore", "CPMTLinux"]))
#endif

let package = Package(
    name: "PoorMansText", platforms: [.macOS(.v13)],
    products: products, dependencies: dependencies, targets: targets,
    swiftLanguageModes: [.v6]
)
