# Postmortem — Core ML / acceleration attempts for Kokoro & Supertonic

**Phase 1 deliverable of the hybrid CPU + ANE plan.** Written 2026-11-09 on
branch `batch-c-d-session`. Sources: full git history (all branches,
`fa2fdb8` → `fee156a`, 2026-08-16 → 2026-11), every doc under `Docs/` and the
repo root, `.github/workflows/build.yml` history, current `ModelManager` /
engine sources. The repo has **no open issues and no PRs** (checked via
`gh`), so branches + commits + docs are the entire record.

---

## 0. Executive summary — the premise, corrected

The working premise was "Core ML was attempted before for Kokoro and mostly
failed." **The history does not contain a literal Core ML attempt for Kokoro.**
No commit, branch, doc or CI log ever used `coremltools`, an `.mlmodel/.mlpackage`,
`MLModel`, or ORT's CoreML execution provider (verified by pickaxe over all refs
for `coreml`/`CoreML`/`MLModel`/`ExecutionProvider` — the only Core ML code in the
repo's history is WhisperKit for STT, which worked).

What *was* tried, and what the phrase "Core ML failed" actually compresses:

| # | Attempt | Era | Outcome |
|---|---------|-----|---------|
| A | **KokoroSwift/MLX on the GPU** ("Metal" engine, Plan A) | v0.2–v0.6, 2026-08-16 | Ran on device at RTF ≈ 0.5, then killed by memory (jetsam) on long notes; removed entirely in v0.7.0 |
| B | **ONNX Runtime CPU EP** (Plan B) | v0.6.0 → today | The reference path. Works. RTF ≈ 0.5 warm foreground on the A14 |
| C | **Quantized ONNX tiers** (q8f16 → uint8 → fp16 → int8) | v0.6.1 → v1.8 | uint8 **corrupt** (proven, deterministic), fp16 **NaN** on ORT CPU, int8 (92 MB) shipped and clean |
| D | **Soprano** (Qwen3+Vocos ONNX, KV-cache) | v1.7.0 | Runner spike failed on a `Gather` op; device quality failed user review; fully removed |
| E | **Supertonic** (4-session flow-matching) | v1.0.0 → today | Works on CPU; RTF ≈ 0.85 @ rate 1.2 on A14; thermal throttling is the open enemy |
| F | **WhisperKit (Core ML) for STT** | v2.0 | **Success** — proof the Core ML toolchain works in this app's constraints |

So the honest headline is: **GPU-accelerated Kokoro was tried once (MLX, not
Core ML), worked arithmetically, and died of memory management — not of math.
Core ML per se has never been attempted.** That is materially better news than
"Core ML mostly failed," but the failures that did happen leave four hard
lessons (§5) that the hybrid plan must honor.

---

## 1. Environment (verified, 2026-08 docs + current tree)

- Device: **iPhone 12 Pro Max, A14, iOS 26.5** (SPEECHNOTES-IOS-PLAN.md:338).
  One doc says "A14/6GB" (SUPERTONIC-PORT.md:79); public spec for this model is
  4 GB — plan against 4 GB.
- Install path: unsigned IPA → SideStore / **LiveContainer**. LiveContainer
  imposes **no dynamic frameworks** (dyld kill at launch if an `@rpath` framework
  is referenced but not embedded — hit once, see §2.1). All SPM deps are patched
  to static in CI (`2db3319`).
- Build: XcodeGen (`project.yml`) on GitHub Actions `macos-latest` runners;
  no local Mac. `build-ipa` ≈ **6 min** warm (TTS_BASELINE §7), not 45.
- Pins (frozen by repo golden rule): KokoroSwift 1.0.11 / MLX 0.30.2 /
  MLXUtilsLibrary 0.0.6 / MisakiSwift 1.0.6 / ORT 1.24.2 (all from 2026-08).
- iOS deployment target 18.0 — so MLTensor / stateful / async Core ML APIs are
  available when we want them.
