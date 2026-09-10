# TTS Baseline — SpeechNotes

Status of this document: **there are no recorded measurements.** Nothing in this
repository has ever been benchmarked on a device, and no benchmark numbers exist
in the git history, the docs, or the issue tracker. Every figure below is either
(a) arithmetic derived from code that can be read, or (b) a placeholder waiting
for the first device session with the Batch A instrumentation installed.

That is the reason the instrumentation exists. This document states the model,
states what the model cannot know, and defines the protocol that turns the model
into numbers.

---

## 1. What the pipeline actually does

Read from `StreamingTTSPlaybackCore.speak(_:)` and the producer loop:

1. `SentenceChunker.chunks(for:firstMaxChars:batchMaxChars:)` splits the text.
   The core passes **the same value for both parameters** — 160 for Kokoro, 200
   for Supertonic (`config.chunkMaxChars`).
2. Chunk 0 is `firstChunk(in:maxChars:)` — **exactly one sentence**, capped at
   the limit. Chunks 1…n are greedily packed whole sentences up to the same
   limit.
3. The producer runs on `generateQueue` and generates up to
   `generationAheadLimit` chunks ahead (Kokoro 3, Supertonic 2) before blocking
   on a pacing semaphore. The first `generationAheadLimit` chunks therefore
   generate back-to-back with **no wait at all**.
4. Each finished buffer is scheduled on the main thread. The first schedule flips
   `.generating` → `.speaking` and calls `playerNode.play()`.
5. There is **no prebuffer gate**. Playback starts the instant one buffer exists.

Point 5 is the whole first-stall problem, and point 2 is why it bites.

---

## 2. The stall model

Three parameters:

| Symbol | Meaning | Value |
| --- | --- | --- |
| `cps` | chars of text per second of generated audio (speech rate) | ~15 for English narration at speed 1.0 (150 wpm × ~6 chars/word). Range 12–18. **Unmeasured.** |
| `RTF` | generation seconds ÷ audio seconds | **Unmeasured.** The instrumentation reports it as `synthesis RTF`. |
| `c0`, `c1` | UTF-16 length of chunk 0 and chunk 1 | `c0` = one sentence (4…limit). `c1` ≈ limit (160 Kokoro, 200 Supertonic). |

Derived:

```
audio(c) = c / cps
gen(c)   = RTF · c / cps

TTFA     ≈ gen(c0)                      # first buffer scheduled
T2B      ≈ gen(c0) + gen(c1)            # chunks 0 and 1 never wait on pacing
dead air = max(0, T2B − TTFA − audio(c0))
         = max(0, gen(c1) − audio(c0))
         = (1/cps) · max(0, RTF·c1 − c0)
```

**Break-even: `c0 ≥ RTF · c1`.** Below it, the listener hears silence for
`(RTF·c1 − c0)/cps` seconds between the first sentence ending and the second
starting.

### What that means per engine

Kokoro, `c1 ≈ 160`:

| RTF | break-even `c0` | consequence |
| --- | --- | --- |
| 0.5 | 80 chars | any first sentence under ~80 chars stalls |
| 0.8 | 128 chars | most first sentences stall |
| 1.0 | 160 chars | `c0` must equal `c1` — the fast-start premise is dead |
| 1.5 | 240 chars | **above `batchMaxChars`**: no `firstMaxChars` value can fix it |

Supertonic, `c1 ≈ 200`: break-even `c0` = 200·RTF, so 100 chars at RTF 0.5,
unstoppable above RTF 0.8.

Two things fall out of this table, and they are the reason Batch C is two fixes
rather than one:

- **At RTF ≲ 0.6 the stall is a chunk-sizing problem.** Raising `firstMaxChars`
  from "one sentence" to a *pack target* of ~85 (Kokoro) / ~105 (Supertonic)
  clears it. Those constants are exactly `RTF·c1` at RTF ≈ 0.53, which is the
  plan's assumed foreground RTF — the model reproduces the chosen numbers.
- **At RTF ≳ 1.0 the stall is not a chunk-sizing problem at all.** No legal
  `firstMaxChars` reaches break-even, because break-even exceeds the batch cap.
  Only the **bounded prebuffer gate** — hold `playerNode.play()` until the second
  buffer is scheduled or ~1.5 s elapses — helps, and it helps by trading a known
  fixed delay for an unknown dead-air gap.

