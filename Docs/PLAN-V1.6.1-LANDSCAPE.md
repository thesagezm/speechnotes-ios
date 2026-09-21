# v1.6.1 — Landscape orientation probe (device-gated)

Status: **CI green; probe IPA built and staged for device test. NOT released,
not tagged.**

## What this build is

One question, asked with the smallest possible artifact: *do the two landscape
`UISupportedInterfaceOrientations` keys still black-screen the app at launch
inside LiveContainer?* That is the exact failure mode of v1.2.0
(`Docs/BUILD-FAILURES-V1.2.md`), traced by byte-level IPA diff, and the reason
rotation has been disabled since.

Commit `cdf61fd` differs from v1.6.0 in exactly two ways:

1. `project.yml` `info.properties.UISupportedInterfaceOrientations` gained
   `UIInterfaceOrientationLandscapeLeft` + `UIInterfaceOrientationLandscapeRight`
   after `UIInterfaceOrientationPortrait` (no upside-down).
2. The four version fields bumped 1.6.0/32 → 1.6.1/33.

**No code changed** — not one Swift file. If the device black-screens, there is
exactly one suspect and it reverts with one commit. (v1.2.0 shipped a code
change in the same build and burned 19 CI runs chasing the wrong theory.)

## Verification done so far

- `Scripts/version-check.sh`: 1.6.1 / 33 OK (all four fields agree).
- CI run 35662428709: **all six jobs green** — logic tests, all four spikes,
  unsigned IPA build.
- Packaged IPA inspected: `Info.plist` carries all three orientations
  (verified from the downloaded artifact, not from the source), reports
  1.6.1/33, and `otool -L` shows only system dependencies (static linking
  intact — the LiveContainer requirement).

Probe IPA staged at `/tmp/SpeechnotesIOS-1.6.1-probe.ipa` (also the
`SpeechnotesIOS` artifact of CI run 35662428709).

## Device test (the gate — user to run)

1. Install the probe IPA in LiveContainer.
2. Cold-launch the app. **The only acceptance criterion for this build: it
   launches. No black screen.**
3. Confirm portrait behaves exactly like v1.6.0 (the layout code is byte-
   identical to v1.6.0 — only the plist key set differs).
4. Optional but useful: rotate the phone in the notes list and the editor and
   note what looks wrong. It WILL look unfinished — every surface still lays
   out as a tall portrait column stretched sideways, and the playback controls
   are still bottom/top bars. That is expected and is what Batch B (v1.6.2)
   replaces with lateral rails. Report anything that is *broken* (clipped
   controls, unreachable buttons, crashes), not merely stretched.

## Decision rule

- **Launches clean** → Batch B (lateral playback rails in landscape) builds on
  top of this commit. Note the result + date here.
- **Black screen at launch** → revert the two orientation lines in one commit,
  keep version 1.6.1/33, landscape goes dormant; the rail code from Batch B is
  still written (it keys off `isLandscape`, which is false when rotation is
  locked) but ships only when a device-tested safe route exists (candidate:
  LiveContainer's per-app Orientation Lock — research needed).

## Result

_(filled in after the device test)_
- Date:
- Launches clean: yes / no
- Notes:
