# HANDOVER — Hybrid CPU+ANE plan, Phases 4→5 (2026-11-10)

## State in one paragraph

Branch `batch-c-d-session`. Phases 1–3 are DONE and CI-green: postmortem
(`Docs/POSTMORTEM-KOKORO-ACCELERATION.md`), op-inventory placement
(`Docs/PHASE2-OP-INVENTORY-PLACEMENT.md`), the Benchmark Mode harness
(`Docs/PHASE3-BENCHMARK-HARNESS.md`, code in `App/Sources/Benchmark/`), the
first measured baseline (`TTS_BASELINE.md` §8, raw files in
`Docs/benchmarks/2026-11-09/`), and the Phase-4 runner-side parity gate
(`.github/workflows/convert-parity.yml` + `Scripts/convert_parity.py`).
Two parity rounds have already settled the placement decisions; round 3
(run `42718617400`, commit `df68268`) was in flight at handover — READ ITS
RESULT FIRST (§3). The user's standing decisions: **no more benchmarking
runs for the baseline** (§8 is final; CPU %/footprint stay open until the
first Core ML variant reports them in-app), and the web-import workstream
(another agent) shares this checkout — its finished work is UNCOMMITTED in
the tree and must be committed SEPARATELY before anything of ours (§5).

## 1. Committed trail (all CI-green unless noted)

| sha | what |
|---|---|
| `b9e36b6` | Phase 1–3 docs (postmortem, placement, benchmark protocol) |
| `6caa998` | Benchmark Mode harness + engine seams + BenchmarkMath tests |
| `765759d` | compile round 1 (Codable on tier enum, `duration(to:)`, Double literals) |
| `ce8afd5` | **Baseline §8 + sampler fix — run 42712544580 all green** |
| `5c6b022` | Phase-4 parity workflow + script |
| `d543916` | push trigger on the parity files (dispatch API needs default-branch registration) |
| `a662c1c` | parity round 2 (run 42716891074 — failed on OUR script bugs, findings still valid) |
| `df68268` | parity round 3 (provider proof + decoder isolation) — **run 42718617400 in flight at handover** |

## 2. What the parity rounds already proved (runner-side, macOS ARM, onnxruntime 1.24.2 wheel)

| part | result | meaning |
|---|---|---|
| **B — Supertonic-3 chain via ORT CoreML EP** | **Pearson 1.0000, rel-RMS 0.0007, exact length (latent_len 742)** | The EP path is numerically PERFECT for the whole 4-model chain. **Supertonic ships via the EP — no conversion pipeline, no new artifacts.** |
| **A — Kokoro fp32 via EP (default units)** | **Pearson 0.6305, exact length** | A DIFFERENT UTTERANCE — the uint8-tier signature. The EP's internal fp16 corrupts Kokoro's math. **Kokoro must NOT ship via the EP with default (ANE-allowed) units.** |
| C — direct coremltools conversion | crashed: coremltools cannot ingest ONNX (source must be pytorch/tensorflow) | DEFERRED, recorded as skipped in the script. The onnx2torch route only pays if device EP perf disappoints. |
| A2 — Kokoro localization | round 2 inconclusive (my provider_options bug silently dropped the EP); round 3 re-runs it properly: EP pinned to `MLComputeUnits=CPUAndGPU` with ACTIVE-PROVIDER PROOF, plus the graph split at the first `/decoder/decoder/` node with both decoder sessions fed the SAME CPU pre-stage output | Read round 3's `parity-report.json` (artifact `convert-parity` on run 42718617400): if `whole_cpu_and_gpu` passes WITH `gpu_pin_active_providers` showing CoreML, ANE-fp16 is the sole culprit and a GPU-only EP variant of Kokoro becomes a legit Phase-5 experiment; `stage_pre_decoder` vs `stage_decoder` says whether the decoder alone is the casualty. |

Round-2 gotchas that are now FIXED in the script (do not reintroduce):
provider_options must align 1:1 with providers or ORT may silently drop the
CoreML EP (always log `session.get_providers()`); the report dict must not
reference itself (json.dump dies, summary step then reads a partial file);
the summary step survives a partial report.

## 3. FIRST ACTION: harvest round 3

```bash
gh run view 42718617400 --json conclusion,jobs --jq '.conclusion, (.jobs[] | "\(.conclusion // .status)\t\(.name)")'
gh run view 42718617400 --log | grep -E 'parity:|localization|active providers|boundary'
# artifact: run 42718617400 → convert-parity → parity-report.json
```

Interpretation table is in `Scripts/convert_parity.py`'s docstring. Then
update `Docs/PHASE2-OP-INVENTORY-PLACEMENT.md` §4/§8 with the outcome
(Kokoro: EP-with-defaults banned; GPU-pinned EP = open experiment).

## 4. Phase 5 — flagged implementation, in order

1. **Commit the web-import work FIRST, separately** (§5), so our commits
   stay clean.
