// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "EpubSpike",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../Packages/SpeechLogic")
    ],
    targets: [
        .testTarget(
            name: "EpubSpikeTests",
            dependencies: ["SpeechLogic"],
            path: "Tests/EpubSpikeTests",
            resources: [
                // Vendored Gutenberg books (Wayback snapshots of the same
                // URLs the CI job fetches) — the fallback tier when
                // Gutenberg 503s the runner. See EpubSpikeTests' doc comment.
                .copy("Fixtures")
            ]
        )
    ]
)