- Known dependency fact: **MisakiSwift 1.0.6 depends on MLX 0.30.2 (MLX + MLXNN)
  and ships as a dynamic library product** (Package.swift verified on GitHub);
  CI patches it to static. The app also links MLX directly for `NpyzReader`
  (voices.npz) in `OnnxKokoroEngine.swift:3`. MLX/Metal is therefore still
  inside every IPA today, used only for the text frontend + voice loading.
  Removal is catalog item 1.11 ("gated on MisakiSwift edge verification"),
  still pending.

---

## 2. Attempt-by-attempt, with the evidence

### 2.1 Attempt A — KokoroSwift/MLX (Plan A, the "Metal" engine) — removed v0.7.0

**What it was.** `mlalma/kokoro-ios` (KokoroSwift 1.0.11): a pure-Swift Kokoro
port that runs the whole model (plbert + text encoder + decoder + istftnet
vocoder) through Apple **MLX 0.30.2** on the Metal GPU. Not Core ML, not
`MLModel` — MLX compiles its own Metal kernels at runtime (`default.metallib`).
Upstream claimed **~3.3× real-time on iPhone 13 Pro (A15)**; we budgeted
1.5–2.5× on A14 (SPEECHNOTES-IOS-PLAN.md:338) and measured **RTF ≈ 0.5**
(`KokoroEngine.swift:53`, "Generation outruns playback (RTF ≈ 0.5)").

**Model payload:** fp32 safetensors ≈ **342 MB** + `voices.npz`, downloaded at
first use (v0.3.0).

**Timeline — Plan A went from spike to removal in one day** (2026-08-16):

| Time (UTC+2) | Commit | Event |
|---|---|---|
| 11:04 | `fa2fdb8` | Phase 2 spike: macOS CI test generates `sample.wav` via KokoroSwift/MLX |
| 11:19 | `7d30c67` | Spike link fix: explicitly depend on MLX + MLXUtilsLibrary |
| 12:05 | `efdd4f7` | Spike → standalone SPM package (resource-bundle crash in xctest) |
| 12:29 | `3df825b` | **Phase 3: on device** — KokoroEngine, downloader, voice settings |
| 13:47 | `1f7a35a` | **LiveContainer launch crash** — dyld kill |
| 16:20 | `c34f3ad` | **"cut off after 3 words" + jetsam** (v0.5.1) |
| 16:50 | `799092a` | "too many tokens" → splitOversized + 160-char cap (v0.5.2) |
| 17:21 | `28ad963` | **Plan B step 1** — ORT SPM package linked (v0.6.0) |
| 17:43 | `d120245` | OnnxKokoroEngine (v0.6.1) — additive, MLX kept |
| 19:48 | `aa7699c` | **v0.7.0: MLX engine deleted** |

**Failure modes, precisely (this is the core of the postmortem):**

1. **dyld launch kill inside LiveContainer** (`1f7a35a`): "KokoroSwift 1.0.11
   declares `type: .dynamic` in its Package.swift; the unsigned archive linked
   `@rpath/KokoroSwift.framework` but never embedded it, so dyld killed the app
   at launch inside LiveContainer." Fixed by patching the checkout to static in
   CI — this is the origin of the repo-wide static-patch step that still runs.

2. **Per-call token limit** (`799092a`, v0.5.2): "larger chunks throw **'too
   many tokens'** and kill the rest of the note" — KokoroSwift throws on
   >~510-token calls; a run-on paragraph as one chunk failed long notes
   outright. Fixed by `splitOversized` + 160-char chunk cap (observed ceiling
   "~36 words ≈ the 200-char first chunk"). *The chunker the hybrid plan will
   reuse is a direct descendant of this failure.*

3. **Audio-graph reconnect glitch** (`c34f3ad`, R1): "Audio graph reconnected
   on EVERY chunk … chunk 1 played, chunk 2's buffer was silently dropped …
   That's the **'cut off after 3 words'** bug." Fixed: wire the graph once per
   format. *Not an acceleration failure — an AVAudioEngine lesson that must
   survive any engine swap.*

