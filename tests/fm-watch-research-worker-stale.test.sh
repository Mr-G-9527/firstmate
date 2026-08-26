#!/usr/bin/env bash
# tests/fm-watch-research-worker-stale.test.sh - direct unit test of
# wedge_timer_check. Confirms the post-submit FM_RESEARCH_WORKER guard
# added in bin/fm-watch.sh:wedge_timer_check suppresses escalation and
# clears bookkeeping when data/executor-jobs/<corr>.worker.log already
# carries `state: done`, while leaving running panes and non-research
# panes unaffected. Regression observed 2026-08-20 / 2026-08-21 when
# the wedge detector kept escalating "stale: ... possible wedge,
# escalation N" against post-submit research worker panes whose
# dispatcher submit had already landed.
#
# The function is tested directly (not via the watcher's main loop)
# because the watcher's boot path itself runs PR-check migration,
# watcher-lock acquisition, and a half-dozen other guards; isolating
# the wedge_timer_check behavior lets us pin only what this fix owns.
#
# Three behavioral pins:
#  1. post-submit FM_RESEARCH_WORKER (worker.log carries `state: done`):
#     wedge_timer_check MUST clear the since/escalation bookkeeping and
#     MUST NOT append a stale wake.
#  2. running FM_RESEARCH_WORKER (worker.log absent or no `state: done`):
#     wedge_timer_check MUST emit the wedge-stale wake as it does today.
#  3. non-research pane (window name not `fm-executor-<corr>`):
#     wedge_timer_check MUST emit a stale wake even when an unrelated
#     `state: done` line appears in worker.log.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# --- mocks for wedge_timer_check's dependencies ---------------------------
# wedge_timer_check calls:
#   triage_log "$label ..."      -> append to $FM_TRIAGE_LOG
#   fm_wake_append stale "$win" ... -> append to $STATE/.wake-queue
#   rm -f "$since_file" "$escalation_file"
# All are stubbed here.

TMP_ROOT=$(fm_test_tmproot fm-watch-research-worker-stale-tests)

extract_wedge_timer_check() {  # extract wedge_timer_check body from bin/fm-watch.sh
  awk '/^wedge_timer_check\(\) \{/{flag=1} flag{print} /^}$/{ if (flag) exit }' \
    "$ROOT/bin/fm-watch.sh"
}

# Source the function in a clean subshell with the mocked helpers, then
# invoke it via the harness; this keeps each test isolated.
run_wedge_timer_check() {  # <fixture_dir> <window> <since_secs_ago> <expect_escalate> <expect_clear>
  local fixture_dir=$1 win=$2 since_ago=$3 expect_escalate=$4 expect_clear=$5
  local state="$fixture_dir/state" key since past triage_log wake_queue
  mkdir -p "$state"
  triage_log="$state/.watch-triage.log"
  wake_queue="$state/.wake-queue"
  : > "$triage_log"
  : > "$wake_queue"

  # Derive the watcher's stale bookkeeping key from the window name.
  # The watcher's rule: tr ':/.' '___' applied to the window name.
  key="${win//:/_}"; key="${key//\//_}"; key="${key//./_}"

  past=$(( $(date +%s) - since_ago ))
  printf '%s\n' "$past" > "$state/.stale-since-$key"
  printf '%s\n' 0 > "$state/.wedge-escalations-$key"

  # Run wedge_timer_check in a child shell with the mocks bound.
  (
    # Mocks bound to the test-local paths so we can inspect them after.
    TRIAGE_LOG="$triage_log"
    WAKE_QUEUE_FILE="$wake_queue"

    triage_log() { printf '[triage] %s\n' "$1" >> "$TRIAGE_LOG"; }
    fm_wake_append() {
      local kind=$1 key2=$2 reason=$3 sep=$'\t'
      printf '%s%s%s%s%s\n' "$kind" "$sep" "$key2" "$sep" "$reason" >> "$WAKE_QUEUE_FILE"
    }
    wake() { :; }

    FM_HOME="$fixture_dir"
    STALE_ESCALATE_SECS=2
    FM_WEDGE_DEMAND_INSPECT_COUNT=3
    # shellcheck disable=SC1090
    eval "$(extract_wedge_timer_check)"
    # Defensive: if the function definition accidentally picked up a
    # follower via the awk extractor, drop anything defined past it.
    unset -f hash_pane 2>/dev/null || true

    wedge_timer_check "$win" \
      "$state/.stale-since-$key" \
      "test label" \
      "$state/.wedge-escalations-$key"

    # Make sure we don't accidentally leak local declarations.
    unset win since_file label escalation_file since age n reason corr worker_log
  )

  local wakes emitted triage_after
  emitted=$(grep -c "^stale"$'\t'"$win" "$wake_queue" 2>/dev/null || true)
  emitted=${emitted:-0}
  triage_after=$(cat "$triage_log" 2>/dev/null)
  local since_present escal_present
  [ -e "$state/.stale-since-$key" ] && since_present=1 || since_present=0
  [ -e "$state/.wedge-escalations-$key" ] && escal_present=1 || escal_present=0

  local rc=0
  if [ "$expect_escalate" -eq 1 ] && [ "$emitted" -lt 1 ]; then
    echo "FAIL: expected >=1 stale wake for $win, got $emitted. triage: $triage_after" >&2
    rc=1
  fi
  if [ "$expect_escalate" -eq 0 ] && [ "$emitted" -ne 0 ]; then
    echo "FAIL: expected 0 stale wakes for $win, got $emitted. triage: $triage_after" >&2
    rc=1
  fi
  # expect_clear semantics:
  #   1: post-submit guard MUST have run (rm-f cleared both .stale-since
  #      AND .wedge-escalations files).
  #   0: legacy escalation path MAY have cleared .stale-since (the
  #      wedge_timer_check body removes it after firing), but MUST NOT
  #      have cleared .wedge-escalations (the counter file is bumped, not
  #      removed).
  if [ "$expect_clear" -eq 1 ] && [ "$since_present" -ne 0 ]; then
    echo "FAIL: expected .stale-since-$key cleared for $win, still present. triage: $triage_after" >&2
    rc=1
  fi
  if [ "$expect_clear" -eq 1 ] && [ "$escal_present" -ne 0 ]; then
    echo "FAIL: expected .wedge-escalations-$key cleared for $win, still present. triage: $triage_after" >&2
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "ok - wedge_timer_check on $win (expect_wakes=$expect_escalate, expect_clear=$expect_clear) emitted=$emitted, since_present=$since_present, escal_present=$escal_present"
  fi
  return "$rc"
}

