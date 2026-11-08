# HANDOVER — Background TTS persistence (bug 1 of 3), + bugs 2 & 3 queued

Date: 2026-11-07. Base: `main` @ `58a5ddf` (v1.7.4). Branch: main, working
tree has uncommitted bug-1 changes (5 modified files + 1 new file).

Three user-reported bugs, to be fixed one at a time, in order:

1. TTS does not persist in the background (hot or cool phone).
2. Kokoro artifacts / skipped-mispronounced words / size larger than expected.
3. Opus audiobook needs several taps before playback; bookmarks unreliable
   in the background.

**Bug 1 is IMPLEMENTED but NOT verified. Bugs 2 and 3 are NOT STARTED.**
No local Swift toolchain (`swift` unavailable) — CI build requires the
user's authorization; Xcode/device verification is still required.

## Bug 1 — what was implemented (uncommitted)

The prior branch `batch-c-d-session` (read with `git show <sha> -- <path>`,
do NOT merge wholesale) is the reference: `241888e` silence bridge v1,
`fb2e17b` bridge closure fix, `8dc6104` grace task + 10 s health check +
compact Kokoro + audiobook clock, `2718984` diagnostics round (CrashMarker,
memory vitals, Kokoro eviction, session rung).

CRITICAL prior evidence (HANDOVER §2c in commit 2718984): the bridge alone
did NOT stop the deaths — the app still died 9–110 s after backgrounding,
sometimes with live I/O and mid-generation; activation never failed; no
frozen playhead was ever observed. Remaining suspects: a crash or a
memory/system kill. Hence this round = corrected bridge + health check +
grace task + memory reduction + diagnostics that NAME the killer.

### Design decision that differs from the old branch

The old bridge decided "real audio resumed" because `scheduledUpTo`
changed — but a SKIPPED chunk also advances the cursor while queueing
nothing, ending the bridge mid-starvation. The new implementation tracks a
counter `realBuffersOnNode` (real, non-bridge buffers queued on the node,
not yet completed) and uses IT as the dryness test:

- incremented in `schedule()` immediately before `scheduleBuffer`;
- decremented at the TOP of the buffer's main-queue completion handler
  (before finishLastChunk/scheduleReadyChunks), floored at 0;
- reset to 0 in `speak()` and `teardownPlayback()` (node stop clears any
  queued bridge buffer; its completion is generation-guarded into a no-op);
- purged rate buffers stay balanced (increment at schedule, decrement at
  their completion even though the pool entry was removed).

### File-by-file

**App/Sources/Engine/StreamingTTSPlaybackCore.swift**

- Silence bridge: `bridgeSilenceSeconds = 0.5`, `bridgeArmed`,
  `bridgeIncidentSeconds` (log ledger), `realBuffersOnNode`.
  - `scheduleBridgeSilenceIfNeeded()` (main thread) arms only when:
    state is `.speaking`/`.generating` AND `!bridgeArmed` AND
    `realBuffersOnNode == 0` AND `scheduledUpTo + 1 < chunks.count` AND
    `bufferSlots[scheduledUpTo + 1] == slotPending`. (The last check keeps
    the bridge OFF the foreground first-chunk path: when the producer just
    resolved the first buffer, the schedule pass in the same turn queues it.)
  - `armBridge()` schedules one 0.5 s silent buffer; guards
    `ensureAudioEngineRunning(format:)` returning true (on failure state is
    already `.idle`), then `audioEngineRunning` + live state. Tracker
    marker re-states the last real chunk's end-char (0 during .generating)
    so read-along chars / progress / bookmarks FREEZE over bridge silence
    (tracker only emits when the interpolated char count GROWS).
    Completion: `bridgeArmed = false`; `generatedFrames +=` bridge frames +
    `recomputeBank()` (keeps `banked` = real unplayed audio); re-arm only
    while `realBuffersOnNode == 0 && scheduledUpTo + 1 < chunks.count`;
    logs `keepalive bridge —` on first arm and `keepalive bridge ended —
    real audio queued after Xs` when it ends.
  - Call sites: tail of `scheduleReadyChunks()` (early `return`s became
    `break`s + tail call — covers buffer completion, skipped chunk,
    config-change re-drive, health-check re-drive); `handleBackgroundTransition`
    when entering background with state `.generating` (gives a first-chunk
    session audio I/O at the lock instant); end of `resume()`.
- `ensureAudioEngineRunning(format:)` now returns `Bool`
  (`@discardableResult`); on engine-start failure it logs, sets
  `state = .idle` (teardown) and returns false. `schedule()` guards on it
  and STOPS (no more scheduling into a stopped engine).