4. **Jetsam — the one that actually killed Plan A** (`c34f3ad`, R2):
   "Unbounded accumulation: all chunk buffers were held forever and **MLX's GPU
   cache grew with every generation** — long notes climbed until **jetsam killed
   the whole LiveContainer process** after the first sentence; long-note exports
   died the same way." Fixes shipped same day: release played buffers, cap
   generation 3 chunks ahead, `MLX.GPU.clearCache()` after every chunk. The
   in-code comment records the blunt version: "**unbounded accumulation killed
   LiveContainer via jetsam**" (`KokoroEngine.swift:216`).

   Classification: the *bug* (unbounded cache) was fixed in hours; the
   *condition* (a 342 MB fp32 model + MLX runtime + Metal allocations inside a
   4 GB LiveContainer process) remained. v0.6.x shipped both engines with
   README wording that says it outright — "Kokoro (Metal) … the fallback for
   **devices/situations where Metal memory pressure is a problem**" — and two
   days later `aa7699c` deleted the engine, switching to a standalone ONNX
   set (~101 MB q8f16 at the time) + legacy migration.

5. **CI-only wound — the metallib bundle dance** (`6c1a11d`, v0.8.1, the spike
   job for the retired kokoro-spike package): "Under `swift test` the xctest
   bundle is the main bundle, and **mlx's metallib loader checks mainBundle
   first, then the mlx-swift_Cmlx bundle — SPM copies neither into the xctest**."
   CI had to `find .build -name 'default.metallib'` and hand-copy it plus
   `mlx-swift_Cmlx.bundle` into the xctest, then `swift test --skip-build`. Any
   future GPU/CPU-hybrid test target on the runner inherits this class of
   resource-copy problem. (Job retired at `dfe6124`.)

**Was Plan A a Core ML failure?** No — but the *shape* of its failure is the
single most predictive datapoint for the hybrid plan: **the math was fine
(RTF 0.5, correct audio); the memory envelope was not.** Any ANE/Core ML path
must budget: model weights resident + activation arena + staging copies, and
prove the budget on the A14 before promising anything.

**Also worth recording (anti-claim):** MLX/Metal produced no wrong-output
evidence anywhere in the history. No NaN, no parity gate on the MLX path ever
existed or failed. The failure set was: packaging (dynamic framework), resource
loading (metallib), audio glue, and memory.

### 2.2 Attempt B — ONNX Runtime CPU EP (Plan B → the reference)

- **Packaging** (`28ad963`): `microsoft/onnxruntime-swift-package-manager`
  **1.24.2**, pinned exact, static library — satisfies LiveContainer with no
  CI changes. Never moved since (frozen by golden rule).
- **First model:** `model_q8f16.onnx` ≈ 82 MB from
  `onnx-community/Kokoro-82M-v1.0-ONNX` (`d120245`).
- **Input contract** (from `d120245`, still true): `input_ids` int64 `[1,N]`;
  style `float32 [1,256]` sliced from the voice's flat 510×256 vector at
  `clamp(N-2, 0, 509)·256`; `speed` float32. Output name is *not* stable across
  exports — `e4ee628` hardening note: "some exports name the output 'audio' and
  every synthesis would have thrown."
- **Streaming design** (unchanged in kind today): 160-char sentence chunks,
  producer up to 3 chunks ahead, pacing semaphore, played-buffer release,
  read-along ranges, WAV export. Today it runs through the shared
  `StreamingTTSPlaybackCore` (`852db44`) with `ChunkSchedule` audio-seconds
  pacing (8 s Kokoro / 10 s Supertonic) and a render-ahead bank that responds
  to thermal state.
- **Threads** (`f1101b2`): `setIntraOpNumThreads(min(activeProcessorCount, 6))`.
  The binding **does not expose** `setInterOpNumThreads` or
  `setIntraOpAllowSpinning` in ORTSessionOptions 1.24.2 — recorded as open
  items rather than faked.
- **Measured (device, A14, warm, foreground):** synthesis RTF ≈ **0.50**
  (chunk RTF 0.48–0.53) on fp32; TTFA 840 ms on a 12-char opener. The one
  device-log session with thermal degradation: **opened at RTF 0.47, closed at
  2.89** — thermal throttling detection was added to the session summary
  because of exactly that log (overall mean ≥ 35 % above first-quartile mean).

ORT CPU never produced a wrong output. Its sins are heat and battery — which
is the reason this project exists.

### 2.3 Attempt C — quantized tiers (the "silent wrong output" graveyard)

