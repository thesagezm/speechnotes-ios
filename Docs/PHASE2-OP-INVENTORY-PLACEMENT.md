# Phase 2 — Op inventory & placement plan (Kokoro + Supertonic)

**Deliverable 2 of the hybrid CPU + ANE plan.** Written 2026-11-09. Builds on
`Docs/POSTMORTEM-KOKORO-ACCELERATION.md` (failure classes + hypotheses H1–H4).

Method: the actual ONNX graphs were parsed (onnx 1.23.2, script in
`/tmp/phase2/scripts/dump_graph.py`) from the user's local model store —
`~/.local/share/speechnotes/models/`. The Kokoro file is **byte-exact** to the
CI-pinned artifact (325,532,232 B, `pytorch 2.6.0`, opset 20). The local
Supertonic set is the **v1/v2 sizing** (27.3 / 1.5 / 132.5 / 101.4 MB,
`pytorch 2.8.0`, opset 19); the iOS app's `ModelManager` pins **supertonic-3**
(36.4 / 3.7 / 256.5 / 101.4 MB). Topology is expected to be the same family
(same vendored Helper.swift orchestration); Phase 4 CI converts the *actual*
iOS-pinned supertonic-3 artifacts, and the inventory below is validated there.
A supertonic-3 download was attempted and aborted on network flakiness — CI
will fetch it instead.

Support-matrix sources: ONNX Runtime CoreML-EP docs (option names quoted),
coremltools 9.0 (current), and the community Kokoro-on-CoreML ports
(`mattmireles/kokoro-coreml` — split-for-ANE technique; `txgsync/kokoro-82m-coreml-ane`
— 7-stage ANE pipeline), carried as hypotheses, not facts.

---

## 1. Kokoro fp32 (`model.onnx`) — measured

**IO:** `input_ids` INT64 `[1, 'sequence_length']` · `style` FLOAT `[1, 256]` ·
`speed` FLOAT `[1]` → `waveform` FLOAT `[1, 'num_samples']`. Single graph, no
subgraphs. 2463 nodes, 49 distinct op types, 554 initializers = **324.6 MB**.

**Op histogram (all 49):**

| op | n | op | n | op | n |
|---|---|---|---|---|---|
| Add | 441 | Mul | 315 | Unsqueeze | 192 |
| Slice | 170 | ReduceMean | 130 | Gather | 121 |
| MatMul | 102 | Div | 94 | Sqrt | 90 |
| Transpose | 89 | Conv | 88 | Shape | 73 |
| Gemm | 73 | Concat | 72 | Sub | 68 |
| Pow | 62 | Reshape | 61 | Sin | 51 |
| LayerNormalization | 31 | LeakyRelu | 28 | Cast | 18 |
| Tanh | 13 | Softmax | 12 | Where | 7 |
| ConstantOfShape | 6 | LSTM | **6** | Resize | 6 |
| ConvTranspose | **6** | Expand | 5 | Squeeze | 5 |
| Equal | 4 | Greater | 3 | CumSum | 2 |
| Range | 2 | Less | 2 | Pad | 2 |
| Sigmoid | 1 | ReduceSum | 1 | Round | 1 |
| Clip | 1 | GreaterOrEqual | 1 | And | 1 |
| Floor | 1 | STFT | **1** | Atan | 1 |
| Exp | 1 | Cos | 1 | NonZero | 1 |
| ScatterND | 1 | | | | |

**Structure (from node names):**

- **PLBERT encoder** (ALBERT-style): attention MatMuls + FF (e.g. 6.29 MB
  `[768,2048]` pairs), LayerNorm, Softmax ×12 — the transformer block.
- **Text CNN**: Conv k5 s1 (5-wide, pads 2) + LayerNorm stacks.
- **Duration/prosody path**: **6 × bidirectional LSTM(hidden 256)** —
  `text_encoder/lstm`, `predictor/text_encoder/lstms.0/2/4`, `predictor/lstm`,
  `shared/LSTM`. ~5.2 MB of weights each ≈ **31 MB total**.
