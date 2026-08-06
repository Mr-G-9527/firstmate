#!/usr/bin/env bash
# fm-captain-outbox-append.sh - append a single captain-outbox row under flock.
#
# All writers to state/captain-outbox.jsonl MUST route through this helper or
# hold the same flock on state/.captain-outbox.lock. The shared flock file
# path is the contract; do not split the lock file path across writers.
#
# Why the lock is needed:
#   state/captain-outbox.jsonl row 17 had two JSON objects glued without a
#   newline separator (root cause: drain.sh ack append + LLM-agent printf +
#   manual retry interleaved on a plain `>>` with no shared lock). The flock
#   here serializes every append so a single newline-terminated line is the
#   only unit that can land on disk.
#
# What other writers must do:
#   - Use this helper (preferred - one place that owns the lock pattern).
#   - OR open state/.captain-outbox.lock and acquire the same flock before
#     any `>> state/captain-outbox.jsonl`. Do not invent a second lock path.
#
# What happens if a writer forgets the lock:
#   Degrades to the pre-fix row 17 bug: concurrent appends can interleave
#   and produce glued JSON objects that fail single-line validation.
#
# Inputs:
#   --corr <id>          correlation id (required)
#   --state <state>      state field for the row (required; e.g. done|received|accepted|rejected|blocked|needs-decision)
#   --text <text>        captain-facing text (may be empty)
#   --seq <n>            integer seq (required)
#   --kind <kind>        row kind (optional; default chat)
#   --json '<row-json>'  full prebuilt JSON object (overrides --text/--state/--kind/--seq)
#   --ts '<iso8601>'     optional timestamp override (default: now UTC)
#   --outbox '<path>'    optional outbox path override (default: $STATE/captain-outbox.jsonl)
#
# Output:
#   stdout: the row that was appended (single newline-terminated JSON line).
#   exit 0: appended; non-zero: rejected (multi-line body, invalid JSON, etc).
#
# Mode 0700 because the file path is captain-private and the outbox is
# adjacent to other state-secret material.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
OUTBOX="${OUTBOX:-$STATE/captain-outbox.jsonl}"
LOCK="$STATE/.captain-outbox.lock"
mkdir -p "$STATE"

CORR=
ROW_STATE=
TEXT=
SEQ=
KIND=chat
JSON_BODY=
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while [ $# -gt 0 ]; do
  case "$1" in
    --corr) CORR="${2:-}"; shift 2 ;;
    --state) ROW_STATE="${2:-}"; shift 2 ;;
    --text) TEXT="${2:-}"; shift 2 ;;
    --seq) SEQ="${2:-}"; shift 2 ;;
    --kind) KIND="${2:-chat}"; shift 2 ;;
    --json) JSON_BODY="${2:-}"; shift 2 ;;
    --ts) TS="${2:-}"; shift 2 ;;
    --outbox) OUTBOX="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) echo "fm-captain-outbox-append: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Build or accept the row.
if [ -n "$JSON_BODY" ]; then
  # Reject any payload that would write more than one line; this is the
  # exact guard that would have prevented the row 17 corruption.
  case "$JSON_BODY" in
    *$'\n'*)
      echo "fm-captain-outbox-append: --json payload must be a single line (no newlines)" >&2
      exit 3
      ;;
  esac
  ROW="$JSON_BODY"
else
  [ -n "$CORR" ] || { echo "fm-captain-outbox-append: --corr required (or use --json)" >&2; exit 2; }
  [ -n "$ROW_STATE" ] || { echo "fm-captain-outbox-append: --state required (or use --json)" >&2; exit 2; }
  [ -n "$SEQ" ] || { echo "fm-captain-outbox-append: --seq required (or use --json)" >&2; exit 2; }
  case "$SEQ" in ''|*[!0-9]*) echo "fm-captain-outbox-append: --seq must be an integer" >&2; exit 2 ;; esac
  ROW="$(jq -cn \
    --arg ts "$TS" \
    --arg corr "$CORR" \
    --arg state "$ROW_STATE" \
    --arg text "$TEXT" \
    --arg kind "$KIND" \
    --argjson seq "$SEQ" \
    '{ts:$ts,corr:$corr,state:$state,text:$text,kind:$kind,seq:$seq}')"
fi

# Validate the row is single-line, well-formed JSON before holding the lock.
case "$ROW" in
  *$'\n'*)
    echo "fm-captain-outbox-append: built row contains a newline" >&2
    exit 3
    ;;
esac
if ! printf '%s' "$ROW" | jq -e . >/dev/null 2>&1; then
  echo "fm-captain-outbox-append: row is not valid JSON" >&2
  exit 3
fi
ROW_STATE_VALUE="$(printf '%s' "$ROW" | jq -r '.state // empty')"
if [ "$ROW_STATE_VALUE" = accepted ]; then
  echo "fm-captain-outbox-append: state=accepted is captain/controller-only; use needs-decision" >&2
  exit 4
fi

# Acquire the shared flock, append, release. The lock file path is
# state/.captain-outbox.lock - same as bin/fm-review-submit.sh.
exec 9>"$LOCK"
flock 9
printf '%s\n' "$ROW" >> "$OUTBOX"
flock -u 9

printf '%s\n' "$ROW"