This is the most instructive part of the whole history for a Core ML plan,
because it is where **silent corruption actually lived** — and it lived in
*artifacts*, not runtimes.

| Tier | File / size | Verdict | Evidence |
|---|---|---|---|
| q8f16 | `model_q8f16.onnx` ≈ 82 MB | Shipped v0.6.1 → replaced v0.9.0 | No parity gate existed then; superseded before forensics |
| uint8 (weight-only + graph rewrite) | `model_uint8.onnx` ≈ 177 MB | **Corrupt — retired, deleted on launch** | Rel-RMS 1.3655, Pearson 0.0570 (0 lag); best of ±0.5 s lag search 0.0818 @ 480 samples — a *different utterance*, not a shift |
| fp16 | `model_fp16.onnx` | **NaN on ORT CPU — banned** | "The fp16 sibling (model_fp16.onnx) was spike-tested and produces **NaN on ORT CPU (CI 34008548349)**" (ModelManager.swift:66) |
| uint8f16 | ≈ 114 MB | Lost the 4-way bake-off | Spike (fp32 oracle vs uint8 177 MB vs uint8f16 114 MB vs quantized 92 MB) |
| **int8 dynamic** | `model_quantized.onnx` ≈ **92 MB** | **Shipped v1.8** ("Compact") | "equal-or-better spectral fidelity in 5 of 6 cases, and no NaN" vs the fp32 oracle |

**The uint8 forensics** (`87245df`, `f9b2558`, `UINT8-TIER-FORENSICS.md`) is
the repo's gold-standard debugging record, and its three controls are exactly
the gates a Core ML conversion must pass later:

1. **Determinism control** — same uint8 graph through two fresh ORT sessions:
   `0/92,400 samples differ, max delta 0, rel-RMS 0.000000`. **ORT CPU is
   bit-deterministic for this graph**, so any divergence between artifacts is
   real. (Also: rel-RMS 1.3655 identical to four decimals across runs two days
   apart.)
2. **Sanity control** — neither render was NaN/clipping: uint8 peak 0.6406 /
   RMS 0.0670 / 0 non-finite; fp32 peak 0.5611 / RMS 0.0678 / 0 non-finite.
   Both were loud, clean, finite, identical-length audio — two confident
   different utterances, which is the worst kind of silent failure.
3. **Byte-level artifact audit** — `model_uint8.onnx` is `producer onnx.quantize
   0.1.0` over a `pytorch 2.6.0` original and **is not the same graph**: it
   carries five nodes the fp32 graph lacks — `MatMul_6704_quantized`,
   `MatMul_6704_scale`, `MatMul_6886_quantized`, `MatMul_6886_scale`,
   `MatMul_6886_zero_point` (QLinearMatMul-style rewrites of two MatMuls) —
   where fp32 has `MatMul_6704` and `MatMul_6886`. Same token stream in, two
   different graphs out; duration prediction (shared path) stayed
   sample-identical in length while the waveform diverged.

Consequence recorded at the time: "this cannot be fixed by loosening the gate.
The gate is correctly reporting that the artifact is not the fp32 graph." The
CI gate was re-scoped from `testQuantizedRenderMatchesFP32` (correlation > 0.9 —
an impossible bar for the shipped artifact) to `testQuantizedRenderEvidence`
(finite + audible + length-stable, metrics printed, both WAVs kept), with the
original thresholds preserved at `60b75f6` for future re-quantization.

**Reframe for Phase 2 (important):** "fp16 is banned" and "uint8 is corrupt"
are **ORT-CPU + artifact** facts, not physics. fp16 ONNX NaNs on CPU EP because
CPU EP doesn't execute fp16 graphs natively; Core ML *wants* fp16. The hybrid
plan must re-open fp16 through the Core ML conversion gate, not inherit the ban.

### 2.4 Attempt D — Soprano (the non-Kokoro cautionary tale)

v1.7.0 added Soprano 1.1 (Qwen3 17-layer backbone + KV-cached audio decoder +
Vocos, 2048 samples/token @ 32 kHz, ~110 MB int8) via ONNX.

- **Runner vs device op support differs in both directions**: the CI spike
  "fails on the macOS runner every time (the **runner's runtime trips on an
  ONNX `Gather` op the device doesn't**)" — kept non-blocking as diagnostics.
  *A green runner is neither necessary nor sufficient for a green device.*
