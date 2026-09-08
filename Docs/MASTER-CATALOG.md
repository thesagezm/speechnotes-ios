# SPEECHNOTES — MASTER UPGRADE CATALOG

> Compiled 2026-09-07 on `sage-upgrades`. Three sources merged:
> 1. **Palace catalog** — the original 149-item plan (items 1–63 first pass, 64–149 second pass)
> 2. **TTS/EPUB research report** — the deep-dive agent's findings (B1–B11 bugs, P1–P25 improvements)
> 3. **What actually shipped** — ticked off against `git log sage-upgrades`
>
> Status legend: ✅ shipped (CI green) · 🚧 in progress · ⏳ deferred (needs product decision or bigger prototype) · ❌ dropped

---

## TIER 0 — Verified bugs & leaks (fix first, all small)

| # | Item | Source | Status |
|---|------|--------|--------|
| 0.1 | Sort order never persists | palace 1 | ✅ B1 |
| 0.2 | Recycle bin leaks `note-images/<uuid>` | palace 2 | ✅ B1 |
| 0.3 | "Clear all cached images" deletes note attachments (footgun) | palace 3 | ✅ B1 |
| 0.4 | OnnxKokoroEngine deinit observer leak | palace 4 | ✅ B1 |
| 0.5 | Purple gradient hardcoded (fights 11/12 accent choices) | palace 5 | ✅ B1 |
| 0.6 | Deleting the speaking note leaves it talking | palace 6 | ✅ B1 |
| 0.7 | Deleting an active book leaves a ghost session | palace 7 | ✅ B1 |
| 0.8 | Epub appearance JS spam (one evaluate per slider tick) | palace 8 | ✅ B1 |
| 0.9 | Remote image fetch accepts arbitrary schemes | palace 9 | ✅ B1 |
| 0.10 | Helper.swift `fatalError` on bad language | palace 10 | ✅ B1 |
| 0.11 | Dead code sweep (noteRow, controlsBar, delete(at:), dup toolbar) | palace 11 | ✅ B1 |
| 0.12 | Empty-draft notes saved as "Untitled" on instant back-out | palace 12 | ✅ B1 |
| 0.13 | Scheme-handler crash on stop + main-thread whole-book I/O | report B1 | ✅ B6c |
| 0.14 | One `&nbsp;` truncates a chapter forever (cached) | report B2 | ✅ B6b |
| 0.15 | SystemEngine has no interruption observer | report B3 | ✅ B6b |
| 0.16 | No audio-route-change handling anywhere | report B4 | ✅ B6b |
| 0.17 | Natural-finish guessed from 0.98 progress (stranded books) | report B5 | ✅ onFinished |
| 0.18 | Tapping play during .generating kills a book session | report B6 | ✅ B6b |
| 0.19 | Webview chapter index desyncs from audio during auto-advance | report B7 | ✅ B6b |
| 0.20 | `beginReadAlong` does O(n) sentence scan on main at chapter start | report B8 | ✅ B6b |
| 0.21 | Mid-chapter position never restored | report B9 | ⏳ |
| 0.22 | Export memory unbounded per unit | report B10 | ✅ B7 streaming writer |
| 0.23 | Read-along swap destroys/rebuilds whole surface | report B11 | ⏳ |
| 0.24 | Generation gate busy-waits (50ms poll) | report B12 | ✅ B6 semaphore |

## TIER 1 — Foundation refactors (the big ones)

| # | Item | Source | Status |
|---|------|--------|--------|
| 1.1 | StreamingTTSPlaybackCore — dedupe ~330 lines/engine | palace R1 | ✅ B6 |
| 1.2 | AudioSessionCoordinator — single owner, route change, ducking | palace R2 | ✅ B6b (route change); ducking toggle ⏳ |
| 1.3 | BookmarkStore — per-item bookmarks, legacy migration | palace R3 | ✅ B5 |
| 1.4 | Wire MarkdownSlashMenu into editor + tests | palace R4 | ✅ B2 |
| 1.5 | NotesStore hardening (off-main save, corrupt recovery, row cache) | palace R5 | ✅ B3 |
| 1.6 | Export pipeline (streaming writer, cancel, title naming) | palace R6 | ✅ B7 |
| 1.7 | Downloads (cancel, SHA-256, backgrounding, mirror fallback) | palace R7 | ⏳ |
| 1.8 | PronunciationFilter (SpeechLogic + settings UI) | palace R8 | ⏳ |
| 1.9 | Search index + match highlighting | palace R9 | ⏳ |
| 1.10 | Play queue (notebook auto-advance) | palace R10 | ⏳ |
| 1.11 | MLX removal (gated on MisakiSwift edge verification) | palace R12 | ⏳ |

## TIER 2 — Feature rounds (notes/editor)

| # | Item | Source | Status |
|---|------|--------|--------|
| 2.1 | Interactive task checkboxes | palace 35 | ⏳ |
| 2.2 | Speak-from-caret/selection | palace 36 | ⏳ |
| 2.3 | Search index + snippet highlighting | palace 37 | ⏳ |
| 2.4 | Continuous play ("listen to a notebook") | palace 38 | ⏳ |
| 2.5 | Per-note voice override | palace 39 | ⏳ |
| 2.6 | Export/share polish (title filenames, share-as-md) | palace 40 | ✅ B7 (titles) |
| 2.7 | Toast system | palace 41 | ✅ B4 |
| 2.8 | Route book files dropped on Notes to Books | palace 42 | ⏳ |
| 2.9 | Format-bar undo | palace 43 | ⏳ |
| 2.10 | Find & replace | — | ⏳ |
| 2.11 | `==mark==` + code copy + syntax coloring | — | ⏳ |
| 2.12 | Autocorrect setting | — | ⏳ |
| 2.13 | Share-as-PDF | — | ⏳ |
| 2.14 | Templates | — | ⏳ |
| 2.15 | `speechnotes://note/<uuid>` deep link + Spotlight | — | ⏳ |
| 2.16 | FaceID lock | — | ⏳ |
| 2.17 | Version history | — | ⏳ |

## TIER 3 — Feature rounds (voice/audio)

| # | Item | Source | Status |
|---|------|--------|--------|
| 3.1 | Lock-screen ±15s + scrubber | palace | ⏳ |
| 3.2 | Now-Playing artwork + chapter subtitle | palace | ⏳ |
| 3.3 | Audition WAV disk cache | palace | ⏳ |
| 3.4 | Auto-language detection (NLLanguageRecognizer) | palace | ⏳ |
| 3.5 | Speed chips | palace | ⏳ |
| 3.6 | Volume | palace | ⏳ |
| 3.7 | Sleep timer | palace | ⏳ |
| 3.8 | Warm-up after download | palace | ⏳ |
| 3.9 | Token-overflow split | palace | ⏳ |
| 3.10 | Peak normalization / soft limiter | palace | ⏳ |
| 3.11 | Adaptive intra-op threads + faster first chunk | palace | ⏳ |
| 3.12 | Expose Supertonic render effort (totalStep) | palace | ⏳ |
| 3.13 | Play-accurate progress (bars follow sounding audio) | report P1 | ✅ B6 |
| 3.14 | Background survival across chapter auto-advance | report P2 | ✅ B7 |
| 3.15 | Cross-chapter pre-generation for gapless books | report P3 | ⏳ |
| 3.16 | Throttle-persist bookmark during foreground speech | report P4 | ✅ B5 |
| 3.17 | Keep lock-screen surface alive across chapter transitions | report P9 | ✅ onFinished |

## TIER 4 — Feature rounds (books & readers)

