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
trap 'rm -f "$RENDER_TMP" "$ACK_TMP" 2>/dev/null' EXIT

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

# read unprocessed rows (from byte OFFSET+1 onward), parse + build render/ack
tail -c "+$((OFFSET + 1))" "$INBOX" | \
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
    BODY_JSON="$(printf '%s' "$line" | jq '.body // ""' 2>/dev/null)" || BODY_JSON='""'
    # render block: header + body as single-line JSON string + footer (no sentinel collision)
    printf '=== FIRSTMATE CAPTAIN INPUT v1 corr=%s kind=%s seq=%s ===\n' "$CORR" "$KIND" "$SEQ" >> "$RENDER_TMP"
    printf '%s\n' "$BODY_JSON" >> "$RENDER_TMP"
    printf '=== END FIRSTMATE CAPTAIN INPUT ===\n' >> "$RENDER_TMP"
    # received ack (model reasoning precedes; this is drain-script-confirmed surfacing)
    printf '{"ts":"%s","corr":"%s","state":"received","text":"","seq":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORR" "$SEQ" >> "$ACK_TMP"
  done

# --- print-before-commit boundary ---
# print render first; if print fails, do NOT commit (re-drain next time = duplicate, not loss)
if [ -s "$RENDER_TMP" ]; then
  if ! cat "$RENDER_TMP"; then
    flock -u 9
    exit 1
  fi
fi

# commit: append acks to outbox, advance offset. Route through the shared
# outbox helper so every writer (drain + LLM agent + review-submit) holds
# the same flock. The helper also rejects any multi-line body, so even a
# future bug in the drain ack builder cannot recreate the row 17 gluing.
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
