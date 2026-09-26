# v1.7.1 device checklist — the four reported bugs, in order

Build: `batch-c-d-session` at the CI-green commit, version 1.7.1/38.
Sideload the unsigned IPA from the green run (same procedure as every
round). NOT tagged, NOT released — this is a test build.

## 1. Soprano download (was: stuck at 99%, then "failed validation")

- Settings → Speech Settings → Soprano model → Download (~110 MB).
- The bar should pass 72% (backbone done), 99% (decoder done), and REACH
  100% with "Soprano model ready" — the four config files that 404'd now
  come from the repo root.
- If it still fails, the error now NAMES each file and its on-disk size —
  send that line back.
- Then: pick the Soprano engine, play a note with numbers ("42 apples at
  $5"), audition, export a WAV. The voice quality call is yours.

## 2. JEX import (was: "fix importing the jex")

- Settings → Backup → Import from Joplin (.jex) — pick a .jex that
  Joplin itself exported AND one this app exported.
- Expect: notes appear (notebooks recreated or merged into same-named
  ones), images inside notes render, an alert states how many
  notes/notebooks/images landed.
- A non-JEX file must be refused with a clear message, not imported.

## 3. Audiobooks (was: no thumbnail, no chapters, plays ~2 s)

- Import an M4B with real chapters (the one from the report).
- Cover should appear on the shelf; title/author from the file's tags.
- Chapters list should show REAL titles, not "Full audiobook".
- Play: must run past 2 seconds, keep playing with the screen locked,
  survive the mute switch being off (the session is now .playback).
- Existing books from the v1.6/v1.7 import round heal on first shelf
  open — no re-import needed. If one doesn't, note its title.

## 4. Soprano regression sweep (small)

- Switch engines mid-play (the old wedge repro) — controls must respond.
- Read-along + rate slider on Kokoro — unchanged from v1.7.0.

CI status at push: logic tests green (incl. the new JexImport round-trip
and chapter-track tests), Soprano spike GREEN for the first time
(run 36208555022), all other spikes green, IPA built.
