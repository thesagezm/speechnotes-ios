# FOLIATE ENGINE PROBE — the 17-file corpus, measured

The engine harness (`Scripts/foliate-harness/`) drives the **shipped** iOS
shell (`App/Resources/foliatejs/sn-shell-ios.js`) over the real books in
`~/Downloads` and reports what it produces. It is not a re-implementation —
the shell is the same file the app splices into `foliate.html`, so the
numbers below are the numbers the device will see.

Run it:

```sh
python3 -I Scripts/foliate-harness/serve.py --port 8731
# http://127.0.0.1:8731/Scripts/foliate-harness/index.html
```

See `Scripts/foliate-harness/README.md` for what each column means. The raw
run is `Scripts/foliate-harness/report.json`.

**Corpus:** 17 files — 5 `.mobi`, 5 `.azw3`, 3 `.fb2`, 2 `.rtf`, 1 `.html`,
1 `.txt`. Two of the `.azw3` files are 0 bytes (truncated downloads) and are
kept as **negative cases**: the engine must refuse them, not crash.

---

## 1. What the engine produces

| file | fmt | sections | TOC rows | title / author | jump lands |
|---|---|---|---|---|---|
| Truth in Comedy (Halpern/Close/Johnson) | mobi | 99 | 98 | *Truth in Comedy: The Manual of Improvisation* / Charna Halpern, Del Close, Kim Johnson | ✅ 1 |
| IMPRO (Johnstone) | mobi | 13 | 12 | *IMPRO Improvisation and the Theatre* / Keith Johnstone | ✅ 1 |
| A Reader's Companion (Beidler) | azw3 | 1 | 17 | *A Reader's Companion…* / Beidler, Peter | ✅ 0 |
| Catcher in the Rye (Marsden) | rtf | 3 | 2 | *(none — the RTF carries no metadata)* | ✅ 1 |
| Great Gatsby | html | 1 | 1 | *The Great Gatsby* | ✅ 0 |
| One Hundred Years of Solitude | txt | 21 | 21 | *(none — the chapteriser found no title)* | ✅ 1 |
| The Great Gatsby (Fitzgerald) | rtf | 5 | 4 | *(none)* | ✅ 1 |
| In Search of Lost Time I–VII (Proust) | azw3 | 86 | 9 | *…Remembrance of Things Past…* / Proust, Marcel | ✅ 1 |
| The catcher in the rye | fb2 | 1 | 1 | *The catcher in the rye* / Jerome David Salinger | ✅ 0 |
| Ulysses S Grant (Johnson) | azw3 | 19 | 16 | *Ulysses S Grant: The Forgotten Hero* / Johnson, Jack | ✅ 1 |
| Ulysses | azw3 | 13 | 12 | *Ulysses* / James Joyce | ✅ 1 |
| One Hundred Years of Solitude (mobi) | mobi | 29 | 26 | *One Hundred Years of Solitude* / Gabriel García Márquez; Gregory Rabassa | ✅ 1 |
| One Hundred Years of Solitude (fb2) | fb2 | 1 | 1 | *One Hundred Years of Solitude* / Gabriel Garcia Marquez | ✅ 0 |
| Proust I–VII **×2 (0 bytes)** | azw3 | — | — | **refused** — "not a Mobipocket book" | — |
| Steps to Christ | mobi | 17 | 15 | *Steps to Christ* / Ellen G. White | ✅ 1 |
| The Great Gatsby (fb2) | fb2 | 10 | 10 | *The Great Gatsby* / Francis Scott Key Fitzgerald | ✅ 1 |

**15 of 17 open; the 2 truncated ones are refused with a clear message.**
Every book that opened also answered a **chapter jump** (the chevron) with
the right section index, and handed back the section's prose for the TTS
path.

### The TOC rows the manifest must carry

The engine's own contents, with the section each row resolves to — this is
what `DocumentParseService.probe` records and what the Contents sheet shows:

| book | first rows (label → section index) |
|---|---|
| IMPRO (mobi) | Cover → 0, Title Page → 1, Contents → 2, A selection of books in this series → 3, Introduction → 5 |
| en_SC / Steps to Christ | Information about this Book → 2, Foreword → 3, Chapter 1—God's Love for Man → 4, Chapter 2 → 5, Chapter 3 → 6 |
| Ulysses S Grant (azw3) | INTRODUCTION: A TROUBLED AMERICA → 3, CHAPTER 1 → 4, CHAPTER 2 → 5, CHAPTER 3 → 6, CHAPTER 4 → 7 |
| One Hundred Years (mobi) | ONE HUNDRED YEARS OF SOLITUDE → 0, GABRIEL GARCIA MARQUEZ → 4, TRANSLATED FROM SPANISH → 4, BY → 4, GREGORY RABASSA → 4 |
| In Search of Lost Time (azw3) | Title Page → 0, Copyright → 1, Contents → 2, Volume I → 3, Volume II → 20 |
| The Great Gatsby (fb2) | Francis Scott Fitzgerald The Great Gatsby → 0, CHAPTER I → 1, CHAPTER II → 2, CHAPTER III → 3, CHAPTER IV → 4 |
| Ulysses (azw3) | Title Page → 0, epubBooks Information → 1, Notes on this epubBooks title → 2, — I — → 3, — II — → 4 |
| One Hundred Years (txt) | Gabriel → 0, Chapter 1 → 1, Chapter 2 → 2, Chapter 3 → 3, Chapter 4 → 4 |
| Truth in Comedy (mobi) | page1 → 1, page2 → 2, page3 → 3, page4 → 4, page5 → 5 |

**The publisher's own chapter names are there** — "CHAPTER 1: GRANT'S
FORMATIVE YEARS", "Chapter 1—God's Love for Man" — not "Chapter 1…N". That
is the report the reader was filed about.

---

## 2. What the probe found (and what was fixed)

### 2.1 The metadata report would have failed the decode — every mobi/azw3

`mobi.js` and the KF8 builder report `language: ['en']` — a **list** — while
FB2 reports `language: 'en'`, a string. The shell passed the engine's value
through untouched, and Swift's `ParseMeta.language` is a `String?`, so
`JSONDecoder` threw a type mismatch on **every Kindle file**:

```
probe() throws → the import catches it → the Swift fallback parse runs →
docRenderer: "pages" → the foliate reader never opens the book.
```

That is the original complaint, reproduced by the *new* code. Fixed in two
places: the shell flattens the engine's metadata (`metaTitle` / `metaAuthor`
/ `metaLanguage`) at the boundary, and the unused `language` field is out of
`ParseMeta` — a field the manifest does not use must never be able to fail
the decode and take the whole book down to the fallback renderer.

*Verified: the language now reads `"en"` for every file in the corpus.*

### 2.2 A section with no text reports no relocation — the chevron did nothing

