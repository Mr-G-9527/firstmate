#!/usr/bin/env bash
# fm-watch-supervisor - keepalive for the firstmate watcher (captain-side fix,
# friction #16, 2026-08-18).
#
# WHY: fm-watch.sh exits after every actionable wake by design; re-arm normally
# happens via the primary Claude Stop hook (fm-claude-stop-autoarm.sh). GAP: if
# the primary is IDLE when the wake lands (no turn ends -> no Stop hook), nobody
# re-arms the watcher. Observed 2026-08-17 22:25-01:04: dispatch sat undrained
# for ~2.5h until captain manually restarted the watcher.
#
# This supervisor runs from cron every 5 min. It ONLY re-arms when no watcher
# holds the lock - it never kills, never touches a live watcher. All output to
# the log below (rotate manually when large).
LOCK=/home/fm-captain/firstmate/state/.watch.lock
LOG=/home/fm-captain/firstmate/data/fm-watch-supervisor.log
ARM=/home/fm-captain/firstmate/bin/fm-watch-arm.sh

# lock dir exists AND the pid inside is alive -> healthy, exit quietly
if [ -d "$LOCK" ]; then
  pid=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi
fi

echo "[$(date -u +%FT%TZ)] no live watcher (lock missing or pid dead) - re-arming" >> "$LOG"
"$ARM" >> "$LOG" 2>&1
echo "[$(date -u +%FT%TZ)] arm exit=$?" >> "$LOG"
