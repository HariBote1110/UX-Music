// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "lyrics-sync-swift",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "lyrics-sync-swift", targets: ["LyricsSyncCLI"]),
    ],
    targets: [
        .executableTarget(
            name: "LyricsSyncCLI",
            path: "Sources/LyricsSyncCLI"
        ),
    ]
)
