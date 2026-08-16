# Plan — New Voices: Kitten + Supertonic Engines (v0.8+)

> Written 2026-08-16. Goal: more voice variety + more languages, fully
> offline, on the proven ONNX-CPU path. Facts below verified against
> Hugging Face on 2026-08-16 (sizes from the HF API). Companion doc:
> `Docs/PLAN-UI.md`.

## Status 2026-08-16 (late)

- **Kitten: IMPLEMENTED in v0.8.0** (unpushed at time of writing). Full
  contract extracted from the reference implementation
  (KittenML/KittenTTS `onnx_model.py`): inputs `input_ids` (BOS 0 + 175-entry
  symbol-table ids + EOS [10, 0]), `style` float32 [1,256] — each voice is a
  SINGLE row (bank = 8×1×256, 10,294 bytes), `speed` [1]; waveform @ 24 kHz
  with last 5,000 samples trimmed per chunk. `KittenTokenizer` in SpeechLogic
  is GENERATED from the Python source (byte-exact) + unit tests.
  `KittenEngine` mirrors OnnxKokoroEngine streaming. Model: 23,792,492 B
  quantized from onnx-community; voices.npz from KittenML. CI `kitten-spike`
  job validates the ONNX contract (hardcoded espeak-dialect phonemes, no
  MLX on the runner; voice row pre-extracted via python zipfile).
  **Remaining risk:** MisakiSwift phonemes vs espeak dialect differences
  (both IPA-with-stress; a few combining-mark edge cases may tokenize
  differently) — listen to the device output.
- **Supertonic: researched, ready to port.** Official iOS example exists at
  `supertone-inc/supertonic` `ios/ExampleiOSApp` — XcodeGen + the SAME
  `onnxruntime-swift-package-manager` dependency we already ship. The whole
  pipeline is ONE vendored file, `swift/Sources/Helper.swift` (835 lines):
  `loadTextToSpeech(dir, useGpu, env)`, `TextToSpeech.call(text, lang,
  style, nfe, speed:, silenceDuration:) → (wav, duration)`,
  `loadVoiceStyle(paths)`. Assets: `onnx/{tts.json,duration_predictor,
  text_encoder,vector_estimator,vocoder}.onnx` + `voice_styles/*.json`
  (M1–M5, F1–F5). **Supertonic 3** (2026-04-29) added the 31-language
  support with v2-compatible assets (Supertone/supertonic-3). License:
  **openrail** (personal sideload fine; verify the GitHub code-repo license
  before vendoring Helper.swift).

## Why these two

| | Kokoro (have) | **KittenTTS nano 0.1** | **Supertonic (Supertone)** |
|---|---|---|---|
| Params | 82 M | ~6 M (nano) | 66 M |
| Download | 86 MB q8 + 15 MB voices | **23.8 MB total** | ~262 MB (v1: 4 models) or int8 build |
| Voices | 28 | 8 expressive (4 m + 4 f) | 8–9 (F1–F5, M1–M4) |
| Languages | English | English | **31 languages** |
| License | Apache-2.0 | MIT | openrail (Supertone) |
| Texture | Warm, narrative | Bright, expressive | Fast, clean, multilingual |

Kitten is the cheap win (24 MB); Supertonic is the strategic win (any
non-English note becomes speakable — it also removes the G2P problem for
non-English, see risks).

## Verified model sources (2026-08-16)

- Kitten: `onnx-community/kitten-tts-nano-0.1-ONNX`
  — `onnx/model_quantized.onnx` (23.8 MB), `tokenizer.json`, `config.json`,
  `voices/expr-voice-{2..5}-{f,m}.bin` (8 voices).
  (Alt: `KittenTTS-Nano-v0.8-ONNX`, `KittenTTS-Mini-v0.8-ONNX`.)
- Supertonic v1: `Supertone/supertonic` — `onnx/{text_encoder 27.3,
  duration_predictor 1.5, vector_estimator 132.5, vocoder 101.4}.onnx`,
  `unicode_indexer.json`, `voice_styles/F1…M3.json` (8 styles).
