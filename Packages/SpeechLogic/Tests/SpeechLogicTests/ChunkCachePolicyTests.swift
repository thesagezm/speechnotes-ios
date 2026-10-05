//
//  ChunkCachePolicyTests.swift
//  SpeechLogic
//
//  Tests for the file-queue cache policy (Batch D of the render-to-file
//  substrate) — the cap arithmetic, the eviction order and floor, and the
//  per-chunk silence trim.
//

import XCTest
@testable import SpeechLogic

final class ChunkCachePolicyTests: XCTestCase {

    // MARK: - Cap admission

    /// A write is admitted while both caps have room — the common case, and
    /// the one that must not evict anything.
    func testAdmitsWhenUnderBothCaps() {
        let policy = ChunkCachePolicy(maxItems: 10, maxBytes: 1_000, floorItems: 2)
        XCTAssertTrue(policy.admits(bytes: 900, count: 5, incomingBytes: 50))
    }

    /// The CAP IS ENFORCED BEFORE THE WRITE. A policy that checks after has
    /// already allocated the bytes; this is the assertion that says the
    /// boundary is on the right side of the write.
    func testDoesNotAdmitWhenCountWouldExceed() {
        let policy = ChunkCachePolicy(maxItems: 10, maxBytes: 1_000_000, floorItems: 2)
        XCTAssertFalse(policy.admits(bytes: 0, count: 10, incomingBytes: 10))
        XCTAssertTrue(policy.admits(bytes: 0, count: 9, incomingBytes: 10))
    }

    func testDoesNotAdmitWhenBytesWouldExceed() {
        let policy = ChunkCachePolicy(maxItems: 100, maxBytes: 1_000, floorItems: 2)
        XCTAssertFalse(policy.admits(bytes: 950, count: 5, incomingBytes: 51))
        XCTAssertTrue(policy.admits(bytes: 950, count: 5, incomingBytes: 50))
    }

    // MARK: - Eviction order

    /// Oldest finished first, and only down to the count cap. Index 5 is
    /// unfinished (the player is on it) and index 6 is a live lookahead; the
    /// count cap of 4 is satisfied after evicting 1 and 2, so the walk stops
    /// there rather than reaching the unfinished one.
    func testEvictsOldestFinishedFirst() {
        let policy = ChunkCachePolicy(maxItems: 4, maxBytes: 10_000, floorItems: 1)
        let live = [1, 2, 3, 4, 5, 6]
        let bytes = [100, 100, 100, 100, 100, 100]
        let finished: Set<Int> = [1, 2, 4]
        let evict = policy.indexesToEvict(
            live: live, bytes: bytes, finished: finished, incomingBytes: 100)
        XCTAssertEqual(evict, [1, 2])
    }

    /// The floor protects the player's lookahead. Everything is finished,
    /// but the cache may not shrink below 3 items — so it evicts exactly
    /// down to the floor and no further, even though the count cap would
    /// allow more.
    func testFloorStopsEviction() {
        let policy = ChunkCachePolicy(maxItems: 3, maxBytes: 10_000_000, floorItems: 3)
        let live = [1, 2, 3, 4, 5, 6]
        let bytes = Array(repeating: 100, count: 6)
        let finished: Set<Int> = [1, 2, 3, 4, 5, 6]
        let evict = policy.indexesToEvict(
            live: live, bytes: bytes, finished: finished, incomingBytes: 100)
        XCTAssertEqual(evict, [1, 2, 3])
    }

    /// Nothing is evictable when nothing is finished: the cache is over its
    /// cap and the only items left are live. Empty is the CORRECT answer —
    /// the caller holds the producer rather than deleting audio the player
    /// may still schedule.
    func testNothingEvictableWhenNothingFinished() {
        let policy = ChunkCachePolicy(maxItems: 2, maxBytes: 10_000_000, floorItems: 1)
        let live = [1, 2, 3]
        let bytes = Array(repeating: 100, count: 3)
        let evict = policy.indexesToEvict(
            live: live, bytes: bytes, finished: [], incomingBytes: 100)
        XCTAssertTrue(evict.isEmpty)
    }

    /// The byte cap evicts by BYTES, not by count: seven items is under the
    /// count cap, but their total plus the incoming write exceeds 700, so
    /// the oldest finished item goes.
    func testByteCapEvictsByBytes() {
        let policy = ChunkCachePolicy(maxItems: 100, maxBytes: 700, floorItems: 1)
        let live = [1, 2, 3, 4, 5, 6, 7]
        let bytes = Array(repeating: 100, count: 7)
        let finished: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
        let evict = policy.indexesToEvict(
            live: live, bytes: bytes, finished: finished, incomingBytes: 100)
        XCTAssertEqual(evict, [1])
    }

    /// Under both caps nothing is evicted, however long the session.
    func testNoEvictionUnderCaps() {
        let policy = ChunkCachePolicy()
        let live = Array(1...10)
        let bytes = Array(repeating: 100, count: 10)
        let finished: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        XCTAssertTrue(policy.indexesToEvict(
            live: live, bytes: bytes, finished: finished, incomingBytes: 100).isEmpty)
    }

    /// A length mismatch between `live` and `bytes` is a caller bug; the
    /// policy refuses to guess and evicts nothing (which surfaces as a
    /// producer hold, not silent corruption).
    func testMismatchedLengthsEvictNothing() {
        let policy = ChunkCachePolicy(maxItems: 1, maxBytes: 1, floorItems: 0)
        XCTAssertTrue(policy.indexesToEvict(
            live: [1, 2], bytes: [100], finished: [1, 2], incomingBytes: 100).isEmpty)
        XCTAssertTrue(policy.indexesToEvict(
            live: [], bytes: [], finished: [], incomingBytes: 100).isEmpty)
    }

