# TTS Regression Audit — SpeechNotes

Scope: every commit from `bf2198d` (2026-08-16, Phase 0) to `070d38f`
(2026-09-10, Batch A) — **214 commits over 26 days**. This document is the
history half of Batch A's Phase 0 deliverable; `TTS_BASELINE.md` is the
measurement half.

**What "confirmed" means here.** Every regression below carries an
*introducing* commit and either a *fixing* commit or the word **LIVE**. Both
ends were located with `git log -S` on the identifier that changed, not
inferred from commit subjects. Where the attribution is weaker than that —
where I could identify the fix but not bisect the exact commit that
introduced the defect — the entry says so explicitly (see R9). Nothing in
this document is a hypothesis dressed as a finding.

**What this document cannot claim.** No benchmark number appears anywhere in
it, because none exists: nothing in this repository has ever been measured on
a device. Green CI does not prove LiveContainer launch behaviour, and the two
worst incidents in this history (R12's black screen, R1's "cut off after 3
words") were both CI-green and device-only. See `TTS_BASELINE.md` for the
model that Batch A's instrumentation exists to turn into numbers.

---

## 1. The six eras

The commit-date histogram is not flat, and the shape is the history:

| # | Era | Dates | Commits | Opens with | Closes with |
| --- | --- | --- | --- | --- | --- |
| 1 | Foundation & engine bring-up | 08-16 | 49 | `bf2198d` Phase 0 | `663ce82` v1.0.0 Supertonic end-to-end |
| 2 | v1.1/v1.2 UI + the type-checker burn | 08-17 → 08-18 | 29 | `591fa4e` background audio added, read-along **removed** | `678f020` restore exact v1.1 editor |
| 3 | v1.3 features | 08-19 → 08-20 | 9 | `e1858c7` first persistent playback position | — |
| 4 | Markdown v2 + bisect device-debugging | 09-02 → 09-05 | ~20 | — | `42ac74c` "scrub all launch-time side effects for LiveContainer crash" |
| 5 | v1.4/v1.5 books + PDF | 09-05 → 09-07 | ~85 | `ad7f4f1` v1.4 P1 | `fdbf4ff` v1.5.0 release |
| 6 | Post-release upgrades | 09-08 → 09-10 | ~28 | `0250513` upgrade batch 1+2 | Batch A |

Per-day counts: 49 / 8 / 21 / 3 / 6 (Aug 16–20), 4 / 5 (Sep 2–3), 27 / 38 /
25 / 11 / 14 / 3 (Sep 5–10).

Three things about this shape matter for the audit:

**Era 1 is 49 commits in one day and contains four regressions and three of
their fixes.** v0.4.0 → v0.5.1 → v0.5.2 → v0.6.1 → v0.7.0 → v0.8.0 → v0.9.0
→ v0.9.4 → v1.0.0 all landed on 2026-08-16. The turnaround was fast because
the user was reporting device symptoms same-day and the fixes were aimed at
real reports — `c34f3ad` opens with "On-device diagnosis from user report +
log", `799092a` with "User-diagnosed". The cost of that speed is visible
below: `799092a` fixed a crash and introduced a 25-day-old live defect (R16).

**Era 2 contains the single most expensive sequence in the history: 19
consecutive commits on 2026-08-18 fighting one Swift expression.** Verified
by date histogram, in order: `447c099, 540cb04, 7cc6c2e, 5af3c69, 19e9070,
dfe0d27, b781660, 8189b15, c0d0ccd, 41b59be, 2ba0b41, 83beb51, 1a60a23,
78b7858, ff88790, aa29aa7, 41cfbb3, 2adc1f3, f2fb11f`. All of them attempt
the same `NoteEditorView` change against Swift's expression-complexity
limit. The sequence ends in `a011c5c` — a revert whose message names
landscape keys as the "prime suspect for LiveContainer launch black-screen" —
and `678f020`, which restores the exact v1.1 editor. **Nineteen CI runs bought
one revert.** This is the origin of the plan's type-checker-budget constraint
and the reason Batch G mandates "any view additions in small private computed
vars or new files".

**Era 5 is the largest (≈85 commits) and produced both the worst live
regression (R15, resume dead) and the pipeline that everything since has
been repairing.** `852db44` deduped two engines' pipeline machinery into
`StreamingTTSPlaybackCore`; `292df75` replaced a single UserDefaults bookmark
slot with a per-item `BookmarkStore`. Both were correct consolidations. R15
is what happens when a consolidation moves code without re-auditing the order
it runs in.

Era 6 is where `d25131a` lives — one commit that fixed five separate
regressions (R7, R8, R9, R10, plus M14 live-rate). It is the most
regression-dense single fix in the history, and its audio-session half is the
reason Batch E must be conservative about `setActive`.

---

## 2. Fixed regressions (R1–R14)

Each entry: **introduced by → fixed by**, age at fix, mechanism, evidence.

### R1 — Audio graph reconnected on every chunk ("cut off after 3 words")

`133f77d` (v0.4.0, 08-16) → `c34f3ad` (v0.5.1, 08-16). **Age: hours.**

v0.4.0's new streaming pipeline called `connect` while the engine was running
and the node was playing, on *every* chunk. Chunk 1 played; chunk 2's buffer
was silently dropped and its completion handler fired late. The user-visible
symptom was speech dying mid-line at the `generating → speaking` transition.

Evidence — `c34f3ad`'s message quotes the device log directly: *"Audio graph
reconnected on EVERY chunk (connect while engine running and node playing) —
chunk 1 played, chunk 2's buffer was silently dropped, its completion fired
late. That's the 'cut off after 3 words' bug. The graph is now wired once per
format."*

### R2 — Unbounded buffer and MLX GPU-cache accumulation

`133f77d` → `c34f3ad`. **Age: hours.**

Every chunk buffer was retained for the life of the session, and MLX's GPU
cache grew with each generation, so long notes climbed until jetsam. Fixed in
the same commit as R1, which is why the two are always seen together: a
single on-device diagnosis surfaced both.

### R3 — Oversized sentence sent as one giant chunk (token-limit crash)

`133f77d` → `799092a` (v0.5.2, 08-16). **Age: hours.**

The v0.4.0 chunker *deliberately* kept an oversized sentence as a single
chunk. A run-on paragraph went to KokoroSwift as one call and tripped its
per-call token limit, so long notes failed outright. The fix was
`splitOversized` — split at word boundaries, hard-cut only unbroken tokens —
plus a 160-char cap on every synthesis call.

Evidence — `799092a`: *"User-diagnosed: long notes failed because the chunker
deliberately kept oversized sentences as single giant chunks — a run-on
paragraph went to KokoroSwift as one call and tripped its per-call token limit
(observed ceiling ~36 words ≈ the 200-char first chunk)."*

**This fix introduced R16.** That sentence — *"≈ the 200-char first chunk"* —
is the moment the fast-start parameter was misread as a token-budget
parameter. See R16.

### R4 — Notes never opened (navigation destination never registered)

`f7c0367` (v0.9.0, 08-16) → `f8582c0` (v0.9.4, 08-16). **Age: hours.**

v0.9.0's list rewrite moved to value-based `NavigationLink` and paths but
never registered `navigationDestination(for: UUID.self)`. Tap-on-note and the
new-note button did nothing at all.

Evidence — `f8582c0`: *"Notes never opened: value-based NavigationLink/paths
need a navigationDestination(for: UUID.self), which v0.9.0's list rewrite
never registered."*

### R5 — Per-keystroke full-store JSON encode and synchronous disk write

Pre-v0.9.4 store design → `f8582c0` (v0.9.4, 08-16). **Age: days.**

Every keystroke encoded *all* notes to JSON and wrote the file synchronously
on the main thread, then re-sorted and re-rendered the full list. Fixed with a
400 ms editor→store debounce, 1 s coalesced disk writes
(`NotesStore.scheduleSave`), and flushes on editor exit and `scenePhase`
change.

This is the same class of defect as R13 and R19 and the same shape as the
Batch D `@Published` coalescing item: **work whose frequency is set by the UI
event rate rather than by the user's ability to perceive it.**

### R6 — `handleInterruption` lost in an init merge, then a failed restore

`b7ea6f8` (09-06) → `fea4475` (09-06) → `6a5da15` (09-06). **Age: hours, and
the fix needed a fix.**

Merging `OnnxKokoroEngine`'s two inits dropped the interruption handler. The
first restore attempt did not actually restore it — `6a5da15`'s subject is
*"fix: actually restore handleInterruption (previous pattern miss)"*.

Three commits, one day, to put back a function that was deleted by a
mechanical merge. The anti-pattern (AP18) is that the first restore was
verified by pattern-matching the diff rather than by grepping for the symbol.

### R7 — Model-load latch bricked the engine on a transient ORT error

`d120245` (v0.6.1, 08-16) → `d25131a` (09-08). **Age: 23 days.**

`modelLoadAttempted` was set *before* the load succeeded, so any transient
failure — memory pressure, a file lock, a jetsam mid-load — permanently
disabled the engine until relaunch. `git log -S modelLoadAttempted` puts the
identifier's origin at `d120245`; it was touched en route by `ad7f4f1` and
`4708a9d`, neither of which reordered it.

The fix is the comment now in both engines: *"Only latch AFTER success — a
transient ORT error (memory pressure, file lock) used to brick the engine
until relaunch."* The bug was original to the ONNX engine, not inherited.

### R8 — Retry storm: 30–90 s of dead air per bad chunk

`5c7813d` (09-06) → `d25131a` (09-08). **Age: 2 days.**

Supertonic's duration model intermittently predicts a zero-length result
(`noOutput`), and a single flaky chunk aborted the whole session — the
*"failing like crazy"* report. The fix was 3 attempts per chunk, then a 0.5 s
silence placeholder, then continue.

That fix converted a crash into dead air. Three attempts with back-off plus a
silence gap measured 30–90 s per bad chunk on device. `d25131a` replaced it
with **one** retry then **SKIP** the chunk, and removed the silence insertion
entirely — the current core comment reads *"no silence insertion (it read as
dead air at the retry boundary)"*. The skip required new machinery: pending /
skipped / buffer-id slots so the schedule cursor steps over a gap, the
natural-finish path still firing when the *last* chunk is the one skipped, and
the read-along cursor advancing past unspeakable text.

