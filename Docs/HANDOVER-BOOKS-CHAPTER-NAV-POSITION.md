# HANDOVER — 2026-10-26: books chapter navigation + resume/start discordance

**Status: DIAGNOSED, NOT YET FIXED. No code changed in this session.**
**Version untouched (1.8.0 / build 45) — the user groups features into releases.**

## The user report (v1.8.0 release prep)

> 1) "we have to now start working on pushing the release v1.8.0, big remaining
>    issue is that in notes preview doesnt render formulars and maths symbols
>    (e.g beta)"
>
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

**Scope split agreed mid-session:** another agent owns issue 1 (math/symbols
rendering in the notes preview). THIS session owns issues 2 + 3 only.

## Repo state at handover

- Branch: `batch-c-d-session`, HEAD `b1139b4`.
- **Foreign WIP in the tree (another session — do NOT touch or commit):**
  - `App/Sources/Views/BookAudioReaderView.swift` (modified)
  - `App/Sources/Views/MarkdownPreviewView.swift` (modified)
  - `Packages/SpeechLogic/Sources/SpeechLogic/MarkdownText.swift` (modified)
  - `Packages/SpeechLogic/Sources/SpeechLogic/MathCommands.swift` (new)
  - `Packages/SpeechLogic/Sources/SpeechLogic/MathNotation.swift` (new)
  - `Packages/SpeechLogic/Tests/SpeechLogicTests/MathNotationTests.swift` (new)
  - `Packages/SpeechLogic/Package.resolved` (untracked)
  These are the OTHER agent's maths work. Stage by explicit path only.
- No local Swift toolchain — app-target changes verify via GitHub Actions
  (`gh workflow run build.yml --ref <branch>`; `build.yml` auto-runs only on
  `main` / `sage-upgrades`).

---

# ISSUE 2 — next/previous chapter jumps to the LAST chapter

## The two readers have separate root causes. Both are real.

### 2a. EPUB reader — `App/Sources/Views/BookReaderView.swift`

**Symptom:** prev/next chevrons at the bottom of the EPUB reader jump to the
last chapter instead of the adjacent one.

**Status: NOT YET DIAGNOSED. The exploratory reading below was inconclusive
— the next session must settle it empirically before changing code.**

**What IS established (verified):**

1. `BookReaderView.chapterIndex` is the **SPINE index** — it comes from
   epub.js's `relocated` event (`location.start.index`, which is the index
   into the book's spine). `handleRelocated` (line 709-718) sets it.
2. The bottom chevrons step it by ±1: `goChapter(chapterIndex - 1)` /
   `goChapter(chapterIndex + 1)` (lines 443, 458). The rail and the
   minimised pill do the same (lines 175-176, 416-417).
3. The TOC sheet taps resolve to `row.entry.spineIndex` (line 497-499),
   which is ALSO a spine index — `BooksStore.buildManifest` (line 639-645)
   maps every TOC href to its spine index at import:
   `indexByHref[entry.href]`. **So the chevrons and the TOC are in the SAME
   index space.** The "TOC works, chevrons don't" asymmetry the user
   describes is therefore NOT a spine-vs-TOC space mismatch.

**The remaining candidate explanations (test them in this order):**

- **(A) The TOC has more entries than the spine, and the USER counts TOC
  rows while the chevrons count spine items.** A compiled-notes EPUB often
  has 12 spine documents but 60+ TOC rows (many sections share one
  document). Tapping TOC row 20 lands on spine item 3; pressing "next"
  then goes to spine item 4 — which the user may perceive as "it jumped to
  the wrong place", and if the last TOC rows all map to the LAST spine
  item, pressing next near the end repeatedly lands on the last spine
  item — **"it only jumps to the last chapter"**. **THIS FITS THE REPORT
  BEST.** Verify by printing `book.spine.count` vs `book.toc.count` and
  the `spineIndex` of each TOC row.
- **(B) `goChapter` never updates `chapterIndex` optimistically.** It only
  calls JS (line 730-732); `chapterIndex` changes when the `relocated`
  event comes back. If the JS command does not take effect (the book is
  still opening, or `window.RENDITION` is nil — `readerGoChapter` returns
  early in that case), the chevrons compute the SAME target again and
  again. **This is a real defect worth fixing regardless** — the reader
  should set `chapterIndex` immediately and let the relocation correct it.
