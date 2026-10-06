# The uint8 Kokoro tier — byte-level forensics

**Branch:** `batch-c-d-session`, commit `87245df`.
**Question:** why does `testQuantizedRenderMatchesFP32` fail, and can the
spike's verdict be trusted?
**Short answer:** yes — and the failure is real, deterministic, and
structural in the artifact, not in the test.

Everything below was measured on 2026-10-06 from the exact files CI
downloads (`huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX`).

---

## 1. What CI measured

| metric | value |
| --- | --- |
| render length | 92,400 samples both tiers (delta 0) |
| rel-RMS (zero lag) | 1.3655 |
| Pearson correlation (zero lag) | 0.0570 |
| best of ±0.5 s lag search | 0.0818 at lag 480 |
| aligned rel-RMS at best lag | 1.3474 |
| uint8 peak / RMS / non-finite | 0.6406 / 0.0670 / 0 of 92,400 |
| fp32 peak / RMS / non-finite | 0.5611 / 0.0678 / 0 of 92,400 |
| same-graph determinism | 0/92,400 samples differ, max delta 0, rel-RMS 0.000000 |

The last row is the new control (`testRenderIsDeterministicAcrossSessions`,
added in `87245df`). It matters because the whole gate rests on the premise
that the runtime reproduces itself: a zero correlation between two graphs
could mean the quantized graph corrupts speech **or** that ORT CPU is not
deterministic for this graph (float atomics in a parallel reduction, thread
races, denormal/FTZ differences between sessions). The control rules the
second explanation out — the same graph through two fresh sessions renders
bit-identically. The gate's comparison is therefore measuring the models,
not the runtime.

The per-tier loudness rows matter for the same reason at the other end: a
tier that had degenerated into all-NaN, all-`-1`, or full-scale clipping
would also correlate ~0 against anything. Both tiers are finite, loud and
sane; the two waveforms are simply different speech.

Both files are byte-pinned and identical across days (verified against the
HF API on 2026-10-06):

| file | bytes |
| --- | --- |
| `onnx/model.onnx` (fp32) | 325,532,232 |
| `onnx/model_uint8.onnx` | 177,464,632 |

## 2. The two files are not the same graph

Decoding the ModelProto headers from the first bytes of each file:

| field | `model_uint8.onnx` | `model.onnx` |
| --- | --- | --- |
| `producer_name` (field 2) | `onnx.quantize` | `pytorch` |
| `producer_version` (field 3) | `0.1.0` | `2.6.0` |
| `ir_version` (field 1) | 9 | 9 |

Then the node sets, collected from the `onnx::<Op>_<n>` identifiers that
name each node's op type:

| | count |
| --- | --- |
| distinct op identifiers, uint8 | 38 |
| distinct op identifiers, fp32 | 35 |

**Present in the uint8 graph only** — five nodes the fp32 graph does not
have:

```
MatMul_6704_quantized
MatMul_6704_scale
MatMul_6886_quantized
MatMul_6886_scale
MatMul_6886_zero_point
```

**Present in the fp32 graph only:** `MatMul_6704`, `MatMul_6886`.

So `model_uint8.onnx` is not a weight-only quantized copy of `model.onnx`
with the same topology. The optimizer replaced two `MatMul` nodes with
`QLinearMatMul`-style quantized matmuls and their per-tensor scale /
zero-point satellite nodes — a *different graph* that computes the same
function in exact arithmetic, with an extra rescale path and quantized
accumulation.

That is the mechanism behind the numbers: same inputs, materially different
arithmetic, no shared intermediate rounding, and a vocoder fed differently
rounded latent frames diverges into a different utterance. It also explains
why the length agrees exactly — the duration predictor sits in a part of
the graph both files share, so phoneme timing is identical while the
waveform is not.

## 3. What this rules in and out

| hypothesis | verdict |
| --- | --- |
| shifting / partial download in CI | ruled out — byte-pinned sizes, and identical metrics on different days |
| ORT CPU nondeterminism | ruled out — 0/92,400 sample delta across two fresh sessions |
| test harness bug (tokens, style row, speed) | ruled out — `testGenerateSpeech` proves the contract, and both tiers use the SAME harness in the SAME process |
| uint8 degenerating to NaN/clipping | ruled out — 0 non-finite samples, sane peak/RMS |
| genuine graph-level divergence in the quantized artifact | **confirmed** |

## 4. What to do with the tier

The recorded options (ship fp32, re-quantize with calibration, drop the
tier) all remain, and the byte-level evidence narrows them:

- **"Re-quantize with a calibration set"** is the only one that can save a
  uint8 tier. Calibration only tunes *scale selection*, and these graphs
  differ in *which nodes exist* — so the fix is to quantize in a way that
  leaves the topology alone (e.g. `quantize_static` with
  `QuantFormat.QOperator` off for the MatMuls it rewrote, or a toolchain
  that emits DequantizeLinear before MatMul rather than replacing it).
- **Shipping fp32** is already the default (`EngineKind.kokoroOnnx`) and
  needs no change.
- **Dropping the tier** would be a product decision; nothing in the app
  depends on it, and the picker lists it explicitly.

Whatever is chosen, the guard to keep in mind: this cannot be fixed by
loosening the gate. The gate is correctly reporting that the artifact is
not the fp32 graph.

## 5. Reproducing the measurements

The spike prints the signal metrics on every run (`KOKORO-SMALL-SPIKE
quantization gate: …` and `… determinism: …` lines in the
`kokoro-small-spike` job log). The graph-level comparison is a
one-off protobuf decode of the first bytes of each ONNX file — ModelProto
fields 1/2/3 for the headers, then the `onnx::*` node-name strings for the
op sets.
