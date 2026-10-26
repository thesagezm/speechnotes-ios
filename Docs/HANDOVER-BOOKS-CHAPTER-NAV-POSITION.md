# HANDOVER — 2026-10-26: books chapter navigation + resume/start discordance

**Status: FIXED IN CODE, NOT YET CI-VERIFIED, NOT YET DEVICE-VERIFIED.**
**DO NOT PUSH THE RELEASE YET — see "Release gate" at the bottom.**
**Version untouched (1.8.0 / build 45) — the user groups features into releases.**

Supersedes the earlier diagnostic-only drafts of this file. The diagnosis is
preserved because several theories were RULED OUT and should not be
re-chased.

## The user report (v1.8.0 release prep)

> 2) "Chapters in the book gestational rophoblastic dieseases (currently
>    available or imported in speechnotes linux, its also called compiled obgy
>    notes chinkoyo)... the chapters show well in the table of contents - but
>    jumping to the previous chapter or to next chapter using the next and
>    previous buttons... the one at the bottom in books... its only jumping to
>    the last chapter not the ones in between"
>
> 3) "there is a big issue... in books particularly pdf... between resuming
>    from previous/last bookman(where i ended) and starting from any page i
>    want or chapter i want... fix this discordance"
>
> 4) "if you are certain youve solved this you can push the release"

**Scope:** another agent owns issue 1 (maths/symbols in the notes preview).
This work covers issues 2 + 3 only.

## Repo state at handover

- Branch `batch-c-d-session`, HEAD `821ce2f`.
- **Another session commits on this branch concurrently.** Commits
  `c826eb6` and `ca068b2` ("Fix CI: …") were made by that session and
  **they swept in two of my files** (`App/Sources/Services/BooksStore.swift`,
  `App/Sources/Views/BookPDFReaderView.swift`). My changes in those files are
  intact — verified by grep. **Always stage by explicit path.**
- `Packages/SpeechLogic/Package.resolved` is untracked (not mine).

---

# WHAT WAS CHANGED

## Fix 1 — `BooksStore`: stop reverting newer manifest fields

`App/Sources/Services/BooksStore.swift`

**The bug.** `updatePosition` and `markOpened` built their new `Book` from
the CALLER's snapshot and wrote it back with `save()`, which REPLACES the
whole shelf entry:

```swift
var updated = book                    // the reader's STALE snapshot
updated.position = BookPosition(...)
save(updated)                         // replaces the whole entry
```

The reader's snapshot goes stale the moment anything else writes the
manifest — and the shelf backfill does exactly that: it resolves
`pdfChapters`, `pdfIsScanned` and the cover AFTER the book is opened
(`BooksStore.backfillMissingBooks`, around line 359-463).

So the reader's next position write **reverted the freshly backfilled
chapter list.** With the chapter list reverted to an older one, the visible
page no longer falls inside any chapter's page range — which is exactly what
put the PDF reader into its "last chapter" fallback (Fix 2). The same revert
made the persisted position disagree with the page on screen.

**The fix.** Both now merge into the LIVE shelf entry:

```swift
private func liveEntry(for book: Book) -> Book {
    allBooks.first(where: { $0.id == book.id }) ?? book
}
```

plus a new `mutate(_:_:)` API that applies a field-level change to the live
entry. The PDF reader's force-OCR toggle now uses `mutate` instead of
`save()` (it had the same stale-snapshot problem).

**Files:** `App/Sources/Services/BooksStore.swift`,
`App/Sources/Views/BookPDFReaderView.swift` (force-OCR toggle).

## Fix 2 — PDF: the chapter lookup never answers "the last chapter"

`App/Sources/Views/BookPDFReaderView.swift` — `currentChapterIndex`

**The bug.** When the visible page was outside every chapter's page range,
the lookup answered `chapters.count - 1` — **THE LAST CHAPTER**:

```swift
return currentPage < (chapters.first?.startPage ?? 0) ? 0 : chapters.count - 1
```

And `goChapter` clamps its target:

```swift
let clamped = max(0, min(chapters.count - 1, index))
```

So from that state, "next" computes `chapters.count` → clamped straight back
to `chapters.count - 1` → **the same last chapter, no movement, forever.**
That is the exact "it only jumps to the last chapter" symptom.

**The fix.** The honest answer for a page outside every range is the chapter
it belongs to — the one that STARTS at-or-before it:

```swift
if let index = chapters.lastIndex(where: { $0.startPage <= currentPage }) {
    return index
}
return 0   // before the very first chapter
```

