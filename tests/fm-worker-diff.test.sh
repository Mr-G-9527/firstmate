#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-diff.sh (F16 fix).
#
# Each case builds a real git worktree, runs the script, and round-trips the
# emitted patch through `git apply` on a fresh clone so the verdict reflects
# what the captain actually sees, not just the bytes the script produced. The
# three required cases are:
#   1. modified file  - tracked file changes; the diff must be a modification
#                        diff (no `/dev/null` source) and `git apply` must
#                        overwrite the existing file.
#   2. new file       - untracked file under data/; the diff must be a new-file
#                        diff from `/dev/null` and `git apply` must create it.
#   3. no change      - the script must exit 0 and emit an empty patch so the
#                        downstream receiver can still read patch.diff.
# A fourth bonus case covers a mixed change set (modified + new) in one worktree.
# A fifth case covers the out-of-scope untracked filter (a /tmp file is not a
# deliverable and must be dropped with a warning, not silently included).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-diff)
SCRIPT="$ROOT/bin/fm-worker-diff.sh"

fm_git_identity

# Build a fresh worktree seeded with one tracked file and one tracked data
# file, so the test fixtures can both modify and create under data/ without
# any leftover state from a previous run. Sets globals FWT_REPO and FWT_WT
# for the caller to consume (a here-doc over command substitution is the
# classic broken pattern for this; globals are the only portable form).
FWT_REPO=
FWT_WT=
build_fresh_worktree() {
  local prefix=$1
  FWT_REPO="$TMP_ROOT/$prefix-repo"
  FWT_WT="$TMP_ROOT/$prefix-wt"
  rm -rf "$FWT_REPO" "$FWT_WT"
  mkdir -p "$FWT_REPO"
  git -C "$FWT_REPO" init -q -b main
  printf 'tracked line one\n' > "$FWT_REPO/tracked.txt"
  mkdir -p "$FWT_REPO/data"
  printf 'baseline data\n' > "$FWT_REPO/data/report.md"
  git -C "$FWT_REPO" add tracked.txt data/report.md
  git -C "$FWT_REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git -C "$FWT_REPO" worktree add --quiet -b fm/test "$FWT_WT"
}

# extract_file_hunk <patch> <path>: print only the hunk for <path> from <patch>,
# so a per-file assertion does not see markers from sibling files in a combined
# diff. The hunk starts at the matching `diff --git a/<path> b/<path>` line
# and runs until the next `diff --git` or end of file.
extract_file_hunk() {
  local patch=$1 path=$2
  awk -v header="diff --git a/$path b/$path" '
    $0 == header { in_hunk = 1 }
    /^diff --git / && $0 != header { in_hunk = 0; next }
    in_hunk { print }
  ' "$patch"
}

assert_diff_is_modification() {
  local patch=$1 path=$2 hunk hunk_file
  hunk=$(extract_file_hunk "$patch" "$path")
  [ -n "$hunk" ] || fail "no hunk for $path in $patch"
  assert_grep "--- a/$path" "$patch" \
    "modification diff missing --- a/$path for $path"
  assert_grep "+++ b/$path" "$patch" \
    "modification diff missing +++ b/$path for $path"
  hunk_file=$(mktemp "$TMP_ROOT/hunk.XXXXXX")
  printf '%s\n' "$hunk" > "$hunk_file"
  assert_no_grep "+++ /dev/null" "$hunk_file" \
    "modification diff for $path unexpectedly contains +++ /dev/null"
  assert_no_grep "--- /dev/null" "$hunk_file" \
    "modification diff for $path unexpectedly contains --- /dev/null"
  rm -f "$hunk_file"
}

assert_diff_is_new_file() {
  local patch=$1 path=$2 hunk hunk_file
  hunk=$(extract_file_hunk "$patch" "$path")
  [ -n "$hunk" ] || fail "no hunk for $path in $patch"
  hunk_file=$(mktemp "$TMP_ROOT/hunk.XXXXXX")
  printf '%s\n' "$hunk" > "$hunk_file"
  assert_grep "new file mode" "$hunk_file" \
    "new-file diff missing new file mode for $path"
  assert_grep "--- /dev/null" "$hunk_file" \
    "new-file diff missing --- /dev/null for $path"
  assert_grep "+++ b/$path" "$hunk_file" \
    "new-file diff missing +++ b/$path for $path"
  rm -f "$hunk_file"
}

assert_round_trip_apply() {
  local source_wt=$1 target_wt=$2 patch=$3 path=$4
  rm -rf "$target_wt"
  git clone --quiet "$source_wt" "$target_wt"
  git -C "$target_wt" apply --check "$patch" \
    || fail "git apply --check failed for $path against $target_wt"
  git -C "$target_wt" apply "$patch" \
    || fail "git apply failed for $path against $target_wt"
}

test_modified_file_emits_modification_diff_and_round_trips() {
  local patch target lines
  build_fresh_worktree modified-1
  printf 'tracked line one\ntracked line two added\n' > "$FWT_WT/tracked.txt"
  patch="$TMP_ROOT/modified-1.patch"
  "$SCRIPT" --worktree "$FWT_WT" --out "$patch"
  assert_diff_is_modification "$patch" tracked.txt
  target="$TMP_ROOT/modified-1-target"
  assert_round_trip_apply "$FWT_REPO" "$target" "$patch" tracked.txt
  lines=$(wc -l < "$target/tracked.txt" | tr -d ' ')
  [ "$lines" = "2" ] || fail "applied tracked.txt has $lines lines, expected 2"
  pass "fm-worker-diff.sh: modified tracked file produces modification diff that round-trips"
}

