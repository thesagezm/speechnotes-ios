# Supertonic port blueprint (the last V1 feature)

> Written 2026-08-16 as the handoff for implementing Supertonic — the final
> feature before tagging v1.0.0. All research below is verified; the port
> itself is mechanical from here.

## What we vendored already

- `App/Sources/Engine/Supertonic/Helper.swift` — 835 lines, copied verbatim
  from `supertone-inc/supertonic@main` (`swift/Sources/Helper.swift`).
  **License: MIT** (repo LICENSE verified) — vendoring is clean. It uses our
  exact ORT SPM package (`import OnnxRuntimeBindings`) + Foundation +
  Accelerate, no other deps, no G2P (multilingual via codepoint indexer).
- `App/Sources/Engine/Supertonic/ExampleONNX.swift.reference` — the CLI
  example showing orchestration (NOT compiled; rename/remove reference).

Helper.swift gives us: `UnicodeProcessor` (unicode_indexer.json → codepoint
token ids; NFKD decomposition, emoji stripping, symbol normalization),
`TextToSpeech` class (4 ORT sessions, `_infer`/`call`/`batch`, returns
`[Float]` wav at `config.ae.sample_rate`), `loadVoiceStyle` (voice style
JSONs → `Style`), `loadTextToSpeech(onnxDir:useGpu:env:)`, `preprocessText`.

## Assets (HF: `Supertone/supertonic-3`, all verified 2026-08-16)

| File | Size | Notes |
|---|---|---|
| onnx/duration_predictor.onnx | 3.70 MB | |
| onnx/text_encoder.onnx | 36.42 MB | |
| onnx/vector_estimator.onnx | **256.53 MB** | the beast |
| onnx/vocoder.onnx | 101.42 MB | |
| onnx/tts.json | ~10 KB | config (ae.sample_rate, ttl) |
| onnx/unicode_indexer.json | 0.28 MB | codepoint → token id |
| voice_styles/{F1..F5,M1..M5}.json | 0.29 MB each | 10 voice styles |

**Total ≈ 399 MB download.** This exceeds the 300 MB figure the user set for
the *Kokoro* upgrade — whether Supertonic ships at ~399 MB (as an optional
third engine) is a user call to make in the next session. Smaller escape
hatch if needed: the older `Supertone/supertonic` (v2) HF repo has smaller
assets — check sizes before proposing.

Languages (31): en ko ja ar bg cs da de el es et fi fr hi hr hu id it lt lv
nl pl pt ro ru sk sl sv tr uk vi na. Voice styles: M1–M5 (male), F1–F5
(female). Default speed 1.05 (recommended 0.9–1.5). Long text: Helper's
`call` handles chunking with `silenceDuration` pauses (0.3 s default).

## Implementation plan (in order)

1. **CI spike first** (clone the kitten-spike job → `supertonic-spike`):
   download the 4 onnx + tts.json + unicode_indexer.json + 2 voice styles,
   run Helper verbatim in a standalone SPM package on the macOS runner,
   assert non-silent ≥1 s audio, upload `supertonic-sample.wav`, log RTF
   and RSS (`ps` before/after). The macOS runner is ARM — a decent A14
   proxy. **Gate the device work on this.**
2. **SupertonicEngine** (`App/Sources/Engine/SupertonicEngine.swift`):
   streaming clone of OnnxKokoroEngine's public shape (SpeechEngine
   protocol: speak/pause/resume/stop, onStateChanged/onProgress/
   onSpokenRange, renderWAV for export). Internals: engineQueue, load 4
   ORT sessions + UnicodeProcessor once, per chunk call
   `textToSpeech.call(chunk, lang, style, totalSteps, speed)` — adapt the
   float array to AVAudioPCMBuffers at `config.ae.sample_rate` (check it —
   likely 24 kHz or 44.1 kHz; read tts.json in the spike and hardcode).
   `totalSteps`/chunking: follow ExampleONNX.swift.reference defaults (8
   steps) unless docs say otherwise. Read-along offsets: chunk-granular
   like the other engines. Speed: map rateMultiplier → `speed:` param
   (default 1.05).
3. **ModelManager**: `supertonicState` + URLs/expectedBytes for the 6 files
   (+ voice styles — download M1–M5/F1–F5 all at once, 2.9 MB total) into
   Documents/Supertonic/. Validation: vector_estimator > 200 MB etc.
   Preflight ~600 MB free. Reuse the retrying downloader as-is.
4. **SpeechPlayer**: add `.supertonic` EngineKind (label "Supertonic
   (multilingual, experimental)"), `supertonicVoice` + `supertonicLang`
   prefs, rebuildEngine branch, audition support, currentVoiceDescription.
5. **UI**: VoiceCatalog descriptors (M1–M5/F1–F5 friendly names + gender),
   VoicePickerSheet `.supertonic` scope, language picker row (default "en",
   full AVAILABLE_LANGS list), Settings model card (~399 MB!), engine
   picker already renders new cases automatically.
6. **Memory guard**: single-slot engine rule stays — only ONE neural
   engine's sessions resident at a time (PocketPal lesson). 256 MB
   vector_estimator + 101 MB vocoder on A14/6GB inside LiveContainer:
   spike must show RSS headroom before device install.

## V1 release checklist (after Supertonic acceptance)

- [ ] supertonic-spike green + sample sounds good
- [ ] device: download, play EN + one other language, export, read-along
- [ ] bump MARKETING_VERSION → 1.0.0, CURRENT_PROJECT_VERSION → 20-ish
- [ ] README refresh (features, engines table, sizes)
- [ ] `git tag v1.0.0` + GitHub Release with the signed-off IPA artifact
- [ ] update SPEECHNOTES-IOS-PLAN.md header → "v1.0.0 SHIPPED"
