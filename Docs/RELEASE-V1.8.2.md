# v1.8.2 — release notes

Status: **tagged and released at the user's go.** Everything below was
CI-green on `batch-c-d-session` before the tag; device checks were the
user's round. Version 1.8.2, build 48. Build 47 (v1.8.1) was the BookDrop
transfer-fix + maths round of the same release grouping and was never
tagged separately; v1.8.0 was the previous tagged release.

## Books

**The document family reads in the real reader (foliate-js).** mobi, azw,
azw3, prc, pdb, fb2, rtf, html/htmlz and txt/md open in the vendored
foliate-js engine — the same reader engine the Linux app uses — rendering
the ORIGINAL file. Nothing is converted to EPUB on the read path. The
publisher's own table of contents carries through with real chapter names;
a chapter jump lands in-renderer, instantly, with no page reload (the old
pre-parsed-pages pipeline was why the mobi chapter buttons lagged); resume
is a real foliate CFI (legacy pseudo-CFIs migrate to chapter + section
fraction); one section iframe is held in memory at a time. The reader, the
TTS chapter parse and the TOC share ONE section numbering by construction —
"speaking chapter 4 while reading chapter 5" cannot exist. Existing shelf
books migrate to the new renderer on launch; a file the engine refuses
falls back to the previous pipeline, stamped honestly in the manifest.

**The mobi/azw3 TOC is the publisher's.** The real Kindle index layout is
parsed (TAGX numeric table, VWI entry walk, CNCX label runs) where the old
code read an invented layout and silently returned an empty TOC on every
real book — publisher chapter names replace the "Chapter N" heading
heuristic, and the chapter cut happens on the raw stream so offsets after
the first pagebreak cannot drift. RTF chapter splitting was dead twice over
(the spec's toggle rule read backwards, and group-scope dropped the marked
flag); bold standalone titles split again. The EPUB TOC tree renders — the
manifest snapshot now keeps the `depth` field it dropped.

**Slide decks are a book format.** PPTX decks import whole and render —
preset shapes including bare rule lines and arrows, gradients (with the
mirrored-angle defect fixed), Wingdings/Webdings/Symbol bullets and text —
speech reads slides in VISUAL order (top→bottom, repeated lines once) so
the footer no longer ends every slide, the deck re-fits on every rotation
and rail change, and it fills the viewport edge-to-edge like the PDF does.
The renderer is a port (SlideDeckKit, deckcraft-lineage) kept whole; decks
are never converted.

**Covers arrive.** Ogg/Opus audiobooks pick up their embedded artwork (the
FLAC picture block was never extracted before — a rev-bump gives existing
books one self-heal re-read, a few per launch, oldest first); M4B covers
read before the waits instead of after; a cover that lands after the tile
painted now repaints the tile; and a cover-less document book heals via the
native mobi cover path (fresh imports, migrations and the backfill).

**The scrubber holds where you drop it.** A seek publishes the target and
holds the readout until the clock confirms, and the two per-seek O(n) scans
over up to 2M Opus packets are cached at load.

## Speech

**Nano Edge — the fifth engine.** Kokoro's 28 English voices, tokenizer and
phoneme front end over a distilled two-graph ONNX decoder (~157 MB, one
download, fully offline, 24 kHz). Same voices, same pronunciation, same
speaker codes as Kokoro — a compact option between the compact-Kokoro and
Phonon tiers.

**Phonon's chunk click and dead air are gone.** Every chunk gets a
sentence-shaped boundary fade (5 ms in, 12 ms out) on playback AND export,
and the keepalive silence bridge shrank 0.5 s → 0.2 s so a synthesized
chunk no longer queues behind half a second of padding.

**Copy out of every reading surface.** Long-press selects in the read-along
of EPUB, PDF, slides and notes (the native Copy/Share/Look Up menu — there
was no way to lift text out at all); the markdown preview's prose —
paragraphs, headings, quotes, list items, table cells — selects (code
blocks already did); and the editor's native selection menu carries "Play
from selection" (sentence-snapped, idle-only), alongside the ⋯ menu's
"Play from caret". Tap-to-speak in read-along is unchanged: a tap still
starts speaking from the tapped paragraph.

**Row menus hold the full action set.** Note rows gain Rename… (alert with
editor-style fallback to the derived title), Share and Export alongside
Pin/Favorite/BookDrop/Move; both recycle bins gain long-press Recover /
Delete Now to match their swipes.

## App

**Settings rebuilt to the Android reference.** Flat icon+title+subtitle
rows; engine rows state verifiable facts only (voices, sizes, languages —
no "best quality", no "on-device neural" filler); ONE Models list sorted
smallest→largest with a single download/retry/delete button per model;
every footer essay replaced by a nav-bar ⓘ sheet; Bypass-Paywalls is always
on (the toggle is gone) and the image-caching picker is gone; Keep Screen On
lives in Appearance; Logs moved to a Diagnostics section with Benchmark
mode; Backup collapses to one row with JEX import inside; the duplicated
second copy of the speech settings (NoteEditorView's modal) is deleted.

**Acknowledgements.** The About row always promised it — one grouped list of
what each vendored/SPM/model piece does here, its license and its source.

**Immersive chrome takes the tab bar too.** Tap-to-hide on all four reading
surfaces now removes the tab bar as well (iOS 18 `.toolbar(_:for: .tabBar)`)
— the safe-area inset it held is handed back, so the portrait playback rail
docks into the strip the tabs vacated and the landscape surface runs to the
screen's bottom edge in every reader.

**Benchmark mode** (Diagnostics) — the sustained-synthesis harness with
CSV/JSON exports lives in the app for device measurement rounds.

## Fixes along the way (the v1.8.1 grouping, build 47)

- BookDrop transfer fix + transfer progress bars.
- Maths rendering fixes (unescaped-dollar handling).
- Background TTS persistence, playback ownership and identity-safe remote
  commands, self-repairing TTS resume, Opus one-tap start + exact audiobook
  bookmarks.
- Linux parity round: HTMLZ images, TOC depths, continuation titles, HUFF
  and RTF fixes.
- Web import: flat-paragraph root cause fixed, a 15 s hang guard, and the
  Bypass-Paywalls pass runs on every import.