- **Duration → frames sampling**: CumSum ×2, Range ×2, NonZero, ScatterND,
  Round, Floor — the token-duration expand step.
- **F0/N pools**: Resize(nearest) + grouped ConvTranspose k3 s2 (group 512 / 1090).
- **istftnet decoder** (`decoder/decoder`): **193.3 MB of the 324.6 MB
  weights (60 %)** — AdaIN resblocks as [1024,1090,3] convs (13.4 MB each ×3),
  encode [1024,514,3], upsample ConvTranspose k20 s10 and k12 s6, iSTFT built
  from a ConvTranspose k20 s5 + **one ONNX `STFT` node**, sine source
  (Sin/Cos ×51, Resize linear ×2).

## 2. Supertonic (local v1/v2 set) — measured

| model | IO (in → out) | nodes | distinct ops | weights | hostile ops |
|---|---|---|---|---|---|
| text_encoder | `text_ids[i64 B,L]`, `style_ttl[f32 B,50,256]`, `text_mask` → `text_emb[f32 B,256,L']` | 680 | 24 | 27.1 MB | **none** |
| duration_predictor | `text_ids`, `style_dp[f32 B,8,16]`, `text_mask` → `duration[f32 B]` | 400 | 28 | 1.3 MB | **none** |
| vector_estimator | `noisy_latent[f32 B,144,Ll]`, `text_emb`, `style_ttl`, `latent_mask`, `text_mask`, `current_step[B]`, `total_step[B]` → `denoised_latent` | 964 | 30 | **132.1 MB** | **none** |
| vocoder | `latent[f32 B,144,Ll]` → `wav_tts[f32 B,S]` | 170 | 17 | **101.4 MB** | **none** |

Op character across all four: Conv (pointwise k1 + **ConvNeXt depthwise k5
with dilations 1/2/4/8, group=512**), MatMul + Softmax + LayerNorm attention,
Erf (GELU), PRelu, one BatchNorm, Sin/Cos (RoPE in the estimator). **No LSTM,
no ConvTranspose, no STFT, no random ops, no control-flow.** Batch is a
dynamic axis (`'batch_size'`) but the app always runs B=1; `total_step` is a
scalar input (8-step flow matching → 8 estimator calls per chunk).

## 3. Core ML support matrix (op-group level)

Predicted device from: coremltools 9 mlprogram coverage, the ORT CoreML-EP
supported-ops/format differences (NeuralNetwork vs MLProgram), known ANE
affinities, and the community ports' split points. ANE column = expectation
to be *verified by `ProfileComputePlan` + on-device stage timing*, not assumed.

| op-group | where (Kokoro / Supertonic) | coremltools 9 mlprogram | ORT CoreML EP | predicted ANE | risk |
|---|---|---|---|---|---|
| MatMul/Gemm/attention | PLBERT; S-estimator attention | ✅ | ✅ (B const) | ✅ likely | low |
| Conv 1D k5 (dense) | K-text CNN; S encoder | ✅ (→conv2d) | ✅ (1D/2D) | ✅ likely | low |
| Depthwise k5 dilated conv | S ConvNeXt ×32 | ✅ (→conv2d) | ✅ | ✅ likely | low (verify dilation) |
| LayerNormalization | both | ✅ | MLProgram format only | ✅ | low |
| Softmax/Erf/Tanh/PRelu/LeakyRelu | both | ✅ | ✅ | ✅ | low |
| **LSTM bi-256 ×6** | K predictor path | ⚠️ NN-format only | ❌ (falls back) | ❌ never | **CPU by design** (31 MB, small FLOPs share) |
| **ConvTranspose k20s10 / k12s6** | K istftnet upsample | ✅ | ✅ (MLProgram) | ⚠️ often GPU/CPU | **split risk** (community ports split here) |
| ConvTranspose k3 s2 grouped | K F0/N pools | ✅ | ✅ | ⚠️ | medium |
| **STFT ×1** | K iSTFT tail | ❌ (needs decomposition) | ❌ | ❌ | **CPU** (single node, cheap) |
| Resize nearest / linear | K pools, sine source | ✅ | ✅ const-attrs only | nearest ✅ / linear ⚠️ | low |
| Gather ×121 / Shape ×73 | K shape math + embeddings | ✅ | scalar-index ❌ | ❌ mostly | CPU; partition-fragmentation driver |
| CumSum/Range/NonZero/ScatterND | K duration sampling | ✅ | ✅ | ❌ | CPU; must keep **bit-exact** (parity) |
| Sin/Cos | K sine source; S RoPE | ✅ | ✅ | ⚠️ | low |

