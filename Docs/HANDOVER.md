# HANDOVER — Speechnotes iOS markdown reader

> **Status: bisect-f at commit `0785f1b` is the new base.**
> `main` is currently behind; do not merge into main until the device test passes.
>
> Author: previous agent (ZCode). Written 2026-09-05 for the incoming agent.

## 1. The original request

1. Revert the app to **v1.3.0** (commit `37a5598`) — the last known-good base before the STT detour.
2. Drop STT entirely. The app is a **TTS + powerful markdown** tool now.
3. Integrate the user's upgraded markdown engine (MarkdownText v2, MarkdownSlashMenu, NoteImageStore with thumbnails/prune).
4. Ship from there.

## 2. What actually happened (the mistakes to learn from)

I salvaged `47c080a` ("Fix background TTS + mini-player stuck mid-screen") onto v1.3.0.
**This was the single biggest mistake.** The user explicitly told me NOT to copy anything
from `47c080a` or anything after it — that whole sequence was red on CI and known-broken.

The cherry-pick auto-merged several latent bugs into the new base:

- A **duplicate `notesList` declaration** in `NotesListView.swift` that nested the whole
  view body one scope deep.
- **iOS 26-only `TextRange`** selection binding in `MarkdownFormattingBar` and
  `NoteEditorView` — blank/missing on the iOS 18 deployment target.
- A **Swift 5 ambiguity** around `rangeOfCharacter` whose return collided with `??`.
- A `SpeechnotesApp.init` **escaping-closure capture** of a mutating `@StateObject`
  receiver — benign on the simulator, fatal on LiveContainer.

CI caught each of those (red for many iterations). We got CI green, but the app **still
crashed on launch in LiveContainer** — no dyld leaks, no Info.plist issues, no framework
problems. The hotfix (`75cf8a7`) moved `@StateObject` side-effects (engine init,
AVAudioSession, NowPlayingCenter) out of `App.init` and into a lazy `wirePlaybackOnce()`
fired from `onAppear` — pure speculation because **no crash log was ever available**, and
the user confirmed it still crashed.

**The `@StateObject` capture pattern is the prime suspect for the launch crash.** Until a
crash log proves otherwise, never assign to a `@StateObject`'s wrapped value inside
`App.init`. Always defer to `onAppear` or a single-shot `@MainActor` helper.

## 3. The bisect that pinpointed the problem

With the user's help I ran several bisect branches:

| Branch | Contents | CI green | On device |
|---|---|---|---|
| `bisect-a` (`37a5598`) | v1.3.0 only | ✅ | ✅ **Works** |
| `bisect-b` (`98ca99e`) | v1.3.0 + TTS salvage | ❌ | — |
| `bisect-c` (`5603cc3`) | v1.3.0 + markdown | ❌ | — |
| `bisect-d` (`75cf8a7` minus mini-player + NowPlayingCenter) | partial revert | ✅ | ✅ Works with markdown |
| **`bisect-f` (`7003350` + cherry-picks)** | **v1.3.0 + markdown ONLY** | ✅ (after many CI fixes) | ✅ Works, see bugs below |

The verdict: **the crash was NOT in the markdown engine** — it was somewhere in the
`47c080a` TTS salvage (NowPlayingCenter / GlobalMiniPlayerOverlay / the App.init capture).
Dropping the salvage entirely gave us a working app.

## 4. The repo right now

- **Active branch**: `bisect-f`, commit `0785f1b` (pushed to origin).
- **Local working copy** is on `bisect-f`. `git status` should be clean except possibly for
  the most recent test fix.
- `main` is **behind** `bisect-f`. **Do not merge bisect-f into main with a merge commit.**
  Once the device test passes: `git checkout main && git reset --hard bisect-f && git push
  --force-with-lease origin main`, then tag `v1.4.0`.
- **Do NOT cherry-pick from `47c080a` or anything after it on main** — the whole sequence
  was red on CI and the app it produced crashed on device.
- **Do NOT salvage the mini-player / NowPlayingCenter work piecemeal.** If the user wants
  that back, re-implement from scratch on a known-good bisect-f base, with a device test at
  every incremental commit.

