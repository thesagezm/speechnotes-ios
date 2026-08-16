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
# Unauthenticated GitHub API — no token needed (repo is public). Rate limit
# is 60 req/h per IP; polls every 45 s by default (POLL=… to override).

set -uo pipefail
REPO="thesagezm/speechnotes-ios"
API="https://api.github.com/repos/$REPO/actions"
POLL="${POLL:-45}"
cd "$(dirname "$0")/.."
TARGET="${1:-$(git rev-parse HEAD)}"

fetch_run() {
  # Prints "id|status|conclusion|url" for the target run, or nothing.
  if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    curl -sf "$API/runs/$TARGET" | python3 -c '
import json,sys
r=json.load(sys.stdin)
print(f"{r[\"id\"]}|{r[\"status\"]}|{r.get(\"conclusion\") or \"\"}|{r[\"html_url\"]}")'
  else
    curl -sf "$API/runs?per_page=30" | TARGET="$TARGET" python3 -c '
import json,sys,os
sha=os.environ["TARGET"].lower()
runs=json.load(sys.stdin).get("workflow_runs",[])
r=next((x for x in runs if x["head_sha"]==sha or x["head_sha"].startswith(sha)),None)
if r: print(f"{r[\"id\"]}|{r[\"status\"]}|{r.get(\"conclusion\") or \"\"}|{r[\"html_url\"]}")'
  fi
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
      echo "[watch_ci] $(date -u +%H:%M:%SZ) run $ID status=$STATUS conclusion=${CONCLUSION:-–} $URL"
      LAST="$LINE"
    fi
    if [[ "$STATUS" == "completed" ]]; then
      echo "[watch_ci] --- jobs ---"
      curl -sf "$API/runs/$ID/jobs" | python3 -c '
import json,sys
for j in json.load(sys.stdin).get("jobs",[]):
    mark={"success":"✅","failure":"❌","cancelled":"⚠️","skipped":"⏭️"}.get(j["conclusion"],"？")
    print(f"  {mark} {j[\"name\"]} [{j.get(\"conclusion\")}]")
    if j.get("conclusion")=="failure":
        for s in j.get("steps",[]):
            if s.get("conclusion")=="failure":
                print(f"       ↳ failed step: {s[\"name\"]}")'
      if [[ "$CONCLUSION" == "success" ]]; then
        echo "[watch_ci] RESULT: SUCCESS"
        exit 0
      elif [[ "$CONCLUSION" == "cancelled" ]]; then
        echo "[watch_ci] RESULT: CANCELLED"
        exit 2
      else
        echo "[watch_ci] RESULT: FAILURE — fetch annotations/logs (see SPEECHNOTES-IOS-PLAN.md working loop)"
        exit 1
      fi
    fi
  fi
  sleep "$POLL"
done
