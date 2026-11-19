# HANDOVER — the foliate document viewer (mobi/azw3/fb2/rtf/html/txt)

**State: implementation is ~90% done, UNCOMMITTED, and never compiled.** There is no Swift
toolchain on this box (`swift --version` → not found); CI is the compile gate. The next agent
must read this file first, then `git diff`, then finish the items in §6.

Branch `batch-c-d-session`, base commit `9ebfe9d`. Nothing has been committed yet.

---

## 1. Why this work exists (the user's report)

> "I've committed a lot of mobi/azw3/fb2 etc foliate work to the app but none of it is
> working… the table of contents is failing to work for navigation… and I can't go to the
> next/previous chapters using the button… I don't want the content in the books to be parsed
> or extracted — I want a native viewer/display, the way slides and PDF have not parsed or
> extracted text… the parsing maybe only for TTS, but the formats should have their own
> viewers."

The foliate work (committed in `6c2f7b6` + two CI fix-ups) never ran on a device. Every
document-family book still renders through the old pre-parsed `doc/chapter-N.html` "pages"
pipeline, and that pipeline cannot navigate.

### The five root causes (all verified line-by-line against the code)

| # | Fault | Evidence | Effect |
|---|---|---|---|
| 1 | **The engine never opened a book.** The parse page is `bookscheme://shell/foliate.html?...&src=/parse/current`; the shell's `fetch('/parse/current')` resolves against the page's OWN authority → `bookscheme://shell/parse/current` → the handler's `case "shell"` looks it up in the asset allow-list → `current` is not in it → 404. The `case "parse"` branch was unreachable (nothing ever built `bookscheme://parse/current`). | `DocumentParseService.swift:132-139` vs `:301-308`; `sn-shell-ios.js:211` | every import silently took the Swift fallback → `docRenderer:"pages"` → `rendersWithFoliate` always false → the foliate reader path was dead code |
| 2 | **The running renderer cannot navigate.** The pages script jumped to `location.href = "/" + "chapter-N"`, dropping the book's UUID segment → `bookscheme://book/chapter-N`, while the handler demands `/<uuid>/<name>` → `badURL`. The ordinal parser had the same bug (`location.pathname` is `/<uuid>/chapter-N`, so `/^chapter-(\d+)$/` never matched). | `BookWebView.swift:561` vs `:266-270` | every next/prev chevron and every TOC tap died at the scheme handler |
| 3 | **The chapter bar would still be stuck on "Chapter 1"** even after 1+2: `view.js` re-emits the progress report, which keeps the section index at `progress.section.current` and the fraction as a WHOLE-BOOK fraction — the shell read `detail.index` (undefined) → posted `0` forever. | `view.js:342-351`, `progress.js:199-202`, `sn-shell-ios.js:530-533` | prev chevron permanently disabled, next always targets section 1, position persists as 0 |
| 4 | **The fraction had the wrong unit and was fed back as a pixel offset.** `progress.fraction` is whole-book; Swift stored it as the chapter fraction and re-sent it as `anchor:` to `renderer.goTo({index, anchor})`, where a numeric anchor is a PIXEL offset. | `sn-shell-ios.js:582-590`, `paginator.js:4327` | resume landed at the section top; the % label was book-wide |
| 5 | **Commands vanished and failures were never reported.** `readerGoChapter` did `if (!view) return` (silent, no `goChapterFailed{book-not-ready}`), and `view.goTo` swallows its own errors, so the `.catch()` that would post `bad-target` was dead code. | `sn-shell-ios.js:626-635`, `view.js:537-547` | a chevron pressed during the open moved the bar and did nothing; the optimistic bar never rolled back |

