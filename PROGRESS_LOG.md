# PROGRESS LOG — SpeechNotes Upgrade Cycle

Format: newest first. Every critique round, merge, and escalation lands here.

---

**CI: GREEN — run `45179341329` on `2cd80dd`, all 8 jobs success — the IPA artifact is up** (branch `batch-c-d-session`, 2026-11-23): the device-test build for the round; **no release/tag, per the ask**. The **SpeechnotesIOS** IPA artifact (23.1 MB, unsigned) + dSYMs uploaded; the IPA is at `dist/SpeechnotesIOS.ipa` locally, and its `Info.plist` carries **1.8.3 / 49** (`com.speechnotes.ios`, minimum iOS 18.0).
- **The run before it failed on ONE line, and it was in the new code.** Run `45176920893` got all the way through the `UIEditMenuInteraction` rewrite — the delegate signatures, `UIEditMenuConfiguration` and `presentEditMenu(with:)` all compiled — and stopped at `BookWebView.swift:649`: `cannot use optional chaining on non-optional value of type 'String'`. The suggested-actions filter used `$0.title?.`, but `UIMenuElement.title` is **nonnull** (a plain `String`; it is `UIMenu`'s own title that is the nullable one). Fixed in `2cd80dd`. The lesson is the same one this round keeps teaching: the parse check on this box catches SYNTAX, and only CI can type-check — every SDK-shape question gets settled by reading the SDK header, not by guessing.

**CI: the first v1.8.3 device build did not compile — four root causes, all fixed** (branch `batch-c-d-session`, 2026-11-23; commit `ca2c5f1`):
- **What failed.** CI run `45155943764` on `0b756eb`: **seven of eight jobs GREEN** — the logic tests (the full SpeechLogic suite on macOS), the EPUB and PDF spikes, and the four engine spikes (Kokoro, Nano Edge, Phonon, Supertonic) — and the **"Build unsigned IPA" job FAILED** at its "Archive (unsigned, generic iOS device)" step. The app target did not compile, so the IPA packaging, the version verify and the artifact upload were skipped. Six errors, **four root causes** (two of the six were cascades of a root cause). The runner is Xcode 26.6 / iPhoneOS 26.5, so these are modern-SDK differences the Linux box cannot see — CI is the only app-target build gate, and it earns its keep here.
- **Root cause 1 — the menu API that does not exist.** `BookWebView.swift`: `value of type 'UIContextMenuInteraction' has no member 'presentMenu'`. The API that presents a menu AT a point of the caller's choosing is `UIEditMenuInteraction` (iOS 16+), and it presents through a **configuration**, not a bare point: `UIEditMenuConfiguration(identifier:sourcePoint:)` + `presentEditMenu(with:)`, with the menu answered by `editMenuInteraction(_:menuFor:suggestedActions:)` and its position by `editMenuInteraction(_:targetRectFor:)`. The shape was read from the **iPhoneOS 26.5 SDK header itself** (`UIEditMenuInteraction.h`) and cross-checked against three shipping implementations (nextcloud/ios, Runestone, conduit) — the iOS 16 header and the iOS 26 header agree on this API, so it is not a beta-era spelling that changed. The whole context-menu delegate is gone: `UIContextMenuInteraction` cannot present a menu programmatically at all, and the old `UIMenuController` is the process-wide list that broke Copy in the notes (see `MarkdownEditorView`).
  - **Why the interaction sits on an ANCHOR.** An interaction attached to the webview would also answer the user's own long presses — and a long press on a LINK must reach WebKit, whose link menu has to survive. So the interaction lives on a clear view that does not intercept touches, pinned to the webview with constraints (the webview is born with a ZERO frame, so an autoresizing mask from zero stays zero). On that anchor the interaction can only ever appear because WE present it, which is exactly the one case the reader asks for. The selection's own rect rides along (the page reports `x/y/w/h`) so the menu's arrow lands on the selected passage, and the stale selection is cleared when the menu is dismissed.
- **Root cause 2 — `BookFormat` lives in the wrong package.** `DeckThumbnailRenderer.swift`: `cannot find type 'BookFormat' in scope`. The enum is in **SpeechLogic** (`BookFormat.swift`), not SlideDeckKit — the file imported SlideDeckKit (for `DeckHTML`/`DeckParser`) and never SpeechLogic. The import is added. The `BooksStore.swift:1068` `cannot infer contextual base in reference to member 'atomic'` was the **cascade**: with the renderer's signature unresolved, `format` had no type, so `.atomic` had nothing to infer from.
- **Root cause 3 — `\.accentColor` is not public API any more.** `MarkdownPreviewView.swift`: `'accentColor' is inaccessible due to 'package' protection level`. In the iOS 26 SDK `SwiftUI.EnvironmentValues.accentColor` is **package-level** — readable inside the SDK, not from an app target. The preview drops the `@Environment(\.accentColor)` and reads `theme.accentColor` instead: the same value the root view sets with `.accentColor(theme.accentColor)`. The `MarkdownPreviewView.swift:238` `cannot convert value of type '(Color?) -> some View'` was the cascade.
- **Root cause 4 — the font call that does not exist.** `MarkdownProseTextView.swift`: `extra argument 'design' in call`. `UIFont.systemFont(ofSize:design:)` is not an API; the serif face is asked for BY NAME through the descriptor (`fontDescriptor.withDesign(.serif)`), which is the one call that works on every SDK this app targets.
- **Verification before the re-dispatch.** The package suite in the docker scratch container: **106 tests, 0 failures** (including the new `SelectionOffsetMapperTests` (14) and `ReaderModeExtractionTests` (12)). Every changed Swift file parse-checks clean (`/tmp/parsecheck.sh`) — syntax only; the app target still cannot be compiled on this box (no Swift/Xcode toolchain, and UIKit does not exist on Linux), so CI remains the only real build gate. The page-side JavaScript harness: 14/14. `Scripts/version-check.sh`: 1.8.3 / 49 OK.
- **Still open for the device:** the native menus themselves, the preview's UIKit-redrawn prose, the offscreen `WKWebView.takeSnapshot` on a windowless webview (fallback if empty: host it in an offscreen `UIWindow`), and the webview selection inside the epub/foliate IFRAMEs (including the cross-origin frame-offset postMessage handshake).

**The copy/selection round, read-from-here, real deck thumbnails, reader-mode imports** (branch `batch-c-d-session`, 2026-11-23; committed as `74445ca` + `0b756eb` — 20 code files, plus this entry, the README and `Docs/READER-MODE-EXTENSION-NOTES.md`):
- **What shipped.** Five things, one round. (1) **Copy is back in the notes** — the v1.8.2 regression that killed it is gone, and "Play from caret" / "Play from selection" ride the editor's OWN native menu instead of replacing it. (2) **"Read from here"** on three surfaces: the editor's selection menu, the notes preview's prose, and the book reader's webview selection. (3) **Decks show their FIRST SLIDE on the shelf** — the real first slide, rasterized offscreen, not the generic "SLIDES" tile. (4) **Web imports strip the chrome and prefer a real `<article>`** — and a walled page's teaser no longer beats an equally long bypass result. (5) The preview's double-tap-to-edit is gone (it collided with double-tap-to-select-a-word); the pencil button still switches to edit mode.
- **The Copy regression, and why the fix is not "add the items back".** v1.8.2 registered "Play from selection" by ASSIGNING `UIMenuController.shared.menuItems`. The legacy contract is "your list IS the menu", not "your list is ADDED to the menu" — so the assignment replaced the built-in edit menu for EVERY text view in the app: Cut/Copy/Paste/Select All vanished from the notes editor AND from the SwiftUI preview's selectable prose, while Books (a WKWebView with WebKit's own edit menu) was untouched. The fix is the modern iOS 16+ hook: `textView(_:editMenuForTextIn:suggestedActions:)` APPENDS a `UIAction` to the system's suggested actions and returns a `UIMenu` built from them, so the built-in items always survive and the custom one can never replace them. The `EditorTextView` subclass is deleted; the coordinator holds the CURRENT view (`var parent`, refreshed in `updateUIView`) because the menu's availability depends on live SwiftUI state UIKit cannot see.
- **The menu's OWN range is the truth.** The old code asked the editor for the last REPORTED selection. The loupe can move the selection after that report — the user drags the handles, the reported range is stale, and "play from selection" started from the wrong word. The iOS 16+ hook hands over the MENU'S OWN range, and that range's `location` is what every caller maps (`canPlayFromSelection: (Int) -> Bool`, `onPlayFromSelection: (Int) -> Void`, `playFromCaretOffset(at:)` in `NoteEditorView`).
- **"Play from caret" is ALWAYS in the ⋯ menu.** It used to be conditional — it appeared only after the user had tapped into the text AND the caret sat past the first character — which reads as "the option is missing" (the 2026-11-23 device report). It is now permanently visible and explains itself when it is greyed out: "tap into the note first" / "stop playback first" / "the caret is at the top" / "add a little more text first". A permanently visible entry that explains itself is discoverable; an entry that appears and disappears is not.
- **"Read from here" — three surfaces, one mapper.** The surfaces and the ENGINE do not read the same bytes: the web reader hands over the DOM's own block text (soft-wrapped lines, tabs, entities already decoded), the note preview hands over text built from the markdown AST, and the engine reads the chapter's EXTRACTED — and sanitised — text. `SelectionOffsetMapper` (new, in the package, 14 tests) normalises whitespace on both sides while recording where every normalised character came from, finds the block inside the speech text and adds the intra-block offset, then maps the result back onto the original speech offset. Whitespace is the only difference it bridges safely — it never reorders, drops or rewrites a word. When the block cannot be located, the SELECTED passage alone is the fallback.
  - **The book reader** (`BookWebView`): a new `snsel` script-message channel carries the selection out of the page. The script is injected `.atDocumentEnd` for `forMainFrameOnly: false`, because the epub.js and foliate readers render the book inside an IFRAME and a top-frame-only script would never see the selection. It reports the selected text, the containing block's text, the selection's UTF-16 offset in that block, and the rect. WebKit's own callout is suppressed ONLY for a live text selection and NEVER for a link (the link menu must survive), so the native menu has to carry Copy itself — it is a `UIContextMenuInteraction` (`presentMenu(at:)`), NOT the process-wide `UIMenuController` that broke Copy in the notes. The rect crosses from the page's viewport into the webview's space through `contentOffset + adjustedContentInset` and `scrollView.convert(_:to:)`. An IFRAME asks its parent for its own offset by `postMessage` (the frame is cross-origin and cannot reach the parent's DOM; the parent CAN see the iframe element and answers with its rect). `BookReaderView.readFromHere` then maps the selection onto the chapter's speech text (`BookPlaybackController.chapterText` is no longer private) and calls `player.playFrom(text, at:, book:)`.
  - **The notes preview — OPTION A: the prose moved to `UITextView`s.** SwiftUI's `.textSelection(.enabled)` gives the reader Copy and nothing else — there is NO hook for adding a menu item to a SwiftUI selection, so "Read from here" was impossible on the preview without giving up the preview. A `UITextView` has exactly the hook the editor uses, so the preview's HEADINGS, PARAGRAPHS and LIST ITEMS are now drawn by native text views (one per contiguous prose group, built from the SAME `MarkdownText` AST spans, so the emphasis on screen is the emphasis the AST resolved — never a second regex pass over the markdown). **The tradeoffs, stated plainly:** (a) the preview's exact look may shift slightly — UIKit re-draws the headings, paragraphs and lists, and the metrics are matched to the SwiftUI ones by hand (`MarkdownProseStyle`), not by construction; (b) quotes, code blocks, tables, images, dividers and maths blocks STAY on the SwiftUI path — a quote keeps its vertical rule (a text view has no paragraph border), a table cannot be laid out by a text view, and a paragraph carrying an INLINE IMAGE stays SwiftUI because the picture is a SwiftUI view. Those surfaces keep Copy but do NOT offer "Read from here"; (c) the grouping keeps the view count bounded — a two-hundred-paragraph note is two hundred paragraphs in ONE text view, not two hundred views.
  - **The editor**: "Play from selection" now means "play from HERE", using the same mapping discipline (the menu's own offset, not the reported one).
- **Deck thumbnails: the shelf shows the deck's OWN first slide.** A deck ships no cover image, so every deck on the shelf wore the same synthesized "SLIDES" tile. The deck is ALREADY rendered by a WKWebView in the reader, so the same document can be rasterized offscreen: `DeckHTML.slidePreviewHTML(deck, index:, zoom:)` (new, public, one slide, the same CSS, no fit script, an opaque white page) is loaded into an offscreen `WKWebView` that serves the deck's own `deck://media` URLs through the SAME scheme handler the reader uses (the handler moved out of `BookSlidesView` into `DeckThumbnailRenderer` so the two cannot drift), waits for the load and for the slide's pictures, and takes a `WKSnapshotConfiguration` snapshot at 480 points, flattened onto white and JPEG-encoded. The parse runs off the main actor; the webview work runs on it. The import path renders it (the tile is only the fallback), and the launch backfill re-looks cover-less decks — the old filter had NO `.slides` clause at all, so no deck was ever re-looked. A marker file (`cover.kind`: "slide" / "failed") keeps the backfill bounded: a deck that rendered once is never parsed again, and a deck that FAILED to rasterize is not retried on every launch.
- **Reader-mode imports.** New `ReaderModeExtraction` (package) holds the plan: the chrome pre-strip selector list (nav/footer/sidebar/menu/form controls — NOT `img`, NOT `aside`), the article-root preference order (`article`, `main`, `[role="main"]`, `.post-content`, …) and `minArticleChars = 400`. The page-side script reads the lists from `ReaderModeExtraction.selectorsJSON`, so the Swift module and the injected JavaScript CANNOT drift. Two changes in the extraction: the chrome comes off the CLONE before Readability scores the page (a sticky header or a "related articles" rail must not be able to out-score the story), and an ARTICLE FAST PATH takes over when the page carries an article root with real text — returning markdown only, because the DOM's `textContent` runs the paragraphs together ("onetwo") while the markdown walker keeps the block structure; the plain text is derived on the Swift side with `MarkdownText.plainText`. The fast path has a FLOOR (400 characters) and a fallback: a stub `<article>` must not win over the story, and a page with no article root still goes through the scoring path exactly as before. `PaywallHeuristics.bypassWins(bypassedLength:directLength:directPaywalled:)` decides which pass wins, and the rule now includes the case the old comparison missed: a DIRECT result the heuristics flagged as a WALL is a teaser, so an equally long BYPASS result beats it. The research write-up (what was studied in `kushagrasinghx/reader-mode-extension` @ `d6b677f`, what was folded in, what was deliberately left behind — including the repo's 15-line STUB `readability.js`, whose real algorithm lives in `contentScript.js`) is `Docs/READER-MODE-EXTENSION-NOTES.md`.
- **Verification without an iOS build.** The package suite runs in the docker scratch container (`/tmp/slcheck.sh`): **106 tests, 0 failures** — including the new `SelectionOffsetMapperTests` (14) and `ReaderModeExtractionTests` (12), the new `PaywallHeuristicsTests` cases and `DeckTests.testSlidePreviewHTMLIsOneSlideAtTheRequestedZoom`. Every changed/added Swift file parse-checks clean (`/tmp/parsecheck.sh`, 19 files) — syntax only; the app target still cannot be compiled on this box (no Swift/Xcode toolchain, and UIKit does not exist on Linux), so CI remains the only real build gate. The page-side JavaScript is tested by a mock-DOM harness (`Scripts/test-reader-mode-extraction.js`, 14/14) that EXTRACTS the extraction JS out of the Swift string literal — one source of truth, tested on both sides — and the selection script passes `node --check`. The final self-review re-read every changed app file for TYPE-level mistakes the parse check cannot catch; it found and fixed: the prose text view's text container still TRACKED the view's own width (so the height measured for a stale width could clip the last line — the container is now sized explicitly), the selection message captured a non-Sendable `WKScriptMessage` across the main-actor hop (now a Sendable payload), and the deck preview's payload crossed the detached parse without a Sendable conformance.
- **Version 1.8.2/48 → 1.8.3/49** (`project.yml`, the guarded four-field pair — `Scripts/version-check.sh` is the CI gate and reads "1.8.3 / 49 OK").
- **Device round (open):** (1) long-press a passage in the notes EDITOR — the menu must show Cut/Copy/Paste AND "Play from selection", and tapping the item must start from the SELECTED word (move the loupe first, then check); (2) the ⋯ menu's "Play from caret" must be VISIBLE in every state, greyed out with its reason when it cannot run; (3) the notes PREVIEW — long-press a paragraph → Copy AND "Read from here"; the read must start at the selected word; a quote/code/table must still offer Copy but not "Read from here"; the preview's look may differ slightly from before (UIKit draws the prose now) — report anything that reads broken; (4) in a BOOK (epub and foliate document), long-press a paragraph → the native menu with "Read from here" + Copy, and the read must start there; long-press a LINK → the LINK menu must survive (it must not be replaced); (5) import a PPTX — its shelf tile must be the FIRST SLIDE, not the "SLIDES" badge; (6) import a web article — the note must carry the article's body without the nav/footer, the title must not be printed twice, and a PAYWALLED page must import the full story rather than the teaser; (7) double-tap in the preview must SELECT a word (it used to switch to edit mode) and the pencil button must still switch to edit mode.

