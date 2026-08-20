# PLAN V2.0 — Offline Speech-to-Text (whisper.cpp)

> **WHO YOU ARE:** Next agent on this repo. Repo at
> `~/.zcode/workspace/default/speechnotes-ios` (GitHub:
> `thesagezm/speechnotes-ios`, public). `gh` CLI authenticated. Build loop:
> edit → `git add -A && git commit -m "..." && git push` → watch CI
> (`./Scripts/watch_ci.sh <sha>`). `gh run view --log-failed` for failures.
>
> **WHAT THIS RELEASE IS:** V1.3 shipped recycle bin, resume playback,
> storage tab, settings tabs. V2 adds **offline speech-to-text**:
> microphone → transcribed text → inserted into the note editor.
> Ships as **v2.0.0, build 25**. Keep zero `project.yml` keys beyond a
> `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` bump until the user has
> device-tested.

---

## 1. Why whisper.cpp (not whisper.rn / FluidAudio / Apple Speech)

Researched Amical (amicalhq/amical, MIT, Whisper.cpp via native Node addon)
and n0an/VivaDicta (Swift, WhisperKit + Parakeet + FluidAudio + Apple
Foundation Models). The conclusions for this app:

| Engine | iOS-friendly? | License | Verdict |
|---|---|---|---|
| **whisper.cpp via Swift C bridge** | ✅ mature, statically linkable, used by Amical's native module | MIT | **Pick this.** Same shape as our Kokoro ONNX integration. |
| whisper.rn (React Native) | ❌ needs RN runtime | MIT | Rejected. |
| WhisperKit (Argmax) | ✅ pure Swift, ANE | MIT | Excellent but CoreML-only — bigger model bundles, harder to swap. Keep as optional Phase 2 fallback. |
| Apple `Speech.framework` / `SpeechAnalyzer` (iOS 26+) | ✅ zero model | System | Use as **instant first-pass** + as a language-id hint; ship offline quality as the upgrade path. |
| FluidAudio | ✅ CoreML Parakeet | MIT | Park for Phase 2 if Apple STT disappoints. |
| Vosk | ❌ Java + C++ + glue; mobile support is rough | Apache-2.0 | Rejected. |

User explicitly asked about whisper — confirmed. whisper.cpp is the
primary path; Apple's `SpeechAnalyzer` is the fast always-on fallback for
short utterances (one-shot commands) when no STT model is downloaded yet.

## 2. User-facing UX (informed by Amical + VivaDicta)

- **Notes tab gains a microphone button** next to the plus button in the
  navigation bar. Tap → record sheet slides up. Tap again to stop. While
  recording: live waveform, live partial text, elapsed timer, "Insert"
  button (enabled when there's text).
- **Long-press the mic button** → "New note from speech" — record into a
  fresh note in one motion.
- **Inside the editor**, a small mic button in the title area (like iOS
  Notes dictation). Tap → append transcribed text at the cursor. Long
  press → replace selection.
- **Languages** in Settings → Speech: picker (English + 99). When set to
  "Auto", the engine detects per-clip.
- **Models** in Settings → Storage: list of downloaded Whisper models
  (tiny, base, small, large-v3-turbo) with size, accuracy/speed stars
  (Amical-style), delete button. Default: `tiny` for instant use,
  recommended upgrade: `small` or `large-v3-turbo`.
- **Engine picker** in Speech Settings: "Apple (built-in, fast, online
  permission, English-fluent)" / "Whisper tiny (offline, 78 MB)" / etc.
  Default = Apple when no model downloaded.
- **Background:** recording stops on app background (Apple-mandated for
  Voice over IP-style use without entitlement). Tapping the mic button in
  the editor re-foregrounds the app and resumes dictation.

## 3. Architecture

```
┌────────────────────────────────────────────────────────────┐
│ SwiftUI views                                              │
│  DictationSheet, EditorMicButton, SttModelPicker           │
├────────────────────────────────────────────────────────────┤
│ DictationCoordinator (@MainActor ObservableObject)          │
│  - AVAudioEngine capture, ring buffer, VAD                  │
│  - routes audio to active STT engine                       │
│  - publishes: state, partialText, elapsed, levelMeter      │
├────────────────────────────────────────────────────────────┤
│ STTEngine protocol                                         │
│   ├─ AppleSTTEngine      (SpeechAnalyzer / SFSpeechRecogn.)│
│   └─ WhisperCppEngine    (whisper.cpp via C bridge)        │
├────────────────────────────────────────────────────────────┤
│ WhisperModelManager (parallel to ModelManager for TTS)     │
│  - downloaded ggml-tiny.bin / base.bin / small.bin /       │
│    large-v3-turbo.bin from ggerganov/whisper.cpp on HF     │
│  - progress, resume, delete, disk preflight                │
└────────────────────────────────────────────────────────────┘
```

Hard rule from v1.3: **never restructure `NoteEditorView`**. New mic
button added as a tiny `toolbar` item only.

## 4. Files to create / modify

### New files (one step per file, type-checker budget):

