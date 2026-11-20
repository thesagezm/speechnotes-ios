# Speechnotes iOS

An offline, Speech Note (Linux)-style app for iPhone — built entirely from Linux,
compiled on GitHub Actions macOS runners, sideloaded via SideStore + LiveContainer.

**Current status: v1.8.2 — the document family reads in the real reader.**
mobi/azw3/fb2/rtf/html/txt render in the vendored foliate-js engine — the
original file, never converted — with the publisher's own table of contents
and instant chapter jumps; PowerPoint decks import whole and speak in visual
order; **Nano Edge** joins as a fifth engine (Kokoro's 28 voices, distilled,
~157 MB); every reading surface lets you copy a passage out (long-press
selection in read-along, selectable preview prose, "Play from selection" in
the editor); note rows and both recycle bins carry full long-press menus;
tap-to-hide takes the tab bar too, in both orientations; settings are
rebuilt to the Android reference (info buttons instead of footer essays,
one Models list by size); Ogg/Opus audiobooks finally show their embedded
artwork; and About gained a real acknowledgements screen. The v1.8.0
headlines — transparent books readers, maths that renders AND speaks,
Pomodoro, Keep Screen On, BookDrop over any LAN (hotspot transfers, stable
port), web-article import with a paywall-bypass pass and the Share
Extension (`Docs/WEB-ARTICLE-IMPORT.md`), Joplin round-trip (JEX + E2EE),
mobi/azw, scanned-PDF OCR and m4b chapter audiobooks — are all still here.
Pick an engine in Speech Settings, download
its model once, and notes are spoken fully offline (airplane-mode tested):