So the RTF measurement is not a nice-to-have. **It decides which of the two
Batch C fixes is load-bearing**, and if measured RTF differs materially from
0.5, the chunk constants are the dial to retune.

### The `c0` distribution is itself unknown

A notes app's first sentences skew short, and the chunker treats newlines as hard
sentence boundaries — so text beginning with a Markdown heading or a list item
may yield a chunk 0 of a handful of characters. Whether that happens on the real
play path depends on which extractor feeds `speak()` (notes go through
`MarkdownText.plainText`, which may already strip headings; books go through
`XhtmlText`). **Not resolved here.** The instrumentation settles it directly: the
session-start line logs `chunk 0 is N chars` for every play, so a device session
yields the real distribution instead of a guess.

---

## 3. What TTFA does not include

`metrics.beginSession` stamps t0 at **core `speak()` entry**. Everything the app
does before that is outside the number, and it is not nothing:

| Excluded | Where | Why it matters |
| --- | --- | --- |
| Model-file validation | `OnnxKokoroEngine.speak()` / `SupertonicEngine.speak()`, main thread | Runs *before* `core.speak()`. Kokoro: three `attributesOfItem` syscalls plus reading and JSON-parsing `tokenizer.json`. Supertonic: roughly sixteen syscalls across four ONNX sessions. **Measured separately** by `PlaybackMetrics.timedValidation` and logged as `play-path file validation Nms` — it is not lost, it is just not inside TTFA. |
| Text extraction | `MarkdownText.plainText` / `XhtmlText` / `PdfText` | A whole EPUB chapter's XHTML parse sits upstream of a book's TTFA. Not instrumented in Batch A. |
| The cold model load | `loadModelIfNeeded()` on `generateQueue` | This one **is** inside TTFA — it happens after t0. It is separated out by the `model-ready Ns (COLD/warm)` line so a 25 s cold TTFA is not read as a 25 s pipeline TTFA. |
| Chunking | `SentenceChunker.chunks(for:)` inside core `speak()`, after t0 | Inside TTFA. Includes the O(n²) `utf16Offset` walk that Batch C removes; on a 200k-char chapter that walk is not free. |
| UI → player dispatch | `SpeechPlayer`, `BookPlaybackController` | Whatever the tap handler does before reaching the engine. Not instrumented. |

**A measured TTFA is therefore a lower bound on tap-to-audio**, and the gap
between the two is exactly what `play-path file validation` plus the unmeasured
extraction and dispatch cost. When comparing TTFA across builds, hold the note
constant or the extraction term dominates.

Also excluded from TTFA, by construction: time blocked on the pacing semaphore.
Chunks 0 and 1 never block, so this does not affect TTFA or T2B — but it does
mean `synthesis RTF` describes the model and not the pipeline. See §5.

---

## 4. What is measured, and how to read it

Filter the Logs tab (or an export) to the string `metrics`. A healthy warm
session on a short note looks like:

```
OnnxKokoroEngine metrics play-path file validation 1ms → valid
OnnxKokoroEngine metrics session start — 4 chunks, chunk 0 is 12 chars, rate@start 1.00
OnnxKokoroEngine metrics model-ready 0.00s (warm)
OnnxKokoroEngine metrics TTFA 840ms — first buffer scheduled (12 chars → 0.80s audio)
OnnxKokoroEngine metrics T2B 6100ms — second buffer 5260ms after the first; the first was 12 chars / 0.80s of audio → margin -4460ms (SHORT — audible silence)
OnnxKokoroEngine metrics chunk 1/4 — 12 chars → 0.80s audio in 0.41s (RTF 0.51)
OnnxKokoroEngine metrics chunk 2/4 — 158 chars → 10.53s audio in 5.26s (RTF 0.50)
OnnxKokoroEngine metrics session finished — 4 chunks (0 skipped), 32.10s audio, 16.02s gen, synthesis RTF 0.50 [chunk RTF 0.48–0.53], TTFA 840ms, T2B 6100ms, gaps 1 (worst 0.31s, lower bound), wall 33.04s incl. 0.00s paused across 0 pause(s), rate@start 1.00
```

That `margin -4460ms` line is the first-sentence stall, measured, with its cause
visible on the same line: 12 chars of first chunk against 5.26 s to build the
second.

Reading rules:

- **`margin` is the verdict on Batch C.** Positive = covered. Negative = the
  number of milliseconds of silence the listener hears.
- **`synthesis RTF`** is model throughput, not pipeline efficiency. It excludes
  pacing-gate waits (the stamp is taken after `pacingGate?.wait()`) and includes
  retry back-off sleeps (`Thread.sleep(0.15 · attempt)`) — so a session with
  retries reads worse than the model actually is. Per-chunk RTF range is printed
  beside the mean for exactly that reason.
- **`gaps N (worst X, lower bound)`** — a lower bound twice over: both stamps are
  main-queue events, not render-callback events, so each carries dispatch
  latency; and a drain across a pause/resume is dropped.
- **`wall` includes every pause** and counts through device sleep. Do **not**
  divide it by the `audio` figure beside it. Use `synthesis RTF`.
- **`RTF at 25%/50%/75%`** lines appear only for sessions of ≥16 chunks.
  Comparing them answers the one question per-chunk lines cannot: does synthesis
  slow down across a 40-minute chapter (thermal throttling on a 326 MB CPU ONNX
  model is plausible)?
- **`STALL`** at ERROR means the UI said playing and the node was silent for ≥2
  consecutive watchdog seconds. This is the terminal-hang detector; it is
  deliberately *not* conditioned on chunks still being outstanding, because the
  hang it exists for happens after the last schedule.
- **`session superseded`** means a second play tap landed while a session was
  open. Expected when skipping chapters.
- **`session teardown`** means the pipeline was torn down underneath a live
  session — model not ready, or the audio engine failed to start. This is the
  interesting one.

### Falsifiable predictions

The instrumentation makes claims that can be wrong. Record the outcome:

1. **`playerNode.isPlaying` goes false when the node drains.** The whole GAP
   metric depends on this and it cannot be verified from source. If a device
   session reports `gaps 0` in every summary while the listener reports stutter,
   this assumption is false and GAP must be rebuilt on a render-callback stamp.
2. **RTF ≈ 0.5 foreground.** If measured RTF is materially higher, the Batch C
   `firstMaxChars` constants (~85 / ~105) are wrong and the prebuffer gate
   becomes the primary fix.
3. **Chunk 0 is short.** If the logged `chunk 0 is N chars` distribution is
   mostly ≥ 120, the stall is not chunk sizing and Batch C's first fix is aimed
   at the wrong thing.

---

## 5. Measurement protocol

The instrument perturbs what it measures, so follow this or the numbers are
worthless.

1. **Do not sit in the Logs tab while measuring.** `LogsView` holds
   `@ObservedObject logs = Log.shared` and renders a 500-entry list plus a
   `ShareLink(item: logs.exportText)` that re-joins every entry — so *each* log
   line re-evaluates that view on the main thread. Instrumentation raises the
   line rate, and the observer effect lands squarely on the gaps being measured.
   Play with the Logs tab closed, then open it (or export) afterwards: every line
   is persisted to `Documents/speechnotes.log` and its tail is reloaded at
   launch, so nothing is lost by not watching.
2. **One note, repeated.** Hold the text constant across builds or the
   extraction term in §3 swamps the comparison.
3. **Separate cold from warm.** The first play after launch pays the model load.
   Discard it, or keep it and read the `model-ready … (COLD)` line. Never average
   the two together.
4. **Background test.** Lock the screen or switch apps mid-session. Background
   RTF is not foreground RTF; the plan's ~0.5 is a foreground assumption and
   nothing here verifies it for background.
5. **Long-chapter test.** ≥16 chunks, ideally ≥250, to get the quartile lines.
   This is the only way to see RTF drift over a session.
6. **Export, don't screenshot.** `LogStore` keeps 500 entries in memory and
   persists a 300-line tail. A long session overflows both; export to a file at
   the end of the session rather than scrolling.

---

## 6. Work accounting

The plan's no-regression argument is "every hot-path change removes work."
**Batch A is the exception and does not get that argument.** It adds work. Here
is the whole of it, per event, so the exception is bounded rather than asserted:

