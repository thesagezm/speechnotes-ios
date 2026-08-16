# Speechnotes iOS

An offline, Speech Note (Linux)-style app for iPhone — built entirely from Linux,
compiled on GitHub Actions macOS runners, sideloaded via SideStore + LiveContainer.

**Current status: Phase 3 — Kokoro on the phone.**
The app now contains a full Kokoro engine: pick the engine in Speech Settings,
download the ~342 MB model once (on-device, with progress), pick a voice
(am_eric et al.), and notes are spoken fully offline. The CI spike is
non-blocking garnish — the iPhone is the real test bench.

## v1 target

- Notes list + editor
- Text-to-speech with **Kokoro** (KokoroSwift / MLX), fully offline
- Voices: `am_eric`, `af_heart`, `am_adam` bundled — more downloadable later
- Speed control, WAV export via Share Sheet

## How this repo works (no Mac required)

- The Xcode project is **generated from text** (`project.yml`, via XcodeGen) on CI.
- `.github/workflows/build.yml` runs on every push to `main`:
  generates the project → archives an unsigned build → packages
  `dist/SpeechnotesIOS.ipa` → uploads it as an artifact.
- The `.ipa` is unsigned on purpose: LiveContainer/SideStore sign it your way.

## Layout

```
project.yml                  XcodeGen project definition (the "project file")
.github/workflows/build.yml  CI: build + package IPA
App/Sources/                 Swift code
App/Resources/               Assets, generated Info.plist
Scripts/                     package-ipa.sh, make_icon.py
Docs/                        SETUP.md (the workflow loop), PLAN.md (master plan)
```

See `Docs/SETUP.md` for the exact push → build → install loop and
`Docs/PLAN.md` for the full master plan.

Personal-use project. Kokoro model: Apache-2.0. KokoroSwift: MIT.