2. **Verify the Swift binding's CoreML surface** (H1b): does ORTSessionOptions
   1.24.2 expose `appendCoreMLExecutionProvider` (flag-based, deprecated but
   present) and/or the new options (`MLComputeUnits`, `ModelFormat`,
   `SpecializationStrategy`, `ModelCacheDirectory`)? The headers live in the
   pod archive: `pod-archive-onnxruntime-c-1.24.2.zip` (SPM binary target;
   verified to contain the full CoreML EP — see Phase-2 doc §8). Re-download
   if `/tmp/phase2/ortpod/` is gone. Whatever the binding exposes decides
   how the session is built; the flag-based API is acceptable for v1.
3. **Supertonic CoreML-EP engine variant** (the shipping change):
   - `SupertonicEngine` gains a `usesCoreMLEP: Bool` (default false) that
     appends the CoreML EP to all FOUR sessions in `loadModelIfNeeded` —
     via the same `loadTextToSpeech` seam (add `useCoreML: Bool = false`
     param next to `intraOpThreads`; nil/pin decisions per the binding).
   - `BenchmarkTier` gains `supertonicHighCoreML` / `supertonicBalancedCoreML`
     (labels "(Core ML EP)"); `BenchmarkSession` builds the engine with the
     flag. This makes the harness the measurement instrument for the
     variant — the user's "no more benchmarking" decision bars RE-running
     the CPU baseline, not measuring the NEW variants (that is the plan's
     acceptance mechanism).
   - Normal playback gets a flag too (SpeechSettings row behind
     `UserDefaults`, default OFF until the device round passes): engine
     variant selection must stay runtime-selectable, ONE build.
4. **Device round for the EP variant**: Benchmark Mode runs (supertonic
   EP vs CPU back-to-back) — read RTF mean/drift, thermal transitions,
   and NOW WORKING footprint/available columns (sampler fixed in
   `ce8afd5` — first Core ML sessions finally answer the §8 memory-budget
   open item). Listen for parity by ear (runner says the math is perfect;
   the device could still surprise via ANE dispatch differences).
5. **Kokoro**: stays CPU (tuned). Optional next experiments, in value order:
   GPU-pinned EP variant IF round-3's A2 shows the GPU pin holds parity
   with CoreML active; otherwise the onnx2torch decoder-split (deferred —
   `Scripts/convert_parity.py` §C has the reasoning).
6. **Thermal policy integration**: the render-ahead bank already responds
   to thermal; the EP variant should not bypass it. Nothing new to build —
   just verify the variant obeys `RenderAheadBankPolicy` (it does, same core).

## 5. The parallel workstream — handle with care

Another agent's FINISHED web-import work is sitting UNCOMMITTED:
`App/Sources/Services/WebArticleService.swift`, `ImportService.swift`,
`Views/NotesListView.swift`, `README.md`, `App/Resources/JS/html-to-markdown.js`
+ `VENDOR-NOTES.md`, `Scripts/test-html-to-markdown.js`,
`Docs/WEB-ARTICLE-IMPORT.md`, `.github/workflows/build.yml`, `project.yml`,
**and a new `ShareExtension/` directory + target**.

- Commit it as its OWN commit (user's instruction: that work is done).
- ⚠️ **VERIFY ShareExtension against the LiveContainer constraint first**:
  the repo's founding constraint is "LiveContainer: no app extensions"
  (`Docs/PLAN.md` §2). If the share extension cannot work under
  LiveContainer, either drop the target from project.yml or gate it — ask
  the user. Do not silently ship a build that regresses LiveContainer.
- Never mix our TTS files with theirs in one commit. `git add` by path.
- PROGRESS_LOG and project.yml are shared files — re-read before editing
  (a linter/another agent may have touched them mid-session; both have
  collided once already).

## 6. CI mechanics (unchanged but easy to forget)

- `build.yml` triggers on push to **main/sage-upgrades only** — for our
  branch: `gh workflow run build.yml --ref batch-c-d-session`.
- `convert-parity.yml` triggers on push touching ITS OWN files, or manual
  dispatch once registered (it may now be registered — try
  `gh workflow run convert-parity.yml --ref batch-c-d-session`).
- No local Swift; CI is the compile oracle; budget one compile round.
- Keep `main` untouched — releases are user-gated (repo golden rule).

## 7. Acceptance criteria, as amended by the no-more-benchmarking decision

- **Supertonic EP variant**: on-device Benchmark session shows RTF ≤ the
  CPU tier's §8 numbers (0.527 High / 0.493 Balanced) or wins on the
  thermal/energy axis (drift + footprint), with NO audible difference from
  the CPU tier (runner parity says the math is identical) and thermal never
  escalating past `serious` where CPU didn't.
- **Memory**: the variant's session JSON reports footprint + available —
  closing the §8 open item regardless of RTF outcome.
- **Kokoro**: unchanged behavior on CPU (§8 numbers are its baseline); any
  Kokoro acceleration experiment must pass the same in-app parity-by-ear +
  drift comparison before shipping.
- Ship nothing that fails its own `parity-report` evidence; the B4-gate
  discipline applies to every future conversion.