## 5. What's already integrated and working on device (bisect-f v2)

- Markdown engine v2 (`MarkdownText` + `MarkdownSlashMenu` + `NoteImageStore`).
  Unified scanner drives both `plainText()` and `blocks()`. Supports tables, task lists,
  nested lists, setext headings, reference links/images, autolinks, backslash escapes,
  language-tagged fenced code.
- `MarkdownSlashMenu` — fuzzy filter (`tbl` → Table), keyword aliases, wrap-selection
  commands, slash trigger after `- `, `> `, `1. `, `[x] ` prefixes, detects the last
  `/` between line-start and caret.
- `NoteImageStore` — `speechnotes://note-image/<hash>.<ext>` URIs, SHA-256 dedupe,
  `importImage` with magic-byte sniffing + HEIC/oversize JPEG re-encode, disk-cached
  thumbnails (`<hash>-thumb.jpg`), `prune(markdown:)` orphans, `copyImages`, `allTargets()`,
  `remove(target:)`.
- Reader opens in **preview by default**. Edit is via **double-tap** anywhere in the
  preview, or tapping the pencil badge in the top-right. Single-tap does nothing so
  scrolling readers never accidentally switch modes.
- H1/H2 format-bar buttons render as text labels (SF Symbols `h1`/`h2` don't exist on
  iOS 18 and silently render blank).
- Pinch-to-zoom sheet for images (tap image → full-resolution, pinch to zoom, drag to
  pan, double-tap resets, X button to close). `URL: Identifiable` lives in
  `StorageView.swift` only — one conformance.
- Appearance → Reading View → **Text size slider** (75–150%, 5% steps) via
  `AppTheme.previewTextScale`. Applied through `.font(.system(size: 17 * scale))` on the
  preview root so headings/paragraphs/lists/quotes scale uniformly; code blocks keep their
  monospaced font.
- `ImageCache` (NSCache, 64MB budget, 80-image cap) decodes once per URL and holds the
  decoded `UIImage`. `CachedImage` reads from it synchronously on the success path and
  decodes off-main on miss, then seeds the cache — so preview toggling, scrolling, and
  re-entering a note never re-hit disk or network. Mirrors Joplin's `resourceDir` model.
- Local (cached) images now resolve to their **thumbnail** first via
  `thumbnailURL(for:noteId:)`; the full original is read only for zoom.
- Quote block anchors the text to the top of the vertical rule with a full-width text
  frame.
- Storage tab gained a **Cached images** section above Exported audio: per-row thumbnail,
  truncated hash, per-row delete + share, "Clear all" action, total bytes in the footer.

## 6. New but UNVERIFIED on device (bisect-f v3, pending device test)

These are committed but the user hasn't run them yet:

- **`MarkdownEditorView.swift`** (new file) — a `UIViewRepresentable` wrapping
  `UITextView` to replace SwiftUI's `TextEditor`. **Root cause of the "bold / italic /
  bullet don't work" bug**: SwiftUI `TextEditor` on iOS 18 does not report selection
  changes, so the formatting bar was always operating at end-of-text. `UITextView`
  reports both text and selection through its delegate; Joplin uses the same UIKit pattern
  under its React Native bridge.
  - Caret and selection flow back as UTF-16 offsets (`selectionUTF16`) through
    `UITextViewDelegate.textViewDidChangeSelection`.
  - A `formattingBarSelection` computed binding bridges `selectionUTF16` (Int) to
    `Range<String.Index>` because `MarkdownFormattingBar`'s API was already typed that way.
  - `updateUIView` skips redundant text writes (`if uiView.text != text,
    context.coordinator.lastSentText != text`) so programmatic format-bar edits don't
    clobber the caret.
- `NoteEditorView.insertAtCaret` was rewritten to use `selectionUTF16` directly and
  convert to `String.Index` for the actual `replaceSubrange`.
- Quote block uses `alignment: .top` and `.padding(.top, 2)` on the rule.
- Images inside `runsView` and standalone-image blocks use `frame(maxWidth: .infinity)`.
- `MarkdownPreviewView` emphasis regex is now a compiled `static let`
  (`Self.emphasisRegex`) instead of recompiling on every call.