## 4. Engine choice per model

> **Phase-4 outcome (2026-11-10, parity round 3, run 42718617400 — all numbers
> from `parity-report.json`, macOS ARM runner, onnxruntime 1.24.2 wheel):**
>
> - **Supertonic ships via (a) the ORT CoreML EP — this REVERSES the (b)
>   recommendation below.** The whole 4-model chain through the EP is
>   numerically perfect against the ORT-CPU fp32 oracle: Pearson **1.0000**,
>   rel-RMS **0.0007**, exact length (latent_len 742, waveform 2,279,424
>   samples), zero non-finites, and `active_providers` proves CoreML engaged
>   on **all four sessions**. The predicted "nothing to split" from §2 is
>   confirmed — the EP never had a hard job here, so the conversion pipeline
>   (b) would have bought nothing but artifacts to maintain. (c) is moot for
>   a different reason: coremltools cannot ingest ONNX at all (source must be
>   pytorch/tensorflow); the onnx2torch route is deferred and only pays if
>   on-device EP perf disappoints.
> - **Kokoro stays on CPU (d) — the EP is banned under EVERY unit
>   configuration.** With the EP active (provider-proof logged), Kokoro fp32
>   renders the WRONG UTTERANCE: Pearson 0.6305, rel-RMS 0.7849 (gate: >0.9 /
>   <0.25), exact length. Round 3's localization killed the last hope: with
>   `MLComputeUnits=CPUAndGPU` (ANE excluded, `gpu_pin_active_providers`
>   shows CoreML genuinely active) the result is **identical bad**
>   (0.6305 / 0.7849) — the corruption is in the EP's CoreML conversion of
>   the graph itself, not ANE-fp16 rounding. The decoder-stage split
>   experiment is INCONCLUSIVE (onnx subgraph extraction died on a
>   topological-validation error: `/encoder/bert/Shape_1` input `input_ids`
>   not topologically resolvable after extraction), but moot: a split that
>   routes part of the graph through this EP inherits this failure. The only
>   unexplored route is the (c) onnx2torch decoder split (direct coremltools
>   conversion, bypassing the EP) — deferred, `Scripts/convert_parity.py` §C.
>   Compact int8 (92 MB) remains the low-memory CPU tier.

### Supertonic → **(b) direct coremltools MLProgram conversion** (fp16, compute_units ALL) — **SUPERSEDED: ships via (a) EP, see outcome above**

- **Why (b):** every op is mlprogram-supported and ANE-shaped; there is nothing
  to split. The heavy models (estimator 132 MB, vocoder 101 MB local; 256 MB
  estimator on supertonic-3) are exactly the perf-per-watt prize. The
  flow-matching loop (8 estimator invocations per chunk) is a natural async
  overlap: ANE runs step k while CPU prepares chunk k+1's text embeddings.
- **Why not (a):** ORT's EP would add a second runtime's partitioner between us
  and the ANE with no benefit for a graph that needs no partitioning.
- **Why not (c):** nothing to split.
- **Precision:** fp16 (weights 262 → ~131 MB local; 398 → ~199 MB on
  supertonic-3). int8/palettization behind a flag + quality gate (§6).

