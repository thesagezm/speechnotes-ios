import Foundation
import MediaPlayer
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
    }

    /// Set by SpeechPlayer once — decides what each remote command does.
    var onCommand: ((Command) -> Void)?

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
            guard let handler = self?.onCommand else { return .commandFailed }
            handler(.previousChapter)
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard let handler = self?.onCommand else { return .commandFailed }
            handler(.nextChapter)
            return .success
        }

        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let handler = self?.onCommand else { return .commandFailed }
            handler(.toggle)
            return .success
        }
        commands.playCommand.addTarget { [weak self] _ in
            guard let handler = self?.onCommand else { return .commandFailed }
            handler(.play)
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let handler = self?.onCommand else { return .commandFailed }
            handler(.pause)
            return .success
        }
        commands.stopCommand.addTarget { [weak self] _ in
            guard let handler = self?.onCommand else { return .commandFailed }
            handler(.stop)
            return .success
        }
    }

    /// Publish current playback so the lock screen shows the note title,
    /// an advancing elapsed time, and a roughly-correct total duration.
    /// Accepts a title of nil (anonymous text) with a generic fallback — a
    /// missing surface during backgrounded speech weakens the background
    /// mode contract. `subtitle` shows as the artist row (book chapter,
    /// e.g. "Ch 12 — The Reunion"); `artwork` is a pre-rendered UIImage
    /// (book cover) that lands as the lock-screen thumbnail.
    func publish(
        title: String?,
        subtitle: String? = nil,
        artwork: UIImage? = nil,
        isPlaying: Bool,
        progress: Double?,
        rate: Float
    ) {
        let now = Date()

        // Bank playing time; pause/resume no longer loses elapsed seconds.
        if isPlaying {
            if let started = playStartedAt {
                elapsed += now.timeIntervalSince(started)
            }
            playStartedAt = now
        } else {
            playStartedAt = nil
        }

        // Throttle: mediaserverd doesn't need per-tick updates.
        if !isPlaying, let since = lastPublishAt, now.timeIntervalSince(since) < 0.75 {
            return
        }
        if isPlaying, let since = lastPublishAt, now.timeIntervalSince(since) < 0.5 {
            return
        }
        lastPublishAt = now

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
        // estimates jump around visibly in Control Center.
        if let progress, progress > 0.05 {
            info[MPMediaItemPropertyPlaybackDuration] = elapsed / progress
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

    /// Clear the lock-screen surface (speech finished, stopped, or reset).
    func clear() {
        infoCenter.nowPlayingInfo = nil
        elapsed = 0
        playStartedAt = nil
        lastPublishAt = nil
        currentSubtitle = nil
        currentArtwork = nil
    }
}
