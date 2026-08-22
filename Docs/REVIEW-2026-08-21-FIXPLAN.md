# Speechnotes iOS — Review Fix Plan (2026-08-21)

Full-codebase review remediation plan. Written for step-by-step implementation:
**apply ONE fix at a time, in order. Do not refactor anything not listed here.**

Current state at time of writing: local `main` == `origin/main` @ `391815b`,
CI green, version 2.0.0 (25). Post-v1.3 work = the v2.0 STT feature.

## Ground rules for the implementing model

1. One fix per change-set. If a fix has multiple files, do them together, then re-read every edited file top to bottom before moving on.
2. NEVER change: `ModelManager.swift`, the TTS engines (`OnnxKokoroEngine`, `KittenEngine`, `SupertonicEngine`, `SystemEngine`, `Supertonic/Helper.swift`), `SpeechLogic` package sources, `SentenceChunker`, the CI workflow, and the portrait-only orientation keys in `project.yml`. These are stable/shipping and the app depends on their exact behavior.
3. Do not rename any public/internal symbol other than the ones this plan explicitly renames. Other files reference them.
4. There is no local macOS/Xcode on this machine — the compiler of record is GitHub CI (`.github/workflows/build.yml`). After implementing, commit and push to `main` and watch the "Build IPA" run. If it fails, read the archived `archive.log` artifact and fix only what it reports.
5. The deployment target is iOS 18.0, Swift 5 mode. `MainActor.assumeIsolated` is available.
6. Wherever this doc says "replace the whole function", copy the new body exactly — do not merge old and new.

---

## FIX-1 (P0) — Whisper models cannot be downloaded: `downloadRow` is never rendered

**File:** `App/Sources/Views/SttSettingsView.swift`

**Problem:** `downloadRow(_:)` (defined around line 125) is dead code. The Form's
model section only calls `modelRow(model)`, so no Download/Delete UI exists and
the Whisper engine can never get a model through the UI.

**Remedy:** In `body`, inside the "Whisper model" `Section`, render the download
row under each model row:

```swift
ForEach(WhisperModelManager.catalog) { model in
    modelRow(model)
    downloadRow(model)
}
```

**Verification:** Build. Settings → Speech-to-text → every catalog row now shows
a second row: "Download <name>" when not installed, progress + Cancel while
downloading, "Downloaded" + Delete when ready.

**Guards:** Do not change `modelRow` or `downloadRow` bodies. Do not remove the
`.disabled(!isInstalled)` on `modelRow` — that is the fix for the
"tapping a row restarts the download" bug from commit 391815b.

---

## FIX-2 (P0) — Audio import fails: fileImporter URLs are read without security scope

**File:** `App/Sources/Services/AudioImportService.swift`

**Problem:** URLs returned by `.fileImporter` require
`startAccessingSecurityScopedResource()` before reading. The used code path
(`DictationCoordinator.transcribeAudioFile` → `AudioImportService.samples(from:)`)
never takes the scope, so `AVURLAsset` sees no audio track and the user gets
"No audio track in the file." The scope call exists only in the UNUSED instance
method `transcribe(_:language:engine:)`, which nothing calls.

**Remedy:**

1. Wrap the decode in the scope in `samples(from:)`:

```swift
/// Splits the import into two stages so callers can drive a progress bar.
/// Takes the security scope itself: every caller hands us a URL straight
/// from fileImporter / onOpenURL, and AVURLAsset silently sees no tracks
/// without it.
static func samples(from url: URL) async throws -> [Float] {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try await Task.detached(priority: .userInitiated) {
        try Self.decode(url: url)
    }.value
}
```

2. Delete the entire unused `transcribe(_:language:engine:)` instance method
   (the one whose body already did this). Keep `runTranscription` — the
   coordinator calls it.

**Verification:** Build. Import an .m4a from the Files picker on device →
decoding proceeds instead of erroring with "No audio track".

**Guards:** Do not touch `decode(url:)` or `linearResample` — they are correct
and are invoked off the main actor.

---

