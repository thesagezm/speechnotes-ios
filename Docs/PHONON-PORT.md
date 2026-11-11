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

## Flow graph contract (`model.onnx`, one prefill call + empty-prompt continuations)

The graph unrolls 8 autoregressive frames per call (frame = 80 ms = 1/12.5 s
= 1920 samples). **Call 0 (prefill)** runs the whole prompt against an empty
cache; **calls 1+ feed an EMPTY prompt** (`input_ids [1,0]`,
`audio_prompt_latents [1,0,512]`) and carry only the input slot + 7 frame
rows. The prefill's K/V are fed back whole and FROZEN — see "KV feedback
policy" and "The prompt-requery defect" below for why the prompt must never
be re-run.

Inputs (batch 1):

| Input | Shape | Value |
|---|---|---|
| `input_ids` | int64 [1, T] (prefill) / [1, 0] (continuation) | text tokens ONLY (no specials — the graph prepends the voice and BOS-latent itself). ORT accepts the zero-size tensors; empty Swift arrays must skip `withUnsafeBufferPointer` (nil baseAddress) |
| `audio_prompt_latents` | float32 [1, 125, 512] (prefill) / [1, 0, 512] (continuation) | the voice. **The `.bin` is [1, 512, 125] little-endian — transpose to [1, 125, 512]** |
| `attention_mask` | int64 [1, kv_rows + new_rows] | all ones; prefill: kv_rows=0, new_rows = P + 7 (P = 125 + T + 1); continuation: new_rows = 8 |
| `position_ids` | int64 [1, new_rows] | prefill: `concat(arange(0, P-1), arange(P-1, P+7))`; continuation: `arange(kv_rows, kv_rows + 8)` (see the positions paragraph below) |
| `noise` | float32 [1, 8, 32] | per-frame Gaussian × √temperature (0.3; 0 = deterministic) |
| `past_key_values.audio_latents` | float32 [1, past, 32] | the FULL latent history, normalized space (feed `present.audio_latents` straight back) |
| `past_key_values.{0..5}.key/value` | float32 [1, 8, kv_rows, 64] | 6 layers × KV cache |

Outputs:

| Output | Shape | Meaning |
|---|---|---|
| `audio_latents` | float32 [1, past+8, 32] | **cumulative** latent history, denormalized (× std + mean folded in). Per call, only the LAST 8 rows are new |
| `present.audio_latents` | float32 [1, past+8, 32] | same, normalized — feed back as `past_key_values.audio_latents` |
| `eos_logits` | float32 [1, 8] | end-of-speech logits for the 8 NEW frames |
| `present.{0..5}.key/value` | float32 [1, 8, kv_rows + new_rows, 64] | KV cache = fed-back cache + this call's new rows (prompt block on prefill, 8 latent rows otherwise) |

**KV feedback policy**: feed the WHOLE `present.*` back as the next
`past_key_values.*` — the model card's own driver convention ("feed every
output back under its `past` name on the next call"). The prefill call
computes the voice+text K/V against an EMPTY cache (exactly the reference
prefill, RoPE baked at `0..P-2`), and from then on those rows are never
recomputed: they sit in the fed-back cache bitwise unchanged for the rest
of the chunk. The ORTValues can pass straight through — no copy, and the
whole class of head-major striding bugs (below) disappears with the copy.
Two counters: `kv_rows` (P + 7 after prefill, +8 per continuation call)
drives attention_mask/position_ids; the latent history (+8 every call)
drives the frame slice.

**Positions (reference-exact — xn-ptts)**: `position_ids` values may be
NON-CONTIGUOUS — the graph slices `[0 : P]` for the prompt block and
`[P + k]` for frames 1-7, and nothing requires contiguous values.

