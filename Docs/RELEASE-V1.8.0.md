# v1.8.0 — release notes

Status: **tagged and released at the user's go.** Everything below was
CI-green on `batch-c-d-session` before the tag; device checks were the
user's round. Version 1.8.0, build 46 (builds 44–45 were the web-import and
pomodoro rounds of the same release grouping).

## Books

**The readers show the book behind the chrome.** The page colour runs behind
the tab bar to the physical bottom of the screen — and behind the status bar
when a tap hides the chrome — in the EPUB and PDF readers. The old solid slab
behind the bars is gone (sepia on white was the loudest case). Content keeps
its native insets, so a chapter or page always ends with its last lines
readable ABOVE the chrome; the fill is colour, never text. EPUB portrait
controls float over the book via the note editor's `safeAreaInset` mechanism
(paginated flow gets the matching `env()` container inset in reader.js); PDF
pages keep their reserved window (fixed geometry can't inset). The landscape
playback rail is untouched.

**Wide tables pan.** Converted books' many-column tables — the ones that
clipped at the page edge — become laterally pannable blocks (per-section CSS
in reader.js, verified in a browser against the real script). Nested tables
keep native layout; a swipe starting on a table pans the table instead of
turning the page.

**TTS starts where you look.** Play begins at the viewed page/spot (PDF page
through the chapter's page-offset sidecar, EPUB scroll fraction); a stored
bookmark still wins, with start-of-chapter positions counting as no bookmark.
In read-along, tapping a Contents row moves the SPEECH to that chapter.

**Chapter navigation lands.** A jump the webview can't carry out is reported
back and either held (book still opening) or rolled back — no more silent
dead chevrons and a bar lying about the chapter. The mid-chapter position is
a throttle with a trailing write plus a background flush, so scrolling no
longer loses the exact spot.

**The minimised transport is one pill.** The Notes-style pill is shared by
EPUB, PDF and audiobook readers; chapter/page bars hide while minimised and
the prev/next chevrons ride the pill.

**mobi/azw books, OCR for scans, m4b chapters.** Real .mobi/azw/azw3/prc
reading with Calibre-exact text extraction; CamScanner-style scans get
watermark-aware OCR with a per-book force-OCR toggle; m4b audiobooks play
with their own chapter TOC.

## Speech

**Maths, rendered and spoken.** LaTeX in notes renders as display glyphs in
the preview AND speaks as words — the engine receives "beta summed over…",
never "β∑". Exports keep the glyphs.

**The audible gap is gone.** The chunk schedule is seconds-based
(100/125/150/175/200 tiers) instead of the character ladder that made
time-to-first-audio short and gaps audible.

**Background persistence.** The never-run-dry silence bridge for the
streaming core, chapter-gap grace chained through first audio, and
crash-marker + memory vitals that name crash vs system kill when the process
dies mid-playback. Stop→play resumes exactly; start-from-point TTS (tap a
paragraph) shipped earlier in the cycle.

## Focus & stats

**Pomodoro on the Stats tab.** Structured work/break cycles, Flowmodoro
(break banks at 1 min per 5 focus minutes; a break is claimable once 3 BREAK
minutes are banked — the gate moved off focus minutes after device feedback)
and a classic free timer, with a gentle app-wide banner and two bubbles
rising in the juice fill. The stuck-at-full fill (degenerate-window progress
painted 1) and the stale-session render both fixed; the Goals percentage
now reaches 100%.

## App

**Keep Screen On.** Settings → Reading → "Keep Screen On", default ON — the
mainstream readers hold the screen awake too. A registry
(`ScreenAwake.acquire/release`, pure policy + tests in SpeechLogic) holds
the idle timer across all four reading surfaces and survives tab switches
and suspension re-asserts; editing a note does not hold (the keyboard
already does).

**BookDrop everywhere, and stable.** Multi-select send sheet from storage,
backups, note swipes and book context menus; receive routing into notes,
books, exported audio and JEX imports; hotspot transfers (the receiver scans
any LAN interface); the LocalSend server's port churn is a serialized state
machine — the port stays 53317 across off/on toggles instead of walking the
range; launches always come up OFF; a 401 raises an "Access code required"
section with prefill from the receive code and a Send-again button.

**Web articles become notes.** Share a URL: Readability extracts the
article; paywalled pages get a Bypass-Paywalls-Clean userscript pass (GM
bridge).

**Joplin, both ways.** JEX exports carry the full Joplin metadata set in the
canonical title-first layout (real-Joplin imports confirmed by the user);
Joplin end-to-end encryption (KeyV1/StringV1, PBKDF2) round-trips through
the notes library.

**Onboarding, refreshed.** Still five pages; the "Start with a note" page
folded into the welcome page and a Pomodoro & Stats page added.

## Engineering notes

- The books-UI round and the BookDrop fixes round were committed together at
  the user's direction (99d6cae); the first CI run caught one compile error
  in the BookDrop state machine (`candidate` out of scope after its
  refactor) — fixed in 6738737, then green end to end.
- README brought to v1.8.0 reality: Kokoro Compact is the ~92 MB
  dynamic-int8 build (the ~177 MB uint8 was replaced by the 80–130 MB ask),
  Soprano is no longer an engine and its credit is gone, epub.js's FreeBSD
  licence is now credited, and the CI/layout sections match the tree.
- Version bumped per the release policy: 1.8.0 stays, build 45 → 46 in all
  three project.yml spots.
