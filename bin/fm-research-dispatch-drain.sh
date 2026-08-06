#!/usr/bin/env bash
# fm-research-dispatch-drain.sh - retry durable report_research admissions.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-wake-lib.sh"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
QUEUE_DIR="${FM_RESEARCH_DISPATCH_QUEUE_DIR:-$STATE/research-dispatch-queue}"
SPAWN_HELPER="${FM_RESEARCH_WORKER_SPAWN:-$SCRIPT_DIR/fm-research-worker-spawn.sh}"
MAX_ATTEMPTS="${FM_RESEARCH_DISPATCH_RETRY_MAX:-3}"
LOCK="$STATE/.research-dispatch.lock"
mkdir -p "$QUEUE_DIR"
case "$MAX_ATTEMPTS" in ''|*[!0-9]*) MAX_ATTEMPTS=3 ;; esac
[ "$MAX_ATTEMPTS" -gt 0 ] || MAX_ATTEMPTS=3
exec 9>"$LOCK"
flock 9
shopt -s nullglob
for QUEUE_FILE in "$QUEUE_DIR"/*.json; do
  [ -f "$QUEUE_FILE" ] || continue
  CORR="$(jq -r '.corr // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  SEQ="$(jq -r '.seq // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  REVISION_SEQ="$(jq -r '.revision_seq // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  ROW_JSON="$(jq -c '.row // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  ATTEMPTS="$(jq -r '.attempts // 0' "$QUEUE_FILE" 2>/dev/null || true)"
  case "$CORR" in ''|*[!A-Za-z0-9._-]*) echo "dispatch queue invalid corr: $QUEUE_FILE" >&2; continue ;; esac
  case "$SEQ" in ''|*[!0-9]*) echo "dispatch queue invalid seq: $QUEUE_FILE" >&2; continue ;; esac
  case "$ATTEMPTS" in ''|*[!0-9]*) ATTEMPTS=0 ;; esac
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "dispatch paused: corr=$CORR seq=$SEQ attempts=$ATTEMPTS/$MAX_ATTEMPTS" >&2
    continue
  fi
  if [ -z "$ROW_JSON" ] || [ ! -x "$SPAWN_HELPER" ]; then
    echo "dispatch pending: corr=$CORR seq=$SEQ (invalid row or missing spawn helper)" >&2
    continue
  fi
  SPAWN_OUT="$QUEUE_FILE.spawn.out"
  if FM_RESEARCH_WORKER_REVISION_SEQ="$REVISION_SEQ" "$SPAWN_HELPER" "$CORR" "$ROW_JSON" "${FM_RESEARCH_WORKER_PROJECT_DIR:-$FM_HOME}" >"$SPAWN_OUT" 2>&1; then
    cat "$SPAWN_OUT"
    rm -f "$SPAWN_OUT" "$QUEUE_FILE"
    echo "dispatch complete: corr=$CORR seq=$SEQ"
    continue
  fi
  NEXT=$((ATTEMPTS + 1))
  TMP_FILE="$(mktemp "$QUEUE_DIR/.retry.XXXXXX")"
  if jq --argjson attempts "$NEXT" '.attempts=$attempts' "$QUEUE_FILE" >"$TMP_FILE"; then
    chmod 600 "$TMP_FILE"
    mv -f "$TMP_FILE" "$QUEUE_FILE"
  else
    rm -f "$TMP_FILE"
  fi
  rm -f "$SPAWN_OUT"
  echo "dispatch retry pending: corr=$CORR seq=$SEQ attempt=$NEXT/$MAX_ATTEMPTS" >&2
  if [ "$NEXT" -lt "$MAX_ATTEMPTS" ]; then
    fm_wake_append signal research-dispatch "retry corr=$CORR seq=$SEQ" || true
  else
    echo "dispatch paused after retry budget: corr=$CORR seq=$SEQ" >&2
  fi
done
flock -u 9