- Background health check: `backgroundHealthTimer` 10 s `.common`-mode
  timer, started in `speak()` beside `startStallWatchdog()`, stopped in
  `teardownPlayback()`, `stop()`, `handleMediaServicesReset()`
  (same diddy-noop-didSet race as the watchdog), invalidated in `deinit`.
  `backgroundHealthCheck()`: foreground → refresh baseline only; not
  speaking/generating → refresh baseline; backgrounded `.generating` →
  `scheduleBridgeSilenceIfNeeded()` + baseline refresh (playhead is not a
  liveness signal there); backgrounded `.speaking` → if `playedFrames` is
  UNCHANGED since the last tick (compare `!=`, not `<` — a rate-purge
  tracker reset also changes the number), log
  `background health check — playhead frozen…`, re-activate session,
  restart engine if needed, `playerNode.play()`, re-drive
  `scheduleReadyChunks` (tail re-arms bridge).
  Every backgrounded live tick logs one `background vitals — mem XMB
  footprint / YMB to ceiling, task window Zs` line.
- `handleBackgroundTransition` snapshot line now also carries
  `bridge armed/off`, `ProcessMemory.summary()`, `task window …`.
- `lastHealthPlayedFrames` reset to -1 in `startBackgroundHealthCheck()`.

**App/Sources/Services/SpeechPlayer.swift**

- Background grace task: `playbackGraceTask`,
  `var isAppBackgrounded` (plain var — SpeechnotesApp writes it;
  `private(set)` was a compile error, fixed in the last edit),
  `beginPlaybackGraceIfNeeded()` (armed only while `.speaking`/`.generating`,
  idempotent, expiry handler LOGS `background grace EXPIRED` then ends),
  `endPlaybackGraceIfNeeded()` (idempotent).
  - Armed: SpeechnotesApp on scenePhase `.background`.
  - Re-armed: in `onStateChanged` for transitions INTO `.speaking`/
    `.generating` while `isAppBackgrounded` (lock-screen play / chapter
    advance under lock screen — no scenePhase event fires).
  - Ended: `.idle` transition (BEFORE the `onNaturalFinish == nil` book
    guard), `.paused` transition, `abandonLiveSession`,
    `reconcileOnForeground`'s wedge path, SpeechnotesApp on `.active`.
- Kokoro eviction on switch-away (the ~326 MB fp32 ORT session —
  Supertonic + Kokoro resident is the jetsam arithmetic): in
  `rebuildEngine()`, `if engineKind != .kokoro { onnxEngine = nil;
  onnxEngineFileIsBig = true }` — mirror of the Supertonic release.
  (scheduleKokoroIdleUnload only covered STAYING on Kokoro.)
- IMPORTANT regression fixed during the round: the lock-screen
  `NowPlayingCenter.shared.publish(...)` lived in the onStateChanged
  final `else`; inserting `.paused`/`.speaking` branches initially hid it.
  Now: non-idle branch does grace housekeeping first, then publish runs
  for EVERY non-idle state. Do not re-narrow that else.

**App/Sources/Services/BookPlaybackController.swift**

- Chapter-gap grace no longer ends at `togglePlay` (which only OPENS the
  vulnerable window). `speak()` now calls `armChapterGapSpeechWatch()`:
  a `Task` polls every 0.5 s until `player.state == .speaking` (logs
  `chapter gap closed — speech sounding, grace released`), exits early if
  the chain was abandoned (`state == .idle && activeBook == nil`), falls
  back to ending after `chapterGapSpeechTimeout = 25` s.
- Expiry now CHAINS: `renewOrEndChapterGapGrace()` begins a fresh ~30 s
  window while `activeBook != nil && player.onNaturalFinish != nil` and
  `chapterGapExpiries < chapterGapMaxExpiries (3)`; otherwise ends the
  grace. Bounded (~90 s worst case) — deliberately not a keep-alive.
- `endChapterGapGrace()` also cancels `chapterGapWatchTask`.

**App/Sources/Services/AudioSessionSetup.swift** (ported from 2718984)

- New rung 2.5: `.playback` + `.spokenAudio` + NO options, before the
  bare-playback rung (the 2026-10-23 log showed rungs 1+2 failing with
  -50 while the bare call succeeded — options were the variable).
- `apply` failure line now prints the options bitmask:
  `setCategory(cat, mode, opts N) failed: …` (bits: 1 mixWithOthers,
  2 duckOthers, 4 allowBluetooth, 8 defaultToSpeaker, 32 allowBluetoothA2DP).

**App/Sources/Services/CrashMarker.swift** (NEW, ported verbatim from 2718984)

- `CrashMarker.installAndReplay()`: async-signal-safe fatal-signal +
  uncaught-exception marker (Documents/crash-marker.txt), replayed next
  launch as `PREVIOUS LAUNCH CRASHED — …`; no marker on fresh relaunch =
  system kill (jetsam SIGKILL cannot be caught).
- `ProcessMemory.summary()`: `phys_footprint` (task_info flavor 22) +
  `os_proc_available_memory` via `@_silgen_name` binding.

**App/Sources/SpeechnotesApp.swift**

- `init()` calls `CrashMarker.installAndReplay()` first thing.
- scenePhase `.background`: `player.isAppBackgrounded = true` +
  `player.beginPlaybackGraceIfNeeded()`.
- scenePhase `.active`: `player.isAppBackgrounded = false` +
  `player.endPlaybackGraceIfNeeded()` (fresh ~30 s window per backgrounding
  — the bg → 6 s peek → bg trap), then the existing reconcile.

