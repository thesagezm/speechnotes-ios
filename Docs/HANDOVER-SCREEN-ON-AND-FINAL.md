# HANDOVER — 2026-10-26: screen-on setting (NOT STARTED) + final state of the release round

**Branch `batch-c-d-session`, HEAD `4ad3cb3`.**
**The screen-on setting is NOT IMPLEMENTED — it is the next agent's first job.**
Everything else in this file is DONE and (for the maths/books round) CI-verified.

---

# 1. THE OPEN ITEM: a setting to keep the screen on

## What the user asked for

> "also add a setting to keep screen on or allow it to go off and start handing
> over right now... the remaining things another agent will continue"

So: a user-facing setting that decides whether the screen stays awake, and
whether it is on or off by default.

## What was checked before handing over

- **There is NO existing screen-on handling anywhere in the app.** A grep for
  `isIdleTimerDisabled`, `idleTimer`, `keepScreen` and `screenOn` across
  `App/Sources/` returns nothing. So this is a greenfield feature, not a
  bug fix — nothing to correct, only something to add.
- **iOS 18.0 deployment target** (`project.yml`), so the modern API is
  available:
  ```swift
  UIApplication.shared.isIdleTimerDisabled = true
  ```
  (The older `UIApplication.shared.isIdleTimerDisabled` on the app object is
  the same property; there is no scene-level variant to prefer here.)
- **Settings live in `App/Sources/Views/SettingsView.swift`** (306 lines, six
  `Section`s) with sub-screens in `SpeechSettingsView`, `AppearanceSettingsView`,
  `StorageSettingsView`, `EncryptionSettingsView`. A reading-time toggle
  belongs on the main `SettingsView` — it is a behaviour of the READING
  surface, not of speech synthesis.

## How it should be built

1. **The preference.** An `@AppStorage` key, e.g.
   `@AppStorage("keepScreenOn") private var keepScreenOn = false`.
   The app uses `@AppStorage` for every user preference (see
   `bookBarMinimized`, `immersiveBars.pdf`, `landscapeRailMinimized`),
   so follow that pattern — do NOT invent a new settings store.

2. **Where it applies.** The screen should stay awake while the user is
   READING — the three book readers:
   - `App/Sources/Views/BookReaderView.swift` (EPUB)
   - `App/Sources/Views/BookPDFReaderView.swift` (PDF)
   - `App/Sources/Views/BookAudioReaderView.swift` (audiobook)

   and probably the notes editor's reading/preview mode
   (`NoteEditorView`). **The decision for the next agent:** whether the
   toggle applies only to the book readers or also to the note editor's
   preview. The user's phrasing ("keep screen on or allow it to go off")
   is about reading generally, so both are defensible — but it must be ONE
   decision, applied consistently, not a toggle that silently does nothing
   on some surfaces.