- **(C) `RENDITION.display(item.href)` vs `RENDITION.display(index)`.**
  `reader.js` (App/Resources/epubjs/reader.js:273-277) passes the item's
  HREF string; `Rendition._display` resolves it via
  `book.spine.get(href)` → `spineByHref[t.href]`. `Spine.append` registers
  each item under `t.href`, `encodeURI(t.href)` and `decodeURI(t.href)`,
  and `Spine.unpack` overwrites `t.href` with the MANIFEST href — the
  same string `reader.js` reads back off the item. **So the lookup
  resolves.** This was explored and is NOT the bug. Passing the SPINE
  INDEX instead (`RENDITION.display(index)`) would sidestep the
  href-key question entirely and is a cheap robustness win.

**RECOMMENDED FIX for the EPUB reader, once (A)/(B) are confirmed:**

```swift
private func goChapter(_ index: Int) {
    // Move the bar IMMEDIATELY: the chevrons used to wait for the
    // webview's relocation event, so a command the webview had not
    // picked up yet (still opening, or RENDITION not ready) left the
    // bar on the old chapter and the next press computed the same
    // target again.
    let clamped = max(0, min(max(totalChapters - 1, 0), index))
    chapterIndex = clamped
    chapterFraction = 0
    webView?.evaluateJavaScript("readerGoChapter(\(clamped))", completionHandler: nil)
}
```

and in `reader.js`, navigate by index rather than by href:

```javascript
window.readerGoChapter = function (index) {
    if (!window.BOOK || !window.RENDITION) return;
    var item = window.BOOK.spine.get(index);
    if (!item) return;
    if (window.RENDITION.display.length) { /* by index when supported */ }
    window.RENDITION.display(item.href);
};
```

**ALSO consider (A)'s UX fix:** the bottom bar should step the SAME list
the user sees in the Contents sheet. If the TOC is finer than the spine,
either (i) step TOC rows (and jump to their `spineIndex`) or (ii) label the
bar honestly — "Chapter 3 of 12" (spine) vs. the TOC's 60 rows — so the
two counts cannot be confused. Option (i) matches the user's expectation
("jump to the previous/next chapter" = the chapters they see listed).

### 2b. PDF reader — `App/Sources/Views/BookPDFReaderView.swift`

**THIS one is a confirmed, reproducible-by-inspection bug. Fix this first.**

`currentChapterIndex` (line 210-217):

```swift
private var currentChapterIndex: Int {
    guard let chapters = book.pdfChapters, !chapters.isEmpty else { return 0 }
    if let index = chapters.firstIndex(where: { currentPage >= $0.startPage && currentPage <= $0.endPage }) {
        return index
    }
    // Before the first chapter (cover/colophon): step from its start.
    return currentPage < (chapters.first?.startPage ?? 0) ? 0 : chapters.count - 1
}
```

**When the visible page is NOT inside any chapter's page range, this returns
`chapters.count - 1` — THE LAST CHAPTER.** Then:

- "Next chapter" → `goChapter(currentChapterIndex + 1)` → clamped to
  `chapters.count - 1` → **the last chapter**.
- "Previous chapter" → `goChapter(currentChapterIndex - 1)` → `count - 2` →
  the second-to-last.

**That is exactly the reported symptom: "its only jumping to the last
chapter".**

**Why the page falls outside every chapter range — the REAL cause
(corrected 2026-10-26 after re-reading the builders):** it is **NOT** a gap
in the chapter builder. Re-reading `PdfText.chaptersFromOutline`
(PdfText.swift:68-116) and `chaptersFromHeadings` (line 124-162) with care:
`kept` is strictly increasing, so `end = next.start - 1` is always
`>= start.page` and the `guard end >= start.page else { continue }`
**never fires**. The ranges TILE the document contiguously — outline path
(chapters run to `pageCount - 1`), heading path (front matter + one range
per candidate, last running to `pageCount - 1`), and `fallbackChapters`
(page groups). **The builder is sound.** The earlier "heading gaps" reading
in this handover was wrong; disregard it.

**The page falls outside every range because THE READER IS LOOKING AT A
STALE CHAPTER LIST.** See issue 3 root cause (a): `BooksStore.updatePosition`
and `markOpened` replace the WHOLE shelf entry from the reader's STALE
`book` snapshot. If the shelf backfill re-resolved `pdfChapters` after the
reader captured its snapshot (import-time resolution failed and the
backfill later produced the real list; or the source changed from "pages"
to "headings"; or the book was imported from the Linux app and the
backfilled list differs from the imported one), the reader keeps stepping
through the OLD list while the document has a different page layout — the
visible page then matches no range, and the fallback fires.

