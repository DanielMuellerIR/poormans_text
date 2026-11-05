// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "P11ProjectionProbe", products: [.executable(name: "p11-projection", targets: ["ProjectionProbe"])],
 dependencies: [.package(path: "/dependencies/swift-crypto")], targets: [
 .target(name: "CPMTLinux", linkerSettings: [.linkedLibrary("png16")]),
 .systemLibrary(name: "zlib", path: "Sources/CZlib", pkgConfig: "zlib"),
 .target(name: "PoorMansTextCore", dependencies: [.product(name: "Crypto", package: "swift-crypto"), "CPMTLinux", "zlib"], resources: [.copy("LinuxBackends")], swiftSettings: [.unsafeFlags(["-enable-testing"])]),
 .executableTarget(name: "ProjectionProbe", dependencies: ["PoorMansTextCore"])
 ])
