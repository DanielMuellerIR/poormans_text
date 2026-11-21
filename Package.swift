// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [
    .library(name: "PoorMansTextCore", targets: ["PoorMansTextCore"]),
    .executable(name: "poormans-text", targets: ["PoorMansTextCLI"]),
]
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"),
]
var coreDependencies: [Target.Dependency] = []
var coreResources: [Resource] = []
var coreExclusions: [String] = []
var coreTestDependencies: [Target.Dependency] = [
    "PoorMansTextCore",
    .product(name: "Markdown", package: "swift-markdown"),
]
var coreTestExclusions: [String] = []
var targets: [Target] = []

#if os(Linux)
coreResources = [.copy("LinuxBackends")]
coreTestDependencies.append("zlib")
coreTestExclusions = ["Apple"]
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
// Der Updater bleibt außerhalb des Linux-Abhängigkeitsbaums.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"))
coreExclusions = ["LinuxBackends"]
coreTestDependencies.append("PoorMansTextAppSupport")
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
]
#endif

targets += [
    .target(
        name: "PoorMansTextCore",
        dependencies: coreDependencies,
        exclude: coreExclusions,
        resources: coreResources
    ),
    .executableTarget(name: "PoorMansTextCLI", dependencies: ["PoorMansTextCore"]),
    .testTarget(
        name: "PoorMansTextCoreTests",
        dependencies: coreTestDependencies,
        exclude: coreTestExclusions,
        resources: [.copy("Fixtures")]
    ),
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
