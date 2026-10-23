# HANDOVER — BookDrop network restriction + audible TTS gap

**Date:** 2026-10-23 · **Branch:** `batch-c-d-session` · **HEAD:** `5354ca4` (pushed, CI **green**)
**Scope:** post–BookDrop request (5 items, done + verified) and the two open asks
this session was cut off mid-diagnosis on. **No code for either open ask has been
written** — everything below is analysis + a concrete fix plan.

---

## 0. What is DONE and verified (do not redo)

Items 1–5 of the BookDrop request, all in `f001022` + follow-ups, built green by
run [39874177309](https://github.com/thesagezm/speechnotes-ios/actions/runs/39874177309):

1. **JEX export → BookDrop:** BackupExport now has three destinations on ONE
   build — Share archive (system sheet), Save to Files… (fileExporter, as
   before), Share with BookDrop (hands prebuilt bytes to the send sheet).
   Shared builder: `App/Sources/Services/JexExporter.swift`.
2. **Share from every list:** one APP-LEVEL send sheet (`BookDropSendView`
   presented by `SpeechnotesApp` on `.bookDropSendRequest`); surfaces post a
   `BookDropRequest` (new file, payload + id sets) — Notes list context/swipe,
   Books shelf context menu.
3. **Storage books sublist:** `StorageSettingsView` "Books library" row is a
   `DisclosureGroup` listing every book + real per-directory size (walked
   off-main in `loadUsage()`), swipe/context → Delete (soft, recycle bin,
   playing-book stop guards identical to the shelf) or BookDrop; alert attached
   to the DisclosureGroup (the Form's body-level alert slot is taken by
   clear-temporary-files — a view carries ONE alert).
4. **Everything selectable:** send sheet payloads = books&audiobooks / notes /
   exported audio / .jex, multi-tick, one LocalSend session
   (`LocalSendSender.send(files:)` already batched). Receive router
   (SpeechnotesApp): `.jex`→notes, `.md/.txt/.markdown`→new note (NOT the
   Books importer), `.wav`→`Documents/Exports` (Storage lists it at once),
   rest→books. Receive allowlist gained `wav,md,markdown,txt,text`.
5. **Strong controls:** receive-side **access code** (BookDropView →
   `bookDropPin`), enforced 401 at prepare-upload (body `pin` AND `?pin=`
   query) AND re-checked per upload; sender-side SecureField uses a
   deliberately DIFFERENT key (`bookDropSendPin` — a device can require one
   code and send to a peer with another); 401 → "Access code needed or wrong".
   Docs updated: `Docs/BOOKDROP.md` (routing table, send-surface table, PIN
   contract).

**CI fixes along the way (they compile now):** `notes.notes.filter` (store ≠
array — dynamic-memberMember trap, hit twice) and the
`selectableNotePreviewLimit` name. All committed; last dispatch is green.

### Repo/CI facts worth carrying

- **`build.yml` only auto-builds `main` + `sage-upgrades`** (`on.push.branches`).
  `batch-c-d-session` runs are **manual `workflow_dispatch`** — pushes here
  appear as NO run. Add the branch to `on.push.branches` if you want auto-CI
  (concurrency group already cancels-in-progress per branch, so no pile-up).
  Not done — user was asked, no answer yet.
- **Concurrent sessions share this worktree.** The other session left WIP in the
  tree (audiobook chapters, BooksStore/Onboarding, README) and later committed
  items 6/8/9 + a CI fix on top of mine; they even cut an isolation branch
  (`e6cbb53`, green) to prove MY WIP was breaking their build — then my fixes
  landed. **Stage only your own paths; never `git add -A`; never stash/clean.**
- Watcher: `Scripts/watch_ci.sh <short-sha>` (unauth GitHub API — 60 req/h, it
  rate-limits; `gh run list` is the better read path if authenticated).

---

## 1. OPEN — BookDrop demands "same Wi-Fi"; fails on a phone hotspot

**Ask:** "allow it to just require same network — when I create the hotspot with
my phone, the other devices are still available."

### Diagnosis (root cause, verified in code)

`App/Sources/Services/LocalSend/LocalSendSender.swift`:

- `wifiSubnet()` walks `getifaddrs` and **keeps ONLY `ifa_name == "en0"`** —
  iOS's Wi-Fi interface. A hotspot client's default route rides a DIFFERENT
  interface (historically `pdp_ip0`/`rndis0`-style cellular/tether names; exact
  name varies by iOS version — do NOT hardcode one name).
- No en0 IPv4 → `wifiSubnet()` returns nil → `canSend == false` → **the Send
  button is disabled before any scan**, and a forced `scan()` fails with
  "Not connected to Wi-Fi". That's the exact user-visible symptom.
- The RECEIVER never checks this (it just listens), so the block is one-sided:
  the phone holding the hotspot can receive, the client phone can't send.

### Fix plan (small, no protocol change)

1. `wifiSubnet()` → `lanSubnet()`: iterate ALL `ifaddrs`, accept any
   `AF_INET`, non-loopback address (`ifa_name` != `lo*`, first octet != 127),
   prefer `en0`/`en*` when present, else take the route's interface
   (a cellular/hotspot tether gets a real IPv4 + a /24-shaped mask — take the
   /24 from THAT address as before).
2. Errors/copy: "Not connected to Wi-Fi" → "No local network connection".
   UI strings that say "same Wi-Fi" → "same network":
   `BookDropView.swift` (footer + `statusText` "Visible on this Wi-Fi"),
   `BookDropSendView.swift` (footer ×2, "Looking for devices on this Wi-Fi…"),
   the peer-picker footer, `Docs/BOOKDROP.md`, and the plist
   `NSLocalNetworkUsageDescription` in `project.yml` (xcodegen regenerates the
   plist in CI — commit project.yml, never the generated Info.plist).
3. Doc comments in the sender ("off Wi-Fi there is nothing to find") — update
   so the next reader doesn't reintroduce en0.
4. No protocol change needed: /24 unicast scan + HTTP `/register` works the
   same on any IPv4 LAN; hotspot clients can reach the group leader's address
   space the same way.

**Estimate:** one function + ~8 strings. Highest-confidence, lowest-risk of the
two open items — do this first.

---

## 2. OPEN — audible gap at TTS session starts (the one that got cut off)

**Ask:** "the gap is still audible in tts what can be done?"

### What the log actually shows (evidence from the 02:0x–02:20 sessions)

Every session, both engines, thermal **critical**:

| session | chunk 0 | chunk 0 audio | T2B (2nd buffer @ ms after 1st) | verdict in log |
|---|---|---|---|---|
| Supertonic 44 ch | 15 chars | 2.01 s | 8 474 | **−4 069 ms SHORT** |
| Supertonic 66 ch | 20 chars | 2.10 s | 8 513 | **−4 523 ms SHORT** |
| Supertonic 752 ch | 54 chars | 7.64 s | 13 214 | **−1 462 ms SHORT** |
| Supertonic 822 ch | 54 chars | 7.64 s | 12 589 | **−1 381 ms SHORT** |
| Kokoro 1029 ch | 54 chars | 3.30 s | 7 359 | −1 155 ms SHORT |
| Kokoro 177 ch | 69 chars | 4.10 s | 14 563 | **−8 178 ms SHORT** |
| Kokoro 949 ch | 54 chars | 3.30 s | 25 198 | **−14 111 ms SHORT** |
| *earlier 19:24 session* | 98 chars | 7.77 s | 12 276 | −80 ms SHORT |

Plus the signature round 7 wired but that keeps firing:
`chunk schedule — second buffer was LATE, next opener 125/150/175 chars` — then
the NEXT session's `chunk 0 is 15/20/54 chars` shows the schedule STARTED OVER.

### Root causes (three, all confirmed in code)

**RC-A — the ladder resets to the bottom on any on-time session
(`ChunkSchedule.record`).** One session whose second buffer happened to be
covered snaps `size` back to `first` (100 chars). Sessions alternate cover/miss
(12 276 late → next rung → covered → reset → 8 474 late at 15 chars…), so the
device oscillates at the BOTTOM of the ladder forever. The log's repeated
"next opener 125" right before 15-char chunk 0s is this, verbatim.

**RC-B — a CHARACTER rung is the wrong unit.** The failure condition is
`chunk-0 AUDIO seconds > T2B`. Audio seconds depend on text, RTF and rate:
at thermal-critical RTF ≈ 6.4 (19:26 session), 9 chars → 1.53 s of audio, so
NO character rung in [100…200] (≈10–20 s of speech normally) can cover a 6–14 s
T2B — yet 54 chars DID cover at RTF 0.41 a minute earlier. The rung cannot see
RTF; a seconds target can.

**RC-C — chunk 0 renders ALONE (cold), chunks 1+ render warm.** Look at
02:06: chunk 0 = 0.91 s for 15 chars (RTF 0.46), chunk 2 = 6.81 s for 13.61 s
(RTF 0.50) — same rate, warm. TTFA carries model-ready (0.69–0.76 s of it) and
the first-render warm-up; chunk 1's T2B therefore includes BOTH chunks'
generation start-to-finish from the listener's clock: ~T2B ≈ chunk1_gen + chunk0
pipeline overhead. Growth that doesn't assume a ×2–×3 first-render premium
under-shoots.

Also visible (secondary, worth logging but NOT this fix): `setCategory(…)
failed Code=-50` on every session start → falls back to plain Playback (no
SpokenAudio/Bluetooth path); `bank hold extended — main thread stalled` events;
`HangWatchdog: main thread blocked ~4.5s` during shelf backfill.

### The fix plan (redesign, was MID-IMPLEMENTATION — nothing written)

Replace the rung ladder with a **seconds-based target + opener completion**:

1. **`ChunkSchedule.State` → seconds.** `targetSeconds` (start 3.0, cap 30.0,
   floor 3.0), `record(secondBufferWasLate:chunk0AudioSeconds:t2bSeconds:rate:)`:
   - late → `target = max(target × 2, measuredT2B × 1.2)` capped at 30
     (growth is ×2 because gaps span 0.08 s → 14 s; +25 %/session needs ~10
     sessions to cross that, doubling needs 4–7);
   - covered with ≥ +2.0 s slack → probe DOWN (×0.5, floor 3.0) — the
     "shrinkSlack" prevents oscillation;
   - covered tight → stay (no more reset-to-bottom);
   - `nil` late (single-chunk/early stop): compare `chunk0AudioSeconds`
     against the remembered `lastT2B` — cover → stay, else grow (today `nil`
     "teaches nothing" and the schedule sits at `first` after any on-time
     session).
   - **Both directions taught**: keep-on-success (fixes RC-A), grow-to-cover
     (fixes RC-B by measuring on the real axis).
2. **Budget → chars at speak time:** `budget = ceil0.5(targetSeconds × 15 /
   rate)` chars (15 chars/audio-second calibrated on the shipped logs:
   157→13.6 s, 192→17.1 s, 198→25.1 s), clamped to the engine ceiling
   (Supertonic 200 / Kokoro 160 — unchanged constants).
3. **`SentenceChunker` opener completion — THE missing piece:** today
   `firstChunk(in:maxChars:)` stops at the FIRST sentence ≤ cap, so a rung
   above the first sentence's length does nothing (54-char opener = one
   sentence ≈ 7.6 s — a budget of 600 chars would still emit 54). Add a new
   parameter `minOpenerChars` (opt-in, DEFAULT OFF — the doc contract
   `firstMaxChars = cap` and ~15 pinned tests must not move):
   after `firstChunk`, walk the piece list (the existing
   `sentencePieces(in:)` machinery) and APPEND whole pieces while
   `≤ max(firstMaxChars, minOpenerChars)` and `≤ batchMaxChars`. Production
   call sites (`StreamingTTSPlaybackCore.speak` + `renderWAV`,
   `SystemEngine` line ~342) pass both values. Without this the seconds
   schedule is a no-op on texts whose first sentence is short — exactly the
   sessions in the log.
