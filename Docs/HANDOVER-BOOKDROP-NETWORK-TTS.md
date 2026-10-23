# HANDOVER — BookDrop hotspot fix + TTS seconds-based chunk schedule

**Date:** 2026-10-23 · **Branch:** `batch-c-d-session` · **HEAD:** `e680114`
(pushed, CI **green** — run
[39939815899](https://github.com/thesagezm/speechnotes-ios/actions/runs/39939815899))
**Scope:** both open asks from `HANDOVER-BOOKDROP-NETWORK-TTS.md` are now
IMPLEMENTED and CI-verified. **No device round yet** — that is the next
session's job.

---

## 0. What landed

Two commits:

| commit | what |
|---|---|
| `afdc1d1` | BookDrop: scan any LAN interface + TTS: seconds-based chunk schedule |
| `e680114` | CI round 1 fixes: opener-completion cap + per-engine schedule seeds |

Both pushed to `origin/batch-c-d-session`.

---

## 1. BookDrop — the hotspot fix (DONE, needs a device check)

### The bug

`LocalSendSender.wifiSubnet()` kept ONLY `ifa_name == "en0"` (Wi-Fi). A phone
that CREATES a hotspot has **no `en0` IPv4 at all** (iOS turns the Wi-Fi radio
into the soft AP), so `canSend` was false → the **Send button was disabled
before any scan**, and a forced `scan()` failed with "Not connected to Wi-Fi".
The receiver never checked this, which is why the hotspot HOST could receive
while the client could not send.

### The fix

`LocalSendSender.swift` — `wifiSubnet()` is gone; `lanSubnets()` replaces it:

- walks **every** `getifaddrs` interface, keeps all IPv4 addresses;
- drops loopback (127/8) and link-local (169.254/16);
- ranks `en0` (100) > `en*` (90) > `ap*` (80, the soft AP) > `bridge*` (70) >
  `rndis*` (60, USB tether); `utun*` / `ipsec*` / `awdl*` / `llw*` score 0
  (VPN tunnels and AirDrop radios are not peer networks);
- **cellular (`pdp_ip*`) is a last resort** — used only when a hotspot
  interface is present AND nothing else has been found. A carrier /24 is
  nobody's peer set;
- a `172.20.10.x` address (iOS's own hotspot LAN) gets +50, so the hotspot
  range outranks an ordinary home LAN;
- **up to three subnets are probed per scan** (Wi-Fi AND a running hotspot
  are both real peer sets), and `probeSubnet` became `probeSubnets`.

Copy sweep: "same Wi-Fi" → "same network" in `BookDropView` (footer +
`statusText` "Visible on this network"), `BookDropSendView` (doc comment,
section footer, "Looking for devices on this network…", peer-picker footer —
which now says "the same Wi-Fi, **or one phone's hotspot**"),
`BackupExportView`, and `project.yml`'s `NSLocalNetworkUsageDescription`.
`Docs/BOOKDROP.md` gained a "Which subnet the SENDER scans" section.

**The protocol did not change.** A /24 unicast scan plus an HTTP `/register`
works the same on any IPv4 LAN.

### Device check to run

1. Phone A creates a hotspot; phone B joins it.
2. B → Settings → BookDrop → "Send to a device" → the button must be
   ENABLED (this was the disabled state).
3. A must have Nearby BookDrop ON; B should find A in the picker.
4. Also re-test plain Wi-Fi — the ranking changed, so the peer list must
   still populate.

### Known limits (state them if asked)

- A peer on a DIFFERENT subnet (two phones on two different hotspots, or a
  client with a static IP outside the /24) is still not found — discovery
  is a /24 scan, unchanged.
- VPN on either device breaks the peer set: the tunnel's `utun*` interface
  is skipped and the LAN address may be unreachable through the tunnel.
  That is a known LocalSend-class limitation, not a regression.

---

## 2. TTS — the audible gap at session start (DONE, needs a device check)

### What was wrong

The chunk schedule counted **CHARACTERS** (`100→125→150→175→200`). The
device log shows two reasons that cannot work:

1. **A character count cannot see the speech rate.** The same 54 characters
   were 7.64 s of audio in one session and 3.30 s in another — a size that
   covered one session was far too short for the next.
2. **The ladder reset to the bottom on every covered session.** One lucky
   session snapped the opener back to 100 chars, the next session was short
   again, and the device oscillated at the bottom rung forever.

A third defect made the schedule a no-op on many texts: `firstChunk` stops
at the FIRST sentence that fits the cap, so a 54-char opener stayed 54 chars
no matter how big the budget was.

### What it is now

`ChunkSchedule` holds an **AUDIO-SECONDS target**:

- seeds: Kokoro **8 s**, Supertonic **10 s** (the measured waits in the log);
  band 3–30 s;
- a **late** second buffer grows the target to `max(target × 2, wait × 1.2)`;
- a **covered** session **HOLDS** the target (this is the fix for the
  oscillation);
- a **comfortable** cover (≥ 2 s slack) settles the target just above the
  wait it must cover — never below it;
- a session with **no** second buffer grows only if the opener was shorter
  than a remembered wait; otherwise it teaches nothing and the target holds;
- the target becomes a **character budget** at speak time from the engine's
  own **measured** chars-per-audio-second (learned from the opener itself).
  Per-engine fallbacks until the first measurement: Kokoro 16, Supertonic 10
  (device log: 54 chars → 3.30 s / 7.64 s).

`SentenceChunker.chunks` gained **`minOpenerChars`** (default **0** = off,
so the existing contract and every pinned test are unchanged): the opener
grows by **WHOLE following sentences** up to the budget, never by a cut.
`minOpenerChars` IS the opener's total size; `firstMaxChars` only bounds the
first sentence. Production call sites opt in: both ONNX engines (via
`currentOpenerSize`) and `SystemEngine` (120).

`PlaybackMetrics` gained three internal reads: `firstScheduledAudio`,
`firstScheduledCharacterCount`, `secondBufferDelay` (the inter-buffer wait —
the quantity the opener's audio must cover).

### The new log line

```
<engine> chunk schedule — second buffer was LATE, target 16.00s of opener
audio, 16.36 chars/audio-s, next opener 160 chars
```

### Device check to run

Three signatures to grep in the next log:

1. `chunk 0 is N chars` — should now be ~100–160, not 15–54;
2. `T2B … SHORT` — should stop appearing;
3. `chunk schedule — …` — the target should GROW on a late session and HOLD
   on a covered one.

**What this cannot fix:** a gap bounded only by "the engine is too slow under
thermal critical" (RTF 6.4 — nothing is fast enough). If gaps persist after
this lands, the next lever is **pre-warming the render before `firstAudioAt`**
(killing the cold-first-render premium), not more characters.

---

## 2b. Background persistence — the never-run-dry silence bridge (commit 241888e)

User report 2026-10-23: "supertonic was doing fine but now it cuts after some
time; kokoro has never managed to [persist in background]; make every engine —
supertonic, kokoro, audiobook — persist like the apple system voice does."

### What was wrong (the mechanism, from this repo's own device logs)

Both Kokoro deaths in the 2026-10-06 log landed **15–25 s after backgrounding —
exactly when the already-scheduled audio ran out**, while the deep-banked
Supertonic session survived. A drained `AVAudioPlayerNode` takes the process's
audio I/O idle with it; a session with no live I/O loses the
`UIBackgroundModes: audio` assertion no matter how deep the render-ahead bank
target is. Session activation (Batch F), the 45 s background bank boost
(8dc6104) and the 10 s heal timer all reduce how OFTEN the queue runs dry —
none of them survive it actually running dry, because by then synthesis
(thermal-throttled in the background, RTF > 1) cannot refill before iOS
suspends the process. That is why Supertonic "cuts after some time" (it
survives exactly as long as its bank) and Kokoro "never managed to".

### What landed

**`StreamingTTSPlaybackCore` (covers Supertonic AND Kokoro):**
- **Silence bridge.** When the last queued real buffer completes and the next
  chunk is still rendering, 0.5 s silent buffers are scheduled on the player
  node, re-armed from their own completions until real audio is scheduled
  again. The render chain never idles → the audio I/O never goes quiet → the
  process keeps its background assertion → **speech resumes** when the
  producer catches up, instead of dying mid-book. The listener hears the same
  silence they would have heard anyway.
- Read-along: bridge markers carry the last real end-char, so the highlight
  freezes at the sentence boundary through bridged silence. Bank ledger:
  bridge frames are mirrored into `generatedFrames` at completion so `banked`
  stays a measure of real unplayed audio.
- **`.generating` while backgrounded** now has I/O: the background-transition
  handler arms the bridge at the lock instant (tap-play-then-lock), and the
  10 s health tick covers `.generating` entries that happen while ALREADY
  backgrounded (chapter advance under the lock screen fires no transition
  event).
- New log lines: `keepalive bridge — node queue ran dry at chunk N of M,
  banked X (thermal)` opens an incident (carries the same data the
  `nodeRestarted`/`bankExhausted` GAP events used to — those triggers no
  longer fire because the node no longer stops); `keepalive bridge ended —
  real audio resumed after Xs` closes it. The `backgrounded — state …` line
  now ends with `bridge armed|off`.

**`BookPlaybackController` (the book/audiobook chain):**
- The chapter-gap grace used to end AT `togglePlay` — which only OPENS the
  vulnerable window (state goes `.generating`; the engine starts on first
  schedule). It now ends when `player.state == .speaking` (polled ≤ 25 s).
- The grace chains up to 3 bounded ~30 s tasks on expiry while the book is
  still mid-transition (uncached epub parse, PDF Vision OCR, throttled first
  render) instead of dropping the book at the first expiry. Logged as
  `chapter-gap grace expired mid-transition — chaining task N of 3`.

Untouched on purpose: **SystemEngine** (persists per the user's own report),
**AudioBookPlayer/AVPlayer M4B** (AVPlayer manages its own session), and
**OpusAudioBackend** (decode-bound, queue kept fed by `pump`; if background
deaths are ever reported on `.opus` books, the bridge pattern ports to it).

### Device check to run (the user's three cases)

1. **Supertonic, backgrounded mid-note:** lock the screen mid-session, wait
   past the point where it used to cut. Expect: either uninterrupted speech,
   or `keepalive bridge` lines followed by `keepalive bridge ended — real
   audio resumed` (speech comes back after the bridged silence). NOT
   acceptable: a cut with no resume and a `foreground reconcile — state …
   no live session` line on return.
2. **Kokoro, backgrounded:** same. Kokoro may bridge OFTEN (its RTF is the
   worst) — persistence is the fix's promise, gaplessness is not.
3. **Book/audiobook chain:** play a book, lock the screen, let it cross ≥ 2
   chapter boundaries. Expect `chapter-gap grace expired mid-transition`
   lines only when text extraction was cold; the next chapter starts
   sounding either way.

---

## 3. CI facts (unchanged, still true)

- `build.yml` auto-builds `main` + `sage-upgrades` ONLY. This branch needs
  `gh workflow run build.yml --ref batch-c-d-session`. The concurrency group
  cancels in-progress runs per branch, so dispatching per push is safe.
- **No local Swift toolchain here** — app-target edits can only be verified
  through GitHub Actions. Pre-check syntax with a brace/paren balance scan.
- **Other sessions share this worktree.** Stage only your own paths; never
  `git add -A`; never stash or clean.

---

## 4. Next-session checklist

1. [ ] **Device round for BookDrop** (§1, 4 steps above). If the Send button
       is still disabled on a hotspot client, the log to read is
       `canSend`/`lanSubnets` — add a one-line log of the interfaces and
       their scores before guessing again.
2. [ ] **Device round for the TTS gap** (§2). If `T2B SHORT` persists, read
       the `chunk schedule` line first: a target that does NOT grow means
       `reportToSchedule` is not being reached; a target that grows but the
       gap stays means the engine is simply too slow (the pre-warm lever).
3. [ ] **Still unanswered from the user:** add `batch-c-d-session` to
       `build.yml on.push.branches`? (Recommended yes — the concurrency group
       already prevents pile-up.)
4. [ ] **Separate bugs seen in the same log, NOT started:**
       `setCategory(…) failed Code=-50` on every session start (falls back to
       plain Playback, no SpokenAudio/Bluetooth route) and the ~4.5 s
       `HangWatchdog: main thread blocked` during shelf backfill.
