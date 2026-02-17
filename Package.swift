// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Loqui",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Loqui", targets: ["Loqui"]),
        .executable(name: "ptts", targets: ["ptts"]),
    ],
    dependencies: [
    ],
    targets: [
        // Shared client library
        .target(
            name: "LoquiClient",
            path: "Sources/LoquiClient"
        ),
        // Main menubar app
        .executableTarget(
            name: "Loqui",
            dependencies: [],
            path: "Sources/Loqui",
            exclude: ["Info.plist", "Loqui.entitlements"]
        ),
        // CLI tool
        .executableTarget(
            name: "ptts",
            dependencies: ["LoquiClient"],
            path: "Sources/ptts"
        )
    ]
)
