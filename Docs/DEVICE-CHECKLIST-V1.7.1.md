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

---

# Round 4 (device feedback 2026-09-26) — version fields stay frozen

Identify builds by commit + CI run id. This round touched the audiobook
player's ARCHITECTURE (playback ownership moved app-level), the Soprano
inference loop (twice), haptics, and two readers — test in this order.

## 1. Audiobooks — playback must survive leaving the reader

- Play an audiobook, then switch to Notes, then back. Audio must NOT stop.
- A mini-player bar (cover thumbnail, title, chapter, progress capsule)
  docks above the tab bar while you're away; play/pause/stop work from it.
- Tap the bar → lands back in the book's reader at the live playhead.
- The chevron collapses the bar to a floating bubble (tap to expand).
- Lock screen / Control Center: title + chapter + REAL elapsed time and
  duration, chapter number where the file has chapters; the buttons work
  (±chapter skip). Elapsed keeps ticking between refreshes (iOS
  extrapolates from rate — it should never freeze for more than ~10 s).
- Transport: ±15 s skip buttons flank play (gobackward.15/goforward.15);
  they work even on files WITHOUT chapter metadata, and a skip across a
  chapter boundary moves the chapter with it.
- Chapter list (TOC): the list-number button in the bottom chapter bar
  works even while the title bar is tap-hidden. Files with no chapter
  metadata open a "No chapter markers — use the ±15 s skip" panel instead
  of a dead button.
- Reopening the book resumes INSIDE the chapter (not at the chapter start).
- Deleting a playing book from the shelf stops it immediately.

## 2. Soprano — three independent fixes are now stacked

Prior rounds fixed the KV shape, then the decode schedule. The syllable
repetition persisted, and a NEW prime suspect surfaced: the spike header
and the slicing code disagreed about the hidden-state tensor layout
([1, 512, seq] vs [1, seq, 512]). The wrong orientation feeds the vocoder
channel slices as frames — structured garbage that sounds like syllables
repeating with slight variation. The engine now reads the tensor's real
shape at runtime and slices correctly either way.

- Play the same text. The FIRST log lines to send back:
  `hidden-state tensor is token-first [...]` or
  `CHANNEL-first [...] — every prior build sliced it wrong` — that line
  alone tells us whether this was the bug all along.
- Also new: nucleus sampling (top_p 0.95, the model card's own setting),
  a token-loop breaker with a `token loop #N` log line, and per-chunk
  summaries (RTF, prefill ms, steps, decodes, loop breaks, end reason).
- If it STILL repeats: paste `chunk done` lines — the honest call is then
  that the model itself loops on-device and the engine goes experimental/
  gets dropped (your "maybe I shouldn't have attempted it" — the decode
  and layout bugs are now provably fixed, so the verdict will be clean).

## 3. Haptics + note-open lag

- Tap around (list rows, play buttons, tab switches) — the haptic should
  land the same moment as the visual tap, not half a beat later.
- Open a LONG note — the push should be as quick as a short one (the
  markdown/sanitizer pass moved off the main thread).

## 4. PDF Contents (the TOC ask)

- Open a PDF WITH an outline: the list-number button in the bottom page
  bar (and the toolbar's Contents) opens the outline — indented by depth,
  page number right-aligned, the current entry highlighted and the list
  scrolled to it on open. Tap jumps the reader.
- Open a PDF WITHOUT an outline: the sheet lists the TTS chapter units
  (headings or "Pages N–M") with page ranges — never a dead button.
- Landscape: the page bar (and chapter bar in EPUB) are back at the
  bottom; the TTS playback rail is now truly 78 pt wide — its controls sit
  centered in the reserved column instead of hugging the right edge.

## 5. Multi-notebook export

- Settings → Backup → Export notes to Joplin (.jex) → "Selected
  notebooks": tick any number (counts per row, Select all/Deselect all),
  the summary line names what will be written, and the .jex carries all
  ticked notebooks as separate folders in Joplin.

## 6. Regression sweep (small)

- Notes TTS: play/pause/read-along/mini-player unchanged (the haptics
  change touches every tap; the rail width change touches the editor's
  landscape rail).
- EPUB reader in landscape: the chapter stepper bar overlays the bottom.

---

# Round 5 (2026-09-26, from 355abc8) — immersive chrome, audiobook metadata, export player, landscape rail

## 1. Title-bar hide/show is per-surface, and the editor always lets you out

- In a note's PREVIEW, tap once to hide the title bar, then enter edit mode
  (double-tap or the pencil) — the bar must come BACK immediately: back
  button and ⋯ menu reachable, no dead end (was the "trapped in the editor"
  bug).
- Hide the bar in a note, open an EPUB — its own bar is untouched; tap the
  epub page to hide it, tap again to bring it back (the tap now comes from
  inside the webview — this was impossible before).
- Same independence for PDF and audiobooks.

## 2. PDF Contents actually navigates

- Outline sheet rows: tap → the reader jumps to that page (was a no-op;
  in-book links already worked). Chapter-fallback rows too.

## 3. Audiobooks: metadata + live clock

- Re-open the shelf once (the manifest backfill runs on shelf open): the
  m4b should now show its embedded ARTWORK (shelf, reader, mini-player,
  lock screen) and its real chapter list — prologue/epilogue included, not
  "Full audiobook". The import log line names the chapter count + source.
- Time readout under the transport moves while playing, elapsed / total of
  the FILE (tap flips to remaining). No more frozen 0:00:00.

## 4. Redundant bottom TOC removed

- PDF page bar: page count only. Audiobook chapter bar: position + prev/next
  only. The toolbar's Contents/Chapters button is the one entry point.

## 5. Settings moves

- Appearance now has "Render Markdown" (Notes), "Haptic feedback" toggle,
  and "Image caching" (Automatic/Manual) under Images. Speech Settings no
  longer lists Render Markdown.
- Speech follows what you SEE: play while in reading preview → clean text;
  switch to edit while speaking → stop, play again → raw text.

## 6. Haptics + image caching

- Appearance → Haptic feedback OFF: no vibration anywhere, immediately.
- Image caching Automatic: open a note with web images — they land in the
  cache right away (scrolling never waits on the network). Manual: only
  images you actually view.
- Storage → "Per-note cached images": swipe-delete ONE note's web images.
- Put a note in the recycle bin → its images remain; Delete Now / Empty →
  its web images go too (images shared with another note stay until both).

## 7. Exports are playable downloads

- Export a note (list or editor): the file lands named after the TITLE.
- Storage → Exported audio: tap a file — transport expands (scrub, ±15 s,
  speed 0.5–2×, elapsed/total). Leave Storage while it plays → global mini
  player (bar; collapse to bubble); tap the bar → back to the Storage
  player.

## 8. Landscape playback rail (the redesign)

- Notes / EPUB / PDF in landscape: a 170 pt panel on the trailing edge with
  voice chip + voice name, progress capsule + %, 52 pt play, read-along +
  stop (+ PDF's export), horizontal rate slider + value. Everything the
  portrait bar does, nothing cramped, no rotated fader.
- Audiobook landscape: same width — ±15 s around a 52 pt play, position
  capsule, live time readouts.
- Read-along text must not run under the panel in landscape.