4. **`PlaybackMetrics`** already holds everything needed — expose
   `firstScheduledAudioSeconds` and the T2B delay (`seconds(from: firstAudioAt,
   to: secondBufferAt)`, guard `secondBufferAt != nil`) as `private(set)`
   internal reads; `StreamingTTSPlaybackCore.reportToSchedule()` then calls
   `schedule.record(secondBufferWasLate: metrics.secondBufferWasLate,
   chunk0AudioSeconds: …, t2bSeconds: …, rate: Double(speed))` and logs
   `"\(logPrefix) chunk schedule — \(schedule.summary)"`.
5. **Docs/tests:** rewrite `ChunkScheduleTests` (the ladder tests pin the exact
   API being replaced — `sizes/first/largest/record(Bool)/clamped(to:)`); add
   opener-completion cases to `SentenceChunkerTests` with
   `minOpenerChars` (completion packs; never exceeds batch; reconstructs;
   default-off preserves every existing assertion). `TTS_BASELINE.md` §B3 and
   `TTS_REGRESSION_AUDIT` R16 wording describes the old ladder — update prose,
   not those audits' history.
6. **What this CANNOT fix:** a gap bounded only by "engine too slow under
   thermal critical" (RTF 6.4 — nothing is fast enough; the honest answer stays
   the top of the range, as the ladder's top rung was). If gaps persist AFTER
   this lands, the next lever is pre-warming the model render BEFORE
   `firstAudioAt` (kill RC-C's warm-up premium in TTFA/T2B), not more chars.

**Expected effect on the logged sessions:** 02:17's −1 462 ms (54 chars/7.64 s
vs T2B 13.2 s) → target grows to ≈16 s ≈ 600 chars → opener completes to ~6
sentences ≈ 16 s of audio ≥ T2B → gap gone; subsequent covered sessions hold
the target (no reset) and only shrink when slack > 2 s.

