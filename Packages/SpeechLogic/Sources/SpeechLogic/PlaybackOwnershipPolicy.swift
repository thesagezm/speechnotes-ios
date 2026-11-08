//
//  PlaybackOwnershipPolicy.swift
//  SpeechLogic
//
//  The two decision surfaces behind "one playback owner" and "identity-safe
//  item switching" — what a play tap MEANS when something is already
//  playing, and who must yield when a different player starts.
//
//  Pure and assertable in CI, which is the only reason they live in
//  SpeechLogic (the app target has no test target). The AVAudioEngine /
//  AVPlayer side lives in App/Sources (SpeechPlayer, AudioBookPlayer,
//  NowPlayingCenter) and cannot be tested without a device.
//

import Foundation

// MARK: - Identity / takeover (in-app item switching)

/// What a play tap on an item means, given the item the LIVE session is
/// playing.
///
/// The device-log bug this pins: `SpeechPlayer.togglePlay` resumed whatever
/// was paused without checking WHICH item the caller asked for — tapping
/// play on note B could silently resume note A, and the mini-player's
/// transport-only toggle (which passes no identity) wiped a book's
/// auto-advance chain and lock-screen payload on the way. The rule:
///
///  - same item (or an un-identifiable transport tap) → TRANSPORT:
///    pause/resume the live session in place. Nothing about the session's
///    dressing may change.
///  - a different identified item → TAKEOVER: the OLD item's bookmark is
///    PRESERVED (written, not cleared) so it stays resumable, the old
///    session ends, and the tapped item starts.
///  - nothing live → also TRANSPORT: the tap simply starts.
public enum PlaybackTakeoverDecision: Equatable {
    /// Pause/resume (or start) without ending anything or touching state.
    case transport
    /// Persist the live item's bookmark, end its session, start the
    /// requested item.
    case takeoverKeepBookmark
}

public enum PlaybackTakeoverPolicy {

    /// The decision for a play tap whose requested item is
    /// `requestedItemId` (a stable string the caller builds — e.g.
    /// "note:<uuid>" / "book:<uuid>") while the live session plays
    /// `liveItemId`.
    ///
    /// Identity strings are opaque here; the callers own the format. nil
    /// requested identity = a transport-only tap from a surface that does
    /// not know what is playing (the mini-player) — it ALWAYS means the live
    /// session, never a takeover. nil live identity = nothing is playing.
    public static func decide(
        requestedItemId: String?,
        liveItemId: String?
    ) -> PlaybackTakeoverDecision {
        // Nothing live (or no identity for it): the tap starts playback.
        // There is no old session to preserve.
        guard let liveItemId else { return .transport }
        // Transport-only tap: the surface has no item identity, so it can
        // only mean the live session.
        guard let requestedItemId else { return .transport }
        // Same item: transport. Different item: takeover that keeps the old
        // item's bookmark resumable.
        return requestedItemId == liveItemId ? .transport : .takeoverKeepBookmark
    }

    /// Builds the stable identity string the decision compares. Books win
    /// over notes when a caller carries both (a book chapter speaks through
    /// the note machinery with the book ref attached — its identity is the
    /// BOOK's). nil when neither is set (anonymous text).
    public static func identity(noteId: String?, bookId: String?) -> String? {
        if let bookId { return "book:\(bookId)" }
        if let noteId { return "note:\(noteId)" }
        return nil
    }
}

// MARK: - Single playback owner (TTS ↔ audiobook)

/// The app's playback owners. TTS (notes + book chapters through
/// `SpeechPlayer`) and the audiobook file player (`AudioBookPlayer`) are the
/// two engines that can hold the device's audio; the ownership rule is that
/// AT MOST ONE holds it at a time.
public enum PlaybackOwnerKind: Equatable {
    case tts
    case audiobook
}

/// What the starter must do about the CURRENT owner before it starts.
public enum PlaybackOwnershipDecision: Equatable {
    /// No conflict — nothing holds audio, or the starter IS the current
    /// owner (its own supersede/transport rules apply).
    case proceed
    /// Another kind of player holds audio: stop it first — through its own
    /// position-preserving path — then start.
    case stopOtherFirst
}

public enum PlaybackOwnershipPolicy {

    /// The rule for a start/resume on `starting` while `currentOwner` holds
    /// playback. Same-owner restarts are governed by that player's own
    /// single-slot/supersede rules; only a CROSS-KIND start takes the
    /// stop-other-first path, which is what keeps TTS and Opus audio from
    /// ever sounding together.
    public static func decide(
        currentOwner: PlaybackOwnerKind?,
        starting: PlaybackOwnerKind
    ) -> PlaybackOwnershipDecision {
        guard let currentOwner else { return .proceed }
        return currentOwner == starting ? .proceed : .stopOtherFirst
    }
}
