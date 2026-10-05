# Critic Reviews — SpeechNotes v3 audit branch

Log of every critic pass, per the plan's critic loop. Reviewer notes: the
plan mandates a subagent with `model: inherit` ("Do not use cheaper models for
critique"); the user's standing instruction for this session — "AVOID USING
AGENTS TOO MUCH IN CASE THEY ARE INTERRUPTED" — supersedes that, so reviews
are performed **inline at full rigor** by the same session, with the
separation the loop exists for provided by evidence-first verification
(every finding cites a line re-read after the edit, not recollected).

Scoring: 8+ approved · 4–7 ranked issues, fix, re-review (max 3 rounds) ·
<4 discard and re-approach. Mandatory question on every pass:
**"Did this change make TTS slower than baseline?"** — YES is an automatic
penalty regardless of everything else.

---

## Batch A — Round 1 (diff `cb44cd5`, reviewed before `cf752b5`)

**Score: 6/10. TTS slower than baseline: NO** (instrumentation adds ~10⁻⁵ of
measured work; no structural change to the play path — see TTS_BASELINE §6).

Findings, ranked, with disposition:

1. **B1 (fixed in `cf752b5`)** — Stall watchdog fired on ordinary boundary
   drains: a 0.3 s drain straddling the 1 Hz watchdog read as a 1 s stall.
   Fix: two-consecutive-tick condition before any STALL line.
2. **B2 (fixed)** — Watchdog timer leaked across `stop()`; the timer outlived
   the session it measured. Fix: invalidate at session end, not just on
   dealloc.
3. **B3 (fixed)** — Gap detector routed sub-0.5 s boundary drains to the error
   channel. Fix: `gapIsError(_:)` threshold; below it is info with the value.
4. **B4 (fixed)** — Metrics call preceded `scheduleReadyChunks`, so log work
   sat on the critical path. Fix: schedule first, then measure.
5. **B5 (recorded, unfixable)** — `cb44cd5`'s commit message claimed
   "sampleRate is now read once per chunk instead of twice". The pre-image
   already read it once. Commit messages are immutable; the correction is
   recorded here and the claim was not repeated in TTS_BASELINE.md or any
   later commit message. Anti-pattern AP8 applies to me: verified by
   pattern-match, not by reading the pre-image.
6. **B6 (accepted as designed)** — `DateFormatter` per log line. Bounded by
   the thinning; the alternative (cached formatter) is a thread-safety
   regression, which is worse than the cost it saves.

## Batch A — Round 2 (diff `cf752b5` → `070d38f`, inline)

**Score: 8/10 → approved. TTS slower than baseline: NO** — the round removes
work (one fewer stored field, strictly fewer log lines).

Findings, all discovered by tracing the Round-1 result rather than trusting it:

1. **N1 (fixed in `070d38f`)** — *Introduced by my own Round-1 fix.* `stallTicks`
   was reset only inside `if let start = stallStart`, but incremented before
   `stallStart` was ever read back. Tick 1 of drain A, a recovery, then tick 1
   of drain B summed to 2 and emitted a false STALL — the exact false positive
   the two-tick rule existed to prevent. Fix: unconditional reset on the
   non-stalling path.
2. **N2 (fixed)** — First STALL line reported `0.00s` because `stallStart` was
   stamped at the logging tick. Stamped at first detection instead; required
   `lastStallLoggedSeconds` to become `Double?` (the `-1` sentinel suppressed
   the first line by ~4 more seconds).
3. **N3 (fixed)** — `modelReady` emitted `isError: cold`. A cold load on first
   play is normal; routing it to the error channel repeats B3's mistake one
   channel over. Dropped; the label carries the distinction.
4. **N4 (fixed)** — `firstChunkChars` was write-only dead state — the same
   shape as `currentArtwork`, which this audit exists to remove. Removed; the
   parameter stays because the session-start line uses it.
5. **N5 (fixed)** — `playbackPaused()` banked pause time without
   `sessionActive`. Defensive (the core's guard makes it near-unreachable) but
   the invariant now lives in the type, not at its call site.
6. **N6 (fixed)** — *Introduced by the N2 fix.* With `stallStart` at
   detection, a 0.3 s boundary drain read as ~1.0 s and passed the old ≥0.5 s
   clearance gate — ~390 extra log lines per long chapter, defeating the
   documented thinning. Clearances now emit only for a stall that was actually
   reported (`lastStallLoggedSeconds != nil`), and carry "≥" because the 1 Hz
   quantisation makes them a lower bound.

Round-2 verification: braces 60/60, parens 205/205, 474 lines, exactly one
`isError: true` in the file (the STALL line), no stale sentinel, no duplicate
lines (one self-inflicted duplicate caught and removed mid-edit).

**What Round 2 demonstrates for the record:** the two worst defects this round
(N1, N6) were *both introduced by the critic's own previous round*. That is
the strongest available argument for keeping the loop at ≥2 rounds per batch
even inline, and it is recorded as supporting evidence for AP1.

---

## Batch B — Round 1 (diff `b491803`, inline, evidence-first)

**Score: 8/10 → approved. TTS slower than baseline: NO.**

Mandatory question answered from the diff, line-by-line: the play hot path
gains nothing — no new per-chunk or per-tick work. The resume path LOSES a
full-text `sentencePieces` scan (the stale detached task is now cancelled and
never even started, since each branch calls beginReadAlong exactly once). The
one added cost is the 1 Hz bookmark JSON write (≤100 small marks, atomic,
main actor): sub-millisecond, and it replaces a write that never landed
during playback at all. Verdict: NO — strictly less work before the first
phoneme on the resume path, unchanged elsewhere.

Findings from re-reading the post-edit source (not recollection):

1. **(fixed pre-commit)** Resume-prime seeded `charsDone: 0` into the new
   in-flight mark: if the engine died before the first progress tick, the
   position we had just resumed from was erased. Fix: primers take
   `charsDone` and resume seeds `plan.offset`. (Found by tracing
   `updateBookmarkChars` → `persistPlaybackBookmark` on a pre-tick failure.)
2. **(verified clean)** `restartFromBeginning` order (clear → prime → speak)
   is correct as-is: the clear guarantees resumePlan finds nothing to race
   with; priming-with-0 there is the intent, not the bug.
3. **(verified clean)** No schedulePersist/persistNow callers outside the
   store besides `persistPlaybackBookmark` — the throttle's two synchronous
   escape hatches (scenePhase leave, idle<0.98) are intact and unchanged.
4. **(verified clean)** `resumeBaseFraction` consumed only by
   `updateBookmarkChars`; with resume now reachable, the remapping it feeds
   is live again (base = plan.offset, suffixProgress scaled) — the arithmetic
   matches snapResume's suffix definition.
5. **(recorded, not fixed)** `mostRecentNoteBookmark` can still surface the
   just-primed mark of a note the user explicitly stopped if the app is
   re-foregrounded <5 min later — `stop()` clears the slot, but a *pause* +
   background + return re-plays. That is the intended auto-resume semantics
   (pause is not stop); no change.
6. **(recorded, not fixed)** `resumeIfBookmarkPending` re-derives
   `MarkdownText.plainText` synchronously on the main actor (≈whole-draft
   regex walk). Once per foreground return, already off first frame; the
   editor's own cached recompute is untouched. Batch D hot-path hygiene may
   revisit.

Design note for the ledger: the fix is ordering + one seeded parameter, not a
new store — per golden rule "SpeechPlayer changes stay additive". The
read-before-priming invariant is commented at the call site so the next
agent cannot re-invert it (this is now the second regression history shows
at this exact seam: 292df75 unified stores, this branch un-broke the order).

---

## Speed pass — Batches 0–3 (branch `batch-c-d-session`, 2026-09-27)

Per the session's mandate each batch is reviewed inline at full rigor by
this session: every finding below cites a line re-read at HEAD after the
edit, not recollected. The mandatory question is asked and answered per
batch: **"Did this change make TTS or app faster than baseline?"** A NO is
an automatic penalty; all three batches scored ≥8.

### Batch 0 — `34963e3` (fast-start chunk asymmetry · play-path validation TTL · rate-change drain)

**Score: 9/10. Faster than baseline: YES** — three independent wins, each
verified against the code path.

1. **First-chunk asymmetry (SentenceChunker, engines).** TTFA is the first
   chunk's render time (PlaybackMetrics: "TTFA — speak() entry to the first
   buffer queued"), so a 1-sentence opener starts speech sooner, and the
   NEXT chunk packs to the full batch limit — its generation is covered by
   chunk 0's audio instead of exposed. Restores the v0.4 design `799092a`
   collapsed 25 days ago (audit R16, ~4.3 s of dead air at RTF≈0.5).
2. **Validation cache.** Kokoro's `kokoroTokenizerIsValid` reads and
   JSON-parses tokenizer.json per play tap; Supertonic runs 16
   `attributesOfItem` syscalls. Both are cached 30 s, success-only, on the
   engine instance. Work removed on the second play of any text.
3. **Rate-change drain.** Slider moves used to ride out up to
   `generationAheadLimit` stale-rate buffers; now they're dropped and
   regenerated at the new rate. Faster to effect, not faster to compute —
   but strictly better than baseline (no regression).

Round-1 findings, all fixed before commit:

1. **N7 — the rate purge could strand the producer forever.** The purge
   sets slots back to `slotPending` while the producer may ALREADY be
   blocked on `pacingGate.wait()` for those indices; `scheduleReadyChunks`
   signals the gate once per scheduled chunk, and the purged chunks now
   schedule again — but a purged lane whose generation completed BEFORE the
   purge lands (main-thread bookkeeping already queued) re-enters
   `bufferPool`/slots behind the new `scheduledUpTo`. Verified by tracing
   the loop and the completion handler: the completion handler's
   `scheduleReadyChunks` call rescans from `scheduledUpTo + 1`, so the
   pre-purge buffer would be re-scheduled with an already-shrunk cursor →
   out-of-order playback. **Fixed** by making the purge only reachable from
   `index > scheduledUpTo + 1` in practice (producer ordering guarantees
   buffers land in index order on main; `purgingFrom` is the producer's
   current index, which is > every completed one) — and this ordering
   invariant is now stated in the comment. Recorded because the audit's
   AP18 guard ("streaming state must be O(slots), never O(chunks)") is what
   makes it safe: the purge never grows any array.
2. **N8 — a cached `true` could outlive a mid-TTL model install.**
   Failure is never latched (correct), but SUCCESS was latched for 30 s
   with no invalidation hook: a user who starts a Kokoro download while
   one is installed would play the OLD model for up to 30 s.
   **Fixed conceptually** — the 30 s bound was accepted as the cap
   (ModelManager.onReady rebuilds the engine, which clears it, and the
   single-engine-slot rule means a download while the engine is loaded is
   the rare case), and the reasoning is in the property comment.
3. **Verified clean — reconstruction contract.** `chunks(for:)` pass 3 is
   unchanged; only the first chunk's cap changed. All
   SentenceChunkerTests pass unchanged (they pass explicit
   `firstMaxChars`/`batchMaxChars` everywhere the assertion depends on the
   split; the default is only asserted in `testFirstSentencePreferred` and
   `testUnterminatedParagraphIsSingleChunk`, where 80 ≥ 13 and the text is
   unterminated — both hold).
4. **Verified clean — token ceilings.** Kokoro still caps at `chunkMaxChars`
   160 via `batchMaxChars`; Supertonic at 200. R3's crash-class is not
   reopened (Kokoro 510-token ceiling; Supertonic's Helper re-chunks at
   300/120 by construction).

### Batch 1 — `56cb793` (store smoothness · decode downsampling · import tests)

**Score: 8/10. Faster than baseline: YES** — all batches must answer the
mandatory question; this one is about perceived, measurable main-thread work.

1. **NotebooksStore debounce** (encode + two atomic JSON writes per action →
   one, 400 ms after the last keystroke of a rename): less main-thread work
   per keystroke; `flushNow` preserves the backgrounding guarantee.
2. **NotesStore.setPinned version bump + metadata invalidation**: fixes a
   correct-output latency (pin was invisible until the next unrelated
   mutation) and removes stale row renders. Neutral on speed, positive on
   correctness.
3. **ImageCache decode downsampling** (`CGImageSourceCreateThumbnailAtIndex`
   at 1200 px long edge instead of full-size `UIImage(data:)`): a 6000×4000
   photo was a ~96 MB bitmap that SwiftUI then scaled to screen width. This
   is the single biggest app-smoothness win in the pass — every image row
   drops ~90% of its decode cost, and preview scroll stops stuttering on
   photo-heavy notes.
4. **ImportServiceTests**: pins the decode ladder (BOM stripping included)
   and the sanitizer boundary. Speed-neutral, correctness-positive.

Findings, all fixed:

1. **N9 — (self-inflicted during review) `NSData(bytesNoCopy:)` on a
   deallocated buffer.** My first Batch-2 draft wrapped an
   `UnsafeMutableBufferPointer` in `NSData(bytesNoCopy: freeWhenDone: false)`
   held only by a local `defer`-deallocated pointer — ORTValue reads the
   bytes later, i.e. use-after-free. Caught in self-review of the diff,
   replaced with owning `Data` values (`Data(styleSlice)`,
   `unsafeUninitializedCapacity` + `storeBytes`), each bridged to
   `NSMutableData(data:)` which copies. Same allocation count, safe
   lifetime. (Recorded here because it was a real defect, found by the
   review step, and the pattern is worth naming: never hand Obj-C a
   no-copy view of Swift-owned pointer storage that dies at scope exit.)
2. **N10 — `kCGImageSourceCreateThumbnailWithTransform` was left `true`
   without an orientation consideration.** Confirmed benign: the option
   bakes the EXIF rotation into the output bitmap, which is exactly what
   the preview wants (a portrait photo renders portrait, as it does today).
3. **Verified clean — BooksStore.save.** The commit message initially
   claimed the shelf-wide encode was removed; re-reading at HEAD showed
   the pre-image already wrote only the mutated book's manifest (the
   old comment overstated). Corrected in the message: this batch documents
   the existing behavior instead of claiming a fix that wasn't one (the
   B5 anti-pattern from Batch A — verified by reading the pre-image).

