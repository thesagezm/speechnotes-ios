# HANDOVER — books UI transparency + wide tables, 2026-10-26

**Branch `batch-c-d-session`.** One commit carries BOTH this round's books UI
work AND the BookDrop fixes round (the user asked for everything to be
committed together). CI: dispatched on this branch after the commit — check
`gh run list --workflow build.yml --branch batch-c-d-session --limit 1`
before trusting the code. Version untouched (1.8.0 / 45) per policy.

Supersedes `Docs/HANDOVER-SCREEN-ON-POMODORO-AND-BOOKS-UI.md` (its section 2
— the books UI round — is what this round built; sections 1/3 remain useful).

---

# 1. Books UI: the readers show the book behind the tab bar and hidden chrome

The user's five requirements, verbatim-condensed: (1) don't touch the
landscape rail AT ALL; (2–3) in portrait the solid fill behind the tab bar
must show the book to the very bottom of the screen; (4) content keeps a
readable safety margin at the end of the page/chapter — the fill is only
"behind" content, never over it; (5) in landscape the same fill is removed,
rail untouched.

## The mechanism (one idea, both readers)

The slab behind the tab bar was never a control — it was the reader NOT
painting anything there. The fix: only the reader's PAGE COLOUR bleeds into
the safe areas (`.background(pageColor.ignoresSafeArea(...))`), while the
CONTENT's frame and scroll insets are untouched — so the fill behind the tab
bar / status bar is the book's own page, and a chapter always ends with its
last lines resting READABLE above the chrome (requirement 4 is native
behaviour, not something we built).

`edges:` is `immersiveBarsHidden ? .all : .bottom` — when the chrome is
hidden (tap-to-immersive) the colour also runs under the status bar: "just
the book all to the very top, the way notes does". That is 2b, done for BOTH
the EPUB and the PDF reader with the same one modifier.

## EPUB (`BookReaderView.swift` + `App/Resources/epubjs/reader.js`)

