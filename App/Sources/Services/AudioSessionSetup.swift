import AVFoundation

/// The app's ONE audio-session configuration.
///
/// Why this exists: three engines used to configure the session each with
/// their own copy of the same call, and the logs showed `OSStatus -50` on
/// the first play of every cold session (`audio session setup failed`) —
/// the category was being set while another engine's session was still
/// mid-flight, and the OS rejects a category change it considers invalid for
/// the current route.
///
/// -50 is `paramErr`: the category/mode/options combination is not valid for
/// the route that is active at that moment. The retry ladder below is not a
/// guess — it drops the one option most likely to be rejected on a given
/// route (`.duckOthers` and `.allowBluetoothA2DP` are both route-dependent)
/// and finally falls back to a bare `.playback` category, which every route
/// accepts. Speech quality is unaffected; what matters is that playback
/// starts at all.
///
/// The session is configured lazily, on the first real playback, and never
/// at launch — configuring it before the app is attachable is the
/// cold-start `OSStatus -50` spam this project fixed once before (R10) and
/// must not reintroduce.
enum AudioSessionSetup {

    /// Applies the category for speech playback. Safe to call repeatedly;
    /// only the first call does work. Never throws — a failure is logged and
    /// the fallback ladder is walked.
    static func configureIfNeeded(prefix: String = "AudioSession") {
        guard !configured else { return }
        configured = true

        // Preferred: spoken-audio mode with ducking, which is what the
        // engines want when a notification arrives mid-sentence.
        if apply(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP], prefix: prefix) {
            return
        }
        // Some routes reject the ducking option (or A2DP) outright.
        if apply(.playback, mode: .spokenAudio, options: [.allowBluetooth], prefix: prefix) {
            return
        }
        // Last resort: the plainest category that any route accepts.
        if apply(.playback, mode: .default, options: [], prefix: prefix) {
            Log.shared.info("\(prefix): fell back to the plain playback category — speech still works, without ducking")
        }
    }

    private static var configured = false

    @discardableResult
    private static func apply(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
        prefix: String
    ) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(category, mode: mode, options: options)
            return true
        } catch {
            Log.shared.error("\(prefix): setCategory(\(category.rawValue), \(mode.rawValue)) failed: \(error)")
            return false
        }
    }

    /// Test seam: lets a unit test force the next `configureIfNeeded` to do
    /// real work.
    static func resetForTesting() {
        configured = false
    }
}
