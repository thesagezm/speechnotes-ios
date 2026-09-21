# Audiobooks — plan and current state

Status: **implemented, CI-green as of 2026-09-21; device test pending.**
Branch `batch-c-d-session`. Nothing merged, nothing tagged, no release.

## What was asked for

1. A sentence that fails synthesis should be **skipped on the first attempt**
   — no retry — with a **gentle** beep, then the next sentence.
2. Text in notes and books should be **cleaned** so synthesis stops failing.
3. The Books section should also **import audiobooks**.

## 1. No retry, one beep, next sentence

`StreamingTTSPlaybackCore` used to call `generateWithRetry(attempts: 2)` on
the play path and `attempts: 3` on the WAV-export path, with a
`Thread.sleep(0.15 * attempt)` between tries. That is the R8 regression the
`TTS_REGRESSION_AUDIT.md` records as "an error-handling path that is worse to
listen to than the error" — the first fix (3 attempts + 0.5 s silence) made it
30–90 s of dead air, and the second (1 retry + skip) still made the listener
wait through a second attempt at text that is going to fail the same way.

`generateWithRetry` is **deleted**. A chunk that throws is now:

- logged once, with its index out of the total (`chunk 4 of 812 skipped`);
- sounded with `BeepPlayer.playSkipTone()`;
- marked `slotSkipped` and stepped over by the schedule cursor.

The WAV export keeps its one-pass shape: a failed chunk writes a quarter
second of silence and the count lands in the export log line. No beep there —
an export is silent by definition.

### The beep

`BeepPlayer` (App/Sources/Services/BeepPlayer.swift) plays 0.18 s of a 720 Hz
sine at `Slot.level = 0.08` (≈ −22 dBFS peak) with a raised-cosine envelope on
both edges — the envelope is what makes it read as a soft tick rather than a
click. It is built once, off the audio path, and played from **its own
engine and player node** so it mixes under whatever is already sounding. The
speech engines' `AVAudioEngine` and `AVAudioPlayerNode` are never touched:
an engine allows one player per chain, and stealing the speech node would
kill the session.

Best-effort by construction — if the audio stack cannot play it the skip
still happens and the reason is logged once.

## 2. Text cleaning

New `SpeechLogic/SpeechSanitizer.swift`, wired in at extraction time so the
cached chapter text on disk is already speakable.

`clean(_:)` handles the classes of character that make a real document fail:

| Class | Examples | Why it goes |
|---|---|---|
| C0/C1 controls | `\u{07}`, `\u{1B}`, `\u{00}` | Kokoro's phonemizer emits a one-token tail; the two-row style lookup goes non-finite |
| Zero-width & format | `\u{00AD}`, `\u{200B}`–`\u{200D}`, `\u{FEFF}` | layout characters, never pronounced |
| Bidi controls | `\u{202A}`–`\u{202E}`, `\u{2066}`–`\u{2069}` | can reverse a line's phoneme order |
| Variation selectors | `\u{FE00}`–`\u{FE0F}`, `\u{E0100}`–`\u{E01EF}` | presentation modifiers |
| Private Use | `\u{E000}`–`\u{F8FF}` etc. | embedded-font glyphs with no agreed pronunciation |

Two rules that the CI loop caught and the tests now pin:

- **Replace, don't delete.** `exam\u{00AD}ple` must become `exam ple`, not
  `example` — deleting makes the engine pronounce a word the reader never saw.
  `normalizeWhitespace` collapses the runs this creates.
- **Line separators are breaks.** U+2028/U+2029 are `Separator`s, not
  `Whitespace`, so `Character.isWhitespace` misses them; they are kept by
  `isUnspeakable` and mapped to `\n` by `clean`. A lone CR is folded to LF
  before the split, because leaving it inside a line made `collapseSpaces`
  treat it as an ordinary space and silently join two lines the document had
  apart — costing the chunker a sentence boundary.

`cleanedPreservingOffsets(_:)` is the same pass for the read-along path,
replacing rather than removing so `result.utf16.count == text.utf16.count`
exactly — dropping a character there would slide every later highlight.

