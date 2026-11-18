import XCTest
import SpeechLogic

/// EPUB spike — the CI contract test for ZipReader + EpubInfo against REAL
/// books (the fixture-based unit tests in SpeechLogic cover the synthetic
/// cases; this covers whatever Project Gutenberg's toolchain actually emits).
///
/// Two input tiers, by design:
///
/// 1. FRESH — the `epub-spike` CI job downloads the books into ~/epub-spike
///    (override with EPUB_SPIKE_DIR). When Gutenberg serves, today's emits
///    are what get tested.
/// 2. VENDORED — Fixtures/pg*.epub, Wayback snapshots of the same URLs
///    (2026-11-09/15, byte-faithful). Gutenberg 503s cloud-runner IPs
///    arbitrarily (2026-11-18: every file, both runs), so a missing fresh
///    book can never again turn the job red — the tests always run.
///
/// Marker lines "EPUB-SPIKE ..." are grepped by the job's failure-summary
/// step.
final class EpubSpikeTests: XCTestCase {

    private func book(_ filename: String) throws -> Data {
        // Fresh first, per file: a partial-fetch leaves the other books
        // untouched, and a book Gutenberg didn't serve must fall back
        // instead of failing the test.
        if let dir = ProcessInfo.processInfo.environment["EPUB_SPIKE_DIR"]
            ?? (FileManager.default.fileExists(atPath: NSHomeDirectory() + "/epub-spike")
                ? NSHomeDirectory() + "/epub-spike" : nil),
           FileManager.default.fileExists(atPath: dir + "/" + filename) {
            return try Data(contentsOf: URL(fileURLWithPath: dir + "/" + filename),
                            options: .mappedIfSafe)
        }
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: (filename as NSString).deletingPathExtension,
                              withExtension: "epub",
                              subdirectory: "Fixtures"),
            "vendored fixture \(filename) missing from the test bundle")
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Shared structural contract every book must satisfy.
    private func assertValidEpub(_ data: Data, expectedTitleFragment: String, minSpine: Int, minToc: Int, minCoverBytes: Int, label: String) throws {
        let entries = try ZipReader.entries(in: data)
        XCTAssertTrue(entries.contains { $0.name == "META-INF/container.xml" }, "container.xml missing")
        XCTAssertTrue(entries.contains { $0.name == "mimetype" }, "mimetype missing")

        let info = try EpubParser.parse(archive: data)
        print("EPUB-SPIKE \(label): title=\(info.title ?? "?") creator=\(info.creator ?? "?") spine=\(info.spine.count) toc=\(info.toc.count) cover=\(info.coverPath ?? "none")")

        XCTAssertNotNil(info.title)
        XCTAssertTrue(info.title?.localizedCaseInsensitiveContains(expectedTitleFragment) == true,
                      "title \(info.title ?? "?") should contain \(expectedTitleFragment)")
        XCTAssertNotNil(info.creator, "creator missing")
        XCTAssertGreaterThanOrEqual(info.spine.count, minSpine, "spine too short")
        XCTAssertGreaterThanOrEqual(info.toc.count, minToc, "TOC too short")
        XCTAssertNotNil(info.coverPath, "cover not detected")
        let cover = try ZipReader.readEntry(try XCTUnwrap(info.coverPath), in: data)
        XCTAssertGreaterThan(cover.count, minCoverBytes, "cover suspiciously small (\(cover.count) bytes)")
        // Every TOC href and spine path must be a real zip entry — one broken
        // resolution here would send the reader hunting for a phantom file.
        for href in info.spine + info.toc.map(\.href) {
            XCTAssertTrue(entries.contains { $0.name == href }, "resolved path not in archive: \(href)")
        }
    }

    func testPrideAndPrejudice() throws {
        try assertValidEpub(
            try book("pg1342.epub"),
            expectedTitleFragment: "Pride and Prejudice",
            minSpine: 10, minToc: 20, minCoverBytes: 10_000,
            label: "pg1342"
        )
    }

    func testAliceInWonderland() throws {
        try assertValidEpub(
            try book("pg11.epub"),
            expectedTitleFragment: "Alice",
            minSpine: 5, minToc: 5, minCoverBytes: 10_000,
            label: "pg11"
        )
    }

    func testFrankenstein() throws {
        try assertValidEpub(
            try book("pg84.epub"),
            expectedTitleFragment: "Frankenstein",
            minSpine: 5, minToc: 5, minCoverBytes: 10_000,
            label: "pg84"
        )
    }
}
