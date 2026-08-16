// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KittenSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        .package(path: "../../Packages/SpeechLogic")
    ],
    targets: [
        .testTarget(
            name: "KittenSpikeTests",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                "SpeechLogic"
            ],
            path: "Tests/KittenSpikeTests"
        )
    ]
)