### Kokoro → **staged: try (a) ORT CoreML EP first; fallback (c) manual decoder split; (d) stays the baseline** — **RESOLVED: (d) CPU, EP banned in all unit configs, see outcome above**

- **Why EP first:** zero graph surgery, works on the existing byte-pinned
  artifact, and `ProfileComputePlan=1` + provider logging *is* the H1/H2
  experiment (one CI job + one device run). The known CPU-resident ops (6
  LSTMs, STFT, sampling glue, shape math) force CPU segments regardless of
  approach — the question is only whether ORT's partitioner produces few large
  segments or a fallback explosion (H1).
- **Fallback (c) — manual split at a documented boundary:** the decoder is a
  clean subgraph (`decoder/decoder`, 193 MB, pure conv/matmul + the istft
  tail). Split = Core ML MLProgram for the decoder (+ optionally PLBERT/text
  CNN), ORT CPU for everything else, with the duration-sampling glue
  (CumSum/Range/NonZero/ScatterND) kept **on CPU and bit-exact** so the frame
  expansion is identical to the reference. This mirrors what the community
  ports do (split-for-ANE, 7-stage pipelines) without their rewrite cost.
- **Why not coremltools-direct whole-graph:** the 6 LSTMs (mlprogram support is
  weak/absent) and the STFT node would force surgery for no placement gain —
  those ops stay on CPU in every variant.
- **Kokoro Compact int8 (92 MB) remains the low-memory CPU tier** — it is the
  existing shipped artifact and the memory-pressure fallback.

## 5. Dynamic shapes → buckets, pre-warm, cache

**Constraint (H2):** ANE specialization is per-shape; dynamic axes risk
respecialization or CPU fallback. Both engines expose a single dynamic axis we
control: `sequence_length` (Kokoro) / `text_length` (Supertonic).

- **Chunker hook (existing):** `SentenceChunker` already caps at 160 (Kokoro) /
  200 (Supertonic) chars; token counts land roughly in the low hundreds
  (Kokoro hard ceiling 510 — the style-row clamp `clamp(N-2, 0, 509)`).
- **Bucket set (initial, to be re-cut from Phase-3 measured token
  distribution):** {64, 128, 192, 256, 320, 448, 510} for Kokoro; same idea for
  Supertonic text_length, with latent_length derived from the duration output.
  Each bucket = a static-shape model variant (RequireStaticInputShapes=1 for
  the EP variant; fixed shapes for MLPrograms).
- **Padding + trim:** pad to the bucket edge with token id 0 and trim the
  produced waveform at the real-token frame count. For that trim to be exact
  rather than heuristic, expose the duration-sum as an **extra graph output at
  conversion time** (coremltools can mark internal tensors as outputs — no
  pytorch re-export needed). Fallback if that proves brittle: existing
  energy-based tail trim, validated by the parity gate.
- **Pre-warm at launch (after model-ready, off the audio path, `.utility`
  QoS):** one dummy inference per bucket per engine → triggers ANE
  specialization + MLProgram compilation ahead of the first speak.
  `SpecializationStrategy = "FastPrediction"` (iOS ≥ 18 — matches our target).
- **Model cache:** `ModelCacheDirectory` → `NSCachesDirectory`-backed path
  (purgeable, never backed up). Cache keys pinned to model metadata so a
  re-download can't hit a stale specialization.

## 6. Precision plan

- **fp16 everywhere by default** (MLProgram, half weights; ANE-native math).
- **GPU fp16 accumulation** (`AllowLowPrecisionAccumulationOnGPU=1`) behind a
  flag — default off until the parity gate passes with it on.
- **int8 / palettization behind flags only**, each gated by the Phase-4 parity
  harness reusing the uint8-era machinery: fixed corpus, ORT-CPU fp32 oracle
  (proven bit-deterministic), best-of-±0.5 s lag Pearson > 0.9, rel-RMS < 0.25,
  length delta ≤ 0.1 s / 2 %, zero non-finite samples. The uint8 forensics is
  the template; nothing ships on file size.

