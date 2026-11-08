import Foundation
import MediaPlayer
import SpeechLogic
import UIKit

/// Keeps the lock screen / Control Center "Now Playing" surface in sync with
/// `SpeechPlayer`.
///
/// Two jobs:
/// 1. Register remote commands (play / pause / toggle / stop) on
///    `MPRemoteCommandCenter` so playback is controllable from the lock
///    screen, Control Center, and Bluetooth headsets while the app is
///    backgrounded.
/// 2. Publish now-playing metadata — its presence is what signals iOS that
///    the declared `audio` background mode is genuinely in use, which is
///    what keeps the process alive and the audio session active in the
///    background.
///
/// Driven by `SpeechPlayer`'s state/progress callbacks; the app never
/// touches `MediaPlayer` anywhere else.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    enum Command {
        case toggle
        case play
        case pause
        case stop
        /// Chapter-granular skips — the reader's Previous/Next buttons.
        case previousChapter
        case nextChapter
        /// ±N-second skips — the lock screen's skip buttons (audiobooks
        /// only; synthesized speech is not seconds-addressable).
        case skipBackward
        case skipForward
    }

    /// Set by SpeechPlayer once — decides what each remote command does.
    /// Returns true when the TTS side actually consumed the command (acted
    /// on it); false lets the target report failure so iOS does not believe
    /// a command was handled by a session that no longer exists.
    var onCommand: ((Command) -> Bool)?

    /// Set by AudioBookPlayer on its first play and never removed. Returns
    /// true when it consumed the command (an audiobook is the active
    /// playback), false to let the command fall through to `onCommand`. A
    /// router rather than a steal: SpeechPlayer's handler assignment stays
    /// untouched, so TTS playback regains the buttons the moment no
    /// audiobook is loaded — reassigning `onCommand` from two owners would
    /// leave whichever wired second in permanent control.
    var audioBookHandler: ((Command) -> Bool)?

    /// True when SOME owner consumed `command`. A command no owner consumed
    /// (nothing playing, or the live player cannot act on it) reports
    /// failure to iOS instead of the old blanket `.success` — the lock
    /// screen then stops believing every tap "worked" against a dead
    /// session, which is exactly the stale-surface symptom that made Control
    /// Center keep sending pause against a paused session.
    @discardableResult
    private func dispatch(_ command: Command) -> Bool {
        var consumed = false
        switch command {
        case .skipBackward, .skipForward:
            // Seconds-addressable content only: a ±15 s seek into
            // synthesized speech is a lie (it's generated per sentence
            // chunk), so these never fall through to SpeechPlayer.
            if let audioBookHandler { consumed = audioBookHandler(command) }
        default:
            if let audioBookHandler, audioBookHandler(command) {
                consumed = true
            } else if let onCommand {
                consumed = onCommand(command)
            }
        }
        logCommandOutcome(command: command, consumed: consumed)
        return consumed
    }

    // MARK: Bounded command logging

    /// One line per distinct outcome, throttled so a mash of lock-screen
    /// taps cannot spam the log: a future device log must be able to
    /// distinguish a ROUTED command (somebody consumed it) from an IGNORED
    /// one (no owner acted — nothing is playing, or the live player cannot),
    /// and from an accepted-but-silent resume (the resume path's own log
    /// lines cover that case). The throttle holds one suppressed count per
    /// outcome so the log still says how many repeats it ate.
    private var lastCommandLogAt: Date?
    private var lastCommandLogKey: String?
    private var suppressedCommandLogs = 0
    private static let commandLogCooldown: TimeInterval = 2.0

    private func logCommandOutcome(command: Command, consumed: Bool) {
        let key = "\(command)-\(consumed)"
        let now = Date()
        if key == lastCommandLogKey, let last = lastCommandLogAt,
           now.timeIntervalSince(last) < Self.commandLogCooldown {
            suppressedCommandLogs += 1
            return
        }
        if suppressedCommandLogs > 0, lastCommandLogKey != nil {
            Log.shared.info("NowPlayingCenter: (+\(suppressedCommandLogs) suppressed repeats)")
        }
        suppressedCommandLogs = 0
        lastCommandLogKey = key
        lastCommandLogAt = now
        if consumed {
            Log.shared.info("NowPlayingCenter: remote \(command) routed to the active playback owner")
        } else {
            Log.shared.info("NowPlayingCenter: remote \(command) IGNORED — no playback owner consumed it")
        }
    }

    /// Set by SpeechPlayer/BookPlaybackController when a book chapter starts
    /// — subtitle (e.g. "Ch 12 — The Reunion") and cover go out on every
    /// publish until another book/none takes over.
    var currentSubtitle: String?
    var currentArtwork: UIImage?

    private let infoCenter = MPNowPlayingInfoCenter.default()

    /// Accumulated seconds of audio spoken (banked across pause/resume), so
    /// Control Center's elapsed time keeps a believable value.
    private var elapsed: TimeInterval = 0
    /// Wall-clock moment the current playing stretch started; nil when not
    /// playing (paused / idle / generating).
    private var playStartedAt: Date?
    /// Wall-clock of the last publish — writes are throttled since every
    /// engine progress tick would otherwise spam mediaserverd.
    private var lastPublishAt: Date?
    /// The playing state the last WRITE published — the state-edge ledger.
    /// A publish whose isPlaying differs from this bypasses the cadence
    /// throttle entirely (see NowPlayingPublishPolicy); reset in `clear()`
    /// so the first publish of a fresh session is never throttled either.
    private var lastPublishedIsPlaying: Bool?

    private var configured = false

    private init() {}

    /// Register remote commands once per app lifetime.
    func configure() {
        guard !configured else { return }
        configured = true

        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.isEnabled = true
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.stopCommand.isEnabled = true
        // Skip buttons double as chapter navigation for books: content isn't
        // seconds-addressable (it's synthesized per sentence chunk), so a
        // ±15 s seek would be a lie. Chapter skip is exact.
        commands.previousTrackCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true

        commands.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatch(.previousChapter) ? .success : .commandFailed
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatch(.nextChapter) ? .success : .commandFailed
        }

        // The lock screen's skip buttons (v1.7.2, audiobooks): iOS shows
        // them only while the commands are enabled AND the published info
        // carries MPNowPlayingInfoPropertyPreferredIntervals. Disabled by
        // default; AudioBookPlayer enables them on play and disables on
        // stop (synthesized speech gets chapter buttons instead).
        commands.skipBackwardCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatch(.skipBackward) ? .success : .commandFailed
        }
        commands.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatch(.skipForward) ? .success : .commandFailed
        }

        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatch(.toggle) ? .success : .commandFailed
        }
        commands.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatch(.play) ? .success : .commandFailed
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatch(.pause) ? .success : .commandFailed
        }
        commands.stopCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatch(.stop) ? .success : .commandFailed
        }
    }

    /// Publish current playback so the lock screen shows the note title,
    /// an advancing elapsed time, and a roughly-correct total duration.
    /// Accepts a title of nil (anonymous text) with a generic fallback — a
    /// missing surface during backgrounded speech weakens the background
    /// mode contract. `subtitle` shows as the artist row (book chapter,
    /// e.g. "Ch 12 — The Reunion"); `artwork` is a pre-rendered UIImage
    /// (book cover) that lands as the lock-screen thumbnail.
    ///
    /// `elapsedSeconds`/`durationSeconds` (audiobook path): absolute player
    /// position and file length — published directly instead of the
    /// wall-clock bank / progress-derived estimate, and the bank resyncs so
    /// a later TTS session starts from a sane elapsed.
    func publish(
        title: String?,
        subtitle: String? = nil,
        artwork: UIImage? = nil,
        isPlaying: Bool,
        progress: Double?,
        rate: Float,
        elapsedSeconds: TimeInterval? = nil,
        durationSeconds: TimeInterval? = nil,
        chapterCount: Int? = nil,
        chapterNumber: Int? = nil
    ) {
        let now = Date()

        // Bank playing time; pause/resume no longer loses elapsed seconds.
        if let elapsedSeconds {
            // Absolute position from the player: the bank takes the value
            // and restarts its wall-clock accumulation from here.
            elapsed = elapsedSeconds
            playStartedAt = isPlaying ? now : nil
        } else if isPlaying {
            if let started = playStartedAt {
                elapsed += now.timeIntervalSince(started)
            }
            playStartedAt = now
        } else {
            playStartedAt = nil
        }

        // Throttle: mediaserverd doesn't need per-tick updates — EXCEPT a
        // play/pause STATE EDGE, which is exactly what the device-log bug
        // hinged on (a throttled pause left the published rate nonzero
        // indefinitely, so Control Center kept showing "playing" and sent
        // another pause). The decision lives in SpeechLogic so CI pins it:
        // edges publish immediately; only same-state cadence updates wait.
        let sinceLast = lastPublishAt.map { now.timeIntervalSince($0) }
        guard NowPlayingPublishPolicy.shouldPublish(
            isPlaying: isPlaying,
            lastPublishedIsPlaying: lastPublishedIsPlaying,
            secondsSinceLastPublish: sinceLast
        ) else { return }
        lastPublishAt = now
        lastPublishedIsPlaying = isPlaying

        let displayTitle = (title?.isEmpty == false) ? title! : "Speechnotes"

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: displayTitle,
            MPMediaItemPropertyArtist: subtitle ?? currentSubtitle ?? "Speechnotes",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        let resolvedArtwork = artwork ?? currentArtwork
        if let resolvedArtwork {
            let item = MPMediaItemArtwork(boundsSize: resolvedArtwork.size) { _ in resolvedArtwork }
            info[MPMediaItemPropertyArtwork] = item
        }
        // Derive a plausibly-stable total duration from progress. Only
        // publish once progress has meaningfully advanced — the early
        // estimates jump around visibly in Control Center. An explicit
        // duration (real file length) always wins.
        if let durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        } else if let progress, progress > 0.05 {
            info[MPMediaItemPropertyPlaybackDuration] = elapsed / progress
        }
        if let chapterCount {
            info[MPNowPlayingInfoPropertyChapterCount] = chapterCount
        }
        if let chapterNumber {
            info[MPNowPlayingInfoPropertyChapterNumber] = chapterNumber
        }
        if let skipInterval {
            // Raw key: the C constant is not surfaced to Swift here.
            info["MPNowPlayingInfoPropertyPreferredIntervals"] = [skipInterval]
        }
        infoCenter.nowPlayingInfo = info
    }

    /// Chapter skating is book-only: when SpeechPlayer has no book bound,
    /// the buttons stay registered but greyed (system behavior for
    /// unsupported track commands).
    func setChapterSkipEnabled(_ enabled: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        commands.previousTrackCommand.isEnabled = enabled
        commands.nextTrackCommand.isEnabled = enabled
    }

    /// The ±N-second lock-screen skip buttons (audiobooks). Enabled state
    /// rides the audiobook's own lifecycle; `interval` goes out with every
    /// publish so iOS labels the buttons ("15s") — without the intervals
    /// property the system hides them.
    private var skipInterval: TimeInterval?

    func setSkipBackForwardEnabled(_ enabled: Bool, interval: TimeInterval = 15) {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.isEnabled = enabled
        commands.skipForwardCommand.isEnabled = enabled
        skipInterval = enabled ? interval : nil
        republish()
    }

    /// Re-issues the last publish (same metadata) — used when the skip
    /// buttons' availability changes, so the lock screen reflects it at
    /// once instead of on the next cadence tick.
    private func republish() {
        guard let info = infoCenter.nowPlayingInfo else { return }
        var updated = info
        if let skipInterval {
            updated["MPNowPlayingInfoPropertyPreferredIntervals"] = [skipInterval]
        } else {
            updated.removeValue(forKey: "MPNowPlayingInfoPropertyPreferredIntervals")
        }
        infoCenter.nowPlayingInfo = updated
    }

    /// Clear the lock-screen surface (speech finished, stopped, or reset).
    /// The publish ledger resets WITH the surface: the first publish of the
    /// next session must not be throttled against a timestamp (or a playing
    /// state) that belonged to a session that no longer exists.
    func clear() {
        infoCenter.nowPlayingInfo = nil
        elapsed = 0
        playStartedAt = nil
        lastPublishAt = nil
        lastPublishedIsPlaying = nil
        currentSubtitle = nil
        currentArtwork = nil
    }
}
