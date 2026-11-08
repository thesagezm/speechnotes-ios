//
//  PlaybackOwnershipPolicyTests.swift
//  SpeechLogic
//
//  Tests for the identity/takeover decisions (what a play tap MEANS when
//  something is already playing) and the single-owner rule (what a starter
//  must do about a cross-kind owner). The device-log bugs these pin:
//  togglePlay resuming the WRONG item, a mini-player transport toggle wiping
//  a book's auto-advance, and Opus + TTS audio sounding simultaneously.
//

import XCTest
@testable import SpeechLogic

final class PlaybackOwnershipPolicyTests: XCTestCase {

    // MARK: - Identity / takeover decisions

    /// Nothing live: the tap simply starts — no takeover machinery, nothing
    /// to preserve.
    func testStartWithNothingLiveIsTransport() {
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: "note:A", liveItemId: nil),
            .transport)
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: nil, liveItemId: nil),
            .transport)
    }

    /// Same item: transport — pause/resume in place, session dressing
    /// untouched.
    func testSameItemIsTransport() {
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: "note:A", liveItemId: "note:A"),
            .transport)
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: "book:B", liveItemId: "book:B"),
            .transport)
    }

    /// The mini-player's transport-only tap (no requested identity) always
    /// means the LIVE session — it must never take over, and never wipe a
    /// book's auto-advance/payload on the way.
    func testUnidentifiedTapIsTransportOnLiveItem() {
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: nil, liveItemId: "book:B"),
            .transport)
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: nil, liveItemId: "note:A"),
            .transport)
    }

    /// A different identified item takes over: the old bookmark is kept
    /// resumable, the old session ends, the tapped item starts. Note A →
    /// note B, note → book, book → note, book → other book — all takeovers.
    func testDifferentItemIsTakeoverKeepBookmark() {
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: "note:B", liveItemId: "note:A"),
            .takeoverKeepBookmark)
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: "book:B", liveItemId: "note:A"),
            .takeoverKeepBookmark)
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: "note:A", liveItemId: "book:B"),
            .takeoverKeepBookmark)
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: "book:C", liveItemId: "book:B"),
            .takeoverKeepBookmark)
    }

    /// Kind prefixes cannot collide: a note and a book with the same raw id
    /// string are DIFFERENT items.
    func testIdentityPrefixesPreventCollisions() {
        XCTAssertEqual(
            PlaybackTakeoverPolicy.decide(requestedItemId: "note:1", liveItemId: "book:1"),
            .takeoverKeepBookmark)
    }

    /// The identity builder: books win over notes when both are carried (a
    /// book chapter speaks through the note machinery), and anonymous text
    /// has no identity.
    func testIdentityBuilder() {
        XCTAssertEqual(PlaybackTakeoverPolicy.identity(noteId: "n1", bookId: "b1"), "book:b1")
        XCTAssertEqual(PlaybackTakeoverPolicy.identity(noteId: "n1", bookId: nil), "note:n1")
        XCTAssertNil(PlaybackTakeoverPolicy.identity(noteId: nil, bookId: nil))
    }

    // MARK: - Single-owner transitions

    /// No current owner: the starter proceeds.
    func testStartWhenIdleProceeds() {
        XCTAssertEqual(
            PlaybackOwnershipPolicy.decide(currentOwner: nil, starting: .tts),
            .proceed)
        XCTAssertEqual(
            PlaybackOwnershipPolicy.decide(currentOwner: nil, starting: .audiobook),
            .proceed)
    }

    /// Same-owner restarts are governed by that player's own single-slot
    /// rules — no cross-kind stop.
    func testSameOwnerRestartProceeds() {
        XCTAssertEqual(
            PlaybackOwnershipPolicy.decide(currentOwner: .tts, starting: .tts),
            .proceed)
        XCTAssertEqual(
            PlaybackOwnershipPolicy.decide(currentOwner: .audiobook, starting: .audiobook),
            .proceed)
    }

    /// Cross-kind starts must stop the other player FIRST — this is the
    /// "never simultaneous audio" rule for both directions.
    func testCrossKindStartStopsOtherFirst() {
        XCTAssertEqual(
            PlaybackOwnershipPolicy.decide(currentOwner: .audiobook, starting: .tts),
            .stopOtherFirst)
        XCTAssertEqual(
            PlaybackOwnershipPolicy.decide(currentOwner: .tts, starting: .audiobook),
            .stopOtherFirst)
    }
}
