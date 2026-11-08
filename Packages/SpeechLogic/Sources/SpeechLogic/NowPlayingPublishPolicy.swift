//
//  NowPlayingPublishPolicy.swift
//  SpeechLogic
//
//  The publish throttle behind the lock-screen / Control Center surface —
//  the decision `NowPlayingCenter.publish` applies on every engine tick.
//
//  Pure and assertable in CI, which is the only reason it lives in
//  SpeechLogic (the app target has no test target). The MediaPlayer side
//  lives in App/Sources/Services/NowPlayingCenter.swift and cannot be
//  tested without a device.
//

import Foundation

/// Whether a now-playing info write should happen NOW.
///
/// The device log's Control Center bug: a rapid pause could leave
/// `MPNowPlayingInfoPropertyPlaybackRate` nonzero indefinitely, because the
/// pause's publish was throttled away like every other tick — Control Center
/// still showed "playing", so the user's next tap sent PAUSE again instead of
/// PLAY and the session looked dead. The rule that fixes it: a STATE EDGE
/// (playing ↔ paused) is never throttled — only same-state cadence updates
/// (the progress ticks while a session plays, the repeated paused publishes)
/// wait for their window.
///
/// The decision takes already-measured inputs (current state, the state the
/// last write published, seconds since that write) so the whole throttle —
/// including its edge behavior — is pin-able in CI without MediaPlayer.
public enum NowPlayingPublishPolicy {

    /// Seconds a playing session's same-state updates are throttled to.
    /// Control Center extrapolates between publishes from rate + elapsed, so
    /// a half-second cadence keeps the scrubber smooth.
    public static let playingCadenceSeconds: Double = 0.5

    /// Seconds a paused session's same-state updates are throttled to. A
    /// paused surface has nothing to extrapolate; the cadence only exists so
    /// metadata changes (artwork, title) still land.
    public static let pausedCadenceSeconds: Double = 0.75

    /// True when the caller must write `MPNowPlayingInfoCenter` now.
    ///
    /// - `isPlaying`: the state being published.
    /// - `lastPublishedIsPlaying`: the state the last WRITE published; nil
    ///   when nothing was ever written (or the ledger was cleared) — the
    ///   first write after a clear is always immediate.
    /// - `secondsSinceLastPublish`: elapsed since that write; nil means the
    ///   same (no prior write).
    public static func shouldPublish(
        isPlaying: Bool,
        lastPublishedIsPlaying: Bool?,
        secondsSinceLastPublish: Double?
    ) -> Bool {
        // A state edge (or a first publish after a clear) lands immediately:
        // Control Center's transport state must never trail the real session.
        if lastPublishedIsPlaying == nil || isPlaying != lastPublishedIsPlaying {
            return true
        }
        // Same state: cadence throttle. No prior timestamp cannot happen
        // here (an existing ledger implies a prior write), but treating it
        // as publishable is the safe direction.
        guard let seconds = secondsSinceLastPublish else { return true }
        let cadence = isPlaying ? playingCadenceSeconds : pausedCadenceSeconds
        return seconds >= cadence
    }
}
