# HANDOVER — BookDrop fixes, 2026-10-26

Round: the iPhone half of the six BookDrop reports. The Linux twin round is
`speechnotes-linux-rust/docs/HANDOVER-bookdrop-2026-10-26.md` — read both
before touching either side; the two ends must agree on the wire.

**2026-10-27 status:** the addendum-2 upload fix (`upload(for:fromFile:)`),
the addendum-1 hygiene (background task, 120 s inactivity bound) and new
byte-progress bars BOTH ways (send sheet: file + percent via a delegated
URLSession task delegate; BookDrop screen: "Receiving" bar fed by a
throttled server body-progress hook) ship in **v1.8.1 build 47** via CI.
Still NOT device-verified — the verify checklist below stands.

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

---

## ADDENDUM — the "stuck on Sending…" transfer (same round, 2026-10-27)

### Diagnosis (confirmed on the wire, both directions)

PC→phone works. Phone→PC reaches "Sending…" and never finishes or fails.
Evidence gathered:

* `ss -tnp | grep 53317` during a stuck transfer: **ESTAB, Recv-Q 0** and
  the receiver's session temp dir held **0 bytes** across repeated 8 s
  samples → the desktop had drained everything received and was waiting for
  bytes that never came. The phone's body write froze right after prepare.
* The receiver itself passes the same flow from a local client in
  0.04 s (5 MB), imports a real 1.1 GB `Ulysses.m4b` in 7.2 s and answers
  200 — including the mp4 parse + ffmpeg cover that runs **before** the
  upload's 200. So the receiver is NOT the bottleneck.
