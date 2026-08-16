# Lessons from PocketPal AI's TTS stack

> Sources studied (2026-08-16): [`a-ghorbani/pocketpal-ai`](https://github.com/a-ghorbani/pocketpal-ai)
> (main) — app-side TTS service in `src/services/tts/`, store in `src/store/TTSStore.ts`,
> setup UI in `src/components/TTSSetupSheet/`; and their native inference package
> [`a-ghorbani/react-native-speech`](https://github.com/a-ghorbani/react-native-speech)
> v2.5.1 (main) — engines in `src/engines/`, Obj-C++ audio player in `ios/RNSpeech.mm`,
> design docs in `docs/ARCHITECTURE.md`. Their stack: React Native + ONNX Runtime
> (CPU-only) + native AVAudioEngine player. Ours: native SwiftUI + KokoroSwift/MLX.
> Where their lesson applies to us regardless of stack, it's marked **adopt**;
> stack-specific notes are marked **context**.

## 1. Our architecture is validated — and they show what to add

Their engine interface (`src/services/tts/types.ts`) is nearly our `SpeechEngine`:

| Their `Engine` | Ours | Verdict |
|---|---|---|
| `isInstalled()` — files on disk? | `ModelManager` state | **Adopt**: make install-state an explicit engine query, separate from load-state |
| `loadInto()` / implicit release | engine switching in `SpeechPlayer` | **Adopt**: explicit `release()` to free memory |
| `play(text, voice)` | `speak()` | same |
| `playStreaming()` → `StreamingHandle` | — (our Phase 4) | **Adopt wholesale** (see §3) |
| `stop()` safe-when-idle | ours | same |

Voices are **pure data** (`Voice {id, name, engine, language, gender}`) in per-engine
catalog files — exactly our voice-picker model, plus `gender` for UI grouping.

## 2. Single-slot runtime with serialized swaps (`runtime.ts`)

Only **one neural engine is ever loaded in native memory**; a `TTSRuntime` class owns
the truth of which one is active, and every acquire/stop/release is serialized through
a promise-mutex. Their bug note is a gift to us: per-engine "initialized" flags *lie*
after another engine silently swaps the native one out. Also: a fire-and-forget
`stop()` can cancel an utterance that was ordered later but reached native first —
stop must be serialized with swaps. **Adopt**: our `SpeechPlayer` engine-switching
should follow this exact single-slot + mutex shape in Phase 4.

Memory reality check (their numbers, ONNX fp32): Kokoro 150–250 MB RSS during
synthesis, Kitten 80–150 MB; they gate the whole TTS feature at 4 GiB device RAM and
recommend `release()` between usages on small devices. Our MLX fp32 model is heavier
— measure ours on device and log it (§7).

## 3. Streaming playback design (steal for Phase 4)

- Sentence-boundary chunking: regex `[.!?]+\s+` (+ CJK `。！？`), `maxChunkSize`
  ≈ 400 chars; chunks carry **absolute char offsets** so progress UI maps to the note.
- First chunk = first sentence (fast start), then batches of ~300 chars — their
  `STREAM_TARGET_CHARS = 300` balances prosody vs second-chunk latency.
- `StreamingHandle {appendText, finalize, cancel}` must be **idempotent** — after
  finalize/cancel, later calls are no-ops. Queue appends that arrive before the
  engine is acquired; flush them on acquire.
- Generation pipeline: synthesize chunk k+1 while chunk k plays. Their native
  `scheduleBuffer` completion handler resolves **when playback finishes, not when it
  starts** — that's what makes sequential `await`-driven chunk playback correct
  (`ios/RNSpeech.mm`, comment: "This allows sequential chunk playback to work
  correctly"). All audio ops go through one serial dispatch queue.
- Don't chunk finer than ~100 ms of audio — per-chunk overhead dominates (their
  note about JSI marshaling; for us the analog is MLX op-dispatch + buffer copies).

## 4. Audio session recipe (`ios/RNSpeech.mm`)

Copy this for Phase 4/6:

- Best-effort default at init: category `.playback`, mode `.spokenAudio` (mode is
  what makes interruption notifications fire reliably).
- Ducking: `.playback` + `.duckOthers`, `setActive:YES` on start; on finish
  deactivate with `.notifyOthersOnDeactivation`.
- Ringer switch policy, three modes: `respect` → `.ambient` (silenced by switch),
  `ignore` → `.playback` + `.interruptSpokenAudioAndMixWithOthers`, `obey` (default).
- Subscribe to `AVAudioSessionInterruptionNotification`: began → stop + update UI;
  ended + `shouldResume` → resume.
- Their per-chunk scheduling uses `AVAudioPlayerNodeBufferInterrupts` (new chunk
  kills pending) — fine for their await-sequential design; for true gaplessness we
  can schedule ahead without the interrupts flag.

## 5. Model management (steal for Phase 5)

- **Two-phase download**: core files (model + tokenizer + dict) are all-or-nothing —
  any failure cleans the whole engine dir; per-voice files are best-effort, partial
  success accepted, voices manifest written last.
- **Per-voice files, not one blob**: Kokoro voices download as individual
  `<voice>.bin` files (small) instead of a monolithic `voices.npz`. Investigate
  splitting ours so "add af_bella" is a 0.5 MB fetch, not a re-download. (KokoroTestApp
  ships `voices.npz`; check whether KokoroSwift can load per-voice bins.)
- **Version sentinel**: write `model-version.json` as the *last* step of download;
  `isInstalled()` requires it to match the expected generation. Interrupted downloads
  never read as installed; version bumps force a clean re-download. Our
  existence-checks in `ModelManager` should gain this.
- **Disk-space preflight**: check free space ≥ estimated size × 1.2 before starting.
- **Backup exclusion**: create model dirs with `NSURLIsExcludedFromBackupKey: true`.
- **Legacy reclaim**: `reclaimLegacySpace()` deletes obsolete files (their FP16
  → FP32 migration) *before* the disk gate so reclaimed space counts.

## 6. CPU vs GPU (context, Plan B validation)

They force `executionProviders: ['cpu']` on all neural engines — deliberately skipping
the iOS default CoreML — "for consistent battery/thermal behavior and easier QA."
Their whole production TTS runs CPU-only fp32 ONNX. Two implications: (a) if our
MLX/Metal path ever shows thermal or battery problems on the A14, the ONNX-CPU Plan B
is proven production-grade by a 8k-star app; (b) watch A14 thermals during our
airplane-mode acceptance test — a hot phone after one note is a signal.

## 7. Observability & testing discipline

- Cold-start timing is logged (`engine_init_ms=...`) — add that to our LogStore on
  first Kokoro load, plus peak memory during first generation (iOS:
  `os_proc_available_memory()` before/after).
- They keep **e2e memory baselines in-repo** (`e2e/baselines/memory/iphone-…-tts.json`)
  and scripts that analyze the produced audio (`analyze-tts-audio.ts`) — regression
  gates for "did TTS get slower/hungrier" and "is the output actually audible".
  Our equivalent: assert non-silent audio in the (currently broken) CI spike + log
  RTF on device.
- Sentence chunker is pure logic with exhaustive unit tests — cheapest high-value
  tests to write first in Phase 4.
- Their native dict parser treats downloaded data as untrusted input (bounds checks,
  fuzz target). Any binary we download (voices, future models) deserves the same
  paranoia in `ModelManager` validation.

## 8. Nice UX touches worth stealing

- Voice preview button in the picker with a fixed sample line: "Oh, hello there!
  I've been waiting for you to test me. I sound pretty good!"
- Engine picker shows logos + per-engine install state; voice grid with avatars and
  gender grouping.
- `stripMarkdown()` before synthesis (their chat context; ours matters if notes ever
  hold markdown/emoji soup).
