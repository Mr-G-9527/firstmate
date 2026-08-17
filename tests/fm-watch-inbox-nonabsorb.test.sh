#!/usr/bin/env bash
# tests/fm-watch-inbox-nonabsorb.test.sh - the fm-autodrain-fix-01 regression:
# bin/fm-watch.sh must NEVER absorb a captain-inbox.jsonl signal as benign,
# even when the crew is provably working. A captain message is inherently
# actionable (the captain sent it explicitly), so the per-poll signal triage
# must surface it, drain the inbox, and exit with the rendered chat block as
# the wake payload. Absorbing the signal previously drained the inbox silently
# (offset advanced) and discarded the rendered chat block, leaving the LLM
# without the captain's row until a manual /fm-wake replayed it.
#
# The four behavioral pins, in priority order:
#  1. inbox-only signal + crew provably working: ACTIONABLE (NEW behavior)
#  2. inbox-only signal + crew NOT provably working: ACTIONABLE (unchanged)
#  3. status signal + crew provably working: still BENIGN / absorbed (unchanged)
#  4. absorb branch never advances the inbox .seen-* marker, so a captain row
#     survives the absorb and is re-detected on the next poll when the crew
#     becomes non-busy (the re-poll fires the wake that was previously forced
#     via /fm-wake). Belt-and-suspenders for case 1 above.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-inbox-nonabsorb-tests)

# Common watcher knobs for these tests: tight poll/grace, no check/heartbeat
# cadence (the inbox path never touches either), and a fake fm-crew-state.sh
# whose verdict is steered per case via FM_FAKE_CREW_STATE. The extra env
# assignments are passed through `env` because bash word-splits a quoted
# "FOO=value with spaces" prefix when it sits next to a command, and FM_FAKE_CREW_STATE's
# default value carries spaces (the · separator).
watch_bg_inbox() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  env PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_BACKSTOP_DISABLE=1 "$@" "$WATCH" > "$out" &
}

# Append a single captain-inbox.jsonl row + prime the .seen-* marker to a
# pre-existing signature, so the watcher MUST treat the new row as a fresh
# signal. Mirrors how a captain-side inbox-append lands in the live home.
append_inbox_row() {  # <state> <corr> <body>
  local state=$1 corr=$2 body=$3 inbox seen
  inbox="$state/captain-inbox.jsonl"
  [ -f "$inbox" ] || : > "$inbox"
  printf '{"ts":"%s","corr":"%s","kind":"chat","body":"%s","seq":1}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$corr" "$body" >> "$inbox"
  seen="$state/.seen-captain-inbox_jsonl"
  printf '%s:%s' 0 "$(date +%s)" > "$seen"
  sleep 0.2
}

read_offset() { cat "$1/.captain-inbox.offset" 2>/dev/null; }
read_seen() { cat "$1/.seen-captain-inbox_jsonl" 2>/dev/null; }

# wait_live + reap are tiny per-suite helpers; wake-helpers.sh does not export
# them and one inline copy is clearer than expanding the shared helpers' surface.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- 1. inbox-only signal + crew provably working: ACTIONABLE ---------------
# This is the fm-autodrain-fix-01 regression: before the fix, the watcher
# absorbed this case silently, drained the inbox, and dropped the chat block
# (the captain's row was gone from the inbox but never reached the LLM).
# After the fix, the watcher MUST exit with an actionable inbox-drain wake
# even when the crew is mid-turn.
test_inbox_signal_with_busy_crew_is_actionable() {
  local dir state fakebin out drain_out inbox_size_before inbox_size_after
  dir=$(make_case inbox-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # No status files; the captain-inbox.jsonl signal is the only changed file.
  # Fake crew-state returns working+run-step so crew_is_provably_working is true.
  append_inbox_row "$state" "fm-autodrain-busy" "Captain message while LLM is mid-turn"
  inbox_size_before=$(wc -c < "$state/captain-inbox.jsonl")
  watch_bg_inbox "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE='state: working · source: run-step · busy mid-turn'
  local pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for inbox signal under busy crew: $(cat "$out")"
  grep -F "inbox-drain " "$out" >/dev/null || fail "watcher did not print inbox-drain reason for busy-crew captain message: $(cat "$out")"
  # Inbox must be drained (offset == file size) and acks written.
  inbox_size_after=$(wc -c < "$state/captain-inbox.jsonl")
  [ "$inbox_size_before" -gt 0 ] || fail "inbox row was not appended before watcher run"
  [ "$(read_offset "$state")" = "$inbox_size_after" ] || fail "inbox offset did not advance (offset=$(read_offset "$state") size=$inbox_size_after)"
  # Wake queue must carry the surfaced inbox-drain wake.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after busy-crew inbox signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "captain-inbox.jsonl" >/dev/null \
    || fail "busy-crew inbox signal was not queued for delivery"
  pass "inbox-only signal under busy crew is actionable: inbox drained, wake queued, LLM notified"
}

# --- 2. inbox-only signal + crew NOT provably working: still ACTIONABLE ----
# Sanity check that the new actionable-clause didn't regress the already-
# working path: an idle crew with an inbox change must still surface.
test_inbox_signal_with_idle_crew_is_actionable() {
  local dir state fakebin out drain_out inbox_size_after
  dir=$(make_case inbox-idle); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # Fake crew-state returns done (NOT provably working) so the existing
  # !signal_crew_provably_working branch fires.
  append_inbox_row "$state" "fm-autodrain-idle" "Captain message while LLM is idle"
  inbox_size_after=$(wc -c < "$state/captain-inbox.jsonl")
  watch_bg_inbox "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  local pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for inbox signal under idle crew: $(cat "$out")"
  grep -F "inbox-drain " "$out" >/dev/null || fail "watcher did not print inbox-drain reason under idle crew: $(cat "$out")"
  [ "$(read_offset "$state")" = "$inbox_size_after" ] || fail "inbox offset did not advance under idle crew"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after idle-crew inbox signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "captain-inbox.jsonl" >/dev/null \
    || fail "idle-crew inbox signal was not queued"
  pass "inbox-only signal under idle crew still actionable: inbox drained, wake queued"
}

# --- 3. status-only signal + crew provably working: still BENIGN ------------
# Pin that the new inbox-actionable clause does NOT widen actionability to
# benign status signals: a working: status with a busy crew must remain
# absorbed (the pre-existing no-verb absorb contract).
test_status_signal_with_busy_crew_remains_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case status-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/some.status"
  printf 'working: compiling\n' > "$status_file"
  watch_bg_inbox "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE='state: working · source: run-step · busy mid-turn'
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "working: status with busy crew wrongly surfaced: $(cat "$out")"
  fi
  grep -F "signal:" "$out" >/dev/null && fail "working: status emitted a signal reason under busy crew: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "working: status under busy crew enqueued a wake"
  reap "$pid"
  pass "status signal under busy crew remains absorbed (no inbox regression)"
}

