import Foundation
import SpeechLogic

/// UI-facing wrapper around the active speech engine. Engines are swappable at
/// runtime from Settings: Apple's system voice, or Kokoro once its model is
/// downloaded (with transparent fallback to system until then).
@MainActor
final class SpeechPlayer: ObservableObject {
    enum EngineKind: String, CaseIterable, Identifiable {
        // Declaration order = picker order, worst quality first (user-set).
        case kokoroSmall
        case system
        case kokoroOnnx
        case supertonic

        var id: String { rawValue }

        var label: String {
            switch self {
            case .kokoroSmall: return "Kokoro — small · fp16 (~163 MB)"
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

    // MARK: - Read-along (live sentence highlight)

    /// The exact text handed to the engine for the current playback (the
    /// note's speech text). ReadAlongView renders THIS string, so highlight
    /// coordinates can never drift — the v0.5 read-along failed partly by
    /// mapping engine ranges onto a differently-transformed editor text.
    @Published private(set) var activeSpeechText: String?
    /// UTF-16 range in `activeSpeechText` of the sentence currently sounding.
    @Published private(set) var readAlongRange: Range<Int>?
    /// Sentence-aligned pieces of activeSpeechText (SentenceChunker rules).
    private var readAlongPieces: [Chunk] = []
    /// UTF-16 offset of the trimmed string the engine received within
    /// activeSpeechText (engines trim; a resume adds the bookmark offset).
    private var engineSpeechOffset: Int = 0

    /// True while a read-along surface makes sense for the current playback.
    var readAlongActive: Bool {
        activeSpeechText != nil
            && (state == .speaking || state == .paused || state == .generating)
    }

    private func beginReadAlong(fullText: String) {
        activeSpeechText = fullText
        readAlongRange = nil
        readAlongPieces = SentenceChunker.chunks(for: fullText, firstMaxChars: .max, batchMaxChars: .max)
    }

    private static func leadingWhitespaceUTF16(_ s: String) -> Int {
        var count = 0
        for ch in s {
            guard ch.isWhitespace else { break }
            count += String(ch).utf16.count
        }
        return count
    }

    private func updateReadAlong(engineCharsDone: Int) {
        guard activeSpeechText != nil, !readAlongPieces.isEmpty else { return }
        updateReadAlongRange(fullChar: engineSpeechOffset + engineCharsDone)
    }

    private func updateReadAlongRange(fullChar: Int) {
        guard let piece = readAlongPieces.last(where: { fullChar >= $0.offset }) else {
            readAlongRange = readAlongPieces.first.map { $0.offset..<$0.endOffset }
            return
        }
        readAlongRange = piece.offset..<piece.endOffset
    }

    private func endReadAlong() {
        activeSpeechText = nil
        readAlongRange = nil
        readAlongPieces = []
    }
    /// Engine/voice to restore when the running audition finishes; nil once
    /// the user makes an explicit selection mid-audition.
    private var preAuditionState: (kind: EngineKind, voice: String, supertonicVoice: String)?

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
    /// resume re-speaks the interrupted sentence from its start. Delegates to
    /// SentenceChunker so the rules match the chunking the engines use
    /// (whitespace-after-`.` requirement, decimal guard, CJK terminators,
    /// all line-break variants) instead of a looser byte scan.
    nonisolated static func resumeOffset(in text: String, charsDone: Int) -> Int {
        guard charsDone > 0 else { return -1 }
        return SentenceChunker.resumeOffset(in: text, charsDone: charsDone)
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

    private func clearBookmark() {
        inFlightBookmark = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    /// Set by SpeechnotesApp so the player can resolve a saved bookmark's
    /// note id back to its current text without importing the store.
    var notesProvider: ((UUID) -> Note?)?

    /// Called when the app returns to the foreground. If iOS suspended the
    /// process mid-speech (possible even with the `audio` background mode
    /// under memory pressure), restart playback from the saved bookmark so
    /// the user isn't left in silence on return.
    ///
    /// The INITIAL activation at cold launch is skipped: if the previous run
    /// crashed mid-speech, a fresh bookmark (< 5 min old) would replay that
    /// speech during launch and loop the crash. Auto-resume only serves
    /// returns from the app switcher / lock screen.
    private var skippedInitialActivation = false
    func resumeIfBookmarkPending() {
        if !skippedInitialActivation {
            skippedInitialActivation = true
            return
        }
        guard state == .idle, auditioningVoice == nil else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey),
              let mark = try? JSONDecoder().decode(PlaybackBookmark.self, from: data)
        else { return }
        // Only auto-resume something recorded very recently — a bookmark left
        // over from days ago is almost certainly stale context, not intent.
        // The 30-day cap in resumePlan() still governs the explicit
        // "Resume / restart" affordance in the editor.
        guard Date().timeIntervalSince(mark.savedAt) < 5 * 60 else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            inFlightBookmark = nil
            return
        }
        guard let note = notesProvider?(mark.noteId) else {
            // Note was deleted — drop the stale bookmark so we stop asking.
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            inFlightBookmark = nil
            return
        }
        Log.shared.info("SpeechPlayer: resuming bookmarked note after suspension")
        togglePlay(note.text, note: note)
    }

    /// Stop + speak the full text from the start, clearing any bookmark.
    func restartFromBeginning(_ text: String, note: Note?) {
        ensureNowPlayingWired()
        clearBookmark()
        stop()
        nowPlayingTitle = note?.title
        nowPlayingNoteId = note?.id
        resumeBaseFraction = 0
        lastRawProgress = 0
        beginReadAlong(fullText: text)
        engineSpeechOffset = Self.leadingWhitespaceUTF16(text)
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
    /// Set by the note editor while IT shows its full PlayerControlsBar for
    /// the same note that is speaking — the global mini-player then yields
    /// so two control bars never stack at the bottom of the screen.
    @Published var miniPlayerSuppressed = false
    /// The compact player bar is shown while real speech is active (never
    /// for picker auditions, and never while the editor's own controls for
    /// the same note are on screen).
    var showMiniPlayer: Bool {
        (state == .speaking || state == .paused || state == .generating)
            && !isAuditioning && !miniPlayerSuppressed
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
        case .kokoroSmall:
            // The small tier shares the fp32 set's 28-voice catalog.
            return usingSystemFallback
                ? "Apple voice (model missing)"
                : VoiceCatalog.subtitle(for: voice, kind: .kokoroOnnx)
        case .supertonic:
            return usingSystemFallback
                ? "Apple voice (model missing)"
                : VoiceCatalog.subtitle(for: supertonicVoice, kind: .supertonic)
        }
    }

    private var engine: (any SpeechEngine)?
    private var onnxEngine: OnnxKokoroEngine?
    private var supertonicEngine: SupertonicEngine?
    private var systemEngine: SystemEngine?

    init() {
        let defaults = UserDefaults.standard
        rateMultiplier = defaults.object(forKey: "rateMultiplier") as? Double ?? 1.0
        // v0.6 and earlier also shipped a Metal Kokoro engine ("kokoro");
        // it was removed in v0.7 — carry that preference over to the ONNX engine.
        // v1.3 shipped a Kitten engine ("kitten"), removed in this round —
        // its slot in the picker is now the small Kokoro tier, so carry that
        // preference over too.
        let storedEngine = defaults.string(forKey: "engineKind")
        if storedEngine == "kokoro" {
            defaults.set(EngineKind.kokoroOnnx.rawValue, forKey: "engineKind")
            engineKind = .kokoroOnnx
        } else if storedEngine == "kitten" {
            defaults.set(EngineKind.kokoroSmall.rawValue, forKey: "engineKind")
            defaults.removeObject(forKey: "kittenVoice")
            defaults.removeObject(forKey: "recentKittenVoices")
            engineKind = .kokoroSmall
        } else {
            engineKind = EngineKind(rawValue: storedEngine ?? "") ?? .system
        }
        voice = defaults.string(forKey: "voice") ?? "am_eric"
        supertonicVoice = defaults.string(forKey: "supertonicVoice") ?? "M1"
        supertonicLang = defaults.string(forKey: "supertonicLang") ?? "en"
        systemVoiceIdentifier = defaults.string(forKey: "systemVoiceIdentifier")
    }

    /// Called once the view hierarchy is live — doing this in `init` risks
    /// the LiveContainer crash the HANDOVER doc bisected: read/writing
    /// StateObjects from an App-level init forces model creation before any
    /// scene exists.
    private var playbackWired = false
    func wirePlaybackOnce() {
        guard !playbackWired else { return }
        playbackWired = true

        rebuildEngine()

        ModelManager.shared.onReady = { [weak self] in
            self?.rebuildEngine()
        }
        Log.shared.info("SpeechPlayer wired (engine=\(engineKind.rawValue), voice=\(voice), supertonic=\(supertonicVoice)@\(supertonicLang))")
    }

    /// Lock screen / Control Center / headset buttons are wired lazily on
    /// the FIRST real playback, never at launch — registering
    /// MPRemoteCommandCenter during app startup is a LiveContainer crash
    /// hazard (the host app owns the remote-command registry).
    private var nowPlayingWired = false
    private func ensureNowPlayingWired() {
        guard !nowPlayingWired else { return }
        nowPlayingWired = true

        NowPlayingCenter.shared.configure()
        NowPlayingCenter.shared.onCommand = { [weak self] command in
            Task { @MainActor in
                guard let self else { return }
                switch command {
                case .play:
                    if self.state == .paused { self.engine?.resume() }
                case .pause:
                    if self.state == .speaking { self.engine?.pause() }
                case .toggle:
                    if self.state == .speaking { self.engine?.pause() }
                    else if self.state == .paused { self.engine?.resume() }
                case .stop:
                    self.stop()
                }
            }
        }
    }

    var activeEngineName: String {
        engine?.name ?? "none"
    }

    /// Which model file the cached OnnxKokoroEngine instance points at —
    /// the fp32 and fp16 tiers share one slot, so a tier switch must
    /// rebuild it rather than reuse the other tier's session.
    private var onnxEngineFileIsBig = true

    private func rebuildOnnxEngine(big: Bool) {
        if onnxEngine == nil || onnxEngineFileIsBig != big {
            let onnx = big
                ? OnnxKokoroEngine(
                    modelFileURL: ModelManager.onnxModelFileURL,
                    modelFilesValid: { ModelManager.onnxFilesAreValid() }
                )
                : OnnxKokoroEngine(
                    modelFileURL: ModelManager.smallModelFileURL,
                    modelFilesValid: { ModelManager.smallFilesAreValid() }
                )
            onnx.voice = voice
            onnxEngine = onnx
            onnxEngineFileIsBig = big
        } else {
            onnxEngine?.voice = voice
        }
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
        } else if engineKind == .kokoroSmall, ModelManager.shared.smallIsReady {
            rebuildOnnxEngine(big: false)
            engine = onnxEngine
            usingSystemFallback = false
            Log.shared.info("SpeechPlayer: engine → Kokoro small fp16 (\(voice))")
        } else if engineKind == .kokoroOnnx, ModelManager.shared.isReady {
            rebuildOnnxEngine(big: true)
            engine = onnxEngine
            usingSystemFallback = false
            Log.shared.info("SpeechPlayer: engine → Kokoro ONNX (\(voice))")
        } else {
            if systemEngine == nil {
                systemEngine = SystemEngine()
            }
            systemEngine?.voiceIdentifier = systemVoiceIdentifier
            engine = systemEngine
            usingSystemFallback = (engineKind == .kokoroOnnx || engineKind == .kokoroSmall || engineKind == .supertonic)
            if usingSystemFallback {
                Log.shared.info("SpeechPlayer: neural engine selected but model missing — system voice in use")
            }
        }

        // Capture the engine instance so a callback arriving from the OLD
        // engine after a rebuildEngine() swap doesn't clobber live state.
        let activeEngine = engine

        activeEngine?.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                guard let self,
                      let activeEngine = activeEngine,
                      activeEngine === self.engine else { return }
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
                    self.endReadAlong()
                    NowPlayingCenter.shared.clear()
                } else {
                    NowPlayingCenter.shared.publish(
                        title: self.nowPlayingTitle,
                        isPlaying: newState == .speaking,
                        progress: self.progress,
                        rate: Float(self.rateMultiplier)
                    )
                }
            }
        }
        activeEngine?.onProgress = { [weak self] value in
            Task { @MainActor in
                guard let self,
                      let activeEngine = activeEngine,
                      activeEngine === self.engine else { return }
                self.lastRawProgress = value
                let mapped = self.resumeBaseFraction
                    + (1 - self.resumeBaseFraction) * value
                self.progress = value > 0 ? min(1.0, mapped) : nil
                self.updateBookmarkChars(rawProgress: value)
                NowPlayingCenter.shared.publish(
                    title: self.nowPlayingTitle,
                    isPlaying: self.state == .speaking,
                    progress: self.progress,
                    rate: Float(self.rateMultiplier)
                )
            }
        }
        // Play-time character position — the read-along highlight's source of
        // truth (never schedule-ahead).
        activeEngine?.onPlayedChars = { [weak self] engineCharsDone in
            Task { @MainActor in
                guard let self,
                      let activeEngine = activeEngine,
                      activeEngine === self.engine else { return }
                self.updateReadAlong(engineCharsDone: engineCharsDone)
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
            ensureNowPlayingWired()
            nowPlayingTitle = note?.title
            nowPlayingNoteId = note?.id
            resumeBaseFraction = 0
            lastRawProgress = 0
            beginReadAlong(fullText: text)
            if let note {
                primeBookmark(noteId: note.id, fullText: text)
                if let plan = resumePlan(for: note.id, fullText: text) {
                    resumeBaseFraction = Double(plan.offset) / Double(max(1, text.utf16.count))
                    engineSpeechOffset = plan.offset + Self.leadingWhitespaceUTF16(plan.suffix)
                    Log.shared.info("SpeechPlayer: resuming note at char \(plan.offset)/\(text.utf16.count)")
                    engine?.speak(plan.suffix, rateMultiplier: rateMultiplier)
                    return
                }
            }
            engineSpeechOffset = Self.leadingWhitespaceUTF16(text)
            engine?.speak(text, rateMultiplier: rateMultiplier)
        }
    }

