# Plan — Background persistence (Batch A shipped 2026-10-04)

The diagnosis and the five-approach survey behind this work, plus what Batch A
changed. The reader who wants only the mechanism should read §1 and §2.

## 1. The diagnosis

**The audiobook path already did everything right; the TTS paths did almost
none of it.** Side by side, before this batch:

| | Audiobook (persisted) | TTS (died in seconds) |
|---|---|---|
| Session category | `.playback`/`.spokenAudio` | same shared call |
| **`setActive(true)`** | **yes** (`AudioBookPlayer.resumeAfterSessionEvent`) | **never — zero calls** |
| Interruption ended | re-activate + resume | pause/resume, no re-activate |
| Route change | reflect state | pause |
| `mediaServicesWereReset` | full rebuild | **absent** |
| `AVAudioEngineConfigurationChange` | n/a (AVPlayer rebuilds itself) | **absent — fatal for a hand-wired engine** |

Apple's background-audio recipe is three steps: enable `UIBackgroundModes:
audio` (present since v1.1), **configure *and activate* the session**, start
playing. Step 2's activation half existed in one place out of four.
`AVSpeechSynthesizer` and `AVAudioEngine` do NOT activate a session;
`AVPlayer` does — which is exactly why M4B playback survived backgrounding
and all three TTS engines (system, Kokoro, Supertonic) died identically
within seconds. The failing variable was the engine class, and the three
classes differ on precisely this one point.

## 2. What Batch A changed

1. **`AudioSessionSetup` is now the session OWNER** (`configureAndActivate`,
   `activate`, `reassert`). Every playback path — `SystemEngine`,
   `StreamingTTSPlaybackCore`, `OpusAudioBackend`, `AudioBookPlayer` — calls
   it, and the engine paths re-assert on every schedule/start, because an
   interruption or route change can silently deactivate the session behind
   the app's back.
2. **`duckOthers` removed from the ladder.** Apple: *"Set this option on a
   temporary basis only"* — and it *implicitly sets `mixWithOthers`*, and a
   mixable session is never elected the Now Playing app (Readest
   device-verified on iOS 18.7/26.2). Visible behaviour change: spoken audio
   now PAUSES the user's music instead of ducking over it. One-line revert in
   `AudioSessionSetup.apply` if that is wrong.
3. **`AVAudioEngineConfigurationChange` observers** in
   `StreamingTTSPlaybackCore` and `OpusAudioBackend`: reconnect with the
   format the graph was built for, restart, re-drive the schedule. This is
   the repair AVPlayer does implicitly and a hand-wired engine never had —
   it is what dies first on a Bluetooth connect, AirPods, an alarm, a call.
4. **`mediaServicesWereReset` on the TTS path** — re-arm, tear the dead
   pipeline down, KEEP the bookmark, no auto-resume (Apple: *"shouldn't
   restart your media playback … until initiated by user action"*). The
   audiobook's auto-resume predates this and is left alone; the Opus backend
   reports the reset by type and `AudioBookPlayer` cold-rebuilds it.
5. **`SystemEngine.synthesizer` is a `var`** with `rebuildSynthesizer()` on
   interruption-`.ended`: after a call the old instance can go permanently
   silent with no error; recreation is the documented recovery. Delegate
   callbacks are guarded by synthesizer identity so a stale `didCancel`
   cannot drive the new instance.
6. **Bounded pacing wait** (2 s passes, generation-checked): the producer
   can no longer park forever on a semaphore only the main queue signals
   (the R9 mechanism). A timeout is NEVER a skip — the producer only waits
   when the main thread has fallen more than `generationAheadLimit` chunks
   behind (a transient stall; the device log shows 8–35 s ones), and
   skipping then would permanently lose the sentence. The loop exits only
   for a superseded generation or a dead (`.idle`) pipeline, and it exits
   quietly — no skip tone against a pipeline that no longer exists.
7. **`SpeechPlayer.reconcileOnForeground()`** (called from the scenePhase
   hook): re-assert a live session; repair the "state claims speech, no live
   engine" wedge by keeping the bookmark and abandoning only the pipeline;
   auto-resume a recent bookmark — notes AND now books (30-minute window),
   books via `bookResumeHandler` → `BookPlaybackController.resumeBook`.
8. **Audiobook chapter-gap grace** (`AudioBookChapterGap`
   `beginBackgroundTask`), mirroring the TTS chain's — the between-chapters
   silence is the one window iOS may suspend an audio app.
9. **Backfill terminal stamp** (`-verified` suffix on `audioChapterSource`):
   a chapter-less OR cover-less audio book matched the backfill filter
   forever, so its whole-file manifest build re-ran every launch — the
   device log's repeated "Harry Potter" import and the 8–35 s main-thread
   hangs beside it. One re-read, then the suffix gates the whole audio
   clause off.
10. **CI guard**: the archived Info.plist's `UIBackgroundModes` must be
    exactly `[audio]` — drift in either direction fails the build.
11. **Opus probe chain** (`playback start`, `first buffer scheduled`): the
    device log from an Opus play tap has never gone deeper than
    "stream ready"; these two lines place a silent failure between decoder
    and graph.

## 3. The five approaches considered

1. **Make the current machine correct** — the session contract above. Shipped
   as Batch A.
2. **Render-ahead bank** — audio-seconds banking sized from thermal state,
   replacing chunk-count pacing; Supertonic `totalStep` 8→4 under thermal
   pressure. Batch B. The device log already justifies it: RTF measured
   0.48 → 1.68 with thermal `fair → critical`, first 50% mean 0.69.
3. **Render to file, play with `AVQueuePlayer`** — Readest/Koodo's
   architecture; decisive for throughput but changes pause/rate/read-along.
   Parked until Batch B numbers exist.
4. **One session owner + silent keep-alive** — the invariant that something
   renders from play to stop, including model load and chapter gaps. The
   slice worth taking is folded into Batch C; the keep-alive must be audio,
   never a background task (guideline 2.4.2).
5. **One substrate for everything** — rejected for now: it retires the
   metrics, drain detection and rate purge that fixed real device bugs.

## 4. The do-not list (severe-bug guard)

- No `UIBackgroundModes` beyond `audio` (2.5.4). CI enforces it.
- No blanket `beginBackgroundTask` keep-alive (2.4.2); the two grace tasks
  bridge a gap in the SAME book's narration only.
- `MPRemoteCommandCenter` stays lazy-registered (LiveContainer crash hazard).
- No `UIApplicationSceneManifest` (black-screened in LiveContainer on iOS 26).
- No `setCategory` churn while anything renders; no `setActive(false)` with
  buffers queued.
- The keep-alive (Batch C) must never outlive playback intent — logged
  transitions or it does not ship.
- The render-ahead bank must be capped in BYTES, not only seconds: Supertonic
  (~399 MB) + Kokoro fp32 (326 MB) + an uncapped bank is a jetsam kill, which
  is itself a background-persistence failure.

## 5. Device verification (the gate CI cannot replace)

Per surface — system voice, Kokoro, Supertonic, M4B, one 5.1 EAC3, one Opus:

- Filter the log for `metrics`. Green: `audio` seconds ≈ `wall` seconds,
  `gaps 0`, no `STALL`, no `session teardown`. A `bank hold extended`
  line is INFORMATION on a healthy session (it means the main thread
  stalled briefly and the chunk was held, not lost); any `skipped` line
  is a real event worth the log.
- Interleave mid-sentence: lock screen, Control Centre, app switcher,
  **phone call**, Bluetooth connect/disconnect, headphone yank, alarm,
  Low Power Mode, warm device. The phone call is the highest-value single
  test — it exercises activation, configuration-change, synthesizer rebuild
  and interruption resume at once.
- Supertonic 20+ min for the RTF quartiles; export the log rather than
  screenshotting (500-entry ring, 300-line tail).

## 6. Batch B — the render-ahead bank (shipped 2026-10-04)

The producer's throttle moved from CHUNK COUNT to AUDIO SECONDS. The old
`generationAheadLimit` chunks was the wrong unit: chunk audio length varies
~40× between a short sentence and a packed 200-char chunk, so "2 chunks
ahead" was anywhere from 2 s to 40 s of protection against the 8–35 s
main-thread stalls the device log records. The device log also supplied the
sizing justification: synthesis RTF measured 0.48 at nominal but 1.68 at
critical — past 1.0 the model cannot keep real time no matter how far ahead
it starts.

What shipped:

- **`RenderAheadBankPolicy` in `Packages/SpeechLogic`** (the only
  CI-testable target): bank targets by thermal state — 30 s nominal/fair,
  15 s serious, 8 s critical — a hard BYTE cap (32 MB ≈ 349 s at 24 kHz
  mono Float32; the §4 jetsam guard, binding only if a future retune
  raises the seconds targets), and Supertonic's denoising step count:
  8 nominal/fair, 4 serious/critical. Audio duration comes from the
  duration predictor, not the step count, so the 8→4 shed never disturbs
  the pacing arithmetic.
- **Producer pacing** (`StreamingTTSPlaybackCore.waitForBankRoom`):
  generate while `banked < target`, where banked = generated-but-unplayed
  PCM frames over the session, written on main (pool inserts + the
  playhead) and read on generateQueue through one lock as a coherent
  snapshot pair. The semaphore is now only a WAKEUP token — every pass
  re-reads the bank — so the old chunk-count ledger's surplus-signal
  property holds by construction, and the R9 exit conditions (superseded
  generation, .idle) are unchanged. A TIMEOUT IS NEVER A SKIP.
- **Bank drains from the playhead**: `PlayPositionTracker` grew an
  `onPlayedFrames` callback on its existing 0.3 s heartbeat. `reset()`
  re-zeroes against the node's LIVE clock (`nodeSampleBase = −current`),
  because the rate-change purge resets the tracker mid-session while the
  node keeps playing — a plain zero would read the whole running clock as
  played and the bank would never refill. A first-report heal covers the
  opposite case (reset read the old clock, then stop/play restarted it).
- **Drain classification**: a node drain with ~no bank left (<0.5 s, the
  tracker's heartbeat quantisation) logs `bank exhausted` — synthesis fell
  behind the playhead, the thermal-pressure signature; a drain with banked
  audio still unscheduled stays `GAP` — the main-thread-stall case. Both
  count in the session's gap figure; the summary splits the tally
  (`N bank-exhausted`), so a device log names the cause of every silent
  stretch. A `bank exhausted` line with thermal `nominal` means the model
  itself is too slow on that device, not the silicon.
- **Supertonic step shed**: `generateChunk` reads thermal per chunk and
  passes 8 or 4 steps to Helper's `call`; the per-chunk log now carries
  `steps N` so a slow chunk's line shows whether the shed was active.

Deliberately rejected: gating the allow check on a PREDICTED next-chunk
length (an estimate). A target can drop below one chunk's audio length
(critical's 8 s vs a 20 s chunk), and a `banked + estimate ≤ target` check
never passes then — the producer wedges forever. The shipped check
(`banked < target`) overshoots the target by at most one chunk — bounded,
and unable to deadlock.