project.yml is XcodeGen with directory sources (`App/Sources`), so the new
file needs no registration.

### Bug 1 verification status

- DONE: full diff review pass; brace-balance check on all six files
  (passed); the `private(set)` compile error found in review and fixed;
  the NowPlayingCenter publish regression found in review and fixed.
- NOT DONE (needs Xcode/CI/device — CI requires user authorization):
  - compile of the app target;
  - device log signatures: `keepalive bridge` / `keepalive bridge ended`,
    `background vitals`, `background grace armed/EXPIRED`, `chapter gap
    closed`, `background health check — playhead frozen`,
    `PREVIOUS LAUNCH CRASHED` (its absence on a fresh relaunch = system
    kill; climbing footprint across vitals = jetsam; flat footprint with a
    death = suspend-purge — see §2c of the 2718984 handover for the full
    reading guide);
  - confirming speech resumes after a bridged slow-generation interval,
    no `state speaking with no live session` on foreground return,
    memory footprint not approaching the ceiling.
- Local review checklist already walked: main-thread ownership (all
  bridge/health state is main-only; completions hop to main with
  generation guards); pause/stop leave no bridge buffer or grace task
  (teardown resets ledger + stops timers; grace ends on idle/pause/
  abandon); superseded sessions cannot re-arm (generation-guarded
  completions + speak() reset); read-along/bookmark chars do not advance
  over bridge silence (tracker marker endChar frozen; emits only on growth).

## Bug 2 — Kokoro artifacts / skipped words / size (NOT STARTED)

- Main's "Compact" tier still uses `model_uint8.onnx` (~177 MB); repo
  history says that tier is CORRUPT: `e64b456` ("the quantization gate's
  verdict — the uint8 tier is corrupt"), `f9b2558` ("the controls cleared
  the oracle, and the graph itself is the culprit"). Docs/UINT8-TIER-FORENSICS.md.
- `git show 8dc6104` replaced the uint8 tier with `model_quantized.onnx`
  (~92 MB int8; fp32-oracle A/B equal-or-better LSD in 5/6 cases; fp16
  re-confirmed NaN) and retargeted ModelManager, OnnxKokoroEngine, tier
  naming ("Compact"), UI copy, and Tests/KokoroSmallSpike.
- `git show 2b1f9ce` has the "TTS word forms" work (numbers/symbols/math)
  — likely the skipped/mispronounced-word story.
- Inspect: `App/Sources/Engine/OnnxKokoroEngine.swift` (tokenizer/phoneme
  mapping; the path that deletes/substitutes phonemes missing from the
  vocab; chunking, speed, voice-style lookup), `App/Sources/Services/
  ModelManager.swift` (URL, filename, validation, deletion/migration),
  `Packages/SpeechLogic/Sources/SpeechLogic/SpeechSanitizer.swift`,
  `.../SentenceChunker.swift`, `Tests/KokoroSmallSpike/`.
- Keep four causes separate: (a) graph quality/model tier, (b) phoneme/
  tokenizer coverage, (c) text normalization (numbers/symbols/math),
  (d) chunk-boundary artifacts. Int8 alone does not fix pronunciation.

## Bug 3 — Opus start taps + background bookmarks (NOT STARTED)

- `git show 8dc6104 -- App/Sources/Services/AudioBookPlayer.swift
  App/Sources/Views/BookAudioReaderView.swift App/Sources/Services/
  BookAudioBackend.swift` contains the direct fixes: persist the backend's
  own clock (`BookPosition.audioSeconds`) and resume from it instead of
  reconstructing seconds from a chapter fraction; nil-clock guard so
  chapter 1 is not "finished" while an Opus stream loads; the Opus
  reader's play button resumes a paused live session from the backend
  clock; cold open uses the persisted absolute playhead;
  interruption-began flushes the playhead.
- Also inspect: `App/Sources/Engine/OpusAudioBackend.swift`,
  `AudioBookPlayer.swift`, `BookAudioBackend.swift`,
  `BookmarkStore.swift`, and SpeechnotesApp's scenePhase
  `audioBooks.persistNow()` flush.
- Multi-tap symptom: first tap starts async Opus setup while the UI still
  looks idle/tappable → later taps start competing sessions. Fix should
  make one tap sufficient, expose a real preparing state, and prevent
  duplicate starts. Bookmark reliability = absolute backend position +
  persistence on background/interruption + no false "chapter finished"
  while the Opus clock is nil + recovery from the absolute position.

## Working rules for the next session

- One bug at a time; finish + verify bug 1 report before bug 2, then bug 3.
- Do not push, commit, or dispatch remote workflows unless the user asks.
- No local Swift toolchain: local verification = review + brace/parse
  smoke checks; offer CI build only with the user's authorization.
- Read old-branch work with `git show`, never merge the branch wholesale.
- The old bridge alone was NOT sufficient (§2c evidence) — do not call
  bug 1 fixed without the device-log round; the diagnostics in this round
  exist to name crash vs jetsam vs suspend-purge on the next log.
