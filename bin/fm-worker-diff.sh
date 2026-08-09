#!/usr/bin/env bash
# Build a unified patch.diff for a worker's local copy, ready for `git apply`
# on a separate checkout (F16 fix, wave4).
#
# A worker that runs `git diff HEAD~1..HEAD` over a brand-new file produces a
# `new file mode /dev/null +++ b/path` diff. The captain's local copy may
# already have the file committed, so the patch fails to apply with "already
# exists in index" (issue F16, observed on wave3 task fm-0808-w3-02). The fix
# is to detect per-file whether the worker's worktree already tracks the path:
# if it does, emit a `git diff HEAD` modification diff against the committed
# version; if it does not, fall back to the `--no-index /dev/null` new-file
# diff that a fresh checkout can absorb. The two cases are not equivalent on
# apply, so the per-file tracked/untracked check is what makes the produced
# patch correct for both sides.
#
# Usage: fm-worker-diff.sh [--out <path>] [--worktree <dir>]
#   --out <path>       write the unified diff to <path>; default stdout.
#                      stdout receives the same content as the file.
#   --worktree <dir>   operate against <dir> instead of the current directory.
#                      <dir> must contain a git working tree; the script
#                      uses `git -C <dir>` throughout.
#
# Exit codes:
#   0  patch written (an empty patch when the worktree is clean).
#   1  invocation error (bad flag, missing worktree, no git).
#   2  git error (status, diff, or ls-files failed).
#
# Untracked files outside the per-task `data/` directory are dropped with a
# warning to stderr: they are worker scratch, not a deliverable, and silently
# including them would leak unrelated /tmp content into the patch.
set -eu

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

OUT=
WORKTREE=
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=${2:?fm-worker-diff.sh: --out requires a value}; shift 2 ;;
    --out=*) OUT=${1#--out=}; shift ;;
    --worktree) WORKTREE=${2:?fm-worker-diff.sh: --worktree requires a value}; shift 2 ;;
    --worktree=*) WORKTREE=${1#--worktree=}; shift ;;
    --) shift; break ;;
    *) echo "fm-worker-diff.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ $# -gt 0 ]; then
  echo "fm-worker-diff.sh: unexpected positional args: $*" >&2
  exit 1
fi

if [ -n "$WORKTREE" ]; then
  if [ ! -d "$WORKTREE" ]; then
    echo "fm-worker-diff.sh: worktree not found: $WORKTREE" >&2
    exit 1
  fi
  case "$WORKTREE" in
    /*) WORKTREE_ABS=$WORKTREE ;;
    *) WORKTREE_ABS=$(CDPATH='' cd -- "$WORKTREE" && pwd -P) ;;
  esac
else
  WORKTREE_ABS=$(pwd -P)
fi

if ! git -C "$WORKTREE_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "fm-worker-diff.sh: not a git worktree: $WORKTREE_ABS" >&2
  exit 1
fi

WORKTREE_ROOT=$(git -C "$WORKTREE_ABS" rev-parse --show-toplevel) || {
  echo "fm-worker-diff.sh: could not resolve worktree root: $WORKTREE_ABS" >&2
  exit 1
}

# A deleted file has no on-disk content, so `git diff --no-index /dev/null <path>`
# is the only diff form that compares the worktree to the captain-side empty
# tree. A modified file must be compared against the committed version
# (`git diff HEAD`) so the captain's `git apply` overwrites the existing
# content rather than failing with "already exists in index".
emit_tracked_diff() {
  local path=$1
  git -C "$WORKTREE_ROOT" diff \
    --no-color --no-ext-diff --no-textconv --no-renames --patch HEAD -- "$path"
}

emit_new_file_diff() {
  local path=$1
  (
    cd "$WORKTREE_ROOT" || return 1
    # `git diff --no-index` returns 1 when the two paths differ, which is
    # the success case here (a matching pair would mean an empty file).
    git diff --no-color --no-ext-diff --no-textconv --no-index /dev/null "$path" \
      || [ $? -eq 1 ]
  )
}

build_patch() {
  local tracked untracked path
  local rc=0
  tracked=$(git -C "$WORKTREE_ROOT" diff --name-only HEAD) || {
    echo "fm-worker-diff.sh: git diff --name-only HEAD failed in $WORKTREE_ROOT" >&2
    return 2
  }
  untracked=$(git -C "$WORKTREE_ROOT" ls-files --others --exclude-standard) || {
    echo "fm-worker-diff.sh: git ls-files --others failed in $WORKTREE_ROOT" >&2
    return 2
  }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! emit_tracked_diff "$path"; then
      echo "fm-worker-diff.sh: git diff HEAD -- $path failed" >&2
      rc=2
    fi
  done <<EOF
$tracked
EOF
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      data/*) ;;
      *)
        echo "fm-worker-diff.sh: dropping out-of-scope untracked file: $path" >&2
        continue
        ;;
    esac
    if ! emit_new_file_diff "$path"; then
      echo "fm-worker-diff.sh: git diff --no-index /dev/null $path failed" >&2
      rc=2
    fi
  done <<EOF
$untracked
EOF
  return "$rc"
}

patch_content=$(build_patch) || exit 2

if [ -n "$OUT" ]; then
  if [ -n "$patch_content" ]; then
    if ! printf '%s\n' "$patch_content" > "$OUT"; then
      echo "fm-worker-diff.sh: could not write $OUT" >&2
      exit 1
    fi
  else
    : > "$OUT" || { echo "fm-worker-diff.sh: could not write $OUT" >&2; exit 1; }
  fi
fi
if [ -n "$patch_content" ]; then
  printf '%s\n' "$patch_content"
fi