- **Shape-contract bug with a masked error**: ORT rejected step 0 on every
  chunk because the KV cache came back `[1, 1, 0, 512]` where the graph wanted
  `[1, 1, 0, 128]` (head_dim), "and the catch-all rethrew it as a bare
  **`missingOutput`** and the log was blind." Lesson recorded then: log the
  underlying error verbatim; never let a catch-all replace it.
- **Device verdict**: quality failed the user's ears after two rounds ("the
  model itself loops on-device"); sampling matched the reference, so the
  removal (`c3732c3`) was a *model* decision, not a runtime one.
- Note for Phase 2: the release notes floated "**a CoreML build**" as one of
  the possible spike workarounds. It was never attempted. The engine was
  deleted before any acceleration path was tried.

### 2.5 Attempt E — Supertonic (never tried off CPU)

Supertonic has, as the user remembered, "essentially never [been] tried on
Core ML" — the port (`663ce82`, from `Supertone/supertonic-3`, Helper.swift
vendored MIT) is 4 chained ORT sessions per chunk (`text_encoder 36.4 MB →
duration_predictor 3.7 MB → vector_estimator 256.5 MB → vocoder 101.4 MB`,
≈ 399 MB download) + a codepoint indexer (no G2P) + JSON voice styles.
Device data points: RTF ≈ **0.85 at rate 1.2** ("barely real-time" on A14,
HANDOVER.md:121–122); Supertonic skipped ~20 % of one EPUB via three
independent holes (indexer −1 ids → duration ≤ 0 → skip; vocoder returning a
few hundred samples short vs a strict length check; unlogged offending input) —
all fixed, none related to acceleration. "Balanced" tier (6 of 8 flow steps)
shipped 2026-10-09 as the quality/speed dial. Thermal is its recurring enemy:
the ChunkSchedule work was motivated by waits up to **8.5–13 s** between early
buffers, and the thermal-critical log showed **RTF 6.4**.

### 2.6 Attempt F — WhisperKit (the one Core ML success)

v2.0 STT (`ba7357a` → `e264349`) runs WhisperKit — which is **Core ML models,
downloaded at runtime** (`argmaxinc/whisperkit-coreml`) — on the same device,
under the same LiveContainer constraints. It works. Proof that: (a) `.mlmodelc`
bundle loading at runtime is fine here, (b) Core ML model *downloads* (not
app-bundled conversion) are fine here, (c) iOS 18+ Core ML on an A14 under
this distribution channel is viable end-to-end. The lesson is scoped: Whisper
is a hugely supported architecture (Apple ships the conversions); Kokoro is
not — conversion is our job.

---

## 3. The engines as they stand (the thing the hybrid must beat)

| | Kokoro fp32 | Kokoro Compact int8 | Supertonic (High / Balanced) |
|---|---|---|---|
| Runtime | ORT 1.24.2 CPU EP | same | same |
| Size | 325.5 MB + voices.npz + tokenizer.json ≈ 341 MB | ≈ 92 MB + shared files | ≈ 399 MB (4 sessions) |
| Chunk | 160 chars | 160 chars | 200 chars |
| Ahead cap | 3 chunks | 3 chunks | 2 chunks |
| Sample rate | 24 kHz | 24 kHz | per `tts.json` |
| Measured | RTF ≈ 0.50 warm foreground (A14) | same engine class | RTF ≈ 0.85 @ rate 1.2; thermal-critical 6.4 |
| G2P | MisakiSwift (ships MLX!) | shared | codepoint indexer |
| Voice bank | voices.npz via MLXUtilsLibrary `NpyzReader` | shared | JSON styles |

Correctness references that must survive Phase 5:
- **fp32 Kokoro through ORT CPU is bit-deterministic** across sessions — the
  parity oracle is trustworthy.
- The spike package `Tests/KokoroSmallSpike` already renders fp32-vs-tier on
  the runner and computes best-lag correlation / rel-RMS / peak-RMS-nonfinite —
  the Core ML parity gate can extend this exact machinery.