- Supertonic 2: `onnx-community/Supertonic-TTS-ONNX` — 3 models + external
  `.onnx_data` (~262 MB total), `tokenizer.json`, `voices/{F,M}*.bin` (9).
- Mobile-proven int8: `csukuangfj2/sherpa-onnx-supertonic-tts-int8-*`
  (sherpa-onnx runs it on phones — our ORT setup should too).
- Reference app: PocketPal AI ships Kokoro/Kitten/Supertonic ONNX CPU —
  memory notes in `Docs/POCKETPAL-LESSONS.md` §2 (Kitten 80–150 MB RSS).

## Architecture (already half-built)

- `SpeechEngine` protocol + `SpeechPlayer` single-slot runtime: engines
  plug in; adopt PocketPal's serialized swap (stop before rebuild — our
  `rebuildEngine` already calls `engine?.stop()` first).
- New `EngineDescriptor` registry (id, name, model set, voice catalog with
  gender/language tags, size) drives Settings UI + downloads.
- Per-engine dirs: `Documents/Engines/<id>/` with a `version.json` sentinel
  (PocketPal two-phase lesson); reuse `ModelManager.download(...)` (resume,
  retry, expected-bytes progress — all battle-tested in v0.6.6).
- Shared ORT session/env per engine; `MLX.GPU.clearCache()` calls in
  MisakiSwift G2P stay (Kokoro only — see risks).

## Phase V-1 — KittenTTS nano — ✅ implemented v0.8.0 (see status above)

Acceptance still open: airplane-mode note spoken by a Kitten voice; RTF on
A14; switching Kokoro↔Kitten mid-session never crashes (serialized swap).

## Phase V-2 — Supertonic (port path now concrete)

1. Vendor `swift/Sources/Helper.swift` from supertone-inc/supertonic into
   `App/Sources/Engine/Supertonic/` (verify repo license first — HF model
   is openrail; personal sideload OK).
2. `SupertonicEngine: SpeechEngine` adapter: per-sentence-chunk
   `textToSpeech.call(chunk, "na", style, nfe)` — language "na" = auto.
   Style from one `voice_styles/*.json`. nfe default ~32 (example's slider);
   speed/silence built into the call.
3. Model set download: 5 files from `Supertone/supertonic` (v1 assets,
   OnnxSlim variants exist) or `supertonic-3` — compare sizes first;
   version-sentinel the directory (v1 vs v3 assets differ).
4. Voice sheet: M1–M5 / F1–F5 with language note ("31 languages, auto-detected
   — non-English notes just work").
5. Start as a third engine alongside Kokoro/Kitten; single-slot memory rule
   applies (PocketPal lesson).

**Acceptance**: a Spanish note speaks intelligibly offline; a long English
note plays through (streaming parity); download ≤ ~270 MB with progress.

## Phase V-3 — Kokoro voice blending (cheap garnish, anytime)

- Style vectors are just `[Float]`: offer "Blend" rows (e.g. 60% Eric +
  40% Heart) computed at load time — infinite voices, zero download.
- UI: two pickers + slider in the voice sheet; persist named blends.

**Acceptance**: a saved blend speaks consistently across launches.

## Risks / open questions

- **Kitten input signature unknown** → that's why V-1 step 1 is a CI spike,
  not a device build. Do not skip it.
- **Two ORT models resident**: keep single-slot (only the active engine's
  session loaded; free the other on switch) — PocketPal's exact lesson.
- **Supertonic memory**: vector_estimator+vocoder ~260 MB RSS likely; A14
  (4 GB, LiveContainer overhead) should hold, but measure RTF + RSS in the
  spike before promising.
- **MisakiSwift/MLX stays** Kokoro-only (English G2P); Kitten/Supertonic
  must not import it accidentally — keep phonemizers engine-local.
- HF download flakiness seen with Kokoro (one -1005 + one TLS error,
  recovered by resume) — reuse the retrying downloader as-is; if HF stays
  flaky from the user's network, mirror model files to a GitHub Release in
  `thesagezm/speechnotes-ios` (GitHub CDN proved solid for 342 MB).

## Suggested order

V-1 Kitten (small, fast, expressive) → V-3 blending (tiny) → V-2 Supertonic
(big, multilingual). Each ends with a device acceptance round.
