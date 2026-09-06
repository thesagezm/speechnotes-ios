// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "PdfSpike",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../Packages/SpeechLogic")
    ],
    targets: [
        .testTarget(
            name: "PdfSpikeTests",
            dependencies: ["SpeechLogic"],
            path: "Tests/PdfSpikeTests"
        )
    ]
)
