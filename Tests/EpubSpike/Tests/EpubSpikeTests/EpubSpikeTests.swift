import XCTest
import SpeechLogic

/// EPUB spike — the CI contract test for ZipReader + EpubInfo against REAL
/// books (the fixture-based unit tests in SpeechLogic cover the synthetic
/// cases; this covers whatever Project Gutenberg's toolchain actually emits).
/// Books are downloaded by the `epub-spike` CI job into ~/epub-spike
/// (override with EPUB_SPIKE_DIR); marker lines "EPUB-SPIKE ..." are grepped
/// by the job's failure-summary step.
final class EpubSpikeTests: XCTestCase {

    private func book(_ filename: String) throws -> Data {
        let dir = ProcessInfo.processInfo.environment["EPUB_SPIKE_DIR"]
            ?? NSHomeDirectory() + "/epub-spike"
        let url = URL(fileURLWithPath: dir).appendingPathComponent(filename)
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Shared structural contract every book must satisfy.
    private func assertValidEpub(_ data: Data, expectedTitleFragment: String, minSpine: Int, minToc: Int, minCoverBytes: Int, label: String) throws {
        let entries = try ZipReader.entries(in: data)
        XCTAssertTrue(entries.contains { $0.name == "META-INF/container.xml" }, "container.xml missing")
        XCTAssertTrue(entries.contains { $0.name == "mimetype" }, "mimetype missing")

        let info = try EpubInfo.parse(archive: data)
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