## Fix 3 — PDF: the reader now sees a chapter list resolved after it opened

`App/Sources/Views/BookPDFReaderView.swift`

The reader is handed a `Book` snapshot at navigation time. A PDF whose
chapters are resolved by the backfill AFTER that moment had **no chapter
list in the reader at all** — the steppers had nothing to walk, the bar
showed a bare page count, and the Contents sheet showed a full outline.

Added `liveBook` (the current store entry) and a `chapters` computed
property; every chapter reference in the reader now reads that instead of
`book.pdfChapters`.

## Fix 4 — PDF: a jump issued before the document lands is QUEUED

`App/Sources/Views/BookPDFReaderView.swift` — `goToPage`

**The bug.** The PDF open runs off main and on a big scanned textbook it
takes seconds. A tap on a Contents row in that window hit:

```swift
guard let pdfView, let document = pdfView.document, ... else {
    Log.shared.info("PDFContents: cannot jump — …")
    return          // DROPPED, silently
}
```

No movement, no error — the user read it as "tapping a chapter does
nothing" and "starting from a page I want does not work".

**The fix.** The jump is held in `pendingPage` and applied from
`onDocumentLoaded`. The position is written **even when the jump is queued**,
so the persisted place matches the intent and a book closed during the open
still resumes where the user asked to go.

## Fix 5 — EPUB: the chevrons move the bar immediately

`App/Sources/Views/BookReaderView.swift`, `App/Resources/epubjs/reader.js`,
`App/Sources/Views/BookWebView.swift`

**The bug.** `goChapter` only called into JS:

```swift
private func goChapter(_ index: Int) {
    webView?.evaluateJavaScript("readerGoChapter(\(index))", completionHandler: nil)
}
```

and `readerGoChapter` returned EARLY AND SILENTLY when the book was not up
yet (`if (!window.BOOK || !window.RENDITION) return;`). The bar only moved
when the webview's `relocated` event came back — so a command the webview
had not picked up yet left the bar on the OLD chapter, and the next press
computed the same target from the same stale index. **The chevrons looked
dead.**

**The fix, in three parts:**
1. The bar moves immediately (optimistically) in `jumpToSpineIndex`.
2. `readerGoChapter` now POSTS a `goChapterFailed` message instead of
   failing silently, with a reason: `book-not-ready`,
   `no-such-spine-item`, `display-rejected`.
3. The native side handles it (new `onGoChapterFailed` closure on
   `BookWebView`): `book-not-ready` HOLDS the jump and retries it from the
   first `relocated` event (the rendition is up by then); any other failure
   restores the chapter the reader was actually on.

Also: the TOC sheet now calls `jumpToSpineIndex` instead of `goChapter`, so
a TOC row always navigates — the old no-op guard ("already on this chapter")
swallowed a TOC row pointing at a different spot INSIDE the current chapter.

## Fix 6 — EPUB: a chapter jump clears the CFI; a mid-chapter move persists

`App/Sources/Views/BookReaderView.swift`

**The bug (part 1).** A CFI points at a spot INSIDE a chapter. Keeping
chapter 2's CFI while the reader sat on chapter 1 made a reopen land in the
wrong place — the EPUB half of the resume/start discordance.

**The fix (part 1).** `jumpToSpineIndex` clears `lastKnownCFI`.

**The bug (part 2).** `handleRelocated` persisted ONLY on a chapter change:

```swift
if index != persistedChapter { persistPosition() }
```

So a book closed WITHOUT leaving the chapter lost the exact mid-chapter
spot — "resume lands at the chapter top".

**The fix (part 2).** A CFI change also persists, THROTTLED to one write
every 3 s (`scheduleCFIPersist`) — `relocated` fires on every scroll tick
and a manifest write per tick is a write per frame. The pending write is
flushed in `onDisappear`.

---

# RULED OUT — do not re-chase these

These were investigated and DISPROVED. Re-reading them costs an hour each.

1. **"The PDF chapter builders leave page gaps."** FALSE.
   `PdfText.chaptersFromOutline` / `chaptersFromHeadings` /
   `fallbackChapters` tile the document CONTIGUOUSLY. `kept` is strictly
   increasing, so `end = next.start - 1` is always `>= start.page` and the
   `guard end >= start.page else { continue }` NEVER fires. The builder is
   sound. The gaps the reader saw came from holding a STALE list (Fix 1).