R8 is the clearest instance of the pattern this whole audit exists to catch:
**an error-handling path that is worse to listen to than the error.**

### R9 — Superseded producer leaked until `stop()` (M17)

Producer/pacing-gate design originating in `133f77d`, centralized by
`852db44` → `d25131a` (09-08). **Age: not precisely attributed — see below.**

`speak()` replaced the pacing gate without signalling the old one, so a
producer thread from a superseded session blocked forever on a semaphore
nobody would ever signal. It was reclaimed only when `stop()` tore the
pipeline down. The fix signals the OLD gate before replacing it.

**Attribution honesty:** I can name the fix (`d25131a`, whose message
documents it as M17) and the two commits that shaped the mechanism, but I did
not bisect which commit first made `speak()` swap the gate without releasing
its waiters. `852db44` moved the code into the shared core and is the most
likely point at which the omission became structural, but "most likely" is not
"confirmed", so this entry is marked weaker than the others.

### R10 — Cold-start `OSStatus -50` spam from audio-session config at init

`883c753` (Phase 1, original `setCategory`) → moved into core init by
`852db44` (09-07), touched by `0250513` → made lazy by `d25131a` (09-08).
**Age of the spam: 1 day; age of the underlying placement: ~3 weeks.**

The audio session category was configured when the core was constructed, which
is before the app has finished launching and before the session is attachable.
Result: a wall of `OSStatus -50` in the logs on every cold start. `d25131a`
moved configuration to the first `speak()`/`play()` and, in the same change,
stopped `teardownPlayback` from force-deactivating the session.

