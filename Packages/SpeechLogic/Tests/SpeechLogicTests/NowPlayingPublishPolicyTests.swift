//
//  NowPlayingPublishPolicyTests.swift
//  SpeechLogic
//
//  Tests for the now-playing publish throttle — the state-edge immediacy
//  that keeps Control Center's transport truthful (the stale-rate bug where
//  a throttled pause left the lock screen showing "playing"), the same-state
//  cadence windows, and the ledger reset after a clear.
//

import XCTest
@testable import SpeechLogic

final class NowPlayingPublishPolicyTests: XCTestCase {

    // MARK: - First publish / cleared ledger

    /// The first write after nothing was published (or after clear()) is
    /// always immediate — there is no cadence to ride yet.
    func testFirstPublishIsImmediate() {
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: nil, secondsSinceLastPublish: nil))
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: false, lastPublishedIsPlaying: nil, secondsSinceLastPublish: nil))
    }

    // MARK: - State edges bypass the throttle

    /// A playing→paused edge publishes immediately, no matter how recently
    /// the last same-state write went out — this is the Control Center fix.
    func testPauseEdgeIsImmediate() {
        XCTAssertFalse(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: false, lastPublishedIsPlaying: false, secondsSinceLastPublish: 0.01))
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: false, lastPublishedIsPlaying: true, secondsSinceLastPublish: 0.0))
    }

    /// A paused→playing edge is equally immediate: the resume must reach
    /// Control Center at once or the surface keeps sending PAUSE.
    func testPlayEdgeIsImmediate() {
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: false, secondsSinceLastPublish: 0.0))
    }

    // MARK: - Same-state cadence

    /// Playing cadence: within 0.5 s of the last write, a same-state tick is
    /// throttled; at or past it, the write lands.
    func testPlayingCadence() {
        XCTAssertFalse(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: true, secondsSinceLastPublish: 0.2))
        XCTAssertFalse(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: true, secondsSinceLastPublish: 0.49))
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: true, secondsSinceLastPublish: 0.5))
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: true, secondsSinceLastPublish: 2.0))
    }

    /// Paused cadence is looser (0.75 s): a paused surface has nothing to
    /// extrapolate, the window exists only so metadata changes still land.
    func testPausedCadence() {
        XCTAssertFalse(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: false, lastPublishedIsPlaying: false, secondsSinceLastPublish: 0.5))
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: false, lastPublishedIsPlaying: false, secondsSinceLastPublish: 0.75))
    }

    // MARK: - Rapid toggles

    /// The device-log sequence: play tick, pause, play again within the
    /// same half-second. Every edge publishes; only the same-state ticks
    /// between them could be dropped.
    func testRapidToggleEdgesAllPublish() {
        var ledger: Bool? = nil
        var last: Double? = nil
        var t = 0.0
        // play
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: ledger, secondsSinceLastPublish: last))
        ledger = true; last = t
        // pause 0.2 s later (inside the playing cadence — still immediate)
        t += 0.2
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: false, lastPublishedIsPlaying: ledger, secondsSinceLastPublish: last))
        ledger = false; last = t
        // play again 0.1 s later (inside the paused cadence — still immediate)
        t += 0.1
        XCTAssertTrue(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: ledger, secondsSinceLastPublish: last))
        ledger = true; last = t
        // same-state tick 0.3 s later — the ONLY throttled write in the run
        t += 0.3
        XCTAssertFalse(NowPlayingPublishPolicy.shouldPublish(
            isPlaying: true, lastPublishedIsPlaying: ledger, secondsSinceLastPublish: last))
    }
}
