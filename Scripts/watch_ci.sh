#!/usr/bin/env bash
# Persistent CI watcher — polls a GitHub Actions run until it completes.
# Exit code: 0 = run succeeded, 1 = run failed, 2 = no run found / cancelled.
#
# Usage:
#   Scripts/watch_ci.sh              # watch latest run for local HEAD
#   Scripts/watch_ci.sh <sha>        # watch run for a commit sha (full or short)
#   Scripts/watch_ci.sh <run-id>     # watch a specific run id
#
# Background use (the standard loop while continuing other work):
#   Scripts/watch_ci.sh > /tmp/watch_ci.log 2>&1 &
#   tail -f /tmp/watch_ci.log
#
# Unauthenticated GitHub API (repo is public) — 60 req/h per IP; polls every
# 45 s by default (POLL=… to override). Python heredocs do fetch + parse in
# one process (no curl/pipe/stdin juggling).

set -uo pipefail
export REPO="thesagezm/speechnotes-ios"
POLL="${POLL:-45}"
cd "$(dirname "$0")/.."
TARGET="${1:-$(git rev-parse HEAD)}"

# Prints "id|status|conclusion|url" for the target run, or nothing.
fetch_run() {
  TARGET="$TARGET" python3 - <<'PY'
import json, os, urllib.request

repo = os.environ["REPO"]
target = os.environ["TARGET"]

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "watch-ci"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)

try:
    if target.isdigit():
        r = get(f"https://api.github.com/repos/{repo}/actions/runs/{target}")
    else:
        runs = get(f"https://api.github.com/repos/{repo}/actions/runs?per_page=30").get("workflow_runs", [])
        r = next((x for x in runs if x["head_sha"] == target or x["head_sha"].startswith(target.lower())), None)
    if r:
        print(f"{r['id']}|{r['status']}|{r.get('conclusion') or ''}|{r['html_url']}")
except Exception:
    pass  # transient network/API errors: just poll again next cycle
PY
}

echo "[watch_ci] repo=$REPO target=$TARGET poll=${POLL}s started $(date -u +%H:%M:%SZ)"

LAST=""
while true; do
  LINE="$(fetch_run || true)"
  if [[ -z "$LINE" ]]; then
    echo "[watch_ci] $(date -u +%H:%M:%SZ) no run found yet for $TARGET"
  else
    IFS='|' read -r ID STATUS CONCLUSION URL <<<"$LINE"
    if [[ "$LINE" != "$LAST" ]]; then
      echo "[watch_ci] $(date -u +%H:%M:%SZ) run $ID status=$STATUS conclusion=${CONCLUSION:--} $URL"
      LAST="$LINE"
    fi
    if [[ "$STATUS" == "completed" ]]; then
      echo "[watch_ci] --- jobs ---"
      RUN_ID="$ID" python3 - <<'PY'
import json, os, urllib.request
repo, run_id = os.environ["REPO"], os.environ["RUN_ID"]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/jobs",
    headers={"User-Agent": "watch-ci"})
try:
    jobs = json.load(urllib.request.urlopen(req, timeout=20)).get("jobs", [])
except Exception:
    raise SystemExit
for j in jobs:
    mark = {"success": "OK  ", "failure": "FAIL", "cancelled": "CNCL", "skipped": "SKIP"}.get(j["conclusion"], "?   ")
    print(f"  [{mark}] {j['name']}")
    if j.get("conclusion") == "failure":
        for s in j.get("steps", []):
            if s.get("conclusion") == "failure":
                print(f"          -> failed step: {s['name']}")
PY
      if [[ "$CONCLUSION" == "success" ]]; then
        echo "[watch_ci] RESULT: SUCCESS"
        exit 0
      elif [[ "$CONCLUSION" == "cancelled" ]]; then
        echo "[watch_ci] RESULT: CANCELLED"
        exit 2
      else
        echo "[watch_ci] RESULT: FAILURE — fetch annotations via API (see SPEECHNOTES-IOS-PLAN.md working loop)"
        exit 1
      fi
    fi
  fi
  sleep "$POLL"
done