- Playback contract: `StreamingTTSPlaybackCore` + render-ahead bank +
  `ChunkSchedule` (audio-seconds targets 8 s / 10 s), silence bridge for
  background, stall watchdog. "Never block the audio render thread" is already
  structural.

---

## 4. Failure classification → (a) fixed now / (b) graph surgery / (c) fundamental

Using the user's classes: **(a)** fixed in current tooling/iOS 18, **(b)**
fixable via graph surgery (onnxsim, static/bucketed shapes, re-export),
**(c)** fundamental → split or stay on CPU.

| # | Historical failure | Class | Why / what changed |
|---|---|---|---|
| 1 | KokoroSwift dynamic framework → dyld kill in LiveContainer | **(a)** for Core ML specifically | Core ML + CoreML.framework are *system* frameworks — nothing to embed. The static-patch CI step also exists now. (MLX itself remains dynamic-shipped → patched.) |
| 2 | MLX metallib/bundle loading in xctest on runner | **(a)** | Job retired; a Core ML CI test loads compiled `.mlmodelc` — no metallib dance. Re-verify per test-target shape. |
| 3 | MLX GPU-cache growth → jetsam on long notes | **(c) for MLX path; (b)-shaped for Core ML** | Memory discipline exists now (played-buffer release, ahead caps, idle unload). For Core ML: activation arena + weight residency must be *measured* (benchmark harness, §6) — MLTensor/cached-specialization trade RAM for speed, and 4 GB is the wall. |
| 4 | 342 MB fp32 model resident on a 4 GB device | **(b)** | fp16 Core ML halves weights (~163 MB); MLProgram with fp16 + palettization behind a quality gate. This is exactly what the quantization forensics taught us to gate. |
| 5 | "too many tokens" per-call crash | **(b)** | Long solved (chunker + splitOversized). For Core ML: fixed/bucketed shapes re-raise it as a *shape* problem — bucket the 160-char chunk axis, pad, and keep the reconstruct invariant. |
| 6 | uint8 tier corrupt (graph rewrite by quantizer) | **(b)** | Don't use `onnx.quantize`-style rewrites; convert fp32→Core ML fp16 directly (graph preserved). Parity gate in CI kills it before device. |
| 7 | fp16 NaN on **ORT CPU** | **(a)** | That's CPU EP inability to run fp16 graphs, not a fp16 math problem. Core ML native fp16 is the *normal* path. Re-open under the Core ML gate. |
| 8 | ORT binding gaps (no inter-op threads, no allow-spinning) | **(a)** | If ORT CoreML EP is used, intra-op CPU threading matters less; if not, these remain open items on the CPU path. |
| 9 | Soprano spike `Gather` failure on runner, fine on device | **(a/awareness)** | Runner (macOS, x86_64-or-ARM ORT build) ≠ device ORT build ≠ Core ML runtime. Every parity decision must be made on the *device* or with the *same* runtime the device uses. |
| 10 | Soprano `missingOutput` error masking | **(a, discipline)** | Log underlying ORT errors verbatim; a catch-all must never replace them. Direct input to the hybrid engine's error surface. |
| 11 | "Core ML was tried and failed" | **N/A** | Never tried. Nothing in history invalidates ORT CoreML EP or coremltools MLProgram for these graphs. |
| 12 | Thermal throttling (RTF 0.47→2.89; 6.4 critical) | **(c) unless offload works** | This is the target, not a failure: A14 CPU cannot hold RTF under sustained load. ANE offload is the thesis; the harness must measure *sustained* RTF + thermal transitions, not peak. |

**Hypotheses carried into Phase 2 (community claims, unverified here, each
with its falsification vehicle):**

- **H1 — ORT's CoreML EP partitions Kokoro badly** (per-op CPU↔ANE round-trips
  make it slower than CPU, or explode on LSTM/ConvTranspose/Adain patterns).
  *Vehicle: Phase 4 CI conversion + provider log (`CoreML EP` fallback trace);
  Phase 5 on-device stage timing.* Note: ORT CoreML EP on iOS requires the
  runtime to have been **built with CoreML support** — resolved 2026-11-09
  (Phase 2, `Docs/PHASE2-OP-INVENTORY-PLACEMENT.md` §8): the official SPM
  binary (the `onnxruntime-c` pod archive) **is** built with `--use_coreml`,
  so the EP is available to the app as-is.
- **H2 — dynamic-axis respecialization thrash**: ANE specialization per shape;
  Kokoro's variable token length (per chunk) may trigger re-specialization or
  fall back to CPU. *Vehicle: bucketed static shapes (lengths we control) +
  pre-warm; measure first-N-chunk latency curve.*
- **H3 — fp16 artifacts in decoder/vocoder** (istftnet ConvTranspose/AdaIN
  precision). *Vehicle: Phase 4 numerical parity on fixed inputs vs the ORT
  fp32 oracle; the spike's best-lag correlation machinery reused as-is.*
- **H4 — ANE LSTM/GRU gaps** (duration predictor family) force splits.
  *Vehicle: op inventory on the actual graphs (Phase 2), then conversion
  behavior in CI.*

---

## 5. The four lessons the history actually teaches

1. **Memory is the killer on this device, not compute.** Plan A died of jetsam
   with RTF 0.5 in hand. Every Phase-5 step gets a memory budget line in the
   harness (resident + peak), and the acceptance criteria keep one.
2. **Silent wrong output is an *artifact* problem and CI-detectable.** Every
   corruption in this repo's history (uint8 graph rewrite, fp16 NaN) was
   caught on the runner, deterministically, with the right controls
   (determinism oracle, sanity bounds, byte-level audit). The Phase-4 parity
   gate is not optional plumbing — it is the mechanism that historically
   worked.
3. **Runner truth ≠ device truth** (Soprano `Gather`). CI kills *conversion*
   failures; only the device decides *speed, memory, thermal, quality*.
   Budget for both, and never let a red runner (or a green one) end the
   argument.
4. **The streaming/chunking substrate is battle-tested and is not to be
   rebuilt** — the user's constraint is confirmed by archaeology: the chunker
   exists because of the token-limit crash; the render-ahead bank and
   silence-bridge exist because of real background deaths; the determinism
   and evidence gates exist because of the uint8 grave. The hybrid plugs in
   *under* `SpeechEngine`/`StreamingTTSPlaybackCore` behind flags, exactly
   like every engine before it.

---

## 6. Evidence gaps (what no amount of git reading can produce)

- No on-device MLX numbers survived beyond comments (RTF ≈ 0.5; "model loaded
  in Ns" lines went to the device log only). If the MLX path is ever
  reconsidered, it starts from scratch.
- No memory numbers for any engine exist anywhere (TTS_BASELINE.md: "there are
  no recorded measurements … on a device" for RSS/thermal; the instrumentation
  exists, the session never ran). The Phase-3 harness baseline is therefore a
  prerequisite, not a nice-to-have — it was literally built for this and never
  used.
- ORT 1.24.2 SPM binary's CoreML-EP availability (H1a) is unverified.
- The `voices.npz` → per-voice `.bin` migration (PocketPal lesson) never
  happened; voice loading still goes through MLX's npz reader today.

## 7. Direct inputs to Phase 2 (op inventory & placement)

- Convert from the **fp32 graph** (`onnx/model.onnx`, pytorch 2.6.0 export,
  325,532,232 B, byte-pinned) — the int8/uint8 artifacts are off-the-table
  graph-rewrites; fp16 Core ML conversion preserves topology.
- Keep the ORT-CPU path byte-identical as fallback + parity oracle (it is
  bit-deterministic).
- The text frontend (Misaki G2P) and voice-slice prep are CPU-bound Swift —
  they are the "CPU does the glue" half of the hybrid, and removing their MLX
  dependency (catalog 1.11) is a cheap, independent win the hybrid makes
  *more* valuable (today every IPA still ships Metal machinery for npz).
- Supertonic's vector_estimator (256 MB) + vocoder (101 MB) are the biggest
  dense-compute targets in the app; its text_encoder/duration_predictor are
  tiny CPU-shaped heads — a natural split candidate *if* the big two convert.
- Bucketing axis: chunk token length (0…~510; we control it via chunkMaxChars
  160/200), so a small bucket set covers the real distribution; pre-warm at
  launch, as the plan already specifies.