Evidence — `d25131a`: *"the cold-start OSStatus -50 spam in logs is gone (the
session isn't attachable before the app finishes launching)"*.

**This second half is load-bearing for Batch E.** The absence of an explicit
`setActive` is *deliberate* and dates from this commit, not from oversight.
The plan's instruction — be conservative, only add it if analysis supports it,
otherwise document why not — traces directly to this line.

### R11 — fp16 Kokoro tier produced NaNs on ORT CPU

`ad7f4f1` (v1.4 P1, 09-06) → `dccd9ac` (v1.4, 09-06). **Age: same day.**

The small-tier model was shipped as fp16 to halve its size. ONNX Runtime's CPU
execution provider produced NaNs from it. The replacement is the uint8 tier
(~177 MB, same graph), which is what `onnxFilesAreValid()`'s
`> 200_000_000` threshold now exists to distinguish from the fp32 set.

A format chosen for size and not verified against the runtime that would
execute it. CI could not have caught this: the spike job that validates uint8
on ORT CPU (`Kokoro small spike`) is `continue-on-error` and postdates the
incident.

### R12 — The type-checker burn and the LiveContainer black screen

The 19-commit `NoteEditorView` series on 08-18 (`447c099` … `f2fb11f`) →
`a011c5c` (revert landscape keys) → `678f020` (restore exact v1.1 editor).
**Age: 1 day, 19 CI runs.**