- **Portrait controls now FLOAT** (the note editor's exact mechanism): the
  portrait branch swapped `VStack { surface; [chapterBar]; playerBar }` for
  `readerSurface.safeAreaInset(edge: .bottom) { [chapterBar]; playerBar }`.
  Chapter text runs behind the minimised pill; scrolling carries it under
  the chrome; the end of the chapter still rests above it. `pageColor` is a
  NEW computed property matching reader.js THEMES exactly (sepia #f6efe2,
  dark #121212, trueBlack #000000, light #ffffff) — deliberately NOT
  `veilColor`, whose dark case is `.black` and would sit against the page
  as a near-match.
- **Paginated flow got the matching inset in reader.js**: `applyPadding`
  now sets `#viewer` height to `calc(100% - env(safe-area-inset-bottom))`
  for paginated flow (columns are measured off the container, so padding
  would break the column math; the height calc doesn't). `env()` reflects
  the webview's safe-area insets (viewport-fit=cover is already set),
  which include the chrome it runs behind — so a page's last lines stay
  clear of the floating pill. Scrolled flow needs nothing: native
  scrolling insets itself.
- **Landscape**: the HStack with the rail is UNTOUCHED; only the shared
  `.background` bleed was added at the ZStack level. The rail keeps its
  exact column, card and centering.

## PDF (`BookPDFReaderView.swift`)

- The same bleed (`pdfCanvasColor` = `.systemBackground`, now PINNED on the
  PDFView itself in `BookPDFView.makeUIView` so canvas and bleed are one
  tone, not two near-matches).
- **The chrome KEEPS reserving its window** (no floating): PDF pages are
  fixed geometry — a floating pill would park itself over the page's
  bottom lines with no way for PDFView to inset its content. The user's
  requirement for PDF was the fill behind the tab bar, which the bleed
  delivers; the reserve keeps requirement 4 honest.
- Landscape rail: untouched, same as EPUB.

## Audiobook (`BookAudioReaderView.swift` — deliberately NO change)

The audiobook reader has no scroll content to reveal and no explicit
background — the system background behind its tab bar IS the reader's
background, so there is no slab to remove. "To a certain degree" is
satisfied by nothing-to-fix; touching its Spacers/cover centering would
move controls the user did not ask to move. If the user wants the cover
centered in the full screen height, that is a separate, explicit ask.

# 2. Wide EPUB tables pan to the lateral end

Converted books (Calibre & friends) carry many-column tables with no width
discipline; epub.js rendered them clipped at the page edge. In reader.js:

- `injectTablePanning(view)` runs on every `rendered` section (same hook as
  `attachGestures`) and injects per-section CSS: `table { display: block;
  width: fit-content; max-width: 100%; overflow-x: auto }` with `!important`
  (converted books' CSS out-specifies a bare selector; this is a usability
  fix, not typography — a table that FITS renders exactly as the book
  styled it, `fit-content` keeps narrow tables shrink-wrapped instead of
  stretched). Nested tables get a reset rule back to `display: table` —
  the block treatment would stack their cells vertically.
- `touchStartsOnTable` + a `touch.onTable` flag: a paginated-flow swipe
  that starts on a table pans the TABLE and no longer also turns the page.
- **Verified in a desktop browser against the real served reader.js** (the
  function source was extracted from the IIFE and run against the real test
  chapter in an iframe): wide 12-column table pannable and `scrollLeft`
  reaches the true lateral end; narrow table shrink-wrapped (89 px in a
  385 px viewport); nested table keeps native display; the gesture guard
  passes for cell targets and rejects paragraph/document targets. Fixture
  recipe: synthetic EPUB (mimetype stored first) + `python3 -m http.server`
  + the shell with `?bookPath=…&flow=scrolled`. NOTE: epub.js `display()`
  hangs in that desktop environment EVEN WITH the unmodified reader.js from
  HEAD — it is an environment quirk, not a regression; on device the
  WKWebView pipeline is the proven one. Device check still required.

# 3. BookDrop round integrated in the same commit

`Docs/HANDOVER-bookdrop-2026-10-26.md` (the BookDrop agent's own handover)
describes the five files: the LocalSendHTTPServer port-churn state machine,
the receiver's `desiredOn` guard + launch-OFF default, the sender's
`needsAccessCode`, the BookDropSendView 401 recovery, and a SpeechnotesApp
comment. That work was uncommitted in the tree when this round started; the
user asked for everything to be committed together, so it ships in this
commit. Its device checks (port stays 53317 across toggles; launch OFF;
access-code retry) are pending and listed in its own handover.
`Packages/SpeechLogic/Package.resolved` (pins swift-cmark 0.7.0, generated
by the Linux test runs) is checked in for reproducible Linux tests.

# 4. Device checklist (this round)

1. **EPUB portrait, minimized**: open a book, minimize the transport — the
   text runs behind the pill, and the book's page colour (sepia/dark!) fills
   the area behind the tab bar to the very bottom of the screen. Scroll to
   the chapter end: the last lines rest ABOVE the pill + tab bar, readable.
2. **EPUB portrait, expanded**: the chapter bar + player bar float over the
   book; scrolling carries text under them; chapter end rests readable.
3. **EPUB paginated flow** (Appearance → flow): last line of each page must
   not hide under the pill/tab bar (the `calc(100% - env(...))` container).
4. **EPUB immersive** (tap to hide chrome): the page colour reaches the very
   top under the status bar; no smaller fixed bar at the top in portrait.
   Landscape unchanged.
5. **PDF portrait**: fill behind the tab bar is the PDF canvas colour to the
   bottom; page bottom stays readable above the chrome; tap-to-hide carries
   the canvas colour under the status bar.
6. **Landscape (both readers)**: the lateral rail is pixel-identical to
   before; the book's colour shows behind the tab bar.
7. **Audiobook reader**: unchanged (expected — nothing to fix there).
8. **Wide tables**: open a converted book with a many-column table; pan it
   laterally to the last column; in paginated flow confirm a swipe on the
   table pans the table instead of turning the page.

# 5. Known risk + designed fallback

The EPUB floating-controls path relies on the WKWebView's internal scroll
view receiving SwiftUI's safe-area expansion (the same mechanism the note
editor's UITextView uses, which is proven on device). If the device check 1
shows chapter ends parking BEHIND the pill instead of above it, the fallback
is designed and small: push the exact bottom chrome height into the shell
(`window.readerInsets(bottomPx)` via evaluateJavaScript, called on
layout/minimize changes) and apply it as CSS `padding-bottom` on the shell
body — deterministic, no reliance on safe-area propagation.

# 6. Working notes

- No local Swift toolchain: verify via `gh workflow run build.yml --ref
  batch-c-d-session` + `Scripts/watch_ci.sh <sha>`; `logic-tests` is the
  fast signal.
- Version policy: MARKETING_VERSION stays 1.8.0; no tag/release without the
  user's explicit go.
- Release gate for v1.8: the TTS device checks (583acdb) + the BookDrop
  device checks + this round's device checks + the user's device round.