**That is why the symptom is "always the last chapter":** the fallback
`chapters.count - 1` is reached on EVERY step, because the page is outside
every range of the stale list. The next press computes `chapters.count - 1 + 1`
→ `goChapter`'s clamp folds it back to `chapters.count - 1` → **the same
last chapter, again and again.** It LOOKS like "next always goes to the
end", and prev would step to `count - 2` — which the user may not have
noticed because the first symptom they hit was next.

**So the PDF fix has TWO parts — do BOTH:**
1. Stop the stale-snapshot writes (issue 3 root cause (a)). That is what
   actually puts the reader out of step with its own manifest.
2. Make the fallback honest anyway — `chapters.count - 1` is never a
   sensible answer for "which chapter am I in". It must be the chapter that
   STARTS at-or-before the visible page.

**THE FIX (PDF), part 2 — replace the fallback with:**

```swift
// The page sits outside every chapter's range (a stale list, or a page
// the resolver skipped): it belongs to the chapter that STARTS at-or-before
// it. The old fallback returned `chapters.count - 1` — the LAST chapter —
// so every next/prev press landed on the end of the book.
if let index = chapters.lastIndex(where: { $0.startPage <= currentPage }) {
    return index
}
return 0
```

**NOTE the clamp in `goChapter` is what makes the symptom PERMANENT:**

```swift
let clamped = max(0, min(chapters.count - 1, index))
```

With `currentChapterIndex == chapters.count - 1`, "next" computes
`chapters.count` → clamped to `chapters.count - 1` → **the same last
chapter, no movement**. Exactly "it's only jumping to the last chapter".

**Also worth fixing while here — the stepper should not be able to sit on a
chapter it does not move from.** `goChapter` currently returns silently when
`clamped == currentChapterIndex` and the page is already at the chapter
start. With the fallback fixed the stepper moves properly, but a visible
"no movement" is still worth a log line while diagnosing.

### 2c. The TOC/stepper granularity mismatch (PDF)

Even with 2b fixed, the steppers walk `book.pdfChapters` (top-level
outline nodes) while the **Contents sheet** shows the full outline tree
(`outlineRows`, every level). The user asked to jump "to the previous
chapter or to next chapter" using the buttons at the bottom, expecting the
same granularity they see in the TOC. **The steppers should walk the SAME
list the Contents sheet shows** — i.e. `outlineRows` when it is non-empty,
falling back to `book.pdfChapters`.

That also fixes the PDF **playback** mismatch: `BookPlaybackController`
speaks `book.pdfChapters` (top-level units), while the reader's stepper
would walk the finer outline — the play button would speak a different unit
than the one the reader shows. **Keep ONE list.** The honest resolution:
build the manifest's `pdfChapters` from the FULL outline tree (all levels),
not just top-level nodes. `PdfText.chaptersFromOutline` is the place to
change — but that changes the TTS unit boundaries for every PDF, so it
needs care (auto-advance granularity changes).

**A SAFER, RECOMMENDED SHAPE:** keep `book.pdfChapters` as the SPEECH unit
list (top-level), and give the reader a separate, finer NAVIGATION list
built from the live outline (`outlineRows`) for the Contents sheet AND the
steppers. The steppers then move the PAGE; the play button still speaks the
top-level chapter containing that page. The two can disagree about
granularity but not about **which page you are on** — and the user's
complaint is about page/chapter destination.

---

# ISSUE 3 — resume vs. manual start discordance (PDF focus)

## Root cause: the manifest's single `position` field is overloaded, and the
## PDF reader writes PAGE index into a field that other code reads as
## CHAPTER index.

`BookPosition` (App/Sources/Models/Book.swift:25-30):

```swift
struct BookPosition: Codable, Equatable, Hashable {
    var chapterIndex: Int
    var chapterFraction: Double
    var cfi: String?
    var audioSeconds: Double?
}
```

Its doc comment says:

> "EPUB: spine index + scroll fraction inside the chapter; **PDF: page index
> + fraction inside the page**. One shape keeps the manifest and the resume
> logic format-agnostic."

