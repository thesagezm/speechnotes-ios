# Speechnotes iOS — Master Plan

> **Resuming in a new session?** You're building "Speechnotes iOS" — an offline
> Speech Note (Linux) clone for iPhone, native Swift/SwiftUI, built from Linux
> via GitHub Actions (no Mac), sideloaded unsigned via LiveContainer.
> Repo: `~/.zcode/workspace/default/speechnotes-ios` (GitHub: `thesagezm/speechnotes-ios`, public).
> **Read this file fully, plus `Docs/SETUP.md`.** Working loop: agent writes
> code → user pushes → CI builds IPA → user installs via LiveContainer → user
> reports / agent reads CI results via the unauthenticated GitHub API
> (runs → jobs → check-run annotations; job logs need the user's login).
> Toolchain facts: XcodeGen project from `project.yml`; exact package pins
> (KokoroSwift 1.0.11 / MLX 0.30.2 / MLXUtilsLibrary 0.0.6); Swift 5 language
> mode; every failure gets diagnosed via the CI "Show failure summary" steps.
> **Current state (2026-08-16):** Phase 3 (Kokoro on device, v0.3.0) committed;
> last commit `27384e5` fixed 5 concurrency errors — awaiting push + green CI +
> on-device acceptance (see checklist item below). Next actions: verify CI, fix
> any new errors, then guide the user through the Phase 3 test script (download
> model → am_eric speaks → airplane mode). React Native / ONNX Runtime were
> discussed and declined: native + MLX stays Plan A, ONNX is Plan B only if MLX
> fails inside LiveContainer (swap touches one file: `KokoroEngine.swift`).

**Goal:** A fully offline, Speech Note (Linux/Flatpak)-style app for iPhone, built from a Linux PC with no Mac, sideloaded via SideStore + LiveContainer (iloader on the PC). **v1 uses Kokoro for text-to-speech.** STT and translation come later using the same engine-plugin architecture.

---

## 1. Scope

### v1.0 — Kokoro TTS (the current mission)
- Notes app: create/edit/delete notes (like Speech Note's notes list).
- Play any note aloud with Kokoro, fully offline (airplane-mode test = acceptance test).
- Voice picker (af_heart, af_bella, am_adam, …), speed slider.
- Export spoken audio as WAV via the iOS Share Sheet.
- Model manager: a couple of voices bundled in the IPA, more downloadable on first launch (mirrors Speech Note's "download engines" UX).

### v2+ — Roadmap (do NOT start until v1 works)
- STT via whisper.cpp (has an official iOS example; tiny/base quantized models).
- Offline translation (hardest part; research spike later — Argos Translate is C++/Python and awkward on iOS; whisper.cpp covers X→English; we'll evaluate options when we get there).
- The architecture keeps a `SpeechEngine` protocol so new engines plug in without rewriting the app.

---

## 2. Facts & constraints (verified 2026-08)

| Fact | Consequence |
|---|---|
| iOS apps can only be *built* with Xcode on macOS | We build on **GitHub Actions** free macOS runners — your Linux PC never compiles anything |
| GitHub Actions is free-unlimited for **public** repos; private repos get 2000 min/mo and **macOS jobs burn minutes at 10×** | Keep the repo public (it's a personal app, code being visible is fine) or budget ~3–4 builds/month |
| LiveContainer: **no app extensions** (widgets, share ext., etc.), one app at a time, dynamic frameworks can be re-signing headaches | Single app target, prefer statically-linked dependencies (SwiftPM static libs), no extensions, verify LiveContainer compatibility in Phase 0 |
| Fully unsigned IPAs inside LiveContainer need JIT (SideStore provides it); SideStore can also sign apps directly with your Apple ID | Our CI produces a clean **unsigned IPA**; your existing SideStore/LiveContainer/iloader flow handles the rest |
| SideStore free Apple ID = 7-day signing expiry | Your existing refresh habit continues; nothing new needed from us |
| [`mlalma/kokoro-ios` (KokoroSwift)](https://github.com/mlalma/kokoro-ios): MIT Swift package, MLX backend, **~3.3× real-time on iPhone 13 Pro**, includes Misaki G2P (text→phonemes) in Swift | **Primary engine choice** — pure Swift, no C++ vendoring, fastest path |
| KokoroSwift requires **iOS 18+** | Need your iPhone model + iOS version; if too old → fallback engine path |
| Fallback path: ONNX Runtime iOS + `kokoro-v1.0.int8.onnx` (~80 MB) + espeak-ng phonemization (what `kokoro-onnx` Python does; also proven natively on iOS by community ports) | Plan B if MLX/LiveContainer misbehave; works on older iOS |
| Licenses: Kokoro model Apache-2.0, KokoroSwift MIT, misaki MIT, espeak-ng **GPLv3** | Fine for personal sideloading; matters only if we ever distribute publicly |
| Model files (80–320 MB) don't belong in git | CI downloads them at build time from Hugging Face / GitHub Releases |

---

## 3. Architecture

```
┌─────────────────────────────────────────────────┐
│ SwiftUI App                                     │
│  NotesList · NoteEditor · VoicePicker · Logs    │
│  ModelManager UI (download voices)              │
├─────────────────────────────────────────────────┤
│ Services                                        │
│  NotesStore (persist notes as JSON/SwiftData)   │
│  Player (AVAudioEngine: queue, pause, resume)   │
│  ModelManager (bundled + downloaded models)     │
│  LogStore (on-device debug logs → share)        │
├─────────────────────────────────────────────────┤
│ SpeechEngine protocol                           │
│   ├─ SystemEngine   (AVSpeechSynthesizer)       │
│   └─ KokoroEngine   (KokoroSwift / MLX)         │
│        fallback: ONNX Runtime + espeak-ng       │
└─────────────────────────────────────────────────┘
```

**Key decisions & why:**
- **Native Swift + SwiftUI, not Flutter/React Native.** Those also need macOS to build (no advantage), and the Kokoro/whisper.cpp libraries are native. Your HTML/CSS intuition maps surprisingly well to SwiftUI (views ≈ tags, modifiers ≈ CSS).
- **XcodeGen.** The Xcode project file is generated from a text `project.yml` on CI, so the whole repo stays text-driven — I can write every file, and you never open Xcode.
- **SystemEngine first.** Apple's built-in TTS gets the UI working end-to-end in Phase 1 before any ML lands.
- **Unsigned IPA.** `xcodebuild … CODE_SIGNING_ALLOWED=NO` → zip `Payload/` → `.ipa` artifact.

### Repo layout (I create all of this)
```
speechnotes-ios/
├── project.yml                  # XcodeGen spec
├── .github/workflows/build.yml  # CI: build + test + package IPA
├── App/                         # SwiftUI views
├── Engine/                      # SpeechEngine protocol, KokoroEngine…
├── Services/                    # NotesStore, Player, ModelManager, LogStore
├── Tests/                       # simulator unit tests (audio sanity etc.)
├── Scripts/                     # CI helpers (model download, IPA packaging)
└── Docs/                        # guides, lessons, this plan
```

---

## 4. Build & install pipeline (the no-Mac trick)

1. I write code → you `git push` (exact commands provided each time).
2. GitHub Actions spins up a macOS runner (Xcode preinstalled).
3. CI: `xcodegen` → `xcodebuild` (build + run unit tests on iPhone simulator) → downloads Kokoro model + voices → packages **unsigned `SpeechnotesIOS.ipa`** → uploads as artifact.
4. You download the artifact, install with **iloader**, run inside **LiveContainer** (or let SideStore sign it directly).
5. You test, send screenshots + exported in-app logs; I fix; loop.

Debugging without Xcode = the in-app **Logs tab** (copy/share) + CI simulator tests.

---

## 5. Phases

### Phase 0 — Pipeline proof ⚠️ de-risk first
Hello-world SwiftUI app ("Speechnotes iOS" icon, one label). CI builds unsigned IPA.
**Acceptance:** the app opens on your phone via LiveContainer. *This proves the entire toolchain before we invest in features.*

### Phase 1 — UI skeleton + system TTS
Notes list + editor, play button wired to `AVSpeechSynthesizer`, persistence.
**Acceptance:** create a note, hear Apple's voice read it, note survives app restart.

### Phase 2 — Engine spike (in CI, no phone needed)
Integrate KokoroSwift; a simulator unit test generates audio from "Hello world", asserts a non-silent buffer, and attaches `sample.wav` to the Actions artifacts so you can listen in a browser. Also confirms model/voice embedding works and measures speed. If MLX fails us → evaluate ONNX Runtime + espeak-ng path here.
**Acceptance:** `sample.wav` artifact sounds like Kokoro.

### Phase 3 — Kokoro on device
Bundle model + 3 voices, voice picker, speed slider, airplane-mode test.
**Acceptance:** your note is spoken by Kokoro fully offline.

### Phase 4 — Real-app polish
Sentence chunking + streaming playback for long texts (generate while playing), pause/resume, WAV export + Share Sheet, dark mode, app icon, Logs tab.
**Acceptance:** a 1000-word note plays through without freezing the UI; you can export and share the WAV.

### Phase 5 — Model manager (the "Speech Note" UX)
Download extra voices/models on demand (progress bar, resumable), store in app Documents, manage/delete.
**Acceptance:** fresh install + Wi-Fi → download af_heart extra pack → airplane mode → it speaks.

### Phase 6+ — Roadmap
STT via whisper.cpp → record button → transcript into note. Then translation research spike. Also: Bluetooth/audio-session correctness, per-language voices (needs espeak path for non-English), maybe background playback.

---

## 6. Division of labor

**Me (ZCode):** 100% of the code, project files, CI, docs, debugging from your logs/screenshots, step-by-step copy-paste guides, just-enough Swift lessons.

**You (~15–30 min per iteration):** run the git commands I give you, watch the Actions run, download the IPA, install via iloader, test on the phone, report back (screenshots + shared logs), make taste decisions (voices, UI).

**Iteration loop:** you request → I code → you push → CI builds → you install/test → feedback → repeat.

---

## 7. Just-enough Swift track (optional but recommended)

Per phase I write a 10-minute lesson tied to what we're building:
1. Views & state (HTML/CSS → SwiftUI mapping)
2. Optionals & structs vs classes (Python → Swift mapping)
3. Closures & async (callbacks/await)
4. Protocols (how engines plug in)
5. Reading Swift error messages

You can contribute small tweaks immediately (labels, colors, layout) — low-risk edits that build real familiarity.

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| iPhone older than iOS 18 | Plan B engine: ONNX Runtime int8 + espeak-ng (iOS ~15+) |
| MLX binaries vs LiveContainer re-signing | Prefer static linking in project.yml; worst case install via SideStore directly (it signs properly) |
| Slow/old device | Quantized weights; measure sec-audio/sec-compute in Phase 2; chunk generation |
| GitHub Actions quota (private repo) | Make repo public, or cache builds locally and build on tag pushes only |
| 80–320 MB model in git | CI downloads from Hugging Face at build time; voices later from our own GitHub Releases |
| Long-iteration debug loop (no Xcode console) | Logs tab from day one; unit tests in CI for everything testable |
| espeak-ng GPL (only if Plan B) | Irrelevant for personal sideload; revisit if ever distributing |

---

## 9. Questions — ANSWERED 2026-08-16

1. **Device:** iPhone 12 Pro Max, 256 GB, iOS 26.5 → ✅ MLX/KokoroSwift path locked (needs iOS 18+). A14 chip; expect roughly 1.5–2.5× real-time (Phase 2 measures it).
2. **GitHub:** account exists (from VS Code/Copilot days); no gh CLI / credentials on the PC yet → `sudo apt install gh && gh auth login` (Path A) or VS Code "Publish to GitHub" (Path B), per `Docs/SETUP.md`.
3. **Install method:** prefer importing the IPA **directly into LiveContainer** (keeps SideStore certificate slots free); iloader/SideStore install kept as fallback. Our IPAs are unsigned on purpose — LiveContainer signs them its way.
4. **Languages:** English-only for v1 ✅ (misaki G2P is English-first anyway).
5. **Voices:** bundle **am_eric** (user's pick) + af_heart + am_adam; keep all other voices downloadable via the Phase 5 model manager.

## 10. Kickoff checklist — progress

- [x] Questions answered (2026-08-16, see above)
- [x] Phase 0 scaffolded, pushed, built on Actions, **installed via LiveContainer and confirmed working on the phone** (2026-08-16 — "said hello to the cloud")
- [x] Phase 1 built & committed (v0.2.0): notes list + editor with autosave (JSON persistence in Documents), `SpeechEngine` protocol + `SystemEngine` (AVSpeechSynthesizer with pause/resume/stop + speed slider), SpeechPlayer wrapper (engine-swappable — Kokoro drops in here), on-device Logs tab with share
- [x] Phase 1 **accepted on device** (2026-08-16: note typed, read aloud, logs normal)
- [x] Phase 2 built & committed: `kokoro-spike` CI job runs KokoroSwift on the macOS runner (MLX does **not** work on iOS simulators — verified from KokoroTestApp docs), downloads model (kokoro-v1_0.safetensors, 327 MB, cached between runs) + voices.npz from the KokoroTestApp repo, generates speech, writes `sample.wav` artifact with a real-time-factor measurement
- Phase 2 debugging log (2026-08-16): fixed Info.plist generation → fixed explicit linking of MLX/MLXUtilsLibrary → pinned exact versions (KokoroSwift 1.0.11 / MLX 0.30.2 / MLXUtilsLibrary 0.0.6; `from:` ranges drifted to MLX 0.31.6 whose CudaBuild plugin blocked CI) → added `-skipPackagePluginValidation` → diagnostics proved **Metal works on runners** ("Apple Paravirtual device"), files valid, **28 voices incl. am_eric** confirmed. Remaining crash: `unable to find bundle named KokoroSwift_KokoroSwift` — xcodebuild's unhosted macOS test runner breaks SPM resource bundles → **spike moved to a standalone SPM package** (`Tests/KokoroSpike/Package.swift`) run via `swift test`; spike job no longer needs XcodeGen. CI now also extracts a failure summary into step output + GitHub annotations (readable via public API).
- [ ] Phase 2 acceptance: `kokoro-sample` artifact contains audible Kokoro speech; check RTF and the voice list in `kokoro-spike-log` — **demoted to non-blocking garnish** after 6 environment-only failures (all Xcode/SPM plumbing, Kokoro inference never ran); `continue-on-error: true` set. The iPhone is now the test bench. Latest finding: under `swift test` the spike loads config + all 28 voices, then fails with `MLX error: Failed to load the default metallib` — the test runner doesn't place MLX's Metal shader bundle where MLX looks for it; apps embed it correctly, so the phone path is unaffected. Possible future fix: copy `mlx-swift_Cmlx.bundle` into the xctest Resources before `swift test --skip-build`.
- [x] Phase 3 built & committed (v0.3.0): app links KokoroSwift/MLX/MLXUtilsLibrary (same exact pins); `KokoroEngine` (SpeechEngine impl: background MLX generation, AVAudioEngine + time-pitch playback so speed changes don't shift pitch, cancelable generation); `ModelManager` (~342 MB one-time download to Documents/Kokoro with progress/retry/delete, .part-file atomic renames); `SettingsView` (engine picker with system fallback, 28-voice picker, model manager UI, am_eric default); SpeechPlayer supports runtime engine switching; editor gained a speaker-icon settings button + generating state
- [ ] Phase 3 on-device acceptance: install → Settings → engine Kokoro → download model on Wi-Fi → note spoken by am_eric → **airplane mode still speaks** → Logs clean
- [ ] Phase 3 begins (bundle model + voices into the IPA, KokoroEngine in the app, voice picker; am_eric preferred)

---

## Glossary

- **IPA** — the iPhone app installer file (like an .apk/.deb)
- **Sideloading** — installing apps outside the App Store (SideStore/iloader here)
- **CI / GitHub Actions** — cloud machines that run our build recipe on every push
- **XcodeGen** — generates the Xcode project from a text file, so no Mac is needed to author it
- **SPM** — Swift Package Manager, how we pull libraries (like pip/npm for Swift)
- **G2P / phonemization** — converting "hello" → phonemes `hˈəloʊ`, the model's actual input
- **MLX** — Apple's on-device ML framework (Metal-accelerated); KokoroSwift's backend
- **ONNX Runtime** — portable engine for running .onnx models; our Plan B backend
- **JIT** — Just-In-Time execution; SideStore's trick that lets LiveContainer run unsigned code
