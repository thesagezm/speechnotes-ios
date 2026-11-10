# HANDOVER — Phonon TTS: the position recipe is still wrong (device: artifacts after ~4 words)

> **STATUS (2026-11-11): EXECUTED.** The recipe below was verified against `/tmp/xn-ptts`
> ground truth (`qnn/runner/phonon.cpp`, `transformer.rs`, `synth.rs` — all agree), proven in
> `/tmp/phonon-diag/position_recipe_ab.py` (call-1 latents bit-identical; re-run prompt-row KV
> drift across calls 9-10 → 0.0 bitwise; 8-seed renders no-regression), shipped to
> `PhononEngine.swift` + the spike mirror, and `Docs/PHONON-PORT.md` corrected. See the
> PROGRESS_LOG entry from this date. The "next steps" below are kept as the historical brief.

Branch `batch-c-d-session`. Read this before touching `PhononEngine.swift`.

## State

- **Shipped and confirmed**: commit `49e8ab7` fixed the catastrophic repeat spiral — the KV
  feedback copied a contiguous float prefix of the `[1, heads, seq, dim]` cache (head-major!),
  so from call 1 the model attended garbage. Now the feedback walks the heads and keeps
  `[0, past) ++ [past+P-1, end)` (the prompt block's input-slot row kept; KV grows +8/call ==
  latent history; one counter). CI run 42903874020 green; the device log (see PROGRESS_LOG
  entry 2026-11-10) shows every chunk now crossing EOS sharply at natural ends.
- **Still broken**: the user reports the latest build is "much much better" but after ~4 words
  there are repetitions/artifacts/whispering — unusable for real TTS. 4 words ≈ 20-25 frames ≈
  calls 2-3. The EOS/length bookkeeping is healthy; the latents themselves degrade mid-chunk.

## The #1 suspect (derived this session, NOT yet tested): the re-run prompt block's positions

The graph (trace proven on `model.onnx`, see `/tmp/phonon-diag/graph_trace*.py`):
- Each call's sequence = `[past KV rows | prompt block P | 7 frame positions]`.
- `Slice_29 = position_ids[0:P]` → the whole prompt block; `Slice_199…1219 = position_ids[P+k]`
  → frames 1-7. Nothing requires `position_ids` values to be CONTIGUOUS.
- `Slice_8 = Concat[bos_latent | past_key_values.audio_latents][-1:]` → only the LAST latent of
  the fed-back history feeds the prompt block's LAST row (the input slot). On call 1 (empty
  history) that row is the learned `bos_latent`. The past KV keeps its baked RoPE.
- Output `audio_latents` = cumulative denormalized (input rows + 8); `present.audio_latents` =
  normalized, fed straight back. The decoder (`mimi_decoder.onnx`) is stateless, windows ≤160.

The reference runtime (see below) is: **text+voice prompted into the KV ONCE per chunk
(`prompt_text`), then ONE latent per step, cache grows +1/step, RoPE offset = cache length
(`current_end`), FlowLm cache NEVER trimmed, positions contiguous `0,1,2,…"`.** So in the
reference, the voice+text rows live at absolute positions `[0, P-2)` FOREVER and latent `L_i`'s
input row sits at position `P+i-1`, generating `L_i` from it.

The shipped engine feeds `position_ids = arange(past_kv, past_kv + P + 7)` — so the re-run
voice+text rows ride the moving timeline (8 positions too far along by call 2, 16 by call 3…).
The prompt rows' K/V values are identical to the reference's cached rows (embeddings are
deterministic), but their RoPE offsets are wrong and grow every call. That matches the device
symptom exactly (first words fine → artifacts once calls 2-3 accumulate). The doc
(`Docs/PHONON-PORT.md`, KV feedback section) claims this deviation is "unavoidable" because the
input slot is welded to the prompt block's end — **that claim is wrong**: `position_ids` may be
non-contiguous. The reference-exact recipe is:

```
position_ids = concat(arange(0, P-1),                 # voice+text re-run at TRUE absolute positions
                      arange(P + n - 1, P + n + 7))   # input slot at P+n-1, then the 7 frames
# n = pastKVCount (grows +8/call). Call 1 (n=0) degenerates to the current contiguous form.
```

Distances then match the reference exactly (query at `P+n+k-1`: voice+text at `P+n+k-1-p`,
input slot at `k`, baked latents at `n+k-1-i`). Causality preserved (queries always at higher
positions than keys). Keep the current KV feedback policy unchanged — only `position_ids`
changes (a ~3-line change in `PhononEngine.generateChunk` + the spike mirror).

## Ground truth on disk (use it, don't re-derive)

- `/tmp/xn-ptts` — clone of **gradium-ai/xn-ptts**, the ORIGINAL runtime (Rust, Apache) that the
  hub validates >70 dB against. Read in this order:
  - `ptts/src/transformer.rs` — `StreamingMHAState::complete_kv` (append, `current_end`),
    `RotaryEmbedding::new(head_dim, offset=current_end, …)` (RoPE offset = cache length),
    `KvCache::trim` (Mimi-only; FlowLm never trims).
  - `ptts/src/flow_lm.rs` — `backbone()` (concat text_embeddings + input, strip prefix),
    `sample_next_latent_parts` (one latent per step), EOS head.
  - `ptts/src/synth.rs` — `Flow::start` (line ~1233: `model.prompt_text(&mut state, tokens)`
    — text cached ONCE per chunk) → `Flow::step` (`StepInput::Bos/Latent`, one position);
    `run_backbone` (line 1319); `seq_budget = text + prompt + headroom` (line ~814) — proves
    the text is NOT re-cached per step (budget would be text×frames otherwise).
  - `ios/PhononTTS/` — Gradium's OWN iOS implementation (Swift). `Phonon.swift` may show how
    they drive a CoreML/ONNX export on device — the closest thing to an official export driver.
  - `qnn/runner/phonon.cpp` — their QNN runner; may encode the same call contract for a
    graph-export runtime.
