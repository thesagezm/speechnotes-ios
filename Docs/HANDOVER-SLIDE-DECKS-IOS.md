# HANDOVER — Slide decks on iOS (BookFormat.slides + SlideDeckKit read path)

Branch `batch-c-d-session`. Written 2026-11-12, mid-task: the **package side
is complete and locally verified**; the **app side is written but not yet
compile-verified** (no iOS toolchain on this box) and **CI has not run**.
The next agent picks up at "Verify the app target in CI" below.

## What the user asked for

"the slides work you did has not worked - they are still being converted to
epub - fix this and make sure it works." A `.pptx` import produced an EPUB
(`BooksStore.importBook` → `DocumentBook.parse` → `DocumentEpubConverter`)
and opened in the epub webview. The SlideDeckKit commits `42254fe`…`416baac`
were only the deckcraft *foundation* (XML DOM, colours, preset geometry) —
`PROGRESS_LOG.md` said so explicitly ("Nothing from the app target touched
yet"). The fix: decks are a first-class book format, shown AS THE DECK, the
Linux reader's rule ("the deck is shown as the deck, never converted").

## What landed in this session

### SlideDeckKit (Packages/SpeechLogic/Sources/SlideDeckKit/) — DONE, 66 tests green

Local verification loop: **`/tmp/deckpkg/run.sh`** — rsyncs the target into a
scratch SwiftPM package and runs `swift test` in docker (`swift:6.0` image is
already pulled locally). All 66 tests pass there (Linux, Swift 6.0.3). CI
(macos-latest) runs the same suite via `swift test` in Packages/SpeechLogic.

New files (all ported from deckcraft @ a0eeb34 + speechnotes-linux-rust
sn-doc/src/slides.rs + sn-ui/src/slideview/{document,script}.rs):

- **Zip.swift** — own zip reader (central directory by hand, stored +
  deflate, CRC verified). The DEFLATE decoder is **pure Swift** (RFC 1951:
  stored / fixed / dynamic Huffman) because `import Compression` does not
  exist on Linux — this is what makes the local docker loop possible.
- **Ooxml.swift** — OPC package: parts, per-part rels, content types,
  target resolution (`resolve`, `relsPath`, percent-decoding).
- **DeckTypes.swift** — the READ model (deckcraft-model subset): ColorRef/
  Fill/Line/Effects, BodyProps/ParaProps/RunProps/ListStyle, PhType/
  Shape/Geom/Table, Theme/Master/Layout/**PptxSlide**/Presentation.
  NOTE the names `PptxSlide` and `BulletSpec` — the resolved model owns
  `Slide` and `Bullet` (same-module collision with the Rust crates' two
  same-named types).
- **DmlRead.swift** — DrawingML element reading (read/dml.rs + the table
  half of read/shapes.rs) + `ReadCtx` (media allocation) + `PartInfo`.
- **PptxRead.swift** — package → Presentation: presentation.xml (sldSz,
  slide order via rels, defaultTextStyle), theme, masters + layouts
  (layoutByPart → per-slide master/layout indices), slides' shape trees,
  notes text, header/footer survey, placeholder-geometry and text-anchor
  post-passes.
- **DeckResolve.swift** — the inheritance chain (resolve.rs port): Ctx,
  placeholder matching (findPh/compatible/masterPh), xfrm/fill/line/
  effects/body/levelStyle/run/para, font family, background.
- **DeckSlides.swift** — resolution to the viewer model (slides.rs port):
  buildShapeAtXfrm (groups flattened via affines), textItem, tableItem,
  place/compose/xfrmAffine/childInSpace, presetRadius, shapeSVG (uses the
  ported preset geometry), fillCSS/gradientCSS/borderCSS/shadowCSS,
  assembleText (speakable text + byte spans).
- **DeckHTML.swift** — the whole deck as one HTML document (document.rs
  port) + DECK_CSS + the slide script (`__snslides`: show/step/current/
  setFit/highlight, `slidechanged:` and `chromeTap` posts). Media URLs are
  `deck://media/<index>/<name>`; `DeckParser.parse(bytes)` is the entry.
- Tests: **Tests/SlideDeckKitTests/DeckTests.swift** — an in-memory pptx
  built byte-by-byte (stored zip + a hand-encoded fixed-Huffman DEFLATE
  entry) pinning: slide order/size/metadata, master-box inheritance through
  layout, style-ref fills via phClr, dashed borders, SVG bodies, picture
  media, tables with gridSpan, blank-paragraph end marks, connectors,
  speakable text + spans (incl. notes tail), and the HTML output.

### App (App/) — WRITTEN, NOT YET CI-VERIFIED

- **Book.swift** — `BookFormat` is no longer a raw-String enum:
  `case epub / pdf / audio / slides(String)`. Custom Codable: decodes
  "pptx"/"ppsx"/"potx"/"odp" → `.slides(ext)` (so Linux-written manifests
  open), encodes `.slides` as the extension (so iOS-written deck manifests
  open on Linux — `is_slides()` matches). `fileExtension`, `isSlides`,
  `deckLabel(forExtension:)` helpers. docKindLabel now answers decks.
- **BooksStore.swift** — `importBook` routes
  `BookFormat.deckExtensions` (pptx/ppsx/potx/odp) to `.slides(ext)`:
  the file is COPIED WHOLE (`original.pptx`), no EPUB conversion.
  `buildSlidesManifest` parses the deck once (SlideDeckKit) for slide
  count, per-slide TOC, deck title/author; spine entries `slide-0…` and
  toc rows `slide-1…` are byte-compatible with the Linux app's
  `import_slides`. `originalFileURL` uses `format.fileExtension`.
  Backfill grew a `.slides` case (cover tile synthesis).
- **BookPlaybackController.swift** — `chapterCount` + `chapterText`
  case `.slides`: one slide = one chapter; the deck is parsed off-main and
  `DeckSlides.slideText(deck, index)` is what the voice reads (shape text
  in z-order, then speaker notes); result flows through the existing
  speech-text cache/sanitizer.
- **BookSlidesView.swift** (new) — the deck reader: WKWebView + the
  deck HTML; `DeckMediaSchemeHandler` serves `deck://media/N`; script
  messages (`slidechanged`, `chromeTap`); slide stepper bar + TOC sheet +
  position persistence (`store.updatePosition`, only on real changes) +
  read-along swap (`ReadAlongView`) + BookPlayerBar / PlaybackRail chrome —
  all copied from the EPUB reader's established patterns.
- **Switch coverage** — every exhaustive switch over BookFormat gained a
  `.slides` case: BooksView (reader dispatch + shelf meta), BookRowView
  (meta + glyph "rectangle.on.rectangle"), ReadingGoalsView (fraction +
  unitLabel), BookPlaybackController (×2), BooksStore (backfill +
  buildManifest). BooksRecycleBinView prints authorOrFormat now;
  BookDropSendView uses format.fileExtension.
- **project.yml** — the app target additionally links the `SlideDeckKit`
  product (decks are app-level now).

## Verify the app target in CI (FIRST ACTION)

1. `git add -A && git commit -m "Slide decks: SlideDeckKit read path + BookFormat.slides (deck kept whole, no EPUB conversion)" && git push`
2. CI does NOT auto-run on this branch — dispatch it:
   `gh workflow run build.yml --ref batch-c-d-session` then
   `gh run watch` / `gh run view <id> --log-failed`.
3. Expect these failure classes on the first round (written blind — the app
   target cannot compile on Linux):
   - `PlaybackRail.Action` / `BookPlayerBar` argument mismatches: copy the
     exact call shape from BookReaderView.swift:188-228 / 492-524.
   - Actor-isolation complaints from the WKScriptMessageHandler callback
     into view methods: BookWebView's coordinator does the same thing —
     mirror however it bridges (Task { @MainActor in ... }).
   - `ScreenAwakeSurface` / `StatsRecorder` spelling — copied verbatim from
     BookReaderView, should be fine.
4. Fix rounds until green; the package side is already green, so any
   logic-test failure is a real regression in the new code, not noise.

## Known gaps (documented degradations — say these, don't hide them)

- **ODP imports still normalize to EPUB on the IMPORT side** only in the
  sense that `odp` is in `BookFormat.deckExtensions` — so a local .odp
  import COPIES the file but `DeckParser.parse` throws `notADeck` (the ODF
  reader was not ported; deckcraft's Linux app reads ODP in sn-doc/src/
  odp.rs, 1,582 lines). An ODP deck book shows "could not be opened as a
  slide deck". The follow-up is porting odp.rs into SlideDeckKit (it is
  self-contained; its resolution shares DeckSlides' model). Alternative
  interim: drop "odp" from `BookFormat.deckExtensions` so odp stays on the
  old EPUB path until the ODF reader lands — pick whichever the user
  prefers, but SAY which.
- Charts/SmartArt render as labelled frames (the reference's chart SVG and
  diagram outlines are the follow-up); legacy `.ppt` (CFB) is refused —
  it is NOT in deckExtensions, so it stays on the old path.
- Placeholder geometry inheritance for SVG shapes is simplified: a
  placeholder that names no geometry gets the rect default rather than the
  reference's layout/master geometry lookup (DeckSlides/shapeSVG only
  consults the shape's own preset). Text and box positions DO inherit
  fully. Custom geometry (custGeom) draws as its box.
- The deck reader has no zoom stepper / present mode yet (fit=page);
  the Linux reader's presenter window and fit cycling are the follow-up.
- BookDrop: a deck manifest written by iOS says format "pptx"/"odp" and
  spine "slide-N" — byte-compatible with Linux. An iOS device can't parse
  a Linux ODP deck (above).

## Reference map (for the next round of work)

- Rust truth: `/home/sagestation/code/speechnotes-linux-rust` —
  crates/sn-doc/src/slides.rs (1,662), crates/sn-ui/src/slideview/
  {document,script}.rs, crates/sn-doc/src/odp.rs (1,582).
- deckcraft @ a0eeb34 vendored at
  `/home/sagestation/.cargo/git/checkouts/deckcraft-80b967a9065386ec/a0eeb34`.
- The port's own progress notes: PROGRESS_LOG.md (M1 entry) + this file.