## 7. RAM: can the app ask for more? (researched)

**Short answer: no runtime "give me more RAM" API exists — but there is a
signing-time entitlement, and for this app's install path it must ride on
LiveContainer, not on Speechnotes.**

1. **The mechanism:** iOS jetsam caps each process by a per-device, opaque
   limit. There is no API to raise it at runtime. Read it, don't guess:
   `os_proc_available_memory()` (bytes until jetsam), plus
   `task_vm_info.phys_footprint` for what we currently hold.
2. **The entitlement:** `com.apple.developer.kernel.increased-memory-limit`
   (iOS 15+) raises the cap **on supported device models** — Apple's own docs
   say to verify at runtime with `os_proc_available_memory()`, and its sibling
   `com.apple.developer.kernel.increased-debugging-memory-limit` applies only
   when a debugger is attached (useless here). There is also
   `com.apple.developer.kernel.extended-virtual-addressing` — address *space*,
   not RAM; harmless but not what we need.
3. **The catch for this project:** free Apple ID ("personal team") signing
   **strips the entitlement during re-signing** (documented SideStore bug
   report #1616). And because the TTS app runs *inside LiveContainer's
   process*, the entitlement that matters is the **host's**: it must be on
   LiveContainer itself. Community paths that work: install LiveContainer via
   Cydia Impactor (its docs note Impactor adds `increased-memory-limit`
   automatically), newer AltStore builds which support the entitlement, or the
   iRAM+/GetMoreRam-style forks that enable it on-device. Adding it to the
   Speechnotes IPA does nothing under LiveContainer and gets stripped under
   SideStore.
4. **Therefore the engineering answer is to cut dirty memory** — which is also
   the only lever we fully control:
   - fp16 Core ML (Kokoro 325 → ~163 MB; Supertonic local 262 → ~131 MB);
   - keep the single-slot engine rule and idle unload (already shipped);
   - on memory warning / thermal escalation: drop the render-ahead bank and
     buffers before the system drops us (Phase 5 policy);
   - retire MLX from the voice/npz path (catalog 1.11) — today every IPA ships
     Metal machinery + GPU allocations just to read voices.npz;
   - verify in Phase 3 whether the ORT-CPU path heap-allocates the whole model
     (dirty) vs mmap (clean, evictable) — external-data/mmap is a real
     footprint lever for the CPU fallback tier;
   - **instrument**: `os_proc_available_memory()` + `phys_footprint` per
     session in the Phase-3 harness (added to its spec), so "how close to the
     cliff are we" becomes a number, not a crash report.
5. **Expectation to verify, not trust:** community tables put 4 GB-device
   foreground caps around ~3.0–3.4 GB, but per-device limits vary by iOS
   version and the A14 numbers for *our* exact build/iOS 26.5 are unmeasured —
   the harness measures the actual budget on day one.

## 8. Hypothesis status after Phase 2

| # | Hypothesis | Status |
|---|---|---|
| H1a | ORT 1.24.2 SPM binary lacks the CoreML EP | **ANSWERED, twice over — it ships with it.** (1) Primary source: the SPM binary target is `pod-archive-onnxruntime-c-1.24.2.zip` (Package.swift), and ORT's Apple-pod release build settings pass **`--use_coreml`**. (2) **Binary verification (2026-11-09)**: the downloaded archive's `onnxruntime.xcframework/ios-arm64` binary contains the full `CoreMLExecutionProvider` implementation — `GetCapability`/`Compile` symbols, the `MLComputeUnits` and `ModelCacheDirectory` option keys, and the `setSpecializationStrategy:` selector (FastPrediction path). The EP is available to the app as-is. |
| H1 | ORT CoreML EP partitions Kokoro into a fallback explosion | **ANSWERED, Phase 4 (rounds 2–3, run 42718617400) — worse than an explosion: silent corruption.** The EP engages (CoreML active in `session.get_providers()` and the per-result `active_providers`), lengths stay exact, but the audio is a DIFFERENT UTTERANCE (Pearson 0.6305, rel-RMS 0.7849 vs gate >0.9/<0.25). Not an ANE-fp16 rounding story: pinning `MLComputeUnits=CPUAndGPU` (ANE excluded, provider-proof logged — the round-2 provider_options bug is fixed) reproduces the failure **identically**. The EP's CoreML conversion of Kokoro's graph is numerically wrong on GPU too. Placement verdict: **Kokoro never ships via the EP — default units banned, GPU-pinned banned; CPU is its engine** unless the deferred onnx2torch decoder split (direct coremltools, no EP) is ever revived. Supertonic is the mirror image: whole chain EP-perfect (Pearson 1.0000, rel-RMS 0.0007, all 4 sessions CoreML-active) → ships via the EP. |
| H2 | Dynamic-axis respecialization thrash | mitigated by design (buckets + pre-warm + FastPrediction); measured by first-N-chunk latency curve. **Moot for the shipping variant's parity question** — round 3 ran the EP with default dynamic shapes and Supertonic still matched the CPU oracle exactly (best_lag 0, exact length) |
| H3 | fp16 artifacts in decoder/vocoder | **gate built and passed for the shipping path**: the Phase-4 parity workflow (`.github/workflows/convert-parity.yml` + `Scripts/convert_parity.py`) ran the EP's internal fp16 against the ORT-CPU fp32 oracle — Supertonic PASS (rel-RMS 0.0007 ≪ 0.25), Kokoro FAIL (0.7849) and thereby banned. Device-ear check still applies per the B4 discipline |
| H4 | ANE can't do the LSTMs | **resolved analytically**: LSTMs stay CPU in every variant; their weight share (~31 MB) and FLOPs share are small |

## 9. What Phase 3/4 must produce for this plan to proceed

- **Phase 3 (harness):** baseline ORT-CPU session on device (RTF, TTFA,
  CPU-seconds, thermal, **footprint + available-memory now added**); the
  measured token-length distribution to finalize bucket edges.
- **Phase 4 (CI):** coremltools 9 conversion of Supertonic ×4 (+ supertonic-3
  variants) and the Kokoro EP/split variants; numerical parity vs the ORT fp32
  oracle; `xcrun coremlcompiler compile` smoke; artifacts cached; ONE
  multi-variant build behind flags (engine ∈ {cpu, ep, direct, split} ×
  precision ∈ {fp16, int8}).
- **Go/no-go between (a) and (c) for Kokoro** is decided by exactly one CI job
  plus one device run — no long bake.

---

## Appendix A — the increased-memory-limit entitlement, concretely

**Entitlement plist (would live on LiveContainer's host build, NOT on the
Speechnotes IPA — see §7.3):**

```xml
<key>com.apple.developer.kernel.increased-memory-limit</key>
<true/>
```

Optionally alongside `com.apple.developer.kernel.extended-virtual-addressing`
(address-space only). Xcode exposes this as Signing & Capabilities →
"Increased Memory Limit".

**Verification that it actually took effect (device log line for the
harness):**

```swift
import os
let headroom = os_proc_available_memory()   // bytes until jetsam, iOS 13+
// harness logs: "mem: available \(headroom / 1_048_576) MB, footprint \(footprintMB) MB"
```

If the entitlement was stripped at signing (free-profile re-sign) or the A14
doesn't honor the raise, the `available` number simply won't move — which is
why it must be *measured*, per Apple's own recommendation, rather than assumed
from the profile contents.

**Failure signatures if we hit the default cap anyway:**Jetsam kills are
visible in-device as the known `NSPOSIXErrorDomain Code=12` / silent process
death patterns this repo already diagnosed (the 1.7 GB Opus book, the MLX-era
jetsam deaths) — the harness's footprint log turns those post-mortems into
pre-mortems.
