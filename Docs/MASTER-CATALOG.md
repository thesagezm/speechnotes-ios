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