1. `App/Sources/Engine/STT/STTEngine.swift` — protocol
   `{func transcribe(_ audio: [Float], language: String?, prompt: String?) async throws -> String; var name: String { get }}`
   + `enum STTState { idle, recording, transcribing }`
2. `App/Sources/Engine/STT/AppleSTTEngine.swift` — `SFSpeechRecognizer`
   wrapper (iOS 13+) on iOS < 26, with an `#available(iOS 26, *)` branch
   upgrading to `SpeechAnalyzer` + `SpeechTranscriber` for the new
   module-based API (live partials, on-device, multilingual). Falls back
   to server only when the user revokes on-device permission.
3. `App/Sources/Engine/STT/WhisperCppEngine.swift` — actor wrapping a
   static `whisper_context` loaded from the selected `.bin` file.
   Public API: `transcribe(samples:[Float], language:String?) async throws -> String`.
   Streams partials via `whisper_full_with_state` + `greedy` strategy.
4. `App/Sources/Engine/STT/WhisperBridge/` — vendored C/ObjC bridge:
   `whisper.h` (single-include from upstream whisper.cpp), `WhisperBridge.h`,
   `WhisperBridge.m`. Sources added to `App/Sources` in `project.yml`
   (see §6). Vendor choice: **whisper.cpp v1.7.6** single-file build
   (`whisper.cpp/examples/whisper.objc` plus `whisper.h`) compiled into
   the app target — static linkage, no SPM pin needed. (Alternative:
   `argmaxinc/WhisperKit` if the C build explodes — see §11.)
5. `App/Sources/Services/DictationCoordinator.swift` — `@MainActor`
   `ObservableObject`. Owns AVAudioEngine, ring buffer (5 s windows),
   Silero-VAD-style energy VAD (no extra model needed — short-window RMS
   + hangover; matches Amical's choice of Silero for an upgrade path
   later). Publishes `state`, `partialText`, `elapsed`, `levelMeter`.
6. `App/Sources/Services/WhisperModelManager.swift` — `@MainActor`
   mirror of `ModelManager` for TTS: download progress, resume,
   preflight, delete, list `installedModels()`. Models live in
   `Documents/Whisper/`. Hosting: `ggerganov/whisper.cpp` on HF
   (`ggml-tiny.bin`, `ggml-tiny.en.bin`, `ggml-base.bin`, `ggml-base.en.bin`,
   `ggml-small.bin`, `ggml-small.en.bin`, `ggml-medium.bin`,
   `ggml-medium.en.bin`, `ggml-large-v3.bin`, `ggml-large-v3-turbo.bin`).
   Default ship: none (download-on-demand). Curated defaults list
   (Amical-style): tiny → base → small → large-v3-turbo, plus `.en`
   variants.
7. `App/Sources/Views/DictationSheet.swift` — modal sheet with mic
   button, waveform, partial text, language picker, insert button.
8. `App/Sources/Views/SttSettingsView.swift` — engine picker, language
   picker (Auto + per-engine), model picker with size / speed /
   accuracy labels.
9. `App/Sources/Views/EditorMicButton.swift` — small reusable
   microphone button (long-press = new-note mode, tap = insert at cursor).

### Modify:
- `App/Sources/SpeechnotesApp.swift` — instantiate
  `DictationCoordinator` + `WhisperModelManager` as `@StateObject`,
  inject via `.environmentObject(...)`.
- `App/Sources/Views/NotesListView.swift` — add mic button to the
  toolbar (long-press → new note from speech).
- `App/Sources/Views/NoteEditorView.swift` — only **additive**: one
  `toolbar` item (mic) using `EditorMicButton`. Hard rule §0: never
  restructure the view body.
- `App/Sources/Views/SpeechSettingsView.swift` — add STT section:
  "Speech-to-text engine", language picker, jump to "STT models" detail.
- `App/Sources/Views/SettingsTabView.swift` — add "Speech-to-text"
  row (and "STT models" sub-row).
- `App/Sources/Views/StorageView.swift` — add a "Whisper models"
  usage row alongside the existing TTS models.
- `App/Resources/Info.plist` (via `project.yml`) — add
  `NSSpeechRecognitionUsageDescription` and
  `NSMicrophoneUsageDescription`. **This is one of the rare project.yml
  edits allowed in this release.**
- `project.yml` — bump version to 2.0.0 / build 25; add the
  `NSMicrophoneUsageDescription`/`NSSpeechRecognitionUsageDescription`
  keys; **add `App/Sources/Engine/STT/WhisperBridge/` as an explicit
  sources entry** if XcodeGen doesn't auto-include `App/Sources`
  recursively (it does, but keep an explicit path to make CI happy).

## 5. Whisper.cpp integration in detail

Use the **single-file C build** pattern from whisper.cpp upstream:
`whisper.h` + the ObjC wrapper. Build flags in `project.yml`:
```
GCC_PREPROCESSOR_DEFINITIONS:
  - WHISPER_BUILD_STATIC
  - GGML_USE_ACCELERATE=1
OTHER_LDFLAGS:
  -lc++
```
Disable Metal in whisper build (`GGML_NO_METAL=1`) — Apple Speech
engine + ANE WhisperKit cover the fast path; CPU+Accelerate is more
than enough for tiny/base and matches the `whisper.cpp` runner behaviour
that Amical uses.

