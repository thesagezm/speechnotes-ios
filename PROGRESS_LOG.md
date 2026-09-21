# PROGRESS LOG — SpeechNotes Upgrade Cycle

Format: newest first. Every critique round, merge, and escalation lands here.

---

**Audiobooks + session robustness** (branch `batch-c-d-session`, 2026-09-21):
- **No retry.** `generateWithRetry` is deleted from the streaming core. A chunk
  that throws is logged once (with its index out of the total), sounded with
  `BeepPlayer.playSkipTone()` and stepped over — for playback and WAV export
  alike. This is the R8 anti-pattern (AP7, "error handling worse to experience
  than the error") finally closed by removing the retry rather than tuning it.
- **`SpeechSanitizer`** (SpeechLogic, new): `clean()` strips what a reader
  cannot pronounce — C0/C1 controls, zero-width and bidi controls, variation
  selectors, private-use glyphs — and normalises whitespace. Two rules the CI
  loop forced: replace rather than delete (`exam\u{00AD}ple` must not become
  `example`), and U+2028/U+2029 plus a lone CR are line breaks, not spaces.
  Wired into `MarkdownText.plainText`, `XhtmlText.extract`,
  `PdfText.normalize`, every note/book speak path through the new `SpeechText`
  helper, `ImportService`, and the chapter cache write.
- **`AudiobookChapters`** (SpeechLogic, new): reads `chpl` inside `moov` and
  ID3v2.3/2.4 `CHAP` frames, bounded (an 8 MB head slice, never the whole
  file). `Book` gains `.audio`, `BookAudioReaderView` + `AudioBookPlayer` play
  it with no `SpeechPlayer` involvement, its own lock-screen surface, and
  chapter resume.
- Chunker hardening: a piece under 4 UTF-16 units with nothing to say is glued
  onto the piece before it. Nothing is dropped — the reconstruct invariant
  (chunks concatenate to the original) is what the read-along and resume index.
- **CI loop history worth recording:** six red runs, every failure a real
  defect rather than a typo — `Set<Unicode.Scalar>` array literals reject Int;
  a dangling helper call; a fixture that wrapped `chpl` raw instead of as a
  box; piece-dropping that broke reconstruct; U+2028 treated as a space; a
  lone CR joining two lines; `[weak self]` in a struct. Full writeup in
  `Docs/PLAN-AUDIOBOOKS.md`.
- **Device test pending.** CI green (logic tests + unsigned IPA + all four
  spikes); nothing merged to `sage-upgrades` and no release.

---

**Batch 5 — Accessibility sweep** (branch `fix/a11y-labels`, merged @ `4d83a3e`):
- MarkdownFormattingBar's 13 icon buttons labeled; MiniPlayerBar play/stop; PlayerControlsBar play/stop/read-along + rate slider label + value.
- No visual change; VoiceOver goes from "button" ×13 to named controls.
- CI: green (34293436652).

---

## Cycle summary

6 batches → all ≥8/10 critique, all CI green, zero escalations:

| Batch | Scope | Merge | CI run |
|---|---|---|---|
| 0 | TTS pipeline regressions (quit-bug, retry-storm, live-rate, load-latch, audio session init) | 4d7286e | 34242349583 ✅ |
| 1 | BooksStore race, zip-bomb bound, image-sniff brand, SystemEngine epoch | f9e56bd | 34248407439 ✅ |
| 2 | Sleep timer, lock-screen subtitle + cover | b3455b5 | 34289888739 ✅ |
| 3 | Joplin JEX export + 6 unit tests | 78ff6e3 | 34291148672 ✅ |
| 3b | Note share as MD/TXT/PDF | c1b8a7f | 34292710925 ✅ |
| 4 | EPUB mid-chapter CFI restore (M20) | cd0b6f8 | 34292066132 ✅ |
| 5 | A11y labels | 4d83a3e | 34293436652 ✅ |

## Deferred (documented for next cycle)
- True playback queue (replaces onNaturalFinish chain) — scope, not a stuck task.
- Per-chapter % on lock screen — content isn't seconds-addressable.
- In-book search, highlight model, translation — sequenced after CFI restore shipped.
- `AVSpeechSynthesisProvider` system-voice extension — high complexity, high value; needs its own phase.
- M22 ModelManager HEAD-size check; M25 Supertonic Helper force-unwraps.

## 2026-09-08 (late) — Batches delivered and merged

**Batch 0 — TTS pipeline regressions** (branch `fix/playback-pipeline-regressions`, merged to `sage-upgrades` @ `4d7286e`):
- Retry storm fixed: 3 retries + 0.5 s silence → 1 retry + skip. No more 30–90 s dead air per bad chunk.
- Player no longer traps on engine switch: new speak floods the old pacing gate.
- Live rate changes (M14): speed slider reaches the next chunk without restart.
- Load latch fixed (M16): transient load failures no longer brick the engine until relaunch.
- Audio session lazy init (kills OSStatus -50 spam on cold start).
- CI: green (34242349583).

**Batch 1 — Data-layer races** (branch `fix/books-store-race`, merged @ `f9e56bd`):
- M18 BooksStore last-writer-wins (monotonic seq + drop stale write).
- M23 ZipReader 100 MB safety cap.
- M24 Image sniffing distinguishes HEIC from MP4 by brand.
- M15 SystemEngine epoch guard.
- CI: green (34248407439).

**Batch 2 — Sleep timer + lock screen** (branch `feat/playback-queue-sleep-lock`, merged @ `b3455b5`):
- Sleep timer (5/15/30/60 min + "end of chapter" for books). End-of-chapter swallows the natural finish and keeps the bookmark so resume lands past the end.
- Lock-screen subtitle ("Ch N — Title") + cover art ride out via `SpeechPlayer.NowPlayingPayload`, so the between-chapter "Loading…" state doesn't blank the metadata.
- Critique: 9/10 (no per-chapter % on lock screen — deferred; content isn't seconds-addressable).
- CI: green (34289888739).

**Batch 3 — Joplin JEX export** (branch `feat/note-export-jex`, merged @ `78ff6e3`):
- `SpeechLogic.JexExport` — pure-Swift ustar writer; `<noteId>.md` entries with metadata footer (`type_: 1`), `<notebookId>.md` with `type_: 2`, `<resourceId>.md` + `resources/<id>.<ext>` for images (`type_: 4`).
- Independent reimplementation per Joplin format docs — no AGPL code.
- 6 unit tests in `JexExportTests` (tar framing, entry names, type_-last invariant, orphan-note drop, resource round-trip, UTC ISO).
- Settings → Backup → "Export notes to Joplin (.jex)".
- CI: green (34291148672).

**Batch 3b — Note share formats** (branch `feat/note-share-formats`, merged @ `c1b8a7f`):
- Editor overflow menu: Share as Markdown (raw source), Share as plain text (`MarkdownText.plainText`), Share as PDF (UIMarkupTextPrintFormatter + UIPrintPageRenderer).
- Reuses the share sheet that WAV export already presents.
- CI: green (34292710925).

**Batch 4 — EPUB mid-chapter restore** (branch `feat/epub-cfi-restore`, merged @ `cd0b6f8`):
- epub.js reader now publishes the CFI on every relocation and accepts `?cfi=` at shell-load (preferred over the chapter index when present).
- `BookPosition.cfi: String?` persists the CFI; legacy manifests decode cleanly.
- Reopening a book mid-chapter now restores the exact spot, including across font-size changes and rotations (M20 / 4.7 prerequisite).
- CI: green (34292066132).

**Batch 5 — Accessibility sweep** (branch `fix/a11y-labels`, CI running):
- MarkdownFormattingBar's icon-only buttons labeled (bold/italic/strike, H1/H2, lists, quote, code, rule, link, image) — VoiceOver no longer reads "button" 13 times.
- MiniPlayerBar play/stop labeled; PlayerControlsBar play/stop/read-along + slider labeled.
- No visual change.

---

## Escalated items

None. (Batch 2's skip of a true playback queue is a scope decision, not a
stuck task — deferred to a later round once CFI work lands, at which point a
proper queue becomes both needed and testable.)

## References
- `FEATURE_BACKLOG.md` — full prioritized list from the 8 reference repos.
- `INTEGRATION_PLAN.md` — phase plan, dependency graph, license fence.
- `UPGRADE_AUDIT.md` — codebase map + open findings.

## [2026-09-10 ~11:20Z] Batch A — Phase 0 deliverables + instrumentation
- Pushed: `070d38f` (docs commit pending: TTS_REGRESSION_AUDIT.md, this log, CRITIC_REVIEWS.md)
- CI: logic-tests ✅ 52s · build-ipa ✅ 6m57s — run 34468296292, all 6 jobs green (third consecutive sub-7-min build; the 45-min premise is retired, see TTS_BASELINE §7)
- Critic Round 2: Score 8/10 (approved). Round 1: 6/10.
- Issues found: Round 1 B1–B6 (stall watchdog false positives, timer leak, gap misclassification, metrics on critical path, commit-message overclaim); Round 2 N1–N6 — including two defects introduced by Round 1 itself (stall-tick reset gating, clearance-gate volume)
- Issues fixed: all of B1–B4, N1–N6. B5 recorded in CRITIC_REVIEWS.md (immutable commit message). B6 accepted as designed.
- Next action: commit the three docs, then Batch B (resume resurrection — prime-after-read in both branches, debounce→throttle, resumeIfBookmarkPending markdown fix, readAlongPiecesTask assignment + generation bump in the fast path)
- TTS baseline impact: **slower by~10⁻⁵ of measured work** (the one exception to the no-regression-by-removal rule, accounted line-by-line in TTS_BASELINE §6, with the thinning that keeps a 1300-chunk chapter at ~64 log lines)
- O5 decision recorded: README stays at v1.5.0 — 1.5.1/31 is a diagnostic build number, and the release procedure (README refresh + tag + fast-forward) is reserved by constraint
- O7 deferred to Batch C: PlaybackMetrics testability needs SpeechLogic reachability or an app test target; rides with the chunker contract tests
