# The foliate engine harness

A browser harness that drives the **shipped** iOS shell
(`App/Resources/foliatejs/sn-shell-ios.js`) over the real book files in
`~/Downloads`, and reports what the engine actually produces.

It is not a re-implementation: the shell is the same file the app splices
into `foliate.html`, and the harness only asks it questions. So the numbers
it prints are the numbers the device will see.

## What it measures

**Parse mode** — the import probe (`DocumentParseService.probe`):

| Field | What it is |
|---|---|
| `title`, `author`, `language` | the book's identity, as the manifest stores it |
| `sectionCount` | how many sections the engine's book has (the manifest's spine length) |
| `toc` | the book's own contents: label, resolved section index, depth |
| `section0Chars` | the first section's prose length (the TTS source) |

**Reader mode** — the live reader:

| Field | What it is |
|---|---|
| `firstIndex`, `firstFraction` | the position the engine reports on the first relocation |
| `landedIndex` | the section the reader lands on after a chapter jump (the chevron) |
| `liveTextChars` | the prose the engine hands back for the live section (the TTS path) |
| `engine.renderer` | `foliate-paginator` or `foliate-fxl` (fixed layout) |

## Running it

```sh
# 1. serve the repo + the books
python3 -I Scripts/foliate-harness/serve.py --port 8731

# 2. open the harness
#    http://127.0.0.1:8731/Scripts/foliate-harness/index.html
```

"Run all" walks every book the server lists; "Run selected" walks one. The
report is posted back to the server and lands in
`Scripts/foliate-harness/report.json`.

Options: `--port`, `--books` (default `~/Downloads`), `--out` (default
`Scripts/foliate-harness/report.json`).

## How it works

- `frame.html` is the page the shell runs inside. It installs a
  `window.webkit.messageHandlers.reader` shim (a browser has no Swift
  bridge) that forwards every shell message to the harness page, and it
  stands in a 16 ms timer for `requestAnimationFrame` — a Chromium that is
  not compositing never fires rAF, and the foliate paginator lays out on
  it. **The rAF stand-in is a harness artefact, not engine behaviour**: a
  device renders normally.
- `index.html` runs one book at a time and tears its frame down before the
  next, so only one book is ever in the heap.

## The recorded run

`Docs/FOLIATE-ENGINE-PROBE.md` holds the numbers from the 17-file corpus
run and what they mean.
