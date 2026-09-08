# INTEGRATION PLAN — SpeechNotes State-of-the-Art Upgrade

Order is dependency-aware, not just priority-sorted. Each phase delivers as
one PR (CI green + critique ≥ 8). Numbering matches FEATURE_BACKLOG.md.

## Phase A — Robustness (done)

Batch 0 ✅ M14/M15/M16/M17 + retry-storm skip-chunk + audio-session lazy init
Batch 1 in flight: M18 (BooksStore race), M23 (zip bomb bound), M24 (brand-aware image sniff)

## Phase B — Playback UX backbone (queue → timer → lock screen)

Why first: H1, H11 depend on the same queue machinery C1 introduces.

1. **PlaybackQueue (C1)** — `PlaybackItem` = {kind: note|book-chapter, id,
   ref}. SpeechPlayer gains a queue surface: `enqueue`, `playNext`, `clear`.
   BookPlaybackController becomes a queue *consumer* (chapter chain = queue
   of one book's chapters in order). This subsumes today's `onNaturalFinish`
   special case.
2. **Sleep timer (3.7)** — `SleepTimer` in SpeechPlayer: off / N minutes /
   end-of-item. Uses queue's "current item done" event; survive backgrounding
   via `Task` + tolerance, not a Wall-clock timer.
3. **Lock screen controls (H1)** — NowPlayingCenter: skip-forward-15 /
   skip-back-15 mapped to N-chunks-forward/back (chunk-aware skip = exact),
   scrubber disabled (position is content-derived, not seekable in seconds —
   publish `elapsedPlaybackTime` honestly instead). Chapter subtitle + book
   cover artwork.

**Exit criteria:** queue survives engine switch mid-queue; sleep timer fires
at exact end-of-item; lock screen buttons respond within 300 ms.

## Phase C — Notes export (H3 → H4)

1. **Markdown/TXT/PDF share (H3)** — add MarkdownText renderers for plain
   md/txt and PDF via print-to-PDF of a styled attributed string. Share sheet
   from NoteEditorView + long-press on list item.
2. **Joplin JEX export (H4)** — new SpeechLogic module `JexExporter`:
   `tar` writing in pure Swift, entry order deterministic; per-note `<id>.md`
   with metadata block (`id/parent_id/created_time/updated_time/type_`),
   per-notebook `<id>.md` (`type_: 2`), resource entries (`type_: 4`) +
   `resources/<id>.<ext>`. Schema follows PROGRESS_LOG research (32-hex ids,
   UTC ISO-8601, `type_` last). **Independent reimplementation** — JEX is an
   open format, no AGPL code will be read or ported.

**Exit criteria:** JEX round-trips into a clean Joplin install with notebook
hierarchy and inline images intact.

## Phase D — Reader (CFI first, then highlights)

1. **CFI position restore (C2 / M20)** — epub.js emits CFI per relocation;
   persist `(bookId → cfi)` in Book manifest; on open, evaluate
   `reader.display(cfi)` before first paint. Reader acceptance: after
   font-size change mid-book then quit → reopen lands on the same paragraph.
2. **Highlights model (H6)** — `BookHighlight { id, bookId, cfi, color,
   note, createdAt }`. Persisted per-book JSON (same directory as the
   manifest). UI: long-press selection in webview → highlight colors row;
   notes panel lists with tap → jump.
3. **In-book search (H5)** — spine-indexed text search; results jump to CFI.

**Exit criteria:** CFI-induced drift test (rotation + font size + reopen),
highlight CRUD across relaunch, highlight → note export to a markdown note.

## Phase E — A11y + polish sweep

H8 labeled icon buttons; V4/V5 delete confirmations; V6 PhotosPicker
migration; V11 mini-player inset from safe area instead of 49+34; C6
swiftLanguageVersions pin.

## Risk register

| Risk | Mitigation |
|---|---|
| JEX format drift across Joplin versions | Pin to the documented RAW export schema; test import against Joplin desktop 3.x; keep schema version comment in code |
| Queue change regresses chapter auto-advance | Regression tests on SpeechLogic side + dedicated device run through 3-chapter book before merge |
| CFI restore fails on fixed-layout EPUB | Feature-detect: fall back to (chapter, fraction) as today |
| LiveContainer still relevant | All AV work stays out of `App.init`; no MPRemoteCommandCenter until first user press |

## License fence

AGPL (readest, koodo, joplin, piper-app, BookPlayer): ideas only. Apache
(sherpa-onnx) / MIT (expo-kokoro-onnx): code may be adapted with credit;
none planned for this cycle.
