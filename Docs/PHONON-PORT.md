# Phonon TTS — port blueprint and pinned contract

Gradium's **Phonon** (31M-param English streaming TTS, Apache-2.0) via the
ONNX conversion `onnx-community/phonon-31m-en-ONNX`. This doc is the
porting brief, the same role `Docs/SUPERTONIC-PORT.md` played for
Supertonic: the contract below was pinned **empirically** by running the
actual fp32 graphs with ORT (Python, ORT 1.24.2 — the exact version the app
vendors) before any Swift was written. Where the hub README and the graphs
disagree (they do — the README documents an older export), **the graphs
win**.

## Why Phonon

- ~31M params, English-only, 24 kHz mono, fully on-device — the smallest
  neural engine in the app (fp32 set ~192 MB vs Kokoro's 341 MB).
- Autoregressive flow transformer over codec latents (Mimi codec); the hub
  validates its fp32 export against the reference Rust runtime
  sample-for-sample (>70 dB SNR).
- License: Apache-2.0 (model, ONNX conversion, voices).

## Files downloaded (Documents/Phonon/)

All from `https://huggingface.co/onnx-community/phonon-31m-en-ONNX/resolve/main/`:

| File | Bytes | Role |
|---|---:|---|
| `onnx/model.onnx` | 225,310 | flow graph (fp32) |
| `onnx/model.onnx_data` | 121,833,472 | flow weights (external data) |
| `onnx/mimi_decoder.onnx` | 33,479 | codec decoder (fp32, STATELESS) |
| `onnx/mimi_decoder.onnx_data` | 43,670,480 | decoder weights |
| `tokenizer.json` | 169,734 | Unigram vocab + normalizer chain |
| `voices/default.bin` | 256,000 | default voice embedding |
| + curated `voices/<id>.bin` | 256,000 each | VoiceCatalog's voices |

The README's `flow_lm.onnx`/`mimi_decoder_q4.onnx` names and its streaming
snippet describe an OLDER export; the current tree uses `model.onnx` +
external data and a stateless decoder. The q4 variants (MatMulNBits) and
fp16/q4f16 are deliberately NOT shipped (v1): the decoder's "q4" file is
actually a different-precision graph (22.5 MB, contradicting the README's
"fp32 copy" note), and fp16 on ORT CPU is the exact class of failure the
Kokoro fp16 spike proved fatal (CI 34008548349). A compact q4 tier is a
follow-up behind the spike proving MatMulNBits on the vendored ORT.

## Flow graph contract (`model.onnx`, one call = 1 prefill + 7 AR frames)

The graph unrolls 8 autoregressive frames per call (frame = 80 ms = 1/12.5 s
= 1920 samples). Frame 0 of each call re-runs the whole prompt; frames 1-7
are single-position steps.

Inputs (batch 1):

| Input | Shape | Value |
|---|---|---|
| `input_ids` | int64 [1, T] | text tokens ONLY (no specials — the graph prepends the voice and BOS-latent itself) |
| `audio_prompt_latents` | float32 [1, 125, 512] | the voice. **The `.bin` is [1, 512, 125] little-endian — transpose to [1, 125, 512]** |
| `attention_mask` | int64 [1, past_kv + P + 7] | all ones; P = 125 + T + 1. Length is load-bearing: each unrolled frame slices it to `past + P + k` (k = 0…7), so it must cover the final frame |
| `position_ids` | int64 [1, past_kv + P + 7] | `arange(past_kv, past_kv + P + 7)` — frame 0 slices `[0 : P]`, frames 1-7 take single positions |
| `noise` | float32 [1, 8, 32] | per-frame Gaussian × √temperature (0.3; 0 = deterministic) |
| `past_key_values.audio_latents` | float32 [1, past, 32] | the FULL latent history, normalized space (feed `present.audio_latents` straight back) |
| `past_key_values.{0..5}.key/value` | float32 [1, 8, past_kv, 64] | 6 layers × KV cache |

Outputs:

| Output | Shape | Meaning |
|---|---|---|
| `audio_latents` | float32 [1, past+8, 32] | **cumulative** latent history, denormalized (× std + mean folded in). Per call, only the LAST 8 rows are new |
| `present.audio_latents` | float32 [1, past+8, 32] | same, normalized — feed back as `past_key_values.audio_latents` |
| `eos_logits` | float32 [1, 8] | end-of-speech logits for the 8 NEW frames |
| `present.{0..5}.key/value` | float32 [1, 8, past+P+7, 64] | KV cache = fed-back cache + re-run prompt (P) + 7 new latent positions |

**KV feedback policy**: keep the latent K/Vs, drop the re-run prompt block.
`present` = [fed-back latents (past_kv) | prompt (P) | 7 new] — the next
call feeds back `[0 : past_kv) ++ [past_kv + P :]`, i.e. everything except
the middle prompt block. This keeps the latent history attended (the
reference loop's semantics) while the prompt is recomputed fresh each call
at offset `past_kv` (RoPE positions stay monotonic; cos/sin cache covers
8192 positions).

**EOS stop rule** (generation_config + preprocessor_config): first frame
whose logit > 4.0 starts a countdown of `frames_after_eos` (1 frame; 3 for
text ≤ 4 words) — stop when it runs out. Frame budget:
`ceil((T/3 + 2) * 12.5)`.

## Mimi decoder contract (`mimi_decoder.onnx` — STATELESS)

| Input | Shape | Value |
|---|---|---|
| `audio_latents` | float32 [1, N, 32] | the denormalized latents of one sentence |
| `num_frames` | int64 [1] | N |

Outputs: `audio_values` float32 [1, 1, ~1920·N] (24 kHz mono),
`audio_lengths` int64 [1].

**Window limit**: the decoder's rotary positions run over the upsampled
sequence (~16× the latent count) against an 8000-position cos/sin cache —
empirically N ≤ ~500 per call (N = 512 fails; ≤ 256 verified clean). The
ceiling that actually bites is MEMORY: the decoder's ConvTranspose
activations cost ~2.7 MB per latent (measured RSS deltas: 50 → +96 MB,
100 → +236 MB, 160 → +431 MB, 208 → +536 MB, 400 → +1084 MB). The engine
decodes in windows of ≤ 160 latents — real chunks (≤ ~150 latents at
`chunkMaxChars` 180) decode in ONE call, so the window is a safety valve
only; a split window has a conv-context boundary artifact. EOS timing is
noise-dependent: two runs of the same 43-token sentence crossed at call
20/26 (Python seed) and rode past the budget (Swift seed) — the engine
runs the hub's frame budget × 1.5 and logs when even that is reached.

## Tokenizer

Unigram, 4000 pieces, byte fallback, Metaspace pre-tokenizer, a 191-step
normalizer chain (quotes/dashes → ASCII, accented letters → ASCII,
subscripts → digits, symbol/emoji runs → space, whitespace collapse, first
letter capitalized, terminal period). Ported as `SpeechLogic.PhononTokenizer`
(+ generated `PhononNormalizerTable.swift`, regenerate with
`Scripts/gen-phonon-normalizer.py`); ids verified 14/14 against the
reference `tokenizers` implementation (fixtures in SpeechLogicTests).

Known gaps inherited from the hub (documented, not fixed app-side): currency
(`€5.50` reads as dollars), emails (the `@` is skipped) and similar symbols
are NOT spelled out — the hub's Rust/Python runtimes do that pre-tokenization,
the ONNX repo does not. Digits, times, percentages and phone numbers read
correctly natively.

## Voices

`voices/*.bin` are raw little-endian float32 `[1, 512, 125]` (256,000 bytes).
102 voices on the hub (`voices.jsonl` metadata); the model ALWAYS speaks
English regardless of the voice's design language. The app ships a curated
catalog (default + 12 en-us + 13 en-gb named voices; ids = the hub
`voice_id`, mapped to friendly names in `VoiceCatalog`). No voice cloning —
these are precomputed embeddings, which is also why the engine needs no
audio encoder.

## Engine design (`App/Sources/Engine/PhononEngine.swift`)

Same shape as `OnnxKokoroEngine`: a `SpeechEngine` that delegates all
pipeline machinery (chunking, pacing, audio graph, WAV export) to
`StreamingTTSPlaybackCore` and contributes model loading + synthesis on the
core's generateQueue. `generateChunk(sentence)` = fresh KV/latent state →
the call loop above → windowed decode → PCM. Config: 24 kHz,
chunkMaxChars ≈ 180 (≈ 50-token chunks — the hub's own per-chunk ceiling),
opener schedule seeded like Kokoro's until the device round tunes it.

CPU-only (no CoreML EP — a 6-layer KV-cache transformer is exactly the
graph class whose EP parity Kokoro proved broken; round-3 ban stands).
Single-slot memory rule: sessions unload on engine switch like Supertonic's.

## Spike

`Tests/PhononSpike` downloads the fp32 set in CI and runs the pinned recipe
on the vendored ORT 1.24.2 (macOS runner): asserts sessions load (the com.microsoft
contrib ops — GroupQueryAttention, RotaryEmbedding, QuickGelu — are the
load-bearing question), EOS crosses 4.0 within budget, PCM is non-silent at
24 kHz, prints RTF/RSS. Informative/non-blocking like the other spikes;
the phone is the real bench.
