# HANDOVER — 2026-10-26: books TTS play-from-position + reader-mode Contents jump

**Branch `batch-c-d-session`, HEAD `583acdb`.**
Everything here is code-complete; the CI round for `583acdb` was dispatched
manually (`Build IPA` run 40395811218 — `build.yml` does not auto-run on this
branch; `Scripts/watch_ci.sh 583acdb` was started in the background).
**The device is the only remaining gate.**

---

# 1. What the user asked for (their words, decoded)

1. **"i cant jump to a chapter or specific page in reader mode using the
   table of contents."** Reader mode = the READ-ALONG surface (the native
   highlighted text shown while a book speaks). In that mode the TOC taps
   only moved the HIDDEN webview/PDFView — nothing the user could see, and
   the speech kept playing the old chapter. → Fixed: the tap now moves the
   SPEECH.
2. **"reading should start either from the bookmark or my current page"**
   (PDF especially — "which has not been starting from the page id be
   currently viewing"). → Fixed: fresh play starts at the viewed page/spot.
3. **Bookmarks stay exactly as they are.** The user explicitly said the
   play/stop bookmark cycle already works and must not be touched. Nothing
   in `SpeechPlayer.stop()` / `clearBookmark()` changed.
4. "Page 1 is not really a bookmark" — a position at the very start of a
   chapter must not count as a bookmark; the current page wins instead.

Discarded by the user: the earlier idea of making read-along show before
play is pressed ("can be discarded — the default view stays the epub /
markdown preview / pdf viewer").

Items 1/5/6 of that same user message (flowmodoro break bank, transparent
minimised-bar background, top bar in portrait) belong to the OTHER session —
not this round.

---

# 2. How it works (the one diagram)

```
reader (PDF: currentPage / EPUB: chapterFraction)
  └─ BookPlaybackController.togglePlay(book:, chapterIndex:, from: BookStartPoint)
       └─ speak(...) resolves the chapter's speech text, THEN converts the
          start point to a UTF-16 offset (speechStartOffset):
            .page(p)      → sidecar text/NNNN.pages.json: last entry with
                            page <= p  (pdfPageStartOffset, off-main read)
            .fraction(f)  → f * textLength   (0 → nil)
            .beginning    → 0   (the Contents jump only)
            nil           → nil (historic path: resumeBook, auto-advance,
                            lock-screen chapter skip)
       └─ BookPlaybackRef(startOffset:) → SpeechPlayer.togglePlay, .idle book
          branch, in priority order:
            1. resumeBookPlan — a MEANINGFUL bookmark (≥40 chars in, hash-
               and length-matched, <30 days) resumes. Unchanged.
            2. startOffset != nil → playFrom(text, at: startOffset) — snaps
               to the sentence at-or-before the offset and primes a fresh
               bookmark there. Offset 0 = clean restart (playFrom's zero
               path).
            3. neither → chapter top (unchanged).
```

**The priority the user asked for falls out of this ordering**: bookmark
first, current page second, chapter top last. A "page 1" position resolves
to `nil` (see `speechStartOffset`'s doc comment), so it can never shadow a
real bookmark.

**Reader-mode Contents jump** (`jumpToChapter` in BookPlaybackController):
while THIS book is sounding, a TOC tap calls
`speak(book:, from: target, startPoint: .beginning)`; inside `speak`, the
live-session branch (`nowPlayingBookId == book.id && state != .idle`)
supersedes IN PLACE via `player.playFrom(text, at: 0)` instead of
`togglePlay` (which would only PAUSE a live session) or `stop()` (which
would flicker the read-along surface away, wipe the lock screen, and drop
the auto-advance chain). The read-along text IS `activeSpeechText`, so the
moment the new chapter's speak starts, the surface shows it from its top.

The viewers ALSO still run their own jump (`jumpToSpineIndex` / `goToPage`)
so the hidden webview/PDFView and the persisted position follow — when
read-along ends, the reader lands where the jump went.

Tap-a-paragraph-to-play-from inside read-along already existed and is
untouched.

---

# 3. Files touched (all in `583acdb`)

| File | Change |
|---|---|
| `App/Sources/Services/SpeechPlayer.swift` | `BookPlaybackRef.startOffset: Int?`; book branch of `togglePlay` uses it after the bookmark plan fails. |
| `App/Sources/Services/BookPlaybackController.swift` | `BookStartPoint` enum; `togglePlay(book:chapterIndex:from:)`; `jumpToChapter`; `speak` start-offset plumbing + live-session supersede branch; `speechStartOffset` + `pdfPageStartOffset` (sidecar read). |
| `App/Sources/Views/BookReaderView.swift` | Both play buttons pass `.fraction(chapterFraction)`; TOC row: `tocJumpTarget` (manifest spineIndex, else path-exact href match against `book.spine`) + the read-along branch. |
| `App/Sources/Views/BookPDFReaderView.swift` | Both play buttons pass `.page(currentPage)`; outline sheet rows go through `jumpOutlineRow` (+ `chapterContaining`). |

Nothing in SpeechLogic changed (no logic-test surface). The app target has
no unit tests — verification is CI compile + device.

---

# 4. Design decisions worth knowing (so nobody "fixes" them back)

- **Sidecar offsets are pre-sanitization.** `PdfSpeechText` writes page
  offsets against the RAW extracted text; the cached speech text is
  sanitized afterwards and `SpeechSanitizer.clean` is NOT length-preserving.
  This drift already existed for read-along page tracking and is absorbed
  the same way here: `playFrom` snaps to a sentence boundary, so a few
  characters of drift land on the page's first sentence regardless.
- **Image-only pages**: the sidecar has no entry for them, so a page in an
  image run resolves to the nearest preceding page WITH text — the honest
  best for scans.
- **EPUB scrolled-flow fraction**: epub.js may report fraction 0 in scrolled
  flow for short chapters; `.fraction(0)` → `nil` → historic behavior
  (bookmark-or-top). No regression; in paginated flow (and long chapters in
  scrolled flow) the position is real.
- **The live-session branch in `speak` also covers auto-advance** (same
  book still "live" when the advance task lands before the engine's async
  idle transition). `playFrom` supersedes safely; the OLD code path there
  would have PAUSED the engine — the new branch is strictly safer.
- **`jumpToChapter` on a paused session** un-pauses by speaking the chosen
  chapter (supersede) — that is the intent of a Contents tap.
- **Audiobooks untouched** — the user scoped this to PDF/EPUB reading.

---

# 5. Device checklist (the only remaining gate)

## PDF (the compiled OBGYN notes book)
- Open at page 1, scroll to page ~50, press play → TTS starts on page 50's
  first sentence, NOT page 1 / chapter start.
- Pause mid-chapter (bookmark saved), close, reopen, press play → resumes
  from the bookmark (bookmark still wins).
- Stop (bookmark cleared), scroll elsewhere, press play → starts at the new
  current page.
- While listening (read-along up): Contents → tap a section → speech jumps
  to that chapter from its start, read-along shows the new chapter; stop →
  the PDF viewer returns on the page that was sounding.

## EPUB
- Scroll mid-chapter, press play → TTS starts near the viewed spot (in
  Pages mode exactly; in Scroll mode fraction 0 falls back to chapter top).
- While listening: Contents → tap a chapter → speech jumps, read-along
  follows; tap prev/next chevrons still work as before.

## Regression guards
- Play/stop/play/stop → each play restarts at the current page; no stale
  bookmark resurrects.
- Note playback, voice audition, export, lock-screen chapter skips, sleep
  timer — all share SpeechPlayer and must behave exactly as before.

---

# 6. House rules for the next agent (unchanged, they keep biting)

- Stage by explicit path — the other session commits concurrently on this
  branch (this round it had LocalSend/SpeechnotesApp/BookDropSendView WIP in
  the tree; none of it was swept into `583acdb`).
- `build.yml` must be dispatched manually for this branch; `logic-tests` is
  the fast signal, `Build unsigned IPA` is the app-target compile gate.
- Version policy: no `MARKETING_VERSION` bump; stays 1.8.0.
- Adding params with defaults to FUNCTIONS is safe; to SwiftUI view
  memberwise inits it is not (declaration-order trap, see
  `Docs/HANDOVER-SCREEN-ON-AND-FINAL.md` §5).
