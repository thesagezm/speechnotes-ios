# FEATURE BACKLOG — SpeechNotes (assembled 2026-09-08)

Merged from: existing `Docs/MASTER-CATALOG.md` unticked items (M1–M25 + tier lists),
plus three fresh reference-repo scans (readest, koodo-reader, joplin,
AppleNotes2Joplin, BookPlayer, sherpa-onnx, piper-app, expo-kokoro-onnx).
License rules: AGPL/GPL repos → ideas only, never code. Apache-2.0/MIT → code
reusable with attribution. JEX is independent reimplementation (format is
not copyrightable).

## 🔴 Critical (broken / data-loss / ship-blockers)

| # | Feature | Source | Complexity | License | Notes |
|---|---|---|---|---|---|
| C1 | Playback queue + sleep timer | BookPlayer (GPL-3.0 ideas); MASTER 1.10/2.4/3.7 | Medium | GPL → ideas only | Queue = ordered note/book list; sleep timer ends at "end of chapter/note" or after N min; no queue exists today |
| C2 | EPUB position restore (CFI) | Readest (AGPL), MASTER 4.7/M20 | Medium | reimplement | fraction is persisted but never restored; reopening lands at chapter top |
| C3 | Answer a chunk failure without killing the session | user logs + MASTER M13 | Low | — | DONE in Batch 0 (skip-chunk). Residual: a `.failed` state for surfaces that need to distinguish |
| C4 | BooksStore last-writer-wins | MASTER M18 | Low | — | DONE in Batch 1 |

## 🟡 High-impact

| # | Feature | Source | Complexity | License | Notes |
|---|---|---|---|---|---|
| H1 | Lock-screen ±15 s / scrubber + artwork + chapter subtitle | BookPlayer; MASTER 3.1/3.2 | Medium | — | NowPlayingCenter already exists; add MPRemoteCommand skip handlers |
| H2 | Read-along click-to-seek + sentence scrubber | BookPlayer sentence-resume idea + internal | Medium | — | tap a sentence → resume there |
| H3 | Jexport: Markdown/TXT/PDF share for notes | Koodo; MASTER 2.13 | Low | — | big UX win for near-zero code |
| H4 | Joplin JEX export (notebook hierarchy, resources, metadata) | Joplin spec + AppleNotes2Joplin gotchas | Medium | independent reimpl; no code copied | spec sketch in PROGRESS_LOG research notes |
| H5 | In-book search (EPUB text search, result→CFI jump) | Readest; MASTER 4.12 | Medium | — | iterate spine, cache text chunks |
| H6 | Highlights model on books (color + note + CFI range) | Readest/Koodo; MASTER 4.21/7.6 | Medium–High | — | model first, UI after |
| H7 | Voice catalog with size-tiered model downloads + audio previews | piper-app (GPL ideas) + expo-kokoro-onnx (MIT) | Medium | — | fp32/uint8 tiers already exist; add fp16 tier + previews |
| H8 | Accessibility audit: labeled icon buttons, Dynamic Type, rotors | internal V2/V7 + BookPlayer a11y posture | Low | — | 13-symbol formatting bar is the worst offender |
| H9 | Pronunciation lexicon (per-note word→phoneme) | expo-kokoro (MIT) pipeline split | Medium | MIT code OK | fixes names/terms without re-recording |
| H10 | Parallel read (split view, iPad) | Readest; MASTER 7.1 gated | Medium | — | pay-off on the iPad layout work |
| H11 | Smart rewind on resume (back off to sentence start) | BookPlayer | Low | — | BookmarkStore already sentence-snaps — extend to resume N sentences back |
| H12 | One-tap publish of note + audio pair | Koodo "export → Obsidian" idea | Low | — | share sheet already exists |

## 🟢 Nice-to-have

| # | Feature | Source | Complexity | License |
|---|---|---|---|---|
| N1 | Themes: serif font, line-height, true-black | Readest/Koodo; MASTER 4.16/5.8 | Low | — |
| N2 | Reading stats, streaks, time-remaining | Koodo; MASTER 4.8 | Low | — |
| N3 | Reading-ruler / focus mode | Readest | Low | — |
| N4 | Vertical text (CJK) via CSS writing-mode | Koodo | Low | — |
| N5 | iCloud Drive backup / import | Koodo cloud layer | Medium | — |
| N6 | Dictionary lookup on selection (`UIReferenceLibraryViewController`) | Readest | Low | — |
| N7 | OPDS import | Readest | Medium | — |
| N8 | Watch companion | MASTER 7.4 | High | — |
| N9 | AVSpeechSynthesisProvider system voice extension | piper-app | High | — |
| N10 | Reading-goal notifications | Koodo stats | Low | — |

## Explicitly NOT doing

- sherpa-onnx streaming progress callback: the app's chunk-ahead pipeline is
  already ahead of what sherpa's example does; integrate only if first-audio
  latency regresses below 500 ms.
- BookPlayer's full database model (CoreData migration is not worth it now —
  SpeechLogic's Codable stores are scaling fine at 41 notes).
- Piper engine: Supertonic covers the multilingual slot; adding a third ONNX
  TTS pipeline is duplication.