See §1. Two distinct failures are braided here and it is worth separating
them, because the plan's constraint addresses only the first:

1. **Compile-time**: a large `NoteEditorView` body exceeded Swift's
   expression-complexity budget, so each attempt failed in CI rather than
   locally — and there is no local Swift toolchain at all (SpeechLogic imports
   PDFKit; nothing in this repository compiles on Linux).
2. **Run-time**: something in that series made LiveContainer show a black
   screen at launch. `a011c5c` names landscape keys as the prime suspect.
   **CI was green.** This is the second of the two worst incidents in the
   history and the reason "green build ≠ launches" is a hard constraint rather
   than a caveat.

### R13 — bisect-f regressions: freeze, typing lag, overflow, text size, image width

The bisect-f series → `5c1ddad` (bisect-g, 09-05). **Age: days.**

The freeze was a main-thread cache check doing `Data(contentsOf:)` plus a
decode on every miss. The fix split `ImageCache` into `peek()` (hit-only,
main-safe) and `image(for:)` (off-main), made `CachedImage` use a synchronous
warm path with decode strictly in a detached task, pre-resolved
`MarkdownPreviewView` thumbnail URLs off-main into a map instead of doing a
disk read and JPEG encode inside the view body, memoized parsed markdown per
source string (it had been re-parsed on every body evaluation), and routed
`ZoomableImageView` through `ImageCache` instead of `AsyncImage`'s re-read.

**R13 and R19 are the same defect in two places.** `5c1ddad` fixed the note
path in September; `88cf492` reintroduced the identical pattern on the book
path one day before this audit, doing a JPEG read and decode inside an
argument expression on the main actor. The lesson was learned and then not
carried across a subsystem boundary — which is AP5 and AP16, and the reason
Batch D exists.

### R14 — PDF page-follow during TTS, shipped then reverted

`9b54af7` (09-06) → `f5214d9` (revert, 09-07). **Age: 1 day.**

A device-feedback-driven feature: the PDF view turns itself to follow the
sounding page, with a ~1.5 s "Page N" capsule on each turn. It worked and was
rejected anyway — `f5214d9` is a clean revert with no replacement.

Included in this audit because it is the only entry whose "fix" is a removal
of working code, and because it is the strongest available evidence for the
plan's rule that device verification, not CI, is the acceptance gate. A
feature can be correct, green, on-device-tested and still be wrong.

---

## 3. Live regressions (R15–R20) — present at `070d38f`

These are the defects this execution plan exists to fix. Batches are noted per
entry. Every line cited was re-read at HEAD before being quoted here.

### R15 — Resume never fires (prime-before-read) — **Batch B**

`292df75` (09-07). **Age: 3 days at audit. The most user-visible live defect.**

`resumePlan` (`SpeechPlayer.swift:302`) and `resumeBookPlan` (`:316`) both
require `mark.charsDone >= 40` before they return a plan. The `.idle` play
branch calls **both of them after** `primeBookmark` / `primeBookBookmark`:

```swift
case .idle:
    ...
    if let note {
        primeBookmark(noteId: note.id, fullText: text)      // writes charsDone: 0
        if let plan = resumePlan(for: note.id, fullText: text) { ... }
```

`primeBookmark` (`:420`) writes `charsDone: 0` **into the store**
(`bookmarkStore.set(key, inFlightBookmark!)`) immediately before the plan
read. So the `charsDone >= 40` guard can never pass on the play path:
**resume structurally never fires, for notes or books, since `292df75`.**

Mechanism: `292df75` unified a single UserDefaults slot into a per-item
`BookmarkStore` without reordering the calls around it. Before the
unification, the prime written at play start and the resume read from a prior
session were *different storage*; after it they are the same slot, and the
prime destroys the read. No test covers it — `resumePlan` is in
`App/Sources`, which no CI job compiles for tests — and the UI still
advertises resume, so the defect is silent: "Restart from beginning" and Play
do exactly the same thing and no error is ever logged.

