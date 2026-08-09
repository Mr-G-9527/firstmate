#!/usr/bin/env bash
# fm-review-submit.sh - emit a hash-bound report-submission terminal event
# AND write a consolidated code-diff receipt to data/<task-id>/receipt.diff.
#
# Behavior:
#   1. Validate --task-id (optional), --corr, --reply-to-seq, --artifact,
#      and --worktree.
#   2. When --task-id is supplied, compute
#        base_sha = `git -C <worktree> merge-base HEAD origin/main`,
#      falling back to `git -C <worktree> merge-base HEAD main` when
#      origin/main is unavailable, so multi-commit work yields ONE
#      consolidated diff against the canonical base.
#   3. Write data/<task-id>/receipt.diff containing
#      `git -C <worktree> diff <base_sha> HEAD` BEFORE the existing
#      captain-outbox JSONL append + best-effort push. The receipt
#      lands on disk even when the network push later 429s; the outbox
#      row becomes the submission record, and the diff file is the
#      captain's review artifact.
#   4. Append a done row to captain-outbox with kind=report-submission
#      + submission_id + artifact_path + artifact_sha256. Idempotent
#      on (corr, seq, kind, artifact_sha256). Best-effort push;
#      outbox is truth. The controller never infers completion from
#      mtime; fm MUST call this helper.
#
# Flags:
#   --task-id <id>       writes the receipt under data/<id>/receipt.diff;
#                        when omitted, the script skips the receipt step
#                        and behaves as a pure outbox submitter.
#   --worktree <path>    worktree root used for merge-base + diff
#                        computation; default is pwd. Must be inside a
#                        git working tree that can resolve origin/main
#                        (or local main).
#   --corr <id>          correlation id for the submission row.
#   --reply-to-seq <n>   integer seq the row replies to.
#   --artifact <path>    report artifact under FM_HOME/data/.
#   --help | -h          print this header and exit 0.
#
# Outputs (stdout):
#   The captain-outbox JSON row that was appended (or the duplicate row
#   when an idempotent match was found).
#
# Side effects:
#   data/<task-id>/receipt.diff    consolidated diff when --task-id is set
#   state/captain-outbox.jsonl     submission row (idempotent)
#   state/captain-outbox.jsonl     per-task done row (idempotent) when
#                                  --task-id is set; emitted via
#                                  bin/fm-task-done.sh so the captain
#                                  monitor never misses a completion
#                                  that the worker only knew as "call
#                                  the submit helper" (puti 监控漏 fix)
#   best-effort fm-captain-push    network push; outbox remains truth
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
OUTBOX="$STATE/captain-outbox.jsonl"
LOCK="$STATE/.captain-outbox.lock"
DATA_ROOT="${FM_HOME}/data"
mkdir -p "$STATE"

CORR=
REPLY_TO_SEQ=
ARTIFACT=
TASK_ID=
WORKTREE="$(pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
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

# When --task-id is supplied, write the consolidated diff receipt BEFORE
# the JSONL append + push (the submit step). A network 429 on the push
# must not lose the work record, so the receipt lands first.
if [ -n "$TASK_ID" ]; then
  [ -d "$WORKTREE" ] || { echo "fm-review-submit: --worktree not a directory: $WORKTREE" >&2; exit 3; }
  command -v git >/dev/null 2>&1 || { echo "fm-review-submit: git not on PATH" >&2; exit 3; }
  git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "fm-review-submit: --worktree is not a git repo: $WORKTREE" >&2
    exit 3
  }
  BASE_SHA="$(git -C "$WORKTREE" merge-base HEAD origin/main 2>/dev/null \
    || git -C "$WORKTREE" merge-base HEAD main 2>/dev/null \
    || true)"
  [ -n "$BASE_SHA" ] || {
    echo "fm-review-submit: cannot compute merge-base against origin/main or main in $WORKTREE" >&2
    exit 3
  }
  RECEIPT_DIR="$DATA_ROOT/$TASK_ID"
  RECEIPT_PATH="$RECEIPT_DIR/receipt.diff"
  mkdir -p "$RECEIPT_DIR"
  if ! git -C "$WORKTREE" diff "$BASE_SHA" HEAD > "$RECEIPT_PATH" 2>/dev/null; then
    echo "fm-review-submit: failed to write receipt.diff at $RECEIPT_PATH" >&2
    exit 3
  fi
fi

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

# Per-task done emit. The captain monitor reads the outbox for per-task
# completion; without this row a worker that only knows the canonical
# submit helper would still need a separate chat append to surface its
# `done:` event, which is the puti 监控漏 gap. The emit is best-effort:
# the report-submission row above is the contract and remains on disk
# even if this auxiliary call fails. The warning goes to stderr so the
# worker sees it, but the script's exit code reflects the primary row.
# The artifact forwarded to fm-task-done.sh is the report the worker
# submitted, not the receipt.diff fm-review-submit wrote: a fresh
# worktree can have an empty diff against the merge-base, and the
# report is the actual reviewable deliverable anyway.
if [ -n "$TASK_ID" ] && [ -x "$SCRIPT_DIR/fm-task-done.sh" ]; then
  if ! "$SCRIPT_DIR/fm-task-done.sh" \
      --task-id "$TASK_ID" \
      --corr "$CORR" \
      --artifact "$ART_PATH" >/dev/null; then
    echo "fm-review-submit: per-task done emit failed (task-done.sh exit); report-submission row still landed" >&2
  fi
fi