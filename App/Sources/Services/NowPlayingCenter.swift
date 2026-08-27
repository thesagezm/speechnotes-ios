import Foundation
import MediaPlayer

/// Keeps the lock screen / Control Center "Now Playing" surface in sync with
/// `SpeechPlayer`. Two jobs:
///
/// 1. Register remote commands (play / pause / toggle / stop) so the user can
///    control playback while the app is backgrounded.
/// 2. Publish now-playing metadata (title, live progress) — iOS shows this
///    for any app whose audio session is active in the background, and its
///    presence signals the system that the app is legitimately playing media.
///
/// Designed to be driven by SpeechPlayer's published state — the app
/// registers for those `@Published` values and forwards them here.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private let center = MPNowPlayingInfoCenter.default()
    /// Seconds of audio already spoken across the current note (monotonic,
    /// not per-chunk progress).
    private var elapsedAtLastEvent: TimeInterval = 0
    private var lastEventAt: Date = Date()
    private var lastRate: Float = 0

    private init() {}

    enum Command {
        case play
        case pause
        case stop
    }

    var onCommand: ((Command) -> Void)?

    /// Called once at app start — hooks play/pause/toggle/stop into the
    /// shared remote-command center.
    func configure() {
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.isEnabled = true
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.stopCommand.isEnabled = true

        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let handler = self?.onCommand else { return .commandFailed }
            handler(.pause)                    // toggle is decided by SpeechPlayer
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

    /// Forward a SpeechPlayer state + progress + title update.
    /// Call on every state change (and periodically while speaking) so
    /// elapsed-playback-time stays believable in Control Center.
    func publish(title: String?, isPlaying: Bool, progress: Double?, rate: Float) {
        let now = Date()
        if isPlaying {
            elapsedAtLastEvent += now.timeIntervalSince(lastEventAt) * TimeInterval(max(lastRate, 0.0))
        } else if lastRate > 0, !isPlaying {
            // Paused/stopped: freeze the accumulation at its last value.
            elapsedAtLastEvent += now.timeIntervalSince(lastEventAt) * TimeInterval(lastRate)
        }
        lastEventAt = now
        lastRate = isPlaying ? rate : 0

        guard let title, !title.isEmpty else {
            center.nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Speechnotes",
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let progress, progress > 0 {
            // Fake a duration from progress ≈ elapsed / progress so the
            // scrubber has something to hang on. Not user-scrubbable (we
            // don't forward seek commands), purely visual.
            let approximateDuration = max(elapsedAtLastEvent / progress, elapsedAtLastEvent + 1)
            info[MPMediaItemPropertyPlaybackDuration] = approximateDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedAtLastEvent
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
        center.nowPlayingInfo = info
    }

    /// Clear the lock-screen surface (note finished or stop pressed).
    func clear() {
        center.nowPlayingInfo = nil
        elapsedAtLastEvent = 0
        lastEventAt = Date()
        lastRate = 0
    }
}