Severity correction vs. earlier drafts of this audit: this is the *whole* of
the resume breakage. The compounding read-along defect (R17) means a resumed
session would highlight wrong *if* resume fired — but it cannot fire, so R17
is currently latent. Fix order in Batch B (resume first, fast path second)
means R17 never becomes user-visible on this branch.

### R16 — First-chunk stall: `firstMaxChars == batchMaxChars` — **Batch C**

`799092a` (v0.5.2, 08-16). **Age: 25 days. The oldest live defect in the
codebase.**

`StreamingTTSPlaybackCore.speak()` passes the same value for both chunking
limits — verified verbatim at `852db44`'s extraction and pre-dedupe at
`dccd9ac:OnnxKokoroEngine.swift:294-298` and `SupertonicEngine.swift:172-176`:

```swift
let allChunks = SentenceChunker.chunks(
    for: clean,
    firstMaxChars: Self.chunkMaxChars,   // 160 Kokoro / 200 Supertonic
    batchMaxChars: Self.chunkMaxChars    // same
)
```

But `chunks(for:)` was *designed* in `133f77d` (v0.4.0) with a fast-start
first chunk: *"first sentence fast-start, <=400-char batches"* — default
`firstMaxChars: 200, batchMaxChars: 400`. The first chunk held off playback
for one short sentence while chunk 1 packed to twice its size; generation of
chunk 1 overlapped playback of chunk 0, hiding its latency.

`799092a` needed one thing: a 160-char per-call ceiling to stop R3's token
crash. It took that ceiling and applied it to *both* parameters, collapsing
the asymmetry. Attributed by call-site archaeology across nine commits — the
grep over `chunks(for:` at each of `133f77d, 799092a, d120245, aa7699c,
215b8a6, 663ce82, ad7f4f1, dccd9ac, 852db44` shows the signature default
(200/400) intact and the collapse arriving exactly at `799092a`'s engine edit.
Nobody has since passed distinct values in production: `git log -S
firstMaxChars` over all branches shows every post-`799092a` production site
passing one constant twice.

Consequence (arithmetic, worked out in `TTS_BASELINE.md` §2): chunk 0 is one
sentence — as few as 4 chars — and plays ~1 s at cps 15; chunk 1 packs to the
cap and at RTF ~0.5 takes ~5.3 s to generate. Dead air between sentence 1 and
sentence 2: ~4.3 s, on every play, for 25 days. Batch C's fix restores the
original asymmetry deliberately: `firstMaxChars` becomes a pack *target*
(~85 Kokoro / ~105 Supertonic, the break-even `RTF·c1` at RTF≈0.53), capped
by the unchanged `batchMaxChars` token ceiling.

### R17 — Read-along fast path drops the generation bump; cancel is a no-op — **Batch B**

Introduced in two halves: `readAlongPiecesTask` declared by `4d7b8a5` (09-07)
and **never once assigned** — both `.cancel()` calls (`SpeechPlayer.swift:145`,
`:204`) are no-ops, so the detached read-along scan cannot be cancelled by the
mechanism built to cancel it. Separately, `2bd8c39` (P22, 09-07) added the
precomputed-pieces fast path in `beginReadAlong(fullText:pieces:)`, and that
path returns **before** `readAlongGeneration += 1` — so a stale detached scan
from a previous session survives the generation guard that exists to kill it.

Currently latent: via R15, resume never fires, so the fast path is unreachable
in practice. Batch B fixes R15 first; fixing R17 in the same batch is what
keeps R15's fix from exposing R17.

### R18 — Cover artwork: re-read and re-decoded ~3.3×/s, throttle defeated — **Batch D**

`88cf492` (09-09). **Age: 1 day.**

`nowPlayingArtworkImage` (definition `SpeechPlayer.swift:871`) reads the cover
file and decodes the JPEG **in an argument expression** — call sites `:755`,
`:776`, `:811` — so the work runs on every publish tick before
`NowPlayingCenter`'s throttle can reject it. Throttles drop the *publish*;
they cannot drop work already done to compute the throttled call's arguments.
At the 0.3 s heartbeat that is ~3.3 JPEG decodes per second on the main actor.

