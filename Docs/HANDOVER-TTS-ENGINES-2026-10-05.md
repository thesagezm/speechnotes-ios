# HANDOVER — 2026-10-05, session `sess_13fdc1a4-c7a2-4d96-9e1e-df38caf110d4`

## State, in one paragraph

Branch `batch-c-d-session`, HEAD **`c7dab7a`**, pushed to origin, CI dispatched
as run **`37341942646`** (result not yet visible at handover). Eighteen commits
since the session started at `5d60552`. Batches A1, A2, A3, B1/B2, C1/C2, D and
F1 are implemented and committed; **Batch E, B3/B4, F2, G are not**. CI has been
red on every single run this session — five of them — and every failure was
either a compile error in code that had never been compiled before (dead
substrate) or a wrong expected value in a test I wrote from my model of the
arithmetic rather than from the arithmetic. Both are cheap to hit and cheap to
fix; the pattern is worth carrying forward.

---

## What shipped

| Batch | Commit(s) | What |
|---|---|---|
| A1 | `0bea095`, `e3c2851` | Kokoro tokenizer proofs in `Tests/KokoroSmallSpike`: normalizer lemma (class == vocab, both directions), phoneme corpus (drop rate 0), note corpus through the reference normalizer, 28-voice npz assertion, new unsafe corpus pinning B1's drop surface. Fixed `am_fenfir` → `am_fenrir` in `ModelManager.knownVoices` + `VoiceCatalog.irregularNames` (that voice was silently unselectable). CI keeps the whole npz and uploads `corpus-*.wav`. |
| A2 | `112d7ad` | New `SystemSpeechMetrics` — Apple's chunk boundary (`didFinish` → `didStart`), session begin/end, rate-limited logging. `SystemEngine` gains two `ContinuousClock` stamps; stamp dropped on pause/resume/rebuild/stop so those are never counted as gaps. |
| A3 | `29c70f9` | Tier tag through `PlaybackMetrics` (derived from the model FILE, not a caller flag), printed on session start, model-ready and the RTF summary. `TTS_BASELINE.md` §2/§4/§6 updated. |
| B1/B2 | `409a956`, `991fb31` | `tokenize` substitutes a space for un-vocabbed characters instead of deleting them, counts them, logs the offending set; engine-scoped pre-pass maps `-`/`'` to spaces. Style row is now `clamp(phonemeChars - 1, 0, rows - 1)` — upstream's `pack[len(ps)-1]`, two rows more than the old kokoro.js `-2` port. |
| C1/C2 | `f1101b2`, `4e2b0b4`, `e2dd245`, `43572ed` | `setIntraOpNumThreads(min(activeProcessorCount, 6))`; the two options the binding does not expose (`setInterOpNumThreads`, `setIntraOpAllowSpinning` — absent from `ORTSessionOptions` in 1.24.2) recorded as open items rather than faked. `RenderAheadBankPolicy.pressureFactor` (1.0/1.0/0.5/0.25) + `pressuredTargetSeconds`, wired into `recomputeBank`; labelled as granularity, not throughput. |
| D | `e3b6c4e`, `b875b1e`, `dc8b820` | `ChunkCachePolicy` (pure, 19 tests) + `ChunkCacheLayout`. `ChunkFileQueue` — the AVQueuePlayer substrate, **ships dead, nothing routes through it**. |
| F1 | `26af724`, `c7dab7a` | Apple's inter-sentence gap: 4-deep lookahead into `synthesizer`'s own queue, filled from BOTH `didFinish` and `didStart`. Epoch guard on all three delegate callbacks (was only `epoch > 0` in `didStart`). Voice cached per session. Rate re-queue debounced to 250 ms. `AudioSessionSetup.Source.bluetoothOptions`: HFP for `.tts`, A2DP for `.audiobook`. |

Critique loop: two independent passes ran (A2/A3 → 7/10, A1 → 6.5/10); both
rounds' fixes are committed. Verdicts are NOT yet in `CRITIC_REVIEWS.md` — see
below.

---

## Open, in priority order

### 1. A2/A3 critique findings that are still unfixed
The 7/10 pass listed two P1s (fixed), six P2s, four P3s. **Fixed:** tier on the
summary line, `sessionTier` live, `tierName` no longer mislabels non-uint8 as
fp32, `emit` honours `isError`, `didFinish → didStart` labelled honestly,
`boundaries 50/41` doc example recomputed (N chunks → N−1 boundaries), §6 work
table extended with A2's three sites.
**Still open from that pass:**
- `SystemSpeechMetrics` has no injectable `sink` (parity with `PlaybackMetrics`)
  — noted, deferred to Batch F which rebuilds the class.