| Engine | Model size | Voices | Notes |
|---|---|---|---|
| Apple (system) | 0 | all system voices | Instant, no download |
| **Kokoro** (ONNX, CPU) | ~341 MB High (fp32) / ~92 MB Compact (int8) | 28 (US/UK, m/f) | One engine, a quality dial |
| **Nano Edge** (ONNX, CPU) | ~157 MB | 28 (US/UK, m/f — Kokoro's banks) | Kokoro's voices, distilled two-graph decoder |
| **Phonon** (ONNX, CPU) | ~192 MB | 27 (US/UK + default) | Compact English streaming TTS — no speed control yet |
| **Supertonic** (ONNX, CPU) | ~399 MB | 10 styles × 31 languages | Multilingual — flow-matching TTS |

Kokoro's Compact tier is the dynamic-int8 `model_quantized.onnx` (~92 MB) —
the older weight-only uint8 build (~177 MB) was replaced after the device
round asked for an 80–130 MB download. Soprano was removed as an engine; its
preferences carry over to Kokoro.

A sentence the model cannot synthesize is skipped on the first attempt — one
soft tone, then the next sentence. There is no retry: a second attempt at the
same text fails the same way, and the wait for it is silence the listener pays
for. Text is cleaned at import so the things that used to fail (soft hyphens,
zero-width joiners, control bytes, embedded-font glyphs) never reach the model.

## What's new in v1.8.2

- **The document family reads in the real reader.** mobi, azw, azw3, prc,
  pdb, fb2, rtf, html and txt render in the vendored foliate-js engine —
  the original file, never converted to EPUB — with the publisher's own
  table of contents, instant in-renderer chapter jumps (no page reload, so
  the mobi chevron lag is gone structurally), CFI resume, and one section
  in memory at a time. Reader, TTS and TOC share one chapter numbering.
  Existing books migrate on launch; a refused file falls back and is
  stamped honestly in the manifest.
- **The mobi/azw3 TOC is the publisher's.** The real Kindle index layout is
  parsed — publisher chapter names replace the "Chapter N" heuristic; RTF
  bold-title chapter splitting is fixed; the EPUB TOC tree renders (the
  depth field survives the manifest).
- **Slide decks are a book format.** PPTX imports whole and renders —
  preset shapes, gradients, Wingdings/Symbol bullets — and speech reads
  slides in visual order; the deck re-fits on rotation and fills the
  viewport edge-to-edge.
- **Nano Edge, a fifth engine.** Kokoro's 28 English voices over a
  distilled two-graph ONNX decoder (~157 MB, 24 kHz, fully offline).
- **Copy out of every surface.** Long-press selects a passage in the
  read-along of EPUB/PDF/slides/notes and the markdown preview's prose;
  the editor's native selection menu carries "Play from selection".
- **Row menus and bins.** Note rows gain Rename/Share/Export on
  long-press; both recycle bins gain Recover / Delete Now menus.
- **Immersive chrome takes the tab bar too** — all four reading surfaces,
  both orientations; the portrait rail docks into the vacated strip.
- **Settings rebuilt to the Android reference** — flat rows, factual
  engine subtitles, one Models list smallest→largest, info sheets instead
  of footer essays, Bypass-Paywalls always on, Logs + Benchmark under
  Diagnostics.
- **Covers and the scrubber.** Ogg/Opus artwork extracts (existing books
  self-heal a few per launch); M4B covers read first; late covers repaint
  tiles; cover-less documents heal; the seek scrubber holds where dropped.
- **Acknowledgements** — the About row's promised screen: every vendored,
  SPM and model piece with what it does here, its license and source.
- **Phonon playback repairs** — the chunk-boundary click and the dead air
  after each chunk are gone (boundary fades + a shorter silence bridge).

Feature tour:

- **Notes** — create/edit/delete, autosave (debounced, flushed on exit and
  backgrounding), search, sort (edited/created/title), date sections, swipe
  actions (pin / delete / share text / export audio), a long-press row menu
  (pin / favorite / rename / share / export / send with BookDrop / move),
  drag & drop.
- **Notebooks & organization** (Joplin-style) — flat notebooks with a chip
  row for scoping, move notes between them, plus pin (Pinned section on top)
  and favorite (star). Titles auto-derive from the note's first sentence.
  Backup exports one notebook, the unfiled notes, or the whole library.
- **Books** — the Books tab: import EPUB, PDF, mobi
  (`.mobi`/`.azw`/`.azw3`/`.prc`/`.pdb`), PowerPoint decks (.pptx), office
  documents, FictionBook, RTF, HTML and plain text, plus audiobooks (M4B /
  M4A / MP3 / Ogg Opus / Opus-in-MP4, Files picker or Open-In) into a cover
  grid with search. Kindle books decode their own Huff/CDIC compression,
  carry the publisher's own table of contents and flow/chapter structure,
  and show the cover their metadata declares (embedded Ogg/Opus artwork
  included). An audiobook plays the audio it already contains, with the
  chapter list read from the file's own metadata (a `chpl` atom, ID3
  `CHAP` frames, or Ogg/Opus chapter tags) and no synthesis at all;
  Opus books of any size open (lazy packet streams) and play with the
  full multichannel mix intact down to stereo. EPUBs render
  chapter-by-chapter in a real book reader, and so does the whole document
  family — mobi/azw3/fb2/rtf/html/txt via the vendored foliate-js engine on
  the original file (themes, text size, native table of contents, per-book
  position); PDFs open in a full-fidelity PDFKit viewer with an outline
  sidebar. Any book can be spoken: chapter narration with
  auto-advance (exact audio-completion signal, no stranding at chapter
  boundaries), sentence-snapped resume, and the same read-along highlighting as
  notes. PDF chapters come from the document's own outline, with font-size
  heading detection and honest page ranges as fallbacks; scanned pages speak
  via Vision OCR, and two-column papers read left→right. Per-chapter WAV
  export. DRM/locked books explain themselves on the shelf.
- **Slide decks** — a PPTX deck imports whole and renders with its preset
  shapes, gradients and symbol bullets; speech reads slides in visual
  order (top→bottom), so a repeated footer never ends the slide; the deck
  re-fits on rotation, rail changes and hidden chrome, and fills the
  viewport like the PDF does.
- **Streaming playback** — sentence-chunked generation with playback starting
  after the first sentence; pause/resume/stop; speed slider; phone-call
  interruption handling; lock-screen / Control Center controls.
- **Read-along highlighting** — a dedicated reader replaces the editor while
  a note speaks (toggleable from the player bar), highlighting the sentence
  actually sounding via play-time position tracking, with auto-scroll;
  long-press selects and copies a passage, and tapping a paragraph starts
  speaking from it.
- **Resume bookmarks** — stopped notes resume from the prior sentence
  boundary (valid 30 days); auto-resume after a brief backgrounding.
- **Mini-player** — rounded card above the tab bar, minimizable to a
  floating progress-ring bubble; it yields whenever the note's own editor
  controls are on screen.
- **Voice picker** — searchable, grouped, recent voices, tap-to-audition
  (hear a voice before committing). Supertonic adds a language selector
  (English, Korean, Japanese, German, French, +26 more).
- **Markdown option** (Settings → Notes) — preview rendered markdown in the
  editor (eye/pencil toggle), speech reads the plain text without markdown
  symbols, and the preview's prose is selectable/copyable.
