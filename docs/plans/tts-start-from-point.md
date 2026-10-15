# Start-from-point TTS + rewind/forward — plan and shipped state

User request (2026-10-13): "5 ways to start from a specific sentence/point/word in a note/book
and continue TTS from there… and ways to rewind or move forward if I didn't hear something or
already heard this."

Three of the five ways shipped in the same commit as this plan (`playFrom` batch, CI green).
This document records what shipped, specifies the two remaining ways, and specifies the
rewind/forward extensions.

## The foundation (shipped)

`SpeechPlayer.playFrom(_:at:note:book:)` (App/Sources/Services/SpeechPlayer.swift) is the ONE
entry point every start-from-point affordance funnels into:

- Takes a UTF-16 offset into the speech text.
- Snaps it to the sentence boundary at-or-before the offset via the same `snapResume` math
  bookmarks use (`SentenceChunker.resumeOffset`), so playback always starts on a sentence.
- Speaks the suffix through the normal `speak` path — all three engines (system AVSpeech,
  Kokoro, Supertonic) get identical treatment because they all consume the suffix string and
  chunk it internally.
- Primes the bookmark at the new offset, so the start point BECOMES the resume point.
- Keeps `onNaturalFinish` armed for book refs, so chapter auto-advance survives a mid-chapter
  start.

## The five ways

### 1. Play from the caret (notes) — SHIPPED

- UX: editing a note, cursor anywhere; ⋯ menu → "Play from caret".
- Entry: `NoteEditorView.playFromCaretOffset` (maps the editor's `selectionUTF16` into the
  speech text; nil near the top) → ⋯ menu item → `player.playFrom(..., note:)`.
- Effort: S. Done.

### 2. Tap a paragraph in read-along — SHIPPED

- UX: while listening, the read-along surface shows the text with the current sentence
  highlighted; tapping any paragraph starts speech from that paragraph's first sentence.
- Entry: `ReadAlongView.onTapParagraph` (rows carry their own UTF-16 start) wired in all three
  readers: `NoteEditorView` (notes), `BookReaderView` (epub), `BookPDFReaderView` (pdf) — the
  book ones pass a `BookPlaybackRef` for the current chapter so the chain keeps advancing.
- Edge cases handled: mid-word taps snap to the sentence; a tap on the already-sounding
  paragraph re-speaks it from the top (predictable).
- Effort: S. Done.

### 3. Sentence rewind/forward buttons — SHIPPED (notes)

- UX: portrait `PlayerControlsBar` gains two `arrow.uturn` buttons flanking read-along/stop;
  landscape `PlaybackRail` gets the same via `onStepBack`/`onStepForward`.
- Math: anchor = `player.readAlongRange.lowerBound` (play-accurate, from the engine's played-chars
  tracker); pieces = `SentenceChunker.sentencePieces(in: activeSpeechText)`. Forward = first
  piece starting after the anchor; back = `lastIndex(where: offset < anchor)` — mashing steps
  one sentence per press because the anchor moves with each re-speak. At the first sentence,
  back wraps to `restartFromBeginning`.
- Effort: S. Done for notes. Books' read-along shares the same bar for epub/pdf TTS playback
  (the bar's math runs over `activeSpeechText`, which is the chapter text either way).

### 4. Select text → "Speak from here" (notes + epub) — SPECIFIED

- UX: long-press select any span; a "Speak from here" item joins the selection menu (the
  editor's UIMenuController / SwiftUI contextMenu on selection; in the epub reader a
  selection relay over the existing reader.js bridge).
- Entry (notes): `NoteEditorView` already tracks `selectionUTF16` — add the menu item next to
  the format bar's actions; call `playFrom(SpeechText.forText(speechText), at: selection.lowerBound)`.
- Entry (epub): reader.js `attachGestures` already detects selections (it skips chrome toggles
  when one exists). Add a `selectionStart` message: on `touchend`/`mouseup` with a non-collapsed
  selection, post `{speechnotes:"selection", cfi}`; the shell relays to `BookWebView.onSelection`;
  `BookReaderView` maps CFI → char offset via epub.js `book.locations` (needs a
  `locations.generate()` pass at 1024 chars — S) or, cheaper, uses `rendition.getRange(cfi)` and
  walks the section's text nodes. Then `BookPlaybackController.speak(book:from:)` variant with an
  offset (chapter text is already cached on disk, so the suffix math runs on the cached string).
- Engine implications: none beyond `playFrom` — offset math is text-space.
- Risks: epub.js range→text-offset mapping is the one genuinely fiddly part (whitespace
  normalization in XhtmlText.extract means offsets must be computed against the CACHED speech
  text, not the raw xhtml). Mitigate by probing `locations.percentFrom(cfi)` and multiplying by
  the cached chapter length, then letting `playFrom`'s sentence snap absorb the slop.
- Effort: M (notes: S; epub: M).
- Recommendation: implement notes-side first (S), epub behind it.

### 5. Long-press a paragraph in the reader page (epub, no selection needed) — SPECIFIED

- UX: press-and-hold (~500 ms) on a paragraph inside the epub webview → small "▶ Speak from
  here" popover anchored at the touch; tap plays from that paragraph.
- Entry: reader.js `attachGestures` gets a `touchstart` timer (canceled on move/scroll);
  on fire, walk up from `event.target` to the nearest block element (`p/h1…/li`), take its
  first text node, compute the offset into the section the same way way 4 does, and post
  `{speechnotes:"speakFrom", percent}` (percent within the rendered section — immune to
  offset drift). Native side posts into the same `BookPlaybackController` offset path as way 4.
- Interaction with tap zones: the long-press must suppress the following `click` (chrome toggle /
  page turn) — reader.js already tracks `touchstart/touchend`, so set a `suppressNextClick` flag.
- Effort: M.
- Recommendation: ship with way 4's epub half (same plumbing, second gesture).

### Already-present (not counted in the five, but user-visible)

- "Restart from beginning" (⋯ menu) = way at offset 0.
- Sentence-snapped resume after suspension/quit (existing bookmark machinery).
- Audiobooks: chapter sheet, ±15 s skips (in-app + lock screen), scrub slider — seconds-addressable.

## Rewind/forward extensions (not yet built)

1. **Notes/books TTS ±N seconds.** True seconds-seek is impossible for synthesized speech
   (audio is generated per chunk), but the equivalent is char-space stepping: keep a
   `charsPerSecond` EMA from `PlaybackMetrics` (audioSeconds vs chars per chunk) and map
   "−15 s" → `playedChars − 15·cps`, snapped to a sentence. Reuse the sentence-step buttons'
   path with a computed offset. Effort: S, after the EMA is surfaced (it already exists inside
   `PlaybackMetrics` per session).
2. **Sentence step for audiobooks (Opus engine path).** The Opus packet stream has no
   sentence notion; skip there stays ±15 s (shipped) and chapter chevrons. No work.
3. **"Jump to last-heard".** `playFrom` already writes the bookmark, so this is free: the
   resume path IS last-heard. No work.
4. **Lock-screen sentence commands.** Not viable — `MPRemoteCommandCenter` skip commands map
   to seconds; books keep ±15 s, TTS keeps chapter skip. No work.

## Order of implementation

Shipped first (ways 1–3 + foundation), then way 4 notes (S), then ways 4+5 epub (M, shared
plumbing), then ±N seconds via cps EMA (S). Each step is independently shippable.
