# Handover — audiobook chapters (open issue, after v1.7.1)

Repo: `~/.zcode/workspace/default/speechnotes-ios` (branch `batch-c-d-session`;
v1.7.1/38 shipped on `main` 2026-09-27). All claims below are for the *next*
agent to verify, not to trust — the user has reported the chapters issue is
"still not working" even after the shipped fixes.

## State of the bug

The chapter list shown in the audiobook reader/sheet comes from the book's
manifest (`Book.audioChapters`), written at import and rewritten by a shelf
backfill. Files commonly carry an `ffmpeg`/`m4b-tool`-style `chpl` atom
(4-byte count vs. 1-byte count) that round 5/6 each parsed half of; the
parser now tries both layouts. That parser change is NOT verified against
your device yet — it is verified only against one local file (ffprobe
cross-check).

The reference: the user's own MOODY release
`/home/sagestation/Downloads/When.Breath.Becomes.Air.Paul.Kalanithi.M4B.128k-MOODY/`
(266 MB m4b, ffprobe reports 12 chapters). ffmpeg/ffprobe are installed
locally. A Python vs-Swift parser harness was used at `/tmp/soprano/repro.py`
(ephemeral — recreate if needed).

## What to do first (diagnose before fixing)

Ask the user (or ask them to paste) the app's own import log line on the
device, which is emitted exactly once per import/backfill:

    AudioBook import: «title» 19722.5s, N chapter(s) via SOURCE, cover found, author …

`SOURCE` is one of: `avfoundation`, `mp4-full`, `single`. That line is the
whole diagnosis:

- If it says `via avfoundation` and N is 12 — the import path is DONE; the
  bug is downstream, in the reader/sheet/sheet-mapping/UI. Check
  `BookAudioReaderView` chapter sheet and `PlaybackRail`/`player` bindings,
  `AudioBookPlayer.bind`/`play` clamps, and the `chapterIndex` selection path
  (tap row → `playChapter`) for swallowed state.
- If it says `via single` or `via mp4-full` with N=1 — the manifest re-read
  didn't fire for the user's book. Causes to rule out in order:
  - the shelf backfill is one-shot per app launch (`didBackfillLegacyBooks`)
    and filters on `audioChapterSource` — a book whose manifest says
    `avfoundation` will never re-parse;
  - the book manager caches `parse`/`book` identities — confirm
    `BooksStore.refresh()` re-reads manifests on launch and the Open-shelf
    trip actually ran;
  - if the m4b was imported as a `.epub`/`.pdf` on device (format sniff on
    extension) — check `Build.bookFormat` paths.
- If it says `via mp4-full` with N=12 — then the reader, not the parser, is
  the failure; start in `BookAudioReaderView` (chapters sheet source, view
  updates) and `AudioBookPlayer`.

## The thing NOT to do

Don't claim VLC parity and don't repeat the round-5/6 mistake: the parser
and its tests were written in the same session and the test fixture encoded
the buggy assumption. Any new parser change ships with:

1. a test fixture built from the *spec* (or better: from the user's own
   bytes), and
2. a numeric cross-check vs `ffprobe -show_chapters` on the real file.

Then leave the final claim to the device test. The user's standing rule:
"dont claim too much about the audiobook chapters, still not working for now."

## Other active threads (in case of context switch)

- **PDF open freeze (2026-09-28) — DEVICE-CONFIRMED FIXED by the user.**
  Root cause was `BookPDFView.makeUIView`'s synchronous
  `PDFDocument(url:)` + a duplicate concurrent open for the outline walk
  (1f7e380). Follow-ups in dabf043: default fit-to-WIDTH (autoScales
  fits the whole page, which left dead side margins — the user asked),
  re-fit on surface width change, pinch-zoom preserved.
- **Audiobook transport freeze (dabf043, NOT device-confirmed)** —
  mashing ±15 s / prev-chapter froze the UI while audio continued.
  Costs per press: exact-tolerance seek (the comment said "loose" but
  `seek(to:)` is kCMTimeZero), synchronous `AVPlayerItem.duration`
  reads (deprecated; can block the calling thread), and force
  publish+persist per press. Now coalesced: presses accumulate on the
  pending target, one commit 0.2 s after the last press (single loose
  ±0.25 s seek + one publish + one persist); duration cached via KVO;
  tick() holds steady while a commit is pending. If the user still
  reports a stall, the HangWatchdog log line names it.
- **EAC3 background kill (dabf043, NOT device-confirmed)** — 'Harry
  Potter' (EAC3) got suspended in background while AAC books persisted.
  The app had NO audio-session event handling; multichannel content
  triggers reconfigurations stereo AAC never sees. Now wired:
  interruption began/ended (re-activate + resume on shouldResume),
  route change (old-device-unavailable reflects the system pause),
  mediaServicesWereReset (AudioSessionSetup.invalidateConfiguration()
  + cold-resume). VLC comparison: it software-decodes to its own audio
  unit and re-activates after every session event — we adopted the
  session-resilience half; bundling ffmpeg software decode is the
  fallback if AVPlayer's EAC3 background path still fails.
- **Supertonic slowdown** — RTF climbed 0.5 → 5.3 within one session on
  device and recovered on the next; engine now logs
  `thermal <state>` per chunk from `ProcessInfo.thermalState`. Ask the next
  device log whether `thermal` rose — it is the prime suspect. TTFA fix
  (`firstMaxChars = 60`) is in and untested on device.
- **PDF landscape TOC jump** — hardened (re-issue after sheet dismissal,
  `currentPage` write) but not device-confirmed.
- **Landscape rail** — floating panel + bubble minimize shipped; not
  device-confirmed.
- **Exports** — `WavPlayer` shared singleton with transport + global
  mini player; not device-confirmed.

## Memory

`~/.zcode/cli/memories/projects/default-bbac820b7b082f94/memory/` —
`speechnotes-v17-release.md` is the full round history (rounds 1–7),
including the chpl saga and the ModelManager restore. Keep it updated.
