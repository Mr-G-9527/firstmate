#!/usr/bin/env bash
# fm-review-submit.sh - emit a hash-bound report-submission terminal event.
# Appends a done row to captain-outbox with kind=report-submission +
# submission_id + artifact_path + artifact_sha256. Idempotent on
# (corr, seq, kind, artifact_sha256). Best-effort push; outbox is truth.
# The controller never infers completion from mtime; fm MUST call this helper.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
OUTBOX="$STATE/captain-outbox.jsonl"
LOCK="$STATE/.captain-outbox.lock"
DATA_ROOT="${FM_HOME}/data"
mkdir -p "$STATE"

CORR=
REPLY_TO_SEQ=
ARTIFACT=
while [ $# -gt 0 ]; do
  case "$1" in
    --corr) CORR="${2:-}"; shift 2 ;;
    --reply-to-seq) REPLY_TO_SEQ="${2:-}"; shift 2 ;;
    --artifact) ARTIFACT="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) echo "fm-review-submit: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CORR" ] || { echo "fm-review-submit: --corr required" >&2; exit 2; }
[ -n "$REPLY_TO_SEQ" ] || { echo "fm-review-submit: --reply-to-seq required" >&2; exit 2; }
[ -n "$ARTIFACT" ] || { echo "fm-review-submit: --artifact required" >&2; exit 2; }
case "$REPLY_TO_SEQ" in ''|*[!0-9]*) echo "fm-review-submit: --reply-to-seq must be an integer" >&2; exit 2 ;; esac

# Reject .env* artifacts
case "$ARTIFACT" in
  *.env|*.env.*) echo "fm-review-submit: artifact must not be .env*" >&2; exit 3 ;;
esac

# Resolve + validate artifact path (regular, non-empty, under DATA_ROOT)
ART_DIR="$(cd "$(dirname "$ARTIFACT")" 2>/dev/null && pwd)" || { echo "fm-review-submit: cannot resolve artifact dir: $ARTIFACT" >&2; exit 3; }
ART_BASE="$(basename "$ARTIFACT")"
ART_PATH="$ART_DIR/$ART_BASE"
[ -f "$ART_PATH" ] || { echo "fm-review-submit: artifact not a regular file: $ARTIFACT" >&2; exit 3; }
[ -s "$ART_PATH" ] || { echo "fm-review-submit: artifact empty: $ARTIFACT" >&2; exit 3; }
case "$ART_PATH" in
  "$DATA_ROOT"/*) ;;
  *) echo "fm-review-submit: artifact must be under $DATA_ROOT" >&2; exit 3 ;;
esac

HASH="$(sha256sum "$ART_PATH" | awk '{print $1}')"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUBMISSION_ID="sub_${TS}_${HASH:0:12}"

exec 9>"$LOCK"
flock 9

# dedup on (corr, seq=reply_to_seq, kind=report-submission, artifact_sha256)
DUP="$(jq -c --arg corr "$CORR" --arg hash "$HASH" --argjson seq "$REPLY_TO_SEQ" \
  'select(.corr==$corr and .seq==$seq and .kind=="report-submission" and .artifact_sha256==$hash)' \
  "$OUTBOX" 2>/dev/null | head -n1 || true)"
if [ -n "$DUP" ]; then
  echo "$DUP"
  exit 0
fi

ROW="$(jq -cn \
  --arg ts "$TS" \
  --arg corr "$CORR" \
  --argjson seq "$REPLY_TO_SEQ" \
  --arg kind "report-submission" \
  --arg state "done" \
  --arg submission_id "$SUBMISSION_ID" \
  --arg artifact_path "$ART_PATH" \
  --arg artifact_sha256 "$HASH" \
  '{ts:$ts,corr:$corr,seq:$seq,kind:$kind,state:$state,submission_id:$submission_id,artifact_path:$artifact_path,artifact_sha256:$artifact_sha256}')"
echo "$ROW" >> "$OUTBOX"

# best-effort push exact row; outbox remains truth
if [ -x "$SCRIPT_DIR/fm-captain-push.sh" ]; then
  echo "$ROW" | "$SCRIPT_DIR/fm-captain-push.sh" || true
fi

flock -u 9
echo "$ROW"
