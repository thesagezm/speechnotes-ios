# Phase 3 — Benchmark harness: what it measures and how to run the baseline

**Deliverable 3 of the hybrid CPU + ANE plan.** The harness ships in this
commit; the BASELINE it exists to produce (a device run on the current
ORT-CPU build) is the first gate everything after it hangs on.

- Harness code: `App/Sources/Benchmark/` (+ `BenchmarkMath` in SpeechLogic
  with unit tests, + the `benchmarkPrepare`/`benchmarkSynthesize` seams on
  both neural engines).
- UI: Settings → **Diagnostics → Benchmark mode**.
- Postmortem / placement context: `Docs/POSTMORTEM-KOKORO-ACCELERATION.md`,
  `Docs/PHASE2-OP-INVENTORY-PLACEMENT.md`.

---

## 1. What a benchmark run does

**Sustained synthesis, no audio output.** The harness owns a fresh engine
instance (never handed to SpeechPlayer), loads its model (COLD — the load is
timed), chunks the fixed corpus with the tier's production chunker shape
(Kokoro 100/160, Supertonic 60/200), and loops that SAME chunk list until the
duration target elapses (checked between chunks; a stop lands between chunks
and still exports). Each chunk:

1. `benchmarkSynthesize` → samples are counted, then **dropped**;
2. a row is recorded: chunk #, loop #, wall s, chars, tokens (Kokoro) /
   steps (Supertonic), gen s, audio s, **RTF**, footprint MB, available MB,
   CPU %, thermal state.

A silent audio loop (`BenchmarkAudioKeeper`) holds the `audio` background
assertion, so you can **lock the screen** during a run — the benchmark then
measures synthesis, not suspension.

## 2. What it records

**Per chunk** — the CSV. Schema (header included in every file):

```
chunk,loop,wall_s,chars,tokens,steps,gen_s,audio_s,rtf,footprint_mb,available_mb,cpu_pct,thermal
```

**Per session** — the JSON:

| block | fields |
|---|---|
| Provenance | app version+build, device model, iOS version, ORT version (`1.24.2 (SPM pin)`), engine tier+label, intra-op threads (`default` or N), speed, mode, corpus id + **sha256** + chars |
| Timing | model-load s (always COLD on a fresh session), first-chunk s (the TTFA-equivalent), total wall/gen/audio s, RTF mean/median/p95, **RTF at 25/50/75 %** (temporal quartiles — the thermal-throttle shape), `throttleSignature` (mean ≥ 35 % above the first quartile's mean — the app's own Batch A rule) |
| Resources | CPU mean/max %, **CPU-seconds** (mean % × wall), footprint mean/max MB, available-min MB (the jetsam headroom), battery % + state start→end, thermal start→end + transitions with timestamps |
| Counts | chunks, loops, errors, first 5 error messages |

`os_proc_available_memory` + `phys_footprint` ride the same 1 Hz sampler as
CPU (the Phase-2 addition: "how close to the cliff are we" becomes a number,
not a crash report).

**Both files** land in `Documents/Exports/Benchmarks/bench-<UTC stamp>-<tier>.{csv,json}`
and are shareable from the Benchmark screen (Files app can also grab them).

## 3. Configuration (runtime-selectable)

| knob | values |
|---|---|
| Engine tier | Kokoro fp32 · Kokoro Compact int8 · Supertonic High (8 steps) · Supertonic Balanced (6 steps) |
| Duration | 1 / 3 / 5 / 10 min |
| ORT threads | engine default / 1 / 2 / 4 / 6 / 8 (the benchmark seam's `benchmarkIntraOpThreads` override; Kokoro's production policy is min(cores, 6), Supertonic's was previously ORT's unbounded default — noted as a finding) |
| Speed | 1.0 (fixed in v1; the field is in the config for later rate experiments) |

**Entry paths:** the screen's Start button, "Run at next launch" (the
device-side scripted entry — set config, toggle, relaunch), or CI/simulator
launch args: `-BenchmarkAutoStart -BenchmarkTier kokoro-fp32
-BenchmarkDurationSec 300 -BenchmarkThreads 4`.

Not yet selectable (they arrive with Phase 5, behind the same config):
engine ∈ {ORT-CoreML-EP, CoreML-direct, hybrid-split} and precision ∈
{fp16, int8}. The CSV/JSON schemas already carry the fields those
experiments will populate (`steps`/`tokens`, provenance block).

## 4. The baseline protocol (do exactly this, in order)

1. Charge ≥ 80 % (or full), then **unplug** (the battery row records the
   state so a plugged-in run is never mistaken for a drain run).
2. **Airplane mode** on; Wi-Fi off.
3. Auto-brightness OFF, brightness fixed (middle), True Tone whatever it is —
   then **lock the screen** after starting the run (the silent loop keeps it
   alive; screen-off is the comparable condition).
4. No playback of anything else; don't sit on the Benchmark screen after
   starting.
5. Run, per tier, in this order (one app launch each, airplane mode makes
   ordering irrelevant to anything else):
   - **kokoro-fp32 · 5 min · threads default** ← the headline baseline
   - kokoro-fp32 · 5 min · threads 4
   - kokoro-int8 · 5 min · threads default
   - supertonic-high · 5 min · threads default
   - supertonic-balanced · 5 min · threads default
   - repeat kokoro-fp32 5 min at the END of the session — the
     same-tier delta between run 1 and run 6 is the device's own heating
     history, not the engine's.
6. Export each run's CSV+JSON via the share sheet into Files → share back
   (or plug into the Mac-less sync path of choice).

Warm vs cold: every run's model load is COLD by construction (fresh engine
instance). A warm-load number comes from a back-to-back second run in the
same launch — do the runs 1→6 in one launch per tier if warm load matters
that day; the summary's `modelWasWarm` field is v1-false by design and the
protocol reads cold-load separately from synthesis numbers.

## 5. What the baseline decides (why this gates everything)

| number | decides |
|---|---|
| RTF per tier (+ temporal quartiles) | whether the stall is chunk-sizing or thermal (TTS_BASELINE §2's RTF ≳ 1.0 branch); the per-tier target for Phase 5 acceptance |
| throttleSignature + transitions | how early and how hard the A14 throttles under sustained CPU synthesis — the load the ANE thesis has to lift |
| CPU-seconds + battery %/min | the energy baseline; the Phase-5 acceptance criterion is measured against THIS |
| footprint mean/max + available-min | the real memory budget on the A14 under iOS 26.5 (§7 of the Phase-2 doc — no more community folklore) |
| token distribution per chunk | finalizes the Phase-2 bucket edges ({64…510} proposal → measured reality) |
| Supertonic threads=default | quantifies the unbounded-thread finding before the harness caps it |

## 6. Known limits (v1)

- **Synthesis mode only.** Pipeline mode (through SpeechPlayer with real
  buffers) reuses the Batch-A PlaybackMetrics instead and comes with the
  Core ML variants — the harness's numbers here are model numbers, which is
  what the engine choice needs.
- Apple system voice is not benched (its synthesis isn't ours to tune).
- Battery % is coarse (1 % granularity); CPU-seconds is the finer energy
  proxy — both are recorded, the acceptance criterion uses both.
- `coremltoolsVersion` in the JSON is nil on device (conversion is CI-side);
  Phase 4 writes it into the converted models' metadata, which lands in the
  same provenance block.
