// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "lyrics-sync-swift",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "lyrics-sync-swift", targets: ["LyricsSyncCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "LyricsSyncCLI",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/LyricsSyncCLI"
        ),
    ]
)
