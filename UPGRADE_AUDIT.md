# UPGRADE AUDIT — SpeechNotes, 2026-09-08

Snapshot of branch `sage-upgrades` @ `9157878` (post-v1.5.0 + batches 1–3). This
is the input document for FEATURE_BACKLOG.md and INTEGRATION_PLAN.md. Earlier
findings (M1–M25) are consolidated in `Docs/MASTER-CATALOG.md`; this audit
distills the same material plus what the user's logs added today.

## 1. Architecture map

```
App/
├── Engine/
│   ├── SpeechEngine.swift          protocol + SpeechState
│   ├── SystemEngine.swift          AVSpeechSynthesizer wrapper (fallback)
│   ├── OnnxKokoroEngine.swift      Kokoro-82M ONNX, fp32 + uint8 tiers
│   ├── SupertonicEngine.swift      Supertonic-3 (4 ONNX sessions, 10 styles)
│   ├── Supertonic/Helper.swift     vendored upstream (~849 LOC, MIT)
│   ├── StreamingTTSPlaybackCore.swift  shared chunked pipeline for the two ONNX engines
│   └── PlayPositionTracker.swift   sample-clock → UTF-16 char cursor
├── Services/
│   ├── SpeechPlayer.swift          singleton façade — engine swap, bookmarks, read-along
│   ├── BookPlaybackController.swift chapter chain, background grace
│   ├── NowPlayingCenter.swift      lock-screen / Control Center
│   ├── ModelManager.swift          downloads, validation, voice catalog state
│   ├── {Notes,Notebooks,Books,Bookmark,Exports,...}Store.swift
│   └── PdfSpeechText.swift         PDF text + Vision OCR fallback
├── Views/  (29 SwiftUI views — Books/Notes/Settings/Player)
└── Models/ (Book, Note, Notebook, VoiceCatalog)

Packages/SpeechLogic/   pure, test-covered logic
   SentenceChunker, XhtmlText, PdfText, MarkdownText(+SlashMenu),
   ZipReader (CRC-checked), WAVWriter (streaming), NoteImageStore,
   TextHash, EpubInfo
```

## 2. Engine pipeline (as it stands today, post-Batch-0)

- Chunking: `SentenceChunker.chunks(firstMaxChars=chunkMaxChars, batchMaxChars=chunkMaxChars)`
  — Kokoro 160 chars, Supertonic 200 chars. v1.5 sizing unchanged.
- Pacing: semaphore-bounded producer, `generationAheadLimit` chunks ahead
  (Kokoro 3, Supertonic 2).
- Resilience (post-Batch-0): 1 retry, then skip the chunk (slot sentinel; the
  read-along cursor and the natural-finish path both account for it silently).
- Rate: live — `SpeechEngine.speed` written per slider change, read per chunk.
- Load: model loads on first speak; `modelLoadAttempted` latches only on success.
- AVAudioSession: configured lazily at first playback (kills OSStatus -50 spam).

## 3. Open findings carried forward (from MASTER-CATALOG addendum, verified today)

| ID | What | File | Severity |
|---|---|---|---|
| M13 | No `.failed` state in `SpeechState` — errors collapse to idle | SpeechEngine.swift:3 | high |
| M18 | `BooksStore.save` encode-then-write race — stale manifest can clobber fresh position | BooksStore.swift:307 | medium |
| M20 | EPUB scroll fraction persisted but never restored — reopens land at chapter top | BookReaderView.swift:347 | medium |
| M22 | Hardcoded model byte sizes in ModelManager — upstream swap = infinite re-download loop | ModelManager.swift:41 | medium |
| M23 | `ZipReader.inflate` trusts declared size (zip-bomb vector) | SpeechLogic/ZipReader.swift:159 | medium |
| M24 | `NoteImageStore.sniffedExtension`: any ftyp → .heic, large GIF flattened | SpeechLogic/NoteImageStore.swift:144 | medium |
| M25 | Force-unwraps on ORT output names in Supertonic Helper | Supertonic/Helper.swift:614+ | high |
| V2  | Unlabeled icon buttons (PlayerControlsBar, MiniPlayerBar, BookPlayerBar, MarkdownFormattingBar 13 symbols) | Views/*.swift | high a11y |
| V4/V5 | No confirmation on "Delete Now" (recycle bin) / model deletion | RecycleBinView, SettingsView | medium |
| V6  | ImagePicker: deprecated picker + full-res PNG on main thread | ImagePicker.swift:29 | medium |
| V11 | Hardcoded 49+34 tab-bar inset in mini player | GlobalMiniPlayerOverlay.swift:34 | medium |
| V12/V14/V15 | List re-sort on progress tick; markdown preview parse on main; duplicate PDFDocument open | various | medium/low |
| C1  | Three divergent AVAudioSession config copies (post-Batch-0: two — core + SystemEngine; coordinator still open) | Engine/*.swift | — |
| C6  | SpeechLogic Package.swift has no swiftLanguageVersions pin | Packages/SpeechLogic | low |

## 4. User-reported, fixed in Batch 0

See PROGRESS_LOG.md for the full narrative. All four (retry storm, quit-bug,
sluggish-since-v1.5, -50 session spam) trace to the pipeline layer, not model
quality or the chunker.

## 5. Still-unfixed MASTER-CATALOG items (pri order for FEATURE_BACKLOG)

- Engine robustness: M13 (`.failed` state), 3.15 cross-chapter pre-generation.
- Data: M18 BooksStore race; M22 downloader size check; M23/M24 SpeechLogic hardening.
- Audio UX: 1.10 / 2.4 playback queue + continuous note play; 3.1 lock-screen ±15 s; 3.7 sleep timer; 3.2 artwork/chapter subtitle.
- Reader: M20 CFI restore; 4.7 reader-follows-narration; 4.21/7.6 highlights; 4.12/4.19 search.
- Notes/export: 2.13 share-as-PDF/md/txt; Joplin/JEX export (new in this cycle).
- A11y: 5.6 audit, V2 labels, V7 onboarding.