## 7. Known bugs / loose ends to fix on bisect-f

### Bug A — Format-bar actions (bold/italic/strike/bullet/number/quote/code/divider)
  don't apply to a highlighted selection.
  **Status**: root cause identified (TextEditor doesn't report selection); fix committed
  in `MarkdownEditorView` — **UNVERIFIED on device.** If it still doesn't work, the bridge
  `formattingBarSelection` (Int ↔ String.Index) is the first thing to instrument — add a
  `print` in `reportSelection` and the binding setter to see whether the UITextView is
  actually reporting selection changes, and whether the `updateUIView` guard is swallowing
  them.

### Bug B — Images still don't span the full reader width.
  **Status**: `.frame(maxWidth: .infinity)` is applied in both `runsView` and
  standalone-image blocks, but the user still reports they're capped. Likely candidates:
  `frame(maxHeight: 220)` or `scaledToFit()` inside `CachedImage` is shrinking them before
  the outer frame is applied; or the outer VStack's `frame(maxWidth: .infinity,
  alignment: .leading)` isn't propagating. Needs device-side verification + a screenshot.

### Bug C — Quote block's vertical rule occasionally overlaps the next paragraph.
  **Status**: current approach is an `HStack` (rule + text). Joplin uses a
  `ContainerWithDecoration` that puts the gutter **outside** the text flow via a
  `ZStack`. If `alignment: .top` doesn't fully resolve it on device, switch to a
  `ZStack { Rectangle().fill(...).frame(width: 3); Text(...).padding(.leading, 13) }`
  pattern so the rule's height no longer participates in line-box layout with the
  following block.

### Bug D — Minor cleanup
  - `ImageCache.image(for:)` and the detached-task path in `CachedImage.load()` do the
    same decode twice; consolidate.
  - `bisect-f` was hand-cherry-picked from commits including several leftover "CI fix"
    commits from the salvage attempt. Once bisect-f is fully green and device-confirmed,
    consider **squashing** it into a clean 3–4 commit story:
    (1) markdown engine v2, (2) reader/editor UI, (3) image cache + storage viewer,
    (4) reader polish.

## 8. Immediate next steps for the incoming agent

1. **Check CI on `bisect-f`.** `gh run list --limit 3`. If the latest run (after commit
   `0785f1b`) isn't green, read its errors with `gh run view <id> --log | grep error:`
   and fix them on bisect-f. Do not touch main yet.
2. **Hand the user the resulting IPA** (Actions run artifact) and ask them to validate
   specifically:
   - (a) format-bar bold/italic/bullet applying to a highlighted range,
   - (b) images spanning the full reader width,
   - (c) quote blocks not overlapping the next paragraph.
3. **If all three pass** → promote to main:
   `git checkout main && git reset --hard bisect-f && git push --force-with-lease
   origin main`, then tag `v1.4.0`.
4. **If format-bar selection still doesn't work on device**, instrument
   `reportSelection` / `formattingBarSelection` as described in Bug A above before
   rewriting anything.
5. **For Bug B / Bug C**, ask the user for a screenshot so we can distinguish between a
   frame-propagation issue vs. an `AsyncImage` content-sizing issue.

## 9. Key files

```
App/Sources/
  Engine/              Kokoro/Kitten/Supertonic/System TTS engines (unchanged from v1.3)
  Services/
    ImageCache.swift   NSCache-backed decoded-image cache (NEW)
    MarkdownImageInserter.swift
    SpeechPlayer.swift
  Views/
    MarkdownEditorView.swift     UITextView editor replacing TextEditor (NEW)
    MarkdownFormattingBar.swift  Selection-aware formatting bar
    MarkdownPreviewView.swift    Block-rendered reader + zoomable image + env noteId
    NoteEditorView.swift         Edit/preview modes, bridge selection ↔ format bar
    StorageView.swift            Cached images section + URL: Identifiable
Packages/SpeechLogic/
  Sources/SpeechLogic/
    MarkdownText.swift           plainText + blocks from ONE scanner
    MarkdownSlashMenu.swift      detect/filter/apply
    NoteImageStore.swift         speechnotes:// cache (thumb/prune/resolve)
  Tests/SpeechLogicTests/
    MarkdownTextTests.swift
    NoteImageStoreTests.swift