    func stop() {
        // An explicit stop is a deliberate end — do NOT let the idle callback
        // persist a bookmark (which resumeIfBookmarkPending would replay on
        // the next foreground).
        clearBookmark()
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
        // Audition samples are not read-along content — make sure a stale
        // speech text from a previous note can't be highlighted.
        endReadAlong()

        // Resolve the codename to its engine kind — a Supertonic style code
        // auditioned while Kokoro is active would play through the wrong
        // engine. Kokoro codenames keep the CURRENT Kokoro tier (small or
        // fp32) instead of always jumping to the big model.
        let targetKind: EngineKind
        if ModelManager.supertonicVoices.contains(codename) {
            targetKind = .supertonic
        } else if ModelManager.knownVoices.contains(codename) {
            targetKind = engineKind == .kokoroSmall ? .kokoroSmall : .kokoroOnnx
        } else {
            return
        }

        // The engine must match the voice kind before we ask it to speak the
        // sample — otherwise the codename is silently fed to the wrong engine.
        if engineKind != targetKind {
            engineKind = targetKind
        }

        let modelReady: Bool
        switch targetKind {
        case .kokoroSmall: modelReady = ModelManager.shared.smallIsReady
        case .supertonic: modelReady = ModelManager.shared.supertonicIsReady
        case .kokoroOnnx: modelReady = ModelManager.shared.isReady
        case .system: modelReady = false
        }
        guard modelReady else { return }

        if preAuditionState == nil {
            preAuditionState = (engineKind, voice, supertonicVoice)
        }
        switch targetKind {
        case .supertonic: supertonicVoice = codename
        case .kokoroOnnx, .kokoroSmall: voice = codename
        case .system: break
        }
        auditioningVoice = codename
        let name = VoiceCatalog.shortName(for: codename, kind: targetKind)
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
