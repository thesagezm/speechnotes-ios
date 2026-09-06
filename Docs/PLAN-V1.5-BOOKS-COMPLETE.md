# Speechnotes iOS — v1.5 PLAN: Books, complete (PDF TTS + full backlog)

> **WORK ORDER (2026-09-06).** Branch `v15-books-complete` (off main fbfb854,
> v1.4.2). Process rule set by the user after v1.4.2: **nothing ships half-done —
> every phase below is device-tested before the next, and the v1.5 release
> happens only after ALL of it passes.** Any item that genuinely can't land is
> an explicit user decision, never a silent backlog note.

Scope decisions (user-locked 2026-09-06):
- PDF chapters come from the PDF's own OUTLINE (bookmarks). No cop-outs.
- No-outline PDFs fall back to **font-size heading detection**, then labeled
  page ranges ("Pages 1–10") as the guaranteed floor.
- **Scanned PDFs speak**: Vision OCR fallback for text-less pages, cached.
- **Per-chapter WAV export** for books (bounded memory; never whole-book).
- **Column-aware extraction** for two-column PDFs (left→right per page),
  gated by a real 2-column fixture in CI.

Research base (2026-09-06): PDFOutline traversal via numberOfChildren/child(at:)
(this SDK has no `.children` — CI-caught before); PDFPage.string per-page is
cheap, whole-document string is a known freeze source (Apple forums) — extract
per page, cache, off-main, never `PDFDocument.string`; ligatures (ﬁ/ﬂ) need
NFKD normalization before chunking; heading detection by font size is proven
(SciPlore Xtract); column order fix = `PDFPage.selection(for: bounds:)` per
column rect (ISO 32000 defines no reading order); scanned PDFs → render page +
`VNRecognizeTextRequest`; OSS references: nedmah/TextLector (paragraph chunks +
background prefetch of the next chunk — the responsiveness lever),
answersolutionsapps/runandread-ios, Cocoanetics/SwiftText (line-geometry
extraction with y-positions).

## Core design — PDFs are structured documents