# Pin 1: post-submit FM_RESEARCH_WORKER pane must NOT escalate and MUST
# clear bookkeeping. Plant worker.log with `state: done` and an
# arbitrary submission marker.
test_post_submit_research_worker_is_silent() {
  local fixture_dir corr win key
  corr="dogfood-0820-ov-w2-findings-verify"
  win="firstmate:fm-executor-$corr"
  fixture_dir="$TMP_ROOT/postsubmit-$corr"
  mkdir -p "$fixture_dir/data/executor-jobs"
  printf 'submission_id=sub_2026-08-20T11:10:55Z_abcdef012345\nstate: done\nreport_path=/tmp/report.md\n' \
    > "$fixture_dir/data/executor-jobs/$corr.worker.log"
  # Run wedge_timer_check with since-file backed 240s; without the guard
  # this would escalate and bump the counter.
  if ! run_wedge_timer_check "$fixture_dir" "$win" 240 0 1; then
    fail "post-submit FM_RESEARCH_WORKER did NOT silent; review earlier diagnostics"
  fi
  rm -rf "$fixture_dir"
}

# Pin 2: running FM_RESEARCH_WORKER pane (worker.log empty) MUST still
# escalate. Regression guard.
test_running_research_worker_still_wedges() {
  local fixture_dir corr win
  corr="dogfood-0820-ov-w3-accept-gate"
  win="firstmate:fm-executor-$corr"
  fixture_dir="$TMP_ROOT/running-$corr"
  mkdir -p "$fixture_dir/data/executor-jobs"
  : > "$fixture_dir/data/executor-jobs/$corr.worker.log"
  # expect_wakes=1 (escalation fires); expect_clear=0 (legacy wedge path
  # only clears .stale-since; .wedge-escalations is bumped but not removed).
  if ! run_wedge_timer_check "$fixture_dir" "$win" 240 1 0; then
    fail "running FM_RESEARCH_WORKER did NOT escalate; regression"
  fi
  rm -rf "$fixture_dir"
}

# Pin 3: non-research pane (window name not `fm-executor-<corr>`) MUST
# still wedge even though an unrelated worker.log with `state: done`
# exists. Regression guard against over-shoot.
test_non_research_pane_unaffected() {
  local fixture_dir win
  win="firstmate:foo"
  fixture_dir="$TMP_ROOT/nonresearch"
  mkdir -p "$fixture_dir/data/executor-jobs"
  # A worker.log with state:done exists, but for a different corr.
  printf 'state: done\nsubmission_id=other\n' \
    > "$fixture_dir/data/executor-jobs/fm-executor-something-else.worker.log"
  if ! run_wedge_timer_check "$fixture_dir" "$win" 240 1 0; then
    fail "non-research pane failed to wedge; regression"
  fi
  rm -rf "$fixture_dir"
}

# Pin 4 (extra hardening): single-poll idempotency. Even if some poll
# earlier suppressed the wake, the since-file must be cleared AND a
# subsequent identical call must also not escalate. This guarantees
# future polls also stay silent for as long as worker.log carries
# `state: done`.
test_post_submit_is_idempotent_across_repeated_calls() {
  local fixture_dir corr win
  corr="dogfood-0821-ov-w2-lowq-triage"
  win="firstmate:fm-executor-$corr"
  fixture_dir="$TMP_ROOT/idem-$corr"
  mkdir -p "$fixture_dir/data/executor-jobs"
  printf 'state: done\nsubmission_id=sub_2026-08-21T14:55:41Z_z\n' \
    > "$fixture_dir/data/executor-jobs/$corr.worker.log"
  if ! run_wedge_timer_check "$fixture_dir" "$win" 240 0 1; then
    fail "first call did not stay silent"
  fi
  # Second call: plant the since-file again (the first call cleared it),
  # so a subsequent wedge_timer_check would naively escalate.
  local state="$fixture_dir/state" key
  key="firstmate_fm-executor-$corr"
  printf '%s\n' "$(( $(date +%s) - 240 ))" > "$state/.stale-since-$key"
  if ! run_wedge_timer_check "$fixture_dir" "$win" 240 0 1; then
    fail "second call did not stay silent"
  fi
  rm -rf "$fixture_dir"
}

test_post_submit_research_worker_is_silent
test_running_research_worker_still_wedges
test_non_research_pane_unaffected
test_post_submit_is_idempotent_across_repeated_calls