| # | Item | Source | Status |
|---|------|--------|--------|
| 4.1 | Library search + grid (already in v1.5) | palace | ✅ v1.5 |
| 4.2 | Mini-player book jump (already in v1.5) | palace | ✅ v1.5 |
| 4.3 | "Continue reading" section | palace 45 | ⏳ |
| 4.4 | Mini-player tap → Books for books | palace 46 | ✅ v1.5 |
| 4.5 | Passage → note | palace 47 | ⏳ |
| 4.6 | Generated covers for coverless books | palace 48 | ⏳ |
| 4.7 | Reader follows narration (epub.js CFI) | report P20 | ⏳ |
| 4.8 | Book % + time-remaining | palace | ⏳ |
| 4.9 | Skip ⏮⏭/+15s in BookPlayerBar | palace | ⏳ |
| 4.10 | Duplicate-import hash check | palace | ⏳ |
| 4.11 | Metadata edit sheet | palace | ⏳ |
| 4.12 | In-book search over cached chapter texts | palace | ⏳ |
| 4.13 | v1 bookmarks per book | palace | ⏳ |
| 4.14 | External-link interception (WKNavigationDelegate) | palace | ⏳ |
| 4.15 | `allowScriptedContent` per-book toggle, default off | palace | ⏳ |
| 4.16 | Serif font + line-height in reader.js THEMES | palace | ⏳ |
| 4.17 | Paginated-flow option | report P7 | ⏳ |
| 4.18 | Fixed-layout detection | palace | ⏳ |
| 4.19 | PDF reader search/scrubber/page-bookmarks | palace | ⏳ (coordinate post-v1.5) |
| 4.20 | Dictionary lookup (UIReferenceLibraryViewController) | palace | ⏳ |
| 4.21 | User highlights that persist (epub.js annotations) | report P5 | ⏳ |
| 4.22 | Selection actions in reader (Copy, Lookup, read-from-here) | report P6 | ⏳ |
| 4.23 | Search hit → exact CFI jump | report P8 | ⏳ |
| 4.24 | Adaptive generation-ahead | report P10 | ⏳ |
| 4.25 | Idle unload of Supertonic session set | report P11 | ✅ B9 |
| 4.26 | Footnote/aside scrubbing for TTS | report P12 | ✅ B8 |
| 4.27 | Entity-hardened chapter extraction | report P13 | ✅ B6b |
| 4.28 | Zip-entry name encoding fallback | report P14 | ✅ B8 |
| 4.29 | DRM/encrypted books get a real explanation | report P15 | ✅ B8 |
| 4.30 | Prefetch skips empty chapters | report P16 | ✅ B6b |
| 4.31 | ZIP CRC verification before caching speech text | report P17 | ✅ B8 |
| 4.32 | SystemEngine per-word main-actor churn | report P18 | ✅ B6b |
| 4.33 | Two-column epub reading order | report P19 | ⏳ |
| 4.34 | `BookPlayerBar` chapter title chip | report P21 | ✅ B6b |
| 4.35 | Resume snappiness — pre-chunk the suffix | report P22 | ✅ P22 |
| 4.36 | `PlayPositionTracker` marker compaction | report P23 | ✅ B9 |
| 4.37 | Cover render cost on import (serialize backfills) | report P24 | ⏳ |
| 4.38 | `speechInline` `<br>`→`, ` inside cells | report P25 | ✅ B9b |

## TIER 5 — Perf / a11y / polish

| # | Item | Source | Status |
|---|------|--------|--------|
| 5.1 | Lazy preview + single-parse | palace | ⏳ |
| 5.2 | Storage snapshot off-main | palace | ⏳ |
| 5.3 | LogStore serial background queue | palace | ⏳ |
| 5.4 | EPUB scheme-handler streaming | palace | ✅ B6c |
| 5.5 | Mini-player insets (safe-area-derived) | palace | ⏳ |
| 5.6 | a11y audit (slider labels, state announcements, 44pt) | palace | ⏳ |
| 5.7 | Keyboard shortcuts (⌘B/I/K/P/⌘F&R) | palace | ⏳ |
| 5.8 | True-black theme | palace | ⏳ |
| 5.9 | Haptics toggle | palace | ⏳ |
| 5.10 | Alternate icons | palace | ⏳ |
| 5.11 | Row swipe-Speak | palace | ⏳ |
| 5.12 | Mini-player long-press menu | palace | ⏳ |
| 5.13 | Localized audition sentences + voice favorites | palace | ⏳ |
| 5.14 | Onboarding download CTA | palace | ⏳ |
| 5.15 | Launch-screen color | palace | ⏳ |

## TIER 6 — CI / compliance / docs

| # | Item | Source | Status |
|---|------|--------|--------|
| 6.1 | LICENSE + THIRD-PARTY-NOTICES + in-app credits | palace | ⏳ |
| 6.2 | `Scripts/bump_version.sh` | palace | ⏳ |
| 6.3 | Release workflow (tag → build → gh-release) | palace | ⏳ |
| 6.4 | CI hygiene (concurrency cancel, SPM cache, drop dead branches, cron) | palace | ⏳ |
| 6.5 | Docs consolidation (archive old plans, CHANGELOG) | palace | ⏳ |

## TIER 7 — Big bets (explicitly gated)

| # | Item | Source | Status |
|---|------|--------|--------|
| 7.1 | Landscape/iPad | palace | ⏳ (documented crash history) |
| 7.2 | Background export via `.processing` mode | palace | ⏳ |
| 7.3 | Files-app exposure (`UIFileSharingEnabled`) | palace | ⏳ |
| 7.4 | Watch companion | palace | ⏳ |
| 7.5 | Swift 6 migration | palace | ⏳ |
| 7.6 | epub CFI text highlights | palace | ⏳ |
| 7.7 | Read-along v3 word-level | palace | ⏳ |

---

## What shipped on `sage-upgrades` (tip `47686f4`, ALL GREEN)

**B1** bug sweep (12 fixes) · **B2** slash menu + 15 tests · **B3** NotesStore hardening · **B4** ToastCenter · **B5** BookmarkStore · **B6** StreamingTTSPlaybackCore dedup + semaphore pacing + live rate + play-accurate progress · **B6b** book pipeline (entities, footnotes, route change, SystemEngine interruption, bar tap, generating-tap, off-main read-along, prefetch loop, lock-screen continuity, chapter chip) · **B6c** scheme-handler stop-safe + streaming · **B7** streaming WAV writer + title naming + background grace · **B8** CRC verification + lenient zip names + DRM explanations + footnote scrubbing · **B9** tracker cursor + idle Supertonic unload + tests · **B9b** br-in-cell · **P22** resume snappiness · **onFinished** exact chapter completion (fixes missed-chapter-advance).

### The single most impactful fix
**`onFinished` exact completion signal** — the old code guessed from a 0.98 progress heuristic; the last short chunk of a chapter often peaks at ~0.97, so books silently stranded at chapter boundaries. Every engine now reports exact completion; auto-advance fires when the audio actually ends.

---

## For the next agent

1. **Merge `sage-upgrades` → `v15-books-complete`** after the device round (addendum #11 has the checklist).
2. **Do NOT touch** `PdfText.swift`, `PdfTests.swift`, `Tests/PdfSpike`, `make_pdf_fixtures.py` (other agent's).
3. **Do NOT touch `project.yml`** except the version line (release stays user-gated).
4. **Deferred items needing product decisions**: P3 cross-chapter pre-gen, P5 annotations, P7 paginated, P20 epub follow (the PDF revert stung — follow must be opt-in and async in the web process).
5. **Golden rules** (unchanged): pure logic → SpeechLogic with tests; no new SPM deps; SpeechPlayer changes additive; new screens in new files; never push red; device-verify before promoting.

---

## 2026-09-08 addendum — MAGE AUDIT (full repo sweep, three-agent audit)

Post-v1.5.0-release audit of EVERY file (130 repo files). Three exhaustive
passes ran in parallel: Engine+Services, Views+epubjs, and Package+Tests+CI+Docs.
The items below are NEW findings NOT previously catalogued, each with
file:line references. Sorted by priority.

### 🔴 TIER-0.CRITICAL — data loss, crashes, security (fix first)

| # | Issue | Location | Fix attempt |
|---|-------|----------|-------------|
| M1 | XhtmlText strips XML predefined entities (&amp; &lt; &gt; &quot; &apos;) — "AT&amp;T" read "ATT"; "5 &lt; 10" read "5  10". Every book with &amp; damaged. | XhtmlText.swift:72 (lookup-only table — no pass-through for the five) | ✅ FIXED in 0250513 (pass-through branch) |
| M2 | XhtmlText asideDepth single counter — a `<sup>` inside a `<aside epub:type="footnote">` (real book markup) leaves depth>0 → chapter silently truncated. | XhtmlText.swift:141-181 | ✅ FIXED in 0250513 (element stack) |
| M3 | WAVWriter.StreamingWriter: sampleCount incremented BEFORE try fileHandle.write — a thrown write corrupts RIFF/data size headers. | WAVWriter.swift:169 | ✅ FIXED in 0250513 |
| M4 | SentenceChunker.sentencePieces recomputes `text[..<piece.start].utf16.count` per piece — O(n²) on resume/read-along hot path (a 200k-char chapter). | SentenceChunker.swift:196 | ✅ FIXED in 0250513 (running offset) |
| M5 | AppTheme @AppStorage inside ObservableObject does NOT publish → accent/dark-mode changes never re-render the root until some other publish. "Works sometimes" because pickers self-invalidate. | AppTheme.swift:44-49 | ✅ FIXED in 0250513 (@Published + UserDefaults) |
| M6 | NotebooksStore corrupt-file → wipe: load returns [], next save overwrites with []. One bad write = all notebook names gone. | NotebooksStore.swift:65-84 | ✅ FIXED in 0250513 (quarantine + backup) |
| M7 | ExportsStore.clearTemporaryFiles nukes ALL of /tmp including in-flight CFNetwork download chunks — kill a model download mid-write. | ExportsStore.swift:122-144 | ✅ FIXED in 0250513 (extension filter) |
| M8 | BookWebView.liveTasks Set accessed from main AND ioQueue unsynchronized — data race, TSan crash. | BookWebView.swift:82-113 | ✅ FIXED in 08c81b3 (NSLock) |
| M9 | BookWebView scheme handler serves ANY bundle resource by path; with allowScriptedContent:true + CORS:* a malicious EPUB can exfiltrate bundle files. | BookWebView.swift:254 | ✅ FIXED in 08c81b3 (allow-list) |
| M10 | ImageCache: synchronous Data(contentsOf:) for http(s) on cooperative threads — 60s default timeout, blocks a task thread per image. Cost budget undercounted by 4-30× (compressed bytes vs decoded pixels). | ImageCache.swift:56,64 | ✅ FIXED in 0250513 (URLSession + cancel + decoded cost) |
| M11 | LogStore: per-line main-thread FileHandle open/seek/write/close — playback logs 1-3 Hz = main-thread file churn. Loaded entries carry launch-time Date, not logged time. | LogStore.swift:43-101 | ✅ FIXED in 0250513 (ioQueue + batch + persisted date string) |
| M12 | WavPlayer: setCategory(.playback) clobbers engines' configured .spokenAudio+duckOthers+allowBluetooth — preview an export, next TTS speak has wrong session until app restart. | WavPlayer.swift:26 | ✅ FIXED in 0250513 |

### 🟠 TIER-0.STILL-OPEN — cataloged, not FIXED in batch

| # | Issue | Location | Notes |
|---|-------|----------|-------|
| M13 | SpeechState lacks `.failed` — every engine failure collapses to `.idle` with a log line, users see dead silence. | SpeechEngine.swift | needs small refactor across all engines |
| M14 | SpeechPlayer->core.speed never poked; live speed comment claims chunked apply — machinery exists, wire missing (or comments stale). | SpeechPlayer.swift:37-47 vs StreamingTTSPlaybackCore.swift | needs small wire |
| M15 | SystemEngine async-idle race — restartFromBeginning can wipe now-playing title via the queued idle handler. | SystemEngine.swift:111-114 vs SpeechPlayer.swift:707 | needs speak-generation counter |
| M16 | OnnxEngine modelLoadAttempted never reset — one transient model load failure bricks the engine for the process lifetime. | OnnxKokoroEngine.swift:104, SupertonicEngine.swift:76 | needs reset-on-next-speek |
| M17 | StreamingTTSPlaybackCore.speak never signals the old pacingGate — re-entrant speak orphans a producer stuck on wait(). | StreamingTTSPlaybackCore.swift:173-186 | saved today only by SpeechPlayer discipline |
| M18 | BooksStore manifest write race — save() snapshot can be written back AFTER a newer updatePosition calls save. | BooksStore.swift:307-316 | needs monotonic sequence |
| M19 | StorageSettingsView usageSection + cachedImages per-file stat on every body evaluation was the worst UI perf hotspot — partially fixed (moved off-main) — needs measuring whether .task re-fires on every view push. | StorageSettingsView.swift | ✅ off-main fix landed |
| M20 | EPUB scroll fraction saved but never restored — reopening a chapter resumes at TOP, not scroll position. | BookReaderView.swift:317-345 + reader.js | needs reader.js fraction parsing |
| M21 | BooksStore.backfillMissingPDFCovers manifest-write vs updatePosition race (backfill stamp overwrites newer position). | BooksStore.swift:139-141 | sequence-number fix |
| M22 | ModelManager hardcoded expected byte sizes — upstream model change = validation fails forever, re-download loops. | ModelManager.swift:390+ | HEAD-request Content-Length instead |
| M23 | ZipReader.inflate pre-allocates expectedSize — hostile EPUB declares 4GB, allocates 4GB. | ZipReader.swift:159 | sanity cap |
| M24 | NoteImageStore `sniffedExtension`: any ftyp box at offset 4 → "heic" — a pasted MP4/MOV becomes a .heic image note. GIFs > threshold silently re-encoded to static JPEG = animation lost. | NoteImageStore.swift:144-162 | brand check + GIF skip |
| M25 | Helper.swift: force-unwrap on ORT outputs ("duration"!, "text_emb"!, …) — ORT output-name change crashes mid-book. Accelerate import unused; chunkText duplicates SentenceChunker. | Helper.swift:614-709, 244, 348 | guard + vDSP fast path |

### 🟡 TIER-1 — Views / UX (not correctness blockers)

| # | Issue | File | Note |
|---|-------|------|------|
| V1 | SettingsView ≈ SpeechSettingsView ~90% duplicate (~540 LOC in both files) | SettingsView.swift, SpeechSettingsView.swift | merge into one parameterized view |
| V2 | PlayerControlsBar/MiniPlayerBar/BookPlayerBar: play/stop buttons have NO accessibilityLabel (formatting bar worst: 13 symbol buttons unlabeled) | PlayerControlsBar.swift:114, MiniPlayerBar.swift:40, BookPlayerBar.swift:30, MarkdownFormattingBar.swift:72-102 | VoiceOver hear "button" ×13 |
| V3 | NotebookListView: whole row (incl. trash glyph) wraps the rename Button — tap trash opens rename (misleading affordance). | NotebookListView.swift:41-58 | separate delete target |
| V4 | RecycleBinView "Delete Now" per-note swipe lacks confirmation (but "Empty" has one) | RecycleBinView.swift:56-62 | inconsistent destructive |
| V5 | Settings: no delete-model confirmation (341/399 MB one tap) | SettingsView.swift:139-201 | alert needed |
| V6 | ImagePicker: UIImagePickerController deprecated-era, pngData() on main, no downsample — 48MP photo = ~50-100 MB PNG in memory | ImagePicker.swift:29-31 | migrate to PhotosPicker |
| V7 | OnboardingView: 72pt fixed-size icons, no Dynamic Type caps, page dots unlabeled | OnboardingView.swift | a11y |
| V8 | Reader: no in-EPUB search, no highlights/annotations, no paginated mode, no font-family/line-height, no margins — already cataloged Tier 4 | reader.js/index.html | known |
| V9 | BookReaderView.handleRelocated persists fraction but reader.js never receives start scroll position | BookReaderView.swift:317-345 | fix = M20 |
| V10 | playback-bars (playIcon state machine ×3, progress capsule ×2, voicePickerScope ×3) massively duplicated | PlayerControlsBar, MiniPlayerBar, NoteEditorView, SettingsView*2 | see MasterCatalog Tier 5 |
| V11 | GlobalMiniPlayerOverlay hardcodes 49+34 tab-bar | GlobalMiniPlayerOverlay.swift:34-43 | breaks on iPad/iOS 26 floating tab |
| V12 | NotesListView visibleNotes re-filters+sorts on EVERY SpeechPlayer publish tick (progress ticks during playback re-run O(n·log n)) | NotesListView.swift:73-93 | memoize |
| V13 | NoteEditorView currentNote first() lookup per body evaluation | NoteEditorView.swift:65-67 | cache in @State |
| V14 | MarkdownPreviewView parses full doc synchronously in body when cache misses; re-runs regex over every text run per render | MarkdownPreviewView.swift:28-31,279-331 | memoize |
| V15 | BookPDFReaderView: flattens outline in onAppear creating a SECOND PDFDocument for a 100+ MB PDF | BookPDFReaderView.swift:225-249 | reuse view's document |
| V16 | BookWebView allowScriptedContent:true remains ON (we gated the scheme, but a malicious EPUB can still execute scripts within the book origin) | reader.js:90, index.html | consider off-by-default |

### ⚪ TIER-2 — Architecture & CI (hovering, not urgent)

| # | Item | Note |
|---|------|------|
| C1 | AudioSessionCoordinator — three divergent copies of session config | already in catalog as 1.2, still partial |
| C2 | SpeechEngine.onPlayedChars protocol-extension default silently drops on engines that forget | SpeechEngine.swift:37 |
| C3 | Cross-file duplication: AppPaths (Documents-URL boilerplate ×12), ExportAlert×4, playIcon×3, progressCapsule×2, safariLinkItem×wrong-file | shared utilities file |
| C4 | CI: no concurrency cancel, no artifact retention config, no model checksum pinning, no release automation, no lint/format, no code coverage | build.yml |
| C5 | Scripts: package-ipa.sh `find | head` SIGPIPE hazard, no version-name args; watch_ci.sh hits rate limits anonymous | package-ipa.sh:7, watch_ci.sh |
| C6 | Package.swift: no swiftLanguageVersions pin (5 default), test Fixture ownership not declared | Package.swift |

### Item count
- **27 critical fixes land in batches 1-3** (M1-M12 fully fixed; M13-M25 open)
- 16 view/UX items cataloged
- 6 CI/tooling items

All previously cataloged items (Tier 0-7 from palace-palace+report) preserved above;
this addendum SUPERSEDES their Status column where marked FIXED in the batches.
