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

**Root cause: the chapter bar's index and the TOC's index are DIFFERENT
numbering spaces.**

- `BookReaderView.chapterIndex` (line 21) is the **SPINE index** — epub.js's
  `location.start.index`, which is the index into the book's SPINE
  (`book.spine`), i.e. the reading-order list of content documents.
- `Book.toc` (the table of contents the user sees and taps) is built in
  `BooksStore.buildManifest` (App/Sources/Services/BooksStore.swift:639-645)
  from the EPUB's NAV/NCX document, and each entry carries `spineIndex` —
  the index of the spine item its href points at.

**The mismatch:** a book's TOC has MANY MORE entries than its spine. A
typical compiled-notes EPUB has, say, 12 spine items but 60+ TOC entries
(one per section/subsection, many of which live inside the SAME spine
document). epub.js's `relocated` reports the SPINE index. The TOC sheet
shows the TOC's own row order. So:

- The **TOC tap** path works, because `BookReaderView.tocSheet` (line 497)
  resolves `row.entry.spineIndex` and calls `goChapter(spineIndex)` — a
  SPINE index. Correct.
- The **next/prev chevron** path computes `goChapter(chapterIndex + 1)`
  (lines 443, 458) — also a SPINE index, which is *self-consistent*.

So on a spine-index basis the chevrons should be right... **unless the
spine index the chevrons use and the spine index epub.js uses disagree.**
And they do, because of the following.

**The actual defect — `goChapter` does not update `chapterIndex`, and the
relocation round-trip is what makes the chevrons land wrong.**

`BookReaderView.goChapter` (line 730-732):

```swift
private func goChapter(_ index: Int) {
    webView?.evaluateJavaScript("readerGoChapter(\(index))", completionHandler: nil)
}
```

and `reader.js` (App/Resources/epubjs/reader.js:273-277):

```javascript
window.readerGoChapter = function (index) {
    if (!window.BOOK || !window.RENDITION) return;
    var item = window.BOOK.spine.get(index);
    if (item) window.RENDITION.display(item.href);
};
```

`RENDITION.display(item.href)` is called with a **STRING href**, not the
spine index. Look at what epub.js does with that (vendored
`App/Resources/epubjs/epub.min.js`):

- `Rendition._display(t)` → `this.book.spine.get(t)` where `t` is the href
  string → `Spine.get` resolves `spineByHref[t] || spineByHref[encodeURI(t)]`
  → this is where the href must match a **spine item's exact href key**.
- `manager.display(target)` → `this.views.find(t)` → `find` compares
  `e.section.index == t.index`. With `t` a string, `t.index` is `undefined`,
  so `find` NEVER matches and epub.js falls through to `this.clear()` +
  `this.add(t)`.

**`this.add(t)` renders the section — but the `section.index` that comes back
in the next `relocated` event is the SPINE index of the rendered item.** That
part is consistent.

**So where does "last chapter" come from? The href key mismatch.**
`Spine.append` registers each item under THREE keys:
`spineByHref[decodeURI(t.href)]`, `spineByHref[encodeURI(t.href)]`, and
`spineByHref[t.href]`. But `Spine.unpack` OVERWRITES `t.href` with the
**manifest** href when the manifest entry exists:

```javascript
r = this.manifest[t.idref];
if (r) { t.href = r.href; t.url = e(t.href, true); ... }
```

The manifest href is the OPF `<item href="...">` value — e.g. `text/chap3.xhtml`
— which is **relative to the OPF directory**. `reader.js` calls
`BOOK.spine.get(index)` and passes `item.href` to `RENDITION.display()`. That
href string is the same string used as the `spineByHref` key, so
`spine.get(href)` resolves correctly and it works... **when the href has no
fragment and no encoding difference.**

**The decisive detail — `readerGoChapter` passes a NUMBER to `spine.get`,
but `RENDITION.display` then receives a HREF, and the href round-trip through
`display()` is what breaks.** Concretely, `Rendition.display(t)` has this
guard at its head:

```javascript
display(t, e) {
    ...
    (e === t.href || Object(r.isNumber)(e)) && (e = void 0);
    var s = this.views.find(t);
    if (s && t && "pre-paginated" !== this.layout.name) {
        // scroll to the ALREADY-RENDERED view for this section
        ...
        return i.resolve(), n;
    }
    this.clear();
    ...
    this.add(t, o) ...
}
```

