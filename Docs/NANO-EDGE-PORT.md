# nano-edge-tts — port blueprint and pinned contract

**nano-edge-tts** is drmhse's 1.75M-parameter harmonic-plus-noise waveform
decoder distilled from Kokoro-82M's own decoder (Apache-2.0), bolted onto
the Kokoro text side the app already runs. This doc is the porting brief in
the role `Docs/PHONON-PORT.md` played for Phonon — but the pinning here was
done by **speechnotes-linux's runtime** (`sn-tts/src/nano_edge.rs`), which
has run these exact graphs in production on Linux. The iOS port is a
faithful fork of that file; the spike (`Tests/NanoEdgeSpike`) re-proves the
contract on the vendored ORT 1.24.2 every CI run.

## Why Nano Edge

- The text side **IS** Kokoro's: same tokenizer, same Misaki-pronounced
  phonemes, same 28 English voice banks — a voice code means the same
  speaker in both engines, and the engines tokenize identically.
- The decoder is 1.75M params vs Kokoro's 53.3M: same 24 kHz output at a
  fraction of the work, ~33× faster on the decoder half.
- The set is ~157 MB vs Kokoro fp32's 341 MB (112.1 MB text side + 30.4 MB
  decoder + kokoro tokenizer + 28 voice banks) — "Kokoro pronunciation,
  compact tier cost", with native speed control (unlike Phonon).
- The published weights are PyTorch; the installed files are the ONNX
  export speechnotes-linux produces (the speechnotes models repo, the
  same repo the Linux catalog pins). Tokenizer + voice banks are kokoro's
  own files fetched from `onnx-community/Kokoro-82M-v1.0-ONNX`.

## Files downloaded (Documents/NanoEdge/)

| File | Bytes | From | Role |
|---|---:|---|---|
| `text-side.onnx` | 112,134,174 | speechnotes models repo | kokoro text encoder + prosody predictor |
| `nano-decoder.onnx` | 30,420,126 | speechnotes models repo | the distilled decoder (external-data blob inlined) |
| `tokenizer.json` | 3,497 | onnx-community Kokoro | per-char phoneme vocab (same file the Kokoro tiers use) |
| `voices/<code>.bin` × 28 | 522,240 each | onnx-community Kokoro | the English banks (af/am/bf/bm; `af.bin` is an aggregate, excluded) |

Size floors in `ModelManager.nanoEdgeFilesAreValid` sit just under the
landed sizes (110 MB / 30 MB / 522,240 B), matching the Linux catalog's
pins. sha256 pins live in `sn-tts/src/manager.rs`.

## Text-side contract (`text-side.onnx`)

Inputs (batch 1):

| Input | Shape | Value |
|---|---|---|
| `input_ids` | int64 [1, N] | the UN-wrapped token stream — the BOS/EOS wrap the reference `KModel.forward` applies lives inside the graph |
| `style` | float32 [1, 256] | the full 256-wide style row (the graph slices the decoder's half itself) |
| `speed` | float32 [1] | the rate multiplier |

Outputs:

| Output | Shape | Value |
|---|---|---|
| `asr` | float32 [1, 512, T] | text-encoder features — T is HALF the f0 frame count |
| `f0` | float32 [1, F] | prosody predictor pitch (80 Hz axis) |
| `n` | float32 [1, F] | prosody predictor noise |
| `s` | float32 [1, 128] | the style slice the decoder takes |

The style row is chosen BY LENGTH on the pre-tokenization phoneme count —
`row = clamp(phonemeChars - 1, 0, rows - 1)`, offset × 256 (upstream
kokoro's `pipeline.py`; unknown-grapheme substitution happens BEFORE the
count so a dropped phoneme can never move the speaker).

## Decoder contract (`nano-decoder.onnx`)

| Input | Shape | Value |
|---|---|---|
| `asr` | float32 [1, 512, T] | as-is from the text side |
| `f0` | float32 [1, F] | as-is |
| `n` | float32 [1, F] | as-is |
| `s` | float32 [1, 128] | the text side's `s` output |

Output `waveform` float32 [1, S] @ 24 kHz. Two sessions instead of one
because the decoder's interpolations size themselves off input shapes: the
export keeps them symbolic, and the handoff between the graphs is where
the runtime meets the frame count.

**Frame cap**: the creak-noise window was precomputed at 16,384 frames on
the F0 axis (204 s of audio — far past anything the 510-token chunk cap
can produce). A text side that predicts past it has nothing to draw the
jitter from; the engine errors the chunk rather than reading the window
off its end.

## Front end (identical to OnnxKokoroEngine, on purpose)

Misaki `EnglishG2P` (British for `b*` voices) → `-`/`'` echo-back chars
replaced with spaces BEFORE counting (style row sees the same length the
vocab lookup does) → per-char vocab lookup, unknown graphemes become
spaces (id 16) — never deletions (Batch B1's lesson: a deleted phoneme
speaks the word wrong with nothing in the log) → token cap 2…510.

## Engine + app wiring

- `App/Sources/Engine/NanoEdgeEngine.swift` — two ORT sessions over
  `StreamingTTSPlaybackCore` (24 kHz, 160-char chunks, kokoro's opener
  sizing; the core owns boundary fades, scheduling, read-along, WAV
  export).
- `ModelManager` — `nanoEdgeState`, download (~157 MB; graphs 0–0.92,
  voice bins 0.92–1.0), `deleteNanoEdgeModels()`, validation.
- `SpeechPlayer.EngineKind.nanoEdge` — separate voice preference
  (`nanoEdgeVoice`, default `af_heart`), release-on-switch + 5-minute idle
  unload (~142 MB resident), audition + WAV export support.
- Voice picker: the `kokoro` descriptor list is REUSED (same 28 codes,
  same friendly names — one voice code is one speaker in both engines);
  the picker scope/recents are per-engine.
- Benchmark: `BenchmarkTier.nanoEdge` (`-BenchmarkTier nano-edge`).

## Spikes and history

- `Tests/NanoEdgeSpike` — CI job `nano-edge-spike` (continue-on-error):
  downloads the set, feeds a fixed IPA stream through the real vocab
  path at TWO lengths through the same sessions (the dynamic-frame-axis
  proof), asserts finite audible audio, writes `sample.wav`.
- Ported from `speechnotes-linux/crates/sn-tts/src/nano_edge.rs` (the
  non-Rust-repo Linux app) + `manager.rs` catalog pins, 2026-11-18.