* WARP's policy routing is irrelevant: `ip route get 172.20.10.1 from
  172.20.10.3` leaves straight out `wlo1`.
* The desktop drops the socket after its 30 s per-read timeout; the phone
  never learns this and stays in `.sending` for up to its **1 hour**
  upload request timeout. That hour is the "stuck forever".

### Root cause (iOS half, fixed this round)

A frozen sender. iOS suspends the app mid-transfer when the screen locks or
the app is backgrounded over a hotpot; the socket stays open but nothing
moves. The app had a background grace for TTS playback but **none for a
BookDrop send** — so the transfer froze on the first suspension.

### Fixes (iOS — NOT compiled here, no macOS)

1. `App/Sources/Services/LocalSend/LocalSendSender.swift`:
   * `sendBackgroundTask` — `UIApplication.shared.beginBackgroundTask`
     around the whole `sendFiles` (expiry handler ends it), released in
     `cancelSend()` and after the send completes. Mirrors
     `SpeechPlayer.beginPlaybackGraceIfNeeded`, scoped to the transfer.
   * The upload request's `timeoutInterval` 3600 → **120 s**, plus an
     explicit `.timedOut` branch that reports
     "The transfer stalled — <peer> stopped accepting data. Keep this
     screen open and try again." 120 s is an *inactivity* bound
     (URLSession restarts it on progress), so a slow-but-moving 700 MB
     transfer still completes.
2. No receiving-side iOS change: the phone receiving was already fine.

### OPEN — desktop half (same defect, Linux, partially done)

* `crates/sn-net/src/sender.rs:530` still sets the desktop's own
  *outbound* send read/write timeouts to an hour; the same inactivity
  bound + `.timedOut` reporting should be applied there for symmetry
  (this did NOT cause the phone→PC hang — the Linux sender is not the
  stalled one — but it has the identical blind-wait flaw).
* The receiver already fails a silent upload after its 30 s socket read;
  that is correct and left as is.

### Verification state

* Verified on this machine: full iOS-shaped transfer OK from a local
  client (5 MB → 200 in 0.04 s), real 1.1 GB m4b → 200, real epub → 200,
  PIN fix live on the release build.
* NOT verified: any iOS build (no macOS here), any real phone→PC
  transfer with the screen locked.
* Next test when a device is available: lock the iPhone's screen halfway
  through a large send and confirm the receiver stops waiting and the
  phone reports the stall in ~2 minutes rather than hanging for an hour.

---

## ADDENDUM 2 — the REAL root cause of "stuck on Sending…" (2026-10-27, evening)

The addendum above blamed a suspended sender. **That was wrong.** The user
retested live, screen unlocked, watching the sheet the whole time — and the
wire still showed the freeze. What `ss -tnie` actually captured during a
stuck transfer (desktop 172.20.10.3, phone 172.20.10.1):

* The phone opens the upload TCP connection and then sends **nothing — not
  even the HTTP request head**. `segs_in:2` (handshake only), `lastrcv`
  climbing, both queues 0, and the receiver's session temp dir stays empty.
* The receiver's 20 s head deadline (`read_request_head`) drops each silent
  connection, and the phone immediately opens a fresh one (observed peer
  ports 51891 → 51893 → 51895), silent again, forever. "Sending…" is the
  phone cycling dead, silent connections.

So the upload's body pump never starts. Culprit, in `upload()`:

```swift
let stream = InputStream(url: item.url)!
stream.open()                      // ← opened by hand
request.httpBodyStream = stream    // ← URLSession never pumps it
```

URLSession does not adopt a stream that is already open (async `data(for:)`
with an `httpBodyStream` wedges the same way): no head, no body, an idle
connection. Prepare-upload works because its body is plain `Data` — which
is why a session always exists and the sheet always reaches "Sending…".

### The fix (iOS — still NOT compiled here, no macOS)

`App/Sources/Services/LocalSend/LocalSendSender.swift`, `upload()` only:

* The manual `InputStream` is gone. The upload rides
  `URLSession.shared.upload(for: request, fromFile: item.url)` — the
  supported file-upload path. It sets Content-Length itself, so the
  hand-set header (computed from an attributesOfItem probe that could
  silently read 0) is removed too.
* Kept from addendum 1: `timeoutInterval` 120, the query-string
  session/file/token/pin, the status handling, the `.timedOut` stall
  message, and the background task around `sendFiles`. Those are still
  correct hygiene — a backgrounded sender WOULD freeze mid-transfer —
  they just were not this bug.

### Desktop half, done the same evening (Linux twin round)

`crates/sn-net/src/sender.rs`: outbound read/write timeouts 3600 s → 120 s
(each bounds ONE stalled read/write; a slow-but-moving transfer still
completes) plus a `request_error` helper so a stall reads "the transfer
stalled — the peer stopped answering" instead of the OS's "Resource
temporarily unavailable". Built; sn-net tests 35/35 (use
`cargo test --release -p sn-net --lib` — the full run trips over a rustdoc
libLLVM environment breakage unrelated to code).

### Also seen today (context, not code)

* The official LocalSend desktop app was running and held 53317, so the
  Speechnotes receiver sat on 53318 — the phone then showed two
  near-identical "pop-os" peers. After it was closed and BookDrop
  re-toggled, speechnotes holds 53317 again. First check next time this
  smells like ports: `ss -tlnp | grep 533`.
* The receiver logs nothing per request (only "listener stopped"), and a
  failed upload leaves an empty `/tmp/BookDrop-<uuid>` session dir behind
  (six accumulated). Cheap future work: one debug line per prepare/upload,
  and sweep stale session dirs.

### Confirmed by the byte-level probe (same evening, 18:48–18:53)

A logging receiver (`/tmp/pcprobe.py`, log preserved at
`Docs/pcprobe-log-2026-10-27.txt`) took 53317 while the app's BookDrop was
off, and the phone sent three different files at it — a 3.5 MB PDF, a
5.5 KB note, and a 120 KB note. Every attempt, at byte level:

* register: the full JSON arrives (Speechnotes/46 CFNetwork, iPhone13,4).
* prepare-upload: the full JSON arrives, `pin: "1844"` in BOTH the body
  and the query; the probe answers 200 with tokens every time.
* upload: the connection opens and the phone sends NOTHING — not the head,
  not one byte — for ~29 s, then closes the connection itself (clean EOF
  at our side, not a receiver timeout; the probe would have held 120 s),
  and immediately reconnects to repeat. Five silent connections in a row
  for one send.

The 5.5 KB note hanging identically to the 3.5 MB PDF kills both earlier
alternative theories for good: not size-dependent, not app suspension
(the screen was unlocked and watched throughout). The unpumped
`httpBodyStream` is the only explanation left standing, and the fix above
(`upload(for:fromFile:)`) is aimed exactly at it.

### Verification state

* NOT compiled (no macOS here), NOT device-verified. Next macOS session:
  build, then run the phone→PC transfer that has never once completed —
  while it runs, `ls /tmp/BookDrop-*/` on the desktop should show the
  session dir filling for the first time.
* Until that build reaches the phone, phone→PC from Speechnotes cannot
  work against ANY receiver; the workaround is the official LocalSend iOS
  app sending to the desktop.
