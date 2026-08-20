import Foundation
import AVFoundation
import OSLog

/// Restores the shared `AVAudioSession` to a state TTS engines can use.
///
/// STT engines (Apple speech recognition, Whisper) grab the session in
/// `.record` mode and never hand it back. The next TTS speak — especially
/// Supertonic — then fails its output node initialisation with
/// `kAUInitialize` (OSStatus -10851). Centralising the reset here lets
/// both engines' `stop()` paths converge on the same fix.
enum AudioSessionResetter {
    private static let logger = Logger(subsystem: "com.speechnotes.ios", category: "AudioSession")

    static func restoreForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Fallback: a simpler `.playback` category without options.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            logger.error("restoreForPlayback fallback: \(error.localizedDescription)")
        }
    }
}
