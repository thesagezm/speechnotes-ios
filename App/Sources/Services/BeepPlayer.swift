import Foundation
import AVFoundation
import UIKit
import SpeechLogic

/// The one sound the app makes that is not speech: a soft "skip" tone when a
/// sentence could not be synthesized.
///
/// Design constraints, in order:
/// 1. **Gentle.** A failed sentence is already a disappointment; a loud alert
///    would make it an event. The tone is 0.18 s of a single sine at 720 Hz,
///    faded in and out with a raised-cosine envelope, scaled to `Slot.level`
///    — about an eleventh of full scale.
/// 2. **Never in the way.** A failure arrives on the generation queue while
///    audio is playing. The buffer is built once, off the audio path, and the
///    tone is started from this type's own player node attached to its own
///    engine — the speech engines' engine and node are never touched.
/// 3. **Missing is fine.** The tone is best-effort: if the audio stack cannot
///    play it (an engine that will not start, a route that has gone away), the
///    skip still happens and the reason is logged once. Nothing here may
///    throw, block, or leave a node attached on the failure path.
@MainActor
final class BeepPlayer {
    static let shared = BeepPlayer()

    /// Where the tone sits in the mix. Deliberately low: it must read as a
    /// soft "tick", not as a notification.
    enum Slot {
        /// Amplitude of the whole tone, 0…1 (≈ -22 dBFS peak).
        static let level: Float = 0.08
        /// A single constant pitch — the tone never varies with the failure.
        static let frequency: Double = 720
        static let duration: Double = 0.18
        static let sampleRate: Double = 24_000
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?
    /// Guards the short window between `play()` and the completion callback —
    /// two skips in a row must not stop-and-restart the node mid-tone (that
    /// click is louder than the tone).
    private var isSounding = false

    private init() {}

    /// Plays the skip tone. Callable from any thread; it hops to the main
    /// actor and returns immediately. No-op when a tone is already sounding.
    nonisolated static func playSkipTone() {
        Task { @MainActor in
            BeepPlayer.shared.play()
        }
    }

    private func play() {
        guard !isSounding else { return }
        guard let engine = ensureEngine(), let player, let buffer else { return }
        isSounding = true
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in self?.isSounding = false }
        }
        if !player.isPlaying { player.play() }
    }

    /// Builds the engine graph on first use — never at launch: touching
    /// AVAudioSession or creating an engine during app init is the
    /// LiveContainer launch hazard this project has hit twice.
    private func ensureEngine() -> AVAudioEngine? {
        if let engine { return engine }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Slot.sampleRate,
            channels: 1
        ) else { return nil }
        guard let tone = Self.makeToneBuffer(format: format) else { return nil }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // The engine's output is already running (the speech session owns it).
        // Starting it here would be a second start racing the first; if it is
        // NOT running there is no speech to beep under, so silently skip.
        guard engine.isRunning || startQuietly(engine) else { return nil }
        self.engine = engine
        self.player = player
        self.buffer = tone
        return engine
    }

    private func startQuietly(_ engine: AVAudioEngine) -> Bool {
        do {
            try engine.start()
            return true
        } catch {
            Log.shared.info("BeepPlayer: skip tone unavailable (\(error.localizedDescription)) — sentence skipped silently")
            return false
        }
    }

    /// 0.18 s of 720 Hz with a raised-cosine envelope on both edges — the
    /// envelope is what makes it gentle; a bare sine starts and stops with
    /// a click.
    private static func makeToneBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(Slot.duration * Slot.sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        let attackFrames = max(1, Int(0.025 * Slot.sampleRate))
        let total = Int(frames)
        for index in 0..<total {
            let phase = 2 * Double.pi * Slot.frequency * Double(index) / Slot.sampleRate
            let progress = Double(index) / Double(total)
            let releaseStart = 0.55
            let envelope: Double
            if index < attackFrames {
                // Raised cosine: 0 → 1 with zero slope at both ends.
                envelope = 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(attackFrames))
            } else if progress > releaseStart {
                let t = (progress - releaseStart) / (1 - releaseStart)
                envelope = 0.5 + 0.5 * cos(Double.pi * t)
            } else {
                envelope = 1
            }
            channel[index] = Float(sin(phase) * envelope) * Slot.level
        }
        return buffer
    }
}

/// The spoken form of a piece of app text — one place, because the note path,
/// the book path, the audiobook path and the export path must all derive the
/// SAME string or the read-along offsets and the stored bookmark hash stop
/// matching each other.
///
/// Pipeline: markdown → plain text (when the note's "Render Markdown"
/// preference is on) → `SpeechSanitizer.clean`. `plainText` already cleans,
/// but a note spoken as raw text does not, and a chapter from a legacy cache
/// written before the sanitizer existed does not either — so the clean is
/// applied at this single boundary and is idempotent by construction.
enum SpeechText {
    /// Speech text for a note, honouring the `renderMarkdown` preference.
    static func forNote(_ note: Note, renderMarkdown: Bool) -> String {
        let source = renderMarkdown ? MarkdownText.plainText(note.text) : note.text
        return SpeechSanitizer.clean(source)
    }

    /// Speech text for any already-extracted string (book chapters, sidecar
    /// segments, imported documents).
    static func forText(_ text: String) -> String {
        SpeechSanitizer.clean(text)
    }
}