Compounding dead code, same commit family: `NowPlayingCenter.currentArtwork`
(declared `NowPlayingCenter.swift:41`) was never assigned after `23a7d9b`
(09-09) routed the payload through `SpeechPlayer` as single writer — so the
`artwork ?? currentArtwork` fallback (`:153`) reads a permanently-nil second
operand, and the "fallback" `23a7d9b`'s message says the field stays for is
inert. Batch D caches the decoded image and deletes or wires the fallback
(whichever the diff supports — the dead operand is the finding).

Antipattern note: this is R13's defect, reintroduced in a new subsystem one
day before this audit — see AP5.

### R19 — Play-path file validation re-stats the whole model set every tap — **Batch C**

`d120245` (v0.6.1, 08-16). **Age: 25 days. Minor; listed for completeness of
the play-path budget.**

`OnnxKokoroEngine.speak` and `SupertonicEngine.speak` both run
`modelFilesValid()` on the main thread on every play. Kokoro: three
`attributesOfItem` syscalls plus reading and JSON-parsing `tokenizer.json`
(~3.5 KB — **not** the tens of milliseconds a careless "JSON parse on the play
path" implies; confirmed against `ModelManager.swift:178-180` and the
`6b6cc9b` fix message "tokenizer is 3.5KB not >10KB"). Supertonic: sixteen
syscalls across four ONNX sessions and ten style files.

The cost is small every tap and *exactly invariant* between taps — nothing the
user can do changes it — which is why Batch C caches it: not because it is
large, but because it is pure overhead. Batch A's `play-path file validation`
line measures it so the before/after is a number, not a guess.

### R20 — `chunks(for:)` O(n²) offset walk — **Batch C**

`133f77d` (v0.4.0, 08-16). **Age: 25 days. Asymptotic, not perceived — yet.**

`chunks(for:)` derives each chunk's UTF-16 offset by walking the text from
zero (`utf16Offset`), so chunking a whole chapter is O(n²) in its length. The
running-accumulator fix already exists in the same file: `sentencePieces`
(`a4e3292`, 09-06) accumulates `runningOffset += pieceLength` — `chunks(for:)`
simply never got it. At Notes length (hundreds of chars) it is noise; at book
length (a 200k-char chapter ⇒ ~1300 walks averaging ~100k UTF-16 units) it is
a measurable main-thread block sitting inside TTFA. Batch C ports the
accumulator pattern; Batch D moves the whole pass off-main.

### Omitted deliberately

- **Live rate applied per chunk** (`d25131a` M14) is *not* a regression and is
  not listed as one. `11dd15e` added persistence debouncing only; the live
  `engine.speed` property was `d25131a`'s addition. An omission repaired is
  not a regression reintroduced.
- **README "Current status: v1.5.0"** lags the 1.5.1/31 build fields. Not a
  defect: 1.5.1/31 is a diagnostic build, and the release procedure
  (`HANDOVER.md:714-717` — README refresh, tag, main fast-forward) is
  explicitly reserved by constraint. Recorded here so the omission is a
  decision, not an oversight.

---

## 4. Anti-patterns with evidence (AP1–AP20)

Each pattern is named once here and cited from the regressions above; every
Batch C–I change is reviewed against this list during the critic pass.

1. **AP1 — A fix commit that introduces the next defect.** `799092a` (fixed
   R3, introduced R16, lived 25 days); `5c7813d` (fixed the abort, created the
   R8 storm). *Guard:* the critic question "what does this change make worse?"
   is asked of every batch.
2. **AP2 — Work whose frequency is set by the UI event rate.** R5
   (per-keystroke encode), R13 (per-frame cache), R18 (per-tick JPEG).
   *Guard:* any per-tick/per-keystroke hook must state its budget.
3. **AP3 — Throttling the publish while doing the work to build the
   arguments.** R18's throttle can never help because the decode is in the
   argument list. *Guard:* work goes behind the gate, not before it.
4. **AP4 — A latch set before the operation it latches.** R7's
   `modelLoadAttempted`. *Guard:* success flags are written by the success
   path only.
5. **AP5 — A lesson fixed in one subsystem, reintroduced in another.** R13 →
   R18 is the clearest case; R5/R13/R19 are one defect in three subsystems.
   *Guard:* Batch audits grep for the pattern repo-wide before closing.