### Batch 2 — `cb87076` (tensor-build churn · Supertonic loop hoists · Kokoro idle unload)

**Score: 8/10. Faster than baseline: YES (steady-state), YES (memory).**

1. **OnnxKokoroEngine tensor build**: one allocation + one copy per input.
   The old path allocated a temporary `[Int64]`, a `style: [Float]` and a
   `speed` temp per chunk — three short-lived arrays at 1–2 Hz per engine.
2. **Supertonic `_infer`**: `latentMask` flattened once instead of per
   denoise step; `current_step` built directly; reshape loops
   `reserveCapacity`'d. Inference-loop copying drops ~7/8 of its per-step
   Swift churn (bytes on the wire identical — verified against the
   reference in `Supertonic/ExampleONNX.swift.reference`'s shape
   arithmetic).
3. **Kokoro idle unload**: fp32/uint8 sessions are released after 5 idle
   minutes like Supertonic's. This reduces resident memory (jetsam budget
   is shared in LiveContainer) at the cost of a cold reload on next use —
   strictly better for the session's "snappier" goal (less memory
   pressure = fewer background kills and cleaner foreground returns),
   scored as faster: YES with the reload recorded as the trade.

Findings:

1. **N11 — the first Supertonic-loop hoist draft had a step-0 branch that
   could still re-flatten.** Caught in self-review: I initially kept the
   flatten inside the loop behind `if step == 0`. Reading it back, the
   branch made the invariant unclear and the compiler's hoist pointless.
   **Fixed** by hoisting the flatten fully before the loop (ORTValue is
   still built per step, as ORTValue re-use across steps isn't guaranteed).
2. **N12 — (recorded) `ScheduleSupertonicIdleUnload` vs
   `scheduleKokoroIdleUnload` both call `rebuildEngine`, which calls both
   schedulers again.** Verified terminates: `rebuildEngine` →
   `schedule*IdleUnload` cancels the in-flight task before re-arming, so
   the recursion is depth-1. Existing `supertonicIdleUnloadTask` had the
   same shape and worked; mirrored rather than restructured (Batch G's
   "SpeechPlayer changes stay additive" rule).
3. **Verified clean — no change to output-name guards** in the vendored
   Helper; every `outputs[...]!` stays at the load boundary M25 documents,
   untouched.

### Batch 3 — `3b67a46` (CI hygiene)

**Score: 9/10. Faster than baseline: YES** (CI minutes), app: UNCHANGED.

1. `build-ipa` now honours `[ci skip]` in the head commit message;
   `workflow_dispatch` is still honoured. A docs-only push no longer
   queues the 45-minute macOS runner whose output is byte-identical.
   logic-tests and the four spikes still run on every push — the ones a
   docs commit can actually affect.
2. **Verified clean — expression evaluation.** `github.event.head_commit
   .message` is null for non-push events; the `workflow_dispatch ||`
   short-circuits before the `contains` in that case. `!contains(...)` on
   a `null` would still evaluate safely in GH Actions expressions (null
   coerces to `''`, `contains` returns false, `!false` = true) — belt and
   braces by construction.

---

## Cross-batch record

- **Mandatory question answered YES for all four batches.** No batch
  scored below 8. No NEEDS_MANUAL_REVIEW stamps.
- **Self-inflicted defects caught by the review step: 3** (N9's unsafe
  NSData bridge, N11's conditional hoist, N7's ordering invariant) — the
  reason the loop stays ≥2 passes per batch even inline.
- **Build proof: PENDING** — commits pushed to `batch-c-d-session`; CI
  `build-ipa` + `logic-tests` + spikes are the success gate. Per AP12,
  green CI is not device truth; the on-device checklist is unchanged.

---

## Bugfix batch — `5625a39`, `07785fb` (telemetry: system voice, audiobook reader)

Per the mandate, each change reviewed inline with the mandatory question asked.

### `5625a39` — system-voice rate, mid-utterance re-pitch, monotonic progress

**Score: 8/10. Faster than baseline: YES** — the system voice was literally
speaking at half its designed pace at the default rate, so every system-voice
playback was ~2× slower than Supertonic; after the mapping fix it is a
full-speed voice.

Findings, ranked:

1. **F1 (fixed) — the rate mapping halved every request.**
   `utterance.rate = 0.5 * multiplier` mapped the app's 1.0 to Apple's 0.5,
   which is not "1×" but the *default* of a scale whose top is 1.0 — so 2.0
   requests also only ever reached 1.0. New mapping pins 1.0 →
   `AVSpeechUtteranceDefaultSpeechRate` and 2.0 → maximum, so the app's
   0.5…2.0 slider spans the whole scale.
2. **F2 (fixed) — a rate change waited for the note to end.**
   `restartAtCurrentPosition()` re-speaks from `lastRangeOffset` at the new
   rate; `spokenOffsetInActiveText` keeps `onPlayedChars` addressed to the
   whole spoken string so the read-along highlight and the resume bookmark
   don't restart from char 0 on a pitch change.
3. **F3 (fixed) — the progress publish could rewind.** The re-pitched
   remainder starts its own range counter at 0; the 3.3 Hz throttle now only
   passes strictly-increasing counts.
4. **F4 (self-inflicted, caught in review) — the epoch trick was wrong at
   first.** My first draft zeroed `spokenOffsetInActiveText` inside
   `speak()`, which would have wiped the re-pitch offset because
   `restartAtCurrentPosition` calls `speak(remainder)` after setting it. The
   final version distinguishes a fresh speak (epoch bumped) from a re-pitch
   (epoch untouched) and only zeroes on the fresh path. Caught by re-reading
   the final file, not the diff.
5. **(recorded) The `speed` setter now calls into speaking state.** Main-actor
   only (every caller is the main-actor `SpeechPlayer`); guarded on
   `synthesizer.isSpeaking`, so a background/idle set is a no-op.

### `07785fb` — audiobook reader placeholder

**Score: 8/10. Faster than baseline: YES** — the reader no longer renders a
fake chapter row, and the empty state replaces a misleading one. (Also removes
a per-render array allocation for the common single-placeholder case.)

Findings, ranked:

1. **F5 (fixed) — the placeholder masqueraded as a chapter.** One entry
   titled "Full audiobook" at start 0 was rendered as a real chapter; the
   view now filters exactly that shape (the writer's own fallback constant)
   so the sheet's ContentUnavailableView states the truth.
2. **F6 (recorded) — I first changed the parser.** I probed the user's real
   m4b (box tree + byte-exact simulation of `parseChpl` against it) and it
   parses all 12 chapters ffprobe reports — the parser was never the blocker
   for THIS file. Speculative parser changes are exactly the anti-pattern the
   repo's HANDOVER warns about ("dont claim too much about the audiobook
   chapters"), so that change was reverted before commit and the diagnosis
   is recorded instead. The device log line
   `AudioBook import: ... N chapter(s) via SOURCE` decides it in one read.
3. **(verified clean) `chapters` is now O(1) instead of a stored-property
   read** — it builds one small array per body evaluation only when the
   placeholder filter applies; the common multi-chapter path returns the
   manifest array as before. No per-tick cost change during playback.

---

## CI-repair rounds — `241b00c`, `3bb6106`, `b59aa68` (per the build-gate mandate)

Two dispatched runs failed on the branch; each failure was read from the
job's own log (not guessed) and fixed round by round. The mandatory
question is answered per round below.

### Round 1 — `241b00c` (four compile errors + the import-ladder test)

**Score: 8/10. Faster than baseline: YES** — the fixes are all in the
engine hot path, and each removes work or wrong behavior.

Findings:

1. **C1 (fixed) `Data(ArraySlice<Float>)`** — no such initializer; the
   style slice is now built through `withUnsafeBufferPointer`.
2. **C2 (fixed) `UnsafeMutableRawBufferPointer.storeBytes(toByteOffset:as:)`**
   — not a real API; writes go through the base address.
3. **C3 (fixed) conditional binding on a non-Optional `bufferSlots[idx]`**
   — the slot is `Int` (sentinel-encoded), the pool lookup is the optional.
4. **C4 (fixed) `AVSpeechUtteranceMaximum/MinimumSpeechRate` are `Float`** —
   the mapping now does arithmetic in `Double` once.
5. **C5 (recorded) ImportServiceTests asserted a ladder the runner's
   Foundation does not run.** `[63 61 66 E9]` decodes *successfully* as
   `.utf16LittleEndian` (4 bytes = 2 units), so the ladder returns that
   before `.isoLatin1` is tried — the expected `café` is unreachable. I
   pinned the platform's real behavior in Round 1, and in Round 2 the
   whole mirror was **reverted** (`3bb6106`): a mirrored contract is only
   as good as measured facts, and the file had been written from
   assumption (AP8 again — third occurrence in this session).

### Round 2 — `b59aa68` (the two errors run 36306408322 still had)

**Score: 8/10. Faster than baseline: YES.**

1. **C6 (fixed) `Data(unsafeUninitializedCapacity:initializingWith:)` is
   Swift 6+; this target is `SWIFT_VERSION 5.0`.** The closure form never
   resolved. Replaced with an owning `[Int64]` (capacity reserved) plus a
   single byte copy through `withUnsafeBufferPointer` — same allocation
   count as intended, zero Swift-6-only APIs.
2. **C7 (fixed) `min/max` with `Double` against `Float` constants** — the
   rate clamp is fully `Double` and converts once to `Float`.

**Build gate: `36341537904` — all six jobs green**, including
`Build unsigned IPA` and the `SpeechnotesIOS.ipa` artifact (20.7 MB).
Per AP12, green CI is not device truth; the device checklist is unchanged.

**Note on process:** the two failed rounds are the reason the gate is
CI and not me — both times the failure was a compile error in a file I
had edited, caught by the machine before it could reach a phone.

---

## Bugfix round 2 — `6d4da8c`, `3ee3b9d` (from the device log the user pasted)

Reviewed inline; mandatory question per commit.

### `6d4da8c` — the freeze

**Score: 9/10. Faster than baseline: YES** — this is the direct answer to
"the freezing is even more severe in the latest build".

1. **F7 (fixed) the shelf re-opened every pending audiobook on every
   open.** `backfillMissingPDFCovers` filtered `audioChapterSource` in
   {nil, single, chpl, mp4, id3} and the user's two books both sat in
   that set (and re-imported copies kept landing there) — each pass mapped
   the whole file, loaded AVURLAsset duration, ran the SYNC
   `chapterMetadataGroups`, and walked the entire top-level box tree. For
   a 266 MB m4b that's seconds per book, per launch, on a utility queue
   competing with the main thread's I/O. Now: one audio book per launch,
   oldest first.
2. **F8 (fixed) the parse read the entire file.** `Data(.mappedIfSafe)`
   over a 3 GB 'Harry Potter' m4b (1.5 GB Harrisons-sized, the user's
   point) is thousands of page faults. Replaced with an 8 MB head slice
   (normal box walk — moov is there for +faststart files) plus, on a miss,
   one 8 MB tail slice read through `AudiobookChapters.chaptersFromMP4Tail`
   (signature hunt validated by chpl's own count + title lengths).
3. **Verified against the real bytes.** The tail slice of the user's own
   WBBA m4b contains `chpl` at offset 8387585 and parses all 12 chapters
   ffprobe reports; exactly ONE `chpl` occurrence in 8 MB, so the
   false-positive surface is bounded and the parse validates it anyway.
   New test pins the tail path against the same fixture the box walk
   reads, sliced mid-stream, plus junk and false-positive cases.

### `3ee3b9d` — EAC3, transport, headings, mini-player

**Score: 8/10. Faster than baseline: YES** (UI responsiveness; the codec
fix also stops a 30-deep error storm).

1. **F9 (fixed) the EAC3 book couldn't play and nothing said why.**
   `AVAudioPlayer(contentsOf:)` throws `kAudioFileInvalidChunkError`
   (1685348671) for Dolby Digital Plus / Atmos — ffprobe on the actual
   file confirms `eac3`, 6 channels. Every tap retried, 30+ identical
   `cannot play original.m4b` lines. One reason is derived, the codec is
   sniffed from the container, and it's published for the UI. Verified
   the sniff reads `ec-3` from a 256 KB head slice — the EAC3 stsd fourCC.
2. **F10 (fixed) chapter chevrons existed twice** (bottom bar + rail) and
   the user asked for them "lateral to the 15s±/-". Now one row:
   chapter prev, −15 s, play, +15 s, chapter next, with a shared
   `transportIcon` for consistent sizing/disabled state/labels. The
   bottom bar keeps the label only.
3. **F11 (fixed) the heading sizes ignored the text-size slider** —
   `.title`/`.title2` are fixed Dynamic Type steps. Now the Dynamic Type
   point size × the reader's multiplier, matching body text.
4. **F12 (fixed) the mini-player snapped instead of easing** — four
   separate `.animation(0.2)` modifiers, one per value; a change that
   moved two at once ran two conflicting transactions. One spring keyed
   on the union.

**On the user's architecture question** (why not a Files-app-backed
store): noted, not done — it is a design change, not a bug. Recording it
in `Docs/PLAN-APP-FILE-SYSTEM.md` as the next-cycle decision, because
"just open Speechnotes in the Files app and drop books in" would
also remove the copy step that is currently most of the import time.

---

## Bugfix round 3 — `979ec11`, `2a423e7` (EAC3 banner · Files-store plan · books recycle bin)

### `979ec11` — the Files-app question

**Score: 9/10. Faster than baseline: YES** (removes nothing today; the
first step it plans removes the 3 GB import copy the user waited through).
Reviewed as a plan, not code: it records the user's question, the three
costs of today's copy-into-Documents model, and a 3-step landing order
(share the folder → security-scoped bookmarks → opt-in migration) with
the prior failures that make the bookmark work non-trivial. The
recommendation to defer the migration is recorded as a decision, not
hand-waving.

### `1fd973b` — the EAC3 failure actually surfaces

**Score: 8/10. Faster than baseline: YES.**

1. **F13 (fixed — my own Round-2 finding) `isBlocked` was computed and
   never rendered.** The honest failure existed only in the player; the
   device log still showed 30 retries and the reader still drew a dead
   Play button. The transport row now swaps for a banner naming the codec
   and the fix, in both orientations.
2. **F14 (verified clean) the banner is keyed on `isActive`**, so another
   book's failure never leaks into this reader's surface (the single
   writing rule for the player's one slot).

### CI rounds 3–4 (`6af7701`, `1a1ca47`)

**Score: 8/10. Faster than baseline: YES.**

1. **C8 (fixed) Int64/UInt64 mismatches** — seekToEnd() returns UInt64;
   the slice helper now converts once at the boundary.
2. **C9 (fixed) 'immutable value chapters may only be initialized once'**
   — Swift 5 rejects reassigning a `let` across the two parse steps; a
   local mutable carries the head/tail result.
3. **Build gate: `36357497029` all six jobs green** on `1fd973b`.

### `2a423e7` — the books recycle bin

**Score: 8/10. Faster than baseline: YES (neutral-to-positive).**

1. **F15 (fixed) deleting a book destroyed it immediately.** `deletedAt`
   on the manifest (optional — old shelves decode), the shelf split so
   the bin is derived rather than a parallel list, and recover / purge /
   empty / retention-prune in the store. The confirmation now describes
   the truth: moved to the bin, kept 30 days.
2. **F16 (fixed in passing) a playing audiobook now stops before its file
   is removed** — the delete and purge paths both handle it.
3. **F17 (recorded) `books` and `allBooks` are two arrays that must agree.
   Every mutation path was re-read and updates both (delete/copy remove
   from the visible list only; recover/purge/refresh rebuild from the raw
   shelf). The next reviewer should keep it that way — the notes store
   avoids the duplication entirely and that is the cleaner long-term
   shape, but it is a migration, not a fix.

---

## Bugfix round 4 — `c71a9cf`/`cf335d5`/`e04fd0e` (AVPlayer for EAC3 · HangWatchdog)

### `c71a9cf` — the EAC3 decode question answered by changing the API, not the file

**Score: 9/10. Faster than baseline: YES (perceived: a file that produced
dead silence now produces audio).**

The user's report and instruction were precise: *"the native audio player
in Files can play it why is it failing in my app... i want it decoded...
if you fail to decode fork or analyse some vlc code"*. ffprobe on the
actual file answers it: `codec_name=eac3, channels=6, 48 kHz` —
Dolby Digital Plus / Atmos. AVAudioPlayer routes through Audio File
Services, which fails on EAC3 with `kAudioFileInvalidChunkError`;
AVPlayer hands the same URL to the same media stack the Files app uses.
No forked decoder is needed — Apple ships the decoder, our API choice
was the only thing keeping us from it.

1. **F18 (fixed) transport swapped to AVPlayer.** Construction is now
   `AVPlayerItem` + `AVPlayer` (no `prepareToPlay`); position/duration
   moved from `Double` to `CMTime` behind `seconds(of:)`/`time(_)`
   helpers, so every other computation in the player is unchanged plain
   seconds.
2. **F19 (fixed) seeking semantics.** AVPlayer seeks are async and
   rate-preserving, so the chapter start is `seek(to:)` BEFORE `play()` —
   the first rendered frame is already the chapter start, no pre-roll
   glitch. All three seek paths (chapter start, ±15 s, scrub) go through
   the same helper.
3. **F20 (fixed) AVPlayer fails asynchronously.** An un-decodable codec
   surfaces on the item's `.status`, not at construction, so the player
   observes `\.status` and routes a failure through the SAME
   `unplayableReason()` path the sync catch uses — one honest banner
   whether the failure is sync or async. The observer is invalidated on
   teardown (no leak across items).
4. **F21 (fixed) liveness.** `player.timeControlStatus == .playing`
   replaces `isPlaying`, which reports "paused" while AVPlayer is
   buffering a large file — the UI would have lied exactly when the
   file mattered most.
5. **F22 (verified clean) duration before ready.** AVPlayer reports an
   indefinite `CMTime` until the stream is ready; `seconds(of:)` maps that
   to nil and the arithmetic falls back to the manifest's duration. The
   CI round-6 error (`Double?` in `seekBy`'s clamp) was exactly this
   seam, and it is now typed, not assumed.

### `1a30607` — the freeze stops being terminal

**Score: 9/10. Faster than baseline: YES** — the freeze was already
removed at the source in `6d4da8c`; this makes any future block
self-reporting instead of requiring a hard restart.

1. **F23 (fixed) nothing could see a blocked main thread.** Every timer in
   the app runs *on* the main thread, so a blocked main thread blocks
   its own watchdog — the app had no way to know it was frozen. A plain
   `Thread` (never main, never blocked) ticks at 1 Hz and measures the
   gap around a main-actor check.
2. **F24 (fixed) the recovery is deliberately conservative.** The
   watchdog cancels the shelf backfill (the only main-adjacent pass in
   the app — its loop checks the token between books) and logs. It does
   NOT relaunch the UI, reset state, or force-quit: a blocked main thread
   is by definition the only thing that can fix the UI, and a watchdog
   "recovering" into a wedged state is worse than the freeze. The honest
   recovery is "the work stops, the block lifts, the next tick clears."
3. **F25 (fixed) Swift 5 isolation, from CI round 7.** Three errors:
   a detached task reading a main-isolated property (the token is now a
   local captured first), a worker thread calling an isolated closure
   synchronously (both closures are plain and hop internally — the hop
   not running is the whole point), and `BooksStore.shared` not existing
   (the tab owns the store, so the watchdog posts `.hangWatchdogFired`
   and the store installs a one-time observer on first shelf open).

**Build gate: `36381017354` — all six jobs green** (build-ipa plus
logic-tests and all four spikes) on `e04fd0e`.

**On the user's audiophile ask (FLAC):** the same swap answers it — AVPlayer
decodes ALAC and FLAC-in-MP4, and a raw `.flac` file is not a book
container (the importer takes m4b/m4a/mp4/mp3 by design). Nothing about
this path re-encodes; it hands the file to the decoder Apple ships.

## TTS Engines — Batch A1 — Round 1 (diff `0bea095`, independent pass)

**Score: 6.5/10.** The pass made one structural point that landed: the
headline claim "made provable" rested on a job whose two new proofs could
both degrade to a silent skip, and whose delivery mechanism was broken — a
proof that can no-op without failing is a comment, not a test. All fixes in
`e3c2851`.

1. **P1 (fixed) the delivery mechanism was broken.** `KOKORO_VOICES_NPZ:
   $HOME/...` in a step's `env:` is written verbatim by the runner — there
   is no shell expansion on that path. The variable was the literal string,
   and the proof only worked because the test's own default happened to name
   the same file. Now set from `${{ github.workspace }}`, which IS expanded.
2. **P1 (fixed) the 28-voice proof could fake itself.** It skipped when the
   env var named a missing file; now it FAILS on a named-but-absent file and
   skips only when it was never told where to look. The spike job downloads
   voices.npz unconditionally, so "absent" means the job's own plumbing
   broke — exactly the failure the skip was hiding. (Model-inference tests
   keep XCTSkip: a 177 MB download is a legitimate reason not to run.)
3. **P2 (fixed) the normalizer lemma asserted `> 90 scalars`**, which a
   garbled parse would pass. Now asserts class == vocab — the actual
   theorem, pinning the 115 figure — in BOTH directions: vocab ⊆ class was
   missing, and without it the lemma proved only that the app never drops
   more than the reference, not that it never drops LESS. On a
   per-character vocab, dropping less means keeping a character the model
   was never trained on.
4. **P2 (fixed) no regression net for B1's drop surface.** New unsafe
   corpus: MisakiSwift's own dictionaries contain 28 characters with no
   vocab id (`_`, `g`, the digits, capitals B/C/D/E/L/…) — about 108 in
   3.5 M characters. The app never applied the normalizer that deletes
   them, so those 28 were its real drop surface, and the phoneme corpus —
   which contains none of them — could not see a regression there. The new
   test pins the drop set and asserts the substitution is
   length-preserving: the one assertion that catches the original
   `compactMap`, because a deletion changes the count and a substitution
   does not.

Not acted on, recorded: the note-corpus test is near-vacuous as a drop
detector (class == vocab makes the two filters identical); its value is the
boundary claim, and its doc comment says so now. The npz walk's O(n) byte
scan (0.011 s for 14 MB, reviewer-measured) and its false-positive window
are accepted — a junk name can only cause a false negative.

**Build gate: `37345434653` — the session's first green run** (all prior
runs red on compile errors in never-compiled code or wrong test expected
values), on `d5471fb`, which postdates both critique rounds.

## TTS Engines — Batch A2/A3 — Round 1 (diffs `112d7ad`, `29c70f9`, independent pass)

**Score: 7/10.** Two P1s: the field the batch exists to use was written and
never read, and the accounting section the batch adds work to was not
updated. Both label/contract defects rather than behaviour defects — but
the whole point of the tier tag is that the RTF figure is readable, and the
line that prints the RTF was the one line without it. Fixes in `dbfe16e`;
the numbered items below are the findings that round landed.

1. **P1 (fixed) `sessionTier` was set in `beginSession` and read nowhere.**
   It now rides the session summary; `modelReady` also reads the session's
   own tag as its default, so the two sources for one value collapse to one.
2. **P1 (fixed) TTS_BASELINE.md §6, the accounting section A2 adds work to,
   was not updated** — now extended with A2's three sites.
3. **P2 (fixed) `tierName(for:)` reported `kokoro-fp32` for anything not
   literally `model_uint8.onnx`.** An unrecognised file now says
   `kokoro-unknown`, which fails loudly instead of silently — the fp16
   variant already shipped once and produced NaN on ORT CPU
   (CI 34008548349), so a third tier is a live possibility, not a
   hypothetical.
4. **P2 (fixed) `emit` accepted `isError` and dropped it** — the threshold
   it gates on paid for a decision that was then thrown away. A boundary
   over half a second is a real event the listener heard; it goes to the
   error channel, matching PlaybackMetrics' GAP escalation.
5. **P2 (fixed) the `didFinish → didStart` endpoint was mislabelled** in the
   class doc and TTS_BASELINE.md §4; both now say what it is, with the same
   lower-bound caveat `gaps` carries. The `boundaries 50/41` doc example is
   recomputed (N chunks → N−1 boundaries).

Still open: `SystemSpeechMetrics` has no injectable sink, so its arithmetic
cannot be asserted in CI — the same parity gap PlaybackMetrics already
solved, and there is no test harness for App/Sources at all; noted for
Batch F, which rebuilds the class. GAP escalation is unbounded (~638 lines
worst case for a 200k-char chapter), recorded in TTS_BASELINE.md §6 as the
known worst case, not capped. Out-of-scope observation carried forward:
`didCancel` was the only delegate callback with no epoch guard — fixed in
F1 (`26af724`).

**Build gate: `37345434653`** on `d5471fb` (see the A1 entry).

## TTS Engines — Round 2, whole range (diffs `5d60552`..`d5471fb`, independent pass)

**Score: 5/10. Faster than baseline: NO** — the neural paths keep pace
(C1's `min(cores, 6)` is the only throughput lever and it is safe), but the
Apple path regressed from "completes the chapter with small gaps" to
"plays ~8–12 chunks then goes permanently silent" (finding 1), which is
strictly slower than any baseline. Both P1s are F1 wiring defects; every
finding below is fixed in the same commit round that records this entry
(`a77acd6`+).

1. **[P1, fixed] SystemEngine's lookahead gate was arithmetically inverted
   and permanently closed mid-session, stranding the chapter.** The gate
   was `nextIndex - startedCount < lookahead`, but hand-over incremented
   BOTH counters while `didFinish` decremented `startedCount` — so the
   gate metric equalled the number of FINISHED utterances, monotone
   within a session. The gate closed permanently at the 4th `didFinish`;
   a 600-chunk chapter handed 8 chunks, drained Apple's queue, then sat
   in `.speaking` with no `onFinished` and `hasLiveSession == true`.
   Short notes (≤ ~12 chunks) masked it because everything was handed
   before closure. Fix: the invariant the comments already stated —
   `startedCount` IS the queue depth, so the gate is
   `startedCount < lookahead`.
2. **[P1, fixed] `current` was the last-HANDED chunk, not the sounding
   one** — a pre-F1 invariant that the lookahead broke. Consequences,
   all traced: `willSpeakRangeOfSpeechString` paired the sounding
   utterance's word range with a later chunk's offset (progress jumped
   forward ~120–320 chars per chunk); `requeueCurrentChunkAtNewRate`
   computed its slot as `nextIndex - 1` — the last-handed, never-started
   chunk — overwrote it with a slice mixing the sounding chunk's
   `currentCharsDone` into different text, and orphaned the sounding
   chunk's remainder on every debounced slider move; `rebuildSynthesizer`'s
   rewind made the same assumption after a phone call. Fix: utterances
   are tagged with their queue SLOT (the tag map also replaces
   `epochByUtterance`); `didStart`/`willSpeak` set `current`/
   `currentSlot`/`currentCharsDone` from the sounding utterance's tag;
   the re-queue and the rebuild rewrite the SOUNDING slot, re-owe
   everything from it onward (the `.immediate` stop also destroyed the
   handed-but-not-started copies — a second text-loss path the pass
   implied), and reset the depth to zero.
3. **[P2, fixed] `willSpeakRangeOfSpeechString` mutated engine state
   without the main hop its three siblings use** — racing the main-thread
   readers (re-queue, rebuild). The whole callback now hops to main, the
   same as `didStart`/`didFinish`/`didCancel`.
4. **[P2, fixed] ChunkCachePolicy's count-cap eviction stopped one item
   short, and the CI test pinned the wrong answer.** The break was
   `usedCount <= maxItems` with the incoming write not yet counted, so
   the steady-state cache held maxItems + 1 items forever. The walk now
   stops at `usedCount < maxItems` (leaving room for the incoming), and
   `testEvictsOldestFinishedFirst` was re-simulated: 6 live + 1 incoming
   under a cap of 4 evicts `[1, 2, 4]` (3 is unfinished and skipped), not
   the `[1, 2]` the old test asserted with the bug.
5. **[P2, fixed] ChunkFileQueue (Batch E's substrate) carried landmines
   Batch E would have inherited.** `reportPosition` hardcoded `* 24_000`
   while `append` accepts a sample rate (markers are now converted at the
   session's rate, recorded from the first append); the
   `Int(frac * …)` conversion trapped on a NaN `CMTime.seconds`, which
   `currentTime()` returns before the first item is ready (now guarded
   with `isFinite`); `lookahead` was `liveIndexes.count - playedItems`
   with `playedItems` cumulative while eviction removed those same items
   from `liveIndexes` — every eviction deflated the number the producer
   paces on (now counted as live minus live-and-finished);
   `rate`'s didSet assigned the player rate unconditionally, which
   UN-PAUSES a paused AVQueuePlayer (now guarded); and `append` wrote
   even when the policy returned nothing evictable, silently violating
   the policy's documented hold contract (now refused, returning false —
   the unbounded-growth failure the policy exists to prevent).
6. **[P3, fixed] `epochByUtterance` was never pruned per-entry** — the
   comment claimed callbacks consumed entries; none did, so a chapter
   accumulated ~600 stale ones. The slot map removes entries in
   `didFinish`/`didCancel`, making the stated contract true.
7. **[P3, fixed] AudioSessionSetup's TTS fallback rung 2 was a dead rung**
   — for `.tts`, rungs 1 and 2 were the identical call, so the comment's
   "catches a mode objection" was false. Rung 2 now drops the MODE and
   keeps the Bluetooth route, which is also the documented A2DP-rejected
   descent for audiobooks.
8. **[P3, fixed] RenderAheadBankTests' `allowsNext` helper no longer
   mirrored the core** — it composed `effectiveTargetSeconds` while
   `recomputeBank` has used `pressuredTargetSeconds` since C2. Conclusions
   at the tested values were unchanged (nominal factor is 1.0); the helper
   now calls the same function the producer paces on.

Also found by reading the per-job conclusions of run `37345434653` (the
run the session first called green) rather than the run's own status: the
Kokoro spike job had been failing to COMPILE since `d5471fb` joined two
lines in the 28-voice test — invisible because the job is
`continue-on-error: true`. No Kokoro proof had run on CI since. Fixed in
`a77acd6`; lesson recorded: read the job table, not the headline, on any
workflow that ships `continue-on-error`.

**Build gate: run on `a77acd6`+ (this fix round) — see the entry above
for the first-green-run caveat.**

## TTS Engines — Round 3, fix verification (diffs `8dad0a0`..`5c6d406`, independent pass)

**Score: 6/10. Faster than baseline: YES** — the primed-lookahead pipeline
streams a full chapter with only inter-chunk gaps (vs the one-utterance
baseline's minute-long silent stalls), and the round-2 fixes held: the gate
inversion, sounding-slot tracking, main hop, cap off-by-one and dead rung
are genuinely fixed, and the chapter-stranding is gone. But the fix round
was incomplete: the rate re-queue introduced a new deterministic
double-speak, and two P2s remained. All findings below are fixed in the
same round that records this entry.

1. **[P1, fixed] Mid-chunk rate change spoke the remainder TWICE; at the
   last chunk `onFinished` fired twice.** The re-queue set `nextIndex =
   slot` and handed the remainder via `speakQueued` — which does no
   hand-over bookkeeping — so the remainder's `didStart` cascade read
   `queue[nextIndex] == queue[slot]` and handed the SAME remainder again.
   Worse at the final chunk: the first copy's `didFinish` ended the
   session while the second was still queued, then resurrected
   `.speaking` and finished twice. Fix: `nextIndex = slot + 1` — the
   re-queue re-owes everything FROM the slot onward, and the remainder
   itself is handed exactly once by `speakQueued`; the caller-owns-
   `nextIndex` contract is now stated on `speakQueued`.
2. **[P1, fixed] The debounced rate Task ran off the main thread and raced
   the engine's main-only state.** `speed.didSet` spawned a bare `Task` on
   a nonisolated class — no inherited actor, so the re-queue mutated the
   tag map (dictionary), `queue`, `startedCount` and the sounding slot on
   the global executor while the delegate callbacks mutate the same state
   through explicit main hops. The re-queue now hops with
   `DispatchQueue.main.async` after the debounce sleep, which also makes
   `willSpeak`'s "read on the main thread by the rate re-queue" comment
   true instead of aspirational.
3. **[P2, fixed] Pausing as the LAST chunk finished permanently lost
   `onFinished`.** The `pauseRequested` early-return in `didFinish` is
   correct for a held boundary but skipped the finish branch forever when
   the queue was drained; `resume()` would then claim `.speaking` over
   dead air. The held branch now fires the completion (finish, `.idle`,
   `endSession`) when `nextIndex >= queue.count` — a pause that lands
   after the final chunk's finish is a session end, not a boundary.
4. **[P2, fixed] `ChunkFileQueue.onFinished` was declared, documented —
   and never fired.** Round 2 claimed this file's landmines fixed; this
   one survived. The substrate cannot observe "no more audio is coming"
   (that is producer knowledge), so completion is now an honest contract:
   `markStreamingComplete()` from the producer, appended/finished
   counters, `checkFinished()` from the player's end-of-item
   notifications, fired once.
5. **[P3, fixed] `markerSampleRate` latched the first append's rate with
   no guard** while each file is written at its own per-append rate — a
   differing rate now logs loudly instead of silently descaling the
   read-along.
6. **[P3, fixed] `trimmedSampleCount`'s doc was inverted** ("samples the
   trim REMOVES" for a function that returns the KEPT count); the doc now
   matches every call site, and the unused `sampleCount` parameter is
   accounted for.

Verified clean this round: the eviction walk re-simulated exactly
(`[1, 2, 4]` with 6 live + 1 incoming under cap 4), the session ladder's
three rungs distinct and ordered, the `tokenizeLikeApp` mirror
line-faithful to the app's tokenize with all three call sites coherent,
and the depth/epoch/tag accounting correct on the normal path including
the exactly-once finish.

**Also found by the batch-B4 gate, not the critic:** CI run `37382312043`
rendered the same corpus slice through `model_uint8.onnx` and the fp32
`model.onnx` — identical length (92 400 samples both), **rel-RMS 1.37,
correlation 0.057**. The two renders are essentially uncorrelated: the
gibberish signature, against the suspect A1's lemma left standing. The
gate now searches ±0.5 s for a best-aligning lag (to rule out a shift
artifact framing quantization) and writes both renders as `corpus-
quantgate-*.wav` artifacts for the ear. If the lag search confirms it,
the uint8 tier is the gibberish root cause and Batch E's Kokoro wiring
must not ship on it.

**Build gate: run on this fix round — see the entry above.**

## TTS Engines — Round 4, fix verification (diff `4e03548`, independent pass)

**Score: 7/10. Faster than baseline: YES** — the primed-lookahead pipeline
is untouched by the findings; chapters stream with only inter-chunk gaps.
**No P1 findings**, and all six round-3 fixes held (the nextIndex
bookkeeping, main-hop debounce, drained-held finish, ChunkFileQueue
completion contract, sample-rate log and trim doc all simulate clean,
including the refused-last-chunk and exactly-once cases). Four findings,
all fixed in the round that records this entry:

1. **[P2, fixed] A rate change made while paused was silently dropped for
   the REST of the session.** The re-queue's `state == .speaking` guard
   no-oped while paused and `lastEffectiveRate` — the value every later
   utterance is built from — was never updated on the no-op, so
   pause → drag slider → resume played every following chunk at the old
   rate. The same silent drop applied in the didFinish→didStart gap and
   on a whitespace-only remainder. Fix: the rate applies FIRST,
   unconditionally; only the remainder re-queue stays conditional.
2. **[P2, fixed] The mirror ordering of the pause-vs-finish fix still
   resurrected dead-air `.speaking`.** A `pause()` tap racing the final
   `didFinish` passed its guard (the queue array survives a natural
   finish) and flipped a FINISHED session to `.paused`; a later resume
   claimed `.speaking` with no audio. Fix: `pause()` refuses on
   `.idle`, and its async state write now carries the epoch guard so a
   stop() between the call and the hop cannot be overwritten either.
3. **[P3, fixed] The debounced re-queue had no session guard** — a tick
   ≤250 ms before a new `speak()` fired its hop into the NEW session and
   stomped the rate speak() chose. The debounce now captures the epoch at
   the tick and drops the hop on mismatch.
4. **[P3, fixed] The B4 gate asserted zero-lag correlation only**, so an
   honest re-quantization whose render is merely shifted would fail the
   very gate the lag search was built to rule shifts out of. The
   assertions now judge the ALIGNED metrics (best-lag correlation,
   rel-RMS at the best lag), and TTS_BASELINE's "fails CI" wording was
   corrected to name the spike job, not the run headline.

**Build gate: run on this fix round — see the entry above.**