**So for a PDF, `chapterIndex` holds a PAGE index.** Now follow every
consumer:

| Consumer | File:line | Treats `chapterIndex` as | Correct for PDF? |
|---|---|---|---|
| PDF reader resume | BookPDFReaderView.swift:56 | page index | ✅ |
| PDF `goChapter` write | BookPDFReaderView.swift:347, 668, 697, 776 | page index | ✅ |
| EPUB reader resume | BookReaderView.swift:84 | spine index | ✅ |
| **BookPlaybackController.resumeBook** | SpeechnotesApp.swift:118 → `resumeBook(book:from: chapterIndex)` | **chapter index** | ❌ **BUG** |
| **SpeechPlayer.bookResumeHandler** | SpeechnotesApp.swift:112-120 | **chapter index** | ❌ **BUG** |
| `GoalMath.fraction(of:)` | ReadingGoalsView.swift:140-144 | PDF: page index / pageCount | ✅ |
| `StatsTabView.bookProgress` | StatsTabView.swift:465-470 | PDF: page index / pageCount | ✅ |
| `BookPlaybackController.chapterCount` | BookPlaybackController.swift:160-166 | PDF: `pdfChapters.count` | — |

### THE CORE DISCORDANCE (issue 3), precisely

**1. The persisted position is a PAGE index; the resume path treats it as a
CHAPTER index.**

`SpeechPlayer` keeps a `PlaybackBookmark` with `bookId` + `chapterIndex`.
When a book chapter finishes and the app is backgrounded, the bookmark holds
**the chapter index that was spoken**. On foreground,
`player.bookResumeHandler(bookId, chapterIndex)` →
`BookPlaybackController.shared.resumeBook(book: book, from: chapterIndex)` →
`speak(book:from:)` → `chapterText(for: book, chapterIndex:)` →
`PdfSpeechText.chapterText(book:chapterIndex:)` → reads
`chapters[chapterIndex].startPage...endPage`.

That path is **chapter-indexed and correct** — it does NOT read
`book.position`. Good.

**2. But the PDF READER's resume path is PAGE-indexed, and the two are
stored in the SAME field.**

- The PDF reader writes `position.chapterIndex = currentPage` (a PAGE).
- The SpeechPlayer bookmark ALSO stores a `chapterIndex` — but in a
  DIFFERENT store (`BookmarkStore`, not the book manifest).

So within the manifest, `position.chapterIndex` = page. That is
self-consistent for the reader.

**3. Where the two ACTUALLY collide — the audiobook-style "resume" and the
"start from a page" both write `position.chapterIndex`, and NOTHING
records which UNIT the value is in.**

Now the REAL bug the user hit. Look at `BookPDFReaderView.goToPage`
(line 688-706) and `handlePageChange` (line 665-669):

```swift
private func handlePageChange(pageIndex: Int, pageCount: Int) {
    currentPage = pageIndex
    if pageCount > 0 { self.pageCount = pageCount }
    store.updatePosition(book, chapterIndex: pageIndex, chapterFraction: 0)
}
```

`handlePageChange` fires on **EVERY** PDFKit page-changed notification —
including the one caused by the reader's own initial `go(to: savedPage)`.
And `BookPDFView.Coordinator.applyOpened` (line 1005-1019):

```swift
func applyOpened(startPageIndex: Int) {
    guard let opened, let pdfView, pdfView.document !== opened.document else { return }
    pdfView.document = opened.document
    BookPDFView.applyWidthFit(pdfView, width: fitWidth)
    if startPageIndex > 0,
       startPageIndex < opened.document.pageCount,
       let page = opened.document.page(at: startPageIndex) {
        pdfView.go(to: page)
    }
    self.opened = nil
}
```

`startPageIndex` comes from `currentPage`, which is initialised from
`book.position?.chapterIndex ?? 0` (line 56). **For a PDF that is a page
index — correct.** ✅

**4. THE ACTUAL BREAK — `goToPage` has a hard guard that makes "start from
any page I want" IMPOSSIBLE for some pages, and the chapter/Contents jumps
silently do nothing:**

```swift
private func goToPage(_ index: Int) {
    guard let pdfView, let document = pdfView.document,
          index >= 0, index < document.pageCount,
          let page = document.page(at: index) else {
        Log.shared.info("PDFContents: cannot jump — page \(index + 1) of \(book.pageCount ?? 0) not resolvable")
        return
    }
    ...
}
```