- `/tmp/phonon` — the pinning workspace: fp32 ONNX set, `tokenizer.json`, voices, and the
  previous session's scripts. **`/tmp/phonon/final.py` + `contract.py` append the CUMULATIVE
  `audio_latents` per call (`lat[-8:, :]` slices the BATCH axis) — their rendered WAVs
  (`out-*.wav`) are duplicated-history artifacts. DO NOT trust them as quality evidence.**
- `/tmp/phonon-venv` — Python 3.12 with onnxruntime 1.24.2, numpy, tokenizers, onnx.
- `/tmp/phonon-diag/` — this session's verified scripts:
  - `verify_offset.py` (kv vs hist offset, FIXED appending: `lat[:, -8:, :]`),
  - `variant_matrix.py` / `seed_sweep.py` / `long_chunk_test.py` (46 clean runs on x86 —
    note: clean METRICS, nobody listened; whisper/artifacts may not show in these metrics),
  - `graph_trace*.py` (the graph wiring proof),
  - `verify_fix.py` (validates the Swift per-head copy math == numpy; renders audition text),
  - `analyze_wav.py` (duration/self-sim/flatness; flatness band miscalibrated — relative
    comparisons only).

## Next steps (in order)

1. Implement the non-contiguous `position_ids` recipe above in `/tmp/phonon-diag/` Python
   (copy `variant_matrix.py`'s speak loop; change only the position_ids construction; compare
   shipped vs reference-exact on the audition text + a 200-char chunk, 6-8 seeds, same seed
   both variants). Expect: identical call-1 latents, divergent later calls.
2. Check `ios/PhononTTS/Sources/PhononTTS/Phonon.swift` + `qnn/runner/phonon.cpp` for the
   official export-driver's position/KV policy — if it disagrees with the recipe, THE FILE WINS.
3. If Python metrics can't separate the variants by ear-proxy, consider a torch parity gate:
   the Rust runtime's own tests use `ReplayRng` (replay a fixed noise sequence) — the cleanest
   cross-implementation comparison is replaying ONE noise sequence through (a) the Rust runtime
   (`cargo run` on this box, needs `ptts` crate build) and (b) our Python loop on the ONNX
   graph, comparing latents frame-by-frame. Cheaper proxy first: zero-noise determinism
   (`do_sample=False` equivalent: noise=zeros) — both should produce deterministic latents to
   compare directly against each other.
4. Ship to `PhononEngine.swift` + `Tests/PhononSpike/…/PhononSpikeTests.swift` (mirror exactly),
   update `Docs/PHONON-PORT.md` (KV feedback section — remove the "unavoidable" claim, document
   the reference recipe + xn-ptts provenance), append a PROGRESS_LOG entry, commit, push,
   dispatch CI: `gh workflow run build.yml --ref batch-c-d-session`, then watch:
   `gh run watch <id> --exit-status`. Spike log lines `PHONON-SPIKE call N: past_kv=… eos=…`
   are the health signature (deep negative → sharp spike at the end; `past_kv` must step +8).
5. Device round: reinstall, one audition + one long note. If artifacts persist, get
   Settings → Logs → filter "PhononEngine" — the per-chunk line carries
   `eos peak X.XX at call N` + frame counts (engine logs `… frames, N calls …, eos peak …`).

## Secondary threads (do not lose)

- **Device RTF degradation**: device log shows early-session chunk RTF 0.18-0.26 but late in
  sessions up to 2.7 (chunk 6: 6 calls in 10.41 s; "bank hold extended — main thread stalled";
  keepalive bridges 11-20 s of bridged silence; T2B margins SHORT). Suspects: thermal
  throttling, decode RSS spikes (~2.7 MB/latent, 160-latent window ≈ +430 MB), main-thread
  congestion. Cheap next step: add `ProcessInfo.processInfo.thermalState` (+ memory footprint)
  to the per-chunk completion log so the next device log discriminates. (`ProcessMemory.summary()`
  exists in `App/Sources/Services/CrashMarker.swift`.)
- `AVAudioSession setCategory … Code=-50` errors with a Bluetooth route are pre-existing,
  engine-agnostic (Kokoro logs them too), handled by the fallback line after them.
- Engine constants all verified against the checkpoint configs: temperature 0.3, eos_threshold
  4.0, frames_after_eos 1 (3 for ≤4 words), budget ceil((T/3+2)*12.5)×1.5. Don't touch.
- CoreML EP stays banned for Phonon (round-3 parity ban; Supertonic ships via EP behind the
  "Render with Core ML (experimental)" toggle — that's the answer to the user's "Core ML like
  Supertonic?" question).
- Version stays per the release policy (the user bumps MARKETING_VERSION).

## The user's current report (verbatim intent)

"Latest build performing much much better with Phonon TTS, but after 4 words repetitions or
artifacts or some whispering — not as bad as it was but still unusable for TTS right now."