Plus two supporting gaps: the **TOC authority was the import-time manifest** (stale rows, the
pages pipeline's +1 cover offset) rather than the engine, and **`fixed-layout.js` was never
vendored** although `view.js:265-268` dynamically imports it for a pre-paginated MOBI.

### What is NOT broken

- The vendored engine modules (`view.js`, `paginator.js`, `mobi.js`, `fb2.js`, `sn-*.js`) are
  **byte-identical** to `~/code/speechnotes-linux/crates/sn-ui/assets/foliate-js/`. The engine
  is fine; only the iOS shell and the Swift glue were wrong.
- The reader's URL wiring for the foliate path (`BookWebView.shellURL`) was already correct:
  `src=/book/<uuid>/original.<ext>` resolves to `bookscheme://shell/book/…`, which the handler
  serves.
- The Linux app (`~/code/speechnotes-linux`) is the reference architecture: the engine renders
  the ORIGINAL file, the importer records only {title, author, section count, TOC, spine
  names}, and **there is no `doc/` directory** in its manifests (`~/.local/share/speechnotes/
  Books/*/` has only `manifest.json` + `original.*` + `cover.jpg`).

### Decisions taken (the user chose both)

1. **Import runs a headless engine probe** for metadata + section count + TOC — no text is
   ever extracted to disk.
2. **The pre-parsed "pages" renderer stays** as the fallback for files the engine genuinely
   refuses (DRM, a `.pdb` that is really another Palm format) — and its navigation is repaired.

---

## 2. What has been changed (uncommitted)

```
 M App/Resources/foliatejs/sn-shell-ios.js           | 217 +++++++++++-----
 M App/Sources/Models/Book.swift                     |  12 +-
 M App/Sources/Services/BookPlaybackController.swift |  82 ++++--
 M App/Sources/Services/BooksStore.swift             | 121 +++++----
 M App/Sources/Services/DocumentParseService.swift   | 286 ++++++++++++++-------
 M App/Sources/Services/FoliateAssets.swift          |   5 +
 M App/Sources/Views/BookReaderView.swift            |  59 ++++-
 M App/Sources/Views/BookWebView.swift               |  75 ++++--
 ?? App/Resources/foliatejs/fixed-layout.js               (copied from the Linux app)
 ?? App/Resources/foliatejs/vendor/construct-style-sheets-polyfill.js  (its dependency)
```

### 2.1 `DocumentParseService.swift` — the root-cause file
- **The book's bytes are served on the parse page's own host**: `case "shell"` now routes
  `/parse/current` to the chunked `FileHandle` stream of `sourceURL`. The unreachable
  `case "parse"` branch was deleted; the streaming lives in one private `streamBook(_:url:)`.
  No JS change was needed for this — `src=/parse/current` stays.
- **The API changed**:
  - `static func probe(fileExtension:sourceURL:) async throws -> ProbeResult` — title, author,
    sectionCount, toc, coverData. **No section files.** The old `parse(...) -> Result` (with
    `sectionFiles`) is gone.
  - `static func sectionText(fileExtension:sourceURL:index:) async throws -> String?` — the
    TTS-only path: one section's prose.
  - Internals: `run()` = `boot()` + `readMeta()` + `readCover()`; `runSectionText(index:)`
    calls `window.__snParse.prepareSectionText(i)` and waits for the `parseSectionText` post.

### 2.2 `sn-shell-ios.js` — the only vendored file that changed
- **Parse mode**: `prepareSection`/`takeSection` (per-section XHTML) replaced by
  `prepareSectionText(index)` → posts `{type:'parseSectionText', index, ok, text}`.
  `meta()` is unchanged (title/author/language/sectionCount/toc).
- **Reader mode**:
  - The **real section index + a section-local fraction** now come from the RENDERER's
    `relocate` event (`detail.index` = section index, `detail.fraction` = fraction inside that
    section — `paginator.js:3987-4021`); the view's own event still supplies the CFI and
    `section.current` as the fallback. One `relocated` message is posted combining them.
  - **Book report**: `{type:'book', title, author, language, sectionCount, toc:[…]}` — the
    Linux shell's `book:` message adapted to the iOS object channel.
  - **Section text**: `onSectionLoad` caches `doc.body.textContent` per index and posts
    `{type:'text', index, text}`; `window.readerSectionText(index)` returns a loaded section's
    text.
  - **The epub shell's not-ready contract**: `readerGoChapter` posts
    `goChapterFailed{reason:'book-not-ready'}` while the view is booting (the jump is HELD in
    `queuedJump` and run the moment `init()` finishes) and `{reason:'bad-target'}` for an index
    outside `view.book.sections`.
  - **The bogus anchor is gone**: the resume no longer passes the fraction as a pixel anchor.
    Resume is by CFI (`view.init({lastLocation: cfi})`); without a CFI it lands on the
    section top (`renderer.goTo({index})`).

### 2.3 `Book.swift`
- New field `var docEngineTried: Bool = false` — "the engine has had its try at this file
  (it opened it, or it refused it)". A refusal is terminal, so it is never asked again.
- **Precedent for the default-value decode**: `forceOCR: Bool = false` has been in the struct
  since `0e27a49` (385 commits after the manifest format existed) and old manifests still
  decode — Swift's synthesized `Decodable` honours a property's default value for a missing
  key. `Book` has no custom `init(from:)`; `BooksStore.swift:298` decodes with
  `try?` and SKIPS a book that fails, so a wrong call here would silently empty the shelf.

### 2.4 `BooksStore.swift`
- **Import** (`.document` branch): copy `original.<ext>` → `DocumentParseService.probe` →
  stamp {title, author, spine = `chapter-0…N-1`, spineCount = N, the engine's TOC rows,
  `docRenderer:"foliate"`, `docEngineTried: true`, cover}. **No `doc/` directory is written.**
- **On probe failure** the existing Swift-parse fallback runs and stamps `"pages"` +
  `docEngineTried: true` — now the genuine-refusal path only.
- **`DocumentImportBits`** gained `docEngineTried`.
- **Migration** (`migrateLegacyDocumentBooksToFoliate` / `foliateMigrate`): the gate widened
  from `docRenderer == nil` to **every document book with `docEngineTried == false`** (which
  includes the books stamped "pages" while the engine's route was broken). It probes, and on
  success stamps "foliate" + the engine's spine/TOC, reusing the existing cover-offset
  position remap (`hadCoverPage` → `chapterIndex - 1`, `position?.cfi = nil`). On refusal it
  stamps `docEngineTried: true` so the book is not asked again.

### 2.5 `BookWebView.swift`
- New callbacks `onBook: ((String, String, Int, [BookTocEntry]) -> Void)?` and
  `onSectionText: ((Int, String) -> Void)?`; the `book` and `text` messages are handled in
  `handleMessage` and forwarded. The TOC parsing moved into
  `static func tocEntries(_:)`.
  ⚠️ Inside the nested `Coordinator`, `Self` means `Coordinator` — the calls use
  `BookWebView.tocEntries(items)`.
- **The pages renderer's jump URL is fixed**: the script now derives the book's prefix from
  the current path (`/<uuid>/`) and the ordinal from the LAST segment, so
  `location.href = bookPrefix + "chapter-K"` keeps the UUID.

### 2.6 `BookReaderView.swift`
- `onTOC`: for an engine-rendered book the **engine's TOC wins** (the manifest's rows can be
  stale/off-by-one); the epub path keeps "manifest wins".
- `onBook`: sets `totalChapters`, adopts the engine's TOC, and writes {title, author,
  spineCount, spine, toc, docRenderer, docEngineTried} back to the manifest via
  `store.mutate(book) { … }` (the merge API that does not revert newer fields).
