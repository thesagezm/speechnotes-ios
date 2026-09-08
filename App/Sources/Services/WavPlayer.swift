import Foundation
import AVFoundation

/// Plays exported WAV files. One file at a time; toggle play/pause; a 2 Hz
/// timer drives the published progress.
@MainActor
final class WavPlayer: ObservableObject {
    @Published private(set) var playingURL: URL?
    @Published private(set) var isPaused = false
    @Published private(set) var progress: Double?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

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
            p.prepareToPlay()
            p.play()
            player = p
            playingURL = url
            isPaused = false
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

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        isPaused = false
        progress = nil
        ticker?.invalidate()
        ticker = nil
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : nil
                if !player.isPlaying && !self.isPaused { self.stop() } // reached end
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}