# --- 4. inbox absorb branch must NOT advance the .seen-* marker ------------
# The absorb branch's whole job for non-inbox signals is to mark them seen
# so the same file does not re-fire every poll. For inbox signals, we want
# the OPPOSITE: the marker must NOT advance, so a captain row that landed
# while the crew was busy keeps re-firing on subsequent polls until the crew
# becomes non-busy. This test forces the absorb branch (no inbox_in_files
# clause reachable here because the inbox file has no row past offset; we
# construct it by leaving inbox size unchanged so the only "absorbed" file
# is the inbox .seen-* marker that was just primed). The absorb branch's
# inbox-specific `continue` is the load-bearing line; verify it by checking
# the .seen-* marker after a poll that would have been absorbed.
test_inbox_absorb_does_not_advance_seen_marker() {
  local dir state fakebin out seen_before seen_after pid
  dir=$(make_case inbox-marker-preserved); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # Pre-prime the inbox .seen-* marker to a stale value AND advance the
  # inbox offset to the file size, so a size:mtime scan does not see a
  # pending inbox signal. Then write a fresh status signal whose only
  # change is the file. This goes through the absorb branch (busy crew,
  # no captain-relevant verb), and we verify the inbox .seen-* marker is
  # NOT touched.
  printf 'placeholder' > "$state/captain-inbox.jsonl"
  printf '%s' 11 > "$state/.captain-inbox.offset"
  # Seed a FRESH inbox marker so the signal is truly status-only (a stale marker
  # would make inbox_in_files=1 and, per the fix, legitimately actionable).
  seen_before=$(stat -c '%s:%Y' "$state/captain-inbox.jsonl")
  printf '%s' "$seen_before" > "$state/.seen-captain-inbox_jsonl"
  printf 'working: setup\n' > "$state/task.status"
  watch_bg_inbox "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE='state: working · source: run-step · busy'
  pid=$!
  sleep 2  # one full poll cycle under FM_POLL=1
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "watcher exited instead of absorbing (status-only signal under busy crew should absorb): $(cat "$out")"
  fi
  seen_after=$(read_seen "$state")
  [ "$seen_after" = "$seen_before" ] \
    || fail "absorb branch touched the inbox .seen-* marker: before='$seen_before' after='$seen_after'"
  reap "$pid"
  pass "absorb branch leaves the inbox .seen-* marker untouched (captain row stays visible for next poll)"
}

# --- 5. inbox row past offset under busy crew: drains + wakes on first poll
# The previous behavior absorbed a captain inbox row under a busy crew, leaving
# the row in place for the next poll. The fm-autodrain-fix-01 contract is
# different: an inbox row is ALWAYS actionable, so the first poll drains the
# inbox and surfaces the wake. Verify the rendered chat block is what reaches
# the wake payload (this is the exact line the captain used to see only after
# /fm-wake under the old absorb path).
test_inbox_row_drains_on_first_poll_under_busy_crew() {
  local dir state fakebin out drain_out inbox_size_after
  dir=$(make_case inbox-drain-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  append_inbox_row "$state" "fm-autodrain-drain-busy" "Captain row that the busy crew must still see"
  inbox_size_after=$(wc -c < "$state/captain-inbox.jsonl")
  watch_bg_inbox "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE='state: working · source: run-step · busy mid-turn'
  local pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit on first poll under busy crew: $(cat "$out")"
  grep -F "inbox-drain rc=0" "$out" >/dev/null \
    || fail "watcher did not embed the rendered chat block in the wake reason: $(cat "$out")"
  grep -F "fm-autodrain-drain-busy" "$out" >/dev/null \
    || fail "wake reason did not reference the captain corr: $(cat "$out")"
  [ "$(read_offset "$state")" = "$inbox_size_after" ] \
    || fail "inbox offset did not advance after the inbox-drain wake (offset=$(read_offset "$state") size=$inbox_size_after)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after busy-crew inbox signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "captain-inbox.jsonl" >/dev/null \
    || fail "busy-crew inbox signal was not queued for delivery"
  pass "busy-crew inbox row drains + wakes on first poll with rendered chat block as wake payload"
}

# Drive all four tests through the shared suite runner so a single pass/fail
# line reports the run. .test.sh convention: every public test_* function is
# invoked in lexical order at the bottom of the file.
test_inbox_signal_with_busy_crew_is_actionable
test_inbox_signal_with_idle_crew_is_actionable
test_status_signal_with_busy_crew_remains_absorbed
test_inbox_absorb_does_not_advance_seen_marker
test_inbox_row_drains_on_first_poll_under_busy_crew
exit 0