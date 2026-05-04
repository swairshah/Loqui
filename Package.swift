// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loqui",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Loqui", targets: ["Loqui"]),
        .executable(name: "loqui-cli", targets: ["LoquiCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.3"),
    ],
    targets: [
        // Shared client library
        .target(
            name: "LoquiClient",
            path: "Sources/LoquiClient",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Main menubar app
        .executableTarget(
            name: "Loqui",
            dependencies: [
                "LoquiClient",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Loqui",
            exclude: ["Info.plist", "Loqui.entitlements"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // CLI tool. Built as loqui-cli to avoid colliding with the Loqui app
        // executable on case-insensitive macOS filesystems; install scripts copy
        // it to the user-facing `loqui` command.
        .executableTarget(
            name: "LoquiCLI",
            dependencies: ["LoquiClient"],
            path: "Sources/LoquiCLI",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
