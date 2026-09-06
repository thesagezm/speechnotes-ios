# Speechnotes iOS — v1.4.2 PLAN: Books (EPUB + PDF library with TTS)

> **WORK ORDER (2026-09-06).** Follow top to bottom. Branch:
> `books-v1.4.2` (off `22e5afb`, v1.4.1). Device test → promote main → tag
> v1.4.2. Approved approach (user decisions): **EPUB = WKWebView + epub.js;
> PDF = PDFKit viewer; formats = EPUB + PDF; reading = scroll, chapter-paged.**

## 0. Core design — "webview is the eyes, native code is the voice"

Rendering happens inside epub.js in a WKWebView. Speech does NOT: chapter text
is extracted (via the webview's rendered DOM, then cached to disk) and fed to
the existing native pipeline — SpeechPlayer → SpeechEngine (Kokoro/Supertonic/
System) → SentenceChunker → ReadAlongView. No engine changes needed for books.

```
Books tab (library: covers, search, import)
 ├─ .epub → BookReaderView
 │    ├─ BookWebView (ONE WKWebView + WKURLSchemeHandler serving the epub)
 │    │    └─ vendored epub.js (bundled offline, MIT) — renders 1 chapter
 │    ├─ TOC sidebar (native SwiftUI from epub.js navigation)
 │    ├─ Aa sheet (font size/colors via rendition.themes)
 │    └─ TTS: JS extracts chapter textContent → SpeechPlayer
 ├─ .pdf → BookPDFReaderView (PDFKit PDFView + PDFOutline sidebar)
 └─ Both: per-chapter speak + auto-advance, per-book bookmarks, read-along

Disk: Documents/Books/<uuid>/{original.epub|original.pdf, manifest.json,
      text/NNN.txt (cached chapter speech text), cover.jpg}
BooksStore reads per-book manifest.json — NOT notes.json (no whole-file
rewrite per save; notes store keeps doing what it does).
```

## 1. Hard rules (inherited + this release's one exception)

1. Never push red. CI green is the bar. New branch → device test → promote.
2. New screens in NEW files (type-checker budget). NoteEditorView untouched.
3. SpeechPlayer changes strictly ADDITIVE (new optional fields/callbacks,
   tolerant decoding). Never restructure it.
4. Pure logic (zip/epub parsing) lives in Packages/SpeechLogic, public,
   unit-tested. UI stays in App/Sources/Views.
5. iOS 18.0 target, Swift 5 language mode, portrait-only, LiveContainer-safe
   launch path (no file I/O in first render; BooksStore scans lazily on tab
   open).
6. **One planned exception to "project.yml untouched":** add the EPUB
   document type to CFBundleDocumentTypes. Version bumps still touch all
   FOUR fields (CFBundleShortVersionString + CFBundleVersion in
   info.properties, MARKETING_VERSION + CURRENT_PROJECT_VERSION).
7. epub.js + JSZip are VENDORED bundle assets (MIT, headers kept) — no CDN,
   no new SPM pins, fully offline.
8. No whole-file string extraction of big documents, ever: per-chapter /
   per-page-group only. No `locations.generate()` at reader open.

## 2. Phases

### Phase 1 — Storage merge + Books shell + import  ← THIS COMMIT
- **StorageSettingsView** becomes the merged screen (everything the Storage
  tab had): Storage used breakdown (incl. a new "Books" row), Exported audio
  list (rows, swipe delete/share, See-all cap), Cached images gallery, plus
  the old "Clear temporary files" under a **Maintenance** header. Delete
  `StorageView.swift`; relocate `extension URL: Identifiable`, `GalleryThumb`,
  `NotesStoreSizeReader`, `CachedImageEntry` first (NoteEditorView +
  MarkdownPreviewView depend on the URL conformance).
- **Tab swap** (SpeechnotesApp): `Tab.storage` → `Tab.books`,
  `Label("Books", systemImage: "books.vertical")`. Only file referencing it.
- **SpeechLogic additions** (pure logic, macOS-testable):
  - `ZipReader.swift` — minimal ZIP central-directory reader (Foundation +
    Compression's `COMPRESSION_ZLIB` raw-deflate inflate). Reads SINGLE
    entries out of a memory-mapped Data; supports stored + deflate; detects
    zip64/encrypted and fails with a clear error. Used for metadata + cover
    only (epub.js does the heavy lifting in the reader).
  - `EpubInfo.swift` — container.xml → OPF: dc:title, dc:creator,
    dc:language, manifest (id→href/media-type/properties), spine order, TOC
    (EPUB3 nav `properties="nav"` preferred, EPUB2 NCX fallback), cover via
    EPUB3 `properties="cover-image"` OR EPUB2 `<meta name="cover">`
    (Gutenberg uses the latter — verified). Returns hrefs resolved relative
    to the OPF/TOC file's directory.
  - Fixture `Fixtures/sample.epub` in the test target (committed, built with
    real zip bytes) + `ZipReaderTests` + `EpubInfoTests`.
- **CI `epub-spike` job** (mirrors kokoro-small-spike, `continue-on-error`):
  `Tests/EpubSpike` standalone SPM package; job downloads three VERIFIED
  Gutenberg books (`pg1342` Pride & Prejudice, `pg11` Alice, `pg84`
  Frankenstein from `https://www.gutenberg.org/cache/epub/<id>/pg<id>.epub`,
  all curl-checked 200 `application/epub+zip` 2026-09-06), asserts
  ZipReader/EpubInfo contract: entry list, title/creator, spine ≥ N, TOC
  labels, cover bytes > 10 KB. Marker lines `EPUB-SPIKE ...` for the grep.
- **Books model/store/UI**: `Models/Book.swift` (Codable manifest shape +
  `BookFormat` + `BookPosition`), `Services/BooksStore.swift`
  (`Documents/Books/<uuid>/`, import via security-scoped copy → background
  metadata parse → atomic manifest write; refresh scans manifests; delete
  removes the directory; position persistence; static `directorySize`).
  `Views/BooksView.swift` — library list (cover thumb, title, author, format
  glyph), empty state, `+` fileImporter `[UTType.epub, .pdf]`, per-book
  context menu (delete w/ confirmation), import progress/error states.
- **project.yml**: EPUB document type entry. (Version bump stays 1.4.1/28
  until the Phase-5 release commit.)
- Device test: tab shows Books; Storage content lives in Settings → Storage;
  import a Gutenberg epub → appears with cover/title/author; delete works;
  PDF imports with PDF metadata (title from PDFDocument attributes).

### Phase 2 — EPUB reader
- Vendor `epub.js` (+ JSZip) into `App/Resources/epubjs/` (pin a release,
  record source + license in the file headers and here).
- `Views/BookReaderView.swift`: chapter-paged scroll reader. `BookWebView`
  (`Views/BookWebView.swift`, UIViewRepresentable): WKURLSchemeHandler
  `bookscheme://<bookId>/` streams the epub file bytes; epub.js
  `ePub(url, {openAs: "epub"})` → `rendition.display(spineHref)` with
  `flow: "scrolled"`, `spread: "none"`. `rendition.on("relocated")` reports
  spine index + fraction → position persisted (debounced).
- Native TOC sidebar (epub.js `book.loaded.navigation` → JSON via
  `WKScriptMessageHandler`; falls back to `EpubInfo` TOC parsed natively at
  import — manifest already stores it). Aa sheet: font size ±, light/sepia/
  dark themes via `rendition.themes.override`; background color matched to
  the webview via `WKWebView.setBackgroundColor`-equivalent (CSS body).
- Chapter nav: prev/next buttons + swipe-at-end; chapter title in the nav
  bar; progress "Chapter X of Y · N%".
- Reader closes → `book.destroy()`; the WKWebView is created once per reader
  presentation and torn down with it (no app-lifetime webview yet).

### Phase 3 — TTS for books
- **SpeechPlayer (additive)**: `var onNaturalFinish: (() -> Void)?` — called
  in the existing natural-finish branch of `onStateChanged` (`.idle` with
  `lastRawProgress >= 0.98`) alongside `clearBookmark()`. `PlaybackBookmark`
  gains `var bookId: String?` (tolerant decode default nil) + bookmark save/
  match branches on it. `var bookChapterProvider: ((String, Int) -> (title:
  String, text: String)?)?` resolves book bookmarks for auto-resume.
- **BookPlaybackController** (`Services/`, new file): `play(book:chapter:)` →
  chapter text (cached `text/NNN.txt` → JS extraction → normalize) →
  `player.togglePlay(text, note: nil)` with book bookmark bookkeeping;
  `onNaturalFinish` → next chapter (stop at last chapter). Prefetch next
  chapter's text during playback. Chapters > 20k chars split at paragraph
  boundaries into parts; auto-advance walks parts transparently.
- Reader UI: existing `PlayerControlsBar` pinned under the webview (hidden
  while webview scroll... no — always visible, matching editor); read-along
  toggle swaps webview → existing `ReadAlongView` for the same chapter text
  (exact editor pattern). Mini-player + NowPlayingCenter + lock screen work
  unchanged; mini-player jump opens Books tab → reader at the playing book.
- Device test: play a whole multi-chapter book hands-off (auto-advance),
  resume mid-book after app kill, read-along tracks, lock-screen controls,
  airplane mode with Kokoro small.

### Phase 4 — PDF viewer + PDF TTS
- `Views/BookPDFReaderView.swift`: PDFKit `PDFView` (continuous, full
  fidelity), `PDFOutline` sidebar (recursive native List), page indicator,
  position = page index persisted. PDFView is Apple's own lazy engine —
  huge PDFs are its day job.
- TTS: 5-page groups as "chapters" — `page.string` per group into an NSCache
  (≈10 groups LRU), auto-advance between groups, bookmark = page + chars,
  read-along over group text. NEVER `PDFDocument.string` on a whole book
  (that's the note-import lag we're not reproducing).

### Phase 5 — polish + release v1.4.2
- Cover grid in the library (LazyVGrid, Apple-Books-style), search field,
  Books row already in Storage usage, README + HANDOVER addendum #6, bump
  all four version fields to 1.4.2 / 29, device-test checklist run, tag +
  GitHub Release with IPA after device confirmation.

## 3. Stability playbook (why big books won't crash/lag)

1. Import: one security-scoped file copy + 2–3 zip-entry reads, all off-main;
   manifest written atomically; UI shows per-book import state.
2. epub.js rendering memory lives in the OUT-OF-PROCESS WebContent process —
   a heavy book jetsams the web process, not our app (Plan B safety win).
3. One WKWebView per reader; `book.destroy()` on close; no
   `locations.generate()` at open (per-chapter fraction instead).
4. Speech units are chapters ≤ ~20k chars (split at paragraph boundaries);
   engines keep their generation-ahead caps; chunk retry + silence-skip
   (v1.4.1) keeps one flaky chunk from aborting a book.
5. PDF: PDFKit lazy engine + per-page-group text cache; never whole-doc
   extraction.
6. Launch path untouched: BooksStore scans manifests on tab open only.
7. Chapter speech text cached to disk (`text/NNN.txt`) — resume/replay never
   re-parses; the webview is not even opened for TTS once cached.

## 4. Risks / fallbacks

- epub.js scrolled-flow quirks → fallback: paginated flow (`flow:
  "paginated"`) with the same JS bridge, or per-chapter XHTML → markdown
  native rendering (ZipReader/EpubInfo already give us the spine; add
  XhtmlConverter then — sunk cost low).
- Real-world epub weirdness (malformed OPF, missing cover) → EpubInfo fields
  are optional; library falls back to filename; import never fails the copy,
  only downgrades metadata.
- Gutenberg URL drift → epub-spike URLs are content-addressed cache URLs;
  if they rot, the fixture-based unit tests still guard the parser.

## 5. Device test checklist (release gate)

1. Books tab appears; Storage content fully inside Settings → Storage.
2. Import pg1342.epub via Files/Open-In: cover, title, author correct.
3. Open: chapter renders, TOC sidebar lists chapters, Aa changes size/theme,
   prev/next chapters work, position survives close/reopen.
4. TTS: chapter plays with chosen engine; auto-advance to next chapter;
   resume mid-book snaps to sentence start; read-along highlights track.
5. Background playback + lock-screen controls while a book speaks.
6. PDF: opens pixel-perfect (images/zoom), outline sidebar, page-group TTS.
7. Regression: notes playback/bookmarks unaffected; mini-player behaves;
   Settings → Storage numbers sane; app cold-launch still fine in
   LiveContainer.
