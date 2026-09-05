import Foundation
import MediaPlayer

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
    }

    /// Set by SpeechPlayer once — decides what each remote command does.
    var onCommand: ((Command) -> Void)?

    private let infoCenter = MPNowPlayingInfoCenter.default()

    /// Accumulated seconds of audio spoken, so Control Center's elapsed
    /// time keeps advancing realistically between progress callbacks.
    private var elapsed: TimeInterval = 0
    private var lastClockIn: Date?

    private init() {}

    /// Register remote commands once per app launch.
    func configure() {
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.isEnabled = true
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.stopCommand.isEnabled = true

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
    /// Called on every engine state change and progress tick.
    func publish(title: String?, isPlaying: Bool, progress: Double?, rate: Float) {
        let now = Date()

        // Bank the speaking time elapsed since the last publish.
        if let since = lastClockIn {
            elapsed += now.timeIntervalSince(since)
        }
        lastClockIn = isPlaying ? now : nil

        guard let title, !title.isEmpty else {
            clear()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Speechnotes",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        // Derive a plausible total duration from progress so the scrubber has
        // scale. Seek commands are deliberately NOT enabled — rewinding TTS
        // doesn't map onto the engine's chunked pipeline.
        if let progress, progress > 0.02 {
            info[MPMediaItemPropertyPlaybackDuration] = elapsed / progress
        }
        infoCenter.nowPlayingInfo = info
    }

    /// Clear the lock-screen surface (speech finished, stopped, or reset).
    func clear() {
        infoCenter.nowPlayingInfo = nil
        elapsed = 0
        lastClockIn = nil
    }
}