```

## 10. The golden rules (learned the hard way)

1. **Never push red.** CI green is the bar.
2. **Always build on `bisect-f` (or a feature branch), verify on device, THEN promote.**
   The no-crash guarantee is the user's #1 priority.
3. **Never assign to a `@StateObject`'s wrapped value inside `App.init`.** Defer to
   `onAppear` or a single-shot `@MainActor` helper.
4. **Never cherry-pick from the `47c080a` salvage line.** The whole sequence is poisoned.
5. **Pure logic goes in `Packages/SpeechLogic` (public, tested). UI stays in
   `App/Sources/Views`.**
6. **iOS 18.0 deployment target, SwiftUI, Swift 5 language mode.** No iOS 26-only APIs.
7. **LiveContainer constraints:** portrait-only, static linking, no new SPM deps,
   `project.yml` untouched except the version line.
8. **Match existing style:** comments explain *why*, `Haptics.tap()` on buttons,
   `.foregroundStyle(.secondary)` over `.foregroundColor(.gray)`, `enum` namespaces for
   pure logic, small views composed from private vars.

Good luck. The project is in a solid state — just don't undo it by re-introducing the
salvage.

---

## 2026-09-05 addendum — launch-path scrub on bisect-g (post-debug-commits fix)

Delta vs the debug-commit HEAD, aimed at making bisect-g's launch profile match
the device-proven 0785f1b as closely as possible while keeping v1.5 features:

1. **Removed all `launch-diagnostics.log` writes** (SpeechnotesApp.init, WindowGroup
   body, NotesListView.body, and the `appendLine` extension). File I/O inside
   SwiftUI body evaluation during launch is itself a LiveContainer hazard.
2. **`wirePlaybackOnce()` is deferred** to a `Task { @MainActor in ... }` from
   `.onAppear` — engine rebuild now happens after the first committed frame,
   not inside the first render transaction.
3. **`NowPlayingCenter.configure()` (MPRemoteCommandCenter registration) moved
   out of launch entirely** into `ensureNowPlayingWired()`, called lazily from
   `togglePlay(.idle)` and `restartFromBeginning()` — i.e. on first REAL
   playback. Lock-screen controls still work; launch never touches the
   remote-command registry (which the LiveContainer host app owns).
4. **`resumeIfBookmarkPending()` skips the initial scene activation** — a fresh
   (< 5 min) bookmark replaying speech during launch would turn any
   mid-speech crash into a launch crash loop. App-switcher returns still
   auto-resume.

Not changed (audited, judged safe): `ModelManager.init` ran at launch in 0785f1b
too (proven on device); `removeQuantizedDownloads()` is pure `try?` FileManager
ops. `SpeechPlayer.init` only touches UserDefaults. `NoteRowView`/preview cache
are pure string work.

Next: CI build from bisect-g → install in LiveContainer → verify launch. If it
STILL crashes, stop guessing: capture a real crash log via Xcode → Devices →
device console (or Settings → Privacy → Analytics & Improvements → Analytics
Data → Speechnotes-*.ips on device) before touching code again.

## 2026-09-06 addendum — ROOT CAUSE FOUND (device crash log, .ips)

EXC_BREAKPOINT / SIGTRAP at launch, main thread:
    _assertionFailure → EnvironmentObject.error() (SwiftUI)
    → [app binary] → ModifierBodyAccessor.updateBody → DynamicViewList (TabView)
    → _UIHostingView.layoutSubviews during UIApplication._firstCommitBlock

Cause: `.globalMiniPlayer()` was attached AFTER `.environmentObject(...)` in
SpeechnotesApp — making GlobalMiniPlayerOverlay the OUTERMOST node. Environment
objects only flow DOWN the tree, so the overlay's `@EnvironmentObject player`
resolved to nothing and SwiftUI trapped on the very first layout pass — before
anything rendered, hence "crashes without even opening" and no diagnostic line
was ever written. Introduced when the mini-player moved from per-screen
(0785f1b, worked) to a root overlay (main/bisect-g era).

Fix: attach `.globalMiniPlayer()` BEFORE (inside) the `.environmentObject(...)`
modifiers; injection is now the outermost node so TabView content AND the
overlay modifier both resolve. DO NOT move .environmentObject upward in the
chain again.

Historical second signature (bug_type 206, CPU watchdog: 94% CPU 51s, killed):
older-era build spinning ONNX compute at launch. The launch-path scrub
(deferred wirePlaybackOnce) reduces this; if it reappears with the fp32 model,
the next step is lazy engine creation on first playback, off the main actor.

## 2026-09-06 addendum #2 — post-launch polish round (bisect-g)

Device-verified launch fix confirmed (app opens). Seven user items:
1+2. One-letter-per-tap typing + broken selection: MarkdownEditorView's
   updateUIView force-resigned first responder on every re-render because the
   `editorFocused` FocusState it mirrored is never set anywhere (dead since
   2426fb2 editor rewrite). Relay + focusState param removed — UIKit owns
   focus. ONE root cause for both symptoms.
3. CachedImage 400pt height cap removed — full width, unlimited height.
4. Web images now persist: new RemoteImageStore (Caches/remote-images/,
   sha256(url).ext + .url sidecar) with read-through in ImageCache; Storage
   "Cached images" is now a browsable grid gallery of BOTH note images and
   web images (tap → ZoomableImageView, context menu share/delete, combined
   footer + usage row).
5. Blurry ⋯ toolbar: root-level .animation(value:) moved off the window
   ZStack; scoped to a Group wrapping only the conditional mini-player bar.
   If blur persists it's an iOS 26 Liquid Glass artifact inside LiveContainer.
6. Two stacked player bars in-app: global MiniPlayerBar now yields while the
   editor of the SAME note shows its own PlayerControlsBar
   (SpeechPlayer.miniPlayerSuppressed, set by NoteEditorView on appear/
   disappear/nowPlayingNoteId change). NOTE: the earlier AVSpeech duplicate
   Control Center card theory was NOT the user's complaint — no
   NowPlayingCenter changes in this round.
7. main promoted to the device-verified build f7b9c5c (force-with-lease).
   This commit sits ON TOP of that; fast-forward main only after the next
   device-verified CI build.

## 2026-09-06 addendum #3 — v1.4 Phase 1: small Kokoro, Kitten removal, bookmark snap, read-along

TTS:
- Kitten engine REMOVED (quality). EngineKind.kitten → kokoroSmall; UserDefaults
  migrate "kitten" → "kokoroSmall", kittenVoice/recents keys cleared;
  Documents/Kitten deleted on launch (removeLegacyKittenFiles).
- Small tier = Kokoro fp16, model_fp16.onnx 163,234,740 bytes in the SAME
  KokoroOnnx/ dir (own filename so removeQuantizedDownloads' <200MB rule can't
  eat it). Shares tokenizer.json/voices.npz with fp32 (kokoroVoicesAreValid/
  kokoroTokenizerIsValid split out). startSmallDownload fills missing shared
  files. deleteModels/deleteSmallModel each remove only their own model.
- OnnxKokoroEngine parameterized: init(modelFileURL:modelFilesValid:) — fp32
  and fp16 tiers share the class; one engine slot, tier switch rebuilds it
  (onnxEngineFileIsBig flag).
- CI: kitten-spike → kokoro-small-spike (validates fp16 on ORT CPU; artifacts
  kokoro-small-sample/-log). If the spike ever fails, fall back to
  model_uint8.onnx (177 MB) — decision documented then.
- Bookmark resume: SpeechPlayer.resumeOffset now delegates to
  SentenceChunker.resumeOffset (chunker-grade rules: whitespace-after-.,
  decimal guard, CJK, all line breaks). 30-day/≥40-char validity unchanged.
- Read-along v2 (see ReadAlongView.swift header): dedicated reader replaces
  the editor while the SAME note speaks (toggle: book.pages button in
  PlayerControlsBar + readAlongEnabled AppStorage). Position = play-time
  signal: SpeechEngine.onPlayedChars — SystemEngine per word from
  willSpeakRangeOfSpeechString; buffer engines (Onnx/Supertonic) via
  PlayPositionTracker (playerTime samples → chars, 0.3s heartbeat,
  never schedule-ahead). SpeechPlayer maps to sentence ranges via
  SentenceChunker over the EXACT spoken text (activeSpeechText).

## 2026-09-06 addendum #4 — v1.4 complete (all three phases green on CI)

Phase 1 — TTS: small Kokoro tier = uint8 (fp16 NaN'd on ORT CPU per the new
kokoro-small-spike gate — spike did its job). Kitten fully removed. Bookmark
resume snaps on SentenceChunker rules. Read-along v2: ReadAlongView (dedicated
reader while the same note speaks, toggle = book.pages button in the player
bar / readAlongEnabled) driven by onPlayedChars play-time signals
(SystemEngine word-exact; Onnx/Supertonic via PlayPositionTracker heartbeat).

Phase 2 — UI: Storage gallery/exports capped with See-all expanders; accent
picker is a dropdown; mini-player is a rounded material card, minimizable to
a progress-ring bubble (miniPlayerCollapsed AppStorage).

Phase 3 — Org: flat notebooks (Notebook + NotebooksStore, notebooks.json,
Note.notebookId), chip-row scoping in NotesListView with counts, Notebook
manager sheet (delete → notes Unfiled), pin/favorite (context menu + swipe +
row glyphs, Pinned section on top), 3-page onboarding (hasOnboarded).

main fast-forwarded to the green build (6a5da15); IPA artifact on run
34011231751. Device test checklist for the next session: small-model
download + playback (Settings → Kokoro small), resume snap at sentence
boundary, read-along highlight tracking + toggle, mini-player minimize,
notebook CRUD + moves, pin/favorite, onboarding on fresh container.

## 2026-09-06 addendum #5 — Supertonic noOutput resilience + v1.4.1 UI round

Supertonic "failing like crazy": the Helper's duration model intermittently
predicts a ZERO-length result (noOutput) mid-stream; one flaky chunk aborted
the whole reading. Both neural engines now retry each chunk 3× (log includes
the chunk text head — watch for content-dependence) and on final failure
insert 0.5s silence and CONTINUE. Same for WAV-export loops.

v1.4.1 UI round (all in this build): Note.title = first sentence (editable);
editor title lives in the nav bar (.principal) — the title row is gone;
PlayerControlsBar minimizes to a slim pill (editorBarMinimized).

## 2026-09-06 addendum #7 — v1.4.2 Books: phases 1-3 shipped, two open device bugs

Branch `books-v1.4.2` (NOT yet merged to main; main = bisect-g = 22e5afb = v1.4.1).
Version fields still 1.4.1/28 — the release commit bumps all FOUR fields
(CFBundleShortVersionString, CFBundleVersion in info.properties +
MARKETING_VERSION, CURRENT_PROJECT_VERSION) to 1.4.2/29.

### Shipped on books-v1.4.2 (CI green, executable plan: Docs/PLAN-V1.4.2-EBOOKS.md)

- **Phase 1**: Storage tab content merged into Settings → Storage
  (StorageView.swift deleted; `URL: Identifiable` conformance +
  GalleryThumb + NotesStoreSizeReader relocated to StorageSettingsView.swift —
  NoteEditorView/MarkdownPreviewView depend on that conformance). Storage
  TAB is now the Books library (Tab.books, SpeechnotesApp only). Import via
  fileImporter [.epub,.pdf] + Open-In (project.yml gained the EPUB document
  type — the ONE planned exception to "version line only"). Per-book storage:
  Documents/Books/<uuid>/{original.epub|pdf, manifest.json, cover.jpg,
  text/NNNN.txt}. SpeechLogic gained ZipReader (minimal ZIP central-directory
  reader over Compression, stored+deflate) + EpubParser (container→OPF→
  title/creator/spine/TOC/cover; EPUB2 meta-name+NCX and EPUB3
  properties+nav both supported). New non-blocking epub-spike CI job
  validates against 3 Gutenberg books. BooksStore imports off-main, one
  manifest.json per book (NEVER notes.json).
- **Phase 2+4 (readers)**: EPUB = vendored epub.js 0.3.93 + jszip 3.10.1
  (App/Resources/epubjs/, license notes there) in ONE WKWebView per reader
  presentation; EVERYTHING served via the custom `bookscheme://` scheme
  handler — the EPUB must be fetched from the SAME shell origin
  (bookscheme://shell/book/<uuid>/original.epub, RELATIVE fetch in
  reader.js): cross-host custom-scheme fetch = opaque-origin CORS block =
  "TypeError: Load failed" (first device bug, fixed). Chapter-paged scroll
  flow, native TOC sheet from epub.js navigation, Aa sheet (light/sepia/dark
  + font size via rendition.themes; initial values passed as QUERY PARAMS —
  JS-applied settings race rendition creation otherwise). Position persisted
  per chapter+fraction. PDF = PDFKit PDFView (full fidelity), outline via
  PDFOutline numberOfChildren/child(at:) (this SDK has NO .children array)
  and .singlePageContinuous (NOT .continuous). Tap-to-open = NavigationLink
  (value: Book) — Book/BookPosition/BookTocEntry are Hashable. PDF covers =
  page-1 render at import + one-shot backfill (backfillLegacyBooks in
  BooksStore.refresh).
