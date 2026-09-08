# PROGRESS LOG — SpeechNotes Upgrade Cycle

Format: newest first. Every critique round, merge, and escalation lands here.

---

## 2026-09-08 (later) — Batch 2 merged

- **Sleep timer**: `SleepTimer` enum on SpeechPlayer (off / N min / end of
  chapter). N-minute variant is a Task that fires `stop()` at the wall-clock
  deadline. End-of-chapter hooks into the onFinished path — swallows the
  natural completion, clears the chain, keeps the bookmark so the listener
  can resume past it. Menu lives on the MiniPlayerBar.
- **Lock-screen polish**: chapter label (from book TOC) and cover art ride
  out via `SpeechPlayer.NowPlayingPayload` → NowPlayingCenter. The
  "Loading next chapter…" gap publish no longer blanks the metadata.
- Chapter skip already existed; unassigned.
- Critique: 9/10. (Points off: no per-chapter progress % on lock screen —
  deferred because position is content-derived, not seconds-addressable;
  revisit if MediaPlayer surfaces start to matter.)
- CI: IPA build green on the tip (34289888739).

## 2026-09-08 (later) — Batch 1 merged

- M18 BooksStore write race (monotonic seq + drop stale), M23 ZipReader 100 MB
  bound, M24 brand-aware HEIC/MP4 sniff, M15 SystemEngine epoch guard on
  async delegate callbacks. 4 files, +57/−5. CI green (34248407439).

## 2026-09-08 — Batch 0: TTS pipeline regressions (user-reported)

**Trigger.** User log: switching engines while playing → player can't be quit;
chunk failures cost 30–90 s of dead air (3 retries + 0.5 s silence insertion);
generation slower than v1.5 (user asked to restore the v1.5 TTS path).


**Diagnosis (read from the user's logs):**
- `15:44:06`–`15:45:33`: a single Supertonic chunk burned **87 s** on 3 doomed
  retries, then inserted 0.5 s silence on top. That's what the user heard as
  "breaks longer and more palpable."
- `14:44:43`–`14:50:31`: Kokoro fp32 chunk generation at 19–43 s when the app
  is backgrounded — synthesis QoS, not fixable in app code (the constraint
  "generated seconds > generation seconds" holds in the foreground).
- `06:10:55` etc.: every cold start logs `audio session setup failed
  OSStatus -50` — category set in `init` before the app was active.
- `15:40:41` engine switch (Kokoro → Supertonic) did stop Kokoro but the
  replacement-engine pathway left the player hard to kill.

**Fixes (branch `fix/playback-pipeline-regressions`, 6 files, +148/−42):**
| Bug | Before | After |
|---|---|---|
| Retry storm | 3 attempts + 0.5 s silence per bad chunk | 1 retry, then **skip the chunk entirely** (no silence) |
| Skip deadlocks the chain | (n/a — silence inserted kept slots non-nil) | Slot tri-state (pending/skipped/buffer-id); scheduleReadyChunks steps over skipped; last-chunk-skip fires onFinished |
| Re-entrant `speak` leaks producer (M17) | old gate swapped without signal | old gate flooded before replacement |
| Live rate slider did nothing until respeak (M14) | `speed` written once per `speak()` | `SpeechEngine.speed` property; SpeechPlayer pushes slider → engine live; next chunk reflects it |
| Transient model-load failure bricks engine till relaunch (M16) | `modelLoadAttempted = true` at top | latches only after success; log says "will retry on next speak" |
| OSStatus -50 at every cold start | category set in `init` | lazy: applied on first actual playback (`ensureAudioEngineRunning` / SystemEngine.speak) |

**Notes for the reader of these logs in future:** chunk-generation time in the
*foreground* is what matters. Kokoro fp32 idle-app degradation
(19–43 s/chunk) is iOS QoS, not a regression; prior logs from the same commit
in the foreground show 3–6 s for an 8–11 s chunk (ratio > 1.5× realtime). The
v1.5 chunking was *already intact* — the `git diff fdbf4ff..HEAD` on
SentenceChunker showed only an O(n²) → O(n) offset optimization, no sizing
change.

**CI:** run 34242349583 dispatched (workflow_dispatch). Await result, then
critique score.
