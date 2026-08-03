#!/usr/bin/env bash
# fm-captain-inbox-append.sh - append one captain inbox row + enqueue wake.
# Body on stdin. WSL-owned seq. --json prints {corr,kind,seq} to stdout.
# kind: chat|authorize|decision-reply|cancel-request
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
INBOX="$STATE/captain-inbox.jsonl"
LOCK="$STATE/.captain-inbox.lock"
mkdir -p "$STATE"

KIND=chat
CORR=
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND="${2:-chat}"; shift 2 ;;
    --corr) CORR="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    --) shift; break ;;
    *) echo "fm-captain-inbox-append: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CORR" ] || { echo "fm-captain-inbox-append: --corr required" >&2; exit 2; }

BODY="$(cat)"

exec 9>"$LOCK"
flock 9

SEQ="$(awk -F'"seq":' 'NF>1{v=$2; sub(/[^0-9].*/,"",v); if (v+0>max) max=v+0} END{print max+1}' "$INBOX" 2>/dev/null || echo 1)"
case "$SEQ" in ''|*[!0-9]*) SEQ=1 ;; esac

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ROW="$(jq -cn --arg ts "$TS" --arg corr "$CORR" --arg kind "$KIND" --arg body "$BODY" --argjson seq "$SEQ" '{ts:$ts,corr:$corr,kind:$kind,body:$body,seq:$seq}')"
echo "$ROW" >> "$INBOX"

fm_wake_append signal captain-inbox "captain-inbox: seq=$SEQ corr=$CORR" || true

flock -u 9
if [ "$JSON" = "1" ]; then
  jq -cn --arg corr "$CORR" --arg kind "$KIND" --argjson seq "$SEQ" '{corr:$corr,kind:$kind,seq:$seq}'
else
  echo "appended seq=$SEQ corr=$CORR kind=$KIND" >&2
fi