- **E-Ink mode** (Settings → Appearance → Theme) — paper white, ink black,
  square edges, hairline borders: no glass, no gradients, no color, no
  animation, anywhere in the app (notes list and editor included). The
  accent color picker only colors the app again once the mode is left. The
  EPUB reader gets its own E-Ink page theme to match.
- **Import** — .txt / .md / .pdf via the Files picker, drag & drop,
  `speechnotes://import?text=…` links, and clipboard; iCloud-aware with
  encoding fallbacks (UTF-8/16/32, latin-1).
- **Export** — WAV audio of any note via the Share Sheet; share note text too.
- **Storage** (Settings → Storage) — browsable gallery of every cached image
  (attached AND web-downloaded, tap to zoom, share/delete), exported audio
  list, and a usage breakdown.
- **Onboarding** — a five-page first-launch tour (welcome → scanned-PDF OCR
  → audiobooks → voices → Pomodoro & Stats).
- **Diagnostics** (Settings) — Benchmark mode (a sustained-synthesis
  harness with CSV/JSON exports) and crash-persistent on-device logs,
  shareable for debugging.
- **Acknowledgements** (Settings → About) — what each vendored, SPM and
  model piece does here, with its license and source.

Speech-to-text and translation were on the roadmap once — dropped; this is a
speech *notes* app and TTS is the mission.

## How this repo works (no Mac required)

- The Xcode project is **generated from text** (`project.yml`, via XcodeGen) on CI.
- `.github/workflows/build.yml` runs on `main` and by manual dispatch:
  - `logic-tests` — SpeechLogic unit tests (sentence chunker, WAV writer,
    markdown, XHTML, EPUB/ZIP, PDF chapter logic, Pomodoro engine, JEX/Joplin
    crypto).
  - `kokoro-small-spike` (compact int8 on ORT CPU) / `nano-edge-spike` /
    `supertonic-spike` / `phonon-spike` / `epub-spike` / `pdf-spike` —
    non-blocking contract tests that run each
    ONNX model (or the EPUB parser against real Gutenberg books / the PDF
    chapter resolver against real documents) on the macOS runner and assert
    valid output.
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
│   ├── Engine/                  # SpeechEngine protocol + 5 engines
│   │   │                        #   + PlayPositionTracker (read-along sync)
│   │   └── Supertonic/Helper.swift  # vendored upstream runner (MIT)
│   ├── Services/                # NotesStore, NotebooksStore, BooksStore,
│   │                            # BookPlaybackController, SpeechPlayer,
│   │                            # ModelManager, LocalSend (BookDrop),
│   │                            # RemoteImageStore, ImportService,
│   │                            # LogStore, Haptics
│   ├── Models/                  # Note, Notebook, Book, VoiceCatalog
│   └── Views/                   # list, editor, read-along, books library,
│                                #   epub/pdf readers, notebooks, picker,
│                                #   settings, mini-player, onboarding…
├── App/Resources/epubjs/        # vendored epub.js + JSZip (offline EPUB reader)
├── App/Resources/foliatejs/     # vendored foliate-js (document reader engine)
├── Packages/SpeechLogic/        # pure-logic SPM package (tested on CI)
│                                #   SentenceChunker, WAVWriter, MarkdownText,
│                                #   MarkdownSlashMenu, ZipReader, EpubInfo,
│                                #   XhtmlText, PdfText, NoteImageStore,
│                                #   PomodoroEngine, ScreenAwakePolicy,
│                                #   JoplinCrypto/Vault, JexExport/Import
├── Tests/KokoroSmallSpike/      # standalone ONNX contract spike
├── Tests/SupertonicSpike/       # standalone ONNX contract spike
├── Tests/PhononSpike/           # standalone ONNX contract spike
├── Tests/NanoEdgeSpike/         # standalone ONNX contract spike
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
- [Phonon](https://huggingface.co/onnx-community/phonon-31m-en-ONNX) — Gradium phonon-31m-en via the onnx-community conversion; Apache-2.0 (model, conversion, voices)
- [supertonic-3](https://huggingface.co/Supertone/supertonic-3) — Supertone; the vendored Swift Helper is MIT
- [foliate-js](https://github.com/johnfactotum/foliate-js) — MIT; the readest fork vendored under `App/Resources/foliatejs/` for the document reader
- Nano Edge — distilled from Kokoro's weights (Apache-2.0 lineage); the model set rides the project's Hugging Face repo
- SlideDeckKit — the OOXML slide renderer ported from the deckcraft-lineage reference implementation (MIT)
- ONNX Runtime (MIT), XcodeGen, and Apple's AVFoundation do the heavy lifting.

Personal sideload project — model licenses permit personal use; revisit before
any public distribution.
