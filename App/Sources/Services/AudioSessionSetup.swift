import AVFoundation

/// The app's ONE audio-session owner — category, activation, and re-assertion.
///
/// ## Why this exists
///
/// Three engines used to configure the session each with their own copy of
/// the same call, and the logs showed `OSStatus -50` on the first play of
/// every cold session (`audio session setup failed`) — the category was
/// being set while another engine's session was still mid-flight, and the
/// OS rejects a category change it considers invalid for the current route.
///
/// -50 is `paramErr`: the category/mode/options combination is not valid for
/// the route that is active at that moment. The retry ladder below is not a
/// guess — it drops the one option most likely to be rejected on a given
/// route (`.allowBluetoothA2DP` is route-dependent) and finally falls back
/// to a bare `.playback` category, which every route accepts. Speech quality
/// is unaffected; what matters is that playback starts at all.
///
/// The session is configured lazily, on the first real playback, and never
/// at launch — configuring it before the app is attachable is the
/// cold-start `OSStatus -50` spam this project fixed once before (R10) and
/// must not reintroduce.
///
/// ## Activation, and why it is the background-persistence fix
///
/// Apple's three-step recipe for background audio is: enable the background
/// mode, **configure AND activate** the session, start playing
/// (https://developer.apple.com/documentation/watchkit/playing-background-audio).
/// Step 2's *activation* half was missing from every TTS path — the only
/// `setActive(true)` in the app was `AudioBookPlayer`'s post-interruption
/// re-activation. `AVSpeechSynthesizer` and `AVAudioEngine` do NOT activate
/// the session for you; `AVPlayer` does, which is exactly why M4B playback
/// persisted in the background while all three TTS engines died within
/// seconds of backgrounding. Every engine now calls `activate()` beside its
/// first `setCategory`, and every interruption-`.ended` calls it again.
///
/// ## Why both sources share one category
///
/// `.tts` and `.audiobook` deliberately resolve to the SAME category shape.
/// The background-persistence audit looked for a per-source difference and
/// found none that mattered: both want a non-mixable `.playback` session so
/// the system elects this app as the Now Playing owner (a *mixable* session
/// is never elected — Readest device-verified this on iOS 18.7/26.2 with
/// `mediaremoted` forensics). The source tag survives for logging and for
/// the one rule below: a category is never re-applied while something is
/// rendering, because every `setCategory` is itself an interruption source.
///
/// ## The `duckOthers` removal
///
/// The ladder used to carry `.duckOthers` permanently. Two reasons it is
/// gone: Apple's own doc says *"Set this option on a temporary basis only.
/// Don't use it to duck the audio of other apps for more than a few
/// seconds"*, and it *"implicitly sets the mixWithOthers option"* — which
/// costs us the lock-screen card. A spoken-audio reader that pauses the
/// user's music is the music-app behaviour the user explicitly asked for;
/// if ducking is ever wanted back it belongs on a timer scoped to the
/// utterance, not to the session.
enum AudioSessionSetup {

    /// Which playback stack is asking. Both want the same category; the tag
    /// is for logging and for the re-apply rule documented on
    /// `configureIfNeeded(source:prefix:)`.
    enum Source: String {
        case tts
        case audiobook

        var label: String { rawValue }
    }

    private static var configured = false
    private static var configuredBy: Source?

    /// Applies the category for playback. Safe to call repeatedly; only the
    /// first call does work. Never throws — a failure is logged and the
    /// fallback ladder is walked.
    @discardableResult
    static func configureIfNeeded(
        source: Source,
        prefix: String = "AudioSession"
    ) -> Bool {
        if configured {
            if let by = configuredBy, by != source {
                Log.shared.info("\(prefix): session already configured for \(by.label) — leaving it alone (re-applying a category mid-session is its own interruption)")
            }
            return true
        }
        configured = true
        configuredBy = source

        // Non-mixable on purpose: no `.mixWithOthers`, no `.duckOthers`.
        // Both would make the session mixable, and a mixable session is
        // never elected the Now Playing app — the lock-screen card simply
        // does not appear.
        if apply(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowBluetoothA2DP], prefix: prefix) {
            return true
        }
        // Some routes reject the A2DP option outright.
        if apply(.playback, mode: .spokenAudio, options: [.allowBluetooth], prefix: prefix) {
            return true
        }
        // Last resort: the plainest category that any route accepts.
        if apply(.playback, mode: .default, options: [], prefix: prefix) {
            Log.shared.info("\(prefix): fell back to the plain playback category — speech still works, without Bluetooth")
        }
        return false
    }

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

    /// Activates the session. **This is the call every TTS path was
    /// missing**, and it is why background TTS died within seconds:
    /// configuring a category does not make the session active, and neither
    /// `AVSpeechSynthesizer` nor `AVAudioEngine` activates one for you.
    ///
    /// Call it beside the first `setCategory` and again after any event that
    /// tore the session down (interruption ended). Never call
    /// `setActive(false)` — an app that holds an active session with nothing
    /// rendering is exactly the state `UIBackgroundModes: audio` does not
    /// cover, and App Store guideline 2.5.4 is about audible content.
    @discardableResult
    static func activate(prefix: String = "AudioSession") -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            // Not fatal: playback still starts, it just does not survive
            // backgrounding. Logged so a device log distinguishes "did not
            // activate" from "activated and was still suspended".
            Log.shared.error("\(prefix): setActive(true) failed: \(error)")
            return false
        }
    }

    /// Configure + activate in one call — the shape every engine's play path
    /// wants on its first (and every subsequent) playback.
    @discardableResult
    static func configureAndActivate(
        source: Source,
        prefix: String = "AudioSession"
    ) -> Bool {
        let ok = configureIfNeeded(source: source, prefix: prefix)
        let active = activate(prefix: prefix)
        if ok && !active {
            Log.shared.error("\(prefix): category applied but session NOT active — background playback will not persist")
        }
        return ok && active
    }

    /// Re-arm after `mediaServicesWereReset`: the media server died, so the
    /// applied category is void with it. The next `configureIfNeeded`
    /// re-applies from scratch instead of trusting a stale flag. Callers that
    /// want to keep playing must follow this with `activate()` — the reset
    /// leaves the session inactive, and in the background that means the
    /// process is suspended seconds later.
    static func invalidateConfiguration() {
        configured = false
        configuredBy = nil
    }

    /// The full reset path: re-apply the category AND activate, in the one
    /// order that matters. Used by the media-services-reset handlers on both
    /// playback stacks.
    @discardableResult
    static func reassert(
        source: Source,
        prefix: String = "AudioSession"
    ) -> Bool {
        invalidateConfiguration()
        return configureAndActivate(source: source, prefix: prefix)
    }
}