6. **AP6 — Consolidation that moves code without re-auditing execution
   order.** R15 (`292df75`), R9 (probable, `852db44`). Unifying two stores
   made a prime and a read that used to hit different storage hit the same
   slot in the wrong order. *Guard:* after any merge, trace the callers'
   sequence, not just the moved lines.
7. **AP7 — Error handling worse to experience than the error.** R8's 30–90 s
   of silence per flaky chunk. *Guard:* failure paths are reviewed for what
   the listener hears.
8. **AP8 — Verification by pattern-match.** R6's first restore missed the
   symbol and nobody grepped. *Guard:* every "restored"/"re-enabled" claim
   gets a `git grep` of the identifier at HEAD.
9. **AP9 — Init-time side effects before the app is attachable.** R10's
   `OSStatus -50`; the whole of era 4's `42ac74c`. *Guard:* nothing touches
   the audio session, the file system beyond defaults, or the network before
   first user action.
10. **AP10 — Deleting a mechanism while keeping its call sites.** R17's
    never-assigned `readAlongPiecesTask` with two live `.cancel()` calls —
    both no-ops reading as functioning cancellation. *Guard:* declared-but-
    never-written state is itself a finding.
11. **AP11 — Same-value-twice parameters collapsing a designed asymmetry.**
    R16: a two-parameter API reduced to one constant at every call site for 25
    days. *Guard:* when a call passes the same literal to two parameters, name
    why out loud in review.
12. **AP12 — Green CI treated as device truth.** R1, R12 both shipped behind
    green builds; only LiveContainer showed them. *Guard:* baseline doc
    separates "CI-green" from "device-verified"; nothing claims the second.
13. **AP13 — Monolithic SwiftUI bodies burning CI against the expression
    budget.** R12's 19-commit day. *Guard:* new view code in small private
    computed vars or new files; the plan carries this verbatim into Batch G.
14. **AP14 — A second writer to a single-writer resource.** `88cf492` let two
    objects publish now-playing payloads; `23a7d9b` had to pick one. The
    "fallback" it left (`currentArtwork`) is R18's dead operand. *Guard:*
    every shared resource names its writer.
15. **AP15 — Local asymptotics that are invisible until a corpus grows.**
    R20: O(n²) at notes length, seconds at chapter length. *Guard:* cost
    statements in code review cite the largest real input, not a typical one.
16. **AP16 — Fixing a class of bug by fixing its instance.** Each of R5, R13,
    R19 was fixed where it hurt and nowhere else, so the class survived. This
    document's anti-pattern list is the corrective: fix the rule, not the
    instance.
17. **AP17 — UI advertising behaviour the pipeline cannot perform.** R15's
    resume controls do exactly what "Restart from beginning" does and no log
    line ever says so. *Guard:* user-facing affordances are traced to a working
    mechanism before docs mention them.
18. **AP18 — Unbounded retention in a streaming path.** R2's buffers held for
    the session; the fix's slot/bind machinery is what Batch H's gapless
    playback must not widen. *Guard:* streaming state must be O(slots), never
    O(chunks).
19. **AP19 — Measurement added after the conclusion.** The 26-day corpus has
    ~214 commits and, before Batch A, zero instrumentation on the play path;
    R16's arithmetic was unknowable from inside the app. *Guard:* Batch A's
    numbers precede every Batch C retune.
20. **AP20 — A guard whose condition was defeated by its own setup.** R15's
    `charsDone >= 40` never saw a value ≥ 40 because the prime ran first —
    the guard and its saboteur live three lines apart. *Guard:* guards are
    reviewed alongside every writer to the guarded value.

*Rule for Batches C–I:* any diff that matches one of these patterns is a
critic finding regardless of how well it otherwise scores.

---

## 5. What the corpus says about the two claims this audit was asked to check

- **"Build-ipa is a ~45-minute window"** — refuted twice by measurement and
  corrected in `TTS_BASELINE.md` §7 (6m05s on run 34414916499; 6m54s on run
  34417716833). The productive-window premise survives; the number did not.
- **"Green CI does not prove LiveContainer launch"** — **affirmed** by R1 and
  R12, the two worst incidents in 214 commits, both device-only. The hard
  constraint stands exactly as written.