`Truth in Comedy` (a 99-page graphic-layout mobi) is the file that showed
it: the reader jumped to section 1, the section **loaded** (`section loaded
1` in the shell's log), and **no relocation ever arrived** — so the bar
stayed on "Chapter 1" and the reader's own state never moved.

The reason is in the paginator: a section with no text has no visible
range, and `#relocate` returns early when there is none (`if (!range)
return`). The engine never says where it is.

Fixed in the shell: the renderer knows which section it is showing
(`renderer.primaryIndex` — the spine index, the manifest's numbering), so
after a jump, a page turn or a TOC tap the shell reports the position
itself when the renderer stayed silent. A section change resets the
fraction to that section's top; a move inside one section keeps it.

*Verified: the jump to section 1 now reports `landed: 1` on the file that
previously reported nothing.*

### 2.3 The resume fraction was dropped on the floor — and the handover's reason was wrong

The handover called `resumeFraction` a dead parameter and wrote that "the
paginator's anchor is a pixel offset". It is not: in this fork
`paginator.js` takes a numeric anchor as a **fraction of the section**
(`#anchor = 0 // anchor view to a fraction (0-1)`, and
`#scrollToAnchor` uses `anchor * primarySize`). The fraction was dropped
because it was in the wrong unit (a whole-book one), not because the
anchor could not carry it.

So it is now used, correctly: the resume is the CFI when there is one, and
otherwise the manifest's chapter plus the fraction **inside** that chapter,
riding as the anchor. That is the unit the reader now reports and
persists — and the unit the pages pipeline stored.

### 2.4 The compile gate: one argument-order error

`BookReaderView` builds `BookWebView(…)` with a memberwise initializer, and
the new `onBook` / `onSectionText` arguments were passed **before**
`onError`, which the struct declares earlier. Swift requires the arguments
in declaration order — this would have been rejected by the compiler with
*argument 'onBook' must precede argument 'onError'*. Fixed by moving
`onError` back above them.

### 2.5 A typo in the uncommitted work: `'` became the word "undefined"

The shell's `unescapeXml` (the TOC labels come XML-escaped) had its entity
map keyed `'#39:'` — with a stray colon — where it should be `'#39'`. The
regex captures `#39`, the lookup missed, and the replacement was
`undefined` — so **every TOC label containing an escaped apostrophe would
have read "undefined" in the Contents sheet**. The key is fixed, and an
entity the map does not know is now left as it was instead of being
replaced with the word "undefined".

*This one was in the tree before the harness ran — the harness cannot see
it (no corpus label happens to carry `'`); reading the diff did.*

---

## 3. What the numbers say about the formats (not bugs — the engine's truth)

These are the engine's behaviour, identical to the Linux app's, and they
shape what the reader can offer per format:

- **FB2 varies by file.** `The Great Gatsby` (fb2) gives **10 sections and
  10 chapter rows** — a real chapter bar. `The catcher in the rye` and
  `One Hundred Years of Solitude` (fb2) give **1 section and 1 row**: those
  files put the whole book in one `<section>`, so there is nothing to split
  and the Contents sheet has a single row. The Great Gatsby fb2's first row
  label is **empty** (its title element carries no text) — one blank row
  in the sheet.
- **A Kindle file can have more sections than TOC rows** (Proust: 86
  sections, 9 rows) — the nav is a table of volumes, the spine is the flow.
  The bar counts sections, the sheet lists the volumes; both are correct
  and they are different things.
- **Some KF8 nav labels are placeholders** (`{chapter-3}` in *Ulysses*) —
  the file's own nav says so; the engine passes it through.
- **RTF and HTML carry no metadata** — title and author are empty, because
  the file has none. The RTF builder still finds the headings
  ("THE CATCHER IN THE RYE", "CHAPTER III").
- **The `.txt` chapteriser's labels include the first line of the chapter**
  ("Chapter 1 ⏎⏎ MANY YEARS LATER as he faced the firing squad,"). The
  row is long, but it points at the right section.

---

## 4. Still open

- **CI is the compile gate** (no Swift toolchain on this box). The
  argument-order fix in §2.4 is the one error this review found; the rest
  is a careful read, not a compile.
- **The device round** — what the harness cannot see: the real WKWebView,
  the custom scheme, the SwiftUI bar, the TTS voice, and the resume after
  a kill. The list is in `Docs/HANDOVER-FOLIATE-DOCUMENT-VIEWER.md` §5.3.
- **A fixed-layout book** (a pre-paginated KF8) reports a **spread** index,
  not a section index; the shell leaves that renderer's index alone and the
  harness records `isFixedLayout` so it is visible. No file in this corpus
  is fixed-layout, so it is unmeasured.
- **The harness's rAF stand-in** is a harness artefact (a Chromium that is
  not compositing never fires animation frames). A device renders normally;
  the stand-in exists so the paginator lays out at all here.
