import Foundation
import AVFoundation

/// Plays exported WAV files — the "download the note in advance and play it
/// as I read" surface (user request, round 5). One file at a time, with the
/// same transport vocabulary the live engines have: scrub, ±15 s skip, speed,
/// live elapsed/total. A shared singleton so the Storage screen, the global
/// mini-player and anywhere else observe ONE playhead.
///
/// Playback stays in-app: remote-command ownership belongs to the TTS and
/// audiobook paths, and stealing the guarded `onCommand` slot would strand
/// their lock-screen controls (the audiobook router already proved how
/// carefully that slot must be shared).
@MainActor
final class WavPlayer: ObservableObject {
    static let shared = WavPlayer()

    @Published private(set) var playingURL: URL?
    @Published private(set) var isPaused = false
    @Published private(set) var progress: Double?
    /// Live file position / length in seconds — the readouts under the
    /// scrubber. Published per tick like every other player.
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// 0.5…2.0 — same range as the speech rate controls.
    @Published var rate: Double = 1.0 {
        didSet {
            let clamped = min(2.0, max(0.5, rate))
            if clamped != rate { rate = clamped }
            player?.rate = Float(rate)
        }
    }
    /// True while this screen's own expanded controls are visible — the
    /// global mini-player then yields (editor pattern).
    @Published var miniPlayerSuppressed = false

    var showMiniPlayer: Bool { playingURL != nil && !miniPlayerSuppressed }

    /// The export's display name — the file name without its extension.
    var nowPlayingTitle: String? {
        playingURL.map { $0.deletingPathExtension().lastPathComponent }
    }

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// Display name for a not-yet-playing file (Storage rows, picker menus).
    nonisolated static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    func toggle(_ url: URL) {
        if playingURL == url {
            if isPaused { resume() } else { pause() }
            return
        }
        play(url)
    }

    private func play(_ url: URL) {
        stop()
        do {
            // Do NOT re-set the audio session category — the engines configure
            // it (.spokenAudio + duckOthers + allowBluetooth) in their init,
            // and clobbering it here with .playback/.default means the NEXT
            // engine speak after previewing an export runs with the degraded
            // session (no ducking, wrong mode) until app restart. AVAudioPlayer
            // plays fine under the existing spoken-audio category.
            let p = try AVAudioPlayer(contentsOf: url)
            p.enableRate = true
            p.rate = Float(rate)
            p.prepareToPlay()
            p.play()
            player = p
            playingURL = url
            isPaused = false
            duration = p.duration
            currentTime = 0
            progress = 0
            startTicker()
        } catch {
            Log.shared.error("WavPlayer: failed to open \(url.lastPathComponent): \(error)")
        }
    }

    func pause() {
        player?.pause()
        isPaused = true
    }

    func resume() {
        player?.play()
        isPaused = false
    }

    func togglePlay() {
        guard player != nil else { return }
        if isPaused { resume() } else { pause() }
    }

    /// Scrub to a 0…1 fraction of the file (the export player's slider).
    func seek(toFraction value: Double) {
        guard let player, player.duration > 0 else { return }
        let target = min(max(0, value), 0.999) * player.duration
        player.currentTime = target
        currentTime = target
        progress = value
    }

    /// VLC-style skip from the playhead.
    func skip(by seconds: Double) {
        guard let player, player.duration > 0 else { return }
        let target = min(max(0, player.currentTime + seconds), player.duration - 0.05)
        player.currentTime = target
        currentTime = target
        progress = target / player.duration
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        isPaused = false
        progress = nil
        currentTime = 0
        duration = 0
        ticker?.invalidate()
        ticker = nil
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
                self.progress = player.duration > 0 ? player.currentTime / player.duration : nil
                if !player.isPlaying && !self.isPaused { self.stop() } // reached end
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}
