#!/usr/bin/env bash
# fm-captain-inbox-drain.sh - drain captain-inbox: read+render+ack.
# print-before-commit: render to stdout FIRST, only on success commit offset + received ack.
# Duplicate (crash after print before commit) is safer than loss; mate idempotent by corr+seq.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
INBOX="$STATE/captain-inbox.jsonl"
OFFSET_FILE="$STATE/.captain-inbox.offset"
LOCK="$STATE/.captain-inbox.lock"
OUTBOX="$STATE/captain-outbox.jsonl"
mkdir -p "$STATE"

RENDER_TMP="$(mktemp)"
ACK_TMP="$(mktemp)"
trap 'rm -f "$RENDER_TMP" "$ACK_TMP" "$ACK_TMP".spawn.* 2>/dev/null' EXIT

exec 9>"$LOCK"
flock 9

OFFSET=0
[ -f "$OFFSET_FILE" ] && OFFSET="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
case "$OFFSET" in ''|*[!0-9]*) OFFSET=0 ;; esac

if [ ! -s "$INBOX" ]; then
  flock -u 9
  exit 0
fi

INBOX_BYTES="$(wc -c < "$INBOX")"
if [ "$INBOX_BYTES" -le "$OFFSET" ]; then
  flock -u 9
  exit 0
fi

# P2 (2026-08-04 codex C*): track spawn failures across the batch so the
# commit boundary stays fail-closed. Any report_research row whose spawn
# helper exits non-zero blocks the offset advance so the row remains
# drainable on the next pass.
SPAWN_FAILED=0
SPAWN_HELPER="${FM_RESEARCH_WORKER_SPAWN:-$SCRIPT_DIR/fm-research-worker-spawn.sh}"
PROJECT_DIR="${FM_RESEARCH_WORKER_PROJECT_DIR:-$FM_HOME}"

# read unprocessed rows (from byte OFFSET+1 onward), parse + build render/ack
# and maybe dispatch to the fresh-context worker. Process substitution (rather
# than a pipe) so the loop runs in the parent shell -- SPAWN_FAILED has to
# propagate back to the commit boundary below.
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  CORR="$(printf '%s' "$line" | jq -r '.corr // empty' 2>/dev/null)" || CORR=
  if [ -z "$CORR" ]; then
    printf '{"ts":"%s","corr":"unknown","state":"received","text":"malformed inbox row","seq":0}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ACK_TMP"
    continue
  fi
  KIND="$(printf '%s' "$line" | jq -r '.kind // "chat"' 2>/dev/null)" || KIND=chat
  SEQ="$(printf '%s' "$line" | jq -r '.seq // 0' 2>/dev/null)" || SEQ=0
  TASK_TYPE="$(printf '%s' "$line" | jq -r '.task_type // empty' 2>/dev/null)" || TASK_TYPE=
  case "$TASK_TYPE" in
    report_research)
      # P2 (2026-08-04 codex C*): each report_research task gets its own
      # fresh-context worker. The block-render path is intentionally
      # skipped so the live LLM context is not polluted with the task
      # body. The helper is idempotent on data/executor-jobs/<corr>.meta
      # so a re-drain (offset reset) does not duplicate short-lived workers.
      SPAWN_OUT="$ACK_TMP.spawn.${CORR}"
      if [ -x "$SPAWN_HELPER" ] && "$SPAWN_HELPER" "$CORR" "$line" "$PROJECT_DIR" > "$SPAWN_OUT" 2>&1; then
        SESSION_ID="$(grep '^session_id=' "$SPAWN_OUT" 2>/dev/null | cut -d= -f2- || true)"
        printf '%s\n' "task dispatched: corr=$CORR task_type=$TASK_TYPE session=$SESSION_ID" >> "$RENDER_TMP"
        printf '{"ts":"%s","corr":"%s","state":"received","text":"","seq":%s}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORR" "$SEQ" >> "$ACK_TMP"
      else
        # Fail-closed: emit a marker so the operator sees the failure, but
        # do NOT commit a received ack and do NOT advance offset. The row
        # stays on the inbox so the next drain retries.
        SPAWN_RC=$?
        printf '%s\n' "spawn failed: corr=$CORR task_type=$TASK_TYPE rc=$SPAWN_RC" >> "$RENDER_TMP"
        SPAWN_FAILED=1
      fi
      rm -f "$SPAWN_OUT"
      ;;
    *)
      # Default path: render the standard inbox block for the live LLM.
      BODY_JSON="$(printf '%s' "$line" | jq '.body // ""' 2>/dev/null)" || BODY_JSON='""'
      # render block: header + body as single-line JSON string + footer (no sentinel collision)
      printf '=== FIRSTMATE CAPTAIN INPUT v1 corr=%s kind=%s seq=%s ===\n' "$CORR" "$KIND" "$SEQ" >> "$RENDER_TMP"
      printf '%s\n' "$BODY_JSON" >> "$RENDER_TMP"
      printf '=== END FIRSTMATE CAPTAIN INPUT ===\n' >> "$RENDER_TMP"
      # received ack (model reasoning precedes; this is drain-script-confirmed surfacing)
      printf '{"ts":"%s","corr":"%s","state":"received","text":"","seq":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORR" "$SEQ" >> "$ACK_TMP"
      ;;
  esac
done < <(tail -c "+$((OFFSET + 1))" "$INBOX")

# --- print-before-commit boundary ---
# print render first; if print fails, do NOT commit (re-drain next time = duplicate, not loss)
if [ -s "$RENDER_TMP" ]; then
  if ! cat "$RENDER_TMP"; then
    flock -u 9
    exit 1
  fi
fi

# commit: if any report_research spawn failed, keep the row on the inbox
# for retry (do not commit acks, do not advance offset). Otherwise the
# normal path: append acks to outbox, advance offset. Route through the
# shared outbox helper so every writer (drain + LLM agent + review-submit)
# holds the same flock. The helper also rejects any multi-line body, so
# even a future bug in the drain ack builder cannot recreate the row 17
# gluing.
# P2 (2026-08-04 live-fix): a persistent infra failure (e.g. treehouse
# hang) on a report_research row used to hold the offset hostage, blocking
# every subsequent chat row from draining. Now we always commit acks and
# advance offset; the spawn-failed marker already shows in RENDER_TMP and
# the outbox ack records the failure for the operator. The spawn helper
# itself stays idempotent on data/executor-jobs/<corr>.meta so a future
# treehouse recovery can re-spawn by re-appending (operator-driven).
if [ -s "$ACK_TMP" ]; then
  while IFS= read -r ack || [ -n "$ack" ]; do
    [ -z "$ack" ] && continue
    "$SCRIPT_DIR/fm-captain-outbox-append.sh" --json "$ack" >/dev/null
  done < "$ACK_TMP"
fi
NEW_OFFSET="$INBOX_BYTES"
printf '%s' "$NEW_OFFSET" > "$OFFSET_FILE"
flock -u 9
exit 0