- GAP escalation is unbounded (~638 lines worst case for a 200k-char chapter) —
  recorded in `TTS_BASELINE.md` §6 as the known worst case, not capped.

### 2. A1 critique findings
The 6.5/10 pass found the delivery mechanism was broken and the proofs could
fake themselves; **that whole round is fixed** (`e3c2851`). Still open:
- The note-corpus test is near-vacuous as a drop detector (class == vocab makes
  the two filters identical). Its value is the boundary claim; doc comment says
  so now. Left as is deliberately.
- The npz walk is O(n) over 14 MB (0.011 s measured) with a false-positive
  window. Accepted: a junk name can only cause a false negative.

### 3. **The build.** Run `37341942646` is the first that could plausibly go
green — but do not trust that. If `build-ipa` fails again, `gh run view --log-failed`
and read the `error:` lines first; every failure this session was found that way.
The known-fixed errors are: `ChunkFileQueue.swift:99` mutating on a `let` URL;
`SystemEngine.swift:397` `AVSpeechSynthesisVoice(language:)` returning optional.

### 4. `CRITIC_REVIEWS.md` has no entries for this session
The plan says each batch's verdict goes in the file's existing format
(`## <Batch> — Round N (diff <sha>, …)`, `**Score: N/10. Faster than baseline:
YES/NO …**`, numbered findings, `**Build gate: <run-id>**`). **This is the single
biggest documentation gap.** The next un-numbered slot per the file's own
numbering is Batch C, superseded by this work — the first entry should be
`## TTS Engines — Batch A1 — Round 1 (diff 0bea095)`.

---

## Next batches, in the plan's order

- **B3** — `firstMaxChars: 100` in `OnnxKokoroEngine.swift:95`. Needs A3's measured
  RTF from a device session; if RTF ≥ 1.0, implement `TTS_BASELINE.md` §2's bounded
  prebuffer gate instead (hold `playerNode.play()` until the second buffer lands
  or 1.5 s).
- **B4** — quantization gate in CI, only if A1 exonerated the tokenizer (it did).
  Compare uint8 vs fp32 renders of the same corpus.
- **E** — Kokoro + Supertonic onto `ChunkFileQueue`, ~50 lines per engine. Retires
  the render-ahead bank for those two (keep observers, watchdog, metrics, skip
  policy, `isExporting`, WAV export). Rate = **hybrid**: player-side `.spectral`
  immediately, producer regenerates at native rate from the purge point, replacing
  stale files as they land. Gate: lock screen mid-chapter on all three neural
  engines for a full chapter.
- **F2** — `AVSpeechSynthesizer.write(_:toBufferCallback:)`, gated on A2's numbers.
  Abort hatch is F1's look-ahead queue, which already shipped, so F2 is genuinely
  optional.
- **G** — `AudioBookPlayer.handleMediaServicesReset` auto-resume (drop it, Apple
  says don't); `BookmarkStore.persistNow()` off-main **plus** its throttle bug
  (`lastPersist` is never stamped, so the 1 Hz throttle is dead code and every
  playback tick writes); docs.

---

## Lessons worth not re-learning

1. **Test expectations come from the arithmetic, not from my memory of it.** Two
   CI failures this session were my own wrong expected values (`RenderAheadBank`
   pressure composition, `trimmedSampleCount`). Both caught by CI before a phone
   saw either. Simulate in a scratch script before writing the assert.
2. **Dead code has no compiler.** Batch D shipped unwired, and `ChunkFileQueue`
   had three compile errors only CI could see. That is still cheaper than the
   alternative, but budget for one compile round.
3. **`$HOME` is not expanded in a GitHub Actions step `env:`.** Use
   `${{ github.workspace }}` expressions.
4. **The user's standing instruction:** critique runs inline at full rigor, with
   exactly one independent general-purpose pass per batch as a second opinion.
   Verdicts go to `CRITIC_REVIEWS.md`. The user has also asked (2026-10-05) that
   the next independent critique run **after** the builds are green and the
   advised revisions are in, and that critics be told to be faster.

## Working tree

Clean at `c7dab7a`. No local Swift toolchain on this box — CI is the only
compile oracle for anything under `App/Sources`; `logic-tests` covers
`Packages/SpeechLogic`.
