# Setup & the build-install loop

One-time setup, then the repeat loop we use for every change.

## One-time setup

### Step 1 — connect this PC to GitHub

Your PC has git but no stored GitHub credentials yet. Pick ONE path:

**Path A — GitHub CLI (recommended, best for our loop):**

```bash
sudo apt install gh
gh auth login
```

When asked: choose **GitHub.com** → **HTTPS** → **Login with a web browser**,
then open the code it shows you at https://github.com/login/device and enter it.
This also configures git credentials automatically.

**Path B — VS Code (you already used it with GitHub):**

Open the `speechnotes-ios` folder in VS Code, go to the Source Control panel,
click **Publish to GitHub** and choose a **public** repo named `speechnotes-ios`.
Skip Step 2 below if you do this.

### Step 2 — create the repo and push (Path A only)

```bash
cd ~/.zcode/workspace/default/speechnotes-ios
gh repo create speechnotes-ios --public --source=. --push
```

## The repeat loop (every iteration)

1. **I change code** in this folder.
2. **You push it:**
   ```bash
   cd ~/.zcode/workspace/default/speechnotes-ios
   git add -A && git commit -m "describe the change" && git push
   ```
3. **Watch the build:** https://github.com/<your-username>/speechnotes-ios/actions
   (first build takes ~5–10 minutes; later ones are faster)
4. **Download the IPA:** open the finished run → scroll to **Artifacts** →
   download `SpeechnotesIOS` → unzip it → inside is `SpeechnotesIOS.ipa`.
   (The download is a zip *containing* the IPA — unzip once.)
5. **Install:** your normal way — import the `.ipa` straight into
   **LiveContainer**. Our IPAs are intentionally unsigned; LiveContainer
   handles signing. This never touches your SideStore certificate slots.
6. **Report back:** screenshot + what happened (or the in-app Logs once
   Phase 4 adds them).

## Troubleshooting

- **Build failed in Actions:** open the run, read the red step's log, paste the
  last ~30 lines to me. `archive.log` is uploaded in the run too.
- **Auth errors on push:** rerun `gh auth login` (Path A) or use VS Code's
  Source Control panel to push (Path B).
- **IPA won't import into LiveContainer:** make sure you unzipped the artifact
  and are importing the `.ipa` file itself, not the artifact zip.
- **App built with "old" SDK note:** we build with whatever Xcode the runner
  has; apps built for iOS 18+ run fine on your iOS 26 phone. Not a problem.
