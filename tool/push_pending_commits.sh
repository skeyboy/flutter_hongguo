#!/bin/bash
# Pushes the local commits that are ahead of origin/main one at a time, retrying
# each one. A re-recorded evidence frame is a couple of megabytes of PNG bytes
# and GitHub's front end answers HTTP 408 after roughly 133 seconds, so on a
# link that measures tens of KB/s a single push carrying the whole queue can
# never finish -- while one asking for a single commit only carries that frame.
# Each attempt therefore names the commit: git push origin <sha>:refs/heads/main.
# Run it again after the link recovers; it picks up wherever the last round left.
cd "$(dirname "$0")/.." || exit 1
log=${1:-build/push_pending_commits.log}
mkdir -p "$(dirname "$log")"
last=''; fails=0
for round in $(seq 1 "${ROUNDS:-10}"); do
  git fetch -q origin main 2>>"$log" || true
  target=$(git rev-list --reverse origin/main..HEAD | head -1)
  if [ -z "$target" ]; then
    echo "ALL-PUSHED round=$round" >>"$log"
    break
  fi
  if [ "$target" != "$last" ]; then last=$target; fails=0; fi
  if [ "$fails" -ge "${MAX_FAILS:-9}" ]; then
    echo "STUCK $last after $fails attempts, stopping" >>"$log"
    break
  fi
  for attempt in 1 2 3; do
    t0=$(date +%s)
    if git -c http.postBuffer=524288000 push origin "$target:refs/heads/main" >>"$log" 2>&1; then
      echo "OK $target attempt=$attempt round=$round secs=$(( $(date +%s) - t0 ))" >>"$log"
      break
    fi
    fails=$((fails + 1))
    echo "RETRY $target attempt=$attempt round=$round fails=$fails secs=$(( $(date +%s) - t0 ))" >>"$log"
    sleep 45
  done
  sleep 30
done
echo "LOOP-END head=$(git rev-parse --short HEAD) remote=$(git rev-parse --short origin/main) pending=$(git rev-list --count origin/main..HEAD)" >>"$log"
