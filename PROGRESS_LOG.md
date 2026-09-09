# PROGRESS LOG — SpeechNotes Upgrade Cycle

Format: newest first. Every critique round, merge, and escalation lands here.

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