    // MARK: - The default caps

    /// The defaults must satisfy the properties the whole substrate rests
    /// on: the byte cap is many minutes of audio, and the item cap is far
    /// above the 4-item lookahead the queue keeps.
    func testDefaultsAreBytesAndMinutesBounded() {
        let policy = ChunkCachePolicy()
        XCTAssertEqual(policy.maxItems, 240)
        XCTAssertEqual(policy.maxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(policy.floorItems, 8)
        // 24 kHz mono Int16 = 48 KB/s, so 64 MB ≈ 22 minutes of audio.
        XCTAssertGreaterThan(Double(policy.maxBytes) / 48_000.0, 1_000.0)
        XCTAssertGreaterThan(policy.floorItems, 4)
    }

    // MARK: - The silence trim

    /// A closure-driven peak reader: 1 s of silence, 1 s of tone, 1 s of
    /// silence. The trim removes both silent runs and keeps 20 ms of
    /// padding on each side, so the plosive's onset survives.
    func testTrimRemovesLeadingAndTrailingSilence() {
        let policy = ChunkCachePolicy()
        let sampleCount = 24_000 * 3
        func peak(_ i: Int) -> Float {
            (i >= 24_000 && i < 48_000) ? 0.5 : 0.0
        }
        let trim = policy.trimmedRange(sampleCount: sampleCount, peak: peak, padding: 480)
        XCTAssertEqual(trim.start, 24_000 - 480)
        XCTAssertEqual(trim.end, 48_000 + 480)
        // Kept = end - start = the 24 000 samples of tone plus 480 of
        // padding on each side.
        XCTAssertEqual(
            policy.trimmedSampleCount(sampleCount: sampleCount, trim: trim),
            48_000 - 24_000 + 960)
    }

    /// Padding is clamped to the buffer, so a chunk that is ALL tone keeps
    /// its entire length — the trim must never manufacture a negative range.
    func testTrimClampsPaddingToBuffer() {
        let policy = ChunkCachePolicy()
        let sampleCount = 1_000
        func peak(_ i: Int) -> Float { 0.5 }
        let trim = policy.trimmedRange(sampleCount: sampleCount, peak: peak, padding: 480)
        XCTAssertEqual(trim.start, 0)
        XCTAssertEqual(trim.end, sampleCount)
    }

    /// A chunk that is entirely silence is kept whole: trimming it to zero
    /// would mean writing an empty file, and an empty file on the queue is
    /// a gap with no explanation.
    func testAllSilentChunkIsKeptWhole() {
        let policy = ChunkCachePolicy()
        let sampleCount = 5_000
        func peak(_ i: Int) -> Float { 0.0 }
        let trim = policy.trimmedRange(sampleCount: sampleCount, peak: peak)
        XCTAssertEqual(trim.start, 0)
        XCTAssertEqual(trim.end, sampleCount)
    }

    func testEmptyChunkTrimsToEmpty() {
        let policy = ChunkCachePolicy()
        let trim = policy.trimmedRange(sampleCount: 0, peak: { _ in 0.0 })
        XCTAssertEqual(trim.start, 0)
        XCTAssertEqual(trim.end, 0)
    }

    // MARK: - trimIsWorthwhile

    /// Below 20 ms the trim is not worth an extra decode seam.
    func testTrimBelowThresholdIsNotWorthwhile() {
        let policy = ChunkCachePolicy()
        XCTAssertFalse(policy.trimIsWorthwhile(sampleCount: 24_000, keptCount: 24_000 - 100))
        XCTAssertTrue(policy.trimIsWorthwhile(sampleCount: 24_000, keptCount: 24_000 - 480))
        XCTAssertTrue(policy.trimIsWorthwhile(sampleCount: 24_000, keptCount: 0))
    }

    /// A chunk shorter than the threshold never counts as worthwhile, even
    /// when trimmed to nothing — a 5 ms chunk is a broken chunk, not a trim.
    func testShortChunkIsNeverWorthwhile() {
        let policy = ChunkCachePolicy()
        XCTAssertFalse(policy.trimIsWorthwhile(sampleCount: 10, keptCount: 0))
    }

    // MARK: - Layout

    /// The session directory is under Caches/speechnotes-tts, so iOS can
    /// purge it under pressure and it never reaches a backup.
    func testSessionDirectoryIsUnderCaches() {
        let base = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Library/Caches")
        let dir = ChunkCacheLayout.sessionDirectory(base: base, sessionID: "s1700000000000")
        XCTAssertEqual(
            dir.path,
            "/var/mobile/Containers/Data/Application/X/Library/Caches/speechnotes-tts/s1700000000000")
    }

    /// Session ids are time-ordered, so the oldest directory is the first a
    /// purge would reclaim.
    func testSessionIDIsTimeOrdered() {
        let early = ChunkCacheLayout.newSessionID(now: Date(timeIntervalSince1970: 1_000))
        let late = ChunkCacheLayout.newSessionID(now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(early, "s1000000")
        XCTAssertEqual(late, "s2000000")
        XCTAssertLessThan(early, late)
    }

    func testSessionIDIsStableForASecond() {
        // Two calls inside the same millisecond produce the same id; the
        // caller creates one per session, so this is about not surprising a
        // reader, not about uniqueness.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            ChunkCacheLayout.newSessionID(now: now),
            ChunkCacheLayout.newSessionID(now: now))
    }
}