**If `pdfView` is nil (the document has not finished opening) or the
document is not yet assigned, EVERY jump is silently dropped** — and the
position is NOT written, so the resume point stays stale. On a big scanned
PDF (the OBGYN notes are large), the open takes seconds; the user taps a
chapter in the Contents sheet **before the document lands** → the tap does
nothing, and the reader stays on the old page. Then the user thinks
"jumping to a chapter doesn't work" and "resume goes somewhere else".

**5. AND the position write is NOT atomic with the view — `onDisappear`
overwrites it.**

`BookPDFReaderView.onDisappear` (line 345-349):

```swift
.onDisappear {
    player.miniPlayerSuppressed = false
    store.updatePosition(book, chapterIndex: currentPage, chapterFraction: 0)
    readingRecorder.end()
}
```

`currentPage` is the **local @State**. If a jump was dropped (pdfView nil),
`currentPage` never changed → `onDisappear` writes the OLD page. But if the
jump SUCCEEDED, `goToPage` sets `currentPage = index` and writes the
position — then `onDisappear` writes it again. Same value, harmless.

**The REAL killer — `store.updatePosition(book, ...)` takes the `book`
VALUE the view was constructed with, which has the STALE `position`.**
`updatePosition` (BooksStore.swift:1191-1200):

```swift
func updatePosition(_ book: Book, chapterIndex: Int, chapterFraction: Double, cfi: String? = nil, audioSeconds: Double? = nil, sync: Bool = false) {
    var updated = book
    updated.position = BookPosition(chapterIndex: ..., chapterFraction: ..., cfi: cfi, audioSeconds: audioSeconds)
    save(updated, sync: sync)
}
```

`save(updated)` → `allBooks[idx] = book` — **it REPLACES the whole shelf
entry with a snapshot taken from the view's stale `book` value.** If
anything else updated the book in the meantime (the backfill writing
`pdfChapters`, the scan probe writing `pdfIsScanned`, `markOpened` writing
`lastOpenedAt`), **this write reverts those fields.**

**Concretely, this is the discordance:**
- The backfill pass (BooksStore.swift:359-463) runs on shelf refresh and
  writes `book.pdfChapters`, `book.pdfIsScanned`, `book.hasCover` to the
  manifest.
- The reader holds the OLD `book` value (captured at navigation time).
- The reader's `handlePageChange` → `updatePosition(oldBook, ...)` → `save`
  → **the manifest is rewritten with the OLD book, losing the freshly
  backfilled `pdfChapters`** (or the new `lastOpenedAt`).

**`markOpened` has the same shape** (line 1184-1189) — and it is called in
`.onAppear` (line 313) BEFORE the backfill may have landed. And
`toggleForceOCR` (line 719-736) calls `store.save(updated)` with a snapshot
taken from the same stale `book` — reverting the position to whatever the
stale snapshot held.

### THE MINIMAL, HIGH-VALUE FIXES FOR ISSUE 3

**(a) Make `updatePosition` merge into the CURRENT shelf entry, not replace
it.** In `BooksStore.updatePosition`, read the live book from `allBooks`
first and only replace the `position` field:

```swift
func updatePosition(_ book: Book, chapterIndex: Int, chapterFraction: Double, cfi: String? = nil, audioSeconds: Double? = nil, sync: Bool = false) {
    // Merge into the LIVE shelf entry: the view's `book` snapshot can be
    // stale (the backfill wrote pdfChapters/scan flags; markOpened wrote
    // lastOpenedAt). Replacing the whole entry from that snapshot silently
    // REVERTED those fields — the old book came back without its chapters.
    var updated = allBooks.first(where: { $0.id == book.id }) ?? book
    updated.position = BookPosition(...)
    save(updated, sync: sync)
}
```

Same for `markOpened` and `toggleForceOCR`'s `store.save(updated)`.

**(b) Queue pending jumps until the PDF document has landed.**
`goToPage` currently drops the jump when `pdfView` is nil / document not
assigned. Add a `@State private var pendingPage: Int?` and apply it in the
`onDocumentLoaded` callback. **This is the "start from any page I want"
fix** — on a big PDF the user taps a chapter before the document is ready and
nothing happens today.

