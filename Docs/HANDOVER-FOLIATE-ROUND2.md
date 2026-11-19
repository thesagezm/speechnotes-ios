# HANDOVER — the foliate round, part 2 (engine harness + the three fixes)

**Read this first, then `Docs/FOLIATE-ENGINE-PROBE.md` (the findings and the
numbers), then `Docs/HANDOVER-FOLIATE-DOCUMENT-VIEWER.md` (the original
handover — the architecture and the five root causes it lists).**

---

## 1. Where things stand

- Branch `batch-c-d-session`. Commit **`e9b3fc3`** is **pushed**:
  *"fix(foliate): the engine opens every mobi/azw3, the chapter bar follows
  the page, and the corpus is pinned"*. The tree is clean.
- **CI is running on `e9b3fc3`: run `44481980089`** (`gh run view
  44481980089`). The workflow only triggers on a push to `main` /
  `sage-upgrades`, so this branch needs `gh workflow run build.yml --ref
  batch-c-d-session` — that is how the previous rounds were gated too.
- **There is no Swift toolchain on this box**, so CI is the compile gate.
  The next agent's first job is to watch that run (the "Build unsigned IPA"
  job is the Swift compile) and fix whatever it catches.
- The corpus run is recorded in **`Docs/FOLIATE-ENGINE-PROBE.md`**; the raw
  JSON is `Scripts/foliate-harness/report.json` (gitignored — it holds
  short text excerpts of the books).

## 2. What this round did

**The harness** (`Scripts/foliate-harness/`) — a browser page that drives the
**shipped** shell (`App/Resources/foliatejs/sn-shell-ios.js`, the file the app
splices into `foliate.html` — not a copy) over the real books in `~/Downloads`:

```sh
python3 -I Scripts/foliate-harness/serve.py --port 8731
# http://127.0.0.1:8731/Scripts/foliate-harness/index.html
```

It reports, per file: the identity + section count + resolved TOC rows the
import must record, the first section's prose (the TTS source), the position
the reader reports, and where a chapter jump lands. One book at a time; each
frame is torn down before the next.

**The corpus: 15 of 17 files open; the 2 truncated (0-byte) azw3 files are
refused with a clear message.** Every book that opened answered a chapter
jump with the right section index and handed back its section's prose. The
publisher's own chapter names are in the TOC ("CHAPTER 1: GRANT'S FORMATIVE
YEARS"), not "Chapter 1…N".

## 3. The three bugs it found (all fixed in `e9b3fc3`)

1. **The import probe would have failed for every mobi/azw3.** `mobi.js`
   reports `language: ['en']` (a LIST); Swift's `ParseMeta.language` is a
   `String?` → the decode threw → the import fell back to the Swift parse →
   `docRenderer: "pages"` → the foliate reader never opened the book. That
   is the original complaint, reproduced by the *new* code. Fixed at the
   boundary: the shell flattens the engine's title/author/language, and the
   unused `language` field is out of `ParseMeta`.
2. **A section with no text reports NO relocation** (the paginator returns
   early when there is no visible range), so the chevron moved the page but
   never moved the bar. The shell now asks the renderer which section it is
   showing (`renderer.primaryIndex`) after every jump, turn and TOC tap.
3. **The compile gate would have failed**: `BookReaderView` passed
   `onBook`/`onSectionText` before `onError` to `BookWebView`'s memberwise
   initializer; Swift requires the declaration order.

Plus two read-through finds: the shell's `unescapeXml` had lost its `'#39'`
entity key to a stray colon (a TOC label with an escaped apostrophe would
have read **"undefined"**), and the **resume fraction is not dead** — the
handover said the paginator's anchor is a pixel offset; it is a **section
fraction**, so the fraction is used again (the resume is the CFI, else the
chapter + the fraction inside it).

## 4. What is left

1. **Watch CI run `44481980089`.** If the Swift compile fails, fix it, commit
   and re-dispatch (`gh workflow run build.yml --ref batch-c-d-session`).
   The riskiest spots are the ones §5.1 of the original handover lists, plus
   the argument-order fix (already applied).
