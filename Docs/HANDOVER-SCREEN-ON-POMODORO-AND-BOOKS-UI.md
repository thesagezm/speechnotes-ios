# HANDOVER — 2026-10-26 (round 2): screen-on DONE, pomodoro fixes DONE, books UI NOT STARTED

**Branch `batch-c-d-session`, HEAD `484e564`.** CI dispatched on it
(run 40384002759) — **check it is green before trusting this code**:
`gh run list --workflow build.yml --branch batch-c-d-session --limit 1`.
Version untouched (1.8.0 / build 45) — the user groups features into releases.

Supersedes `Docs/HANDOVER-SCREEN-ON-AND-FINAL.md` (its one open item is now
built; that file remains useful for the release-round history).

---

# 1. DONE this round (commit `484e564`, CI pending at writing)

## 1a. The "Keep Screen On" setting (was THE open item)

**Where:** Settings tab → new **Reading** section → `Toggle("Keep Screen On")`
(`SettingsTabView.swift`). **Default ON** — a screen that dims mid-book loses
the reader's place, and the mainstream readers (Kindle, Apple Books) hold the
screen awake while reading. The user can flip it; if they want OFF as the
default it is one line: `ScreenAwakePolicy.defaultEnabled` (SpeechLogic).

**Scope decision (the one the last handover left open):** the hold applies to
ALL FOUR reading surfaces — EPUB, PDF, audiobook readers, and the note
editor's READING modes (preview / read-along). Editing a note does NOT hold:
the software keyboard already keeps the screen awake, so the setting would
have nothing to add there. The rule lives in
`ScreenAwakePolicy.noteIsReadingSurface` (tested in CI) and the same
predicate also feeds the note editor's `isReadingSurface`.

**Why a registry, not onAppear/onDisappear + a bare flag:**
`UIApplication.shared.isIdleTimerDisabled` is ONE GLOBAL flag, and
`onDisappear` fires on every TAB SWITCH while the view stays alive in its
tab's navigation stack. Two surfaces can be alive at once (a book in the
Books stack, the editor in the Notes stack), SwiftUI does not guarantee the
outgoing disappear lands before the incoming appear, and last-writer-wins
would dim the screen while the user reads. So surfaces REGISTER with
`ScreenAwake.shared.acquire/release` (a `Set<ScreenAwakeSurface>`) and the
flag is recomputed after every change — set semantics make the answer
order-independent. Files:

| File | Role |
|---|---|
| `Packages/SpeechLogic/Sources/SpeechLogic/ScreenAwakePolicy.swift` | key, default, the note-scope rule, the decision — pure, 9 tests |
| `App/Sources/Services/ScreenAwake.swift` | the holder registry + `UIApplication` writes + the `.keepScreenAwake(_:isActive:)` View modifier |
| `App/Sources/Views/{BookReaderView,BookPDFReaderView,BookAudioReaderView,NoteEditorView}.swift` | one `.keepScreenAwake(...)` line each |
| `App/Sources/SpeechnotesApp.swift` | `.active` scenePhase re-asserts the hold (iOS may reset the timer across a suspension) |

**Device checks for this feature:**
- Toggle ON → open a book, hold the phone still: the screen must not dim.
- Leave the reader (pop AND tab switch): the screen must dim again on the
  normal timer — the tab-switch exit is the one the registry exists for.
- Note editor in preview: screen stays on; flip to edit: dims (keyboard up).
- Toggle OFF → everything dims as before.
- Logs (Settings → About → Logs): `ScreenAwake: held on / released — <surfaces>`.

## 1b. Flowmodoro — the claim gate moved to the POT

**User report:** "someone can claim a break once they have 3 minutes of
break banked... not just after 3 minutes of focus... as it stands now."

The old rule unlocked the claim at 3 accrued FOCUS minutes — a 36-second
break nobody would take. Now the gate is on the banked BREAK itself:
`flowCanClaim` / `claimBreak` compare `flowEarnedBreak(now:)` against
`flowClaimThreshold` (180 s of break = 15 focus minutes at 1 min per 5).
`PomodoroEngine.swift` (constant comment tells the story), the three
flowmodoro tests rewritten for the new gate, and the UI copy updated
(mode footer, the "The rule" row — now "Claim at 3 break min", the claim
button comment). The claim banner copy was already rule-agnostic
("`X banked`"), so it needed nothing.

## 1c. Pomodoro juice — bubbles + the two "stuck at full" mechanisms

**User report:** on the last focus block the juice sat FULL while the
countdown ran correctly; a tab refresh brought the fill back. Then: "add
juicy elements, dont overdo the juice keep it simple e.g just a couple of
bubbles".

- **Bubbles:** `JuiceBubbles` (inside `PomodoroRunView`,
  `App/Sources/Views/PomodoroViews.swift`) — two white circles rising
  through the fill on a Canvas, deterministic off the frame clock (no
  animation state to stutter when the card re-renders each second), fading
  in/out via `sin(lap·π)`, hidden while the fill is under ~4%.
- **Stale-session fix:** `PomodoroRunView` now reads the session THROUGH
  the store every tick (`store.session ?? sessionSnapshot`) instead of
  rendering its construction-time snapshot. The TimelineView ticks
  independently of the store's publishes — a missed publish could freeze
  the card on an old phase. (The snapshot is a `let` named
  `sessionSnapshot`, NOT `private` — a private there would make the
  synthesized memberwise init private and `PomodoroCard`'s call site would
  not compile.)