**(c) Make the "start from a chapter/page" explicit about what it changes.**
The PDF reader's Contents sheet writes `position` via `goToPage` — good. But
the reader ALSO has `currentPage` as local state that is the source of truth
for the bar, while `book.position` is the persisted mirror. **The
discordance the user feels is that the persisted position and the visible
page can disagree** because of (a) and (b). Fixing both makes resume land
exactly where "start from page N" left off.

**(d) Consider a `pageIndex` field on `BookPosition` for PDFs.** The clean
model: `BookPosition.chapterIndex` means "chapter index" EVERYWHERE, and a
PDF's position is `{chapterIndex: <chapter containing the page>,
chapterFraction: <fraction through that chapter>, pageIndex: <exact page>}`.
That removes the overloading entirely and makes `BookPlaybackController`'s
chapter-indexed resume work with the manifest too.

**`BookPosition` is `Codable` with synthesized keys** — adding a field with a
default (`var pageIndex: Int? = nil`) keeps every existing manifest
decodable. **This is the structurally correct fix** and it is what makes
"resume" and "start from page N" the SAME thing instead of two
discordant paths.

---

# WHAT TO DO NEXT (concrete order)

1. **`BooksStore.updatePosition` / `markOpened` merge** (3a) — stop
   reverting the backfilled fields. **This is the ROOT fix for issue 2 as
   well**: the stale chapter list is what pushes the PDF reader into the
   "last chapter" fallback. HIGHEST VALUE, LOWEST RISK.
2. **PDF `currentChapterIndex` fallback** (2b part 2) — one-function fix in
   `BookPDFReaderView.swift:210-217`: never answer "last chapter"; answer
   the chapter that starts at-or-before the visible page. Belt and braces
   for the same symptom.
3. **PDF pending-jump queue** (3b) — `goToPage` before the document lands.
   This is the "start from any page I want" half of issue 3.
4. **`BookPosition.pageIndex`** (3d) — the structural fix; needs a
   migration-aware decoder and updates in BookPDFReaderView,
   GoalMath, StatsTabView.
5. **EPUB next/prev** (2a) — **VERIFY FIRST** which index space the
   chevrons are in (spine vs TOC) and whether `goChapter`'s JS round-trip
   works. The most likely fix is to make the chevrons and the TOC agree on
   one list and to have `goChapter` update `chapterIndex` optimistically so
   the bar does not show a stale value until the relocation arrives.
6. **Stepper/TOC granularity for PDFs** (2c) — decide whether the steppers
   walk the live outline tree or the manifest chapters. Recommend: the live
   outline tree for navigation; keep the manifest list as the SPEECH unit.

**NOT needed (ruled out while diagnosing — do not "fix" these):**
- `PdfText.chaptersFromOutline` / `chaptersFromHeadings` / `fallbackChapters`
  page tiling — they already tile the document contiguously. The
  `guard end >= start.page else { continue }` never fires.
- The `front matter` insert — it works as intended.
- epub.js's `Spine.get` / `spineByHref` triple-keying — the href the app
  passes (`item.href`) IS the key epub.js registered, so the lookup resolves.

## Verification

- No local Swift toolchain. Verify via:
  `gh workflow run build.yml --ref batch-c-d-session` then watch it.
- Add unit tests in `Packages/SpeechLogic/Tests/SpeechLogicTests/` for the
  chapter-gap tiling (they run in CI on Linux with the SpeechLogic package).
- The PDF reader view itself has no test target — the reader-side fixes are
  CI-compile-verified only and need a DEVICE check.
- Device checklist for the fix:
  - Open the OBGYN notes PDF; Contents shows the sections; the bottom
    next/prev chevrons move ONE section at a time (not to the last).
  - Jump to page N from Contents; close the book; reopen → lands on page N.
  - Read to page M; close; reopen → lands on page M.
  - Open the book on a second device (BookDrop) → position starts fresh
    (BookDrop sends only the original file — position stays on the source
    device, by design; see BookDropSendView.swift:244).

## RELEASE NOTE (issue 4)

The user said: "if you are certain youve solved this you can push the
release". **Issues 2 and 3 are NOT solved yet — do not push.** Also, the
other agent's maths work (issue 1) is uncommitted in the tree, so a release
push must not be made until both sides' work is committed and CI is green
on the release branch. Per the version policy, `MARKETING_VERSION` stays
`1.8.0`; only `CURRENT_PROJECT_VERSION` moves (45 → 46).