3. **How to apply it.** The property is global (it is the app's idle timer),
   so it must be set on appear and RESTORED on disappear — otherwise
   leaving the reader leaves the screen pinned on forever:
   ```swift
   .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
   .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
   ```
   `onDisappear` is the right restore point (the readers already use it —
   see `BookReaderView`'s `onDisappear`, which flushes the position). Note
   that `onDisappear` fires on a TAB SWITCH as well as a dismissal (there is
   a comment about exactly this in `BookReaderView`), so if two surfaces
   could both be alive, a shared reference count would be more correct than
   a bare boolean. **The next agent should decide whether that matters**
   (in this app only one reader is presented at a time, so the simple
   boolean is probably right — but it is worth a thought).

4. **The setting's own surface.** A `Toggle("Keep Screen On", isOn: …)` in
   `SettingsView`. Match the surrounding style exactly — read the file
   before editing.

5. **Verification.** There is NO local Swift toolchain, so it is verified by
   CI (`gh workflow run build.yml --ref batch-c-d-session`) plus a device
   check. The device check is the real test: with the toggle ON, the screen
   must not dim while reading; with it OFF, the screen must dim on the
   normal timer; and the screen must NOT stay on after leaving the reader.

---

# 2. THE FINAL STATE OF EVERYTHING ELSE

## CI-verified green (as of `5e1f510`, and re-run for `49a34ea`)

| Job | Result |
|---|---|
| Logic tests (version fields + SpeechLogic) | success — **488 tests, 0 failures** |
| Build unsigned IPA | success |
| EPUB spike | success |
| PDF spike | success |
| Kokoro small spike | success (informative) |
| Supertonic spike | success (informative) |

The maths + books round (`e1b290a`) and the docs round (`5e1f510`) are both
fully green. The two bug fixes (`49a34ea`) needed one CI round: Swift
requires call-site arguments in DECLARATION ORDER, and `isSpeaking` was
passed before `sessionActive` in both book readers —
`error: argument 'sessionActive' must precede argument 'isSpeaking'`.
Fixed in `4ad3cb3`; **check the run for `4ad3cb3` before assuming the
fixes compile** — `gh run list --workflow build.yml --branch batch-c-d-session --limit 2`.

## What was fixed in this round (all pushed)

### Maths + TTS (`e1b290a`, `5e1f510`)
- **The one red test is fixed.** `speakList` joined node outputs with no
  separator, so a big operator's separate limit nodes welded together:
  "i" + "=" + "1" → "iequals1" instead of "i equals 1". Every node boundary
  now gets a separator. This fixes the whole class of bug, not just that
  operator.
- **The insert affordance is built** — a formula button in the formatting
  bar plus `/math` and `/mathblock` in the slash menu. Both insert the
  DELIMITED form (the delimiters are what tell the parser the run is a
  formula, so prices keep their own dollar signs) and leave the body
  selected to type over.
- **The export carries the GLYPHS.** A shared PDF or text file is a document
  the recipient READS, so it must not carry the engine's words ("E equals mc
  to the power of 2" where the note says "E = mc^2"). `MarkdownText` gained
  a `displayText(_:)` path; the speech path is untouched.
- A test now covers the percent case the device checklist named ("50% of the
  time must keep its percent sign") — it was never covered.

### Books chapter nav + resume/start (`e1b290a`)
- The EPUB mid-chapter write was a **DEBOUNCE, not a throttle**: every
  relocation cancelled the pending write and started a new one.
  `relocated` fires on every scroll tick, so a reader who kept scrolling
  never reached the write at all — the exact spot was lost precisely when
  the reader was moving through the book. It is now a throttle with a
  trailing write.
- The position is also flushed on `scenePhase == .background` (`onDisappear`
  does not fire when the app is backgrounded, and that is the exit the
  reader makes when they put the phone down).

### The two device reports (`49a34ea`)
- **Landscape play/pause glyph.** The glyph was derived from
  `sessionActive && progress != nil`. Progress is nil until the engine's
  FIRST chunk reports in, so the button could read "play" while the audio
  was already running. The glyph is now a function of the player's SPEAKING
  state alone — the portrait bar's rule.
- **Goals percentage never reached 100%.** The PDF progress was
  `(pageIndex + fraction) / pageCount`, and the fraction is always 0 for a
  PDF (the reader is on a page, not inside one), so the formula could never
  reach 1.0 — on the last page of a 100-page book it said 99%. The page the
  reader is ON counts now: `(pageIndex + 1) / pageCount`. The EPUB side had
  the same shape (epub.js reports the within-chapter fraction as 0 for a
  chapter shorter than one viewport, so the last chapter read as
  unfinished). `StatsTabView` now uses the same `GoalMath.fraction` the
  goals use, so the two views cannot show different numbers for one book.

---

# 3. STILL OPEN — the device round

**CI is green; the device is the only remaining gate.** The user has not
yet tested these on their own books. The checklist:

## Books (the compiled OBGYN notes PDF — the user's own book)
- Open the book; the Contents sheet lists the sections; the bottom next/prev
  chevrons move ONE section at a time (not to the last).
- Jump to a page from Contents; close the book; reopen → lands on that page.
- Read to another page; close; reopen → lands there.
- Tap a Contents row IMMEDIATELY (before the big PDF has finished opening) →
  the jump lands once the document is ready.

## EPUB
- Tap next/prev repeatedly → each press advances one chapter, the bar tracks
  it, and a reopen lands where you stopped.
- Scroll WITHIN a chapter, close the book, reopen → lands at the exact spot,
  not the chapter top.
- Scroll within a chapter and put the phone DOWN (background the app) →
  reopen lands at the exact spot. **This is the item that exercises the
  throttle fix** — scroll continuously for a while, then background the app
  rather than closing the reader.

## Maths
- A note with `$…$`, `$$…$$`, `\beta`, `\sum_{i=1}^{n}`, `\frac{a}{b}` renders
  glyphs, not LaTeX source.
- Prices survive: "it was $5 and $10" is not a formula; "50% of the time"
  keeps its percent sign.
- Press play → the spoken text says "beta", not "backslash beta".
- The formula button and `/math` insert a delimited formula with the body
  selected.

## The two new fixes
- Landscape (books readers): tap play → the glyph becomes a PAUSE; tap again
  → it becomes a PLAY.
- Goals: reach the last page/chapter → the goal says **100%**, not 96/97/98%.

---

# 4. DELIBERATELY NOT DONE (and why)

- **`BookPosition` overloading.** `chapterIndex` means a PAGE index for PDFs
  and a CHAPTER index elsewhere. Every current consumer was audited and is
  correct per format, so this is a latent-shape risk, not a live bug. The
  structural fix (a defaulted `pageIndex: Int?` field) touches the goals and
  stats math and deserves its own pass. **The two bug fixes in this round
  made the PDF-vs-EPUB difference EXPLICIT in `GoalMath` instead**, which is
  the cheaper version of the same idea.
- **PDF/EPUB stepper granularity.** The chevrons walk a coarser list than
  the Contents sheet (PDF: top-level outline nodes vs the full tree; EPUB:
  spine items vs TOC rows). Changing the granularity changes the TTS unit
  boundaries and auto-advance for every book — it must be decided on the
  DEVICE, not from a desk.

---

# 5. Working notes for the next agent

- **Version policy: do NOT bump `MARKETING_VERSION`.** It stays `1.8.0`;
  only `CURRENT_PROJECT_VERSION` moves when the user cuts a release. The
  user groups features into releases. `Scripts/version-check.sh` enforces
  the fields agree.
- **No local Swift toolchain.** Verify through GitHub Actions only:
  ```
  gh workflow run build.yml --ref batch-c-d-session
  Scripts/watch_ci.sh <sha>
  ```
  `build.yml` auto-runs only on `main` / `sage-upgrades`, so a branch push
  starts NOTHING — it must be dispatched manually. `logic-tests` is the fast
  signal (~50 s when SpeechLogic does not compile); `Build unsigned IPA`
  catches app-target errors.
- **Stage by explicit path.** Another session commits on this branch
  concurrently and has swept other agents' edits into its CI-fix commits
  before. `git add -A` would take someone else's half-finished work.
  `Packages/SpeechLogic/Package.resolved` is untracked and belongs to
  another session — leave it.
- **The app target has NO unit-test target.** App-target code is only
  compiled by CI, never unit-tested. Verify app-target maths by
  simulation (as was done for the goals percentage) plus a device check.
- **Swift language mode is 5.0** (`project.yml`), so the strict-concurrency
  diagnostics are not on. `@MainActor` annotations are still worth adding
  where a `Task` touches `@State`.
- **Adding a parameter to a SwiftUI view's memberwise init means every call
  site must pass it in DECLARATION ORDER.** This bit the landscape
  play/pause fix (`isSpeaking` before `sessionActive` → `error: argument
  'sessionActive' must precede argument 'isSpeaking'`). The declaration
  order is the property order in the struct, and the error names both
  arguments — read it and swap them, do not go hunting.