A PDF's outline tree IS its chapter list. Chapters resolve in this order:
outline → detected headings → page ranges. The chapter list persists in the
book manifest so the library, reader and TTS all agree without re-parsing.
Speech units stay chapter-shaped (≤ ~20k chars → chunker splits further);
page text is extracted lazily per page (PDFKit's own lazy engine), cached per
chapter to `text/NNNN.txt` exactly like EPUB, with a per-page UTF-16 offsets
sidecar (`text/NNNN.pages.json`) so read-along can auto-scroll the PDFView to
the sounding page.

## Hard rules (inherited)

1. Never push red. 2. New screens in NEW files. 3. SpeechPlayer changes
strictly additive. 4. Pure logic in Packages/SpeechLogic (public, tested on
macOS CI) — PDFKit compiles on both macOS 13 and iOS 18; write to the common
subset (numberOfChildren/child(at:), PDFPage.string/selection(for:)/bounds,
PDFDocument.index(for:)). 5. Version bumps touch all FOUR fields.
6. No whole-document `PDFDocument.string`, ever.

## Phases

### Phase 1 — `PdfText` in SpeechLogic + fixtures + pdf-spike CI
- `Packages/SpeechLogic/Sources/SpeechLogic/PdfText.swift`:
  - `public struct PdfChapter: Codable, Equatable { label, startPage, endPage }`
    (inclusive end page).
  - `chapters(fromOutlineOf:)` — top-level outline nodes → page ranges
    (monotonic fix-up, end = next start − 1, last ends at pageCount − 1;
    page-less parent nodes defer to their children); nil unless ≥ 2 usable.
  - `chapters(fromHeadingsIn:maxScanPages:)` — per-page line geometry via
    `selectionsByLine()` (text + bounds); modal body line-height; heading =
    line-height ≥ 1.25× modal AND short; chapter per heading; page budget
    (huge scanned docs fall through to page ranges rather than grinding).
  - `fallbackChapters(pageCount:groupSize:)` — "Pages 1–10" labels.
  - `resolveChapters(in:) -> ([PdfChapter], source: String)` — the only
    entry the app calls (source ∈ "outline"/"headings"/"pages").
  - `pageText(_:columns:)` — NFKD normalize + de-hyphenate; column-aware:
    detect gutters from line x-coordinates, extract per column via
    `page.selection(for: rect)`, conservative fallback to `page.string`.
  - `chapterText(in:chapters:index:)` — per-page loop, paragraph joins,
    returns text + `[(pageIndex, utf16Offset)]`.
  - `pageHasTextLayer(_:)` — OCR routing threshold.
- Fixtures committed (generator script kept in `Scripts/`): minimal real PDFs
  with outline / heading structure / two-column layout.
- `PdfTests.swift` in SpeechLogicTests.
- CI `pdf-spike` job (mirrors epub-spike: standalone `Tests/PdfSpike` package,
  real downloaded PDFs incl. a 2-column paper, continue-on-error, failure
  summary gated on the test step's real outcome).

### Phase 2 — Manifest + import + backfill + controller
- `Book` gains `pdfChapters: [PdfChapter]?` + `pdfChapterSource: String?`;
  written in `buildManifest`'s `.pdf` branch (off-main); library row shows
  "N chapters" for PDFs (BookRowView metaLine).
- `BooksStore.refresh()` → `backfillMissingPDFChapters()` (mirrors the cover
  backfill so already-imported books gain chapters).
- `BookPlaybackController`: format-neutral chapter iteration (epub = spine,
  pdf = pdfChapters); PDF `chapterText` = per-page extraction (session page
  NSCache + the existing `text/NNNN.txt` chapter cache) + Vision OCR for
  text-less pages (off-main, cached, `.accurate`); offsets sidecar written
  next to the chapter cache.
- Device test: previously imported PDF gains "N chapters"; new imports too.

### Phase 3 — PDF reader TTS UI
- `BookPDFReaderView`: `BookPlayerBar` + `miniPlayerSuppressed` (exact
  epub-reader pattern); play starts at the chapter containing the current
  page; outline rows get a play-from-here affordance.
- Read-along: swap to `ReadAlongView` while this book speaks (same as the
  epub reader); on sentence page change, `pdfView.go(to:)` (page-granular,
  from the offsets sidecar).
- Device test (the release gate): outlined PDF plays hands-off with
  auto-advance; resume snaps; read-along tracks + the page follows; 2-column
  paper reads in order; scanned PDF speaks via OCR; background + lock screen;
  airplane mode with Kokoro small.

### Phase 4 — Markdown read-along accuracy (user's device report: "less so")
- Speak entry points recompute the speech text synchronously (kills the
  300 ms `scheduleSpeechCacheUpdate` staleness window).
- `MarkdownText.plainText` speakability audit + tests: unresolved reference
  links speak the label only; no phantom chars (images/footnotes) in spoken
  offsets.
- Device test: markdown note with links/images/footnotes tracks accurately.

### Phase 5 — Library grid + search; mini-player book jump
- `BooksView`: LazyVGrid cover grid + search field (title/author).
- Mini-player tap for a playing book → Books tab AND push that book's reader
  at the playing chapter (new notification branch alongside the note jump).
- Device test: grid, search, correct jump.

### Phase 6 — Release 1.5.0/30 — only after every phase above passed on device
- Bump the four version fields, README + HANDOVER, full checklist, CI green,
  fast-forward main, tag v1.5.0, attach the IPA.

## Risks / fallbacks
- PDFKit macOS/iOS SDK drift → common-subset API only; CI compiles both.
- Heading detection quality varies → it is only the MIDDLE fallback; page
  ranges always guarantee navigable units.
- OCR cost on big scans → OCR only the chapter being played, cached forever
  after; `.accurate` measured in the spike.
- Column false positives → conservative gutter threshold, per-page fallback
  to default order (worst case = today's behavior).

## Device test checklist (release gate — Phase 6)
1. PDF with outline: library row + reader + TTS all agree on chapters.
2. PDF without outline: heading-detected chapters (or honest page ranges).
3. Two-column PDF reads left column then right column.
4. Scanned PDF speaks (OCR) and says which chapters are OCR-derived in logs.
5. Per-chapter WAV export shares a playable file.
6. EPUB regression: chapters/auto-advance/resume/read-along unchanged.
7. Markdown read-along accuracy confirmed on a rich note.
8. Grid + search + mini-player book jump behave; cold launch fine.