test_new_file_in_data_emits_new_file_diff_and_round_trips() {
  local patch target
  build_fresh_worktree newfile-1
  printf 'fresh per-task artifact\n' > "$FWT_WT/data/fresh.md"
  patch="$TMP_ROOT/newfile-1.patch"
  "$SCRIPT" --worktree "$FWT_WT" --out "$patch"
  assert_diff_is_new_file "$patch" data/fresh.md
  target="$TMP_ROOT/newfile-1-target"
  assert_round_trip_apply "$FWT_REPO" "$target" "$patch" data/fresh.md
  assert_present "$target/data/fresh.md" "round-tripped new file is missing"
  pass "fm-worker-diff.sh: new file under data/ produces new-file diff that round-trips"
}

test_no_change_emits_empty_patch_and_exits_zero() {
  local patch size
  build_fresh_worktree nochange-1
  patch="$TMP_ROOT/nochange-1.patch"
  "$SCRIPT" --worktree "$FWT_WT" --out "$patch"
  size=$(wc -c < "$patch" | tr -d ' ')
  [ "$size" = "0" ] || fail "no-change patch was $size bytes, expected 0"
  pass "fm-worker-diff.sh: clean worktree produces empty patch and exits 0"
}

test_mixed_modified_and_new_combines_into_one_patch() {
  local patch target
  build_fresh_worktree mixed-1
  printf 'tracked line one\ntracked line two added\n' > "$FWT_WT/tracked.txt"
  printf 'second fresh artifact\n' > "$FWT_WT/data/extra.md"
  patch="$TMP_ROOT/mixed-1.patch"
  "$SCRIPT" --worktree "$FWT_WT" --out "$patch"
  assert_diff_is_modification "$patch" tracked.txt
  assert_diff_is_new_file "$patch" data/extra.md
  target="$TMP_ROOT/mixed-1-target"
  assert_round_trip_apply "$FWT_REPO" "$target" "$patch" tracked.txt
  assert_present "$target/data/extra.md" "round-tripped extra new file is missing"
  pass "fm-worker-diff.sh: mixed tracked + new produces one combined patch that round-trips"
}

test_out_of_scope_untracked_file_is_dropped() {
  local patch err size
  build_fresh_worktree scope-1
  mkdir -p "$FWT_WT/tmp"
  printf 'this is scratch, not a deliverable\n' > "$FWT_WT/tmp/scratch.md"
  patch="$TMP_ROOT/scope-1.patch"
  err="$TMP_ROOT/scope-1.err"
  "$SCRIPT" --worktree "$FWT_WT" --out "$patch" 2>"$err"
  size=$(wc -c < "$patch" | tr -d ' ')
  [ "$size" = "0" ] || fail "out-of-scope untracked file was included (patch $size bytes)"
  assert_grep "dropping out-of-scope untracked file: tmp/scratch.md" "$err" \
    "out-of-scope untracked file did not warn on stderr"
  pass "fm-worker-diff.sh: out-of-scope untracked files are dropped with a warning"
}

test_modified_file_on_brand_new_repo_matches_captain_already_committed_state() {
  # The exact F16 scenario: a worker clones captain's repo, modifies a file
  # the captain has already committed, and produces a diff the captain can
  # apply. The diff must look like a modification of the existing tracked
  # file, not a new-file addition.
  local patch target
  build_fresh_worktree f16-scenario
  printf 'baseline data\ndata line two added by worker\n' > "$FWT_WT/data/report.md"
  patch="$TMP_ROOT/f16.patch"
  "$SCRIPT" --worktree "$FWT_WT" --out "$patch"
  assert_diff_is_modification "$patch" data/report.md
  target="$TMP_ROOT/f16-target"
  assert_round_trip_apply "$FWT_REPO" "$target" "$patch" data/report.md
  assert_grep "data line two added by worker" "$target/data/report.md" \
    "F16 round-trip did not preserve the worker's added line"
  pass "fm-worker-diff.sh: F16 scenario (modify-then-apply) round-trips with modification diff"
}

test_no_args_help_and_missing_worktree_failures() {
  local help_file err rc
  help_file="$TMP_ROOT/help.out"
  "$SCRIPT" --help >"$help_file" 2>&1 || fail "--help exited non-zero"
  assert_grep "Usage: fm-worker-diff.sh" "$help_file" "help did not print usage"

  rc=0
  "$SCRIPT" --bogus >/dev/null 2>"$TMP_ROOT/bogus.err" || rc=$?
  expect_code 1 "$rc" "unknown arg must exit 1"
  assert_grep "unknown arg: --bogus" "$TMP_ROOT/bogus.err" \
    "unknown arg did not name the offending flag"

  rc=0
  "$SCRIPT" --worktree "$TMP_ROOT/does-not-exist" >/dev/null 2>"$TMP_ROOT/missing.err" || rc=$?
  expect_code 1 "$rc" "missing worktree must exit 1"
  assert_grep "worktree not found" "$TMP_ROOT/missing.err" \
    "missing worktree did not report the path"

  rc=0
  "$SCRIPT" --worktree "$TMP_ROOT" >/dev/null 2>"$TMP_ROOT/not-repo.err" || rc=$?
  expect_code 1 "$rc" "non-repo dir must exit 1"
  assert_grep "not a git worktree" "$TMP_ROOT/not-repo.err" \
    "non-repo dir did not fail loudly"
  pass "fm-worker-diff.sh: --help works, bad args and missing worktree fail loudly"
}

test_modified_file_emits_modification_diff_and_round_trips
test_new_file_in_data_emits_new_file_diff_and_round_trips
test_no_change_emits_empty_patch_and_exits_zero
test_mixed_modified_and_new_combines_into_one_patch
test_out_of_scope_untracked_file_is_dropped
test_modified_file_on_brand_new_repo_matches_captain_already_committed_state
test_no_args_help_and_missing_worktree_failures