`this.views.find(t)` looks for a view whose `section.index == t.index`. When
`t` is a **string href**, `t.index` is undefined → no match → `this.clear()`
and re-render. When `t` is a **number** (spine index), `t.index` is also
undefined (numbers have no `.index`) → also no match. Either way it re-renders.
That is not the bug by itself.

**The bug is what `RENDITION.display(href)` renders vs. what the reader
THINKS it rendered.** `Rendition.display(t)` → `this.add(t)` → `createView(t)`
→ `new View(t, ...)`. The `View`'s `section` is the **spine item object**
passed in. `Spine.get(index)` returns the spine item, whose `.index` was set
in `unpack`: `this.items.forEach((t, n) => { t.index = n; ... })`.

**BUT** `Rendition.display(t)` receives `item.href` — a STRING — and
`manager.display(target)` → `this.add(t)` → `createView(t)` → `new View(t)`.
`View`'s constructor takes the **section**; passing a string means
`this.section` is a string, and `this.section.index` is `undefined`!
`View.display(request)` then does `this.section.load(request)` — and a
**string has no `.load`** → the view fails to render its content, OR epub.js's
`Section` wrapper handles it.

Wait — this needs checking against `Rendition.display` again: in
`Rendition._display(t)`, `t` is FIRST resolved via `this.book.spine.get(t)`:
`(e = this.book.spine.get(t)) ? this.manager.display(e, t)`. So the SECTION
OBJECT is what reaches `manager.display`. **`t` is the section object, whose
`.index` IS the spine index.** So `views.find(t)` compares `section.index ==
t.index` → **matches** → and `this.scrollTo(...)` + `this.locationOf(e)` path
runs, and `this.add(t)` is never reached.

**THAT is the bug.** `Rendition.display(href)`:
1. `spine.get(href)` → resolves to the spine item → `manager.display(section, href)`.
2. `manager.display(t=section)` → `this.views.find(t)` → **matches the
   already-rendered view for that section** (because epub.js renders
   sections continuously in scroll flow, and the view for that section may
   still be mounted) → it SCROLLS to it and resolves.

So in **scrolled flow**, calling `display(href)` for a section that is
already rendered scrolls to it — correct.

**In PAGINATED flow**, `this.layout.name === "paginated"` so the
"already rendered" shortcut is skipped (`"pre-paginated" !== this.layout.name`
is TRUE for "paginated", so the shortcut IS taken). Hmm.

OK — the cleanest statement of the defect, which the empirical device report
confirms, is:

**`readerGoChapter` navigates by SPINE INDEX, while the reader's chapter bar
and the TOC are in TOC space.** Let me re-verify by reading the numbers
rather than the internals, because the internals are ambiguous and the
numbers are decisive.

Let me do that verification in the NEXT session — it is the single most
important open question, and it decides between two different fixes:

- **(A)** the chevrons step the wrong index space (spine vs TOC), or
- **(B)** the chevrons step the right space but `goChapter` fails to
  round-trip (the JS command doesn't take effect and the reader stays where
  it was, or epub.js renders the wrong section).

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

**Why the page falls outside every chapter range:** `PdfText.chaptersFromOutline`
(Packages/SpeechLogic/Sources/SpeechLogic/PdfText.swift:68-116) builds
chapters from the PDF's OUTLINE top-level nodes. The outline's top-level
nodes are typically **PART/TITLE-level** entries, while the fine-grained
sections the TOC sheet shows are their CHILDREN. The reader's **Contents
sheet** (`outlineSheet`, line 567) shows the FULL flattened outline tree
(`outlineRows` — every level, walked depth-first by `BookPDFView.openWithOutline`),
but `book.pdfChapters` (the manifest list the steppers use) contains only
the TOP-LEVEL nodes (`chaptersFromOutline` → `walk` stops at a node WITH a
destination and swallows its children).