**v1.8.2 RELEASED — "the document family reads in the real reader"** (branch `batch-c-d-session` → `main`, 2026-11-20; release commit `ab85df4`, tag `v1.8.2`, build 48):
- **What shipped.** Everything since the v1.8.0 tag, in one release: the foliate-js document reader (mobi/azw3/fb2/rtf/html/txt render the ORIGINAL file, publisher TOC, instant chapter jumps, CFI resume, one chapter numbering shared by reader/TTS/TOC, legacy books migrate), the real mobi/azw3 index + RTF bold-title chapter split + EPUB TOC tree depths, slide decks as a book format (visual-order speech, refit, full-viewport), the Nano Edge engine (Kokoro's voices, distilled, ~157 MB), copy/selection across read-along + preview + "Play from selection", row menus and bin menus, the settings rebuild (info buttons, one Models list by size), the acknowledgements screen, the immersive tab bar, Ogg/Opus artwork + cover healing, the sticky scrubber, Phonon's chunk click/gap fixes, and the v1.8.1 grouping (BookDrop transfer fix + progress bars, maths fixes).
- **The scrub.** The repo is PUBLIC, so this round also scrubbed identifying references: `/home/sagestation` and `~/.zcode/workspace` paths, hardcoded repo slugs in the plan docs, and the `thesagezm` handle in prose — 15 files. **Two functional URLs keep the handle** and are the minimum working set: the Hugging Face models repo (the app downloads the Nano Edge model from it at runtime — `ModelManager.nanoEdgeBaseURL`) and the onnxruntime SPM mirror fork (the ONLY onnxruntime dependency URL; Microsoft pulled the original, so removing it breaks every build — app and CI). Both swap cleanly if the models/fork are ever rehosted under a neutral account. `Scripts/watch_ci.sh` now reads the repo from the git remote instead of a hardcoded slug. **Known limit: this is a tip-only scrub — the public git HISTORY still carries the old references**, and the GitHub account that owns the repo is visible by definition; rewriting history (`git filter-repo` + force-push + re-tagging) is the only way to change either, and it breaks every existing commit link, clone and release link — deliberately NOT done here.
- **Release mechanics.** `main` was fast-forwarded (`git push origin batch-c-d-session:main` — `origin/main` was a strict ancestor, so no SHA changed and every PROGRESS_LOG run reference stays valid), the CI run on the release commit went green, the IPA was taken from THAT run (not from a branch run), the version was verified inside the IPA's Info.plist (1.8.2 / 48), and the annotated tag + GitHub release went out with the IPA attached as `SpeechnotesIOS.ipa` — matching v1.8.0's asset shape. The repo also gained a description and 20 topics (tts, text-to-speech, adhd, ios, swiftui, epub, pdf, book-reader, audiobook, notes, markdown, offline, on-device, speech, pomodoro, reader, sideloading, livecontainer, side-store, swift).
- **CI: GREEN — run `44649984015` on `ab85df4` (on `main`), all 8 jobs success** — logic tests (version fields + the SpeechLogic suite), all six spikes, and the IPA artifact (23.0 MB, unsigned) + dSYMs. The IPA carries the release commit's build.
- **Open for the device round:** the release's new surfaces (foliate reader on a real KF8, decks on the user's own PPTX files, copy/selection in read-along, the "Play from selection" menu item), plus the two gaps CI cannot see — **there is still no LICENSE file** (the README says "revisit before any public distribution"; a license is the owner's call, so none was chosen here), and the **history scrub** above.

**Copy out of every reading surface, row menus that hold the full action set, and play-from-selection in the editor's native menu** (branch `batch-c-d-session`, 2026-11-20; 2 commits `94a4252`+`2139953`, v1.8.2 build 48):
- **The ask.** A parity audit was done against the Linux (GTK) app's identical gap list — GTK ships no context menus, so the desktop app got a whole new `editmenu` module; iOS needed only the surfaces UIKit does NOT cover. What iOS already had free: the editor is a `UITextView` (native Cut/Copy/Paste/Select All/Undo on long-press), every `TextField` carries the native edit menu, notebooks already have Rename/Delete menus (`NotebookListView`), book cards have a context menu, and the epub reader's `WKWebView` gives the system selection menu (nothing in the foliate shell suppresses it — the one `user-select: none` in `paginator.js` is the loupe overlay). What was actually missing, now fixed:
- **Read-along text was un-liftable — and it covers FOUR surfaces** (the worst gap). `ReadAlongView` rendered SwiftUI `Text` rows with only the tap gesture; no `.textSelection`, no long-press menu — a passage could not be copied out of epub (`BookReaderView`), PDF (`BookPDFReaderView`), slides (`BookSlidesView`), or the note read-along (`NoteEditorView`). One modifier fixes all four: `.textSelection(.enabled)` on `ReadAlongRow`'s `Text` (`ReadAlongView.swift`). The tap-to-speak gesture is untouched by design — selection starts on long-press, plain taps still bubble to `onTapParagraph` → `playFrom`, so paragraph-level speak-from-here was ALREADY the one-tap affordance everywhere; what arrived is passage-level copy.
- **Preview prose was un-selectable.** `MarkdownPreviewView` enabled `.textSelection` on code blocks ONLY — paragraphs, headings, quotes, list items and table cells could not be copied. Enabled at all five sites.
- **The note-row context menu stopped short** (`NotesListView`): it had Pin/Favorite/BookDrop/Move-to-notebook while Share and Export lived only in the swipe actions (invisible on long-press, the discoverable surface), and NO rename existed anywhere outside the editor's title field. Menu gains Rename… / Share / Export; rename is the `NotebookListView` alert idiom, and a blank draft CLEARS `explicitTitle` so the row falls back to the derived first-sentence title — the same fallback the editor's title field uses (the draft is pre-filled with the current display title, derived or explicit).
- **The bins had swipes but no long-press menu** — long-press on a bin row did nothing in BOTH bins. `.contextMenu` (Recover / Delete Now) mirrors the swipes verbatim, haptics included (`RecycleBinView`, `BooksRecycleBinView`).
- **"Play from selection" rides the editor's built-in selection menu** (`MarkdownEditorView` + `NoteEditorView`). The `UITextView` is now an `EditorTextView` subclass whose `canPerformAction` surfaces a registered `UIMenuItem` when playback is idle and the caret/selection is speakable; tapping it runs the SAME logic as the ⋯ menu's "Play from caret" (selection start, snapped to a sentence boundary inside SpeechPlayer). The legacy `UIMenuItem` registration is deliberate — iOS 16+ still surfaces UIMenuItems inside UITextView's built-in menu, and `UIEditMenuInteraction` cannot augment a UITextView's own menu (it only drives menus on custom views). Handlers are refreshed every `updateUIView` because they read live SwiftUI state (player state, caret) UIKit cannot see.
- **Version 1.8.1/47 → 1.8.2/48** (`project.yml`, the guarded two-file pair).
- **Tests/verification:** none runnable on this box (no Swift toolchain; UIKit does not compile on Linux) — CI is the compile gate, and it took ONE fix commit: run 1 (`44640962456`) failed with exactly one error — in the table `cell()` the chain is Text-typed and `Text.monospacedDigit(_:)` takes a Bool, but my `.textSelection` FIRST downgraded the chain to a plain `View`, where `monospacedDigit()` takes no argument. Fix (`2139953`): `.textSelection(.enabled)` moved to the END of the cell's modifier chain, with the reason in a comment. Run 2 is clean.
- **CI: GREEN — run `44642587154` on `2139953`, all 8 jobs success** — logic tests (version fields + the SpeechLogic suite), all six spikes, and the **SpeechnotesIOS** IPA artifact (23.0 MB) + dSYMs uploaded: the device-test build for the round; no release/tag, per the standing ask.
- **Device round (open):** long-press a passage in the read-along of an epub/PDF/slides/note → the native menu with Copy (the selection must not swallow a plain TAP — a tap must still start speaking from the tapped paragraph, the interaction this round could not verify from Linux); select text in the editor → the menu should show "Play from selection" while idle and NOT while playing (if the item never appears, the fallback is UIEditMenuConfiguration replacing the menu wholesale — say so); long-press a note row → Rename…/Share/Export present, blank rename reverts to the derived title; long-press both bins' rows → Recover / Delete Now; select prose in the markdown preview → Copy.

**Six-item bug batch: Ogg artwork (never existed — now it does), late covers, sticky seek, the prose walls, acknowledgements, and document covers that heal** (branch `batch-c-d-session`, 2026-11-20; 7 commits `61de130`→`798d9ae`):
- **Item 1 — Opus books' artwork.** Ground truth: the ONLY artwork source in the audiobook import is AVFoundation metadata (`buildAudioManifest`), and AVFoundation has no Ogg demuxer — every `.opus/.ogg/.oga` read is empty, so the artwork path never fired for them. `git log -S METADATA_BLOCK_PICTURE` says Ogg artwork extraction NEVER existed in this repo — the "worked before ~v1.8.1" memory refers to m4b books, whose covers came (and come) from AVFoundation. The app's own OggReader already assembles the OpusTags comment packet across pages (chapters ride it, capped 24 MB) but ignored the picture comments: `Summary.artwork: Data?` now parses `METADATA_BLOCK_PICTURE` (base64 FLAC picture block — big-endian fields, image at the end, front-cover type 3 preferred over scans/thumbnails) and legacy `COVERART`, and the Ogg branch writes it through the shared `writeAudioCover` (the m4b inline re-encode moved there — one decodable JPEG either way). **`audioReaderRev` 1 → 2** is the load-bearing part: every existing Ogg book carries `-verified` from rev 1, and the rev clause is what buys them ONE re-read (the same repair pass that carried the Dune moov fix). Fixture `cover.opus` is a real ffmpeg mux — 6.x cannot mux attached_pic streams, so the picture rides the metadata passthrough, which writes the same comment an attached_pic would.
- **Item 2 — artwork takes ages.** Two causes, two halves of `b944139`. (a) The metadata read ran LAST — after the 5 s-bounded duration wait and the whole chapter pass — so the M4B/MP3 cover (whose ONLY source that read is) landed at the end of the import; it now runs first (a header read, the cheapest in the function). (b) `BookCoverView` keyed its load task on `book.id` only, so a cover that arrived after the cell painted (launch backfill, foliate migration, the rev-2 re-reads) never reloaded; it keys on `"\(id)-\(hasCover)"` now and decodes into a small NSCache (decoded-bitmap cost — compressed bytes undercount 4–30×, ImageCache.swift's reasoning).
- **Item 3 — the slider seek snapped back then jumped.** `commitSeek` published `chapterProgressValue` right after `backend.seek` — but AVPlayer's clock still reports the PRE-seek position until the async seek lands. It publishes the TARGET through a new position-parameterized `chapterProgress(at:)` and arms `seekHoldTarget`; `tick()` holds the surface until the backend is within ~1 s (3 s cap — a stream with no clock cannot pin the playhead; the Opus backend lands synchronously and releases on the next tick). The second half: both seek consumers ran `packets.firstIndex { $0.granule > 0 }` per seek — an O(n) walk over up to 2.07 M packets ON MAIN, twice per drag; `OpusPacketStream.firstAudioIndex` caches it at construction (one pass at load).
- **Item 4 — the prose walls.** BookDrop (3 long footers + the whole three-step PC section) and Benchmark (3 long footers) rebuilt to the house pattern from 67179e0: footers gone, nav-bar `info.circle` opening a sheet with the facts stated once (EncryptionInfoSheet template). All controls kept — BookDrop's toggles/port/access-code/incoming card/Recent transfers, Benchmark's pickers and live/summary rows.
- **Item 5 — acknowledgements** (`07a17c6`): `AcknowledgementsView`, one grouped list (what each piece does HERE / license / source), linked from About. Vendored (libopus/COpus, swift-markdown AST, foliate-js, epub.js + JSZip, Readability, the DeckCraft port, the KindleUnpack Huff/CDIC transcription), SPM (swift-cmark, MisakiSwift, onnxruntime via the mirror — Microsoft pulled the original repo, MLX + MLXUtilsLibrary), the four HF voice models, and the two spec-implemented formats (Joplin E2EE — independent reimplementation, no code; LocalSend v2.2). Licenses re-verified against upstream at write time; the BPC pair excluded per the ask.
- **Item 6 — mobi/azw3 covers.** The engine is NOT the problem (the harness returned valid JPEGs for 8/8 well-formed files; the two Proust failures were a harness URL artifact) — the native side never repainted, which item 2(b) fixes. Three gaps closed in `8749763`: the backfill filter had NO `.document` clause (a cover-less document healed never), so one now matches; the engine's mobi getCover follows only the EXTH offsets while the native `MobiParser.coverImage` falls through to the first image record (the publisher-logo-vs-real-cover layer) — new public `MobiParser.coverOnly` reads just the header records and `nativeDocumentCover` runs it in fresh import, foliate migration AND backfill before a tile is synthesized; and `foliateMigrate` now synthesizes a tile when the engine returns no cover, which the fresh-import path always did — a migration must not leave the tile WORSE than importing the same file today.
- **Verification without an iOS build:** the full SpeechLogic package cannot compile on Linux (`UniformTypeIdentifiers`), so the docker scratch loop carried OggReader + OpusPacketStream alone — **26/26 OggReaderTests green**, 9 of them new (block parsing, front-cover preference, legacy COVERART, corruption incl. a lying dataLength, artwork+chapters in one page-spanning packet, nil-without-pictures, real-muxer fixture). `MobiParser.coverOnly` was built in its own scratch package and run against 7 real books in `~/Downloads`: **valid JPEG magic from every one**, including BOTH Proust `.azw3` files the engine misses and Ulysses. Every Swift file in the round parse-checks clean, and each commit boundary was staged and parse-checked independently (the BooksStore changes were split across commits 1/2/6 by hunk).
- **CI: GREEN — run 44636086670 on `798d9ae`, all 8 jobs success** — logic tests (the full SpeechLogic suite on macOS, new artwork tests included), all six spikes, and the **SpeechnotesIOS** IPA artifact + dSYMs uploaded: the device-test build for the round. No release/tag, per the standing ask.
- **Device round (open):** the rev-2 audio re-read is capped at `maxAudioBooks: 2` per launch — Ogg books pick up their covers over SEVERAL launches, oldest first (tell the user this is the shelf filling in, not a new bug). Check: Opus/ogg tile shows art after a launch or two; M4B covers appear near-instantly on import; the mobi/azw3 covers heal (documents are uncapped in the backfill, same launch); the slider holds where dropped (seek + pause right after must not drift back); BookDrop/Benchmark read as control screens with an ⓘ; About → Acknowledgements lists the stack.

**The engine harness runs the SHIPPED shell over 17 real books — and caught the two bugs that would have kept the foliate reader dead: a metadata decode that failed every mobi/azw3, and a chapter jump that moved the page but not the bar** (branch `batch-c-d-session`, 2026-11-19):
- **The harness** (`Scripts/foliate-harness/`): a page that drives the REAL iOS shell (`App/Resources/foliatejs/sn-shell-ios.js` — the file the app splices into `foliate.html`, not a copy of it) over the books in `~/Downloads`, and reports what the engine produces: the identity + section count + resolved TOC rows the import must record, the first section's prose (the TTS source), the position the reader reports, and where a chapter jump lands. A `frame.html` installs the `webkit.messageHandlers.reader` shim a browser does not have and stands in a timer for `requestAnimationFrame` (a Chromium that is not compositing never fires animation frames — a harness artefact, noted as such). One book at a time; each frame is torn down before the next.
- **The corpus** (the recorded run is `Docs/FOLIATE-ENGINE-PROBE.md`): **15 of 17 files open** — 5 mobi, 3 azw3, 3 fb2, 2 rtf, 1 html, 1 txt — and the **2 truncated (0-byte) azw3 files are refused with a clear message** instead of crashing. Every book that opened answered a chapter jump with the right section index and handed back its section's prose. The publisher's own chapter names are in the TOC — "CHAPTER 1: GRANT'S FORMATIVE YEARS", "Chapter 1—God's Love for Man" — not "Chapter 1…N". The engine's section counts are pinned: Steps to Christ 17 sections/15 rows, Ulysses 13/12, Proust I–VII 86/9, IMPRO 13/12, One Hundred Years (mobi) 29/26, The Great Gatsby (fb2) 10/10.
- **BUG 1 — the metadata report would have failed the decode for EVERY mobi/azw3.** `mobi.js` and the KF8 builder report `language: ['en']` (a LIST); FB2 reports `'en'` (a string). The shell passed the engine's value through untouched and Swift's `ParseMeta.language` is a `String?`, so `JSONDecoder` threw a type mismatch → `probe()` threw → the import caught it and ran the Swift fallback → `docRenderer: "pages"` → the foliate reader never opened the book. That is the original complaint ("the TOC and the chapter buttons do not work"), reproduced by the NEW code. Fixed at the boundary: the shell flattens the engine's title/author/language (`metaTitle`/`metaAuthor`/`metaLanguage`), and the unused `language` field is out of `ParseMeta` — a field the manifest does not use must never be able to fail the decode and take a whole book down to the fallback renderer.
- **BUG 2 — a section with no text reports NO relocation, so the chevron did nothing.** Found on *Truth in Comedy* (a 99-page graphic-layout mobi): the jump to section 1 landed, the section LOADED (`section loaded 1` in the shell's log), and no relocation ever arrived — the bar stayed on "Chapter 1". The paginator returns early from `#relocate` when a section has no visible range to measure, so the engine never says where it is. The shell now asks the renderer which section it is showing (`renderer.primaryIndex` — the spine index, the manifest's numbering) after every jump, turn and TOC tap, and reports the position itself when the renderer stayed silent. A section change resets the fraction to that section's top; a move inside one section keeps it. Verified: the jump that reported nothing now reports `landed: 1`.
- **The resume fraction is NOT dead — the handover's reason for dropping it was wrong.** It said "the paginator's anchor is a pixel offset"; in this fork it is a **fraction of the section** (`#anchor = 0 // anchor view to a fraction (0-1)`, and `#scrollToAnchor` uses `anchor * primarySize`). The fraction was dropped because it was in the wrong unit (a whole-book one), not because the anchor could not carry it. It is now used, correctly: the resume is the CFI when there is one, else the manifest's chapter plus the fraction INSIDE that chapter, riding as the anchor — the unit the reader now reports and persists, and the unit the pages pipeline stored.
- **One compile error found by reading the Swift diff** (no toolchain on this box): `BookReaderView` passed `onBook`/`onSectionText` BEFORE `onError` to `BookWebView`'s memberwise initializer, and Swift requires the declaration order — the compiler would have rejected it with *argument 'onBook' must precede argument 'onError'*. Fixed by moving `onError` back above them. The other risk in the diff (`Self.tocEntries` inside the nested Coordinator) was already fixed by the last agent.
- **One typo found in the same read** (the harness cannot see it — no corpus label happens to carry `'`): the shell's `unescapeXml` had its entity map keyed `'#39:'` with a stray colon where `'#39'` belongs, so the lookup missed and the replacement was `undefined` — **every TOC label with an escaped apostrophe would have read "undefined" in the Contents sheet**. Key fixed, and an unknown entity is now left alone instead of becoming the word "undefined".
- **The decode-default question, settled:** `Book.docEngineTried: Bool = false` relies on the synthesized `Decodable` honouring a missing key via the property's default. The repo's own precedent proves it — `Book.forceOCR: Bool = false` (0e27a49, a month ago) is the same shape, and the user's pre-flag shelf still decodes; `BooksStore`'s loader SKIPS a book whose manifest fails to decode, so a wrong call there would have emptied the shelf silently.
- **Format truth the numbers show (the engine's, and the Linux app's):** FB2 varies by file — *The Great Gatsby* gives 10 sections and 10 chapter rows (a real chapter bar), while *The catcher in the rye* and *One Hundred Years* (fb2) give 1 section and 1 row (those files put the whole book in one `<section>`), and the Great Gatsby fb2's first row label is empty. A Kindle file can have more sections than TOC rows (Proust 86/9: the nav lists volumes, the spine is the flow). Some KF8 nav labels are the file's own placeholders (`{chapter-3}` in *Ulysses*). RTF/HTML carry no metadata (none in the file); the RTF builder still finds the headings.
- **Tests:** none addable on this box (no Swift toolchain) — **CI is the gate, and it is GREEN**: run **44481980089** on `e9b3fc3` (dispatched on `batch-c-d-session`), all 8 jobs success in 9 min — the **SpeechnotesIOS** IPA artifact (23.0 MB) + dSYMs uploaded, so this is the device-test build for the round; no release/tag, per the ask. The argument-order fix in §2.4 was the only compile error the round needed. The harness is the new gate for the engine: `node --check` passes on all three touched JS files, and the harness re-runs the whole corpus in one command.
- **Device round (still open):** import a fresh `.mobi` (the manifest must show `docRenderer: "foliate"`, the engine's section count and the publisher's TOC), open an existing shelf book (the migration re-stamps it), walk the next/prev chevrons (the bar must read "Chapter N of M" with the right N), tap through the Contents sheet, play TTS (it must speak the page on screen), and reopen a book mid-chapter (the CFI resume).

**CI green on the foliate + settings round — the IPA artifacts are up; two compile-fix commits were all the blind code needed** (branch `batch-c-d-session`, 2026-11-19):
- **Run 44428733287 on `4579801`, all 8 jobs success.** "Build unsigned IPA" archived v1.8.1 clean: only system dependencies in otool -L (Frameworks/ empty — LiveContainer's one kill-requirement), UIBackgroundModes exactly [audio], and the **SpeechnotesIOS** IPA artifact (23.0 MB) + dSYMs uploaded — this is the device-test build for both rounds (foliate reader + settings rebuild); no release/tag was made, per the ask. Logic tests (version fields, SpeechLogic suite, the 53-assertion web-article walker) and all six spikes passed on the same run.
- **What the two failed runs caught** (`1470e5c`, then `4579801`): the foliate round's blind-written Swift had three errors — BookWebView's allowed-extension Set built from an array literal (`[String]` has no `.union`), DocumentParseService's `waiters` typed as non-throwing `CheckedContinuation<_, Never>` while `nextMessage` parks the throwing continuation, and `Data.init(base64Encoded:)` not resolving as an unapplied reference (failable init + defaulted options parameter; closure form now) — then one Swift exclusivity violation in the foliate migration's position remap (`position?.chapterIndex` read and written in one statement; the index moves through a local). The settings round compiled clean on the first attempt; every failure was foliate-side.

**Immersive chrome takes the tab bar too; slides fit the full viewport** (branch `batch-c-d-session`, 2026-11-19):
- **The ask.** "When I tap to hide for markdown preview (not editing mode) and all books… whether portrait or landscape… I want the bottom tabs bar to also be hidden the way the title bar does — for portrait the playback rail/collapsed rail moves lower to occupy the space the tabs bar was using (more display); for landscape the viewing window has no limit at the bottom and occupies the screen top to bottom." Plus: "slides are still not taking up all the space available while maintaining their dimension — see if 1 can also help; PDF takes up screen space well, I want slides to succeed as well."
- **Tab bar joins the chrome toggle** (`OrientationState.immersiveTabBar(_:)` — one View extension, iOS 18's `.toolbar(_:for: .tabBar)` placement, this app's deployment floor): hiding `.tabBar` removes the bar AND its safe-area inset, which is the whole handoff — the portrait bottom controls' `safeAreaInset` docks down into the strip the tabs vacated (the playback rail/collapsed pill moves lower exactly as asked), and in landscape the reader surface runs to the screen's bottom edge. Applied beside each surface's existing navigation-bar line: BookReaderView (`immersiveBars.epub`), BookPDFReaderView (`.pdf`), BookSlidesView (`.deck`), BookAudioReaderView (`.audio`), and NoteEditorView (`chromeHidden` — already computed off the READING surface, so the tab bar hides only in markdown preview/read-along, never while editing; entering edit restores it). Per-surface keys untouched — each reader still remembers its own state.
- **Slides fit the FULL viewport** (DeckHTML): the Linux port's 14px slide gutters + the fit script's 28px allowance (`innerWidth - 28` / `innerHeight - 28`) shrank every slide on both axes; now `margin:0 auto` and the page fit consumes the whole viewport — width edge-to-edge in portrait, height edge-to-edge in landscape, aspect preserved (the 4/3 pt→px factor stays). The box-shadow still separates stacked slides while scrolling. Fix 1 compounds it: in landscape the height-limited slide grows by the whole tab bar's height because the webview itself is taller.
- **Tests:** none addable on this box (no Swift toolchain) — CI (build.yml on this branch) is the gate; dispatch after commit. Device round: tap-to-hide in every reader in BOTH orientations (tab bar gone, portrait rail docked low, landscape surface full-height, tap brings everything back), markdown preview hides tabs while editing never does, and a deck fills its viewport like the PDF does.

**Settings tab rebuilt to the Android reference — footers gone, info buttons instead, one Models list sorted by size, engine rows say facts only** (branch `batch-c-d-session`, 2026-11-19):
- **The ask.** "Fix up the ui in speechotes ios settings: every subsetting has notes — remove them all, important info goes in an info button especially in speech settings; reorder model downloads by size largest last; stop claiming Supertonic is best quality (nobody knows anymore — state only verifiable facts in a smaller secondary font UNDER the engine name, not the same line/font; 'on-device neural'/'compact on-device neural' are useless labels); Appearance loses the bypass-paywalls toggle (always on) and the image-caching picker (never used) plus its notes; keep screen on belongs in Appearance; Diagnostics = benchmark mode and logs; and the tab itself is lackluster — copy speechnotes-android's approach (flat icon+title+subtitle rows; 'About' header over an 'About' row, same for Storage, is repetition)."
- **SettingsTabView is the Android SettingsHomeScreen now**: flat rows — icon in the accent color, title + one-line subtitle, chevron — Speech engine ("Engine, voices, model downloads"), Appearance ("Theme, accent, reader, keep screen on"), BookDrop, Backup (ONE row), Encryption ("Passphrase-sealed notes, Joplin-compatible"), Storage ("Usage, exports, cached images"), then a small "Diagnostics" section holding Benchmark mode + Logs (moved Logs out of About — About stands alone in a headerless trailing group). The JEX import button moved INTO BackupExportView (title "Export"→"Backup", an Import section with the picker/alert/importJex moved from the tab root), which is why Backup collapses to one row. Redundant single-row sections ("Speech" header → "Speech Settings" row) are gone.
- **SpeechSettingsView rebuilt to the Android SpeechSettingsScreen shape**: engine radio rows render `EngineKind.label` (name only) + the NEW `EngineKind.subtitle` (factual caption, smaller secondary font UNDER the name): "Apple system voice / Instant — no download", "Kokoro / 28 English voices · ~341 MB, or ~92 MB compact", "Nano Edge / Kokoro's 28 English voices, distilled · ~157 MB", "Phonon / English · 27 voices · ~192 MB", "Supertonic / Multilingual · 31 languages · 10 voice styles · ~399 MB" — no "best quality", no "on-device neural" filler (those labels went stale/mouthed nothing; sizes, voice counts and languages are what we know). Voice + System voice are ONE section now. Kokoro quality and Supertonic quality pickers carry per-option factual subtitles (tier sizes; denoising-step counts) instead of footer essays; the Core ML toggle keeps its rebuild onChange with the explanation moved to the info sheet. ALL footers deleted; the nav-bar info button opens SpeechInfoSheet — the consolidated engine/model facts from the old footers (system-voice download path, Nano Edge's shared voice banks, Phonon's missing speed input, Supertonic's next-chunk apply + exports-always-full-quality, the Core ML experiment note). The model-missing and neural-active notices stay inline (state feedback, not notes).
- **One "Models" section, smallest first / largest last** (the ask): Kokoro (small) ~92 MB → Nano Edge ~157 MB → Phonon ~192 MB → Kokoro ~341 MB → Supertonic ~399 MB — one compact row per model (`name · size`, state as the secondary line: Not downloaded / Downloading… N% / Failed — msg / Ready — fully offline) with a SINGLE trailing button replacing each old per-model section's stacked full-width Download/Retry/Delete rows (`.borderedProminent` Download, mini `ProgressView` while downloading, `.bordered` Retry / destructive Delete; bordered styles keep the tap scoped to the button — a plain Button in a Form row makes the whole row the hit target). The five near-identical sections were the "loads of repetition especially in speech settings".
- **Appearance**: Bypass Paywalls toggle GONE — `PaywallBypass.isEnabled`/`enabledKey` deleted, WebArticleService checks only `options.allowBypass && loadScripts() != nil` (bypass always runs; the enum keeps script loading + the version helper for the import log). Image-caching picker GONE — NoteEditorView.prefetchImagesIfAutomatic drops its UserDefaults guard and always prefetches. Keep Screen On moved here (Reading section, with its ScreenAwake.refresh onChange; the tab root's Reading section is gone). Theme + Accent share a "Theme" section, render-markdown + haptics share "Notes" (Android groups haptics under Notes too), all sliders live in "Reading" with their short inline captions kept. ALL section footers deleted.
- **Footer essays stripped everywhere**: EncryptionSettingsView keeps exactly ONE line ("If you forget the passphrase, your notes cannot be recovered.") and gains a nav-bar info button (EncryptionInfoSheet: Joplin format, keychain construction, slow-by-design, locking vs turning off, no recovery); StorageSettingsView lost its four essay footers (the exports/images count readouts stay — they are data, not notes). BenchmarkView internals untouched.
- **Duplicate SettingsView.swift DELETED** (the NoteEditorView modal was a drifting second copy of the speech settings) — the sheet now presents the real SpeechSettingsView in a NavigationStack with a Done button; NoteEditorView's stale SettingsView-era state unused gone. Net: ~340 duplicated lines out.
- **Tests:** none addable on this box (no Swift toolchain) — CI (build.yml on this branch) is the gate; dispatch after commit. Device round: check the engine rows' two-line labels render (inline picker + custom VStack labels), download a model to see the mini progress state, confirm the info sheets, and confirm web import still runs the bypass pass (the toggle is gone from Appearance).

**The document family gets the Linux reader's own viewer — foliate-js renders the ORIGINAL file, nothing is converted; the mobi chapter-button lag dies with the page-reload navigation** (branch `batch-c-d-session`, 2026-11-19):
- **What the user asked for and why the old path couldn't give it.** "mobi/azw3/fb2/rtf/html are not rendered well… rendering should not parse or convert them to epub but rather view them in their own viewers… use as much of the speechnotes-linux (not-rust) code as possible — it's working." The Linux app's reader is the vendored **foliate-js** (readest's fork, MIT) under `sn-ui/assets/foliate-js/` — mobi.js decompresses the whole Mobipocket/Kindle family in JS (the reason the letters stop repeating), fb2.js/rtf/html/txt builders the rest — and the user's complaint mapped exactly onto what the iOS import did instead: parsed the file with the Swift-side DocumentBook at import, persisted doc/chapter-N.html pages, and served those as the render. The pre-parsed pages were also the thing that made **next/prev chapter buttons lag**: a chapter jump navigated the top-level document (`location.href` — a full page load per turn).
- **Vendored verbatim** (`App/Resources/foliatejs/`): view.js, paginator.js, epubcfi.js, progress.js, overlayer.js, text-walker.js, section-chunks.js, mobi.js, fb2.js, sn-txt.js, sn-docbook.js, sn-html.js, sn-rtf.js, vendor/zip.js, vendor/fflate.js + LICENSE — the exact bytes the Linux app ships; no epub.js/fixed-layout/pdf/search/tts modules (their formats never reach this engine, and the EPUB stays on the proven epub.js shell). Syntax-pinned as ESM with `node --check` for every file; grep-proof that none of it uses Safari-missing APIs (no Promise.withResolvers/Array.fromAsync/static blocks). The Linux shell's load-bearing quirk carries over: an external `<script type="module" src>` never executes on this WebKit's custom-scheme pages (measured on WebKitGTK there), so the scheme handler SPLICES sn-shell-ios.js inline into foliate.html over the `sn-shell-module` marker (FoliateAssets.serve) — inline modules importing the same files run fine.
- **New shell `sn-shell-ios.js`** — a port of the Linux sn-shell.js onto the iOS bridge: same format dispatch (txt/text/md/markdown → chapteriser, rtf → RTF renderer, html/htmlz → HTML builder, fb2 → fb2.js, mobi/azw/azw3/prc/pdb → mobi.js), same per-section type layer, same flattenToc-with-resolved-indexes; adapted to speak the epub.js shell's exact object protocol on the `reader` channel (relocated/toc/error/chromeTap/pageTurn + goChapterFailed) and to answer the SAME command surface BookReaderView already drives (readerGoChapter/readerNext/readerPrev/readerAppearance/readerGoToHref/readerAutoScroll/…). The chapter jump lands on `view.goTo(index)` — **in-renderer, instant, no page reload** — which is the structural fix for the mobi chapter buttons. Appearance: theme colors land always (a dark theme darkens a respected book too — the epub shell's rule), typography gated on respect-styles, margins ride the paginator's margin-* attributes ( honored in BOTH flows — foliate's paginator does it right, unlike epub.js's container math), flow="scrolled"/"paginated" as the paginator's flow attribute, `no-continuous-scroll` kept (the Linux reader's RAM-bounded rendering: one section iframe at a time), auto-scroll ports the epub shell's rAF loop over the primary section document with the dwell guard. Gestures post pageTurn (the epub shell's relay shape — SwiftUI evaluates readerNext/readerPrev back, haptics fire, one turn). External links preventDefault + post (a book link can no longer navigate the reader away). Resume: a real foliate CFI via `view.init({lastLocation})`; the pre-foliate `doc@…` pseudo-CFIs are filtered (`startsWith('doc@')`) and resume via chapter+fraction on `renderer.goTo({index, anchor})` — anchor is the foliate paginator's section-fraction, the exact shape of the persisted chapterFraction.
- **One chaptering everywhere (the drift fix).** The import's TTS parse now runs the SAME foliate engine: `DocumentParseService` boots a hidden WKWebView on foliate.html `mode=parse` and walks the book section by section — `__snParse.meta()` (title/author/language/toc with resolved section indexes) → per section `prepareSection(i)` posts when the serialized XHTML is ready, `takeSection()` hands it over and DROPS it (one chapter's XHTML in the heap at a time; evaluateJavaScript cannot await a Promise, so async steps post and sync steps pull — the kicked steps tail `'kicked'` because a Promise result is not serializable across the bridge) → `prepareCover()` posts the cover (mobi getCover / fb2 getCover) as base64. The files land under the SAME contract the old pipeline wrote (doc/chapter-N.html, XhtmlText.extract reads them for TTS unchanged — XMLSerializer output is well-formed XML, and the section ORDER is the foliate section list), and the manifest stamps **`docRenderer: "foliate"`** with spine = `chapter-N` 1:1 with the foliate sections: reader section indexes, TTS chapter indexes and TOC spineIndexes are one numbering — the "speaking chapter 4 while reading chapter 5" class of bug cannot exist. Import is CHEAPER too: the file is streamed to the webview from a FileHandle (no Swift-side copy), the CPU-bound decompression runs in the WebContent process, and the old main-thread-detached parse is gone.
- **Fallback kept, honestly stamped.** A file the foliate engine cannot open (DRM, a .pdb that is really some other Palm format) falls back to the unchanged Swift DocumentBook parse with `docRenderer: "pages"` — the pre-foliate pipeline, byte-for-byte what it did before, so a book that fails foliate still imports, speaks and renders exactly as it did. `Book.rendersWithFoliate` routes BookWebView: foliate books boot the foliate shell; pages books keep the nativeReaderScript path untouched.
- **Legacy books migrate.** The user's existing mobi/fb2/rtf shelf predates the flag — `BooksStore.migrateLegacyDocumentBooksToFoliate()` (one pass per launch, after the shelf backfill, sequential, one hidden webview at a time, released between books) re-parses each docRenderer-nil document book with the foliate engine, replaces doc/ wholesale, re-stamps spine/toc/docRenderer, and remaps the saved position: the pages spine's "cover" entry at index 0 shifts every resume back by one, the doc@ pseudo-CFI is dropped, the fraction survives. Engine-failed books are terminal for the launch (never a retry loop); books the fallback stamped "pages" are never retried.
- **Bridge bug found on the way:** BookWebView's `toc` handler hardcoded `spineIndex: nil` — the foliate shell's resolved rows would have been dropped and every TOC jump fallen back to href matching. It reads the field now (epub.js shell posts none — nil keeps the manifest authoritative there).
- **Mobile compatibility (the user's constraint):** WKWebView is WebKit — the same engine class the Linux shell was measured against; iOS 18 covers every syntax the fork uses. zip.js runs with `useWebWorkers: false` (the Linux shell's own setting — workers are the first thing custom schemes break). Bundle layout insurance: FoliateAssets looks resources up flat (xcodegen's group-tree shape, the epubjs-proven one) then under `foliatejs/`, `foliatejs/vendor/`, `vendor/`.
- **RAM discipline throughout (the user's constraint):** the reader holds ONE section iframe (`no-continuous-scroll`); the importer streams the file (no mapped copy) and crosses one section string at a time; the parse webview is released the moment the walk ends; the migration pass releases its webview between books and runs one book at a time.
- **Tests:** none addable on this box (no Swift toolchain) — CI (build.yml on this branch) is the gate; dispatched after commit. `node --check` pins the JS. Device round: import a fresh mobi + open a legacy one (the migration log line "migrated «title» to the foliate renderer"), watch the chapter chevrons land instantly, confirm TTS chapter text and the TOC still line up (they share the foliate numbering now by construction). OPEN: on a real KF8, check the "Chapter N of M" bar reads sensibly — mobi.js's section split is the format's own (its spine), not DocumentBook's heuristic one, so N may differ from what the old reader showed; that IS the fix, not a regression.

**Phonon chunk click + gap; mobi/azw3 (and RTF) TOC + chapter split — the reader-contract round** (branch `batch-c-d-session`, 2026-11-13):
- **Phonon: "a click at the end of every chunk, then a small wait before the next one."** Two causes, both in `StreamingTTSPlaybackCore`. (1) CLICK: every engine cuts a chunk's PCM at a synthesis boundary (Phonon's EOS countdown keeps one 80 ms frame past the crossing; each chunk starts from a FRESH model state), so chunk-end and chunk-start amplitudes are unrelated samples — the step between back-to-back buffers is a broadband transient. Fix: `boundaryFaded` — a 5 ms raised-cosine fade-in + 12 ms fade-out on every chunk at the core's two sinks (playback producer + WAV export), sentence-boundary-shaped so speech never notices. (2) WAIT: the keepalive bridge armed 0.5 s silence buffers when the node queue drained, and a real chunk landing queues BEHIND them (scheduleBuffer has no insert-at-head) — up to half a second of dead air after the chunk was already synthesized. Bridge shortened to 0.2 s (still outlives the producer wakeup + a main-queue hop it exists to cover).
- **mobi/azw3: "fails to keep the table of contents and separate chapters accurately" — root cause found.** `MobiParser.tableOfContents` parsed an INVENTED index layout: TAGX entries read as name-length-prefixed STRINGS ("CNCX"/"position"/"label") where the format actually encodes numeric [tag code u8][values count u8] pairs, and the CNCX as fixed-slot records where it encodes [VWI length][label bytes] runs. On EVERY real book the names never matched → the reader returned `[]` → the publisher's contents page was silently lost; every mobi/azw3 fell back to h1/flow titles ("Chapter N" for books that style headings instead of marking them). Zero tests covered the index path (grep proof). Rewritten to the real layout (KindleUnpack/mobiunpack's mobi_index): TAGX numeric table, VWI entry walk (7-bit, high-bit terminator), CNCX label runs, plus gates that REJECT rather than misread (labels count == entries, offsets ascending + inside the book, labels sane-printable) — any gate failure falls back to the pre-fix heading/flow paths, never worse. MOBI6 (.mobi/.azw): the index's filepos offsets cut the chapters, publisher labels win over h1 echoes. KF8 (.azw3): the chapter index (orthogonal INDX, reached by scanning past FDST + the 0xAA-header skeleton, which the width gate skips) labels the verified flow cut when one entry matches one flow, or cuts at the index offsets gated on flow starts. Also fixed the drift bug: the cut now happens on the RAW stream (the old code cut the PREPARED text at raw offsets — every offset after the first `<mbp:pagebreak>` landed in the previous chapter's tail). DocumentBook's CNCX re-split (re-cutting STRIPPED markup at raw coordinates — garbage-in by construction) removed; the parser consumes the TOC inside `parse` now.
- **RTF: chapter splitting was dead.** Two spec bugs: `\b`/`\i`/`\ul` without a parameter means ON (the spec's toggle rule) but `parameter != 0` read it as OFF — emphasis never latched, no RTF book ever split at bold titles; and `closeGroup`'s formatting-scope merge dropped `isMarked` (the `{\b Title}\par` convention WordPad/calibre write), turning every bold standalone title into a paragraph. Both fixed; `testRTFRoundTrip` pins the exact fixture.
- **Reader TOC tree: the manifest snapshot dropped `depth` (BooksStore, both sites).** `BookTocEntry(label:href:spineIndex:)` omitted the field the reader's drop-down tree reads — every EPUB TOC (real or normalized) stored flat, the tree never rendered, and the backfill's flat-toc condition re-parsed every book EVERY launch forever (the rewrite never satisfied it). Both sites now pass `depth: entry.depth`.
- **Tests: `MobiIndexTests`** — the real-format bytes built byte-for-byte (TAGX numeric pairs, VWIs, CNCX label runs; FDST + 0xAA skeleton + orth INDX for KF8) pin: publisher TOC survives to `MobiBook.toc`, the cut follows it with pagebreaks present (raw-coordinate proof), garbage labels → heading fallback, descending offsets rejected, skeleton width rejected, KF8 count-match labels flows even with junk offsets, count-mismatch + bad offsets falls back to flows. **`DocumentBookRoundTripTests`** — every additional format (md, txt, html, htmlz, fb2, rtf, docx) through the exact import → EPUB → EpubParser loop asserting the reader contract: one spine entry per chapter, TOC labels == chapter titles in order, every TOC href resolves onto the spine, and a book's own NESTED nav keeps its depths (the tree input BooksStore used to flatten). Local box has no Swift toolchain — CI (build.yml on this branch) is the gate; dispatched after commit.
- **OPEN:** device round on Phonon playback (click + gap should be gone; the bridge ledger log line now prints 0.2 s) and on the user's real mobi/azw3 shelf (TOC rows should now carry the publishers' own chapter names).


**Slide decks round 2 — four device reports from the user's real decks, fixed in SlideDeckKit + the reader script (landscape rail untouched)** (branch `batch-c-d-session`, 2026-11-13):
- **Landscape didn't fill the display (PDF/EPUB did; slides didn't; rail minimize changed nothing).** Root cause: the GTK viewer re-pushes the slide fit from a tick callback on every allocation change (slideview.rs `install_resize_tick`); the iOS port called `__snslides.setFit('page', 1)` exactly once at `didFinish` (BookSlidesView.swift) and the script had NO resize listener — the zoom stayed frozen at the size the document loaded with (portrait, rail expanded). Fix: the deck script now re-fits itself on the webview's `resize` event (`applyFit`, skipped in fit 'none' like the Linux reader's manual-zoom skip) — rotation, rail minimize (170→~50pt column), and chrome hide/show all resize the webview, and the zoom follows. Aspect ratio is inherent (`.slide` box scales both axes by one zoom); `body{overflow-x:hidden}` keeps sub-pixel rounding from bleeding. PlaybackRail.swift: untouched.
- **"Presets / beautifying shapes don't render."** Ground truth from the user's own decks (`HIV & TB…`, unzipped): the generated decks are built from text-LESS preset shapes — 0-height rule lines (`prst="line"`, no `txBody`), arrows, alpha-0 decorative blobs — and `build_shape_at_xfrm`'s `guard let text … else { return }` (ported verbatim from the reference, which drops "bare shapes") threw EVERY one away. Fix: a bare plain shape now paints with empty paragraphs (fill/border/radius/preset SVG land; speech unaffected). Verified against the decks: rule-line stroke `#E1E8EE` and the arrow fills now emit.
- **"Symbols don't render."** The decks bullet with Wingdings/Monotype Sorts (`buChar char="l"` + `buFont typeface="Wingdings"` = PowerPoint's ●) and set runs in the Adobe Symbol font — neither `buFont` nor any glyph mapping was ported, so iOS showed raw ASCII letters. Fix: `ParaProps.bulletFont` read from `a:buFont`; `SymbolFonts.swift` ports deckcraft-text's `map_symbol_bullet` tables (Wingdings/W2/W3/Webdings, PUA U+F0xx masked to the low byte) + adds Monotype Sorts, and `mapSymbolText` maps Wingdings-family runs and the Adobe Symbol font's Greek (ONLY the font literally named "Symbol" — "Segoe UI Symbol" carries real Unicode and passes through).
- **TTS/read-along "reads the title last".** `assembleText` spoke file z-order; in these decks the LAST shape is a footer echoing the section name (the header repeats it first), so every slide ended on "the title". Fix: speech now reads in VISUAL order (top→bottom, left→right on ties, 2pt band, stable within a band) with repeated lines spoken once — render order stays z-order, spans keep their item indices so read-along highlighting still lands on the right element. Deliberate deviation from the reference (which speaks z-order too); documented in DeckSlides.swift's header.
- **Colors — audited line-by-line against upstream deckcraft @ a0eeb34 and found faithful** (transforms incl. linear-light tint/shade, resolve chain, `Ctx.color` clrMap mapping, fill/line/effect/gradient CSS emission incl. alpha via `rgba()`, theme parse). One real defect derived and fixed: the gradient angle conversion carried the reference's `90 − angle`, which MIRRORS every non-horizontal gradient (PowerPoint "Linear Down" ang=5400000=90° rendered as CSS 0deg = "to top"); correct mapping is pptx+90° (90°→180deg). The user's decks carry almost no gradients, so if colors still look off on device the next probe needs a concrete slide — candidate suspects are render-level (WKWebView), not pipeline-level.
- **Tests:** the z-order-pinned speech test moved to the visual-order contract (fixture caption at y=28.8pt now reads first; `data-s` offsets follow); new `testBarePresetsAndSymbolsAndOrder` pins all four fixes on a purpose-built deck. Local box has no Swift toolchain — CI (build.yml on this branch) is the gate; dispatched after commit.
- **OPEN:** device round on all four; if colors still read wrong, bring the deck + slide number.

**Slide decks: the app side is CI-verified — first IPA build compiles green; manifest contract pinned by tests; ODP decided** (branch `batch-c-d-session`, 2026-11-12):
- **CI is green on the deck round:** run **43269262140** on `e23fce6`:
  **Build unsigned IPA = success** (the first compile of the blind-written
  app side — BookSlidesView, BookFormat.slides, the BooksStore deck import,
  the per-slide playback all compile against the real SDK), **Logic tests =
  success** (the whole SpeechLogic suite incl. the 5 new manifest round-trip
  tests, on macOS), all spike jobs green — kokoro-small-spike needed two
  reruns (runner capacity cancelled it mid-run once and in-queue once; it
  is informative/continue-on-error by design), then passed. Two earlier
  runs bracket this one: 43265659195 failed Logic tests on the bug below;
  43267588908 was cancelled by the workflow's `cancel-in-progress: true`
  when the next dispatch landed — the discipline from here is one push =
  one run.
- **Round-1 fixes (`0e53a9d`) — what the first CI round caught:**
  DeckTests.swift carried a duplicated `littleBytes` extension pair that had
  been pasted in AFTER the last local docker run (the scratch loop never
  saw it — the repo file and the scratch copy had drifted), plus the
  print-only `testZZDebugDump` scaffolding riding along with it; both
  dropped (deck suite 66 → 65, all green). BooksStore and
  BookPlaybackController used `DeckParser`/`SlideDeck`/`DeckSlides` without
  `import SlideDeckKit` (SpeechLogic does not re-export the module);
  BookSlidesView's script-message coordinator now bridges into the view
  closures through `Task { @MainActor }` — the exact pattern BookWebView's
  coordinator already used. Everything else in the blind-written app side
  compiled first try: the PlaybackRail.Action / BookPlayerBar / ReadAlongView
  shapes copied from BookReaderView were exact, and all the `.slides`
  switch arms were sound.
- **The manifest contract is now tested (`e23fce6`):** `BookFormat` moved
  from the app into the SpeechLogic package (public + Sendable, pure
  Foundation) — it IS the cross-platform manifest contract, and it lived
  where no CI job could reach it. New `BookFormatManifestTests` pin the
  round-trip at the exact boundary: a Linux-written `"pptx"` manifest
  decodes to `.slides("pptx")`, iOS re-encodes it as `"pptx"` (never a
  Swift-only spelling — the Linux `is_slides()` must match the bytes), the
  ppsx/potx/odp family rides along, uppercase normalizes down on read,
  and an unknown format fails the decode loudly instead of shelving a
  husk. Verified locally before pushing: the docker scratch loop
  (/tmp/deckpkg/run.sh) grew a SpeechLogic shim target that compiles the
  exact repo files under the module name CI uses — **70 tests green**
  (65 deck + 5 manifest) on Linux swift:6.0.3.
- **Device-facing sanity pass of the read-path logic:** the JS contract
  between the reader and the deck script checked line by line —
  `__snslides.show/setFit`, the `slidechanged:<n>` and `chromeTap:0`
  message spellings, the `snslides` message-handler name, and the
  `deck://media/<index>/<name>` URL shape (host = `media`, so the scheme
  handler's path split lands on the index) all agree between DeckHTML.swift
  and BookSlidesView's coordinator + scheme handler. What
  CI proves is COMPILATION; runtime behaviour on a device (webview
  rendering, media fetch, speech on a real deck file) is still unexercised
  — that needs the next device sync, not another CI round.
- **ODP DECIDED — keep `"odp"` in `BookFormat.deckExtensions`; the next
  milestone is porting sn-doc/src/odp.rs into SlideDeckKit. Not dropping
  ODP back to the EPUB path.** Why: (1) the rule the user set is "the deck
  is shown as the deck, never converted" — dropping `odp` would put it
  back through `OdpParser` → `DocumentEpubConverter`, the exact
  text-flattening this whole round exists to stop, for one more format;
  (2) the Linux app reads ODP as a deck (odp.rs feeds the same SlideDeck
  model), so an iOS-written `"epub"` manifest for an .odp would disagree
  with Linux's byte contract; (3) the interim failure is honest, not
  silent: the import stamps `importError` ("This ODP could not be opened
  as a slide deck"), the shelf explains it, the reader alerts. (4) The
  port is well-scoped: 1,582 lines / 48 functions, and per its own header
  Impress writes explicit geometry — no placeholder→layout→master chain to
  chase, one-level automatic-style resolution — landing in the same
  SlideDeck model, so DeckSlides/DeckHTML/the reader/speech need zero
  changes when it arrives. The existing SpeechLogic `OdpParser` (text +
  images as EPUB chapters) stays for the normalize path; it carries no
  geometry and is not a shortcut to the deck viewer.
- **Still open (unchanged from the handover):** charts/SmartArt render as
  labelled frames; legacy .ppt refused (not in deckExtensions); SVG-shape
  placeholder geometry simplified to the rect default; no zoom stepper /
  present mode yet; ODP rendering itself until the port lands. Handover
  doc updated to match reality:
  Docs/HANDOVER-SLIDE-DECKS-IOS.md.

---

**Slide decks become a real book format — the read path is ported and locally green; app wiring awaits CI** (branch `batch-c-d-session`, 2026-11-12):
- **The complaint:** "the slides work you did has not worked — they are
  still being converted to epub." True: the M1 port was foundation-only
  (XML + colours + preset geometry, "nothing from the app target touched
  yet"), so a .pptx import still went through `DocumentBook.parse` →
  `DocumentEpubConverter` and opened as an EPUB. The fix, this round:
  **decks are decks** — `BookFormat.slides(ext)` keeps `original.pptx`
  whole, a SlideDeckKit read path (the deckcraft reader + the Linux app's
  slides.rs resolution, ported) resolves every slide to absolutely
  positioned items, and a new deck reader renders them as the Linux reader
  does (one HTML document in a webview, media over a scheme handler, one
  slide = one speech chapter with byte spans).
- **SlideDeckKit grew the reader (7 new files, zero dependencies):**
  Zip.swift (own zip reader with a PURE-SWIFT DEFLATE decoder — `import
  Compression` doesn't exist on Linux, and the local docker loop is how
  this port is verified), Ooxml.swift (OPC parts/rels/content types),
  DeckTypes.swift (the read model; read-model types are `PptxSlide` and
  `BulletSpec` because the resolved model owns `Slide`/`Bullet`),
  DmlRead.swift, PptxRead.swift, DeckResolve.swift (the full placeholder →
  layout → master → theme inheritance), DeckSlides.swift (shape → item
  resolution + assembleText spans), DeckHTML.swift (document.rs +
  script.rs port, `deck://media/N` URLs, `__snslides` API). 66 tests green
  locally (docker swift:6.0, scratch package at /tmp/deckpkg via
  /tmp/deckpkg/run.sh) against an in-memory pptx fixture built byte-by-byte
  (stored entries + a hand-encoded fixed-Huffman DEFLATE block).
- **App wiring (written, NOT yet CI-verified — no iOS toolchain here):**
  BookFormat is no longer a raw-String enum (`slides(String)` with custom
  Codable so Linux-written "pptx"/"odp" manifests decode and ours encode
  back); BooksStore routes the deck family to a whole-file copy + one deck
  parse for slide count/TOC/title (spine "slide-N", byte-compatible with
  the Linux `import_slides`); BookPlaybackController speaks per-slide text;
  BookSlidesView renders the deck (WKWebView + scheme handler + slide
  stepper + TOC + position + read-along swap, all modelled on the EPUB
  reader's chrome); every exhaustive switch gained `.slides`; project.yml
  links the SlideDeckKit product. **Full state + first-CI-round checklist:
  Docs/HANDOVER-SLIDE-DECKS-IOS.md.**
- **Known degradations (documented, honest):** ODP has no ODF reader yet
  (odp.rs is unported — a local .odp import keeps its file but cannot
  render yet); charts/SmartArt render as labelled frames; legacy .ppt is
  refused (stays on the old path); placeholder SVG-geometry inheritance is
  simplified to the rect default; no zoom stepper/present mode yet.

---

**Slide-deck port M1 started: SlideDeckKit (XML + colors + full preset geometry) lands green** (branch `batch-c-d-session`, 2026-11-11/12):
- **New package target `SlideDeckKit`** (Package.swift: product + target, zero
  dependencies — the deck stack must not drag COpus/cmark into its importers)
  carrying the DeckCraft port (github.com/storytold/deckcraft @ a0eeb34,
  MIT/Apache-2.0) approved in HANDOVER-SLIDE-DECKS.md. Five commits, five CI
  rounds, final green run **43108442304** on `416baac` (all 7 jobs OK incl.
  logic tests): XML DOM + colours `42254fe`, preset geometry `676f4a5`,
  operator/IEEE-max syntax fixes `52aa0f9`, scanner declaration-skip fixes
  `de6b75d`, test-helper sub-path semantics `416baac`.
- **XML.swift** — the bounded XML DOM from pptx/src/xml.rs, scanner hand-rolled
  over UTF-8 bytes because quick-xml semantics must hold exactly: a literal
  CR/CRLF folds to LF while a `&#13;` reference stays a CR (XML 1.0 §2.11 —
  the reason Foundation's XMLParser was rejected), attribute values normalize
  literal whitespace but keep reference-resolved whitespace, attributes match
  by local name (xmlns decls never match), depth 256 / 4M nodes bounded,
  truncated docs fold up, bare `&` is literal text. XNode deliberately NOT
  `indirect`: recursion passes only through XEl.children (an Array, heap
  -backed) — the exact shape of the Rust `Vec<Node>`, no per-node boxing.
- **Bugs the CI loop caught (no local toolchain — every round's failures were
  diagnosed against a byte-faithful Python simulation of the scanner before
  the next push):** pre-CI re-reading caught missing Foundation imports, CDATA
  /comment needles compared at the `!` byte instead of `<`, `stack.last`
  mutation through an immutable struct binding, and a dropped start letting
  its end tag pop its PARENT (over-limit subtrees now skip whole via a
  skip-depth counter). CI rounds then found: Rust-style `u8` literal suffixes
  and an XEl Equatable comparison in tests (round 1); `static prefix func -`
  required for unary minus, `.hypot`/`abs` are not Double instance members,
  kurbo's `f64 * Vec2` needed a scalar-on-left `*` overload, and
  `.maximum`/`.minimum` are STATIC members on this toolchain — replaced with
  rustMax/rustMin implementing Rust's f64::max/min NaN semantics (round 2);
  **decimal character references accumulated base 16** (`&#10;` → U+0010,
  `&#65;` → 'e'), the comment skip pointed pos AT the `-->` instead of past it
  (every `-->` leaked into text), CDATA content start off by one, and PI/
  DOCTYPE skips never consumed their closers (both leaked `?>`/`>` as text;
  DOCTYPE now honours an internal subset) (round 3); and the preset test
  helper measured only paths[0] where the Rust `on_path` checks ANY sub-path
  (the magnetic disk's checked point lives on its top ellipse, paths[1]) —
  the ported geometry itself was correct, proven at distance 0 in the
  simulation (round 4).
- **Color.swift** — sRGB `Rgba`, the twelve scheme slots + phClr, the DrawingML
  transform set (linear-light tint/shade, HSL lum/sat/hue mod+off, alpha
  family, comp/inv/gray, channel mods), preset colour names. Editor surface
  (picker grid, standard-colour rows, 190-name preset enumeration) not ported.
- **Preset geometry, the full read-path surface** — Geom.swift (kurbo
  stand-ins DPoint/DVec/DRect/DAffine, GeomPath with `toSVG()` byte-matching
  kurbo's format — shortest round-trip, plain decimal, Rust `Display` rules;
  adaptive flattening for bounds/area/point-distance; EMU↔pt; Xfrm; kurbo
  0.13.1's Arc→cubic approximation ported bit-for-bit so arc-heavy shapes emit
  the reference's exact control points), PresetCatalog.swift (184-entry
  CATALOG + defaults, mitredByDefault, isLineLike), PresetShapes.swift (Pb
  builder + the whole build() switch: corner rects, stars, pie/chord/arc, sun/
  moon, cloud arcTo tables, equation shapes, block arrows, flowcharts incl.
  multidocument's outline-where-visible, ribbons, scrolls, action buttons,
  connectors), PresetShapesExtra.swift (callouts, curved/circular arrows,
  ellipse ribbons, gears, funnel, swoosh). Handles and glue sites dropped
  (editor-only, per the approved decision). The viewer renders preset shapes
  as ONE `outline().toSVG()` — verified against sn-doc's shape_svg consumer.
- **Tests ported from the Rust geometry suites** (PresetTests.swift): every
  catalog preset builds within bounds at five sizes; hostile adjusts
  (NaN/inf/±1e12/±Double.max ×8) never break a build; ECMA-376 fixed-shape
  coordinates; PowerPoint-outline reference points for ~30 shapes (equation
  shapes, sun, waves, stars, moon, cloud, braces, callouts, curved/circular
  arrows, gears, swoosh, ribbons) — distances over a 1e-4 flattened outline
  across all sub-paths; arc-spec direction semantics (the DrawingML
  visual→parametric mapping); areas; EMU roundtrip; Rust-Display number
  formatting. XMLColorTests pins the scanner contract (CR distinction,
  attribute normalization, local-name lookup, entity bases, bounds, truncation
  folding, UTF-16 parts) and the colour math. Once the 4M-node cap trips the
  counter never recovers, so post-cap elements drop — documented and pinned by
  test (the Rust reader errors the whole part instead).
- **Next (M1 continues):** model types + resolve.rs port (`Model.swift`,
  `Resolve.swift`, `Theme.swift`, `Style.swift`, `DMLText.swift`, `Table.swift`,
  `ChartModel.swift`, `Defaults.swift`, `NumFmt.swift`) → Zip.swift (own copy
  of the zip reader, per decision) → pptx read (OPC/CFB sniffer/read modules)
  → ODP → slides.rs resolution → in-memory pptx/odp fixtures. Nothing from the
  app target touched yet.

---

**Web import: flat-paragraph root cause found + fixed, bypass on every import, hang-proof pipeline** (branch `batch-c-d-session`, 2026-11-10):
- **Why EVERY article imported flat (no headings/links/images):** the
  vendored Readability 0.5.0 returns `parsed.content` as an HTML STRING
  (its default serializer is `el.innerHTML`), but the extraction JS handed
  it to the markdown walker as if it were a DOM node — `.documentElement`/
  `.body` on a string are undefined, the walker saw a string with no
  childNodes, and emitted `''` on every page. The Swift cover-rule then
  discarded the empty markdown, so every import fell back to textContent.
  Verified live against Guardian/Ars/NYT/Wired/Apple (0 markdown chars
  everywhere, pre-fix). Fix: re-parse `content` with DOMParser before
  walking (Docs/WEB-ARTICLE-IMPORT.md documents the contract). The mock
  suite never caught it because its fake parse() returned a node.
- **Walker image fixes (live-verified: Guardian hero, Ars hero, Wired
  hero + avatar, NYT hero + caption now all import):** Wired's
  `P > SPAN > PICTURE > IMG` died at `case PICTURE: return ''` — the img
  inside was never reached; `<picture>` now resolves to ONE image (the
  `<img>` inside, else a `<source>` srcset). `data-src`/`data-lazy-src`/
  `data-original` go before a placeholder `src`; `srcset`/`data-srcset`
  fall back to the largest candidate. Junk paragraphs ("Advertisement",
  caption toggles, including link-wrapped `[SKIP ADVERTISEMENT](…)`) drop
  whole. Walker suite grew 46 → 53 assertions, all green.
- **Why imports could hang FOREVER (the "completely failing" report):**
  `evaluateJavaScript` has no internal timeout — a page suspended in the
  background never answers, the pipeline never returned, and
  `isFetchingArticle` stuck true, refusing every later import with
  "Already fetching an article…". The extraction now races the JS answer
  against a 15s claim-guarded continuation (WebKit's completion + a
  detached timeout, exactly one resume wins — a task-group race would
  drain the group and hang anyway). NotesListView also gains a
  legacy-tag-strip fallback before "saved the link".
- **BPC on EVERY import (default ON):** the heuristics no longer gate the
  bypass pass (a wall that kept its markers out of the HTML sails past
  them) — every import goes fetch → BPC, `bypassResultWins` picks the
  fuller text (+150-char margin or direct-stub). Toggle moved to
  Appearance → Web Import; the always-bypass domain list is GONE (user
  call: unnecessary). Heuristics stay as the log/diagnostic signal.
- **project.yml:** the duplicate `NSAppTransportSecurity` keys (one per
  feature since v1.6.1/1.8.0) let the web-import dict silently overwrite
  the BookDrop dict — merged into one dictionary carrying both
  `NSAllowsLocalNetworking` and `NSAllowsArbitraryLoads`.

---

**Phonon engine integration** (branch `batch-c-d-session`, 2026-11-10):
- **The engine**: Gradium's Phonon (31M-param English streaming TTS,
  Apache-2.0) via `onnx-community/phonon-31m-en-ONNX` — the app's 4th neural
  engine and the smallest (~192 MB vs Kokoro's 341 MB): one fp32 flow
  transformer (causal, KV-cached, 8 unrolled AR frames per call) + a
  STATELESS Mimi codec decoder, Unigram tokenizer with byte fallback, and
  precomputed voice embeddings (no audio encoder — no cloning, no G2P).
- **The hub docs lie.** The README documents an older export (`flow_lm.onnx`
  names, a stateful per-frame decoder, `text_ids`/`voice_latents`/`latent`
  input names) and the transformers.js PR #1811 driver targets that OLD
  export — PR closed, unmerged; main has no Phonon support. The current
  tree exports `model.onnx` + external data with different input names
  (`input_ids`, `audio_prompt_latents`, `attention_mask`, `position_ids`,
  per-layer `past_key_values.{0..5}.{key,value}`, noise `[1,8,32]`) and the
  contract was therefore pinned **empirically** by running the actual fp32
  graphs with Python ORT 1.24.2 (the exact version the app vendors) before
  any Swift: `Docs/PHONON-PORT.md` carries the full recipe. Load-bearing
  discoveries the docs would never have given: attention_mask must be
  `past_kv + P + 7` long (each unrolled frame slices it); the BOS latent is
  prepended IN-GRAPH so `input_ids` is text-only; `audio_latents` out is
  CUMULATIVE (denormalized — the decoder takes it directly) while
  `present.audio_latents` is the normalized history fed straight back; the
  voice `.bin` is [1,512,125] and needs a TRANSPOSE (a reshape silently
  mangles the conditioning — the first EOS run went catatonic at −5 until
  this was fixed); the decoder's rotary ceiling limits one decode call to
  ~500 latents (the engine windows at 400); the KV feedback keeps the
  latent K/Vs and drops the re-run prompt block.
- **Validation**: with the pinned recipe the reference sentence reaches EOS
  (logit > 4.0), decodes 24 kHz PCM, RTF ≈ 0.27 CPU on the Linux box.
  `Tests/PhononSpike` (new CI job, informative like the others) re-runs the
  SAME recipe in Swift against the vendored SPM binary — the com.microsoft
  contrib ops (GroupQueryAttention, RotaryEmbedding, QuickGelu) are the
  load-bearing question that only that binary answers.
- **Tokenizer**: `SpeechLogic.PhononTokenizer` — the hub's 191-step
  normalizer chain is GENERATED data (`PhononNormalizerTable.swift`, via
  `Scripts/gen-phonon-normalizer.py`; Rust `\uXXXX` escapes translated to
  ICU `\x{...}`), then Metaspace + a byte-lattice Unigram Viterbi (byte
  fallback only where no piece matches — HF's lattice rule). 14/14 fixtures
  verified against the reference `tokenizers` implementation (fixture =
  the hub tokenizer.json, expected ids generated from it). The audio
  control tokens (<|audio_bos|> 4/5/6) are excluded from matching so user
  text can never inject them.
- **App wiring**: `PhononEngine` (StreamingTTSPlaybackCore shape, per-sentence
  fresh KV state, voice cache single-slot); `EngineKind.phonon` (picker
  order: system, kokoro, phonon, supertonic — labeled compact English, no
  quality claim); ModelManager Phonon set (26 curated voice bins: default +
  12 en-us + 13 en-gb from voices.jsonl); settings/storage/voice-picker
  surfaces; `phonon-fp32` Benchmark tier for the device RTF round. Single-
  slot memory rule applies (sessions release on engine switch + 5-min idle
  unload). fp32-only v1: q4 needs MatMulNBits proven on the vendored ORT;
  fp16 stays banned (every engine's fp16 sibling has NaN'd on ORT CPU).
  CoreML EP banned (a 6-layer KV-cache transformer is exactly the graph
  class whose EP parity Kokoro proved broken — round-3 stands).
- **Known limitation, documented in the settings footer**: the speed slider
  does nothing for Phonon (the flow export baked its duration conditioning
  into a constant — no speed input). Currency (`€5.50` reads in dollars)
  and emails (`@` skipped) inherit the hub's documented text-prep gaps.
  Device round: by-ear quality + RTF vs Kokoro, benchmark tier ready when
  there is time.
- **CI outcome (9 rounds, 7ab6aba — logic tests + app archive + phonon
  spike all green; one EPUB-spike job lost to runner capacity, an infra
  flake unrelated to the changes):** the compile rounds caught what the
  prototype missed — `String(bytes:encoding:)` takes String.Encoding;
  `session.run(outputNames:)` is a Set; a bare `init()` on an NSObject
  subclass needs `override`; the engine's tensor plumbing had lived only
  in the spike; HF's Prepend skips EMPTY strings (whitespace-only text →
  `[]`, verified against the reference). Two REAL contract finds the spike
  proved on the vendored binary: the cumulative `audio_latents` row count
  follows the latent-history feedback (+8/call) while KV grows +7 (the
  prompt never lands there) — two counters the engine must not confuse;
  and EOS crossing is noise-dependent (same sentence: crossed at call 20/26
  with one seed, never crossed with another) → the engine runs the hub's
  frame budget ×1.5 and logs when even that truncates. Memory: the decoder
  costs ~2.7 MB RSS per latent (400-latent window = +1.1 GB — jetsam
  territory), so the window is 160 and real chunks decode in ONE call.
  Spike finals: load +178 MB, RTF 0.309 (macOS runner), rms 0.0397 —
  audible; the A14 numbers come from the device round.

---

**E-Ink appearance mode** (branch `batch-c-d-session`, 2026-11-10):
- **One new mode, app-wide effects.** Settings → Appearance → Theme gains
  "E-Ink" (4th segment beside System/Light/Dark): paper white, ink black,
  square edges, hairline borders — no glass/materials, no gradients, no
  color, no animation or transitions anywhere. The accent picker does not
  matter while the mode is on (ink is ink) and its hue returns the moment
  the mode is left.
- **Plumbing** (`AppTheme.swift`, new `Views/EInkSupport.swift`,
  `SpeechnotesApp.swift`): `AppearanceMode.eink` forces the light scheme;
  `isEInk` rides the environment (`\.isEInk`) for inline view swaps; the
  root applies `.transaction { animation = nil }` (every SwiftUI animation
  snaps) + `.grayscale(1.0)` (every hardcoded tint drains) +
  `.buttonBorderShape(.rectangle)`; `EInk.applyChrome(enabled:)` flattens
  the UIKit tab/nav bars to opaque paper with 1pt ink hairlines and calls
  `UIView.setAnimationsEnabled(false)` (push/pop, sheets, keyboard — the
  UIKit-level motion SwiftUI can't reach). Called at app init so relaunch
  into the mode doesn't flash stock chrome.
- **Notes section (the flagship)**: notebook chips go square (active =
  solid ink block, inactive = paper + hairline); the list renders flat
  full-width rows with hairline separators (`.einkListStyle()`); swipe
  tints go ink; pin/star lose orange/yellow for black; the slash menu,
  formatting bar and markdown preview (quotes, code blocks, tables) square
  off and print-style.
- **Shared one-liners** so the sweep didn't bury files in if/else:
  `.einkPaper { regular }` (square paper tile + hairline),
  `.einkInk { regular }` (solid ink block), `.einkCard(radius:style:)`
  (rounded card squares off), `.einkClip(cornerRadius:)` (square content
  clip). ~30 view files swept: mini-players and bubbles (material pills →
  paper slabs, ring trims → ink), playback rail (portrait + landscape),
  toast, books shelf, stats cards/heatmap/chart, reading goals, pomodoro
  (timer card, banner), storage gallery, onboarding, PDF reader chrome,
  web-article surfaces.
- **EPUB reader** gets its own `eink` page theme (reader.js THEMES:
  `#ffffff`/`#000000` — pure ink, full contrast, nothing softened) plus
  the sheet entry and the chrome/page color maps.
- **Honest limits**: system sheets/alerts/keyboard keep iOS's rounded
  chrome (light + grayscale only); the "generating" spinner still spins;
  PDF reader page surface untouched (PDFKit). All animations die at the
  root transaction — no view logic changed, so leaving the mode restores
  the stock look bit-for-bit.

---

**Web article formatting + native share sheet** (branch `batch-c-d-session`,
2026-11-10):
- **Root cause of the flat-paragraph imports** (`Docs/WEB-ARTICLE-IMPORT.md`):
  extraction consumed only Readability's `textContent` — structure was
  stripped before the note ever saw it. The renderer stack below (cmark-gfm
  `MarkdownPreviewView`, `MarkdownText.plainText` for TTS) was already
  complete; nothing fed it.
- **The walker** (`App/Resources/JS/html-to-markdown.js`): Readability's
  `parsed.content` DOM → the app's GFM subset, injected beside readability.js
  at document end. Headings shift down one (the note's first line IS the
  headline, which the walker also de-dupes), links resolve http(s)-only
  against the live page base, sigils in prose are escaped, data:/tracking
  images and JS/mailto links degrade to text. A walker bug costs formatting
  only — the Swift side keeps markdown solely when it plausibly covers the
  same text, else falls back to plain. 46-assertion mock-DOM suite
  (`Scripts/test-html-to-markdown.js`) runs in CI's logic-tests job.
- **Import paths** prefer `markdown ?? text` (URL shares, clipboard, drag &
  drop, scheme, local .html); the first article import opts
  `renderMarkdown` ON only when the user never touched the setting.
- **ShareExtension target** (`com.speechnotes.ios.Share`, project.yml +
  `ShareExtension/Sources/ShareViewController.swift`): the share sheet the
  native install never had. Pages (public.url) and text; hands off via
  `speechnotes://import?url=/text=` (no App Group — free-account SideStore
  provisioning stays intact); `NSExtensionContext.open` → responder-chain
  `openURL:` → honest fallback (copy + clipboard-importer instructions).
  LiveContainer ignores the embedded `.appex` and keeps its extension-free
  channels. Extension version fields derive from the app's build settings
  (`$(MARKETING_VERSION)`) so release bumps stay a two-file edit.

---

**Phase 3 baseline CAPTURED (first device numbers in repo history)** (branch `batch-c-d-session`, 2026-11-09/10):
- Six 5-minute sustained-synthesis sessions ran on the device (iPhone13,4,
  iOS 27.0, app 1.8.1/47, thermal `serious` throughout — no cooldown); raw
  CSV+JSON archived in `Docs/benchmarks/2026-11-09/`, results in
  `TTS_BASELINE.md` §8. Headlines: Kokoro fp32 sustained RTF 0.553 hot,
  drifting +30 % inside 5 min, 0.683 mean with the throttle signature after
  ~25 min of prior synthesis; **Supertonic High faster AND flat (0.527,
  0.49→0.53)**; compact int8 SLOWER than fp32 (0.812); 4 threads cost +14 %
  vs 6; Kokoro tokens 101–179 → Phase-2 buckets collapse to {128, 192};
  chars/audio-s measured 19.5 (Kokoro, vs the 15 assumed) / 12.7 (Supertonic).
- Harness defect found by the very first runs: the sampler timer and the
  stop flag both sat on the serial queue the synthesis loop occupied —
  resource columns absent from these exports, stop never fired mid-loop.
  Fixed (dedicated sampler queue + NSLock + thread-safe stop). Per the user's
  2026-11-10 decision: **no re-run** — the CPU %/footprint/memory-budget
  numbers stay open until the first Core ML build reports them in-app.

**Hybrid CPU+ANE plan, Phases 1–3** (branch `batch-c-d-session`, 2026-11-09):
- **Phase 1 postmortem** (`Docs/POSTMORTEM-KOKORO-ACCELERATION.md`): the git
  history contains NO literal Core ML attempt for Kokoro — the "Core ML failed"
  memory compresses the MLX/Metal engine (ran at RTF ≈ 0.5, died of jetsam:
  unbounded GPU-cache + buffer growth, 342 MB fp32 resident; removed v0.7.0)
  and the quantized-tier graveyard (uint8 corrupt via QLinearMatMul graph
  rewrite; fp16 NaN on ORT CPU, CI 34008548349; int8 92 MB clean and shipped).
  WhisperKit/CoreML STT worked. Failure classes (a)/(b)/(c) mapped; hypotheses
  H1–H4 carried forward with falsification vehicles.
- **Phase 2 placement** (`Docs/PHASE2-OP-INVENTORY-PLACEMENT.md`): both ONNX
  graphs parsed from the user's local model store (Kokoro fp32 byte-exact to
  the CI pin). Kokoro: 49 op types, 6× bi-LSTM(256) + 1 STFT + sampling glue
  stay CPU in every variant; the istftnet decoder holds 193 MB (60 %) of
  weights — the ANE prize; choice = try ORT CoreML EP first, manual decoder
  split as fallback. Supertonic ×4: pure ConvNeXt+attention, ZERO hostile ops
  → direct coremltools MLProgram fp16 conversion. Buckets {64…510} tokens,
  pre-warm + `SpecializationStrategy=FastPrediction`, int8/palettization only
  behind the uint8-forensics-style parity gate. **H1a ANSWERED twice**: ORT's
  Apple pod release settings pass `--use_coreml`, AND the downloaded
  `pod-archive-onnxruntime-c-1.24.2.zip` ios-arm64 binary contains the full
  `CoreMLExecutionProvider` (GetCapability/Compile, MLComputeUnits,
  ModelCacheDirectory, `setSpecializationStrategy:` selector) — the EP ships
  in the SPM binary the app already links. **RAM question answered**: no
  runtime API; `com.apple.developer.kernel.increased-memory-limit` exists but
  free-profile signing strips it (SideStore #1616) and under LiveContainer it
  must ride on the LC host; the controllable lever is dirty memory (fp16,
  single-slot, idle-unload, memory-warning shedding, MLX removal — catalog
  1.11), now measured via `os_proc_available_memory` + phys_footprint.
- **Phase 3 harness** (`Docs/PHASE3-BENCHMARK-HARNESS.md`, code in
  `App/Sources/Benchmark/` + `SpeechLogic/BenchmarkMath.swift` + benchmark
  seams on both engines): sustained-synthesis Benchmark Mode — fixed original
  corpus (sha256-stamped), per-chunk CSV (tokens/steps, gen/audio/RTF,
  footprint, available, CPU %, thermal) + session JSON (provenance, RTF
  temporal quartiles + throttle signature, CPU-seconds, battery start/end,
  thermal transitions), share-sheet export. Settings → Diagnostics →
  Benchmark mode; "run at next launch" replaces launch args on device;
  `-BenchmarkAutoStart` for CI. Engine knobs: tier (fp32/int8/super-high/
  super-balanced), duration, ORT thread override (new `benchmarkIntraOpThreads`
  seam; Supertonic's sessions previously had NO thread cap — ORT default —
  now overridable via a default-parametered vendored `loadTextToSpeech`).
  Silent audio loop holds background assertion for screen-off runs. Pure
  math + CSV in SpeechLogic with tests (BenchmarkMathTests). **The baseline
  device run on the current CPU build is the next action** — protocol in the
  doc; no Core ML work proceeds before its numbers exist.

---

**Web article import + Bypass Paywalls Clean** (branch `batch-c-d-session`, 2026-10-24):
- **Shared URLs are articles now, not tag soup.** `WebArticleService`
  (new): fetch with a Safari UA → Mozilla Readability 0.5.0 (vendored,
  Apache-2.0) on the fetched HTML inside a headless WKWebView → note with
  title/byline/source footer. JS app shells get a plain rendered pass.
- **Paywalls route through BPC.** `PaywallHeuristics` (SpeechLogic, new,
  9 unit tests in the CI `swift test` job) gates it: high-precision wall
  markers (soft-wall copy, `isAccessibleForFree:false` JSON-LD,
  news-corp `gateway-partial`, og:description-vs-stub truncation). On a
  hit — or an always-bypass domain, or a failed fetch — the page loads in
  a fresh ephemeral webview with the userscript form of Bypass Paywalls
  Clean by magnolia1234 vendored (`bpc.en.user.js` v4.4.7.4 + its
  `@require` companion `bpc_func.js`, MIT). Its one privileged API,
  `GM.xmlHttpRequest`, bridges to URLSession via
  `webkit.messageHandlers.bpcFetch`; everything else (cookie/localStorage
  surgery, archive fallbacks) runs in-page on the clone-at-extract DOM.
  Settle window counts bridge traffic, so BPC's post-load archive fetches
  finish before extraction.
- **Script refresh without a rebuild:** drop updated
  `bpc.en.user.js`/`bpc_func.js` into On My iPhone → Speechnotes →
  BypassPaywalls (Files-app visible) — they override the bundled pair.
  Settings → Web import carries the toggle, the always-bypass domain
  list, and the loaded script's version/origin.
- **Local .html files** import through the same Readability path (no
  fetch), DocumentBook's flattener as fallback. The note Files picker now
  offers every document format `canImport` accepts (docx/pptx/odt/rtf/
  html/mobi/azw3/… — the picker previously greyed them out even though
  Open-In delivered them).
- Import UX: "Fetching article…" toast for the multi-second pipeline;
  legacy regex stripper demoted to last-ditch fallback; bare-URL note
  still never lets a share vanish.
- Version 1.8.0/44. **Device test pending** (paywall sites + a couple of
  JS-shell pages); CI green required before any sideload.

---

**Audiobooks + session robustness** (branch `batch-c-d-session`, 2026-09-21):
- **No retry.** `generateWithRetry` is deleted from the streaming core. A chunk
  that throws is logged once (with its index out of the total), sounded with
  `BeepPlayer.playSkipTone()` and stepped over — for playback and WAV export
  alike. This is the R8 anti-pattern (AP7, "error handling worse to experience
  than the error") finally closed by removing the retry rather than tuning it.
- **`SpeechSanitizer`** (SpeechLogic, new): `clean()` strips what a reader
  cannot pronounce — C0/C1 controls, zero-width and bidi controls, variation
  selectors, private-use glyphs — and normalises whitespace. Two rules the CI
  loop forced: replace rather than delete (`exam\u{00AD}ple` must not become
  `example`), and U+2028/U+2029 plus a lone CR are line breaks, not spaces.
  Wired into `MarkdownText.plainText`, `XhtmlText.extract`,
  `PdfText.normalize`, every note/book speak path through the new `SpeechText`
  helper, `ImportService`, and the chapter cache write.
- **`AudiobookChapters`** (SpeechLogic, new): reads `chpl` inside `moov` and
  ID3v2.3/2.4 `CHAP` frames, bounded (an 8 MB head slice, never the whole
  file). `Book` gains `.audio`, `BookAudioReaderView` + `AudioBookPlayer` play
  it with no `SpeechPlayer` involvement, its own lock-screen surface, and
  chapter resume.
- Chunker hardening: a piece under 4 UTF-16 units with nothing to say is glued
  onto the piece before it. Nothing is dropped — the reconstruct invariant
  (chunks concatenate to the original) is what the read-along and resume index.
- **CI loop history worth recording:** six red runs, every failure a real
  defect rather than a typo — `Set<Unicode.Scalar>` array literals reject Int;
  a dangling helper call; a fixture that wrapped `chpl` raw instead of as a
  box; piece-dropping that broke reconstruct; U+2028 treated as a space; a
  lone CR joining two lines; `[weak self]` in a struct. Full writeup in
  `Docs/PLAN-AUDIOBOOKS.md`.
- **Device test pending.** CI green (logic tests + unsigned IPA + all four
  spikes); nothing merged to `sage-upgrades` and no release.

---

**Batch 5 — Accessibility sweep** (branch `fix/a11y-labels`, merged @ `4d83a3e`):
- MarkdownFormattingBar's 13 icon buttons labeled; MiniPlayerBar play/stop; PlayerControlsBar play/stop/read-along + rate slider label + value.
- No visual change; VoiceOver goes from "button" ×13 to named controls.
- CI: green (34293436652).

---

## Cycle summary

6 batches → all ≥8/10 critique, all CI green, zero escalations:

| Batch | Scope | Merge | CI run |
|---|---|---|---|
| 0 | TTS pipeline regressions (quit-bug, retry-storm, live-rate, load-latch, audio session init) | 4d7286e | 34242349583 ✅ |
| 1 | BooksStore race, zip-bomb bound, image-sniff brand, SystemEngine epoch | f9e56bd | 34248407439 ✅ |
| 2 | Sleep timer, lock-screen subtitle + cover | b3455b5 | 34289888739 ✅ |
| 3 | Joplin JEX export + 6 unit tests | 78ff6e3 | 34291148672 ✅ |
| 3b | Note share as MD/TXT/PDF | c1b8a7f | 34292710925 ✅ |
| 4 | EPUB mid-chapter CFI restore (M20) | cd0b6f8 | 34292066132 ✅ |
| 5 | A11y labels | 4d83a3e | 34293436652 ✅ |

## Deferred (documented for next cycle)
- True playback queue (replaces onNaturalFinish chain) — scope, not a stuck task.
- Per-chapter % on lock screen — content isn't seconds-addressable.
- In-book search, highlight model, translation — sequenced after CFI restore shipped.
- `AVSpeechSynthesisProvider` system-voice extension — high complexity, high value; needs its own phase.
- M22 ModelManager HEAD-size check; M25 Supertonic Helper force-unwraps.

## 2026-09-08 (late) — Batches delivered and merged

**Batch 0 — TTS pipeline regressions** (branch `fix/playback-pipeline-regressions`, merged to `sage-upgrades` @ `4d7286e`):
- Retry storm fixed: 3 retries + 0.5 s silence → 1 retry + skip. No more 30–90 s dead air per bad chunk.
- Player no longer traps on engine switch: new speak floods the old pacing gate.
- Live rate changes (M14): speed slider reaches the next chunk without restart.
- Load latch fixed (M16): transient load failures no longer brick the engine until relaunch.
- Audio session lazy init (kills OSStatus -50 spam on cold start).
- CI: green (34242349583).

**Batch 1 — Data-layer races** (branch `fix/books-store-race`, merged @ `f9e56bd`):
- M18 BooksStore last-writer-wins (monotonic seq + drop stale write).
- M23 ZipReader 100 MB safety cap.
- M24 Image sniffing distinguishes HEIC from MP4 by brand.
- M15 SystemEngine epoch guard.
- CI: green (34248407439).

**Batch 2 — Sleep timer + lock screen** (branch `feat/playback-queue-sleep-lock`, merged @ `b3455b5`):
- Sleep timer (5/15/30/60 min + "end of chapter" for books). End-of-chapter swallows the natural finish and keeps the bookmark so resume lands past the end.
- Lock-screen subtitle ("Ch N — Title") + cover art ride out via `SpeechPlayer.NowPlayingPayload`, so the between-chapter "Loading…" state doesn't blank the metadata.
- Critique: 9/10 (no per-chapter % on lock screen — deferred; content isn't seconds-addressable).
- CI: green (34289888739).

**Batch 3 — Joplin JEX export** (branch `feat/note-export-jex`, merged @ `78ff6e3`):
- `SpeechLogic.JexExport` — pure-Swift ustar writer; `<noteId>.md` entries with metadata footer (`type_: 1`), `<notebookId>.md` with `type_: 2`, `<resourceId>.md` + `resources/<id>.<ext>` for images (`type_: 4`).
- Independent reimplementation per Joplin format docs — no AGPL code.
- 6 unit tests in `JexExportTests` (tar framing, entry names, type_-last invariant, orphan-note drop, resource round-trip, UTC ISO).
- Settings → Backup → "Export notes to Joplin (.jex)".
- CI: green (34291148672).

**Batch 3b — Note share formats** (branch `feat/note-share-formats`, merged @ `c1b8a7f`):
- Editor overflow menu: Share as Markdown (raw source), Share as plain text (`MarkdownText.plainText`), Share as PDF (UIMarkupTextPrintFormatter + UIPrintPageRenderer).
- Reuses the share sheet that WAV export already presents.
- CI: green (34292710925).

**Batch 4 — EPUB mid-chapter restore** (branch `feat/epub-cfi-restore`, merged @ `cd0b6f8`):
- epub.js reader now publishes the CFI on every relocation and accepts `?cfi=` at shell-load (preferred over the chapter index when present).
- `BookPosition.cfi: String?` persists the CFI; legacy manifests decode cleanly.
- Reopening a book mid-chapter now restores the exact spot, including across font-size changes and rotations (M20 / 4.7 prerequisite).
- CI: green (34292066132).

**Batch 5 — Accessibility sweep** (branch `fix/a11y-labels`, CI running):
- MarkdownFormattingBar's icon-only buttons labeled (bold/italic/strike, H1/H2, lists, quote, code, rule, link, image) — VoiceOver no longer reads "button" 13 times.
- MiniPlayerBar play/stop labeled; PlayerControlsBar play/stop/read-along + slider labeled.
- No visual change.

---

## Escalated items

None. (Batch 2's skip of a true playback queue is a scope decision, not a
stuck task — deferred to a later round once CFI work lands, at which point a
proper queue becomes both needed and testable.)

## References
- `FEATURE_BACKLOG.md` — full prioritized list from the 8 reference repos.
- `INTEGRATION_PLAN.md` — phase plan, dependency graph, license fence.
- `UPGRADE_AUDIT.md` — codebase map + open findings.

## [2026-09-10 ~11:20Z] Batch A — Phase 0 deliverables + instrumentation
- Pushed: `070d38f` (docs commit pending: TTS_REGRESSION_AUDIT.md, this log, CRITIC_REVIEWS.md)
- CI: logic-tests ✅ 52s · build-ipa ✅ 6m57s — run 34468296292, all 6 jobs green (third consecutive sub-7-min build; the 45-min premise is retired, see TTS_BASELINE §7)
- Critic Round 2: Score 8/10 (approved). Round 1: 6/10.
- Issues found: Round 1 B1–B6 (stall watchdog false positives, timer leak, gap misclassification, metrics on critical path, commit-message overclaim); Round 2 N1–N6 — including two defects introduced by Round 1 itself (stall-tick reset gating, clearance-gate volume)
- Issues fixed: all of B1–B4, N1–N6. B5 recorded in CRITIC_REVIEWS.md (immutable commit message). B6 accepted as designed.
- Next action: commit the three docs, then Batch B (resume resurrection — prime-after-read in both branches, debounce→throttle, resumeIfBookmarkPending markdown fix, readAlongPiecesTask assignment + generation bump in the fast path)
- TTS baseline impact: **slower by~10⁻⁵ of measured work** (the one exception to the no-regression-by-removal rule, accounted line-by-line in TTS_BASELINE §6, with the thinning that keeps a 1300-chunk chapter at ~64 log lines)
- O5 decision recorded: README stays at v1.5.0 — 1.5.1/31 is a diagnostic build number, and the release procedure (README refresh + tag + fast-forward) is reserved by constraint
- O7 deferred to Batch C: PlaybackMetrics testability needs SpeechLogic reachability or an app test target; rides with the chunker contract tests

## [2026-09-30] v1.7.2 — Reader appearance, Stats, BookDrop, office formats

Batches pushed to `sage-upgrades` per batch; every batch rode its own CI run
(several CI-fix rounds: `@MainActor` isolation on StatsCenter,
`XMLParser.parserError`, `SHA256.Digest`/static-member quirks — CI is the
compiler, there is no local Swift toolchain on the Linux box).

**Batch A — Reader appearance v2** (`76bc0d1`):
- Page flow: Scroll/Pages switch (epub.js flow is fixed at rendition
  creation → the shell webview rebuilds; position survives via
  lastKnownCFI, one relocation fresher than the manifest).
- Auto-scroll: rAF loop in reader.js, advances chapters at the bottom
  (dwell-guarded), speed slider, resumes across flow reloads.
- Typography: font family (book/serif/sans/mono), line height, paragraph
  + letter spacing, scrolled-only margins, respect-book-styles switch;
  one merged theme registered+selected per apply; true-black theme.
- Appearance rides the shell URL at creation and one
  `readerAppearance({...})` JSON command afterwards (`ReaderAppearance`
  owns both encodings).

**Batch B — Stats tab** (`51393f2`):
- `StatsStore` (SpeechLogic): per-day/per-subject/per-kind folded JSON
  rows; windowed queries, streak, active days; UTC-calendar injection for
  deterministic tests.
- Recording: reading time from the epub/PDF readers (scenePhase-aware);
  listening time derived from the players' published state via
  `StatsCenter` (TTS slot for read-aloud books + notes, audio slot for
  audiobook files) — zero hooks inside the playback engines.
- `StatsTabView`: 4th tab — Fitness-style header cards, Swift Charts bars
  (Reading vs Listening split; week/month-pannable/year), an 18-week
  heatmap, per-subject cards with covers and progress. iOS-native theming
  throughout (deliberately not Anx's Material look).

**Batch C — BookDrop** (`f3f9d81` + fixes):
- LocalSend protocol v2.2 RECEIVER: register / prepare-upload / upload /
  cancel with per-file tokens, sha256 verification, one session at a
  time, 5-min timeouts. Receive-only — no multicast entitlement needed
  (senders find us via /24 unicast scan hitting /register).
- `LocalSendHTTPServer` on NWListener, port fallback 53317-53327, bodies
  spill to disk past 8 MB; probe-and-heal on every foreground (Readest's
  zombie-listener lesson: 500 ms loopback connect, stop FIRST then start).
- Routing: books → Books importer, .jex → JEX importer; toasts + history.
  BooksStore promoted to app-level env object so BookDrop imports appear
  live on the shelf. Settings → Integrations → BookDrop.
- `Docs/BOOKDROP.md` = porting brief for the Linux/Android receivers.

**Batches D/E/F — office formats, normalize-to-EPUB** (`4e6bf40`,
`cb5f38a`, `7af0092`):
- DOCX, ODT, PPTX, ODP, legacy DOC all normalize to a real EPUB at import
  (`ZipWriter` + `DocumentEpubConverter`): the existing reader, TOC and
  TTS spine pipeline consume them unchanged. Chapters = heading 1-2
  sections (documents) or slides (presentations); headless text chunks
  at 150 paragraphs.
- Legacy .doc: self-contained CFB reader + FIB/piece-table text
  extraction, best-effort by design — exotic docs fail loudly with a
  convert-to-docx message.
- Note-import twin: office files extract to plain-text notes too.
- Tests: fixtures BUILT in-test (ZipWriter for docx/odt/pptx; a
  structurally-real hand-built CFB for .doc) and validated by parsing the
  emitted EPUB back through the app's own EpubParser.

**Explicitly not done (this round):** per-book appearance overrides
(global-only for now), BookDrop PIN gate (auto-accept toggle exists),
speaker-notes extraction from PPTX, BookDrop for Linux/Android (ported
separately per Docs/BOOKDROP.md).

**Version:** 1.7.2 / 39 (project.yml 4-field bump + NSLocalNetworkUsageDescription).

## [2026-10-08] Notes-surface bug batch — orientation, rail round trip, play glyph, emoji

Commit `289cb6b` on `batch-c-d-session` (CI run 37766970471). Four device
reports on NOTES (books untouched), each root-caused from source:

1. **Orientation freeze/slow + minimize→maximize padding distortion — ONE
   cause.** The editor held `editorContent` at two different tree POSITIONS
   (HStack child in landscape, VStack child in portrait); positional
   structural identity meant every rotation REMOUNTED the editor/preview:
   full synchronous re-parse of a long rich note (the freeze) plus every
   @State geometry reset mid-transition. The landscape HStack also made the
   rail's column a width NEGOTIATION between flexible children (preview's
   scrollable tables/code compete); a bad claim survived in @State,
   GeometryReader centered the over-wide result ("screen moved right, rail
   off the edge"), and it persisted across rotation into portrait until the
   editor unmounted — why going back to the list "reverts everything".
   Books were clean because webview/PDFKit take the width offered.
   Fix: content at ONE position; portrait bar via `safeAreaInset(.bottom)`;
   rail an overlay SIBLING; content pads its trailing edge by the SAME
   `hostColumnWidth` the rail pins (promise, not negotiation).

2. **Landscape play/pause glyph stops changing.** Rail inputs were host-
   evaluated snapshots; taps that only moved player state never re-ran the
   host body, so the glyph froze while audio worked. `PlaybackRail.observesPlayer`
   (editor sets it) gives the rail its own `@EnvironmentObject SpeechPlayer`
   — live glyph/progress/session/voice chip, paused shows play.fill like
   the portrait bar. Book readers keep host-passed values (per-chapter
   narrowing).

3. **Emoji missing (keycaps 1️⃣, circles 🔴, more).** Note-creation paths
   stored `SpeechSanitizer.clean` output as the NOTE BODY — and clean strips
   emoji-presentation scalars (correct for speech, silent data loss for
   storage). New `SpeechSanitizer.displaySafe`: keeps emoji + FE0F + ZWJ +
   combining keycap, still strips control bytes/soft hyphens/bidi/PUA.
   All 3 storage paths switched (ImportService, NotesListView.addNote,
   JexImporter); speech paths unchanged (re-derived at play time). 4 new
   tests pin the speech-vs-storage split.

4. **ReadAlongView inset + preview table width** went stale on layout-only
   reflows (probe updated only via the update cycle; magic 500pt test).
   Read-along keeps clear air only (width > height, recomputed per body);
   host pads the column. Preview probe gains `.task(id: width)` so tables
   re-measure in the rail reflow's own transaction.

## [2026-10-08 PM] Preview edge-shift REGRESSION — table probe feedback loop

Commit `92eaebb` on `batch-c-d-session` (CI run 37787051212). Device report on
the `289cb6b` build: preview content shoved to the leading edge in BOTH
orientations, trailing padding gone, rotation no longer clears it. Editor
fine, preview only. v1.7.2 (`ee04b30`) was clean — divergence began with the
GFM tables.

**Root cause — the width probe fed its own overflow back into layout.** Since
the GFM tables landed, the container-width probe sat at the TOP of the content
VStack as a bare `Color.clear`. `Color.clear` adopts ANY proposal, including a
corrupt one: a table that laid out too wide pushed the VStack wider, the probe
measured the overflow, the column math built a table to MATCH it, and the
wider table pushed the VStack wider still — a self-consistent loop that
pinned the document to the leading edge. `289cb6b`'s `.task(id: width)`
amplifier re-committed the corrupt measurement even when the update cycle
didn't fire, making it terminal. v1.7.2 was immune BY TOPOLOGY: its probe rode
`.background()` of the table's own ScrollView — background children never
influence the size of the view they measure. Second enabler: the GFM wrapper
added the pan ScrollView only when the (corruptible) math said "overflows", so
a mis-sized table rendered bare and pushed the document; v1.7.2 always
wrapped its Grid in the pan ScrollView.

**Fix (GFM tables kept):** probe back on the table's pan-scroll frame,
background-only, no task amplifier; pan ScrollView UNCONDITIONAL (overflow
pans within the table's bounds, the document cannot be pushed). The
`overflows` flag stays in the cached layout as a diagnostic only.

**Why books/editor were never affected:** the editor renders raw text (no
table layout at all); the book readers host webview/PDFKit, which take the
width they are offered.

## v1.7.4 — the five reported issues, then what the device log added (2026-10-09)

Tagged `v1.7.4` (43). CI run 37854780413 all green; both device rounds
passed. Commits 6bf785f → d8b0ee0 on `batch-c-d-session`.

**Round 1 — the five reported issues.**
(1) mobi/Kindle outlines + covers had three layers: every store `.azw/.azw3`
is Huff/CDIC ('DH') compressed and the reader REJECTED them at import, so
those books never imported at all — `HuffCdicReader.swift` (KindleUnpack
port, validated against a real 7.6 MB LWW title, 437 records / 6052-entry
dictionary with recursive entries); KF8 chapters now cut at the book's XHTML
FLOW boundaries (the old h1/h2 rule made 430 junk chapters out of a
reference title with 165 h1s + 265 h2s — flow-split gives its own 25); and
the cover is the EXTH 201-declared record (the first image was a 243×65
publisher logo; the real 517×372 cover sat 97 records later).
(2) Opus fidelity: RFC 7845 output gain applied (libopus doesn't), the
5.1→stereo downmix peak-attenuated instead of hard-clamped (the clamp was
the audible fuzz), and `AVAudioUnitTimePitch` BYPASSED at rate 1.0 — a
phase vocoder smears every buffer even at unity, which was the "something
is lost" report. Non-unity rates and config-change repairs still route
through it.
(3) System-voice pauses: the 1.7.3-era fix bounded chunk-EDGE pauses; the
new report was Apple's same unbounded pause INSIDE chunks. Mid-chunk blank
lines collapse to one comma; same-mark punctuation runs compact (`...`→`.`),
`?!` passes. Read-along unaffected.
(4) Supertonic Balanced: 6 of 8 flow steps, ~3/4 of High's time, most of
its quality — the intermediate the user asked for.
(5) Voice picks persist: a picker tap auditioned the voice AND queued a
restore, so the pick snapped back when the sample ended. Taps now COMMIT
(audition(commit: true)); the waveform button stays listen-only.

**Round 2 — the device log's additions.**
(1) The 1.7 GB full-cast Opus book died at load with `NSPOSIXErrorDomain
Code=12`: the reader held the whole file plus copies. Lazy streams landed:
`OggReader.readLazy(url:)` maps the file and keeps granules + byte ranges
(~80 MB for 2.07 M packets); `OpusPacketStream.payload(of:)` reads slices on
demand; the decoder has ONE payload access path; page-spanning packets
stitch-materialize (bounded by Opus's 127 KB packet cap). readLazy == read
pinned by tests on the real fixtures.
(2) ONE Kokoro engine row; the fp32/uint8 tier is the "Kokoro quality"
dial (stored `kokoroTier`, applied via `rebuildKokoroTier()`). Every stored
spelling carries over (kokoroOnnx/kokoroSmall/kitten/soprano). The
Supertonic section's double title is unified.
(3) Full-cast ambience: surrounds −6→−3 dB (ITU Lo/Ro upper bound), LFE
−12→−6 dB — beds clearly audible behind the narration, peak-attenuation
still guarding the louder sum.
(4) `Documents/Data/Application/...` in device paths is LiveContainer's
guest layout under the host's Documents — NOT an app bug.
(5) Model sources verified live on Hugging Face: fp32 325.5 MB + uint8
177.5 MB, both 200 OK (`onnx-community/Kokoro-82M-v1.0-ONNX`).

**The uint8 gate, re-scoped.** The CI spike asserted uint8-vs-fp32
correlation > 0.9 — a property the B4 forensics PROVED impossible for the
shipped graph (oracle bit-deterministic; onnx.quantize rewrote two MatMuls).
A permanently-red gate hides the next real regression, so
`testQuantizedRenderMatchesFP32` became `testQuantizedRenderEvidence`:
renders both tiers, prints the full metric set, asserts the shipping bar
(finite, audible, length-stable), keeps both WAVs. Original thresholds stay
in history at 60b75f6 for a future re-quantization.

**CI traps this batch (6 rounds):** a `maxcode` local shadowed the `maxcode`
ladder array; a `return` merged onto the next line; `Data(records)` wrapped
a `[Data]` (must concatenate); `OpusLib.gain` needed to be a stored
property; the Kokoro quality Section had to leave the `body` Form (type-check
timeout + `$binding` scope); the MP4 timescale-normalize map fed an
optional payload to the eager Packet init.

## 2026-10-24 — Pomodoro timer (1.8.0/45) + web-import diagnosis handoff

**Pomodoro (commits 8cc4e4c, 49c8cce, d7bd9c7 — CI GREEN, run 40125347834).**
A Stats-tab subsection directly under Goals: idle state mirrors the goals
empty card; running it shows a phase ring + countdown + Pause/Skip/Claim/
Stop. Config subpage (sheet) with three modes: **Structured** (time limit
or finish time, N evenly-spread breaks, absolute window — skips never move
the finish), **Flowmodoro** (5 min focus banks 1 min break, claimable at
3 min, pot resets on claim), **classic Pomodoro** (per-block/per-break
minute tuning — the only mode with it). Mandatory 2–5 min prep opens every
mode. Engine (`SpeechLogic/PomodoroEngine.swift`) is pure wall-clock math:
the Codable session reconciles kills/suspension from `Date()` alone
(19 engine tests). App side: `PomodoroStore` (JSON state, day-folded focus
log, one pending phase notification) and the **gentle top-of-app banner**
(user ask: "not a punch in my face") — thin material card, tap-to-dismiss,
fires on last minute / block done / break's over / session complete /
flow-claim; `.pomodoroBanner()` at the app root also owns the 1 s tick.
Version stayed **1.8.0, build 45 only** — the user groups features into
releases; MARKETING_VERSION is theirs to bump.

**Web-article import — user report: "shared a site, it never worked" (open).**
Pipeline traced end-to-end (share sheet → `onOpenURL` in NotesListView →
`importWebsite` → `ImportService.websiteText` → `WebArticleService`:
direct fetch+Readability → BPC bypass pass → rendered fallback →
legacy tag-strip → bare-URL note). Every stage logs with a "WebArticle:"
prefix. Ranked suspects: (1) readability.js missing from the built bundle
— would nil every pass and always fall back to the bare-link note;
(2) `onOpenURL` never firing (no "Fetching article…" toast at all);
(3) per-site failures only (403s, JS shells). Diagnosis needs the device:
Settings → Logs, filter "WebArticle", plus which symptom the user sees
(no toast / bare-link note / toast then nothing). Unresolved — next
session picks it up from `memory/web-article-import-diagnosis.md`.

**Device-feedback batch (2026-10-25 — five reports, one pass).**
1. **Pomodoro card** (PomodoroViews): running state rebuilt as a
   full-width ROUNDED-RECTANGLE progress card (fill grows with the phase,
   countdown + phase pill centered inside) — the circular ring read
   "round" and off-center; the rectangle centers itself by construction.
   No renames, version untouched.
2. **Stale-UI trio**: delete/favourite didn't refresh the notes list (the
   memoized sections key on `notes.version`, and `softDelete`,
   `setFavorite`, `recover`, `move`, `clearNotebook` never bumped it —
   pin did, which is why pin alone worked); the Kokoro High/Compact
   checkmark never moved (picker read a non-publishing UserDefaults
   computed prop — now `@AppStorage("kokoroTier")`); plus a real
   swapped-args bug in the v1.7.4 Kokoro migration (`set("kokoroTier",
   forKey: "compact")` — migrated compact users opened on High).
3. **Books minimise**: `BookPlayerBar` (EPUB + PDF portrait) and the
   audiobook portrait transport collapse to a slim pill via one shared
   `bookBarMinimized` AppStorage — the editor bar's chevron pattern.
4. **JEX root cause found — Joplin's own layout, verified against its
   source (`BaseItem.serialize`/`unserialize`, node-tar)**: (a) our props
   block ended with a trailing newline; Joplin scans lines from the END
   and stops at the first blank line, so it parsed ZERO props →
   "Missing required property: type_" → the WHOLE import aborts;
   (b) the title must ride the FIRST BODY LINE (`title\n\nbody\n\nprops`)
   — a metadata `title:` prop is ignored/overwritten and a note without
   the title line loses its first two body lines; (c) node-tar matches
   the exact magic+version bytes `ustar\0` + `00`, ours wrote version
   zeros. Exporter now writes the canonical layout; importer parses it
   (old app archives still import); new test simulates Joplin's
   unserializer strictly over every entry.
5. **BookDrop phone side verified against the Linux twin** (wire
   compatible both directions — report in memory). One real bug fixed:
   two same-named files in one session overwrote each other and the
   survivor was routed twice (Linux fixed this with per-fileId names);
   iOS now tracks landed names per fileId with readable -2 suffixes, and
   cancel is restricted to the session's own sender IP.
Version stays **1.8.0/45** per the release policy; device retest of the
JEX import in real Joplin is the open check.

**Books minimised transport, round 2 (2026-10-25 device feedback).**
User: "the bar showing controls for next and previous chapter as well the
chapter number and pages persist above the minimised bar... i want this gone
when i minimise... maybe just the next and previous controls can be folded
into the minimised bar - allow it to have opacity like the one in notes...
and use the extra gained space to display more of the book... basically make
it exactly the same as in notes maybe with just the addition of next and
previous control in minimised bar". Root cause of round 1's miss: the
readers stack the chapter/page bar ABOVE the playback bar, so collapsing
only the playback bar left the navigation bar standing. Now: a NEW shared
`MinimizedBookTransport` pill (the Notes shape — ultraThinMaterial rounded
rect, floating over the content) carries play/pause, PREV/NEXT chapter,
the percentage and the expand chevron; the EPUB/PDF/audiobook chapter or
page bars are GONE while minimised (a chapterless PDF keeps its page bar —
it has no playback bar, hence no minimise button), and the freed space goes
back to the reading surface. One `bookBarMinimized` key for all three
readers. Handover: `Docs/HANDOVER-BOOKS-MINIMIZED-TRANSPORT.md`.
Joplin import confirmed working by the user on device; the rest of the
2026-10-25 batch (pomodoro rectangle, stale-UI trio, BookDrop fixes) also
reported good. Version stays 1.8.0/45.

**Maths + books chapter-nav, finished (2026-10-26).** Two handovers
landed on this branch with code written but unverified — one for the
books chapter navigation + resume/start discordance, one for the notes
maths rendering + TTS word forms. This round verified both, fixed what
the handovers left open, and got CI green.

*Maths (the one red test):* `speakList` joined node outputs with NO
separator, so the big operator's separate limit nodes welded together —
"i" + "=" + "1" came out as "iequals1" instead of "i equals 1". Every
node boundary now gets a separator and the whitespace pass collapses the
runs it leaves. That fixes the whole class of bug (any node boundary),
not just this operator.

*Maths (the open items):* (a) the insert affordance — there was no way
to insert maths without typing "$" by hand, so the formatting bar gets a
formula button and the slash menu gets `/math` and `/mathblock`; both
insert the DELIMITED form and leave the body selected to type over.
(b) the export form — a shared PDF or text file is a document the
recipient READS, so it now carries the glyphs ("E = mc²"), not the
engine's words ("E equals mc to the power of 2"). The speech path is
untouched: the engine still hears words.

*Books (the EPUB resume fix the handover called likeliest to fail):* the
mid-chapter position write was a DEBOUNCE, not a throttle — every
relocation cancelled the pending write and started a new one. `relocated`
fires on every scroll tick, so a reader who kept scrolling never reached
the write at all: the exact spot was lost precisely when the reader was
moving through the book. It is now a throttle with a trailing write, and
the position is also flushed on `scenePhase == .background` (onDisappear
does not fire when the app is backgrounded — that is the exit the reader
makes when they put the phone down).

*Verification:* CI on `batch-c-d-session` — the app archive builds (so
the books/EPUB/PDF code compiles for the first time), and the
SpeechLogic suite runs. The earlier red run was exactly one failure, the
maths test above. Version stays **1.8.0/45** per the release policy; the
device round on the user's own book (the compiled OBGYN notes PDF) is
still the open check.

**Two device bugs + the maths/books round closed (2026-10-26, `49a34ea`).**
After the maths + books handovers were integrated and CI went green
(488 SpeechLogic tests, 0 failures; the app archive builds), the user
reported two more bugs.

1. **Landscape play/pause glyph never changed.** The glyph was derived
   from `sessionActive && progress != nil` — and progress is nil until
   the engine's FIRST chunk reports in (and is cleared again whenever
   the engine reports 0). So the button could read "play" while the
   audio was already running; the clicks registered, the glyph did not
   move. The glyph is now a function of the player's SPEAKING state
   alone, which is the portrait PlayerControlsBar's rule. The rail takes
   the speaking state as its own input, because `sessionActive` counts
   paused and generating as live and those must show "play", not
   "pause".
2. **Goals never reached 100%.** The PDF progress was
   `(pageIndex + fraction) / pageCount`, and the fraction is always 0
   for a PDF (the reader is on a page, not inside one) — so the formula
   could not reach 1.0: the last page of a 100-page book read as 99%,
   which is the user's "97/96/98%" report. The page the reader is ON
   counts now. The EPUB side had the same shape (epub.js reports the
   within-chapter fraction as 0 for a chapter shorter than one
   viewport, so the last chapter read as unfinished). StatsTabView now
   uses the same `GoalMath.fraction` the goals use, so the two views
   cannot show different numbers for one book.

**Open, handed over:** a "keep screen on" setting (the user asked for it
as the app went to sleep). Nothing exists today — there is no
`isIdleTimerDisabled` anywhere in the app. The next agent's brief, with
the decisions to make and the traps (restore on disappear, one decision
for all reading surfaces), is in
`Docs/HANDOVER-SCREEN-ON-AND-FINAL.md`. Version stays 1.8.0/45.

**Books TTS: play starts at the viewed page, and the Contents jump moves the
speech in read-along (2026-10-26, `583acdb`).** The user's round decoded:
(a) in reader mode (= the read-along surface) TOC taps only moved the hidden
viewer, so nothing happened — they now move the SPEECH to the chosen chapter
(`BookPlaybackController.jumpToChapter`, superseding in place so the
read-along text follows and auto-advance stays armed), for PDF and EPUB;
(b) a fresh play starts where the reader IS — the PDF page mapped through
the chapter's page-offset sidecar, the EPUB webview's scroll fraction —
while a meaningful stored bookmark still wins ("page 1 is not really a
bookmark": a start-of-chapter position counts as no position). Bookmark
stop/start semantics untouched per the user. Full mechanics, decisions and
device checklist in `Docs/HANDOVER-BOOKS-TTS-POSITION-AND-READALONG-TOC.md`.
CI dispatched manually for `583acdb` (run 40395811218); device round pending.

**v1.8.0 released (2026-10-27, build 46 — the user's go).** The whole release
grouping shipped: books readers transparency + wide-table panning, TTS
play-from-page + landing chapter jumps, the shared minimised pill, maths
rendering + spoken words, Pomodoro on Stats (claim gate at 3 banked break
minutes), Keep Screen On, BookDrop everywhere (hotspot scan, port-stability
state machine, launch-OFF, 401 recovery), web article import + BPC, JEX
exports real-Joplin-clean + Joplin E2E crypto, mobi/OCR/m4b from the 1.7.x
line. Onboarding refreshed at release time: still five pages, the
"Start with a note" page folded into welcome, a Pomodoro & Stats page added.
The juice bubbles got their own per-frame clock (the card's 1 Hz tick was
stepping them — the "not smooth" report), four slightly larger streams with
sway, and the paused freeze preserved via the schedule's `paused:`.
README brought to v1.8.0 reality (Kokoro Compact ~92 MB dynamic int8, not
~177 MB; Soprano credit removed — no engine; epub.js credited; layout/CI
sections match the tree). Release notes: `Docs/RELEASE-V1.8.0.md`.

**Parity round 3 harvested; Phase 5 EP variant flagged in (2026-11-10,
`ed50e7a`).** Round 3 (run 42718617400, success) settled both placements:
Supertonic's whole 4-model chain through the ORT CoreML EP is numerically
PERFECT vs the CPU oracle (Pearson 1.0000, rel-RMS 0.0007, exact length,
CoreML active on all four sessions) → it ships via the EP, no conversion
pipeline; Kokoro's EP is BANNED under every unit configuration — the A2
localization proved the failure (Pearson 0.6305) is identical with the EP
pinned to CPUAndGPU (ANE excluded, provider-proof logged), so it is the
EP's CoreML conversion itself, not ANE-fp16; the GPU-pinned experiment is
dead and Kokoro stays CPU. Placement doc §4/§8 updated (`4ba0ff0`). H1b
answered: ORT 1.24.2's ObjC binding exposes
`appendCoreMLExecutionProviderWithOptionsV2` (MLComputeUnits dict) through
the umbrella header. The Supertonic CoreML-EP engine variant is now behind
runtime flags: `loadTextToSpeech(useCoreML:)` appends the EP with
MLComputeUnits=All (the exact runner-proven config; append failure
degrades to CPU), Benchmark Mode gains the
supertonic-high/balanced-coreml tiers for the EP-vs-CPU device
comparison, and normal playback gets a "Render with Core ML
(experimental)" settings toggle — default OFF, one build,
runtime-selectable. Acceptance stays gated on the device round: RTF ≤
CPU tiers or thermal/footprint win, no audible difference, thermal never
past serious. Also this session: the parallel web-import workstream's
finished feature committed separately (`05cc552`) — its new ShareExtension
target is GATED build-only (embed: false) because LiveContainer hosts no
app extensions; enabling embed needs the user's say-so + an LC smoke
test. CI: manual dispatch run 42723938178 on `ed50e7a` (compile oracle;
one round budgeted).

**Phase 5 follow-up: full CoreML EP option set + compiled-model cache
(2026-11-10, same day).** The EP variant's provider options now spell out
the full ANE-facing config from the Phase-2 placement plan: MLProgram
format (what the runner gate proved) + all compute units (NPU eligible) +
ModelCacheDirectory in the purgeable caches dir — only the first-ever run
per input shape pays ANE specialization compile. RequireStaticInputShapes
and FastPrediction deliberately left off (documented in Helper.swift why).
User decision this round: NO benchmark session now — they will judge the
EP variant's speed themselves by ear/feel; the Benchmark Mode EP tiers
remain the formal acceptance instrument for when there IS time. Kokoro
gets no EP code (round-3 parity ban stands).

**Phonon repeat spiral root-caused: the KV feedback sliced the cache
head-major-blind (2026-11-10, this session).** The device report: TTS and
the voice audition start fine for ~two words, then repeat/stutter/whisper
into "long sick syllables" — on every run. Diagnosis, with the whole
pinning workspace still alive in `/tmp/phonon` (models, venv, the Python
mirror `final.py`/`contract.py`, the hub's torch `PocketTTSGenerationMixin`
reference): (1) the Python pin's own rendered WAVs (`out-hello.wav` 17.9 s,
`out-fox.wav` 87 s for 3.5/10 s sentences) turned out to be an artifact of
`final.py` appending the CUMULATIVE `audio_latents` per call (`lat[-8:, :]`
slices the batch axis) — the engine appends correctly, so that red herring
was retired; (2) 46 x86 ORT runs (10-12 seeds × 3 feedback variants,
sentence AND 217-char chunk scale) render CLEAN with sharp EOS crossings —
the recipe is not the catastrophe; (3) a graph trace of `model.onnx` pinned
the true semantics: `position_ids` covers only the NEW `P+7` positions
(`Slice_29 = position_ids[0:P]`, frames at `[P+k]`), the fed-back KV keeps
its baked RoPE, and `Slice_8` takes `[-1:]` of `[bos | history]` — only the
LAST latent feeds the prompt block's input slot; (4) the app engine and the
spike BOTH sliced the KV feedback with a contiguous float prefix
(`values[0..<(keepHead * heads * dim)]`), but the cache is
`[1, heads, seq, dim]` — HEAD-major, rows strided: call 1 fed back
head-7-only garbage-aligned rows, call 2+ attended poisoned context. That
is the repeat spiral, device-only (the app's engine runs nowhere but the
device), and it explains CI's marginal EOS ("crossed 20/26 with one seed,
never with another" — misread as noise variance; healthy runs spike sharply
at 12-20 calls, which is what x86 shows). Fix: the feedback copy walks the
heads (`[0, past) ++ [past+P-1, presentTotal)` per head — the prompt block's
input-slot row is kept, so the KV now grows +8/call == the latent history
and `arange(past_kv, …)` lands on the exact reference timeline; the
"slot" variant, 0/12 degenerate in the sweep). Engine gains a finiteness
guard on the new latents (`PhononEngineError.corruptLatents` — the
numeric-divergence signal) and logs the per-chunk eos peak + call; the
spike mirrors the fixed recipe; `Docs/PHONON-PORT.md` documents the
semantics + the layout trap. Audition text through the fixed recipe on
x86: 8/8 seeds clean (10.2-12.2 s, self-sim ≤ 0.18, eos peak 6.1-9.3).
OPEN: the device round — one audition + one sentence; if still wrong,
Settings → Logs → filter "PhononEngine" (per-chunk eos peak line + the
NaN guard discriminate AR degeneration from runtime corruption).

**Phonon positions fixed to the reference recipe: the re-run prompt rows stop riding
the timeline (2026-11-11).** The device report after the KV-feedback fix: "much much
better, but after 4 words repetitions or artifacts or some whispering" — calls 2-3
(4 words ≈ 20-25 frames). This session verified the handover's #1 suspect against
GROUND TRUTH READ FROM THE REPO (not re-derived), then shipped the ~3-line fix.
Ground truth, three independent sources, all agreeing: `qnn/runner/phonon.cpp`
(Gradium's official QNN export driver — the closest thing to an export contract)
bakes the voice KV at 0..V-1 and the text prefill ONCE at V..V+T-1, then runs ONE
latent row per call at `pos = cache length` (`*buf_.pos = pos; …; pos++`) on the
contiguous absolute timeline 0,1,2,…, cache never trimmed; `transformer.rs:736-745`
pins RoPE offset = `current_end` (FlowLm; trim is Mimi-only); `synth.rs:1233/1319` +
`flow_lm.rs:296` prompt the text once per chunk, one `StepInput::Bos/Latent` row per
step. `ios/PhononTTS/Phonon.swift` is a thin FFI wrapper — no per-call driving to
override anything. Our graph forces a prompt-block re-run per call (HF export
format), but `position_ids` values may be NON-CONTIGUOUS (Slice_29 = [0:P], frames
at [P+k] — proven last session), so the shipped contiguous
`arange(past_kv, past_kv+P+7)` was the one structural error: the re-run voice+text
rode the moving timeline, freezing its attention distances at call-1 values (the
prompt appears adjacent forever instead of receding as the latent history grows)
and changing its K/V every call — exactly the after-~4-words degradation.
PHONON-PORT.md's "unavoidable deviation" claim was removed as WRONG AND BACKWARDS:
the reference's prompt never recedes — it is cached once at fixed positions forever.
Fix (engine + spike mirror): `position_ids = concat(arange(0, P-1),
arange(P + past_kv - 1, P + past_kv + 7))` — voice+text at their true absolute
positions on every call, input slot at `P+past_kv-1` (bos at V+T = P-1, then +1 per
latent), frames after; call 1 (past_kv = 0) degenerates to the old contiguous form.
x86 A/B (`/tmp/phonon-diag/position_recipe_ab.py`; same pre-generated noise tape fed
to BOTH arms, position_ids the only variable): call-1 latents BIT-IDENTICAL, diverge
from call 2 (onset matches the device symptom); layer-0 re-run prompt-row KV drift
across calls 9.2-10.0 (shipped) → **0.000e+00 bitwise (recipe)** — the fed-back
cache now replicates the reference's baked cache, which is a stronger parity result
than any metric separation, so the handover's optional Rust/torch parity gate was
skipped; zero-noise determinism probe confirms the same signature. Renders (8 seeds
× audition + 217-char chunk): 0/8 degenerate on both arms — no regression — and the
recipe is mildly better: EOS crosses earlier (18-19 vs 25-31 calls on the long
text) with sharper peaks and natural-band durations (mean 14.1 s vs 18.6 s), i.e.
EOS timing was drifting late under the corrupted geometry. CI: dispatched build.yml
run 42923777452 on `1b232f5` (batch-c-d-session). OPEN: device round — the ear is
the acceptance bar; if artifacts persist, Settings → Logs → filter "PhononEngine"
(per-chunk eos-peak + frame counts discriminate AR degeneration from runtime
corruption). Secondary threads parked from the handover: per-chunk
thermalState/memory logging for the late-session RTF degradation (2.7), untouched.
