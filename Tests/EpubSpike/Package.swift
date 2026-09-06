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
            path: "Tests/EpubSpikeTests"
        )
    ]
)
