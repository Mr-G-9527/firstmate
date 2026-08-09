#!/usr/bin/env bash
# fm-task-done.sh - emit a per-task done row to the captain outbox.
#
# What this is:
#   The root-fix wrapper for the "puti 监控漏 (P1)" friction. Workers
#   already call `bin/fm-review-submit.sh` for hash-bound submission
#   and `bin/fm-captain-outbox-append.sh` for ad-hoc chat rows, but
#   neither of those primitives emits a per-task done row on its own.
#   The captain monitor therefore loses completions whenever a worker
#   finishes without manually appending a chat row for the task. This
#   helper makes the per-task done row a one-call primitive that the
#   controller (or a worker) can fire at task `done:` time, and that
#   `bin/fm-review-submit.sh --task-id` invokes automatically so a
#   worker that only knows the canonical submit helper still gets
#   the per-task emit.
#
# What it does:
#   1. Validate --task-id and --artifact. --kind, --worktree, and
#      --corr are optional. --kind defaults to ship (the only shape
#      firstmate's controller distinguishes today); --corr defaults
#      to the task id so a one-call invocation never has to repeat
#      it; --worktree is reserved for a future variant that derives
#      the patch from the worktree (today the artifact is supplied).
#   2. Stage the captain-facing text "<task-id> done at <artifact
#      path>". A second --text override lets a caller carry richer
#      per-task detail (verify report path, branch, etc) without
#      losing the canonical "task-id done at <path>" prefix.
#   3. Route through `bin/fm-captain-outbox-append.sh --idempotent`
#      with --corr, --state done, --kind task-done, --seq 0. The
#      helper holds the same flock that owns the outbox's row-atomic
#      ity contract, and --idempotent dedupes on (corr, kind) under
#      that lock so a re-call of this helper never doubles the row.
#      Two concurrent calls are also serialized: only one row lands.
#
# Why pass-through to fm-captain-outbox-append.sh:
#   Row atomicity is owned by that helper. Holding a second lock from
#   a parallel writer would split the file's atomicity contract and
#   re-introduce the row 17 corruption shape. The wrapper therefore
#   never writes to the outbox directly.
#
# Flags:
#   --task-id <id>     task identifier; becomes the default corr.
#   --corr <id>        correlation id (defaults to --task-id).
#   --kind <k>         ship|scout (default ship); recorded only as
#                      the row's `kind` field so the controller can
#                      tell ship receipts from scout completion rows.
#   --artifact <path>  the patch.diff or report.md the captain
#                      should review. The outbox text carries this
#                      path so the monitor knows where to look.
#   --text '<text>'    override the captain-facing text. The default
#                      is "<task-id> done at <artifact path>". When
#                      set, the override REPLACES the default (not
#                      appended) so the row always reads as a single
#                      terminal event.
#   --seq <n>          integer seq the row carries (default 0). The
#                      captain outbox is a JSONL, not an inbox, so
#                      seq is informational; the per-task dedup key
#                      is (corr, kind), not seq.
#   --help | -h        print this header and exit 0.
#
# Output:
#   The outbox row that was appended (or the existing row when the
#   idempotent dedup matched). Single newline-terminated JSON line.
#
# Exit codes:
#   0   row appended (or matched an existing one)
#   2   argument error (missing or unknown flag)
#   3   artifact not a regular, non-empty file under $FM_HOME/data
#   4   fm-captain-outbox-append.sh rejected the row (multi-line,
#       invalid JSON, state=accepted, etc); the wrapper does not
#       translate this into a different code
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

OUTBOX_APPEND="$SCRIPT_DIR/fm-captain-outbox-append.sh"

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
DATA_ROOT="${FM_HOME}/data"
mkdir -p "$STATE"

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

TASK_ID=
CORR=
ROW_KIND=ship
ARTIFACT=
WORKTREE=
TEXT_OVERRIDE=
SEQ=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --corr) CORR="${2:-}"; shift 2 ;;
    --kind) ROW_KIND="${2:-ship}"; shift 2 ;;
    --artifact) ARTIFACT="${2:-}"; shift 2 ;;
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
    --text) TEXT_OVERRIDE="${2:-}"; shift 2 ;;
    --seq) SEQ="${2:-0}"; shift 2 ;;
    --) shift; break ;;
    *) echo "fm-task-done: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TASK_ID" ] || { echo "fm-task-done: --task-id required" >&2; exit 2; }
[ -n "$ARTIFACT" ] || { echo "fm-task-done: --artifact required" >&2; exit 2; }
case "$SEQ" in ''|*[!0-9]*) echo "fm-task-done: --seq must be an integer" >&2; exit 2 ;; esac
case "$ROW_KIND" in ship|scout) ;; *) echo "fm-task-done: --kind must be ship or scout, got: $ROW_KIND" >&2; exit 2 ;; esac

# Resolve + validate artifact path (regular, non-empty, under DATA_ROOT).
ART_DIR="$(cd "$(dirname "$ARTIFACT")" 2>/dev/null && pwd)" || { echo "fm-task-done: cannot resolve artifact dir: $ARTIFACT" >&2; exit 3; }
ART_BASE="$(basename "$ARTIFACT")"
ART_PATH="$ART_DIR/$ART_BASE"
[ -f "$ART_PATH" ] || { echo "fm-task-done: artifact not a regular file: $ARTIFACT" >&2; exit 3; }
[ -s "$ART_PATH" ] || { echo "fm-task-done: artifact empty: $ARTIFACT" >&2; exit 3; }
case "$ART_PATH" in
  "$DATA_ROOT"/*) ;;
  *) echo "fm-task-done: artifact must be under $DATA_ROOT" >&2; exit 3 ;;
esac

[ -n "$WORKTREE" ] || WORKTREE="$(pwd)"
[ -x "$OUTBOX_APPEND" ] || { echo "fm-task-done: helper not executable: $OUTBOX_APPEND" >&2; exit 2; }

if [ -z "$CORR" ]; then
  CORR="$TASK_ID"
fi
if [ -z "$TEXT_OVERRIDE" ]; then
  TEXT="$TASK_ID done at $ART_PATH"
else
  TEXT="$TEXT_OVERRIDE"
fi

"$OUTBOX_APPEND" \
  --idempotent \
  --corr "$CORR" \
  --state 'done' \
  --text "$TEXT" \
  --seq "$SEQ" \
  --kind task-done