**So the two lists are different lengths and different granularities.** The
user sees ~30 sections in the TOC but the steppers walk ~8 chapters. Worse:
`chaptersFromOutline` computes each chapter's `endPage` as
`nextTopLevelStart - 1`, and the LAST chapter ends at `pageCount - 1` — but
the page ranges only cover from the FIRST top-level outline node's page to
the end. Any page **before** the first top-level node is covered by a
"Front matter" chapter — but that insert only happens when
`chapters.first?.startPage > 0`, and **if the first top-level outline node
points at page 0, there is no front-matter chapter**, so pages between
chapter 0's end and chapter 1's start... no, those are contiguous.

**The real gap:** `chaptersFromOutline` computes `end = kept[position+1].page - 1`.
If the outline has TWO top-level nodes pointing at the SAME page (e.g. "Part I"
and "Chapter 1" both at page 5), the monotonic fix-up (`kept.last?.page ?? -1
< start.page`) **drops** the second one — fine. But if the FIRST top-level
node points at a LATE page (say page 40 — a book whose outline starts at the
first real section, with 40 pages of front matter), the front-matter insert
covers pages 0-39. OK.

**But `chaptersFromHeadings` (line 124-162) has the gap**: headings are
detected per page, `end = candidates[position+1].page - 1`, `guard end >=
candidate.page else { continue }` — a `continue` **SKIPS the chapter
entirely**, leaving its pages **UNCOVERED by any chapter**. Then the page
between the skipped chapter and the next one falls outside every range →
`currentChapterIndex` → `chapters.count - 1` → **the last chapter**.

**And `fallbackChapters` (page ranges) always tiles the document, so it has
no gaps.** The bug is therefore specific to books whose chapters came from
`"headings"` (or an outline with gaps), which is exactly a "compiled OBGYN
notes" PDF — a teaching-notes PDF with NO outline, so heading detection runs.

**THE FIX (PDF):** `currentChapterIndex` must never fall back to
`chapters.count - 1`. Instead, find the chapter whose range CONTAINS the page;
if none does, find the chapter whose `startPage` is the **nearest at-or-before**
the page (the chapter the page belongs to, extended forward); only if the
page is before every chapter, use 0. And `goChapter` must not silently
clamp to "last" — it should move to the adjacent chapter.

**Concretely, replace the fallback with:**

```swift
// The page sits in a GAP between chapters (or before the first): the
// chapter it belongs to is the one that STARTS at-or-before it. The old
// fallback returned `chapters.count - 1` — the LAST chapter — so every
// next/prev press from a gap landed on the end of the book.
if let index = chapters.lastIndex(where: { $0.startPage <= currentPage }) {
    return index
}
return 0
```

**Additionally**, `PdfText.chaptersFromHeadings` and `chaptersFromOutline`
should not leave page gaps at all: every chapter's `endPage` should reach
the page before the next chapter's `startPage`, and the `continue` that
skips a chapter should extend the previous chapter's range instead.

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

1. **PDF `currentChapterIndex` fallback** (2b) — one-function fix in
   `BookPDFReaderView.swift:210-217`. Fixes "always jumps to the last
   chapter" for the reported book. HIGHEST VALUE, LOWEST RISK.
2. **`PdfText` chapter gaps** — make `chaptersFromHeadings` /
   `chaptersFromOutline` tile the document (extend the previous chapter's
   `endPage` instead of `continue`-skipping) so no page is outside every
   range. Add a test.
3. **`BooksStore.updatePosition` / `markOpened` merge** (3a) — stop reverting
   the backfilled fields.
4. **PDF pending-jump queue** (3b) — `goToPage` before the document lands.
5. **`BookPosition.pageIndex`** (3d) — the structural fix; needs a
   migration-aware decoder and updates in BookPDFReaderView,
   GoalMath, StatsTabView.
6. **EPUB next/prev** (2a) — **VERIFY FIRST** which index space the
   chevrons are in (spine vs TOC) and whether `goChapter`'s JS round-trip
   works. The most likely fix is to make the chevrons and the TOC agree on
   one list and to have `goChapter` update `chapterIndex` optimistically so
   the bar does not show a stale value until the relocation arrives.
7. **Stepper/TOC granularity for PDFs** (2c) — decide whether the steppers
   walk the live outline tree or the manifest chapters. Recommend: the live
   outline tree for navigation; keep the manifest list as the SPEECH unit.

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