- `onSectionText`: stores the engine's prose in a new `ReaderSectionTexts` cache
  (`@State private var sectionTexts = ReaderSectionTexts()` — a reference type, so the
  controller sees live updates).
- `.onAppear` installs the live-text provider on `BookPlaybackController.shared`; `.onDisappear`
  clears it.
- The chevrons needed **no** new logic: `goChapter`/`jumpToSpineIndex`/`clampedSpineIndex`
  already drive `readerGoChapter(index)` → `view.goTo(index)` (an in-renderer jump, no reload).

### 2.7 `BookPlaybackController.swift`
- `liveSectionText: ((UUID, Int) -> String?)?` + `bindLiveSectionText(_:)` /
  `clearLiveSectionText()`.
- `chapterText(for:chapterIndex:)` for a **foliate** book: the live reader's text first, then
  a headless engine (`DocumentParseService.sectionText`), then the existing disk cache/sanitise
  path. A **pages** book keeps the old `doc/<spine>` extraction.
- `chapterCount(of:)`: a foliate book uses `book.spineCount` (the engine's count).

### 2.8 `FoliateAssets.swift`
- `foliateShell` gained `"fixed-layout.js"` and `"construct-style-sheets-polyfill.js"`.

---

## 3. Things the next agent must know (gotchas)

- **`resumeFraction` is now dead** in `sn-shell-ios.js:380` — parsed but never read. The
  Swift side still sends `fraction` (`BookWebView.swift:148-149`) and still stores
  `chapterFraction`; for foliate books the stored fraction is now SECTION-LOCAL (from the
  renderer event), so it is consistent with the epub side. Decide whether to drop the param or
  leave it (it is harmless).
- **`view.goTo` swallows its own errors** (`view.js:537-547`) — a rejection can never be
  observed. The shell's range check is what stands in for the failure report.
- **The renderer exists only after `await view.open(book)`** — the shell's renderer listener is
  attached there, before `view.init()`, so the first relocation is caught.
- **`CFI.fake`** (`epubcfi.js:376-379`) gives mobi/fb2 a section-level CFI
  (`/6/{(index+1)*2}`), and `view.getCFI` joins the range onto it — so the CFI resume works for
  those formats even though they have no `resolveCFI`.
- **`fixed-layout.js` imports `./vendor/construct-style-sheets-polyfill.js`** — both are now
  vendored; the allow-list matches on `lastPathComponent`, so the vendor path is flattened.
- The pages renderer's `ordinalOffset = STATE.chapter - ordinal` arithmetic is now CORRECT
  because the ordinal is parsed from the last path segment. `STATE.chapter` is the SPINE index
  (the query's `chapter`), the ordinal is the doc/ ordinal (`cover` = -1).
- `DocumentParseService` is **not** `@MainActor` as a class, but `run`/`boot`/`evaluate`/
  `nextMessage` are `@MainActor`; the static entry points are nonisolated async and hop.
- `BookPlaybackController` IS `@MainActor`; its `bindLiveSectionText` / `clearLiveSectionText`
  are called from `.onAppear` / `.onDisappear` (main-actor context via SwiftUI's `View`).

---

## 4. The test corpus (real files, on this box)

`~/Downloads` — ~12 real books:
```
en_SC.mobi
 Keith Johnstone - IMPRO ... .mobi
[Gabriel Garcia Marques] One Hundred Years of Solitude ... .mobi
Ulysses.azw3
A Readers Companion to J. D. Salinger's The Catcher in the Rye ... .azw3
Ulysses S Grant_ The Forgotten Hero ... .azw3
In Search of Lost Time, Volume I ... .epub          (the epub control)
The Great Gatsby ... .rtf
Catcher in the Rye ... .rtf
[One hundred years of solitude] ... .fb2
The catcher in the rye ... .fb2
Фицджеральд ... The Great Gatsby - .fb2
```
Two `.azw3` files are **0 bytes** (truncated downloads) — good negative cases.

The Linux app's imported corpus is in `~/.local/share/speechnotes/Books/<uuid>/` (manifest +
original + cover, **no `doc/`** — the target shape).

---

## 5. What is left to do

### 5.1 The engine harness (the verification the user asked for: "there are a lot of files you
can use to test")
A page under `Scripts/foliate-harness/` that runs the SAME format dispatch as
`sn-shell-ios.js` and reports, per file: **section count, the TOC rows (label + resolved
section index), and the first section's text**. These are the exact numbers the iOS manifest
must carry, so the harness pins them before the Swift work lands and catches a regression later.

- It needs a **DOM** (custom elements, iframes) → run it in the browser harness
  (`browser-use:control-browser` skill) against a local http server, NOT bare Node.
- Suggested shape: `Scripts/foliate-harness/index.html` + a tiny static server; the page
  imports `../../App/Resources/foliatejs/{mobi,fb2,sn-rtf,sn-html,sn-txt,sn-docbook}.js`,
  opens each file with `fetch`, and prints a JSON report per file.
- Node can still do the **syntax** gate: `node --check` on every touched JS file (already run
  and passing for `sn-shell-ios.js`, `fixed-layout.js`, the polyfill).

### 5.2 The compile gate
No Swift toolchain here → push to CI (`.github/workflows/build.yml`, the `logic-tests` and
`build-ipa` jobs). Expect to fix Swift compile errors there; the riskiest spots are listed in
§3.

### 5.3 The device round (the real acceptance test)
1. Import a fresh `.mobi` → the manifest must show `docRenderer: "foliate"`, the engine's
   section count and the publisher's TOC (not "Chapter 1..N").
2. Open an existing shelf book → the migration re-stamps it (`docEngineTried`).
3. **The next/prev chevrons** move one section at a time; the bar reads "Chapter N of M" with
   the right N.
4. **The Contents sheet** lists the publisher's chapters; a tap lands on the right section.
5. A **TTS play** speaks the chapter on screen (the live engine text).

---

## 6. Checklist for the next agent

- [x] Read this file, then `git diff`.
- [x] Build and run the engine harness over `~/Downloads` → record the per-file numbers.
      **Done:** `Scripts/foliate-harness/` (page + frame + server) and the recorded run in
      **`Docs/FOLIATE-ENGINE-PROBE.md`**. 15 of the 17 files open; the 2 truncated ones are
      refused with a clear message; every book that opened answers a chapter jump with the
      right section.
- [x] Run `node --check` on every touched JS file — all three pass.
- [x] Re-read the Swift diff for compile errors (§3 lists the risky spots; `Self.tocEntries`
      inside the nested Coordinator was one real bug, already fixed). **One more found and
      fixed:** `BookReaderView` passed `onBook`/`onSectionText` before `onError` to
      `BookWebView`'s memberwise initializer, and Swift requires the declaration order.
- [x] Decide the `resumeFraction` dead param (§3). **Decision: it is not dead, and the
      handover's reason for dropping it was wrong** — the paginator's numeric anchor IS a
      section fraction. It is now used: the resume is the CFI, else the chapter plus the
      fraction inside that chapter.
- [x] Check the `PROGRESS_LOG.md` round convention — the repo records each round there
      (the foliate round is at `PROGRESS_LOG.md:27-37`); add this round's entry.
- [ ] Commit (the user has not asked for a commit yet — ask, or leave the tree dirty).
- [ ] Do NOT re-vendor the foliate modules: they are byte-identical to the Linux app on
      purpose.

### 6.1 What the harness found (and fixed) — the full write-up

**`Docs/FOLIATE-ENGINE-PROBE.md`** §2. The two that mattered:

1. **The metadata report would have failed the decode for every mobi/azw3.**
   `mobi.js` reports `language: ['en']` (a list); Swift's `ParseMeta.language` is a
   `String?` → the decode threw → the import fell back to the Swift parse → the foliate
   reader never opened the book. That is the original complaint, reproduced by the new
   code. The shell now flattens the engine's metadata at the boundary, and the unused
   `language` field is out of `ParseMeta`.
2. **A section with no text reports no relocation**, so the chevron moved the page but
   never moved the bar. The shell now asks the renderer which section it is showing
   (`renderer.primaryIndex`) after every jump, turn and TOC tap.
3. **A typo in the uncommitted work**: `unescapeXml`'s entity map was keyed `'#39:'`
   instead of `'#39'`, so any TOC label with an escaped apostrophe would have read
   "undefined" in the Contents sheet. Fixed.

Plus one compile error the CI would have caught: `BookReaderView` passed `onBook` /
`onSectionText` before `onError` to `BookWebView`'s memberwise initializer, and Swift
requires the declaration order.

---

## 7. Quick reference — the file index

| Concern | Path |
|---|---|
| The engine's shell (the only vendored file that changed) | `App/Resources/foliatejs/sn-shell-ios.js` |
| The shell page (the inline-splice marker) | `App/Resources/foliatejs/foliate.html` |
| The asset allow-list + the inline splice | `App/Sources/Services/FoliateAssets.swift` |
| The headless engine (probe + section text + the bytes route) | `App/Sources/Services/DocumentParseService.swift` |
| Import stamping + the migration | `App/Sources/Services/BooksStore.swift` |
| The manifest model | `App/Sources/Models/Book.swift` |
| The WKWebView host, the scheme handler, the bridge | `App/Sources/Views/BookWebView.swift` |
| The reader controller (chevrons, TOC sheet, write-back) | `App/Sources/Views/BookReaderView.swift` |
| The TTS text source | `App/Sources/Services/BookPlaybackController.swift` |
| The Linux reference app | `~/code/speechnotes-linux/crates/sn-ui/assets/foliate-js/` (+ `crates/sn-ui/examples/engine-probe.rs`) |
| The Linux Rust side's message contract | `~/code/speechnotes-linux/crates/sn-ui/src/bookview.rs` |