- **Phase 3 (TTS for books)** — device-confirmed WORKING incl. auto-advance
  (user reached ch24). Chapter speech text is NATIVE: SpeechLogic.XhtmlText
  (XMLParser→plain paragraphs; always emit a word boundary around <img> —
  alt-less images glued words, CI-caught). BookPlaybackController (singleton,
  bound in SpeechnotesApp.onAppear): cache (text/NNNN.txt) → ZipReader entry
  → XhtmlText off-main, prefetch next chapter, skip empty spine items.
  SpeechPlayer ADDITIVE: PlaybackBookmark has optional bookId/chapterIndex
  (tolerant decode); togglePlay(_ text, note:, book: BookPlaybackRef) primes/
  matches book bookmarks (30-day, sentence-snapped resume); onNaturalFinish
  fires on natural completion (stop() and note takeovers clear it);
  resumeIfBookmarkPending IGNORES and no longer deletes book bookmarks.
  Reader: BookPlayerBar (play/stop/progress/speed/read-along toggle); while
  this book speaks + readAlongEnabled, the webview swaps to ReadAlongView;
  miniPlayerSuppressed while the reader's own bar shows.
- **CI noise fix**: spike jobs' ::error annotations only fire when the test
  step actually failed (the grep matched xctest success summaries — every
  green run used to post fake "failure" annotations).

