#!/usr/bin/env bash
# Behavior tests for bin/fm-scout-dag.sh: a bounded scout DAG runtime that
# reads `(depends: ...)` from the backlog, fans out leaves in parallel, waits
# for the frontier, and dispatches the next layer.
#
# Each test stubs the spawn primitive with a controlled fakebin that, when
# called as `fake-spawn <id> <project> --scout`, appends a configured status
# line to <state>/<id>.status. This keeps the tests fast (no tmux, no real
# crewmate) and lets us drive all five outcomes (done / failed / paused /
# blocked / needs-decision) deterministically.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DAG="$ROOT/bin/fm-scout-dag.sh"
TMP_ROOT=$(fm_test_tmproot fm-scout-dag)

# write_spawn_stub <fakebin>: drop a stub for fm-spawn.sh that, when called
# as `<id> <project> --scout`, looks up <state>/<id>.status and appends a
# configured status line. The configured outcome is read from
# SCOUT_TEST_OUTCOME_<id-with-dashes-replaced-by-underscores>; absent that,
# the stub writes "done: stub".
write_spawn_stub() {
  local fb=$1
  cat > "$fb/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
# stub fm-spawn.sh for fm-scout-dag tests. Reads SCOUT_TEST_OUTCOME_<id>
# from the environment and writes that line to <state>/<id>.status. If no
# outcome is configured for this id, writes "done: stub".
set -u
id="${1:-}"
shift
state_dir="${FM_TEST_STATE_DIR:-}"
case "$state_dir" in
  /*) : ;;
  *)  state_dir="$(pwd)/$state_dir" ;;
esac
status="$state_dir/$id.status"
verb_var="SCOUT_TEST_OUTCOME_${id//[-]/_}"
outcome="${!verb_var:-done: stub}"
mkdir -p "$state_dir"
printf '%s\n' "$outcome" >> "$status"
exit 0
SH
  chmod +x "$fb/fm-spawn.sh"
}

# make_home <prefix>: create a fresh FM_HOME layout (data/, state/, projects/,
# projects/<repo>) and return its absolute path.
make_home() {
  local prefix=$1
  local home=$TMP_ROOT/${prefix}-home
  mkdir -p "$home/data" "$home/state" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# write_backlog <path> <entry-line>...: build a minimal backlog from each
# "<id> - <title> (repo: <r>) (kind: scout) (depends: <deps>)" line so the
# DAG parser sees the canonical `(depends: ...)` syntax.
write_backlog() {
  local f=$1
  shift
  : > "$f"
  printf '%s\n' '# backlog (test fixture)' >> "$f"
  printf '%s\n' '## Queued' >> "$f"
  for entry in "$@"; do
    printf -- '- [ ] %s\n' "$entry" >> "$f"
  done
}

# run_dag <home> <root-id> [extra-args...]: invoke fm-scout-dag.sh against
# <home>. Returns the captured stdout and rc on stdout (rc trailer line at
# end). FM_HOME / state / spawn-bin are pre-configured so the test controls
# the runtime end-to-end.
run_dag() {
  local home=$1 root=$2
  shift 2
  local spawn_bin=$TMP_ROOT/fakebin/fm-spawn.sh
  local out rc
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_STATE_DIR="$home/state" \
    PATH="$TMP_ROOT/fakebin:$PATH" \
    "$DAG" --spawn-bin "$spawn_bin" --poll-secs 1 --await-timeout-secs 30 \
    "$@" "$root" 2>&1) || rc=$?
  rc=${rc:-0}
  printf 'RC=%d\nOUT_BEGIN\n%s\nOUT_END\n' "$rc" "$out"
}

# assert_rc <expected> <captured> <label>: parse the "RC=<n>" trailer from
# run_dag's stdout and fail the test if it does not match.
assert_rc() {
  local expected=$1 captured=$2 label=$3 actual
  actual=$(printf '%s\n' "$captured" | sed -n 's/^RC=\([0-9][0-9]*\)$/\1/p' | head -n 1)
  if [ -z "$actual" ]; then
    fail "$label: no RC trailer in run_dag output"
  fi
  [ "$actual" = "$expected" ] || fail "$label: expected rc=$expected, got rc=$actual"$'\n'"--- captured ---"$'\n'"$captured"
}

# dag_output <captured>: return everything between OUT_BEGIN and OUT_END.
dag_output() {
  awk '/^OUT_BEGIN$/{flag=1;next} /^OUT_END$/{flag=0} flag' <<EOF
$1
EOF
}

# A fresh fakebin (one per test) so tests do not share SCOUT_TEST_OUTCOME_*
# environment from previous runs.
fb=$(fm_fakebin "$TMP_ROOT")
write_spawn_stub "$fb"

# Test 1: a root with no deps. The DAG has one node in layer 0; the script
# dispatches it, awaits the stub's done line, and exits 0.
test_empty_frontier_single_root() {
  local home repo backlog captured out
  home=$(make_home single)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "single-root - solo (repo: alpha) (kind: scout)"
  captured=$(run_dag "$home" single-root)
  out=$(dag_output "$captured")
  assert_rc 0 "$captured" "single-root dispatch"
  assert_present "$home/state/single-root.status" "stub wrote status file"
  assert_grep 'done: stub' "$home/state/single-root.status" "stub wrote done line"
  pass "single-root DAG dispatches and waits for done"
}

# Test 2: a linear chain A -> B -> C. The stub fakes A's done first; the
# runtime should then dispatch B and C in turn. The final state shows all
# three statuses written in order, with B and C only appearing after A.
test_linear_chain() {
  local home repo backlog captured out
  home=$(make_home linear)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "lin-a - a (repo: alpha) (kind: scout)" \
    "lin-b - b (repo: alpha) (kind: scout) (depends: lin-a)" \
    "lin-c - c (repo: alpha) (kind: scout) (depends: lin-b)"
  captured=$(run_dag "$home" lin-c)
  out=$(dag_output "$captured")
  assert_rc 0 "$captured" "linear chain dispatch"
  assert_present "$home/state/lin-a.status" "lin-a status exists"
  assert_present "$home/state/lin-b.status" "lin-b status exists"
  assert_present "$home/state/lin-c.status" "lin-c status exists"
  assert_grep 'done: stub' "$home/state/lin-a.status" "lin-a done"
  assert_grep 'done: stub' "$home/state/lin-b.status" "lin-b done"
  assert_grep 'done: stub' "$home/state/lin-c.status" "lin-c done"
  pass "linear chain A -> B -> C executes in dependency order"
}

# Test 3: a diamond A -> (B, C) -> D. A dispatches first; B and C dispatch
# after A's done (in parallel because their deps are both satisfied);
# D dispatches only after both B and C are done.
test_diamond() {
  local home repo backlog captured out
  home=$(make_home diamond)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "dia-a - a (repo: alpha) (kind: scout)" \
    "dia-b - b (repo: alpha) (kind: scout) (depends: dia-a)" \
    "dia-c - c (repo: alpha) (kind: scout) (depends: dia-a)" \
    "dia-d - d (repo: alpha) (kind: scout) (depends: dia-b, dia-c)"
  captured=$(run_dag "$home" dia-d)
  out=$(dag_output "$captured")
  assert_rc 0 "$captured" "diamond dispatch"
  for id in dia-a dia-b dia-c dia-d; do
    assert_grep 'done: stub' "$home/state/$id.status" "$id stub done"
  done
  pass "diamond A -> (B,C) -> D fans out then joins"
}

# Test 4: a root that depends on an unknown id surfaces a missing-dep error
# and exits non-zero (rc=3 per the script's contract). Manual dispatch
# guidance is printed so the operator sees the missing id.
test_missing_dependency() {
  local home repo backlog captured out
  home=$(make_home missing)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "miss-root - root (repo: alpha) (kind: scout) (depends: not-in-backlog)"
  captured=$(run_dag "$home" miss-root)
  out=$(dag_output "$captured")
  assert_rc 3 "$captured" "missing-dependency exits 3"
  assert_contains "$out" "not-in-backlog" "error names the missing id"
  assert_contains "$out" "unknown id" "error message uses 'unknown id' vocabulary"
  pass "missing-dependency surfaces a clean error and exits 3"
}

# Test 5a: a chain where the middle node fails. With --abort-on-fail it
# exits 5 and the dependent is NOT auto-dispatched.
test_partial_failure_abort_on_fail() {
  local home repo backlog captured out
  home=$(make_home fail-abort)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "faf-a - a (repo: alpha) (kind: scout)" \
    "faf-b - b (repo: alpha) (kind: scout) (depends: faf-a)" \
    "faf-c - c (repo: alpha) (kind: scout) (depends: faf-b)"
  export SCOUT_TEST_OUTCOME_faf_b="failed: simulated mid-chain failure"
  captured=$(run_dag "$home" --abort-on-fail faf-c)
  unset SCOUT_TEST_OUTCOME_faf_b
  out=$(dag_output "$captured")
  assert_rc 5 "$captured" "--abort-on-fail exits 5 on first failure"
  assert_contains "$out" "manual replan" "--abort-on-fail path prints manual replan"
  assert_present "$home/state/faf-a.status" "faf-a ran"
  assert_grep 'failed: simulated' "$home/state/faf-b.status" "faf-b recorded failed"
  assert_absent "$home/state/faf-c.status" "faf-c was NOT auto-dispatched"
  pass "partial failure with --abort-on-fail aborts the DAG and skips dependents"
}

# Test 5b: same chain, default (no --abort-on-fail). The runtime must NOT
# abort; it prints manual-replan guidance and exits 0 so today's manual
# dispatch remains the recovery path.
test_partial_failure_default_replan() {
  local home repo backlog captured out
  home=$(make_home fail-replan)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "fpr-a - a (repo: alpha) (kind: scout)" \
    "fpr-b - b (repo: alpha) (kind: scout) (depends: fpr-a)" \
    "fpr-c - c (repo: alpha) (kind: scout) (depends: fpr-b)"
  export SCOUT_TEST_OUTCOME_fpr_b="failed: simulated mid-chain failure"
  captured=$(run_dag "$home" fpr-c)
  unset SCOUT_TEST_OUTCOME_fpr_b
  out=$(dag_output "$captured")
  assert_rc 0 "$captured" "default (no --abort-on-fail) exits 0"
  assert_contains "$out" "manual replan" "manual replan guidance printed"
  assert_contains "$out" "fpr-b" "replan names the stuck node"
  assert_absent "$home/state/fpr-c.status" "dependent not auto-dispatched"
  pass "partial failure default replans without aborting"
}

# Test 6: a paused leaf keeps the DAG waiting. The runtime treats paused
# as a settled (non-working) state, so it does NOT abort the DAG; it
# surfaces the pause as a captain-decision wake and exits 0 so the
# captain can resume the leaf manually.
test_paused_leaf() {
  local home repo backlog captured out
  home=$(make_home paused)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "pls-a - a (repo: alpha) (kind: scout)" \
    "pls-b - b (repo: alpha) (kind: scout) (depends: pls-a)" \
    "pls-c - c (repo: alpha) (kind: scout) (depends: pls-b)"
  export SCOUT_TEST_OUTCOME_pls_b="paused: waiting on external rate-limit reset"
  captured=$(run_dag "$home" --abort-on-fail pls-c)
  unset SCOUT_TEST_OUTCOME_pls_b
  out=$(dag_output "$captured")
  assert_rc 0 "$captured" "paused leaf does not abort the DAG"
  assert_contains "$out" "paused" "output surfaces the paused verb"
  assert_present "$home/state/pls-a.status" "pls-a ran"
  assert_grep 'paused: waiting' "$home/state/pls-b.status" "pls-b recorded paused"
  assert_absent "$home/state/pls-c.status" "pls-c not auto-dispatched while b paused"
  pass "paused leaf is detected and reported without aborting the DAG"
}

# Test 7: --dry-run parses the DAG, prints the layered plan, and exits 0
# without spawning anything. This is the captain's fall-back flag: when
# anything goes wrong with the runtime, the captain can re-run with
# --dry-run to recover the plan and dispatch each layer manually.
test_dry_run_prints_plan() {
  local home repo backlog captured out
  home=$(make_home dryrun)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "dry-a - a (repo: alpha) (kind: scout)" \
    "dry-b - b (repo: alpha) (kind: scout) (depends: dry-a)" \
    "dry-c - c (repo: alpha) (kind: scout) (depends: dry-b)"
  captured=$(run_dag "$home" --dry-run dry-c)
  out=$(dag_output "$captured")
  assert_rc 0 "$captured" "--dry-run exits 0"
  assert_contains "$out" "Layer 0" "--dry-run prints Layer 0"
  assert_contains "$out" "Layer 1" "--dry-run prints Layer 1"
  assert_contains "$out" "Layer 2" "--dry-run prints Layer 2"
  assert_contains "$out" "dry-a" "plan names dry-a in layer 0"
  assert_contains "$out" "dry-c" "plan names dry-c in layer 2"
  assert_absent "$home/state/dry-a.status" "no scout was dispatched under --dry-run"
  pass "--dry-run prints the layered plan without dispatching"
}

# Test 8: idempotence. A re-run after a partial completion should NOT
# re-dispatch nodes whose state files already carry a terminal verb.
# Same input frontier on a second invocation produces the same dispatch
# decisions, so re-running the script on a partially-completed DAG is
# safe.
test_idempotent_rerun() {
  local home repo backlog captured out
  home=$(make_home rerun)
  repo=$home/projects/alpha
  mkdir -p "$repo"
  backlog=$home/data/backlog.md
  write_backlog "$backlog" \
    "rerun-a - a (repo: alpha) (kind: scout)" \
    "rerun-b - b (repo: alpha) (kind: scout) (depends: rerun-a)" \
    "rerun-c - c (repo: alpha) (kind: scout) (depends: rerun-b)"
  captured=$(run_dag "$home" rerun-c)
  assert_rc 0 "$captured" "first run succeeds"
  local first_done_a first_done_b first_done_c
  first_done_a=$(grep -c '^done:' "$home/state/rerun-a.status" || true)
  first_done_b=$(grep -c '^done:' "$home/state/rerun-b.status" || true)
  first_done_c=$(grep -c '^done:' "$home/state/rerun-c.status" || true)
  captured=$(run_dag "$home" rerun-c)
  assert_rc 0 "$captured" "second run succeeds (no-op)"
  local second_done_a second_done_b second_done_c
  second_done_a=$(grep -c '^done:' "$home/state/rerun-a.status" || true)
  second_done_b=$(grep -c '^done:' "$home/state/rerun-b.status" || true)
  second_done_c=$(grep -c '^done:' "$home/state/rerun-c.status" || true)
  [ "$first_done_a" = "$second_done_a" ] || fail "rerun appended new line to rerun-a"
  [ "$first_done_b" = "$second_done_b" ] || fail "rerun appended new line to rerun-b"
  [ "$first_done_c" = "$second_done_c" ] || fail "rerun appended new line to rerun-c"
  pass "re-run after completion is a no-op (idempotent)"
}

test_empty_frontier_single_root
test_linear_chain
test_diamond
test_missing_dependency
test_partial_failure_abort_on_fail
test_partial_failure_default_replan
test_paused_leaf
test_dry_run_prints_plan
test_idempotent_rerun

echo "all fm-scout-dag tests passed"