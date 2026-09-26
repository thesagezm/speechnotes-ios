# Speechnotes iOS

An offline, Speech Note (Linux)-style app for iPhone — built entirely from Linux,
compiled on GitHub Actions macOS runners, sideloaded via SideStore + LiveContainer.

**Current status: v1.7.1 — Books complete (EPUB, PDF and audiobooks, with
full TTS for the first two), landscape with the playback controls on a
lateral rail, and the v1.7.0 device round's four bugs fixed: the Soprano
download completes and validates (its config files were fetched from the
wrong Hugging Face path and 404'd at 99%), JEX import exists (Settings →
Backup → Import from Joplin), audiobooks read chapters from real chapter
TRACKS as well as `chpl` atoms plus their embedded covers, and the Joplin
round-trip is tested both ways.** Pick an
engine in Speech Settings (listed worst → best), download
its model once, and notes are spoken fully offline (airplane-mode tested):

| Engine | Model size | Voices | Notes |
|---|---|---|---|
| Apple (system) | 0 | all system voices | Instant, no download |
| **Kokoro small** (ONNX, CPU) | ~177 MB | 28 (US/UK, m/f) | Lightweight uint8 tier |
| **Soprano** (ONNX, CPU) | ~110 MB | 1 (English) | Fast English voice — KV-cached audio decoder, reads numbers/currency as words |
| **Kokoro** (ONNX, CPU) | ~341 MB | 28 (US/UK, m/f) | Main engine — fp32 quality build |
| **Supertonic** (ONNX, CPU) | ~399 MB | 10 styles × 31 languages | Multilingual — flow-matching TTS |

A sentence the model cannot synthesize is skipped on the first attempt — one
soft tone, then the next sentence. There is no retry: a second attempt at the
same text fails the same way, and the wait for it is silence the listener pays
for. Text is cleaned at import so the things that used to fail (soft hyphens,
zero-width joiners, control bytes, embedded-font glyphs) never reach the model.

Reader and reading surfaces (v1.6.1→v1.7.0, all from device reports):

- **Landscape, controls on the side.** Rotate the phone: the playback
  controls become a vertical rail on the trailing edge — voice, play/stop,
  read-along, a top-down progress strip and the speed slider — leaving the
  reading surface its full height in both orientations.
- **Tap to hide the chrome.** One tap on a reading surface hides the nav bar
  and title; another brings them back. Typing brings them back too, because
  editing needs the toolbar.
- **The note stays where you put it.** Scrolling still works; the text stops
  dead at the ends instead of drifting past them.
- **Spacing you can tune.** Appearance → Spacing has three sliders — line
  spacing, space between blocks, and table room (up to 2×) — with the
  defaults already roomier than the old hardcoded values.
- **Tables wrap.** Columns take a fair share of the width (weighted by
  content) with a floor at their longest word, and long cells break across
  lines — the table only scrolls sideways when even a fair share cannot fit.
- **The image viewer is a real photo viewer.** Pinch-zoom decelerates and
  anchors on the point under your fingers, double-tap zooms toward where you
  tapped, and a tap while zoomed in zooms back out.
- **Rotation is smooth.** The reading surfaces hold one layout across
  orientations and cross-arrange their controls, so the text, caret and
  scroll position survive the change instead of being rebuilt.

Feature tour:

- **Notes** — create/edit/delete, autosave (debounced, flushed on exit and
  backgrounding), search, sort (edited/created/title), date sections, swipe
  actions (pin / delete / share text / export audio), drag & drop.
- **Notebooks & organization** (Joplin-style) — flat notebooks with a chip
  row for scoping, move notes between them, plus pin (Pinned section on top)
  and favorite (star). Titles auto-derive from the note's first sentence.
  Backup exports one notebook, the unfiled notes, or the whole library.
- **Books** (complete in v1.6.0) — the Books tab: import EPUB, PDF and
  audiobooks (M4B / M4A / MP3, Files picker or Open-In) into a cover grid with
  search. An audiobook plays the audio it already contains, with the chapter
  list read from the file's own metadata (a `chpl` atom or ID3 `CHAP` frames)
  and no synthesis at all. EPUBs render
  chapter-by-chapter in a real book reader (themes, text size, native table of
  contents, per-book position); PDFs open in a full-fidelity PDFKit viewer with
  an outline sidebar. Any book can be spoken: chapter narration with
  auto-advance (exact audio-completion signal, no stranding at chapter
  boundaries), sentence-snapped resume, and the same read-along highlighting as
  notes. PDF chapters come from the document's own outline, with font-size
  heading detection and honest page ranges as fallbacks; scanned pages speak
  via Vision OCR, and two-column papers read left→right. Per-chapter WAV
  export. DRM/locked books explain themselves on the shelf.
- **Streaming playback** — sentence-chunked generation with playback starting
  after the first sentence; pause/resume/stop; speed slider; phone-call
  interruption handling; lock-screen / Control Center controls.
- **Read-along highlighting** — a dedicated reader replaces the editor while
  a note speaks (toggleable from the player bar), highlighting the sentence
  actually sounding via play-time position tracking, with auto-scroll.
- **Resume bookmarks** — stopped notes resume from the prior sentence
  boundary (valid 30 days); auto-resume after a brief backgrounding.
