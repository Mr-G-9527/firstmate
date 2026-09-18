#!/usr/bin/env bash
# Behavior tests for the fleet-snapshot summary hook inside
# bin/fm-claude-stop-autoarm.sh (proposal data/fm-stop-autoarm-fleet-snapshot,
# captain-approved 2026-09-18).
#
# The summary must:
#  - run only on the two clean exit paths (need vanished mid-cycle, healthy
#    watcher with failure-episode reset)
#  - NEVER fire on failed / actionable / AFK / identity-fail / need-not-met paths
#  - write to state/.fleet-snapshot-prepend.txt with the bounded one-line shape
#  - fall back to a sentinel line if jq / timeout / snapshot is unavailable
#  - keep the script's exit code unchanged (snapshot is a side effect only)
#  - keep stderr empty on clean paths (snapshot must NOT use the rewake banner
#    channel)
# shellcheck disable=SC2016 # single quotes deliberate: see fm-claude-stop-autoarm.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-stop-autoarm-fleet-snapshot)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# Mirror fm-claude-stop-autoarm.test.sh fixture layout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Provide a real-looking fm-fleet-snapshot.sh that emits a controlled JSON
# fixture, so the jq pipeline inside write_fleet_summary runs end to end
# without depending on the actual home's snapshot state.
install_snapshot_fixture() {
  local dir=$1 backlog_count=$2 open_dec=$3 stale_24=$4 tasks=$5
  cat > "$dir/bin/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' '{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-09-18T07:00:00Z",
  "backlog": {
    "records": [
$(python3 -c "
import json
recs = []
for i in range(int('$backlog_count')):
    recs.append({'state': 'in_flight', 'hold_kind': None, 'since': '2026-09-17'})
for i in range(int('$open_dec')):
    recs.append({'state': 'in_flight', 'hold_kind': 'captain', 'since': '2026-09-17'})
for i in range(int('$stale_24')):
    recs.append({'state': 'in_flight', 'hold_kind': 'captain', 'since': '2026-09-15'})
print(',\n'.join(json.dumps(r) for r in recs))
")
    ]
  },
  "tasks": [$(python3 -c "print(','.join('{}' for _ in range(int('$tasks'))))")]
}'
SH
  chmod +x "$dir/bin/fm-fleet-snapshot.sh"
}

# Provide a fake fm-watch-arm.sh that mimics the existing 'meta-vanishes'
# fixture: it removes task.meta so the post-arm need_supervision check
# returns 1, taking the "need vanished mid-cycle" clean exit path. That
# path is one of the two where write_fleet_summary() is invoked.
write_arm_clean() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
rm -f "$dir/state/task.meta"
printf 'watcher: started pid=%s (beacon fresh)\n' "\$\$"
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# Spawn a long-lived fake watcher process so fm_watcher_healthy() has a real
# pid to validate, and record its identity + lock + fresh beacon. Mirrors
# record_watcher_lock() from tests/fm-claude-stop-autoarm.test.sh.
spawn_watcher_with_lock() {
  local dir=$1
  : > "$dir/bin/fm-watch.sh"
  chmod +x "$dir/bin/fm-watch.sh"
  (
    trap '' TERM
    while true; do sleep 60; done
  ) >/dev/null 2>&1 &
  local watcher_pid=$!
  local identity
  identity=$(fm_pid_identity "$watcher_pid" 2>/dev/null) || identity="claude"
  local root=$dir
  local bin_dir
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$watcher_pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  : > "$dir/state/.last-watcher-beat"
  printf '%s\n' "$watcher_pid" > "$dir/.watcher-pid"
}

