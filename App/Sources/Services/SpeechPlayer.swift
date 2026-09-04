import Foundation

/// UI-facing wrapper around the active speech engine. Engines are swappable at
/// runtime from Settings: Apple's system voice, or Kokoro once its model is
/// downloaded (with transparent fallback to system until then).
@MainActor
final class SpeechPlayer: ObservableObject {
    enum EngineKind: String, CaseIterable, Identifiable {
        // Declaration order = picker order, worst quality first (user-set).
        case kitten
        case system
        case kokoroOnnx
        case supertonic

        var id: String { rawValue }

        var label: String {
            switch self {
            case .kitten: return "Kitten — tiny, lowest quality"
            case .system: return "Apple system voice"
            case .kokoroOnnx: return "Kokoro — on-device neural, 28 voices"
            case .supertonic: return "Supertonic — best quality, multilingual"
            }
        }
    }

    @Published private(set) var state: SpeechState = .idle
    /// Speech progress 0…1 (chunk-granular) while speaking; nil otherwise.
    @Published private(set) var progress: Double?
    /// Speed preference. Persistence is debounced: the slider fires dozens of
    /// changes per drag and each one wrote UserDefaults; now one write lands
    /// 0.5 s after the drag settles.
    @Published var rateMultiplier: Double {
        didSet {
            guard rateMultiplier != oldValue else { return }
            ratePersistTask?.cancel()
            ratePersistTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                UserDefaults.standard.set(self.rateMultiplier, forKey: "rateMultiplier")
            }
        }
    }
    private var ratePersistTask: Task<Void, Never>?
    @Published var engineKind: EngineKind {
        didSet {
            UserDefaults.standard.set(engineKind.rawValue, forKey: "engineKind")
            rebuildEngine()
        }
    }
    @Published var voice: String {
        didSet {
            UserDefaults.standard.set(voice, forKey: "voice")
            onnxEngine?.voice = voice
        }
    }
    /// Kitten voices live in a separate namespace from Kokoro voices.
    @Published var kittenVoice: String {
        didSet {
            UserDefaults.standard.set(kittenVoice, forKey: "kittenVoice")
            kittenEngine?.voice = kittenVoice
        }
    }
    /// Supertonic voice style ("M1"…"F5") and language (ISO code).
    @Published var supertonicVoice: String {
        didSet {
            UserDefaults.standard.set(supertonicVoice, forKey: "supertonicVoice")
            supertonicEngine?.voice = supertonicVoice
        }
    }
    @Published var supertonicLang: String {
        didSet {
            UserDefaults.standard.set(supertonicLang, forKey: "supertonicLang")
            supertonicEngine?.lang = supertonicLang
        }
    }
    /// Identifier of the `AVSpeechSynthesisVoice` the system engine should
    /// use (Settings → System voice); nil = Apple's default en-US voice.
    /// Persisted, and forwarded to the engine so a change applies to the
    /// next utterance.
    @Published var systemVoiceIdentifier: String? {
        didSet {
            if let identifier = systemVoiceIdentifier {
                UserDefaults.standard.set(identifier, forKey: "systemVoiceIdentifier")
            } else {
                UserDefaults.standard.removeObject(forKey: "systemVoiceIdentifier")
            }
            systemEngine?.voiceIdentifier = systemVoiceIdentifier
        }
    }

    /// True when Kokoro is selected but its model isn't downloaded yet —
    /// the system engine is used in the meantime.
    private(set) var usingSystemFallback = false

    enum ExportState: Equatable {
        case idle
        case running(Double)
        case failed(String)
    }

    @Published private(set) var exportState: ExportState = .idle
    /// Set when a WAV export succeeds — the editor presents the share sheet
    /// and clears this when it dismisses.
    @Published var shareURL: URL?

    /// Title of the note currently being spoken (drives the mini-player).
    @Published private(set) var nowPlayingTitle: String?
    /// Identity of the note currently being spoken — mini-player taps
    /// navigate to it.
    @Published private(set) var nowPlayingNoteId: UUID?
    /// Codename of the voice an in-picker audition is sampling, if any.
    @Published private(set) var auditioningVoice: String?
    /// Engine/voice to restore when the running audition finishes; nil once
    /// the user makes an explicit selection mid-audition.
    private var preAuditionState: (kind: EngineKind, voice: String, kittenVoice: String, supertonicVoice: String)?

    // MARK: - Playback resume bookmark

    struct PlaybackBookmark: Codable {
        let noteId: UUID
        let charsDone: Int
        let textLength: Int
        let textHash: Int64
        let savedAt: Date
    }

    private static let bookmarkKey = "playbackBookmark"
    /// Set at speak start when a real note is playing; updated per tick.
    private var inFlightBookmark: PlaybackBookmark?
    /// Raw engine progress of the CURRENT speak call (0…1 over the text that
    /// was actually passed to the engine, which on a resume is the suffix).
    private var lastRawProgress: Double = 0
    /// Fraction of the full text already spoken when this speak call is a
    /// resume; published progress is remapped through this.
    private var resumeBaseFraction: Double = 0

    /// Stable (process-independent) hash — String.hashValue is seeded per
    /// launch and would invalidate bookmarks across restarts.
    nonisolated static func stableHash(_ s: String) -> Int64 {
        var h: Int64 = 5381
        for scalar in s.unicodeScalars {
            h = (h &* 33 &+ Int64(scalar.value)) & 0x7FFF_FFFF_FFFF_FFFF
        }
        return h
    }

    /// UTF-16 offset of the last sentence boundary at-or-before charsDone —
    /// resume re-speaks the interrupted sentence from its start.
    nonisolated static func resumeOffset(in text: String, charsDone: Int) -> Int {
        let units = Array(text.utf16)
        guard charsDone > 0, charsDone < units.count else { return -1 }
        let terminators: Set<UTF16.CodeUnit> = [
            0x2E, 0x21, 0x3F,
            0x0A, 0x2026, 0x3002, 0xFF01, 0xFF1F, // … 。 ！ ？
        ]
        var i = min(charsDone, units.count - 1)
        while i > 0 {
            if terminators.contains(units[i]) { return i + 1 }
            i -= 1
        }
        return 0
    }

    /// Loads the stored bookmark if it's for this note, this exact text,
    /// recent (<30 days), and at a meaningful position.
    private func resumePlan(for noteId: UUID, fullText: String) -> (offset: Int, suffix: String)? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey),
              let mark = try? JSONDecoder().decode(PlaybackBookmark.self, from: data)
        else { return nil }
        let length = fullText.utf16.count
        guard mark.noteId == noteId,
              mark.textLength == length,
              mark.textHash == Self.stableHash(fullText),
              Date().timeIntervalSince(mark.savedAt) < 30 * 24 * 3600,
              mark.charsDone >= 40,
              mark.charsDone < length
        else { return nil }
        let offset = Self.resumeOffset(in: fullText, charsDone: mark.charsDone)
        guard offset > 0, offset < length else { return nil }
        let units = Array(fullText.utf16)
        let suffix = String(decoding: Array(units[offset...]), as: UTF16.self)
        guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (offset, suffix)
    }

    /// True when the editor should show "Restart from beginning".
    func hasResumeOption(for noteId: UUID, text: String) -> Bool {
        resumePlan(for: noteId, fullText: text) != nil
    }

    /// Call on background/suspension — wired into SpeechnotesApp's
    /// scenePhase hook.
    func persistPlaybackBookmark() {
        guard let mark = inFlightBookmark else { return }
        if let data = try? JSONEncoder().encode(mark) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    /// Called when the app returns to the foreground. If the process was
    /// suspended mid-speech (iOS sometimes kills the audio engine even with
    /// the `audio` background mode), this restarts playback from the saved
    /// bookmark so the user isn't left in silence on return.
    func resumeIfBookmarkPending() {
        guard state == .idle,
              let mark = inFlightBookmark ?? Self.loadBookmark(),
              let note = notesProvider?(mark.noteId)
        else { return }
        togglePlay(note.text, note: note)
    }

    /// Set by SpeechnotesApp so the player can resolve a bookmark's note id
    /// back to its current text without importing the store.
    var notesProvider: ((UUID) -> Note?)?

    private static func loadBookmark() -> PlaybackBookmark? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey),
              let mark = try? JSONDecoder().decode(PlaybackBookmark.self, from: data)
        else { return nil }
        return mark
    }

    private func clearBookmark() {
        inFlightBookmark = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    /// Stop + speak the full text from the start, clearing any bookmark.
    func restartFromBeginning(_ text: String, note: Note?) {
        clearBookmark()
        stop()
        nowPlayingTitle = note?.title
        nowPlayingNoteId = note?.id
        resumeBaseFraction = 0
        lastRawProgress = 0
        if let note { primeBookmark(noteId: note.id, fullText: text) }
        engine?.speak(text, rateMultiplier: rateMultiplier)
    }

    private func primeBookmark(noteId: UUID, fullText: String) {
        inFlightBookmark = PlaybackBookmark(
            noteId: noteId,
            charsDone: 0,
            textLength: fullText.utf16.count,
            textHash: Self.stableHash(fullText),
            savedAt: Date()
        )
    }

    /// Raw engine progress maps back to absolute chars: on a resume the
    /// engine only ever saw the suffix.
    private func updateBookmarkChars(rawProgress: Double) {
        guard let mark = inFlightBookmark else { return }
        let base = resumeBaseFraction * Double(mark.textLength)
        let suffixLength = max(1, Double(mark.textLength) - base)
        let chars = min(mark.textLength - 1, Int(base + rawProgress * suffixLength))
        inFlightBookmark = PlaybackBookmark(
            noteId: mark.noteId,
            charsDone: chars,
            textLength: mark.textLength,
            textHash: mark.textHash,
            savedAt: Date()
        )
    }

    /// True while an audition sample is sounding.
    var isAuditioning: Bool { auditioningVoice != nil }
    /// The compact player bar is shown while real speech is active (never
    /// for picker auditions).
    var showMiniPlayer: Bool {
        (state == .speaking || state == .paused || state == .generating) && !isAuditioning
    }

    /// Friendly description of the voice the active engine will use.
    var currentVoiceDescription: String {
        switch engineKind {
        case .system:
            return "Apple voice"
        case .kokoroOnnx:
            return usingSystemFallback
                ? "Apple voice (model missing)"
                : VoiceCatalog.subtitle(for: voice, kind: .kokoroOnnx)
        case .kitten:
            return usingSystemFallback
                ? "Apple voice (model missing)"
                : VoiceCatalog.subtitle(for: kittenVoice, kind: .kitten)
        case .supertonic:
            return usingSystemFallback
                ? "Apple voice (model missing)"
                : VoiceCatalog.subtitle(for: supertonicVoice, kind: .supertonic)
        }
    }

    private var engine: (any SpeechEngine)?
    private var onnxEngine: OnnxKokoroEngine?
    private var kittenEngine: KittenEngine?
    private var supertonicEngine: SupertonicEngine?
    private var systemEngine: SystemEngine?

    init() {
        let defaults = UserDefaults.standard
        rateMultiplier = defaults.object(forKey: "rateMultiplier") as? Double ?? 1.0
        // v0.6 and earlier also shipped a Metal Kokoro engine ("kokoro");
        // it was removed in v0.7 — carry that preference over to the ONNX engine.
        let storedEngine = defaults.string(forKey: "engineKind")
        if storedEngine == "kokoro" {
            defaults.set(EngineKind.kokoroOnnx.rawValue, forKey: "engineKind")
            engineKind = .kokoroOnnx
        } else {
            engineKind = EngineKind(rawValue: storedEngine ?? "") ?? .system
        }
        voice = defaults.string(forKey: "voice") ?? "am_eric"
        kittenVoice = defaults.string(forKey: "kittenVoice") ?? KittenEngine.defaultVoice
        supertonicVoice = defaults.string(forKey: "supertonicVoice") ?? "M1"
        supertonicLang = defaults.string(forKey: "supertonicLang") ?? "en"
        systemVoiceIdentifier = defaults.string(forKey: "systemVoiceIdentifier")

        // Engine + NowPlayingCenter wiring moved out of init — some engines
        // set up AVAudioSession and observers at construction, which on iOS
        // 26 / LiveContainer can abort the process before WindowGroup
        // installation. The default engine is "system" so the user gets
        // immediate TTS via wirePlayback() on first body run.
        if engineKind == .system {
            systemEngine = SystemEngine()
            engine = systemEngine
        }

        Log.shared.info("SpeechPlayer initialised (engine=\(engineKind.rawValue), voice=\(voice), kittenVoice=\(kittenVoice), supertonic=\(supertonicVoice)@\(supertonicLang))")
    }

    /// Idempotent post-init wiring. Called from `SpeechnotesApp.rootView`
    /// `.onAppear` on the main actor — exactly once per process. Sets up
    /// NowPlayingCenter + ModelManager hooks and, if no engine was chosen in
    /// init, picks the right one now.
    @MainActor
    func wirePlayback() {
        ModelManager.shared.onReady = { [weak self] in
            self?.rebuildEngine()
        }

        if engine == nil {
            rebuildEngine()
        }
    }

    var activeEngineName: String {
        engine?.name ?? "none"
    }

    private func rebuildEngine() {
        engine?.stop()

        // The Supertonic set is ~399 MB of resident sessions — release it as
        // soon as another engine takes over (single-slot rule, PocketPal
        // lesson). The other engines' sessions are an order of magnitude
        // smaller and stay warm for instant switching.
        if engineKind != .supertonic {
            supertonicEngine = nil
        }

        if engineKind == .supertonic, ModelManager.shared.supertonicIsReady {
            if supertonicEngine == nil {
                let supertonic = SupertonicEngine()
                supertonic.voice = supertonicVoice
                supertonic.lang = supertonicLang
                supertonicEngine = supertonic
            }
            engine = supertonicEngine
            usingSystemFallback = false
            Log.shared.info("SpeechPlayer: engine → Supertonic (\(supertonicVoice), \(supertonicLang))")
        } else if engineKind == .kitten, ModelManager.shared.kittenIsReady {
            if kittenEngine == nil {
                let kitten = KittenEngine()
                kitten.voice = kittenVoice
                kittenEngine = kitten
            }
            engine = kittenEngine
            usingSystemFallback = false
            Log.shared.info("SpeechPlayer: engine → Kitten (\(kittenVoice))")
        } else if engineKind == .kokoroOnnx, ModelManager.shared.isReady {
            if onnxEngine == nil {
                let onnx = OnnxKokoroEngine()
                onnx.voice = voice
                onnxEngine = onnx
            }
            engine = onnxEngine
            usingSystemFallback = false
            Log.shared.info("SpeechPlayer: engine → Kokoro ONNX (\(voice))")
        } else {
            if systemEngine == nil {
                systemEngine = SystemEngine()
            }
            systemEngine?.voiceIdentifier = systemVoiceIdentifier
            engine = systemEngine
            usingSystemFallback = (engineKind == .kokoroOnnx || engineKind == .supertonic)
            if usingSystemFallback {
                Log.shared.info("SpeechPlayer: neural engine selected but model missing — system voice in use")
            }
        }

        engine?.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                self.state = newState
                if newState == .idle {
                    if self.lastRawProgress >= 0.98 {
                        self.clearBookmark()            // finished naturally
                    } else if self.inFlightBookmark != nil {
                        self.persistPlaybackBookmark()  // stopped part-way
                    }
                    self.lastRawProgress = 0
                    self.resumeBaseFraction = 0
                    self.nowPlayingTitle = nil
                    self.nowPlayingNoteId = nil
                    self.finishAuditionIfActive()
                } else {
                    /* np disabled in bisect-d */
                }
            }
        }
        engine?.onProgress = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.lastRawProgress = value
                let mapped = self.resumeBaseFraction
                    + (1 - self.resumeBaseFraction) * value
                self.progress = value > 0 ? min(1.0, mapped) : nil
                self.updateBookmarkChars(rawProgress: value)
                /* np disabled in bisect-d */
            }
        }
    }

    /// Play/pause/stop the note's text. `note` feeds the mini-player's title
    /// and jump-to-note tap; omitting it plays anonymous text.
    func togglePlay(_ text: String, note: Note? = nil) {
        if isAuditioning {
            // A note taking control mid-audition ends the sample first.
            stop()
            return
        }
        switch state {
        case .generating:
            // Tapping during generation cancels it.
            stop()
        case .speaking:
            engine?.pause()
        case .paused:
            engine?.resume()
        case .idle:
            nowPlayingTitle = note?.title
            nowPlayingNoteId = note?.id
            resumeBaseFraction = 0
            lastRawProgress = 0
            if let note {
                primeBookmark(noteId: note.id, fullText: text)
                if let plan = resumePlan(for: note.id, fullText: text) {
                    resumeBaseFraction = Double(plan.offset) / Double(max(1, text.utf16.count))
                    Log.shared.info("SpeechPlayer: resuming note at char \(plan.offset)/\(text.utf16.count)")
                    engine?.speak(plan.suffix, rateMultiplier: rateMultiplier)
                    return
                }
            }
            engine?.speak(text, rateMultiplier: rateMultiplier)
        }
    }

    func stop() {
        engine?.stop()
    }

    // MARK: - Voice auditions

    /// Speaks a short sample with a voice WITHOUT committing the selection —
    /// the picker's audition button. Tapping the sounding audition stops it;
    /// engine/voice are restored when the sample ends. No-op while a note is
    /// playing or the engine's model isn't downloaded.
    func audition(voice codename: String) {
        guard state == .idle, !isExporting else { return }
        if auditioningVoice == codename {
            stop()
            return
        }
        let modelReady: Bool
        switch engineKind {
        case .kitten: modelReady = ModelManager.shared.kittenIsReady
        case .supertonic: modelReady = ModelManager.shared.supertonicIsReady
        default: modelReady = ModelManager.shared.isReady
        }
        guard modelReady else { return }

        if preAuditionState == nil {
            preAuditionState = (engineKind, voice, kittenVoice, supertonicVoice)
        }
        switch engineKind {
        case .kitten: kittenVoice = codename
        case .supertonic: supertonicVoice = codename
        default: voice = codename
        }
        auditioningVoice = codename
        let name = VoiceCatalog.shortName(for: codename, kind: engineKind)
        Log.shared.info("SpeechPlayer: auditioning \(codename)")
        engine?.speak(VoiceCatalog.auditionText(for: name), rateMultiplier: 1.0)
    }

    /// An explicit selection made while an audition is still sounding wins:
    /// drop the queued restore (the sample keeps playing to its end).
    func cancelAuditionRestore() {
        preAuditionState = nil
    }

    /// Idle transition hook — restores whatever the audition changed, unless
    /// the user selected a voice mid-audition.
    private func finishAuditionIfActive() {
        guard auditioningVoice != nil else { return }
        if let saved = preAuditionState {
            preAuditionState = nil
            auditioningVoice = nil
            voice = saved.voice
            kittenVoice = saved.kittenVoice
            supertonicVoice = saved.supertonicVoice
            engineKind = saved.kind
        } else {
            auditioningVoice = nil
        }
    }

    // MARK: - WAV export

    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    func export(_ text: String) {
        guard case .idle = exportState else { return }
        guard usingSystemFallback == false, engineKind != .system else {
            exportState = .failed("Export needs a neural engine — download a Kokoro model in Settings first.")
            return
        }

        stop()
        shareURL = nil
        exportState = .running(0)
        Log.shared.info("SpeechPlayer: exporting note to WAV")

        let progress: (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.isExporting else { return }
                self.exportState = .running(value)
            }
        }
        let finish: (Result<URL, Error>) -> Void = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.shareURL = url
                    self.exportState = .idle
                case .failure(let error):
                    self.exportState = .failed(error.localizedDescription)
                }
            }
        }

        if engineKind == .supertonic, let supertonicEngine {
            supertonicEngine.renderWAV(text: text, onChunkProgress: progress, completion: finish)
        } else if engineKind == .kitten, let kittenEngine {
            kittenEngine.renderWAV(text: text, onChunkProgress: progress, completion: finish)
        } else if let onnxEngine {
            onnxEngine.renderWAV(text: text, onChunkProgress: progress, completion: finish)
        } else {
            exportState = .failed("No neural engine available — download a model in Settings first.")
        }
    }

    func dismissExportError() {
        if case .failed = exportState { exportState = .idle }
    }
}