Wired in: `MarkdownText.plainText`, `XhtmlText.extract`, `PdfText.normalize`,
`SpeechText.forNote`/`forText` (the single derivation the editor, the
mini-player, `resumeIfBookmarkPending` and the book controller all use),
`ImportService.importText`, `NotesListView.addNote` (covers Files, clipboard,
drop and the `speechnotes://` URL in one place), and
`BookPlaybackController.chapterText` (before the chapter cache write, so a
cached chapter is clean on every later replay).

### Chunker hardening

`chunks(for:)` glues a piece under 4 UTF-16 units with nothing to say onto
the piece before it — the empty/one-token tail that actually makes Kokoro's
style lookup non-finite. **Nothing is ever dropped**: chunks must still
concatenate to the original text, which is what the read-along offsets and
the resume offset both index. An earlier draft dropped "unspeakable" pieces
and broke that invariant; the reconstruct tests caught it and the drop is
gone.

## 3. Audiobook import

`BookFormat` gains `.audio`, and a book directory holds the original as
`original.m4b` / `original.m4a` / `original.mp4` / `original.mp3`.

`SpeechLogic/AudiobookChapters.swift` reads the two chapter formats real
audiobooks ship with:

- **`chpl`** inside `moov` — the QuickTime/Nero chapter list most M4B
  encoders write. Box walking is length-prefixed and bounded, so a 900 MB
  file is never loaded; the import reads only the first 8 MB.
- **ID3v2.3/2.4 `CHAP`** frames with their `TIT2` names — the MP3 answer.
  Sync-safe sizes, the v2.4 extended header skipped.

Missing end times are filled from the next chapter's start and the last from
the file duration; untitled chapters get positional names. A file with no
chapter metadata at all becomes one implicit chapter, so the player bar still
has a unit and the position can still be remembered.

Duration and tags come from `AVURLAsset` (a header read, not a sample scan);
the cover is the embedded artwork when there is one, otherwise the shelf
shows the format glyph.

Playback is `AudioBookPlayer` + `BookAudioReaderView` — `AVAudioPlayer`
seeking inside the file, a 2 Hz progress mirror, chapter advance at the
boundary, position persisted to the manifest. **`SpeechPlayer` is not
involved at all**: no engine, no read-along, no bookmark. An audiobook cannot
be affected by anything the TTS path does.

`project.yml` registers `public.mpeg4-audio` and `public.mp3` as document
types so Open-In from the Files app works, mirroring the EPUB exception.

## What this does NOT claim

- **No device test.** Everything above is CI-verified only: `logic-tests`
  (SpeechLogic + version fields) and `build-ipa` (unsigned archive). Neither
  proves the app launches in LiveContainer — this project's two worst
  incidents (R1's "cut off after 3 words", R12's black screen) were both
  CI-green and device-only.
- **No measured beep level.** 0.08 is a judgement about "gentle", not a
  measurement. If it is too quiet or too sharp on device, `Slot.level` and
  `Slot.frequency` are the two dials.
- **No chapter-track M4B.** A `chpl`-less M4B with a real chapter `trak`
  needs the whole sample table read and is not implemented; such a file
  imports as one chapter.
- **No OCR'd/odd-encoding audiobooks.** ID3 is read as latin-1/UTF-8/UTF-16;
  an exotic tag encoding yields "Chapter N" rather than the real name.

## Device test checklist

1. Play a note with a soft hyphen, a BOM and a stray control byte in it —
   it speaks, with no gap and no beep.
2. Force a failure (a note full of Private-Use glyphs, or a model that
   cannot load mid-session): one soft tick, the next sentence, playback
   continues. No waiting.
3. Import an M4B with chapters: the shelf shows "N ch", the reader lists
   them, play advances at the boundary, reopening resumes mid-chapter.
4. Import an MP3 with ID3 CHAP frames: same.
5. Import an M4B with no chapters: one implicit chapter, still playable.
6. Background + lock screen while an audiobook plays.
7. Regression sweep: EPUB and PDF chapters/auto-advance/resume/read-along,
   note playback, WAV export.
