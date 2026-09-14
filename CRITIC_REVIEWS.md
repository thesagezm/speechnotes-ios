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