2. **The device round** — what the harness cannot see (real WKWebView, the
   custom scheme, SwiftUI, the voice):
   - import a fresh `.mobi` → the manifest must show `docRenderer: "foliate"`,
     the engine's section count and the publisher's TOC;
   - open an existing shelf book → the migration re-stamps it;
   - the next/prev chevrons move one section at a time and the bar reads
     "Chapter N of M" with the right N;
   - the Contents sheet lists the publisher's chapters and a tap lands on
     the right section;
   - a TTS play speaks the chapter on screen;
   - close mid-chapter and reopen → the CFI resume lands mid-chapter.
3. **Log the round in `PROGRESS_LOG.md`** when the CI result is known (the
   entry for this round is already there; add the CI line).

## 5. Gotchas (read before touching anything)

- **Do NOT re-vendor the foliate modules.** `view.js`, `paginator.js`,
  `mobi.js`, `fb2.js`, `sn-*.js`, `fixed-layout.js` are byte-identical to
  `~/code/speechnotes-linux/crates/sn-ui/assets/foliate-js/` on purpose
  (verified again this round). Only `sn-shell-ios.js` is ours.
- **The harness's rAF stand-in is a harness artefact.** A Chromium that is
  not compositing never fires `requestAnimationFrame` (measured: 0 ticks in
  2.5 s), so `frame.html` stands in a 16 ms timer. A device renders normally;
  do not "fix" the shell to match the harness.
- **`Book.docEngineTried: Bool = false`** relies on the synthesized
  `Decodable` honouring a missing key via the property's default. The
  repo's precedent proves it (`Book.forceOCR: Bool = false`, 0e27a49, a
  month ago — the user's pre-flag shelf still decodes). `BooksStore`'s
  loader SKIPS a book whose manifest fails to decode, so a wrong call there
  would empty the shelf silently. Do not "harden" this by making it optional
  or by writing a custom `init(from:)` without a compiler in hand.
- **A refusal is terminal.** `docEngineTried` means the engine has had its
  try (opened it, or refused it); a refused book is never asked again. A
  book stamped `"pages"` keeps its `doc/` pages — the migration only deletes
  them on the success path.
- **The fixed-layout renderer counts SPREADS, not sections** (a pre-paginated
  KF8 reports a page index). The shell leaves that renderer's index alone
  and the harness records `isFixedLayout`. No file in this corpus is
  fixed-layout, so it is unmeasured.
- **`fb2` varies by file**: *The Great Gatsby* gives 10 sections / 10
  chapter rows; *The catcher in the rye* and *One Hundred Years* (fb2) give
  1 section / 1 row (those files put the whole book in one `<section>`), and
  the Great Gatsby fb2's first row label is empty. That is the engine's
  truth (and the Linux app's), not a bug.

## 6. File index

| Concern | Path |
|---|---|
| The engine shell (ours) | `App/Resources/foliatejs/sn-shell-ios.js` |
| The harness (page + frame + server) | `Scripts/foliate-harness/` |
| The recorded corpus run + the findings | `Docs/FOLIATE-ENGINE-PROBE.md` |
| The original handover (architecture, root causes) | `Docs/HANDOVER-FOLIATE-DOCUMENT-VIEWER.md` |
| The headless engine (probe + section text + the bytes route) | `App/Sources/Services/DocumentParseService.swift` |
| Import stamping + the migration | `App/Sources/Services/BooksStore.swift` |
| The manifest model | `App/Sources/Models/Book.swift` |
| The WKWebView host, the scheme handler, the bridge | `App/Sources/Views/BookWebView.swift` |
| The reader controller (chevrons, TOC sheet, write-back) | `App/Sources/Views/BookReaderView.swift` |
| The TTS text source | `App/Sources/Services/BookPlaybackController.swift` |
| The round's log entry | `PROGRESS_LOG.md` (top) |
| The Linux reference app | `~/code/speechnotes-linux/crates/sn-ui/assets/foliate-js/` |