2. **"The epub.js `spineByHref` triple-keying breaks the lookup."** FALSE.
   `Spine.unpack` overwrites `t.href` with the MANIFEST href, and
   `readerGoChapter` reads that same string back off the item, so
   `spine.get(href)` resolves. The href path works.
3. **"The chevrons and the TOC use different index spaces."** FALSE for the
   EPUB reader. `BookReaderView.chapterIndex` is the SPINE index (from
   epub.js's `relocated`), and the TOC sheet resolves to
   `row.entry.spineIndex` — which is ALSO a spine index
   (`BooksStore.buildManifest` maps every TOC href to its spine index at
   import). Same space.
4. **The audiobook reader.** Untouched. Its position handling
   (`AudioBookPlayer.persistPosition`) writes absolute `audioSeconds` and is
   already correct.

# STILL OPEN (needs a decision or a device check)

1. **EPUB stepper granularity vs the TOC.** The chevrons walk SPINE items;
   the Contents sheet lists TOC ROWS. A compiled-notes EPUB often has far
   more TOC rows than spine items (many sections share one document), so the
   user may count TOC rows while the chevrons count spine items — which
   reads as "it jumped to the wrong place". **This round makes the chevrons
   land on the adjacent SPINE item reliably, but does not make them step TOC
   rows.** If the device check shows the steppers too coarse for the user's
   book, step the TOC list (jump to each row's `spineIndex`) and label the
   bar honestly.
2. **PDF stepper granularity.** Same question: the steppers walk
   `pdfChapters` (top-level outline nodes) while the Contents sheet shows
   the FULL outline tree (`outlineRows`, every level). Different lengths.
   The fix makes them move reliably, but they still step the coarser list.
   Decide AFTER a device check — changing `pdfChapters` granularity changes
   the TTS unit boundaries and auto-advance for every PDF.
3. **`BookPosition` overloading.** `chapterIndex` means a PAGE index for
   PDFs and a CHAPTER index everywhere else (documented in
   `App/Sources/Models/Book.swift:25-30`). Every current consumer happens to
   be correct, but the shape invites the next bug. The structural fix is a
   `pageIndex: Int?` field (defaulted, so old manifests still decode) plus
   updates in `BookPDFReaderView`, `GoalMath.fraction`,
   `StatsTabView.bookProgress`. **Deliberately NOT done in this round** — it
   touches the goals and stats math and deserves its own pass.

# RELEASE GATE (issue 4 — "if you are certain youve solved this you can push")

**NOT satisfied yet. Do not push.** Two things are missing:

1. **CI.** There is no local Swift toolchain, so none of this has been
   compiled. Run:
   ```
   gh workflow run build.yml --ref batch-c-d-session
   ```
   and watch the run. `build.yml` auto-runs only on `main` / `sage-upgrades`,
   so a branch push starts nothing — it must be dispatched manually. Expect
   1-3 CI fix rounds (past rounds needed 3-6); the riskiest edits are the
   new `BooksStore.mutate` / `liveEntry` API and the `BookWebView`
   `onGoChapterFailed` closure.
2. **A device check on the user's actual book** (the compiled OBGYN notes
   PDF). The device checklist:
   - Open the book; the Contents sheet lists the sections; the bottom
     next/prev chevrons move ONE section at a time (not to the last).
   - Jump to a page from Contents; close the book; reopen → lands on that
     page.
   - Read to another page; close; reopen → lands there.
   - Open the book, tap a Contents row IMMEDIATELY (before the big PDF has
     finished opening) → the jump lands once the document is ready.
   - EPUB: tap next/prev repeatedly through a book → each press advances
     one chapter, the bar tracks it, and a reopen lands where you stopped.
   - EPUB: scroll WITHIN a chapter, close the book, reopen → lands at the
     exact spot, not the chapter top.

   **The EPUB "reopen lands at the exact spot" item is the one most likely
   to still fail** — it depends on the CFI throttle firing before the
   reader closes. If it fails, flush the CFI write on
   `scenePhase == .background` as well as `onDisappear`.

# Notes for the next session

- **Do not use subagents** — the user asked for them to be avoided here
  (an earlier attempt timed out against the API and one failed with a DNS
  error).
- **Stage by explicit path.** Another session commits on this branch and
  swept my `BooksStore` / `BookPDFReaderView` edits into their CI-fix
  commits. `git add -A` would take their half-finished maths work.
- **Version policy:** `MARKETING_VERSION` stays `1.8.0`; only
  `CURRENT_PROJECT_VERSION` moves (45 → 46) when the release is cut.
