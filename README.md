# Speechnotes iOS

An offline, Speech Note (Linux)-style app for iPhone — built entirely from Linux,
compiled on GitHub Actions macOS runners, sideloaded via SideStore + LiveContainer.

**Current status: v1.0.0 — three on-device engines, markdown option, polished UI.**
Pick an engine in Speech Settings, download its model once, and notes are spoken
fully offline (airplane-mode tested):

| Engine | Model size | Voices | Notes |
|---|---|---|---|
| **Kokoro** (ONNX, CPU) | ~341 MB | 28 (US/UK, m/f) | Main engine — fp32 quality build |
| **Kitten** (ONNX, CPU) | ~82 MB | 8 expressive | Experimental pack |
| **Supertonic** (ONNX, CPU) | ~399 MB | 10 styles × 31 languages | Multilingual — flow-matching TTS |
| Apple (system) | 0 | all system voices | Fallback while models download |

Feature tour:

- **Notes** — create/edit/delete, autosave (debounced, flushed on exit and
  backgrounding), search, sort (edited/created/title), date sections, swipe
  actions (delete / share text / export audio), drag & drop.
- **Streaming playback** — sentence-chunked generation with playback starting
  after the first sentence; pause/resume/stop; speed slider; phone-call
  interruption handling; mini-player bar while you browse.
- **Read-along highlighting** — spoken text is highlighted and auto-scrolled;
  works with every engine.
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
- **Logs tab** — crash-persistent on-device logs, shareable for debugging.

Speech-to-text and translation were on the roadmap once — dropped; this is a
speech *notes* app and TTS is the mission.

## How this repo works (no Mac required)

- The Xcode project is **generated from text** (`project.yml`, via XcodeGen) on CI.
- `.github/workflows/build.yml` runs on every push to `main`:
  - `logic-tests` — SpeechLogic unit tests (sentence chunker, WAV writer,
    Kitten tokenizer, markdown stripper).
  - `kitten-spike` / `supertonic-spike` — non-blocking contract tests that run
    each ONNX model on the macOS runner and assert audible output.
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
│   ├── Engine/                  # SpeechEngine protocol + 4 engines
│   │   └── Supertonic/Helper.swift  # vendored upstream runner (MIT)
│   ├── Services/                # NotesStore, SpeechPlayer, ModelManager,
│   │                            # ImportService, LogStore, Haptics
│   ├── Models/                  # Note, VoiceCatalog
│   └── Views/                   # list, editor, picker, settings, mini-player…
├── Packages/SpeechLogic/        # pure-logic SPM package (tested on CI)
│                                #   SentenceChunker, WAVWriter,
│                                #   KittenTokenizer, MarkdownText
├── Tests/KittenSpike/           # standalone ONNX contract spike
├── Tests/SupertonicSpike/       # standalone ONNX contract spike
├── Scripts/                     # package-ipa.sh, watch_ci.sh, make_icon.py
└── Docs/                        # plan, setup guide, research notes
```

## Building & installing

1. Push to `main` (or let CI run) → grab the `SpeechnotesIOS` artifact from
   the latest [Actions run](https://github.com/thesagezm/speechnotes-ios/actions).
2. Unzip once — inside is `SpeechnotesIOS.ipa` (unsigned on purpose).
3. Import into **LiveContainer** (or sign with SideStore).
4. First launch: Settings → pick an engine → download its model on Wi-Fi.
   After that, everything works in airplane mode.

Requires iOS 18+. Developed against an iPhone 12 Pro Max (A14) on iOS 26
inside LiveContainer.

## Licenses & credits

- [Kokoro](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX) — Apache-2.0 (model), voice bank from the KokoroTestApp project
- [KittenTTS mini 0.8](https://huggingface.co/KittenML/kitten-tts-mini-0.8) — KittenML
- [supertonic-3](https://huggingface.co/Supertone/supertonic-3) — Supertone; the vendored Swift Helper is MIT
- ONNX Runtime (MIT), XcodeGen, and Apple's AVFoundation do the heavy lifting.

Personal sideload project — model licenses permit personal use; revisit before
any public distribution.