| Site | Frequency | Added work |
| --- | --- | --- |
| `speak()` validation timing | 1 per play | 2 `ContinuousClock` reads + 1 comparison; log line only on the first call per engine instance or when ≥10 ms |
| `beginSession` / `endSession` | 1 per session | 1 log line each (~20–40 µs: `DateFormatter`, `UUID`, 3× `String(format:)`, 2 GCD dispatches) |
| `modelReady` | 1 per session | 2 clock reads on `generateQueue` + 1 extra `main.async` hop |
| Per-chunk generation timing | 1 per chunk | 2 clock reads on `generateQueue` (ns) + 1 `main.async`-side conditional; **log line only for the first 4 chunks, every 25th, and the last** |
| `bufferScheduled` | 1 per buffer | 1 divide (`frameLength / format.sampleRate`) + comparisons; log line only for buffers 1 and 2 |
| `bufferEnded` | 1 per buffer | 1 clock read + 1 assignment |
| Stall watchdog | 1 Hz while a session is live | ~4 field reads + comparisons; **no log line in the steady state** |

Against a pipeline where one chunk takes 0.4–6 s to generate, the per-chunk
addition is on the order of 10⁻⁵ of the work it measures. The 1 Hz timer sits
beside `PlayPositionTracker`'s existing 0.3 s heartbeat (3.3 wakes/s), so it
raises timer wakeups by ~30 % while doing no work in them.

The per-chunk log thinning is not cosmetic. Unthinned, a 200k-char chapter is
~1300 chunks → ~2600 log lines, which evicts TTFA from the 500-entry ring before
the chapter ends and takes the RTF series for the first ~80 % of the session with
it. Thinned, the same chapter emits ~64 lines.

**Nothing in this instrumentation gates, delays, reorders or alters playback.**
It records and logs. The one structural change to the audio path is that
`scheduleReadyChunks` now runs *before* the metrics call rather than after —
which moves log work off the critical path, so the instrumented build is
strictly closer to uninstrumented behaviour than the first draft was.

Batches C, D and H do get the work-removal argument, and each will carry its own
accounting in this section:

| Batch | Change | Work removed |
| --- | --- | --- |
| C | `chunks(for:)` running-offset accumulator | Removes the O(n²) `utf16Offset` walk — `text[..<index].utf16.count` once per chunk. `sentencePieces` already has this exact fix; `chunks(for:)` never got it. On a 200k-char chapter that is ~1300 walks averaging ~100k UTF-16 units. |
| C | Cache tokenizer validation | Removes 3 stat syscalls + a ~3.5 KB read and JSON parse from the main thread on every play tap. **Small in absolute terms** — the file is ~3.5 KB, not the tens of milliseconds a careless reading of "JSON parse on the play path" implies. Pure overhead that cannot change between taps, which is why it goes, not because it is large. The `play-path file validation` line measures it before and after. |
| D | Cache artwork, wire `currentArtwork` | Removes a JPEG re-read and decode (~3.3×/s on the main actor) that `NowPlayingCenter`'s throttle was supposed to prevent but cannot, because the work happens in the argument expression. |
| D | Coalesce `@Published` progress | Removes a 772-line editor body invalidation every 0.3 s tick. |
| D | Per-schedule `reduce` → accumulator | Removes `chunks[...scheduledUpTo].reduce(0)` — an O(k) walk per schedule, O(n²) per session. |
| D | Whole-chapter chunking off main | Moves the §2 chunking pass off the main thread entirely. |

---

## 7. Build-oracle timing (correction to the plan)

The plan budgets ~45 minutes for `build-ipa` and organises the whole batch
cadence around using that window productively. Measured on run 34414916499
(commit `cb44cd5`, 2026-09-09):

| Job | Duration |
| --- | --- |
| `Build unsigned IPA` | **6 m 05 s** (23:00:24Z → 23:06:29Z) |
| `Logic tests` | 53 s |

The two run in **parallel** (`build-ipa` has no `needs:`), so the whole gate is
~6 minutes, not 45. Almost certainly warm runner caches for SPM dependencies and
`xcodegen`.

Consequence for execution: the device-archive compile verdict arrives fast enough
to check **per batch** rather than stacking several batches of unverified app
code. `logic-tests` still does not compile any app code — it covers only
`Scripts/version-check.sh` and `Packages/SpeechLogic` — so `build-ipa` remains
the only oracle for anything under `App/Sources`. The critic loop still runs in
parallel with the build; the window is just shorter than planned.

If build times regress toward 45 minutes (cold cache, runner contention), revert
to the plan's original cadence. Re-measure rather than assume.