- **Prefill** (one call, empty cache): the voice+text rows sit at their
  true absolute positions `0 .. P-2`, the input slot (the prompt block's
  last row, which generates the call's first latent) at `P - 1`, the 7
  frames at `P .. P + 6` — the reference prompts the voice+text KV in once
  with that RoPE baked and never moves or recomputes it.
- **Continuation**: latent L_i sits at `P - 1 + i` (bos at `V+T = P-1`,
  then +1 per latent). Since the fed-back cache holds exactly `P - 1 + i`
  rows when L_i is the next row to generate, the 8 new rows take positions
  `kv_rows .. kv_rows + 7` — the recipe collapses to one arange.

Provenance (verified against /tmp/xn-ptts): `qnn/runner/phonon.cpp` — voice
KV baked at `0..V-1`, text prefill cached ONCE at `V..V+T-1`, then
`*buf_.pos = pos; …; pos++` per latent row on the contiguous absolute
timeline, cache never trimmed; `transformer.rs:736-745` — RoPE offset =
`current_end` (FlowLm cache length), append-only (trim is Mimi-only);
`synth.rs:1233/1319` + `flow_lm.rs:296` — `prompt_text` once per chunk,
one `StepInput::Bos/Latent` row per step; `seq_budget = text + prompt +
headroom` (the text is NOT re-cached per step).

The pre-prefill-once port re-fed the prompt every call with the
non-contiguous recipe below; that is documented in "The prompt-requery
defect". An even earlier port shipped the contiguous
`arange(past_kv, past_kv + P + 7)`: the re-run prompt rows rode the moving
timeline (+8 positions per call), so their attention distances froze at
call-1 values and their K/V changed every call — the device's
after-~4-words artifacts (calls 2-3). The cos/sin cache covers 8192
positions; the EOS-capped call count keeps offsets well under.

**The prompt-requery defect (found + fixed 2026-11-11)**: the previous
recipe re-ran the voice+text block through the graph on EVERY call with
positions pinned at `0..P-2`. Because attention is causal only WITHIN the
new block (the mask reaching the GQA is a shared additive column bias over
the total sequence — per-query-row masking is not expressible), the re-run
prompt rows at layers 1–5 attended to the growing fed-back LATENT cache —
something that never happens in the reference (its prompt rows only ever
saw earlier prompt rows at prefill). The text K/V the latent queries read
therefore MUTATED on every call: x86 probe (30 calls, 163 prompt rows) —
layer-0 K/V drift exactly 0.0 (embedding+position only; the earlier
"bitwise identical call-to-call" claim in this doc was measured at layer 0
ONLY and is trivially true there, proving nothing about the deeper
layers), while layers 1–5 drifted every call without ever settling (value
cosine down to 0.13–0.43, K max|Δ| up to ~3.0; last-pair drift 0.23–0.33).
Same drift on healthy and degenerate seeds — a drifting,
out-of-distribution text representation that mostly survives but
occasionally tips the EOS decision: chunks over-generate at the sentence
end (long tail, occasional verbatim frame repeats — cos 0.997 between
consecutive calls — eos climbing to ~2 but never crossing 4.0, inflated
3.5–4.4 chars/s vs 7–14.7 healthy). Voice-dependent (the drift interacts
with the voice embedding) but not seed-deterministic.

**Fix (shipped)**: prefill-once + empty-prompt continuations + whole-present
feedback, i.e. the model card's own driver convention. The graph accepts
zero-size `input_ids`/`audio_prompt_latents` (verified x86 ORT 1.24.2 numpy
and OrtValue paths; the CI spike re-proves the ORT C API path). The fed-back
prompt K/V are bitwise stable by construction (drift 0.0 at every layer,
verified). x86 A/B sweep (4 texts × 5 device voices × 6 seeds, full audio
render + self-similarity): old recipe 8/120 degenerate runs (7 never
crossed EOS; worst cell 3/6; one 36.5 s run) → prefill-once 0/120, healthy
eos spikes intact, per-cell max frames ≈ median (EOS timing tightened),
12–17 chars/s everywhere. Continuation calls also got ~20× cheaper (8 new
rows vs 171). KV memory +~3 MB per chunk (the P prompt rows ride along).

**KV LAYOUT TRAP (the device bug)**: the caches are `[1, heads, seq, dim]`
— HEAD-major. Rows are STRIDED: position t of every head is 8 separate
64-float segments. Copying a contiguous float prefix (or suffix) of the
buffer is NOT "the first/last N rows of every head" — it takes head 0 (or
head 7's tail) and feeds it back for all eight heads. The first port did
exactly that: call 1 already fed back garbage-aligned rows, call 2+ attended
poisoned context, and the audio degenerated into the repeat spiral →
stutter → whisper the device round reported — while the CI spike (same bug)
only ever scored shapes/EOS/non-silence and its marginal crossings
("crossed at call 20/26 with one seed, never with another") were
misdiagnosed as noise-dependent EOS timing. The x86 Python mirrors slice
correctly through numpy and render clean (46 runs, 10-12 seeds × 3 feedback
variants, sentence and 217-char chunk scale): the recipe was never the
problem. The feedback copy must walk the heads explicitly.

**EOS stop rule** (generation_config + preprocessor_config): first frame
whose logit > 4.0 starts a countdown of `frames_after_eos` (1 frame; 3 for
text ≤ 4 words) — stop when it runs out. Frame budget:
`ceil((T/3 + 2) * 12.5 * 1.5)` (the hub's ×1.5 — it costs nothing when EOS
crosses normally, and bounds the rare late crosser). **Soft-EOS safety
net**: two consecutive CALLS whose per-call eos PEAK exceeds 1.0 without a
real crossing also stop the chunk ("soft-EOS stop", clean head kept).
Healthy runs sit deep negative (-5…-9) until the final spike and only ever
dip to ~+0.5 mid-run (x86 sweep: zero sustained-plateau runs), while a
degenerate context hovers just under the threshold (~1–2, never crossing)
— the sustained plateau is the discriminator, and the two-call window is
what keeps single-call dips from clipping healthy chunks. The engine logs
the per-chunk eos peak + the call it peaked at; a never-crossing run
within budget, a soft-EOS stop, or a non-finite latent is the
degenerate/corrupt-context signal, not noise variance.

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
(prefill-once + empty-prompt continuations, mirroring
`PhononEngine.generateChunk`) on the vendored ORT 1.24.2 (macOS runner):
asserts sessions load (the com.microsoft contrib ops — GroupQueryAttention,
RotaryEmbedding, QuickGelu — are the load-bearing question), zero-size
prompt tensors are accepted, EOS crosses 4.0 within budget, PCM is
non-silent at 24 kHz, prints RTF/RSS. Informative/non-blocking like the
other spikes; the phone is the real bench. The x86 Python harness
(`/tmp/phonon-tail`, ORT 1.24.2 + tokenizers) is where audio-quality
regressions get caught — the spike only scores shapes/EOS/non-silence.
