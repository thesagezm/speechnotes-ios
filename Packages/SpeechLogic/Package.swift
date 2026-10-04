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
        // libopus, the REFERENCE Opus decoder (BSD-3-clause), vendored whole.
        // Apple's media stack has no Opus decoder we can reach, and the
        // three previous attempts all routed through an
        // AVAudioConverter/kAudioFormatOpus path that never produced a
        // decoded sample. libopus is what VLC itself links, and copying
        // VLC's exact flow (opus_header_parse -> multistream decoder ->
        // opus_packet_get_nb_frames x samples_per_frame) is the one route
        // known to decode 6-channel mapping-family-1 streams, which is
        // exactly what the user's "Opus 5.1ch" books are.
        //
        // headerSearchPath rather than unsafeFlags: the sources include
        // "opus.h", "celt.h", "main.h" and friends by bare name from
        // four different directories.
        .target(
            name: "COpus",
            path: "Sources/COpus",
            // The portable top-level C only. silk/x86, celt/x86 and the
            // NEON files are selected by libopus' own build per
            // architecture; on arm64 those macros compile the include out
            // and the generic files are what the reference build uses.
            // The portable top-level C plus silk's float backend. The
            // silk/x86 and celt/x86 .c files are selected per architecture
            // by libopus' own build and are NOT compiled here (arm64);
            // their HEADERS are kept, because pitch.h / SigProc_FIX.h
            // reference them under feature macros and the include must
            // resolve on every platform.
            sources: ["src", "celt", "silk", "silk/float"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("src"),
                .headerSearchPath("silk/float"),
                // Fixed point is unused by the decoder; the runtime build
                // libopus uses everywhere (VLC included) is float-only.
                .define("OPUS_BUILD", to: "0"),
                .define("FIXED_POINT", to: "0"),
            ]
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
                "Markdown",
                "COpus"
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