- **Mini-player** — rounded card above the tab bar, minimizable to a
  floating progress-ring bubble; it yields whenever the note's own editor
  controls are on screen.
- **Voice picker** — searchable, grouped, recent voices, tap-to-audition
  (hear a voice before committing). Supertonic adds a language selector
  (English, Korean, Japanese, German, French, +26 more).
- **Markdown option** (Settings → Notes) — preview rendered markdown in the
  editor (eye/pencil toggle), and speech reads the plain text without
  markdown symbols.
- **Import** — .txt / .md / .pdf via the Files picker, drag & drop,
  `speechnotes://import?text=…` links, and clipboard; iCloud-aware with
  encoding fallbacks (UTF-8/16/32, latin-1).
- **Export** — WAV audio of any note via the Share Sheet; share note text too.
- **Storage** (Settings → Storage) — browsable gallery of every cached image
  (attached AND web-downloaded, tap to zoom, share/delete), exported audio
  list, and a usage breakdown.
- **Onboarding** — a three-page first-launch tour.
- **Logs** (Settings → About) — crash-persistent on-device logs, shareable
  for debugging.

Speech-to-text and translation were on the roadmap once — dropped; this is a
speech *notes* app and TTS is the mission.

## How this repo works (no Mac required)

- The Xcode project is **generated from text** (`project.yml`, via XcodeGen) on CI.
- `.github/workflows/build.yml` runs on every push to `main`:
  - `logic-tests` — SpeechLogic unit tests (sentence chunker, WAV writer,
    markdown, XHTML, EPUB/ZIP, PDF chapter logic).
  - `kokoro-small-spike` / `supertonic-spike` / `epub-spike` / `pdf-spike` —
    non-blocking contract tests that run each ONNX model (or the EPUB parser
    against real Gutenberg books / the PDF chapter resolver against real
    documents) on the macOS runner and assert valid output.
  - `build-ipa` — patches any SPM dependency that declares itself dynamic to
    link statically (LiveContainer requirement), archives an unsigned build,
    verifies the binary has no `@rpath` framework references, and packages
    `dist/SpeechnotesIOS.ipa` as an artifact.
- The `.ipa` is unsigned on purpose: LiveContainer/SideStore sign it your way.

## Layout

```
speechnotes-ios/
├── project.yml                  # XcodeGen spec (targets, pins, version)
├── .github/workflows/build.yml  # CI: tests + spikes + unsigned IPA
├── App/Sources/
│   ├── Engine/                  # SpeechEngine protocol + 3 engines
│   │   │                        #   + PlayPositionTracker (read-along sync)
│   │   └── Supertonic/Helper.swift  # vendored upstream runner (MIT)
│   ├── Services/                # NotesStore, NotebooksStore, BooksStore,
│   │                            # BookPlaybackController, SpeechPlayer,
│   │                            # ModelManager, RemoteImageStore, ImportService,
│   │                            # LogStore, Haptics
│   ├── Models/                  # Note, Notebook, Book, VoiceCatalog
│   └── Views/                   # list, editor, read-along, books library,
│                                #   epub/pdf readers, notebooks, picker,
│                                #   settings, mini-player, onboarding…
├── App/Resources/epubjs/        # vendored epub.js + JSZip (offline EPUB reader)
├── Packages/SpeechLogic/        # pure-logic SPM package (tested on CI)
│                                #   SentenceChunker, WAVWriter, MarkdownText,
│                                #   MarkdownSlashMenu, ZipReader, EpubInfo,
│                                #   XhtmlText, PdfText, NoteImageStore
├── Tests/KokoroSmallSpike/      # standalone ONNX contract spike
├── Tests/SupertonicSpike/       # standalone ONNX contract spike
├── Tests/EpubSpike/             # EPUB parser contract spike (real books)
├── Tests/PdfSpike/              # PDF chapter resolver contract spike
├── Scripts/                     # package-ipa.sh, watch_ci.sh, make_icon.py,
│                                #   make_pdf_fixtures.py
└── Docs/                        # plan, setup guide, research notes
```

## Building & installing

1. Grab `SpeechnotesIOS.ipa` from the
   [Releases](https://github.com/thesagezm/speechnotes-ios/releases) page
   (or the `SpeechnotesIOS` artifact of the latest
   [Actions run](https://github.com/thesagezm/speechnotes-ios/actions)).
2. Unzip once if needed — the `.ipa` is unsigned on purpose.
3. Import into **LiveContainer** (or sign with SideStore).
4. First launch: Settings → pick an engine → download its model on Wi-Fi.
   After that, everything works in airplane mode.

Requires iOS 18+. Developed against an iPhone 12 Pro Max (A14) on iOS 26
inside LiveContainer.

## Licenses & credits

- [Kokoro](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX) — Apache-2.0 (model), voice bank from the KokoroTestApp project
- [Soprano 1.1](https://huggingface.co/ekwek/Soprano-1.1-80M) — Apache-2.0 (Eugene Kwek); [ONNX export](https://huggingface.co/KevinAHM/soprano-1.1-onnx) Apache-2.0
- [supertonic-3](https://huggingface.co/Supertone/supertonic-3) — Supertone; the vendored Swift Helper is MIT
- ONNX Runtime (MIT), XcodeGen, and Apple's AVFoundation do the heavy lifting.

Personal sideload project — model licenses permit personal use; revisit before
any public distribution.
