# Speechnotes iOS

An offline, Speech Note (Linux)-style app for iPhone — built entirely from Linux,
compiled on GitHub Actions macOS runners, sideloaded via SideStore + LiveContainer.

**Current status: v0.6 — two on-device engines + import/read-along.**
Pick an engine in Speech Settings, download its model once, and notes are spoken
fully offline:

- **Kokoro (Metal)** — KokoroSwift/MLX on the GPU, ~342 MB model.
- **Kokoro ONNX (CPU)** — the same voices via ONNX Runtime on the CPU,
  ~82 MB quantized model; the fallback for devices/situations where Metal
  memory pressure is a problem.

Everything else that's in: notes with autosave + delete, sentence-chunked
streaming playback (speech starts after the first sentence), read-along
highlighting, speed control, WAV export via the Share Sheet, pause/resume,
call-interruption handling, system-voice fallback, file import (.txt / .md /
.pdf, Files picker + Open-In + `speechnotes://import?text=…` links), and
crash-persistent on-device logs (Logs tab → share).

## Road toward Speech Note parity

Text-to-speech ✅ · Speech-to-text (whisper) next · Translation after that —
all local. See `Docs/` for the plan and research notes.

## How this repo works (no Mac required)

- The Xcode project is **generated from text** (`project.yml`, via XcodeGen) on CI.
- `.github/workflows/build.yml` runs on every push to `main`:
  runs the `SpeechLogic` unit tests (sentence chunker, WAV writer) → patches any
  SPM dependency that declares itself dynamic to link statically (LiveContainer
  requirement) → archives an unsigned build → verifies the binary has no
  `@rpath` framework references → packages `dist/SpeechnotesIOS.ipa` → uploads
  it as an artifact. A Kokoro generation spike job runs non-blocking.
- The `.ipa` is unsigned on purpose: LiveContainer/SideStore sign it your way.

## Layout

```
project.yml                  XcodeGen project definition (the "project file")
Packages/SpeechLogic/        Local SPM package: sentence chunker + WAV writer (+ tests)
.github/workflows/build.yml  CI: logic tests + build + package IPA
App/Sources/                 Swift code (views, services, three speech engines)
App/Resources/               Assets, generated Info.plist
Scripts/                     package-ipa.sh, make_icon.py
Docs/                        SETUP.md, PLAN.md, POCKETPAL-LESSONS.md
```

See `Docs/SETUP.md` for the exact push → build → install loop.

Personal-use project. Licenses: Kokoro model Apache-2.0 · KokoroSwift MIT ·
MisakiSwift MIT · ONNX Runtime MIT · espeak-ng GPLv3 (unused unless a future
engine needs it).
