#!/usr/bin/env bash
# Durable intake: persist report Work Orders before ACK; execute from retry queue.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-wake-lib.sh"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
INBOX="$STATE/captain-inbox.jsonl"
OFFSET_FILE="$STATE/.captain-inbox.offset"
QUEUE_DIR="${FM_RESEARCH_DISPATCH_QUEUE_DIR:-$STATE/research-dispatch-queue}"
DISPATCH_DRAIN="${FM_RESEARCH_DISPATCH_DRAIN:-$SCRIPT_DIR/fm-research-dispatch-drain.sh}"
META_DIR="${FM_EXECUTOR_JOBS_DIR:-$FM_HOME/data/executor-jobs}"
mkdir -p "$STATE" "$QUEUE_DIR"
RENDER_TMP="$(mktemp)"; ACK_TMP="$(mktemp)"
trap 'rm -f "$RENDER_TMP" "$ACK_TMP" "$ACK_TMP".queue.* 2>/dev/null' EXIT
dispatch_pending() { [ -x "$DISPATCH_DRAIN" ] && "$DISPATCH_DRAIN" 2>&1 || true; }
exec 9>"$STATE/.captain-inbox.lock"; flock 9
OFFSET=0; [ -f "$OFFSET_FILE" ] && OFFSET="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
case "$OFFSET" in ''|*[!0-9]*) OFFSET=0 ;; esac
if [ ! -s "$INBOX" ]; then flock -u 9; dispatch_pending; exit 0; fi
INBOX_BYTES="$(wc -c < "$INBOX")"
if [ "$INBOX_BYTES" -le "$OFFSET" ]; then flock -u 9; dispatch_pending; exit 0; fi
PROJECT_DIR="${FM_RESEARCH_WORKER_PROJECT_DIR:-$FM_HOME}"
ENQUEUE_FAILED=0
queue_report_row() {
  local corr="$1" seq="$2" revision_seq="$3" row="$4"
  case "$corr" in ''|*[!A-Za-z0-9._-]*) printf '%s\n' "rejected report task: unsafe corr=$corr" >> "$RENDER_TMP"; return 2 ;; esac
  case "$seq" in ''|*[!0-9]*) printf '%s\n' "rejected report task: invalid seq=$seq corr=$corr" >> "$RENDER_TMP"; return 2 ;; esac
  local q="$QUEUE_DIR/$corr.$seq.json" t="$ACK_TMP.queue.$corr.$seq"
  [ -f "$q" ] && return 0
  if ! jq -cn --arg corr "$corr" --argjson seq "$seq" --arg revision_seq "$revision_seq" \
      --arg project_dir "$PROJECT_DIR" --argjson row "$row" \
      '{corr:$corr,seq:$seq,revision_seq:$revision_seq,project_dir:$project_dir,attempts:0,row:$row}' > "$t"; then
    rm -f "$t"; printf '%s\n' "queue write failed: corr=$corr seq=$seq" >> "$RENDER_TMP"; return 1
  fi
  chmod 600 "$t"; mv -f "$t" "$q"
}
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  CORR="$(printf '%s' "$line" | jq -r '.corr // empty' 2>/dev/null)" || CORR=
  if [ -z "$CORR" ]; then
    printf '{"ts":"%s","corr":"unknown","state":"received","text":"malformed inbox row","seq":0}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ACK_TMP"; continue
  fi
  KIND="$(printf '%s' "$line" | jq -r '.kind // "chat"' 2>/dev/null)" || KIND=chat
  SEQ="$(printf '%s' "$line" | jq -r '.seq // 0' 2>/dev/null)" || SEQ=0
  TASK_TYPE="$(printf '%s' "$line" | jq -r '.task_type // empty' 2>/dev/null)" || TASK_TYPE=
  BODY="$(printf '%s' "$line" | jq -r '.body // empty' 2>/dev/null)" || BODY=
  REVISION_SEQ=
  if [ -f "$META_DIR/$CORR.meta" ] && { printf '%s' "$BODY" | grep -Fq '[fm cross-model review' || printf '%s' "$BODY" | grep -Fq '[fm review submission reminder'; }; then
    TASK_TYPE=report_research; REVISION_SEQ="$SEQ"
  fi
  case "$TASK_TYPE" in
    report_research)
      if queue_report_row "$CORR" "$SEQ" "$REVISION_SEQ" "$line"; then
        printf '%s\n' "task queued: corr=$CORR task_type=report_research revision=${REVISION_SEQ:-0}" >> "$RENDER_TMP"
        printf '{"ts":"%s","corr":"%s","state":"received","text":"","seq":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORR" "$SEQ" >> "$ACK_TMP"
      else
        QUEUE_RC=$?
        if [ "$QUEUE_RC" -eq 2 ]; then
          printf '{"ts":"%s","corr":"%s","state":"blocked","text":"invalid report Work Order identity; captain must reissue it","seq":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORR" "$SEQ" >> "$ACK_TMP"
        else
          ENQUEUE_FAILED=1
        fi
      fi
      ;;
    *)
      BODY_JSON="$(printf '%s' "$line" | jq '.body // ""' 2>/dev/null)" || BODY_JSON='""'
      printf '=== FIRSTMATE CAPTAIN INPUT v1 corr=%s kind=%s seq=%s ===\n%s\n=== END FIRSTMATE CAPTAIN INPUT ===\n' "$CORR" "$KIND" "$SEQ" "$BODY_JSON" >> "$RENDER_TMP"
      printf '{"ts":"%s","corr":"%s","state":"received","text":"","seq":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORR" "$SEQ" >> "$ACK_TMP"
      ;;
  esac
done < <(tail -c "+$((OFFSET + 1))" "$INBOX")
[ ! -s "$RENDER_TMP" ] || cat "$RENDER_TMP"
if [ "$ENQUEUE_FAILED" -ne 0 ]; then flock -u 9; exit 1; fi
COMMIT_FAILED=0
while IFS= read -r ack || [ -n "$ack" ]; do
  [ -z "$ack" ] && continue
  "$SCRIPT_DIR/fm-captain-outbox-append.sh" --json "$ack" >/dev/null || COMMIT_FAILED=1
done < "$ACK_TMP"
if [ "$COMMIT_FAILED" -ne 0 ]; then flock -u 9; exit 1; fi
TMP_OFFSET="$(mktemp "$STATE/.captain-inbox.offset.XXXXXX")"
printf '%s' "$INBOX_BYTES" > "$TMP_OFFSET"; chmod 600 "$TMP_OFFSET"; mv -f "$TMP_OFFSET" "$OFFSET_FILE"
flock -u 9
dispatch_pending