Threading: `whisper_full` runs on a `Task.detached(priority: .userInitiated)`
so the AVAudioEngine callback never blocks. AVAudioEngine delivers
`AVAudioPCMBuffer` chunks of 1024 frames; we resample to 16 kHz
mono Float32 and append to a ring buffer that the whisper actor drains
every ~1.5 s.

Streaming partials: whisper.cpp emits per-segment text via the
`print_progress_callback` / `new_segment_callback`. We collect segments
into `partialText` and re-emit through the coordinator every 200 ms
(debounced — avoid view thrash).

## 6. CI changes

`.github/workflows/build.yml`:
- New job `whisper-spike` (informational, non-blocking, mirrors the
  Kitten/Supertonic spikes). Compile `whisper.cpp` with the same
  flags, run on the bundled tiny model, dump a 5 s WAV transcript to
  the run log. Validates the C bridge builds and links inside the
  unsigned IPA before we ever install on a phone.
- `build-ipa` step already does `otool -L` verification + Frameworks/
  strip — whisper.cpp links statically, so no new dynamic framework
  appears; verify stays green.
- Bump `macos-latest` image to one with Xcode 16+ (SpeechAnalyzer on
  iOS 26 simulator needs it).

## 7. Hard rules (carried from v1.3 + new)

1. Never restructure `NoteEditorView`. **Additive only.**
2. Never touch `project.yml` except: version bump, the two
   permission strings, and the explicit `WhisperBridge/` source path.
3. New screens in new files — type-checker budget per view stayed
   under 700 lines in v1.3 and that's the ceiling.
4. No new SPM pins if the C/ObjC build works. WhisperKit is a
   fallback only (see §11).
5. Models stay out of git. CI downloads `ggml-tiny.bin` (78 MB) and
   uses it for the spike. Production downloads happen on-device via
   `WhisperModelManager`.

## 8. Phased rollout

**Phase 0 (no engine code):** add `NSMicrophoneUsageDescription` +
`NSSpeechRecognitionUsageDescription`, ship a no-op mic button that
shows "Coming soon". CI green, device-tested.

**Phase 1 (Apple path):** `AppleSTTEngine` via `SpeechAnalyzer` on
iOS 26 with `SFSpeechRecognizer` fallback. DictationCoordinator
captures → engine → coordinator publishes partials → editor inserts.
No model download required. This is the "works out of the box" UX.

**Phase 2 (Whisper path):** vendored whisper.cpp bridge +
`WhisperCppEngine`. Model manager downloads `ggml-tiny.bin` (78 MB)
as the default. Quality uplift for noisy speech, accents, proper
punctuation, 100 languages. WhisperKit can be a drop-in replacement
later if C++ integration bites.

**Phase 3 (polish):** long-press "new note from speech", language
picker (Auto + manual), per-engine model picker with Amical-style
size/speed/accuracy stars, "delete models" in Storage settings.

**Phase 4 (background):** explore Push-To-Talk via
`AVAudioSession.Category.playAndRecord` + a notification action —
parked until user asks.

## 9. Device test checklist (per phase)

Phase 1:
1. Mic permission prompt appears.
2. Dictation sheet shows live waveform.
3. Partial text appears within ~1 s of speech start.
4. Insert button writes the final text into the editor.
5. Mic icon in editor toolbar inserts at cursor.
6. Airplane mode works for Whisper; Apple path requires network for
   some languages but English works on-device.

Phase 2:
1. Download `ggml-tiny.bin` in Settings → STT models.
2. Switch engine to Whisper.
3. Same checklist as Phase 1.
4. Confirm transcription differs from Apple's (better with accents).
5. Background-app then return: recording resumes / stops per policy.

## 10. Out of scope (parking lot)

- Real-time meeting transcription (Amical "Planned"). Parked.
- Cloud STT providers. Parked (offline-first).
- Voice commands / MCP integration. Parked (Amical "Planned").
- On-device LLM post-processing (summarisation, formatting). Parked
  unless user asks — would need llama.cpp and a second model manager.

## 11. Risk register + fallbacks

| Risk | Mitigation |
|---|---|
| whisper.cpp C build doesn't link in CI | Drop in `argmaxinc/WhisperKit` (MIT, pure Swift, CoreML/ANE). Phase 2 retargeted to WhisperKit; engine protocol absorbs the swap. |
| iOS 26 `SpeechAnalyzer` API churn | Gate with `#available(iOS 26, *)`; SFSpeechRecognizer fallback covers iOS 18 deployment target. |
| LiveContainer JIT friction with new dylibs | whisper.cpp + our ObjC bridge are static; only system frameworks added; CI `otool -L` verify continues to gate. |
| App Store-style sandbox microphone prompt | LiveContainer / SideStore handle it; we still ship the `NS*UsageDescription` strings. |
| Model bandwidth | 78 MB tiny first; don't ship large-v3 unless user asks. |
| RAM peak with large model on A14 | Default to tiny; expose size warning on large-v3 / medium download. |
