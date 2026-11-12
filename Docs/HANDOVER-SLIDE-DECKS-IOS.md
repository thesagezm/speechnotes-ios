# HANDOVER — Slide decks on iOS (BookFormat.slides + SlideDeckKit read path)

Branch `batch-c-d-session`. Written 2026-11-12, mid-task: the **package side
is complete and locally verified**; the **app side is written but not yet
compile-verified** (no iOS toolchain on this box) and **CI has not run**.
The next agent picks up at "Verify the app target in CI" below.

> **UPDATE, same day, later:** the CI verification below HAPPENED and is
> green — run **43269262140** on `e23fce6`: ALL seven jobs success
> (Build unsigned IPA, Logic tests, all spikes; kokoro-small-spike needed
> two capacity-reruns, then passed). The app side IS compile-verified
> now. What CI proves is compilation; device behaviour
> (webview rendering, media fetch, speech on a real deck) is still
> unexercised. The sections below are kept as the record of how the app
> side was verified; the "first action" is DONE. The ODP question in
> "Known gaps" is DECIDED — see that section. Fresh state:
> PROGRESS_LOG.md top entry.

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

### SlideDeckKit (Packages/SpeechLogic/Sources/SlideDeckKit/) — DONE, 65 deck tests green

Local verification loop: **`/tmp/deckpkg/run.sh`** — rsyncs the target into a
scratch SwiftPM package and runs `swift test` in docker (`swift:6.0` image is
already pulled locally). All 65 deck tests pass there (Linux, Swift 6.0.3);
the scratch also carries a SpeechLogic shim (BookFormat.swift +
BookFormatManifestTests.swift, the exact repo files) so the manifest
round-trip runs in the loop too — 70 tests total. CI (macos-latest) runs
the same suite via `swift test` in Packages/SpeechLogic. (The original count
"66" included the since-removed `testZZDebugDump` print scaffolding and a
duplicated extension pair that CI round one caught — see below.)

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

### App (App/) — CI-VERIFIED (compiles; runtime on device still unexercised)

- **BookFormat now lives in the SpeechLogic package**
  (Sources/SpeechLogic/BookFormat.swift, public + Sendable) — it is the
  cross-platform manifest contract, moved so `BookFormatManifestTests`
  (Tests/SpeechLogicTests/) can pin it in CI: Linux-written `"pptx"`
  decodes to `.slides("pptx")`, iOS re-encodes it as `"pptx"`, unknown
  formats fail loudly. In the app it is no longer a raw-String enum:
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

## Verify the app target in CI (DONE — first action resolved)

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

**What actually happened (2026-11-12):** the predictions above were right
on class #2 only. The first full run (43265659195) failed Logic tests on
`DeckTests.swift` — a duplicated `littleBytes` extension pair pasted into
the repo file AFTER the last local docker run (the scratch loop never saw
it), plus the print-only `testZZDebugDump` scaffolding; both dropped. The
app side needed exactly two `import SlideDeckKit` lines (BooksStore,
BookPlaybackController — SpeechLogic does not re-export the module) and
the `Task { @MainActor }` bridge in BookSlidesView's coordinator
(`0e53a9d`). The PlaybackRail/BookPlayerBar/ReadAlongView shapes compiled
as written. Then `BookFormat` moved into SpeechLogic so the Linux
round-trip is CI-tested (`e23fce6`, BookFormatManifestTests, 5 tests) —
and the same run's Build unsigned IPA + Logic tests went green
(**43269262140**). Note the workflow has `cancel-in-progress: true`: one
push = one run; overlapping dispatches cancel the earlier run.

## Known gaps (documented degradations — say these, don't hide them)

- **ODP — DECIDED (2026-11-12): keep `"odp"` in `BookFormat.deckExtensions`;
  the NEXT MILESTONE is porting sn-doc/src/odp.rs into SlideDeckKit.** Not
  dropping ODP back to the EPUB path: (1) the user's rule is "the deck is
  shown as the deck, never converted" — dropping `odp` would route it back
  through `OdpParser` → `DocumentEpubConverter`, the exact flattening this
  round exists to stop; (2) Linux reads ODP as a deck (odp.rs feeds the
  same SlideDeck model), so an iOS-written `"epub"` manifest for an .odp
  would break the byte contract; (3) the interim failure is honest, not
  silent — the import stamps `importError` ("This ODP could not be opened
  as a slide deck"), the shelf explains it, the reader alerts. The port is
  well-scoped: 1,582 lines / 48 functions; per its own header Impress
  writes EXPLICIT geometry, so there is no placeholder→layout→master chain
  to chase — one-level automatic-style resolution landing in the same
  SlideDeck model, meaning DeckSlides/DeckHTML/the reader/speech need zero
  changes when it arrives. The existing SpeechLogic `OdpParser` (text +
  images as EPUB chapters, no geometry) stays for the normalize path.
  Until the port lands, a local .odp import copies the file whole but the
  manifest says "could not be opened as a slide deck".
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
  spine "slide-N" — byte-compatible with Linux, and the round-trip is now
  pinned by BookFormatManifestTests. An iOS device can't parse a Linux
  ODP deck (above — until the odp.rs port).
- **CI proves compilation only.** The deck reader's runtime behaviour on a
  device — webview rendering, `deck://media` fetch, speech on a real deck
  file, read-along swap — is unexercised; next device sync covers it.

## Reference map (for the next round of work)

- Rust truth: `/home/sagestation/code/speechnotes-linux-rust` —
  crates/sn-doc/src/slides.rs (1,662), crates/sn-ui/src/slideview/
  {document,script}.rs, crates/sn-doc/src/odp.rs (1,582).
- deckcraft @ a0eeb34 vendored at
  `/home/sagestation/.cargo/git/checkouts/deckcraft-80b967a9065386ec/a0eeb34`.
- The port's own progress notes: PROGRESS_LOG.md (M1 entry) + this file.