- **Degenerate-window fix:** `phaseProgress` had `guard total > 0 else
  { return 1 }` — the only code path that paints the glass FULL
  unconditionally, i.e. exactly "stuck at 100% while the countdown still
  runs" (the countdown reads `phaseEnd` only, so it survives whatever
  raced the start). It now returns 0: an empty fill beside a live
  countdown reads as a cosmetic glitch; a full one reads as finished,
  which is a lie.

Device check: run a classic session to the LAST block — the fill must
track the countdown; bubbles rise inside the colored fill only; paused
freezes the fill AND the bubbles.

---

# 2. NOT STARTED — the books UI round (the next agent's job, user-ordered)

The user's two remaining items, verbatim, before v1.8 can release. **These
were deliberately NOT started — do not assume any of it exists.**

## 2a. Books readers: transparent behind the minimised bar AND behind the tab bar

> "the notes app allows the space or visual display behind the minimised
> bar to be transparent and display the remaining part of the note, only
> the minimised rail and tabs bar (notes,books,stats and setting) icons
> show... not the solid background that shows behind this in books (both
> landscape and portrait — **keep the lateral visuals for books in
> landscape the way they are**) implement this for ebooks aswell — that
> solid background behind the tabs bar should show the ebook"

What the user wants, restated: in NOTES, the content runs under the
minimised pill and under the tab bar — those float over the text with
translucent material, and the note text is visible behind them. In the
BOOKS readers there is instead a SOLID background behind the minimised
bar and behind the tab bar. Make the books readers behave like notes:

- the reading content extends under the minimised transport and under the
  bottom tab bar (content visible behind them, not a solid slab);
- applies to the EPUB reader, the PDF reader and the audiobook reader,
  in BOTH orientations;
- **DO NOT touch the landscape lateral PlaybackRail visuals** — the user
  explicitly said to keep those as they are;
- the reference behaviour to copy is the note editor's (how
  `NoteEditorView` + `MinimizedBookTransport` layer over the content —
  read those first).

Likely mechanics (verify, don't assume): the readers' background
(`.background(...)` / the webview body color) and safe-area treatment.
The webview/PDF view probably stops at the bottom safe-area inset and
paints a solid color behind the tab bar instead of ignoring the bottom
inset like the editor does. `MinimizedBookTransport` is already a floating
material pill (`.ultraThinMaterial`) — the solid slab behind it is the
READER's background, not the pill.

## 2b. EPUB reader, portrait: hiding the chrome must go ALL the way to the top

> "even at the top there is still a smaller fixed bar at the top... i
> basically want when i tap to hide to show just the book all to the very
> top the way notes does (in portrait mode, landscape already does this in
> books)"

When `immersiveBars.epub` hides the chrome in PORTRAIT, a smaller fixed
bar remains at the top (landscape is already correct). The webview must
extend under the status bar / top safe-area inset when the chrome is
hidden — the way the note editor does. The tap-to-hide plumbing already
exists: the EPUB toggle arrives through `reader.js`'s `chromeTap` bridge
(links/selections are skipped) and `immersiveBars.epub` stores the state —
this is a LAYOUT fix (top inset / toolbar), not a gesture fix. Check
`.toolbar(.hidden, for: .navigationBar)` vs whatever still reserves the
top inset, and whether the webview's frame ignores the top safe area when
`chromeHidden`.

## Device feedback from this round (for whichever agent owns TTS)

> "btw the fomulas are working well, the tts on current page not yet working"

Maths rendering + spoken words: WORKING on device (closed). The TTS items
2/3/4 (TOC chapter/page jump, bookmark deletion on play/stop cycling,
start-reading-from-current-page) belong to the OTHER agent working in this
tree — coordinate before touching `SpeechPlayer`/`BookPlaybackController`.

---

# 3. Working notes for the next agent

- **Concurrent sessions are live in this tree.** Another agent works the
  TTS items and had uncommitted WIP in `App/Sources/Services/LocalSend/*`,
  `BookDropSendView.swift` and a comment hunk in `SpeechnotesApp.swift`
  while this round committed. **Stage by explicit path** — this round's
  commit swept only its own files and used `git apply --cached` to take a
  single hunk out of `SpeechnotesApp.swift`. Check `git status` before and
  after your commits; `git add -A` takes their half-finished work.
- **No local Swift toolchain.** Verify through GitHub Actions only:
  `gh workflow run build.yml --ref batch-c-d-session` then
  `Scripts/watch_ci.sh <sha>`. `build.yml` does NOT auto-run on this
  branch — dispatch manually. `logic-tests` is the fast signal.
- **Version policy: do NOT bump `MARKETING_VERSION`.** It stays 1.8.0;
  `CURRENT_PROJECT_VERSION` moves only when the user cuts the release.
- **Declaration-order trap** (bit the last round): adding a parameter to a
  SwiftUI view's memberwise init means call sites pass arguments in
  DECLARATION order — the error names both arguments; read it and swap.
  Same for access levels: a `private let` on a struct makes the synthesized
  memberwise init private, and same-file call sites in other types stop
  compiling (hit this round with `PomodoroRunView.sessionSnapshot`).
- The release gate for v1.8: the books UI round (2a + 2b) + the TTS
  items + the user's device round. **No tag, no GitHub Release, no main
  merge without the user's explicit go.**