## FIX-3 (P0) — Engine picker doesn't switch engines

**File:** `App/Sources/Services/DictationCoordinator.swift`

**Problem:** `engineKind` is `@AppStorage` — its setter only writes defaults.
`rebuildEngine()` runs at init / on `whisperModelReady` / and in
`startRecording` only when `engineKind == .apple`. Switching Apple → Whisper in
settings therefore leaves the Apple engine live while the UI says Whisper.

**Remedy:** Replace `startRecording(language:)` with a version that always
reconciles the engine, and clears stale transcript state (the clear is also
required by FIX-4's stale-final guard). Add one stored property next to
`private var engine: STTEngine?`:

```swift
private var lastWhisperModelId: String?
```

Then:

```swift
func startRecording(language: String? = nil) {
    guard state == .idle else { return }
    // Reconcile the engine with the CURRENT selection every session: the
    // Apple engine is cheap to rebuild, the Whisper engine only when the
    // model id actually changed (WhisperKit reload is expensive).
    switch engineKind {
    case .apple:
        engine = AppleSTTEngine()
    case .whisper:
        if !(engine is WhisperCppEngine) || lastWhisperModelId != whisperModels.activeModelId {
            lastWhisperModelId = whisperModels.activeModelId
            engine = WhisperCppEngine(modelId: whisperModels.activeModelId)
        }
    }
    wireEngineCallbacks()
    // Fresh session: drop any stale final/partial so a later save can never
    // commit the previous session's text (see FIX-4).
    lastFinalText = ""
    partialText = ""
    state = .recording
    startTimer()
    engine?.start(language: language, prompt: nil)
}
```

Extract the closure wiring currently at the bottom of `rebuildEngine()` into:

```swift
private func wireEngineCallbacks() {
    engine?.onPartial = { [weak self] text in
        self?.hopToMain { self?.partialText = text }
    }
    engine?.onFinal = { [weak self] text in
        self?.hopToMain {
            self?.partialText = ""
            self?.lastFinalText = text
            self?.state = .idle
            self?.stopTimer()
        }
    }
    engine?.onStateChanged = { [weak self] s in
        self?.hopToMain { self?.state = s }
    }
}

/// Engine callbacks arrive from mixed threads. When already on main (the
/// common case — stop() is UI-driven and synthesizes its final synchronously)
/// run the handler NOW instead of next runloop tick, so callers that stop and
/// immediately consume the result see it (FIX-4 depends on this).
private func hopToMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}
```

`rebuildEngine()` keeps its existing switch but ends with
`wireEngineCallbacks()` instead of the inline closures (the
`if engineKind == .apple { rebuildEngine() }` line inside the old
`startRecording` is deleted — the new code supersedes it).

**Verification:** Build. Settings → Speech-to-text → switch engine → record:
the engine summary and actual behavior now match (Apple shows live partials;
Whisper shows windowed partials after model load).

**Guards:** Do not touch `transcribeAudioFile`, the timer code, or the
notification observer.

---

## FIX-4 (P0) — Dictated transcripts are lost on stop/save (all UIs)

**Root cause (two independent defects):**
(a) `AppleSTTEngine.stop()` cancels the recognition task before `endAudio()`
can finalize, so `onFinal` never fires for the session.
(b) Whisper's final inference is async (`Task.detached`), landing after the
caller already consumed `lastFinalText` (which `stopRecording()` had also just
wiped `partialText`). Same race hits `EditorMicButton.onDisappear`.

**Files:** `AppleSTTEngine.swift`, `DictationCoordinator.swift`,
`DictationTabView.swift`, `EditorMicButton.swift`.

### 4a. AppleSTTEngine — synthesize the final on stop

Add stored properties next to `recognitionRequest`:

```swift
/// Best transcript of the CURRENT recognition segment, updated on every
/// partial/final callback — lets stop() deliver the text SFSpeech would
/// otherwise discard when the task is cancelled.
private var latestTranscript = ""
/// Session text from completed (restarted) segments — see FIX-5.
private var accumulatedSegments = ""
/// True once this session's final has been delivered (stop() must not
/// deliver twice; cancel() must not deliver at all).
private var deliveredFinal = false
private var stillRecording = false
private var stopRequested = false
private var recognizer: SFSpeechRecognizer?
```

In `setupSFRecognizer`, after the availability guard succeeds, keep a reference
and reset per-session state (insert right after `guard let recognizer … else`):

```swift
self.recognizer = recognizer
latestTranscript = ""
accumulatedSegments = ""
deliveredFinal = false
stillRecording = true
stopRequested = false
```

Replace `stop()` and `cancel()` entirely:

```swift
func stop() {
    logger.info("stop")
    stopRequested = true
    stillRecording = false
    if let task = recognitionTask {
        task.cancel()
        recognitionTask = nil
    }
    recognitionRequest?.endAudio()
    recognitionRequest = nil

    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine = nil

    // Restore the playback category so the TTS engine's AVAudioEngine
    // can initialise its output node (kAUInitialize -10851 fix).
    AudioSessionResetter.restoreForPlayback()

    currentState = .idle
    // Graceful stop: SFSpeech discards the in-flight transcript when the
    // task is cancelled — deliver what we recognized so the caller's
    // save/insert path has text.
    if !deliveredFinal {
        deliveredFinal = true
        onFinal?(accumulatedSegments + latestTranscript)
    }
}

func cancel() {
    logger.info("cancel")
    deliveredFinal = true   // discard, don't deliver
    stop()
}
```

In the recognition callback inside `setupSFRecognizer`, replace the whole
`recognitionTask = recognizer.recognitionTask(with: request) { … }` closure with:

```swift
recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
    guard let self else { return }
    if let result {
        self.latestTranscript = result.bestTranscription.formattedString
        if result.isFinal {
            if self.stillRecording && !self.stopRequested {
                // ~1-minute SFSpeech per-task limit: roll over into a new
                // request and keep transcribing (FIX-5).
                self.restartRecognition()
            } else {
                self.finishSession()
            }
        } else {
            self.onPartial?(self.accumulatedSegments + self.latestTranscript)
        }
    }
    if let error {
        self.logger.error("SFSpeechRecognitionTask error: \(error.localizedDescription)")
        if self.stillRecording && !self.stopRequested {
            self.restartRecognition()
        } else {
            self.finishSession()
        }
    }
}
```

Add these two helpers to AppleSTTEngine:

```swift
/// Tears the session down and delivers the combined transcript as the final.
private func finishSession() {
    stillRecording = false
    currentState = .idle
    if !deliveredFinal {
        deliveredFinal = true
        onFinal?(accumulatedSegments + latestTranscript)
    }
    stop()
}

/// Starts a fresh recognition request on the live mic tap. The audio tap
/// reads `recognitionRequest` per buffer, so it keeps feeding the new
/// request; the previous segment's text moves to `accumulatedSegments`.
private func restartRecognition() {
    guard let recognizer, recognizer.isAvailable else {
        finishSession()
        return
    }
    accumulatedSegments = accumulatedSegments.isEmpty
        ? latestTranscript
        : accumulatedSegments + " " + latestTranscript
    latestTranscript = ""

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    recognitionRequest = request
    recognitionTask?.cancel()
    // Callback wiring identical to setupSFRecognizer's — see the block above.
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
        guard let self else { return }
        if let result {
            self.latestTranscript = result.bestTranscription.formattedString
            if result.isFinal {
                if self.stillRecording && !self.stopRequested {
                    self.restartRecognition()
                } else {
                    self.finishSession()
                }
            } else {
                self.onPartial?(self.accumulatedSegments + self.latestTranscript)
            }
        }
        if let error {
            self.logger.error("SFSpeechRecognitionTask error: \(error.localizedDescription)")
            if self.stillRecording && !self.stopRequested {
                self.restartRecognition()
            } else {
                self.finishSession()
            }
        }
    }
}
```

Also delete the `onPartial?("")` line that used to sit at the end of the old
`stop()` — clearing the visible text is now the coordinator's job on final.

### 4b. DictationCoordinator — don't wipe the text, provide a synchronous consume

Replace `stopRecording()` and `consumeFinal()`:

```swift
func stopRecording() {
    engine?.stop()
    state = .idle
    stopTimer()
    // NOTE: partialText is intentionally NOT cleared here. The Apple engine
    // delivers its final synchronously (see stop()); Whisper's final lands
    // a moment later — until then the visible partial IS the transcript, and
    // consumeFinalOrPartial() uses it as the fallback.
}

/// Returns the session transcript: the engine final when it has arrived,
/// otherwise the last visible partial (complete text for Whisper since
/// FIX-6). Clears both. The editor "insert" and tab "Save as note" paths
/// both go through this.
func consumeFinalOrPartial() -> String {
    let final = lastFinalText
    lastFinalText = ""
    let text = final.isEmpty ? partialText : final
    partialText = ""
    return text
}
```

(`lastFinalText` staleness is impossible: FIX-3 clears it in
`startRecording`, and only a final that arrives AFTER a consume can repopulate
it — the next session start clears it again.)

### 4c. DictationTabView — save from final-or-partial

In `saveTranscript()` replace `let text = dictation.consumeFinal()` with:

```swift
let text = dictation.consumeFinalOrPartial()
```

### 4d. EditorMicButton — stop live recording on dismiss, then insert

Replace the sheet's `.onDisappear` closure body with:

```swift
.onDisappear {
    // "Done" can dismiss while still recording — stop first so the mic
    // session never leaks, then take whatever was recognized.
    if dictation.state == .recording || dictation.state == .transcribing {
        dictation.stopRecording()
    }
    let text = dictation.consumeFinalOrPartial()
    if !text.isEmpty { onTranscribed?(text) }
    keyboardRefreshTrigger?()
}
```

**Verification (all three surfaces):** record with Apple engine ~10 s → tap
stop → note saved / text inserted at cursor. Same with Whisper (note appears
instantly from partial; lastFinalText updates silently). Dismiss the sheet
with "Done" mid-recording → text still inserted, mic releases (record a voice
memo in another app right after to confirm the session is free).

**Guards:** Do not touch `requestPermissionsAndStart`,
`requestMicPermission`, `transcribeFile` (beyond FIX-7), or
`AudioSessionResetter`.

---

## FIX-5 (P1) — Apple live dictation dies at ~1 minute

Already implemented as a side effect of FIX-4a: `restartRecognition()`
rolls the request over when SFSpeech finalizes the task at its ~1-minute
limit while `stillRecording` is true. No additional changes.

**Verification:** dictate with the Apple engine for >75 s without stopping —
transcript keeps growing past the first minute.

---

## FIX-6 (P0) — Whisper only remembers the last 30 s of a session

**File:** `App/Sources/Engine/STT/WhisperCppEngine.swift`

**Problem:** the ring buffer caps at 30 s (`maxSamples = 16_000 * 30`) and
`stop()` transcribes only that snapshot. Longer sessions lose everything
before the last 30 s. Also: live inference hardcodes `language: nil`, and the
UI passes BCP-47 codes (`en-US`) that WhisperKit rejects (it wants ISO-639-1
like `en`).

**Remedy — incremental finalization + language support.** Replace the whole
class body between `// MARK: - STTEngine` and the end of `runInference` with
the design below, and add one stored property near `currentModelId`:

```swift
/// Language for the current session (BCP-47 or nil = auto), set in start().
private var currentLanguage: String?
```

And next to `ringBuffer`:

```swift
/// Transcript of evicted (older-than-window) audio, guarded by ringLock.
/// Chained finalization tasks append in segment order (see enqueueFinalization).
private var finalizedText = ""
/// Serializes evicted-segment transcriptions so appended text stays ordered.
private var finalizeChain: Task<Void, Never> = Task {}
```

Replace `start`/`stop`:

```swift
func start(language: String?, prompt: String?) {
    guard currentState == .idle else { return }
    currentLanguage = language
    guard pipe != nil else {
        logger.error("Whisper model not loaded")
        currentState = .idle
        onFinal?("")
        return
    }
    setupAudioEngine()
    currentState = .recording
    scheduleProcessWindow()
}

func stop() {
    workItem?.cancel()
    workItem = nil
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine = nil
    ringLock.lock()
    let snapshot = ringBuffer
    ringBuffer.removeAll(keepingCapacity: true)
    ringLock.unlock()
    AudioSessionResetter.restoreForPlayback()
    currentState = .idle
    if !snapshot.isEmpty { runFinal(samples: snapshot) }
}

func cancel() { stop() }
```

Replace `scheduleProcessWindow` (evict + partial):

```swift
private static let liveWindowSamples = 16_000 * 30   // hard cap kept in memory
private static let liveKeepSamples = 16_000 * 20     // floor after an eviction

private func scheduleProcessWindow() {
    workItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.ringLock.lock()
        if self.ringBuffer.count > Self.liveWindowSamples {
            let evicted = Array(self.ringBuffer.prefix(self.ringBuffer.count - Self.liveKeepSamples))
            self.ringBuffer.removeFirst(evicted.count)
        } else {
            self.evictedThisTick = nil   // see note below — use a local instead
        }
        ...
```

(The sketch above is abbreviated — implement it as follows, no `evictedThisTick`
property:)

```swift
private func scheduleProcessWindow() {
    workItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.ringLock.lock()
        var evicted: [Float] = []
        if self.ringBuffer.count > Self.liveWindowSamples {
            evicted = Array(self.ringBuffer.prefix(self.ringBuffer.count - Self.liveKeepSamples))
            self.ringBuffer.removeFirst(evicted.count)
        }
        let snapshot = self.ringBuffer
        self.ringLock.unlock()
        if !evicted.isEmpty { self.enqueueFinalization(samples: evicted) }
        if !snapshot.isEmpty { self.runInference(samples: snapshot, isFinal: false) }
        self.scheduleProcessWindow()
    }
    workItem = item
    processQueue.asyncAfter(deadline: .now() + 1.5, execute: item)
}
```

Replace `runInference` and add the two new functions:

```swift
/// BCP-47 ("en-US") → ISO-639-1 ("en"); WhisperKit rejects region-qualified
/// codes. nil/auto passes through as nil (language auto-detect).
static func whisperLanguageCode(_ bcp47: String?) -> String? {
    guard let bcp47, !bcp47.isEmpty else { return nil }
    return String(bcp47.prefix(while: { $0 != "-" })).lowercased()
}

private func runInference(samples: [Float], isFinal: Bool) {
    guard let pipe else { return }
    guard !samples.isEmpty else { return }
    if isFinal { currentState = .transcribing }
    Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }
        do {
            let options = DecodingOptions(language: Self.whisperLanguageCode(self.currentLanguage))
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                if !text.isEmpty { self.onPartial?(text) }
                if isFinal {
                    self.currentState = .recording
                }
            }
        } catch {
            self?.logger.error("WhisperKit transcribe failed: \(error.localizedDescription)")
            await MainActor.run {
                if isFinal { self.currentState = .recording }
            }
        }
    }
}

/// Transcribes one evicted segment and appends it to finalizedText. Chained
/// onto finalizeChain so segments append strictly in recorded order even if
/// inference finishes out of order. Emits combined partials so the UI shows
/// the full session text.
private func enqueueFinalization(samples: [Float]) {
    guard let pipe else { return }
    let prior = finalizeChain
    finalizeChain = Task.detached(priority: .userInitiated) { [weak self] in
        await prior.value
        guard let self else { return }
        do {
            let options = DecodingOptions(language: Self.whisperLanguageCode(self.currentLanguage))
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                self.ringLock.lock()
                self.finalizedText += self.finalizedText.isEmpty ? text : " " + text
                let combined = self.finalizedText
                self.ringLock.unlock()
                self.onPartial?(combined)
            }
        } catch {
            self?.logger.error("WhisperKit finalize failed: \(error.localizedDescription)")
        }
    }
}

/// stop() path: wait for pending finalizations, transcribe the live window,
/// emit the WHOLE session as the final, reset.
private func runFinal(samples: [Float]) {
    guard let pipe else { return }
    let prior = finalizeChain
    finalizeChain = Task.detached(priority: .userInitiated) { [weak self] in
        await prior.value
        guard let self else { return }
        do {
            let options = DecodingOptions(language: Self.whisperLanguageCode(self.currentLanguage))
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            self.ringLock.lock()
            let combined = self.finalizedText + (self.finalizedText.isEmpty || text.isEmpty ? "" : " ") + text
            self.finalizedText = ""
            self.ringLock.unlock()
            self.onFinal?(combined)
        } catch {
            self?.logger.error("WhisperKit final failed: \(error.localizedDescription)")
            self?.ringLock.withLock { self?.finalizedText = "" }
            self?.onFinal?("")
        }
    }
}
```

Note: `ringLock.withLock` requires iOS 16+ — fine. If the compiler rejects it,
use explicit lock/unlock.

Also: the live partial shown while recording should include finalizedText.
In `runInference`'s success path, prefix it:

```swift
self.ringLock.lock()
let combinedPartial = self.finalizedText + (self.finalizedText.isEmpty || text.isEmpty ? "" : " ") + text
self.ringLock.unlock()
if !text.isEmpty { self.onPartial?(combinedPartial) }
```

(That replaces the plain `onPartial?(text)` line above.)

**Verification:** Build; record 2+ minutes with Whisper; the visible text
keeps growing and the saved note contains the whole session. Set language to
Spanish in the tab → live recognition follows it.

**Guards:** Keep `setupAudioEngine()` EXACTLY as is (tap, converter, session
category). Keep `transcribeFile` for FIX-7's changes only.

---

## FIX-7 (P1) — File transcription: chunk long audio (1-min Apple limit + memory)

**Files:** `AppleSTTEngine.swift`, `WhisperCppEngine.swift`.

**Problem:** Apple's `SFSpeechURLRecognitionRequest` effectively caps at ~1
minute per request, so long imports fail or truncate; Whisper on a long file
is one huge inference. Chunking inside each `transcribeFile` needs no protocol
change.

### 7a. AppleSTTEngine

Replace `transcribeFile(samples:language:)`:

```swift
func transcribeFile(samples: [Float], language: String?) async throws -> String {
    guard !samples.isEmpty else { return "" }
    try await Self.ensureSpeechAuthorization()
    // SFSpeech caps one request around a minute of audio — transcribe in
    // 50 s chunks and join.
    let chunkSamples = 16_000 * 50
    var parts: [String] = []
    var start = 0
    while start < samples.count {
        let end = min(start + chunkSamples, samples.count)
        let wavURL = try Self.writeTempWAV(samples: Array(samples[start..<end]))
        defer { try? FileManager.default.removeItem(at: wavURL) }
        parts.append(try await transcribeFile(at: wavURL, language: language))
        start = end
    }
    return parts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}
```

(The existing private `transcribeFile(at:language:)` and
`ensureSpeechAuthorization()` stay unchanged.)

### 7b. WhisperCppEngine

Replace `transcribeFile`:

```swift
func transcribeFile(samples: [Float], language: String?) async throws -> String {
    guard let pipe else { throw TranscribeFileError.unsupported }
    guard !samples.isEmpty else { return "" }
    // One inference per 30 s keeps memory and latency bounded on-device.
    let chunkSamples = 16_000 * 30
    var parts: [String] = []
    var start = 0
    while start < samples.count {
        let end = min(start + chunkSamples, samples.count)
        let options = DecodingOptions(language: Self.whisperLanguageCode(language))
        let results = try await pipe.transcribe(audioArray: Array(samples[start..<end]), decodeOptions: options)
        parts.append(results.map(\.text).trimmingCharacters(in: .whitespacesAndNewlines))
        start = end
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
}
```

(`results.map(\.text)` is `[String]`; add this tiny extension at file scope if
the compiler complains about `.trimmingCharacters` on the array —

```swift
private extension Array where Element == String {
    func trimmedJoined() -> String {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

— and use `results.map(\.text).trimmedJoined()` in both places it appears.)

### 7c. Reuse SpeechLogic's WAVWriter in AppleSTTEngine

Add `import SpeechLogic` at the top of `AppleSTTEngine.swift` and replace the
entire `writeTempWAV` body with:

```swift
private static func writeTempWAV(samples: [Float]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("speechnotes-import-\(UUID().uuidString).wav")
    try WAVWriter.write(samples: samples, sampleRate: 16_000, to: url)
    return url
}
```

**Verification:** import a 3-minute voice memo with each engine → full
transcript, no error. `SpeechLogic` logic-tests still pass on CI.

**Guards:** do NOT change `AudioImportService.decode` — decoding whole files
in memory is a documented limitation for now (files up to ~1 h are fine at
~230 MB peak).

---

## FIX-8 (P1) — Language pickers are disconnected from settings

**Files:** `DictationTabView.swift`, `DictationSheetView.swift`.

**Problem:** both views keep a local `@State languageHint` (reset on every
re-render), while Settings binds the coordinator's `sttLanguage` AppStorage.
Three disconnected sources of truth.

**Remedy:** in BOTH views replace

```swift
@State private var languageHint: String = …
```

with

```swift
@AppStorage("sttLanguage") private var languageHint = "auto"
```

(In `DictationSheetView` drop the `Locale.current…` default — "auto" is the
correct default.) The `languageHint == "auto" ? nil : languageHint` call sites
stay as they are.

**Verification:** pick Spanish in Settings → Speech-to-text → the tab and
dictation sheet pickers show Spanish and recording uses it; picking in the tab
updates Settings.

---

## FIX-9 (P1) — Notes-list mic button records blind and loses the transcript

**File:** `App/Sources/Views/MicButtonView.swift`

**Problem:** it toggles `startRecording`/`stopRecording` with no UI, nothing
consumes the result, and stop discards the text.

**Remedy — replace the whole file:**

```swift
import SwiftUI

/// Notes-list toolbar mic button: opens the same dictation sheet the editor
/// uses; the transcript lands as a new note when the sheet dismisses.
struct MicButtonView: View {
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var notes: NotesStore
    @State private var showingSheet = false

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            Image(systemName: dictation.state == .recording ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(dictation.state == .recording ? .red : .primary)
        }
        .accessibilityLabel("Dictate")
        .sheet(isPresented: $showingSheet) {
            DictationSheetView()
                .onDisappear {
                    if dictation.state == .recording || dictation.state == .transcribing {
                        dictation.stopRecording()
                    }
                    let text = dictation.consumeFinalOrPartial()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let note = notes.createNote()
                    var updated = note
                    updated.text = text
                    notes.update(updated)
                    Haptics.success()
                }
        }
    }
}
```

**Verification:** from the notes list, dictate + stop → a new note appears
containing the transcript.

---

## FIX-10 (P1) — Download cancel can't cancel; retry can double-download

**File:** `App/Sources/Services/WhisperModelManager.swift`

**Remedy:** add `private var inFlightDownloads: Set<String> = []` next to
`states`. In `startDownload(id:)`, insert `inFlightDownloads.insert(id)` right
after the `states[id] = .downloading(0)` line, and at the TOP of the function
add:

```swift
guard !inFlightDownloads.contains(id) else { return }   // no concurrent downloads
```

In the Task's `do` block, after `states[id] = .ready`, add
`self.inFlightDownloads.remove(id)`; in the `catch`, add it too. Leave
`cancelDownload` as is (WhisperKit has no public cancel; the completion
handler self-corrects the state when the orphan download finishes).

---

## FIX-11 (P2) — Storage screen shows 0 B for Whisper models

**File:** `App/Sources/Views/StorageSettingsView.swift`

Change:

```swift
usageRow("Whisper models", ExportsStore.directorySize(WhisperModelManager.modelsDirectory))
```

to

```swift
usageRow("Whisper models", ExportsStore.directorySize(WhisperModelManager.whisperKitDirectory))
```

(FIX-13 deletes the now-unused `modelsDirectory`.)

---

## FIX-12 (P2) — About screen shows v1.3.0

**File:** `App/Sources/Views/AboutView.swift`

Replace the hard-coded version `Text` with:

```swift
Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · offline TTS + STT notes")
```

---

## FIX-13 (P2) — Delete dead pre-WhisperKit download machinery

**File:** `App/Sources/Services/WhisperModelManager.swift`

Delete ALL of the following (they are unreachable since downloads moved to
`WhisperKit.download`, which manages its own storage):

- stored properties: `tasks`, `progressObservers`, `resumeData`, `session`
- the entire `init()` body lines that create the URLSession config, the
  `Documents/Whisper` directory, and its backup exclusion (KEEP the
  active-model/marker scanning part of init)
- `static var modelsDirectory` and `static func modelURL(for:)`
- `nonisolated func urlSession(_:downloadTask:didFinishDownloadingTo:)` and
  `nonisolated func urlSession(_:task:didCompleteWithError:)`
- the trailing comment block about `URLSessionTask.progress` (lines ~337-338)

Also apply FIX-10's `inFlightDownloads` while in the file, and change the
disk preflight to use a 1.5× CoreML headroom (catalog sizes are ggml numbers;
CoreML bundles differ):

```swift
let need = Int64(Double(model.sizeBytes) * 1.5) + 100_000_000
```

**Verification:** build; grep the file — no references to `URLSession`
remain; downloads still work (CI build + manual on-device download of tiny).

---

## FIX-14 (P2) — Playback bookmark not persisted on backgrounding

**File:** `App/Sources/SpeechnotesApp.swift`

Change the scenePhase handler to:

```swift
.onChange(of: scenePhase) { phase in
    if phase != .active {
        notes.flushNow()
        player.persistPlaybackBookmark()
    }
}
```

(Existing behavior on normal stop is unchanged — this only covers
suspension/kill mid-speech.)

---

## FIX-15 (P2) — Small cleanups

1. `LogsView.swift`: collapse the two `.toolbar` blocks into one — the
   `embedded` flag keeps its meaning (future embedding) but only one
   `ToolbarItem` with `ShareLink(item: logs.exportText)` remains. If grep
   shows no caller passes `embedded: true`, leave the property in place
   anyway (zero-risk).
2. `NotesListView.swift` lines ~302-315: fix the mangled indentation of the
   "Import from Files…" / "Recently Deleted" menu buttons (spaces, not tabs,
   matching surrounding code). No code changes.
3. `project.yml`: delete the `NSCameraUsageDescription: ''` line (app never
   uses the camera; an empty string is noise).
4. `SttSettingsView.swift`: delete the empty `.onChange(of: dictation.engineKind)`
   modifier (dead code).

---

## DO NOT DO (yet) — deferred, higher-risk refactors

These are real improvements but each can destabilize a working engine; do
them only after v2.0 ships, one at a time, on a branch:

- Extract the ~200-line streaming scaffold shared by OnnxKokoro / Kitten /
  Supertonic engines into a base class (`generateChunk` as the only abstract).
- Merge `SettingsView` + `SpeechSettingsView` into one parameterized view.
- Make `WhisperCppEngine` state strictly main-actor confined.
- `Note` extensions (`wordCount`, `estimatedListenMinutes`) live in
  `Models/VoiceCatalog.swift` — move to `Models/Note.swift`.
- Gate `KittenEngine`'s per-chunk phoneme logging behind a debug flag.
- Implement or soften `ImportVoicesView` (currently a links-only stub).
- Update Whisper catalog `sizeBytes` to real WhisperKit CoreML sizes
  (requires checking argmaxinc/whisperkit-coreml file sizes on Hugging Face).
