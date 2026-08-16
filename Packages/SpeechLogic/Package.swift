// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "SpeechLogic",
    platforms: [
        // `.iOS(.v18)` sugar requires swift-tools-version 6.0+; the string
        // overload expresses the same iOS 18.0 minimum while staying
        // compatible with tools 5.9 (Swift 5 language mode).
        .iOS("18.0"),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SpeechLogic",
            targets: ["SpeechLogic"]
        )
    ],
    targets: [
        .target(
            name: "SpeechLogic",
            path: "Sources/SpeechLogic"
        ),
        .testTarget(
            name: "SpeechLogicTests",
            dependencies: ["SpeechLogic"],
            path: "Tests/SpeechLogicTests"
        )
    ]
)
