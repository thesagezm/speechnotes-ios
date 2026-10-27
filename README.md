# Speechnotes iOS

An offline, Speech Note (Linux)-style app for iPhone — built entirely from Linux,
compiled on GitHub Actions macOS runners, sideloaded via SideStore + LiveContainer.

**Current status: v1.8.0 — a books release and a focus release.** The readers
show the book behind the tab bar and the hidden chrome (EPUB and PDF; EPUB's
portrait controls float like Notes; the landscape rail is untouched); wide
converted tables pan to their lateral end; TTS starts at the page you're
viewing and chapter jumps always land; the minimised transport is one shared
Notes-style pill; maths renders AND speaks; Pomodoro (Structured / Flowmodoro /
free timer) lives on the Stats tab; **Keep Screen On** holds any reading
surface; BookDrop scans any LAN interface (hotspot transfers work), keeps its
port stable across toggles, launches OFF, and recovers from access-code
prompts; shared URLs become notes (Readability, with a Bypass-Paywalls-Clean
pass for paywalled pages); JEX exports import into real Joplin (full metadata
set) and Joplin's end-to-end encryption round-trips; .mobi/azw books, scanned
PDF OCR and m4b chapter audiobooks all read and play. Pick an
engine in Speech Settings, download
its model once, and notes are spoken fully offline (airplane-mode tested):

| Engine | Model size | Voices | Notes |
|---|---|---|---|
| Apple (system) | 0 | all system voices | Instant, no download |
| **Kokoro** (ONNX, CPU) | ~341 MB High (fp32) / ~92 MB Compact (int8) | 28 (US/UK, m/f) | One engine, a quality dial |
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

## What's new in v1.8.0

- **Books readers, transparent.** The page colour runs behind the tab bar to
  the bottom of the screen and behind the status bar when the chrome is
  hidden (tap-to-immersive), in the EPUB and PDF readers. EPUB portrait
  controls float over the book like Notes; a chapter always ends with its
  last lines readable above the chrome. The landscape playback rail is
  unchanged.
- **Wide tables pan.** Many-column tables from converted books become
  laterally pannable blocks in the EPUB reader; nested tables keep their
  layout, and a swipe on a table pans the table instead of turning the page.
- **TTS starts where you look.** Play begins at the viewed page/spot (a
  stored bookmark still wins); in read-along, tapping a Contents row moves
  the speech to that chapter. Chapter jumps land or report back — no more
  silent dead chevrons — and the mid-chapter position survives scrolling.
- **Maths, rendered and spoken.** LaTeX in notes renders as display glyphs in
  the preview and speaks as words in TTS (exports keep the glyphs).
- **Pomodoro on Stats.** Structured work/break cycles, Flowmodoro (a break
  claimable once 3 break minutes are banked) and a free timer, with a gentle
  app-wide banner and juice in the fill.
- **Keep Screen On.** A Reading setting (default ON) holds the screen awake
  on all four reading surfaces — EPUB, PDF, audiobook and note reading —
  registry-based so tab switches can't wedge it.
- **BookDrop everywhere, and stable.** Multi-select send sheet from storage,
  backups, swipes and context menus; JEX/note/book/WAV routing on receive;
  hotspot transfers (any LAN interface); the port stays 53317 across toggles;
  launches OFF; a 401 offers a prefilled access-code retry.
- **Web articles become notes.** Share a URL — Readability extracts it;
  paywalled pages get a Bypass-Paywalls-Clean userscript pass.
- **Joplin, both ways.** JEX exports carry the full metadata set and import
  into real Joplin; Joplin's end-to-end encryption (KeyV1/StringV1) is
  supported in the notes library.
- **Under the hood from the 1.7.x line, now solid:** mobi/azw reading with
  Calibre-exact text extraction, OCR for CamScanner scans (per-book
  force-OCR), m4b chapter audiobooks, the seconds-based TTS chunk schedule
  (the audible-gap fix), the background silence bridge, and exact
  stop→play resume.

Feature tour:

- **Notes** — create/edit/delete, autosave (debounced, flushed on exit and
  backgrounding), search, sort (edited/created/title), date sections, swipe
  actions (pin / delete / share text / export audio), drag & drop.
- **Notebooks & organization** (Joplin-style) — flat notebooks with a chip
  row for scoping, move notes between them, plus pin (Pinned section on top)
  and favorite (star). Titles auto-derive from the note's first sentence.
  Backup exports one notebook, the unfiled notes, or the whole library.
- **Books** — the Books tab: import EPUB, PDF, mobi
  (`.mobi`/`.azw`/`.azw3`/`.prc`/`.pdb`), office documents, FictionBook,
  RTF, HTML and plain text, plus audiobooks (M4B / M4A / MP3 / Ogg Opus /
  Opus-in-MP4, Files picker or Open-In) into a cover grid with
  search. Kindle books decode their own Huff/CDIC compression, carry
  their own flow/chapter structure, and show the cover their metadata
  declares. An audiobook plays the audio it already contains, with the
  chapter list read from the file's own metadata (a `chpl` atom, ID3
  `CHAP` frames, or Ogg/Opus chapter tags) and no synthesis at all;
  Opus books of any size open (lazy packet streams) and play with the
  full multichannel mix intact down to stereo. EPUBs render
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
- **Onboarding** — a five-page first-launch tour (welcome → scanned-PDF OCR
  → audiobooks → voices → Pomodoro & Stats).
- **Logs** (Settings → About) — crash-persistent on-device logs, shareable
  for debugging.

Speech-to-text and translation were on the roadmap once — dropped; this is a
speech *notes* app and TTS is the mission.

## How this repo works (no Mac required)

- The Xcode project is **generated from text** (`project.yml`, via XcodeGen) on CI.
- `.github/workflows/build.yml` runs on `main` and by manual dispatch:
  - `logic-tests` — SpeechLogic unit tests (sentence chunker, WAV writer,
    markdown, XHTML, EPUB/ZIP, PDF chapter logic, Pomodoro engine, JEX/Joplin
    crypto).
  - `kokoro-small-spike` (compact int8 on ORT CPU) / `supertonic-spike` /
    `epub-spike` / `pdf-spike` — non-blocking contract tests that run each
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
│   ├── Engine/                  # SpeechEngine protocol + 3 engines
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
├── Packages/SpeechLogic/        # pure-logic SPM package (tested on CI)
│                                #   SentenceChunker, WAVWriter, MarkdownText,
│                                #   MarkdownSlashMenu, ZipReader, EpubInfo,
│                                #   XhtmlText, PdfText, NoteImageStore,
│                                #   PomodoroEngine, ScreenAwakePolicy,
│                                #   JoplinCrypto/Vault, JexExport/Import
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
- [supertonic-3](https://huggingface.co/Supertone/supertonic-3) — Supertone; the vendored Swift Helper is MIT
- [epub.js](https://github.com/futurepress/epub.js) — FreeBSD, vendored under `App/Resources/epubjs/` for the offline EPUB reader
- ONNX Runtime (MIT), XcodeGen, and Apple's AVFoundation do the heavy lifting.

Personal sideload project — model licenses permit personal use; revisit before
any public distribution.
