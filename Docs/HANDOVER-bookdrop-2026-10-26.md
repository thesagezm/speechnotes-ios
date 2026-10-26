# HANDOVER — BookDrop fixes, 2026-10-26

Round: the iPhone half of the six BookDrop reports. The Linux twin round is
`speechnotes-linux-rust/docs/HANDOVER-bookdrop-2026-10-26.md` — read both
before touching either side; the two ends must agree on the wire.

## State — READ FIRST

- **The iOS changes are NOT compiled.** This machine is Linux; there is no
  Xcode here. Every edit below is surgical and mirrors existing patterns in
  the same files, but the next macOS session must run the build + test
  suite (`project.yml` → xcodegen → Xcode, Tests/ in the repo root) before
  this is trusted. Treat "compiles" as unverified.
- No device verification either: the port-stability and launch-off
  behaviours need a real iPhone.
- The Linux side is built and its tests pass (35/35 sn-net, 109/110 sn-ui
  with one pre-existing imgcache failure).

## What changed, file by file

1. **`App/Sources/Services/LocalSend/LocalSendHTTPServer.swift` — the port
   churn, rewritten (report #1: "it reached 5…27 on the iPhone and then
   became unavailable after turning nearby bookdrop on and off").**

   Root cause: `stop()` cancelled the listener asynchronously and `start()`
   immediately re-bound — a cancelled `NWListener` holds its port for a
   moment, so the new bind was refused on 53317, fell to 53318, and one
   toggle at a time walked the whole range until
   "Ports 53317–53327 are all in use" = the "unavailable" state. Two
   overlapping starts also leaked concurrent listeners (several ports open
   at once).

   The lifecycle is now a serialized state machine on the server queue:
   - `desiredRunning` / `transitioning` / `rangeExhausted`; a start or stop
     that lands mid-transition is honoured when the running transition
     finishes (`finishTransitionLocked` re-checks the desire) — no two
     listeners race, none leak.
   - `teardownLocked` cancels and **waits (bounded 1 s) for `.cancelled`**
     before anything binds again. The listener now runs on its own
     `listenerQueue` precisely so that wait cannot deadlock against the
     callback it waits for.
   - `handleListenerState` has an **identity guard** (`self.listener ===
     listener`): a stale callback from a replaced listener can no longer
     cancel its replacement or restart the stack (the recursive
     `startLocked`-from-`.failed` that made the climb self-sustaining).
   - `preferredPort`: the last successfully bound port is tried FIRST on
     the next start, so the port the user sees stays 53317 across toggles
     instead of creeping.
   - A full-range refusal sets `rangeExhausted`; the next explicit start
     retries, but nothing rebinds on its own (no retry loop).
   - Request handling, the spill-to-disk body accumulator, `verifyAlive`
     and the loopback probe are untouched; `start`/`stop` signatures are
     unchanged, so `LocalSendReceiver` needed no API change.

2. **`App/Sources/Services/LocalSend/LocalSendReceiver.swift`**
   - `desiredOn` guard: the server's `onReady` can arrive after a stop that
     raced the start; without the guard the late callback set
     `isRunning = true` for a listener that was being torn down, and the
     NEXT start was skipped as "already running" while nothing listened —
     the zombie-listener shape Readest hit, reintroduced by the race.
     `start()` sets `desiredOn = true`, `stop()` clears it, and both
     server callbacks check it.
   - **Report #3 — Nearby BookDrop OFF at launch:** `applyPersistedEnabledState()`
     no longer resumes the listener; it resets the `bookDropEnabled`
     default to false. Every launch comes up OFF and the BookDrop screen's
     toggle (same `@AppStorage` key) agrees; the user switches it on when
     they want to receive. Mid-session the toggle works exactly as before,
     and `probeAndHeal` still rebuilds a reclaimed socket while the
     session's toggle is on.

3. **`App/Sources/Services/LocalSend/LocalSendSender.swift` — report #2,
   iPhone side.** New `@Published private(set) var needsAccessCode`, set on
   a 401 from prepare-upload OR upload, cleared in `reset()` and at the top
   of `send()`. The wire format itself was already correct (the code rides
   the body AND `?pin=` when the field is filled).

4. **`App/Sources/Views/BookDropSendView.swift` — the 401 recovery.** The
   sheet sends the moment a peer is tapped, so the access-code field is
   easily still empty even when the user has set the same code everywhere
   (they set it in BookDrop → Receive, which is a DIFFERENT key,
   `bookDropPin` vs this sheet's `bookDropSendPin`). When
   `sender.needsAccessCode` turns on:
   - a new "Access code required" section appears with the field and a
     **Send again** button that resends to the remembered peer;
   - `onChange(of: needsAccessCode)` prefills the field from the receive
     code when the field is empty — the same-code-everywhere user gets a
     one-tap retry; a per-peer code can still be typed over the prefill.
   (The two-keys design comment in the file still holds: nothing writes the
   send key from the receive key except this explicit, user-visible
   recovery.)

5. **`App/Sources/SpeechnotesApp.swift`** — call-site comment only (the
   launch hook no longer "starts the receiver if the toggle was left on").

## Already correct on iOS (report items with no defect found)

- **Report #6** — the iOS send sheet already sources from the app's own
  items (books & audiobooks, notes, exported audio, .jex). The Linux twin
  now matches; nothing to do here.
- **Report #5** — where received items land: the router in
  `SpeechnotesApp.onAppear` sends everything into the app's own stores:
  `.jex` → JexImporter into Notes/notebooks; `.md`/`.txt` → a new note;
  `.wav` → Documents/Exports (Storage lists it); everything else →
  `books.importBook` onto the Books shelf. Nothing asks the user for a
  path. (Same is now true on Linux, including the wav case it lacked.)

## Verify checklist (next macOS + device session)

1. Build + run the test suite; fix any compile nits in the four touched
   Swift files (highest-risk spots: the new state machine's closure
   captures in `LocalSendHTTPServer`, and `onChange(of:)` old-SwiftUI
   signature use in `BookDropSendView` — the file already uses the
   single-parameter form elsewhere, so it matches).
2. On device: toggle Nearby BookDrop off/on five times — Status/Port must
   stay **53317** every time, and after each launch the toggle must read
   OFF (report #1, #3).
3. iPhone → desktop (Speechnotes Linux, code 1844): tap the peer; if the
   sheet shows "Access code required" prefilled with 1844, tap Send again —
   the transfer must complete. First-try sends with the field filled must
   also pass (the Linux receiver's query-pin shadow is fixed in the twin
   round).
4. Desktop → iPhone (Linux round): with iPhone receive ON, the desktop scan
   must find the iPhone in seconds and the received book/note/jex must land
   in the shelf/notes.