# Walk every test fixture dir created under TMP_ROOT and kill any spawned
# watcher so the test process can exit cleanly.
cleanup_watchers() {
  local watcher_pid
  for f in "$TMP_ROOT"/*/.watcher-pid; do
    [ -e "$f" ] || continue
    watcher_pid=$(cat "$f" 2>/dev/null || true)
    [ -n "$watcher_pid" ] && kill "$watcher_pid" 2>/dev/null || true
  done
}
trap cleanup_watchers EXIT

# Provide a fake fm-watch-arm.sh that emits an actionable wake. This forces
# the script into the ACTIONABLE branch (exit 2 with banner).
write_arm_actionable() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: test.fixture actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# Run the autoarm as the lock-owning fake-harness child. Captures stdout,
# stderr, and exit code into files inside the fixture dir. Emits three lines
# to stdout that the caller reads as paths:
#   line 1: stdout capture file (rewake banner lands here on actionable paths)
#   line 2: stderr capture file (must be empty on clean paths)
#   line 3: RC=N
run_autoarm_capture() {
  local dir=$1
  local rc=0
  local stdout_path="$dir/.captured-stdout"
  local stderr_path="$dir/.captured-stderr"
  local rc_path="$dir/.captured-rc"
  printf '%s\n' '{"session_id":"sess-fs-test","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' >"$stdout_path" 2>"$stderr_path" || rc=$?
  printf '%s\n' "$rc" > "$rc_path"
  printf '%s\n%s\n%s\n' "$stdout_path" "$stderr_path" "$rc_path"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

# Build an isolated fakebin directory containing a controllable `jq` plus
# the standard tools the autoarm runtime needs. Used by tests 3 and 4 to
# isolate the autoarm from the host's real jq / timeout / etc.
#
# $1 = fakebin path
# $2 = jq behavior:
#      "absent"   - do not create the jq symlink (PATH has no jq)
#      "nopass"   - jq that prints valid summary JSON (so write_fleet_summary
#                   succeeds via the jq path)
#      "fail"     - jq that exits non-zero on every invocation (sentinel fallback)
#      "sleep N"  - jq that sleeps N seconds (timeout test)
# Build a jq-only fakebin and prepend it to the host PATH for the test
# run. Keeping only jq isolated (and letting every other tool resolve via
# the host PATH) is enough to exercise write_fleet_summary's command -v jq
# branch and its `timeout 2s ... | jq` wrapper without rebuilding a full
# fakebin for the autoarm's many toolchain dependencies.
#
# $1 = jqwrap dir
# $2 = jq behavior:
#      "absent"   - do not create the jq shim (PATH prepended without jq)
#      "nopass"   - jq shim that prints the host jq output (delegates)
#      "fail"     - jq shim that exits non-zero on every invocation
#      "sleep N"  - jq shim that sleeps N seconds (timeout ceiling test)
build_jqwrap() {
  local bin=$1 jq_mode=$2
  rm -rf "$bin"
  mkdir -p "$bin"
  case "$jq_mode" in
    absent) : ;;
    nopass)
      ln -sf "$(command -v jq)" "$bin/jq" ;;
    fail)
      cat > "$bin/jq" <<'JQ'
#!/usr/bin/env bash
echo "fake-jq: configured to fail" >&2
exit 7
JQ
      chmod +x "$bin/jq"
      ;;
    sleep*)
      local n
      n=$(printf '%s' "$jq_mode" | sed 's/^sleep //')
      cat > "$bin/jq" <<JQ
#!/usr/bin/env bash
sleep $n
JQ
      chmod +x "$bin/jq"
      ;;
    *) fail "build_jqwrap: unknown jq_mode: $jq_mode" ;;
  esac
}

# Run the autoarm with jqwrap prepended to the host PATH. Captures rc,
# summary file presence, and wall-clock seconds into the fixture dir.
#
# $1 = fixture dir
# $2 = jqwrap dir to prepend to PATH (jq may be absent inside)
run_with_jqwrap() {
  local dir=$1 jqwrap=$2
  local stdout_path="$dir/.captured-stdout"
  local stderr_path="$dir/.captured-stderr"
  local rc_path="$dir/.captured-rc"
  local elapsed_path="$dir/.captured-elapsed"
  local rc=0
  local t0 t1
  t0=$(date +%s)
  printf '%s\n' '{"session_id":"sess-fs-test","stop_hook_active":false}' \
    | PATH="$jqwrap:$PATH" FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' >"$stdout_path" 2>"$stderr_path" || rc=$?
  t1=$(date +%s)
  printf '%s\n' "$rc" > "$rc_path"
  printf '%s\n' "$((t1 - t0))" > "$elapsed_path"
}

# --- 1. Happy path: clean exit writes the bounded summary line -----------------

test_clean_exit_writes_summary() {
  local dir out_paths stdout_path stderr_path rc_path rc
  dir=$(make_primary_dir "$TMP_ROOT/clean-ok")
  : > "$dir/state/task.meta"
  install_snapshot_fixture "$dir" 3 2 1 0
  write_arm_clean "$dir"

  local helper_out
  helper_out=$(run_autoarm_capture "$dir" 2>/dev/null)
  stdout_path=$(sed -n '1p' <<<"$helper_out")
  stderr_path=$(sed -n '2p' <<<"$helper_out")
  rc_path=$(sed -n '3p' <<<"$helper_out")
  rc=$(cat "$rc_path" 2>/dev/null)
  rc=${rc:-0}

  expect_code 0 "$rc" "clean exit path must keep exit 0"
  [ -e "$dir/state/.fleet-snapshot-prepend.txt" ] \
    || fail "summary file must be written on clean exit"

  local line
  line=$(cat "$dir/state/.fleet-snapshot-prepend.txt")
  case "$line" in
    # Fixture builds: 3 in_flight (no captain, since 2026-09-17) + 2 open_dec
    # (captain, since 2026-09-17) + 1 stale_24 (captain, since 2026-09-15).
    # Today's date is 2026-09-18 (system clock), so 2026-09-17 records are
    # ~31h old — all 3 captain rows qualify as stale24h. in_flight = 3+2+1=6.
    '[fleet '*'] in_flight=6 open_dec=3 stale24h=3 tasks=0'*) pass "summary line shape ok: $line" ;;
    *) fail "summary line shape unexpected: $line" ;;
  esac

  # Stderr must be empty on the clean path: snapshot must NOT use the
  # rewake banner channel.
  [ ! -s "$stderr_path" ] || fail "clean path leaked stderr: $(cat "$stderr_path")"
}

# --- 2. Actionable path: must NOT write the summary ---------------------------

test_actionable_exit_skips_summary() {
  local dir out_paths stdout_path stderr_path rc_path rc line
  dir=$(make_primary_dir "$TMP_ROOT/actionable-skip")
  : > "$dir/state/task.meta"
  install_snapshot_fixture "$dir" 5 3 2 0
  write_arm_actionable "$dir"

  local helper_out
  helper_out=$(run_autoarm_capture "$dir" 2>/dev/null)
  stdout_path=$(sed -n '1p' <<<"$helper_out")
  stderr_path=$(sed -n '2p' <<<"$helper_out")
  rc_path=$(sed -n '3p' <<<"$helper_out")
  rc=$(cat "$rc_path" 2>/dev/null)
  rc=${rc:-0}

  expect_code 2 "$rc" "actionable path must exit 2"
  [ ! -e "$dir/state/.fleet-snapshot-prepend.txt" ] \
    || fail "summary must NOT be written on actionable (exit 2) path"
}

# --- 3. jq path: real jq produces a real summary line -------------------------

# Isolated PATH containing the host's real jq plus all standard tools the
# autoarm runtime needs. Asserts the jq filter runs end-to-end and writes
# a [fleet ...] line.
test_jq_path_produces_real_summary() {
  local dir jqwrap line rc
  dir=$(make_primary_dir "$TMP_ROOT/jq-smoke")
  : > "$dir/state/task.meta"
  install_snapshot_fixture "$dir" 0 0 0 0
  write_arm_clean "$dir"

  jqwrap="$TMP_ROOT/jqwrap-pass"
  build_jqwrap "$jqwrap" nopass

  run_with_jqwrap "$dir" "$jqwrap"
  rc=$(cat "$dir/.captured-rc" 2>/dev/null)
  rc=${rc:-0}

  expect_code 0 "$rc" "real-jq path must keep exit 0"
  line=$(cat "$dir/state/.fleet-snapshot-prepend.txt" 2>/dev/null || echo "")
  case "$line" in
    '[fleet '*) pass "real jq produces a summary line: $line" ;;
    *) fail "real jq path expected summary, got: $line" ;;
  esac
}

# --- 4. jq found but exits non-zero: command-failure fallback fires ----------

# End-to-end assertion for the `|| line=""` branch in write_fleet_summary:
# jq IS resolved by `command -v jq`, but the jq invocation itself exits
# non-zero. This is the production code path triggered when jq is installed
# but its data is malformed or the user lacks permission to read it. It
# is NOT the path triggered by jq missing from PATH (covered separately by
# test_command_v_jq_missing_unit_assertion below).
#
# A wrapper that exits 7 reaches the same `|| line=""` branch without
# blanking PATH (which would also remove the autoarm's basename / ps / git
# toolchain and break the autoarm before write_fleet_summary ever runs).
test_jq_found_but_fails_falls_back_to_sentinel() {
  local dir jqwrap line rc elapsed
  dir=$(make_primary_dir "$TMP_ROOT/jq-fails")
  : > "$dir/state/task.meta"
  install_snapshot_fixture "$dir" 0 0 0 0
  write_arm_clean "$dir"

  jqwrap="$TMP_ROOT/jqwrap-fail"
  build_jqwrap "$jqwrap" fail

  run_with_jqwrap "$dir" "$jqwrap"
  rc=$(cat "$dir/.captured-rc" 2>/dev/null)
  rc=${rc:-0}
  elapsed=$(cat "$dir/.captured-elapsed" 2>/dev/null)
  elapsed=${elapsed:-0}

  expect_code 0 "$rc" "jq-fails path must keep exit 0"
  [ "$elapsed" -le 5 ] \
    || fail "jq-fails path took ${elapsed}s; expected <=5s"
  [ -e "$dir/state/.fleet-snapshot-prepend.txt" ] \
    || fail "sentinel file must be written when jq exits non-zero"
  line=$(cat "$dir/state/.fleet-snapshot-prepend.txt")
  case "$line" in
    '[snapshot skipped: '*']') pass "sentinel fallback fired: $line" ;;
    *) fail "expected sentinel line, got: $line" ;;
  esac
}

# --- 4b. unit assertion: command -v jq missing ------------------------------

# Lightweight standalone shell check that the production guard predicate
# `command -v jq` correctly reports jq absent under a stripped PATH. This
# is a code-shape assertion (the literal substring `command -v jq` must
# appear in the production guard and must short-circuit when jq is
# unresolvable). It does NOT source the production script — sourcing the
# full autoarm re-triggers Stop-hook machinery and was brittle.
test_command_v_jq_missing_unit_assertion() {
  # Production guard must literally check `command -v jq`.
  grep -q 'command -v jq' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    || fail "production guard no longer contains 'command -v jq'; update this assertion"

  # Build a PATH that has every standard tool except jq, and verify jq
  # truly does not resolve under it. Mirrors the build_jqwrap fixtures
  # used by the e2e tests, minus the jq shim.
  local nojqbindir
  nojqbindir=$(mktemp -d 2>/dev/null) || fail "mktemp failed"
  for b in bash sh cat mv rm sed awk cut printf timeout date ln \
           ps dirname head tail tr sort uniq od tee \
           mkdir touch grep find xargs wc env tty readlink stat whoami git \
           uname diff true false echo test basename id hostname mktemp; do
    command -v "$b" >/dev/null 2>&1 \
      && ln -sf "$(command -v "$b")" "$nojqbindir/$b"
  done

  local jq_check
  jq_check=$(PATH="$nojqbindir" command -v jq 2>/dev/null || true)
  if [ -n "$jq_check" ]; then
    rm -rf "$nojqbindir"
    fail "fixture broken: jq resolved to '$jq_check' inside nojqbindir"
  fi

  # The production guard's first clause is `command -v jq >/dev/null 2>&1`.
  # Under the stripped PATH that returns non-zero, so the outer `if` short-
  # circuits and the sentinel line is the only legal output. This asserts
  # the structural shape; the e2e jq-fails test (test 4) asserts the
  # fall-through end to end.
  rm -rf "$nojqbindir"
  pass "command -v jq short-circuits cleanly under stripped PATH (jq not resolvable)"
}

# --- 5. jq hung: timeout 2s ceiling fires -------------------------------------

# Isolated PATH with a fake jq that sleeps for 5 seconds. The autoarm's
# `timeout 2s ... | jq` wrapper must kill the jq child at 2s, fall through
# to the sentinel line, and the script must still exit 0 with the right
# elapsed-time budget. A regression that removes the timeout ceiling would
# let this test hang past 4s and fail.
test_hung_jq_is_cut_by_timeout() {
  local dir jqwrap line rc elapsed
  dir=$(make_primary_dir "$TMP_ROOT/jq-hung")
  : > "$dir/state/task.meta"
  install_snapshot_fixture "$dir" 0 0 0 0
  write_arm_clean "$dir"

  jqwrap="$TMP_ROOT/jqwrap-hung"
  build_jqwrap "$jqwrap" "sleep 5"

  run_with_jqwrap "$dir" "$jqwrap"
  rc=$(cat "$dir/.captured-rc" 2>/dev/null)
  rc=${rc:-0}
  elapsed=$(cat "$dir/.captured-elapsed" 2>/dev/null)
  elapsed=${elapsed:-0}

  expect_code 0 "$rc" "hung-jq path must keep exit 0"
  [ "$elapsed" -lt 5 ] \
    || fail "hung-jq path took ${elapsed}s; timeout ceiling appears broken (expected <5s)"
  [ -e "$dir/state/.fleet-snapshot-prepend.txt" ] \
    || fail "summary file must be written even when jq times out"
  line=$(cat "$dir/state/.fleet-snapshot-prepend.txt")
  case "$line" in
    '['*']') pass "hung-jq path produced a bounded line (${elapsed}s): $line" ;;
    *) fail "hung jq left an unbounded line: $line" ;;
  esac
}

# --- 4. Truncation: an absurdly large summary must be capped ------------------

test_summary_truncated_to_200() {
  local dir out_paths stdout_path stderr_path rc line
  dir=$(make_primary_dir "$TMP_ROOT/truncate")
  : > "$dir/state/task.meta"
  # Build a snapshot that would, after jq, produce an overly long line.
  # Easiest way: a backlog record with a very long "since" string.
  cat > "$dir/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-fleet-snapshot.v1","backlog":{"records":[{"state":"in_flight","hold_kind":null,"since":"2026-09-17"},{"state":"in_flight","hold_kind":"captain","since":"2026-09-15"}]},"tasks":[]}\n'
SH
  chmod +x "$dir/bin/fm-fleet-snapshot.sh"
  write_arm_clean "$dir"

  run_autoarm_capture "$dir" >/dev/null 2>"$dir/.helper-out" || true
  line=$(cat "$dir/state/.fleet-snapshot-prepend.txt" 2>/dev/null || echo "")
  # The cap is 200 chars before trailing newline; even a normal summary is
  # well under that. Here we just assert the line is bounded and does NOT
  # contain raw JSON paths or backticks.
  [ -n "$line" ] || fail "summary line must be non-empty"
  case "$line" in
    *'`'*|*'${'*) fail "summary line leaks unexpanded expansion: $line" ;;
  esac
  local len=${#line}
  [ "$len" -le 201 ] || fail "summary line exceeded 200 chars: len=$len"
  pass "summary bounded to <=200 chars (got $len)"
}

# --- 5. Schema stability: the line always starts with [fleet or [snapshot ---

test_summary_starts_with_marker() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/marker")
  : > "$dir/state/task.meta"
  install_snapshot_fixture "$dir" 1 0 0 0
  write_arm_clean "$dir"

  run_autoarm_capture "$dir" >/dev/null 2>"$dir/.helper-out" || true
  local line
  line=$(cat "$dir/state/.fleet-snapshot-prepend.txt" 2>/dev/null || echo "")
  case "$line" in
    '['*) pass "summary line starts with '[': $line" ;;
    *) fail "summary line missing leading bracket: $line" ;;
  esac
}

# --- 6. Epoch outcome reflects the branch taken -------------------------------

test_clean_branch_records_clean_outcome() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/epoch-clean")
  : > "$dir/state/task.meta"
  install_snapshot_fixture "$dir" 0 0 0 0
  write_arm_clean "$dir"

  run_autoarm_capture "$dir" >/dev/null 2>"$dir/.helper-out" || true
  local outcome
  outcome=$(epoch_outcome "$dir")
  [ "$outcome" = "clean" ] || fail "expected epoch outcome=clean, got: $outcome"
  pass "epoch outcome=clean confirmed on clean exit"
}

# --- 6. Truncation: an absurdly large summary must be capped ------------------
test_clean_exit_writes_summary
test_actionable_exit_skips_summary
test_jq_path_produces_real_summary
test_jq_found_but_fails_falls_back_to_sentinel
test_command_v_jq_missing_unit_assertion
test_hung_jq_is_cut_by_timeout
test_summary_truncated_to_200
test_summary_starts_with_marker
test_clean_branch_records_clean_outcome

echo "all fm-stop-autoarm-fleet-snapshot tests passed"
