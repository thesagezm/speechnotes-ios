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

---

# Round 2 (device log 2026-09-26) — same version 1.7.0/37, do NOT bump

**User directive: stop advancing build names/numbers.** The version fields
stay at 1.7.0/37 until the user says otherwise. Identifying a build is by
commit + CI run id, not by version.

## What round 2 fixed (from the two pasted logs)

1. **Soprano played nothing — every chunk skipped (missingOutput) in
   ~10 ms.** The engine passed the empty KV caches as [1, 1, 0, 512]
   (hidden_size); the graph wants [1, 1, 0, 128] (head_dim). ORT rejected
   the shape on step 0 and the catch-all masked it as "missingOutput".
   Fixed (kvDim=128), the catch-all now logs the REAL error, generation
   stops cleanly at the model's 512-position ceiling, and the tokenizer is
   the model's real BPE (vocab + 135 merges, fixtures pinned in CI) instead
   of greedy longest-match.
2. **Supertonic skipped ~20% of an EPUB's chunks (noOutput).** Three holes:
   unmapped punctuation (… " " « » ‹ › ≥ ≤) reached the model as -1 ids and
   the duration predictor returned ≤ 0 s (now: extended replacement table
   AND unknown scalars read as the space id); the vocoder can come back a
   few hundred samples short of the predicted length and the engine turned
   that into a skip (now: trim to what came back); the duration ≤ 0 path
   now logs the offending text.
3. **Audiobooks.** Chapters now read through AVFoundation's own chapter
   reader FIRST (chpl AND chapter tracks, real titles) with the hand
   parsers as fallback; the player clamps chapter ends to the file's real
   duration (a legacy manifest could end the only chapter at ~2 s — the
   "plays two seconds" report) and clamps chapter starts to the file;
   imports log one summary line (duration, chapter count + source, cover).
   Existing books re-read their manifest on first shelf open.
4. **EPUB text disappeared after switching tabs and back.** onDisappear
   fires on every tab switch and called readerDestroy() — the rendition
   died with nothing to re-open it. The call is gone; WebKit reclaims the
   whole JS heap on pop, so the teardown bought nothing on dismissal.

## Device checklist for this round

1. Soprano: pick the engine, play the hernia note — chunks must SOUND
   (audio within a few seconds per chunk). If any chunk still fails, the
   log now shows the real ORT error — paste it.
2. Supertonic + the same EPUB: the skipped-chunk rate should drop from
   ~20% to near zero; the previously silent lines (curly-quote dialogue,
   "…" ellipses, | tables) must sound.
3. Audiobook: re-open the Books shelf (triggers the manifest re-read), then
   check cover / real chapter titles / playback past 2 s with the screen
   locked. The import/re-read log line names what the file gave up.
4. EPUB: open a book → switch to Settings → back — text must still be
   there, at the same position.
5. JEX round-trip (from round 1, untested on device): export a notebook,
   import it back, expect duplicate notes with the same titles and intact
   images.
