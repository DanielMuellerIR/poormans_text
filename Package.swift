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
    dependencies: [
        // Der Updater tauscht die installierte App aus. Deshalb exakt gepinnt:
        // ein Versionssprung wird bewusst geprüft, nie still aufgelöst.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "PoorMansTextCore"
        ),
        // Die CLI bleibt bewusst frei von Sparkle: sie aktualisiert sich nicht
        // selbst, sondern liegt als Symlink in der installierten App.
        .executableTarget(
            name: "PoorMansTextCLI",
            dependencies: ["PoorMansTextCore"]
        ),
        .executableTarget(
            name: "PoorMansTextApp",
            dependencies: ["PoorMansTextAppSupport", "PoorMansTextCore"],
            linkerSettings: [
                // SwiftPM gibt einer Binärdatei nur @loader_path mit. Das fertige
                // Bundle legt Sparkle standardkonform unter Contents/Frameworks ab,
                // deshalb braucht die App diesen zusätzlichen Suchpfad.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../Frameworks",
                ])
            ]
        ),
        .target(
            name: "PoorMansTextAppSupport",
            dependencies: [
                "PoorMansTextCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "PoorMansTextCoreTests",
            dependencies: ["PoorMansTextAppSupport", "PoorMansTextCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