### OPEN BUG A — read-along highlight can't keep up (notes AND books)

User report, both surfaces. NOT hopeless — it's render cost, not
architecture. Diagnosis: every sentence change (~1-2×/s) re-evaluates
ReadAlongView's LazyVStack and rebuilds the AttributedString for every
VISIBLE paragraph (attributed(paragraph) runs per paragraph per render).
Fix sketch (next session, small + testable): render ONLY the paragraph
containing readAlongRange with the highlight and all others as plain
Text(text) — i.e. pass the active paragraph id down and make
attributed() a per-paragraph cached AttributedString rebuilt only when
THAT paragraph's highlighted sub-range changes (track lastRange per
paragraph id in @State, or split ReadAlongView into a row view that
Equatable-conforms on (content, isHighlighted, highlightSubrange)).
Throttling further is secondary; the row-level memoization is the real fix.

### OPEN BUG B — chapter % stuck at 0% in the epub reader

epub.js in `flow: "scrolled"` does not populate location.start.percentage
without locations.generate() — which we deliberately skip (it renders the
whole book). The relocated handler forwards percentage verbatim → always 0.
Fix sketch: in reader.js compute the fraction from the rendered iframe's
scroll container (rendition.on("rendered", ... → contents doc
scrollingElement scrollTop/scrollHeight) and post that as `fraction`, OR
drop the % and show "Chapter X of Y" only. Small change in reader.js +
nothing native (handleRelocated already takes the fraction).

### Next session work order

1. Fix OPEN BUG A + B above (both contained: ReadAlongView.swift /
   reader.js + BookReaderView label).
2. Device-test round on those fixes.
3. Release: bump 4 version fields → 1.4.2/29, README + this HANDOVER,
   device checklist in PLAN-V1.4.2-EBOOKS.md §5, fast-forward main,
   tag v1.4.2, attach IPA from the green run.
4. Backlog: PDF TTS (page-group "chapters", never whole-document
   PDFDocument.string), mini-player tap → Books tab jump for books
   (currently jumps to Notes), WAV export stays note-only (whole-book
   render is an OOM hazard).

Golden rules unchanged (see §10). Never push red; device-verify before
promoting; SpeechPlayer changes stay additive; new screens in new files.

## 2026-09-06 addendum #8 — BUG A + B fixed on books-v1.4.2 (0c3256f, CI green, awaiting device test)

- **BUG A (read-along lag)**: ReadAlongView rewritten per the fix sketch —
  rows are now an Equatable `ReadAlongRow` shown through `.equatable()`.
  SwiftUI re-renders only the row whose content or highlighted subrange
  changed; every other row takes a plain `Text(verbatim:)` fast path. This
  also absorbs the faster player progress ticks (they re-evaluate the
  parent body without changing the sentence range). Scroll/anchor behavior
  and the highlight color logic are unchanged.
- **BUG B (chapter % stuck at 0%)**: verified in the vendored epub.min.js
  (0.3.93) — `flow: "scrolled"` uses the continuous manager; with no
  generated locations `percentageFromCfi` returns null, hence 0. Every
  relocated event DOES carry `start.displayed.{page,total}` (viewport-height
  chunks within the CURRENT chapter). reader.js now derives the
  chapter-local fraction from that, clamped 0…1; native side untouched
  (handleRelocated already takes the fraction). A chapter shorter than one
  viewport reports 0% — cosmetic, expected.
- Commit `0c3256f` (pushed, Build IPA run 34045854355 ALL GREEN — logic
  tests, both/kokoro/epub spikes, IPA build). IPA artifact ready for the
  device round.

Still pending (unchanged from addendum #7's work order): the device-test
round on these two fixes, THEN the release commit (bump 4 version fields →
1.4.2/29, README + this HANDOVER, PLAN §5 checklist, fast-forward main,
tag v1.4.2, attach IPA). Backlog unchanged (PDF TTS, mini-player → Books
jump, WAV export stays note-only).

## 2026-09-06 addendum #9 — DEVICE ROUND PASSED; this commit is the v1.4.2 release (1.4.2/29)

User device report on `0c3256f`: (1) read-along highlight in notes "much
much more accurate (not perfect)" — markdown notes less so, that accuracy
nuance is a known follow-up, NOT a regression (mapping engine chars onto
markdown-derived speech text); (2) TTS (esp. Supertonic) noticeably more
responsive — consistent with BUG A's render-cost diagnosis: the row
memoization freed the main thread the playback callbacks hop through;
(3) chapter % works fine. With that, the PLAN-V1.4.2-EBOOKS.md §5 gate is
satisfied minus the deferred PDF TTS item (backlog).

This commit (release commit):
- Version fields bumped 1.4.1/28 → **1.4.2/29** (all FOUR: info.properties
  CFBundleShortVersionString/CFBundleVersion + MARKETING_VERSION/
  CURRENT_PROJECT_VERSION in project.yml).
- README: v1.4.2 status, Books bullet, Storage moved to Settings → Storage,
  stale duplicate feature-tour removed, epub-spike in the CI list, layout
  updated (BooksStore/BookPlaybackController/Book, ZipReader/EpubInfo/
  XhtmlText, epubjs resources, EpubSpike).
- Descoped polish, kept for the backlog: library cover GRID + search field
  (library ships as the row list from Phase 1 — what was device-tested).

Immediately after this commit's CI run goes green: fast-forward main to it
(`git checkout main && git merge --ff-only books-v1.4.2 && git push origin
main`), tag `v1.4.2`, `gh release create` with the IPA from the green run's
`SpeechnotesIOS` artifact (CI's "Verify embedded version" step proves 1.4.2/29).
