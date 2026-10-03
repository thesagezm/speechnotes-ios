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
    dependencies: [
        // The C half of the GFM parser: cmark-gfm, GitHub's own engine. Its
        // manifest is clean; swift-markdown's is not (a Windows-only
        // unsafeFlags entry that SPM rejects in any package dependency), so
        // swift-markdown's Swift AST is vendored at Sources/Markdown —
        // same code, module name `Markdown`, no manifest politics.
        .package(
            url: "https://github.com/swiftlang/swift-cmark.git",
            exact: "0.7.0"
        )
    ],
    targets: [
        .target(
            name: "CAtomic",
            path: "Sources/CAtomic"
        ),
        .target(
            name: "Markdown",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                "CAtomic"
            ],
            path: "Sources/Markdown"
        ),
        .target(
            name: "SpeechLogic",
            dependencies: [
                "Markdown"
            ],
            path: "Sources/SpeechLogic"
        ),
        .testTarget(
            name: "SpeechLogicTests",
            dependencies: ["SpeechLogic"],
            path: "Tests/SpeechLogicTests",
            resources: [
                // EPUB test fixtures (real ZIP bytes) for ZipReader/EpubInfo.
                .copy("Fixtures")
            ]
        )
    ]
)
