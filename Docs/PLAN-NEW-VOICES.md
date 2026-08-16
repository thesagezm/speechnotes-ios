# Plan — New Voices: Kitten + Supertonic Engines (v0.8+)

> Written 2026-08-16. Goal: more voice variety + more languages, fully
> offline, on the proven ONNX-CPU path. Facts below verified against
> Hugging Face on 2026-08-16 (sizes from the HF API). Companion doc:
> `Docs/PLAN-UI.md`.

## Why these two

| | Kokoro (have) | **KittenTTS nano 0.1** | **Supertonic (Supertone)** |
|---|---|---|---|
| Params | 82 M | ~6 M (nano) | ~2.4 M |
| Download | 86 MB q8 + 15 MB voices | **23.8 MB total** | ~262 MB (v1: 4 models) or int8 build |
| Voices | 28 | 8 expressive (4 m + 4 f) | 8–9 (F1–F5, M1–M4) |
| Languages | English | English | **31 languages** |
| License | Apache-2.0 | MIT | Apache-2.0 (Supertone) |
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

## Phase V-1 — KittenTTS nano (start here)

1. **CI spike** (like the old kokoro spike): logic-test that loads the
   quantized model + tokenizer, synthesizes "hello", asserts non-silent
   audio, measures RTF on the macOS runner; artifact `kitten-sample.wav`.
2. **Input-signature research** (the one unknown): confirm tensor names /
   shapes (ids, style/voice vector, speed?) from the onnx-community README +
   KittenML reference code; Kitten phonemization — check whether it reuses
   IPA-style ids like Kokoro (then MisakiSwift may serve) or ships its own
   text normalizer in `tokenizer.json` (then feed text directly).
3. **`KittenEngine`** (~250 lines, clone OnnxKokoroEngine's streaming
   skeleton: chunk → phonemize → tokens → session.run → 24 kHz buffer;
   chunk size ~120 chars given the smaller context).
4. Settings: engine card "Kitten (24 MB) — 8 expressive voices" with
   download progress; voice sheet gains engine sections.

**Acceptance**: airplane-mode note spoken by `expr-voice-2-m`; RTF ≤ 1.0 on
A14; switching Kokoro↔Kitten mid-session never crashes (serialized swap).

## Phase V-2 — Supertonic

1. Pick artifact: start with v1 4-model pipeline (sherpa-onnx-proven,
   documented JSON config `tts.yml`), compare int8 build size before
   shipping the download.
2. **Byte-level tokenizer = no G2P** for non-English text — this is the
   feature: type/paste Spanish/French/etc. and it speaks. Editor language
   is just text; no code changes needed outside the engine.
3. `SupertonicEngine`: 4 chained sessions (text→duration→estimator→vocoder)
   per chunk; voices are small JSON style files — bundle all 8 in the
   engine download (~no size impact).
4. Voice sheet shows language coverage note ("31 languages").

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
