# HANDOVER — 2026-10-25: books minimised transport (round 2)

**Status: implemented, CI pending at the time of writing. Version untouched
(1.8.0 / build 45) — the user groups features into releases.**

## The user report this round

> "the bar showing controls for next and previous chapter as well the chapter
> number and pages persist above the minimised bar... i want this gone when i
> minimise... maybe just the next and previous controls can be folded into the
> minimised bar - allow it to have opacity like the one in notes... and use
> the extra gained space to display more of the book... basically make it
> exactly the same as in notes maybe with just the addition of next and
> previous control in minimised bar"

Context: the FIRST minimise round (commit `ffe47ec`, 2026-10-25) added the
collapse to the book readers but only collapsed the PLAYBACK BAR. The
readers put their chapter / page bar in a SIBLING ROW ABOVE it, so that bar
stayed on screen — exactly the "persists above the minimised bar" symptom.

## What changed

### 1. One shared pill — `App/Sources/Views/MinimizedBookTransport.swift` (NEW)

The Notes shape: a slim `RoundedRectangle(cornerRadius: 18)` filled with
`.ultraThinMaterial` + a soft shadow, floating over the content with
horizontal padding so the reading surface runs under it (that transparency
is what lets "more of the book" show).

Contents, left to right:

| Element | Notes' pill | Books' pill |
|---|---|---|
| Play/pause | 28 pt accent circle, 13 pt bold glyph | same |
| Previous chapter | — | chevron.left in a soft circle (new) |
| Readout | `NN%` | `NN%` (the EPUB/PDF bar's own "N% of chapter" shortens to `NN%`) |
| Next chapter | — | chevron.right in a soft circle (new) |
| Expand | chevron.up in a soft circle | same |

The steppers are optional (`onStepBack` / `onStepForward` = nil hides that
side) and carry their own enable state, so a book with one chapter shows no
dead chevron.

### 2. The chapter / page bars now HIDE while minimised

- `BookReaderView` (EPUB): `if !bookBarMinimized { chapterBar }`.
- `BookPDFReaderView`: `if !bookBarMinimized || !hasChapters { pageBar }` —
  a PDF with no chapters has NO playback bar, hence no minimise button, so
  its page bar must stay (otherwise a chapterless PDF would lose its page
  readout entirely).
- `BookAudioReaderView`: `if !bookBarMinimized { chapterBar }`.

The freed vertical space goes straight back to the reading surface (the
webview / PDFView / cover block), because those readers are a `VStack` with
the bars at the bottom.

### 3. The steppers moved INTO the pill

- EPUB: `onStepBack: { goChapter(chapterIndex - 1) }`,
  `onStepForward: { goChapter(chapterIndex + 1) }`, disabled at the ends
  (`chapterIndex > 0`, `chapterIndex < totalChapters - 1`).
- PDF: the same, against `currentChapterIndex` / `totalChapters`.
- Audiobook: `stepChapter(-1)` / `stepChapter(1)`, which clamp against
  `playableChapters` (the placeholder-only book case).

Both the pill's steppers and the expanded bars' own chevrons call the SAME
functions, so they can never disagree about where a chapter boundary is.

### 4. The preference

`@AppStorage("bookBarMinimized")` — ONE key for all three readers, so the
app opens the way the user left it (the editor-bar pattern: the note editor
uses its own `editorBarMinimized`; the landscape rail uses
`landscapeRailMinimized`; the book portrait transport now uses this one).

## Files touched

- `App/Sources/Views/MinimizedBookTransport.swift` — NEW shared pill.
- `App/Sources/Views/BookPlayerBar.swift` — the EPUB/PDF bottom bar's
  minimised branch now renders the shared pill; the stepper callbacks
  became optional parameters.
- `App/Sources/Views/BookReaderView.swift` — chapter bar hidden while
  minimised; steppers passed to the bar.
- `App/Sources/Views/BookPDFReaderView.swift` — page bar hidden while
  minimised (except for chapterless PDFs); steppers passed to the bar.
- `App/Sources/Views/BookAudioReaderView.swift` — chapter bar hidden while
  minimised; the local minimised pill replaced by the shared one, with
  the steppers folded in.

## Still open / next steps

1. **Device check (the only real gate).** Open an EPUB, PDF and an
   audiobook in portrait; collapse each; confirm (a) the chapter/page bar
   is gone, (b) the pill is translucent and the book shows through, (c) the
   chevrons step chapters, (d) expanding restores the full bar. Rotate to
   landscape and back — the portrait pill state must survive.
2. **A chapterless PDF** — the page bar must still be there (no minimise
   button exists for it).
3. **The audiobook's `blockedReason` state** (a DRM/unsupported file) shows
   a banner instead of the transport; the minimise key stays as it was, so
   returning from a blocked state lands in the same shape it left.

## Notes for the next session

- The Xcode project is GENERATED (`xcodegen generate` from `project.yml`,
  which globs `App/Sources`) — a NEW Swift file needs no project edit, but
  CI must run `xcodegen` before building (it does).
- There is NO local Swift toolchain in this environment: every change is
  verified by GitHub Actions (`Scripts/watch_ci.sh <sha>`), and the build
  workflow does NOT auto-run on this branch — dispatch it manually
  (`gh workflow run build.yml --ref batch-c-d-session`).
- Do NOT bump `MARKETING_VERSION` — the user decides which features land in
  which release; only the build number moves, and only on their word.