**Where each piece goes (file map):**
`Packages/SpeechLogic/Sources/SpeechLogic/ChunkSchedule.swift` (rewrite),
`…/SentenceChunker.swift` (`minOpenerChars`),
`App/Sources/Engine/PlaybackMetrics.swift` (two read accessors),
`App/Sources/Engine/StreamingTTSPlaybackCore.swift` (budget at line ~77
`currentOpenerSize`, `reportToSchedule` ~1139, both `SentenceChunker.chunks`
calls ~798/~1238, `SystemEngine` ~342),
`App/Sources/Engine/{Supertonic,OnnxKokoro}Engine.swift` (comment wording only —
ladder prose at Supertonic ~126–134, Kokoro ~117–127),
tests: `ChunkScheduleTests.swift` (rewrite), `SentenceChunkerTests.swift` (add).

---

## 3. Next-session checklist (in order)

1. [ ] **Hotspot/network fix** (§1): `lanSubnet()` + copy sweep + project.yml
   plist string. Commit → dispatch `workflow_dispatch` (branch not in push
   triggers — see §0) → green → tell user to retest hotspot-to-hotspot.
2. [ ] **TTS gap** (§2): ChunkSchedule seconds rewrite → metrics accessors →
   chunker `minOpenerChars` (default-off) → core wiring → tests → dispatch CI →
   device check: the three signature lines to grep in the next log are
   `chunk 0 is … chars`, `T2B … SHORT`, `chunk schedule — …`.
3. [ ] Answer still pending from user: add `batch-c-d-session` to
   `build.yml on.push.branches`? (I recommended yes — concurrency already
   prevents pile-up.)
4. [ ] Carry-over: `setCategory -50` (no Bluetooth route) and the ~4.5 s
   HangWatchdog shelf-backfill block are SEPARATE bugs seen in the same log —
   not started, not analyzed beyond the log lines.

**CI state at handover:** `5354ca4` green (run 39874177309). Tree clean apart
from other sessions' uncommitted WIP — leave it alone.
