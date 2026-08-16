// swift-tools-version: 6.0
import PackageDescription

// Standalone spike package: runs the Kokoro pipeline with `swift test` on CI.
// Lives outside the Xcode project on purpose — SPM's own test runner handles
// the package's resource bundles correctly, xcodebuild's does not.
let package = Package(
    name: "KokoroSpike",
    platforms: [
        .macOS(.v15)
    ],
    swiftLanguageModes: [.v5],
    dependencies: [
        .package(url: "https://github.com/mlalma/kokoro-ios", exact: "1.0.11"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
    ],
    targets: [
        .testTarget(
            name: "KokoroSpikeTests",
            dependencies: [
                .product(name: "KokoroSwift", package: "kokoro-ios"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
            ],
            path: "Tests/KokoroSpikeTests"
        )
    ]
)
