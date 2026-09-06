import XCTest
import SpeechLogic

/// Pins TextHash.stableHash — the playback bookmark system persists this
/// digest, so ANY change to it invalidates every stored resume position.
/// These vectors are the compatibility contract.
final class TextHashTests: XCTestCase {

    func testEmptyStringIsTheSeed() {
        XCTAssertEqual(TextHash.stableHash(""), 5381)
    }

    func testKnownVectors() {
        // Hand-computed djb2: h = h*33 + scalar, from the 5381 seed.
        XCTAssertEqual(TextHash.stableHash("a"), 177_670)       // 5381*33 + 97
        XCTAssertEqual(TextHash.stableHash("ab"), 5_863_208)    // 177_670*33 + 98
    }

    func testStableAcrossInstances() {
        let a = "The quick brown fox"
        let b = String("The quick brown fox".reversed().reversed())
        XCTAssertEqual(TextHash.stableHash(a), TextHash.stableHash(b))
    }

    func testDifferentTextsHashDifferently() {
        let hashes = ["one", "two", "three", "One", "on e"].map(TextHash.stableHash)
        XCTAssertEqual(Set(hashes).count, hashes.count)
    }

    func testHandlesSurrogatePairsAndEmoji() {
        // Must not trap and must be content-sensitive beyond UTF-16 units.
        let plain = TextHash.stableHash("a")
        let emoji = TextHash.stableHash("a\u{1F600}")
        XCTAssertNotEqual(plain, emoji)
    }

    func testStaysPositive63Bit() {
        // Long input exercises the mask; result must fit Int64 positive.
        let long = String(repeating: "speechnotes", count: 5_000)
        let h = TextHash.stableHash(long)
        XCTAssertGreaterThanOrEqual(h, 0)
    }
}
