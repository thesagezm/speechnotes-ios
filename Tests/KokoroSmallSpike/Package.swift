// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KokoroSmallSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        .package(path: "../../Packages/SpeechLogic")
    ],
    targets: [
        .testTarget(
            name: "KokoroSmallSpikeTests",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                "SpeechLogic"
            ],
            path: "Tests/KokoroSmallSpikeTests"
        )
    ]
)
