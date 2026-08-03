#!/usr/bin/env bash
# tests/fm-watch-backstop.test.sh - the wake backstop for the daemon+argv
# session topology in which Claude Code's Stop-hook asyncRewake does NOT
# re-invoke the idle primary. Covers the trigger gates
# (bin/fm-watch-backstop.sh should-fire), the idempotency re-checks inside
# the inject path, the FM_WATCH_BACKSTOP_CONFIRM_INJECT test-isolation
# gate, the watcher's per-cycle tick (bin/fm-watch.sh's fm_backstop_tick),
# and the paused-defect routing in bin/fm-watch.sh's
# surface_nonterminal_stale.
#
# All tests are hermetic: they drive a scratch state dir under
# FM_TEST_TMP (mktemp), mock the backend primitives through PATH-shim
# fakebins, and never touch the live firstmate home or any real tmux
# pane. The test-isolation contract enforced by
# FM_WATCH_BACKSTOP_CONFIRM_INJECT is exercised explicitly: a probe that
# forgets to set the gate must abort cleanly without sending, even
# against an otherwise-valid epoch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BACKSTOP="$ROOT/bin/fm-watch-backstop.sh"
WATCH="$ROOT/bin/fm-watch.sh"
# DRAIN/CLASSIFY kept for symmetry with sibling suites; not directly
# invoked because this test exercises the backstop's own epoch/queue
# contract, not the drain's annotation flow.
# shellcheck disable=SC2034
DRAIN="$ROOT/bin/fm-wake-drain.sh"
# shellcheck disable=SC2034
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-backstop-tests)

# set_mtime <epoch> <file>: portable file mtime stamp in epoch seconds.
# Mirrors tests/fm-watch-triage.test.sh's helper.
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  f=$2
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# write_epoch <state> <outcome> <updated_at> [seq] [owner_pid]: write the
# four-field ledger exactly as bin/fm-claude-stop-autoarm.sh's write_epoch
# does. Defaults to seq=1 and owner_pid=999.
write_epoch() {  # <state> <outcome> <updated_at> [seq] [owner_pid]
  local state=$1 outcome=$2 updated_at=$3 seq=${4:-1} owner_pid=${5:-999}
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "$owner_pid" "$outcome" "$updated_at" \
    > "$state/.claude-autoarm-epoch"
}

# write_wake <state> <epoch> <seq> <kind> <key> <payload>: append one
# wake row and bump the seq counter, mirroring fm_wake_append's exact
# queue + .wake-queue.seq format.
write_wake() {  # <state> <epoch> <seq> <kind> <key> <payload>
  local state=$1 epoch=$2 seq=$3 kind=$4 key=$5 payload=$6
  printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$key" "$payload" \
    >> "$state/.wake-queue"
  printf '%s\n' "$seq" > "$state/.wake-queue.seq"
}

# Pure read: epoch_outcome / updated_at / seq — mirror the same regexes
# the backstop uses, kept here as a sanity check on the fixture.
epoch_field() {  # <state> <key>
  local state=$1 key=$2
  sed -n "s/^epoch=[0-9][0-9]* owner_pid=[0-9][0-9]* outcome=\\([^ ]*\\) updated_at=[0-9][0-9]*\$/\\1/p" \
    "$state/.claude-autoarm-epoch" 2>/dev/null | head -1
}

# --- should-fire: each trigger gate -----------------------------------------

test_should_fire_returns_zero_without_epoch() {
  local dir state
  dir=$(mktemp -d "$TMP_ROOT/no-epoch-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  out=$(FM_STATE_OVERRIDE="$state" FM_WATCH_BACKSTOP_GRACE=1 "$BACKSTOP" should-fire "$state" 2>/dev/null) || true
  [ "$out" = "0" ] || fail "should-fire without epoch must be 0, got '$out'"
  pass "should-fire returns 0 when no epoch is present"
}

test_should_fire_returns_zero_when_outcome_is_not_rewake() {
  local dir state
  dir=$(mktemp -d "$TMP_ROOT/no-rewake-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  write_epoch "$state" "clean" 1000
  out=$(FM_STATE_OVERRIDE="$state" FM_WATCH_BACKSTOP_GRACE=1 "$BACKSTOP" should-fire "$state" 2>/dev/null) || true
  [ "$out" = "0" ] || fail "should-fire with outcome=clean must be 0, got '$out'"
  pass "should-fire returns 0 when outcome is not rewake"
}

test_should_fire_returns_zero_when_grace_not_elapsed() {
  local dir state
  dir=$(mktemp -d "$TMP_ROOT/fresh-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  write_epoch "$state" "rewake" "$(date +%s)"
  out=$(FM_STATE_OVERRIDE="$state" FM_WATCH_BACKSTOP_GRACE=9999 "$BACKSTOP" should-fire "$state" 2>/dev/null) || true
  [ "$out" = "0" ] || fail "should-fire before grace must be 0, got '$out'"
  pass "should-fire returns 0 when grace has not elapsed"
}

test_should_fire_returns_zero_when_no_undelivered_row() {
  local dir state
  dir=$(mktemp -d "$TMP_ROOT/no-row-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD"
  # Empty queue: no rewake row, so should-fire must not stage an inject.
  : > "$state/.wake-queue"
  echo "0" > "$state/.wake-queue.seq"
  out=$(FM_STATE_OVERRIDE="$state" FM_WATCH_BACKSTOP_GRACE=1 "$BACKSTOP" should-fire "$state" 2>/dev/null) || true
  [ "$out" = "0" ] || fail "should-fire with no undelivered row must be 0, got '$out'"
  pass "should-fire returns 0 when the queue has no row >= the auto-arm's updated_at"
}

test_should_fire_returns_one_when_all_conditions_hold() {
  local dir state
  dir=$(mktemp -d "$TMP_ROOT/fire-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD" 5
  write_wake "$state" "$OLD" 5 "stale" "sess:0" "stale: sess:0 test message"
  out=$(FM_STATE_OVERRIDE="$state" FM_WATCH_BACKSTOP_GRACE=1 "$BACKSTOP" should-fire "$state" 2>/dev/null) || true
  [ "$out" = "1" ] || fail "should-fire with all conditions met must be 1, got '$out'"
  pass "should-fire returns 1 when rewake is older than grace and the queue has a matching row"
}

test_should_fire_returns_zero_when_consumed_marker_present() {
  local dir state OLD
  dir=$(mktemp -d "$TMP_ROOT/consumed-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD" 5
  write_wake "$state" "$OLD" 5 "stale" "sess:0" "stale: sess:0 test message"
  : > "$state/.watch-backstop-consumed-$OLD"
  out=$(FM_STATE_OVERRIDE="$state" FM_WATCH_BACKSTOP_GRACE=1 "$BACKSTOP" should-fire "$state" 2>/dev/null) || true
  [ "$out" = "0" ] || fail "should-fire must be 0 when a consumed marker exists, got '$out'"
  pass "should-fire returns 0 when a previous successful inject wrote the consumed marker"
}

# --- inject: confirm gate, idempotency, consume-on-success -----------------

test_inject_without_confirm_gate_aborts_and_preserves_row() {
  local dir state OLD
  dir=$(mktemp -d "$TMP_ROOT/no-confirm-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD" 5
  write_wake "$state" "$OLD" 5 "stale" "sess:0" "stale: sess:0 test message"
  # Run inject WITHOUT FM_WATCH_BACKSTOP_CONFIRM_INJECT. The row must
  # remain in the queue (consume is the LAST step, only after the
  # confirm gate), and the consumed marker must NOT exist.
  FM_WATCH_BACKSTOP_GRACE=1 "$BACKSTOP" inject "$state" 2>/dev/null || true
  [ -s "$state/.wake-queue" ] || fail "inject aborted at confirm gate removed the queue row"
  grep -F "stale: sess:0 test message" "$state/.wake-queue" >/dev/null \
    || fail "inject aborted at confirm gate mutated the queue row content"
  [ ! -e "$state/.watch-backstop-consumed-$OLD" ] \
    || fail "inject aborted at confirm gate must not write the consumed marker"
  pass "inject refuses to send without FM_WATCH_BACKSTOP_CONFIRM_INJECT and preserves the row"
}

test_inject_idempotency_epoch_outcome_changed_aborts_cleanly() {
  local dir state OLD
  dir=$(mktemp -d "$TMP_ROOT/idempotency-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD" 5
  write_wake "$state" "$OLD" 5 "stale" "sess:0" "stale: sess:0 test message"
  # Simulate asyncRewake finally landing between the watcher's should-fire
  # and the inject's re-check: rewrite the epoch with a newer outcome
  # AFTER seeding the row. The inject's first re-check passes (rewake
  # still), but the second re-check (after the row is located) sees
  # the newer outcome and aborts.
  unset TMUX_PANE HERDR_PANE_ID HERDR_SESSION HERDR_ENV
  PATH="$ROOT/bin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_WATCH_BACKSTOP_CONFIRM_INJECT=1 FM_WATCH_BACKSTOP_GRACE=1 \
    FM_SUPERVISOR_TARGET="hermetic-%0" FM_SUPERVISOR_BACKEND="tmux" \
    bash -c '
      set -u
      # shellcheck source=bin/fm-wake-lib.sh
      . "$1/bin/fm-wake-lib.sh"
      # shellcheck source=bin/fm-supervisor-target-lib.sh
      . "$1/bin/fm-supervisor-target-lib.sh"
      # shellcheck source=bin/fm-backend.sh
      . "$1/bin/fm-backend.sh"
      # shellcheck source=bin/fm-classify-lib.sh
      . "$1/bin/fm-classify-lib.sh"
      # shellcheck source=bin/fm-operational-input.sh
      . "$1/bin/fm-operational-input.sh"
      # shellcheck source=bin/fm-watch-backstop.sh
      . "$1/bin/fm-watch-backstop.sh"
      fm_backend_send_text_submit() { printf "empty\n"; }
      STATE="$2" EPOCH="$STATE/.claude-autoarm-epoch" \
        FM_WATCH_QUEUE="$STATE/.wake-queue" \
        FM_WATCH_QUEUE_LOCK="$STATE/.wake-queue.lock" \
      # Pre-flight: should-fire (run as a one-shot script) confirms
      # rewake is still observed.
      should_fire >/dev/null
      # Simulate the race: advance the epoch outcome to a newer seq
      # (consumed), as if asyncRewake had finally landed.
      OLD_TIME=$(sed -n "s/.*updated_at=\\([0-9][0-9]*\\)\$/\\1/p" "$STATE/.claude-autoarm-epoch")
      printf "epoch=6 owner_pid=999 outcome=consumed updated_at=%s\\n" "$(( OLD_TIME + 1 ))" \
        > "$STATE/.claude-autoarm-epoch"
      inject
    ' _ "$ROOT" "$state" 2>/dev/null || true
  # The row must still be in the queue because the abort happened at
  # the second re-check, BEFORE the consume step.
  [ -s "$state/.wake-queue" ] || fail "inject aborted at the race re-check removed the queue row"
  grep -F "stale: sess:0 test message" "$state/.wake-queue" >/dev/null \
    || fail "inject aborted at the race re-check mutated the queue row"
  [ ! -e "$state/.watch-backstop-consumed-$OLD" ] \
    || fail "inject aborted at the race re-check must not write the consumed marker"
  pass "inject aborts cleanly when the epoch outcome advances mid-flight (asyncRewake race)"
}

test_inject_consumes_row_and_marks_epoch_on_confirmed_delivery() {
  local dir state OLD
  dir=$(mktemp -d "$TMP_ROOT/confirmed-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD" 5
  write_wake "$state" "$OLD" 5 "stale" "sess:0" "stale: sess:0 test message"
  # Source the backstop in a subshell and override the send-text-submit
  # function to report "empty" (confirmed delivery). This is hermetic:
  # NO real tmux call is made because the override shadows the function
  # BEFORE the inject path reaches it. PATH-shadowing is not enough
  # because fm_backend_send_text_submit is a sourced function, not a
  # subprocess binary.
  unset TMUX_PANE HERDR_PANE_ID HERDR_SESSION HERDR_ENV
  PATH="$ROOT/bin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_WATCH_BACKSTOP_CONFIRM_INJECT=1 FM_WATCH_BACKSTOP_GRACE=1 \
    FM_SUPERVISOR_TARGET="hermetic-%0" FM_SUPERVISOR_BACKEND="tmux" \
    bash -c '
      set -u
      # shellcheck source=bin/fm-wake-lib.sh
      . "$1/bin/fm-wake-lib.sh"
      # shellcheck source=bin/fm-supervisor-target-lib.sh
      . "$1/bin/fm-supervisor-target-lib.sh"
      # shellcheck source=bin/fm-backend.sh
      . "$1/bin/fm-backend.sh"
      # shellcheck source=bin/fm-classify-lib.sh
      . "$1/bin/fm-classify-lib.sh"
      # shellcheck source=bin/fm-operational-input.sh
      . "$1/bin/fm-operational-input.sh"
      # shellcheck source=bin/fm-watch-backstop.sh
      . "$1/bin/fm-watch-backstop.sh"
      # Override the send primitive to report confirmed delivery. The
      # real one would call into tmux; this returns "empty" without any
      # subprocess, so the test is hermetic and never reaches the live
      # tmux server.
      fm_backend_send_text_submit() { printf "empty\n"; }
      STATE="$2" EPOCH="$STATE/.claude-autoarm-epoch" \
        FM_WATCH_QUEUE="$STATE/.wake-queue" \
        FM_WATCH_QUEUE_LOCK="$STATE/.wake-queue.lock" \
        inject
    ' _ "$ROOT" "$state" 2>/dev/null || true
  [ ! -s "$state/.wake-queue" ] || {
    echo "queue after confirmed inject:"; cat "$state/.wake-queue" >&2
    fail "confirmed inject did not consume the row from the queue"
  }
  [ -e "$state/.watch-backstop-consumed-$OLD" ] \
    || fail "confirmed inject did not write the consumed marker"
  [ "$(epoch_field "$state" consumed)" = "consumed" ] \
    || fail "confirmed inject did not rewrite the epoch outcome to consumed"
  pass "inject with a confirmed delivery consumes the row and marks the epoch consumed"
}

# --- fire: spawns a detached bash task -------------------------------------

test_fire_spawns_detached_inject_with_confirm_flag() {
  local dir state OLD fakebin
  dir=$(mktemp -d "$TMP_ROOT/fire-spawn-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD" 5
  write_wake "$state" "$OLD" 5 "stale" "sess:0" "stale: sess:0 test message"
  # Build a fake tmux that ALWAYS reports an empty composer (so the
  # backstop's real fm_backend_tmux_send_text_submit considers delivery
  # confirmed) and silently accepts any send-keys call (so a fake
  # target is fine). This is the only subprocess the backstop's
  # inject touches directly, so PATH-shadowing it is sufficient.
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  capture-pane)
    # fm_tmux_composer_state needs this to find the composer box; return
    # nothing so the "no box found" path uses the row fallback. With an
    # empty row the classifier returns "empty" (no text, no border).
    exit 0 ;;
  display-message)
    # fm_tmux_composer_state asks for #{cursor_y} specifically. If the
    # format string contains cursor_y, return 0 (top row, no text) so
    # the row-classifier sees an empty line and reports "empty". Other
    # format strings get a benign string for default-pane reads.
    for arg in "$@"; do
      case "$arg" in
        *cursor_y*) printf '0\n'; exit 0 ;;
      esac
    done
    printf 'hermetic-pane\n'
    exit 0 ;;
  list-windows) printf '0\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Override supervisor discovery so the inject targets our fake pane
  # (NEVER the captain's live $TMUX_PANE). Unset the env vars the
  # discovery walks, then pin FM_SUPERVISOR_TARGET explicitly.
  unset TMUX_PANE HERDR_PANE_ID HERDR_SESSION HERDR_ENV
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_WATCH_BACKSTOP_GRACE=1 \
    FM_SUPERVISOR_TARGET="hermetic-%0" FM_SUPERVISOR_BACKEND="tmux" \
    "$BACKSTOP" fire "$state" 2>/dev/null || true
  # The spawn is setsid + &. Wait up to 30 ticks for the child to do
  # its work: consume the row, write the consumed marker, rewrite the
  # epoch with outcome=consumed.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ ! -s "$state/.wake-queue" ] && [ -e "$state/.watch-backstop-consumed-$OLD" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  # The detached inject ran the full path: queue consumed, marker
  # written, epoch outcome rewritten to consumed. A working spawn +
  # confirm flag + supervisor target pin is exactly what "fire" must
  # produce.
  [ ! -s "$state/.wake-queue" ] \
    || { echo "queue:"; cat "$state/.wake-queue" >&2; fail "fire-spawned inject did not consume the row"; }
  [ -e "$state/.watch-backstop-consumed-$OLD" ] \
    || fail "fire-spawned inject did not write the consumed marker"
  [ "$(epoch_field "$state" consumed)" = "consumed" ] \
    || fail "fire-spawned inject did not rewrite the epoch outcome to consumed"
  pass "fire spawns a detached inject child that runs the full consume+send+mark path"
}

test_fire_disabled_via_env_var() {
  local dir state OLD fakebin sentinel
  dir=$(mktemp -d "$TMP_ROOT/fire-disabled-XXXXXX"); state="$dir/state"; mkdir -p "$state"
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD" 5
  write_wake "$state" "$OLD" 5 "stale" "sess:0" "stale: sess:0 test message"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  sentinel="$dir/invocations.log"
  : > "$sentinel"
  cat > "$fakebin/fm-watch-backstop.sh" <<SH
#!/usr/bin/env bash
printf 'called: %s\\n' "\$1" >> "$sentinel"
exit 0
SH
  chmod +x "$fakebin/fm-watch-backstop.sh"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_BACKSTOP_GRACE=1 FM_WATCH_BACKSTOP_DISABLE=1 \
    "$BACKSTOP" fire "$state" 2>/dev/null || true
  for _ in 1 2 3 4 5; do sleep 0.1; done
  [ ! -s "$sentinel" ] || {
    echo "invocations:"; cat "$sentinel" >&2
    fail "FM_WATCH_BACKSTOP_DISABLE=1 must suppress the fire spawn"
  }
  pass "fire respects FM_WATCH_BACKSTOP_DISABLE=1 and does not spawn"
}

# --- watcher integration: per-cycle tick ----------------------------------

# Drive a real watcher subprocess through a single cycle, with a fake
# helper that records the should-fire + fire calls. The watcher exits
# naturally on the actionable wake; we verify the backstop was triggered
# before exit.
test_watcher_calls_backstop_on_outcome_rewake() {
  local dir state fakebin out capture_file window OLD
  dir=$(mktemp -d "$TMP_ROOT/watcher-fire-XXXXXX"); state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-backstop"
  # Pane content is "idle" so the watcher will eventually emit a stale
  # wake and exit (the backstop is one of the per-cycle checks; the
  # normal stale path is what triggers an exit).
  printf 'idle\n' > "$capture_file"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  list-windows) printf '%s\n' "${window#*:}"; exit 0 ;;
  capture-pane) cat "$capture_file" 2>/dev/null; exit 0 ;;
  display-message) printf 'fakepane\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Real fake fm-crew-state.
  make_fake_crew_state "$fakebin" >/dev/null
  # Seed the epoch with an aged rewake outcome (200s old) and a wake row.
  OLD=$(( $(date +%s) - 200 ))
  write_epoch "$state" "rewake" "$OLD" 5
  write_wake "$state" "$OLD" 5 "stale" "sess:0" "stale: sess:0 test message"
  # Backstop stub that records calls.
  local sentinel="$dir/backstop-calls.log"
  : > "$sentinel"
  cat > "$fakebin/fm-watch-backstop.sh" <<SH
#!/usr/bin/env bash
printf 'called: %s state=%s\\n' "\$1" "\${2:-}" >> "$sentinel"
case "\$1" in
  should-fire) echo 0 ;;  # disable the actual inject; the watcher is
                            # what we're testing.
esac
exit 0
SH
  chmod +x "$fakebin/fm-watch-backstop.sh"
  # meta for the crew so window_to_task resolves.
  printf 'window=%s\nkind=ship\n' "$window" > "$state/backstop.meta"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_BACKSTOP_BIN="$fakebin/fm-watch-backstop.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_BACKSTOP_GRACE=1 \
    "$WATCH" > "$out" 2>&1 &
  pid=$!
  # Wait up to 30 ticks for the watcher to either exit (actionable stale)
  # or the call to register. 1 tick = 0.1s.
  for _ in $(seq 1 30); do
    [ -s "$sentinel" ] && break
    sleep 0.1
  done
  # The watcher may take a couple cycles to settle; if it surfaced a
  # stale wake it exits, which is the normal path the brief expects.
  # We just need to assert the backstop was consulted at least once.
  grep -F "called: should-fire" "$sentinel" >/dev/null \
    || { reap "$pid" 2>/dev/null || true; cat "$sentinel" "$out" >&2; fail "watcher did not consult fm-watch-backstop.sh should-fire on the rewake cycle"; }
  reap "$pid" 2>/dev/null || true
  pass "watcher consults fm-watch-backstop.sh on the rewake cycle"
}

test_watcher_does_not_call_fire_when_conditions_absent() {
  local dir state fakebin out capture_file window
  dir=$(mktemp -d "$TMP_ROOT/watcher-nofire-XXXXXX"); state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-backstop-quiet"
  printf 'working: still chugging\n' > "$capture_file"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  list-windows) printf '%s\n' "${window#*:}"; exit 0 ;;
  capture-pane) cat "$capture_file" 2>/dev/null; exit 0 ;;
  display-message) printf 'fakepane\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # No epoch written: should-fire must be 0 and fire must not be called.
  local sentinel="$dir/backstop-calls.log"
  : > "$sentinel"
  cat > "$fakebin/fm-watch-backstop.sh" <<SH
#!/usr/bin/env bash
printf 'called: %s\\n' "\$1" >> "$sentinel"
case "\$1" in
  should-fire) echo 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/fm-watch-backstop.sh"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_BACKSTOP_BIN="$fakebin/fm-watch-backstop.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  pid=$!
  # Give the watcher a couple cycles to make the call; then probe.
  for _ in $(seq 1 20); do sleep 0.1; done
  grep -F "called: fire" "$sentinel" >/dev/null \
    && { reap "$pid" 2>/dev/null || true; cat "$sentinel" "$out" >&2; fail "watcher called fire on a quiet cycle without a rewake"; }
  reap "$pid" 2>/dev/null || true
  pass "watcher does not call fire when no rewake is pending"
}

# --- paused defect: surface_nonterminal_stale routes through handle_paused_stale

# source the watcher (functions only; not the runtime) and the
# classifier so we can call the internal surface_nonterminal_stale
# function directly with a scratch state. The watcher is sourceable
# because its main entry is guarded by [ "${BASH_SOURCE[0]}" != "$0" ].
test_surface_nonterminal_stale_paused_uses_long_cadence() {
  local dir state fakebin window key out
  dir=$(mktemp -d "$TMP_ROOT/paused-defect-XXXXXX"); state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  window="test:fm-paused-defect"
  # Make a meta and a paused status; prime the .seen-* so the
  # signal-scan path does not also fire (it is out of scope for this
  # test).
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused.status"
  seen_sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$state/paused.status"; else stat -c '%s:%Y' "$state/paused.status"; fi)
  printf '%s' "$seen_sig" > "$state/.seen-paused_status"
  # The watcher uses key=`printf '%s' "$win" | tr ':/.' '___'` for the
  # .paused-* markers. Pre-set them as "never re-surfaced" so
  # handle_paused_stale's first-sight path fires the recheck.
  key=$(printf '%s' "$window" | tr ':/.' '___')
  out="$dir/stale.out"
  # Source the watcher's library surface (the test mirrors how other
  # triage tests exercise the same functions). We need a fake crew
  # state too because the main loop's wedge-timer path touches it.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · fake default'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=9999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    bash -c '
      set -u
      SCRIPT_DIR="'"$ROOT"'/bin"
      # shellcheck source=bin/fm-classify-lib.sh
      . "$SCRIPT_DIR/fm-classify-lib.sh"
      # Source the watcher. It will not run the main loop because
      # BASH_SOURCE[0] is the test, not the watcher.
      # shellcheck source=bin/fm-watch.sh
      . "$SCRIPT_DIR/fm-watch.sh"
      # Hand-craft the same state the pane-staleness backbone uses on
      # a non-terminal new-hash path: pre-set the hash so count=1
      # does not even matter here (we go straight to
      # surface_nonterminal_stale).
      hash_text() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d" " -f1; fi; }
      tail40="idle awaiting external"
      h=$(printf "%s" "$tail40" | hash_text)
      # The fixture here is the FUNCTION-LEVEL surface: surface_nonterminal_stale
      # runs in the same context the watcher does. We exercise it
      # directly.
      surface_nonterminal_stale "'"$window"'" "$h"
    ' > "$out" 2>&1
  unset FM_FAKE_CREW_STATE
  # The fix: a paused status now routes through handle_paused_stale
  # with the first-sight fire flag, so the LIVE-AGENT first sight
  # surfaces an ANNOTATED wake (not a bare "stale: <win>") exactly
  # once. PAUSE_RESURFACE_SECS=9999 means no recheck fires inside
  # the test window, so the queue must carry exactly one row with
  # the paused annotation - not the bare text.
  [ -e "$state/.paused-$key" ] \
    || { echo "out:"; cat "$out" >&2; fail "a paused stale did not set the .paused-<key> marker"; }
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -eq 1 ] \
    || { echo "queue:"; cat "$state/.wake-queue" >&2; fail "a paused stale should fire exactly one annotated wake, got $wakes"; }
  # The wake reason must include the paused annotation - the bare
  # "stale: <win>" path is the bug this fix removes.
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || { echo "queue:"; cat "$state/.wake-queue" >&2; fail "a paused stale emitted a bare-stale wake without the paused annotation"; }
  pass "surface_nonterminal_stale on a paused status routes through handle_paused_stale and fires the first-sight annotated wake"
}

test_surface_nonterminal_stale_unpaused_keeps_bare_path() {
  local dir state fakebin window out
  dir=$(mktemp -d "$TMP_ROOT/paused-bypass-XXXXXX"); state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  window="test:fm-paused-bypass"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/bypass.meta"
  printf 'working: chugging along\n' > "$state/bypass.status"
  seen_sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$state/bypass.status"; else stat -c '%s:%Y' "$state/bypass.status"; fi)
  printf '%s' "$seen_sig" > "$state/.seen-bypass_status"
  out="$dir/stale.out"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · fake default'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=9999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    bash -c '
      set -u
      SCRIPT_DIR="'"$ROOT"'/bin"
      # shellcheck source=bin/fm-classify-lib.sh
      . "$SCRIPT_DIR/fm-classify-lib.sh"
      # shellcheck source=bin/fm-watch.sh
      . "$SCRIPT_DIR/fm-watch.sh"
      hash_text() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d" " -f1; fi; }
      tail40="idle"
      h=$(printf "%s" "$tail40" | hash_text)
      surface_nonterminal_stale "'"$window"'" "$h"
    ' > "$out" 2>&1
  unset FM_FAKE_CREW_STATE
  # A non-paused status still uses the bare-stale path. The wake queue
  # should carry one row.
  [ -s "$state/.wake-queue" ] \
    || { echo "out:"; cat "$out" >&2; fail "a non-paused status did not produce a bare stale wake"; }
  grep -F "stale: $window" "$state/.wake-queue" >/dev/null \
    || { echo "queue:"; cat "$state/.wake-queue" >&2; fail "the bare wake reason was not the unchanged bare-stale text"; }
  pass "surface_nonterminal_stale on a non-paused status still uses the bare-stale path"
}

# --- driver ----------------------------------------------------------------

# Each test function returns via fail() (exit 1) or pass() (echo ok - name).
# Run them in order; the first failure aborts the rest. Order is the
# test_* definition order above, mirrored here so a flake lands on the
# least-disruptive test.
test_should_fire_returns_zero_without_epoch
test_should_fire_returns_zero_when_outcome_is_not_rewake
test_should_fire_returns_zero_when_grace_not_elapsed
test_should_fire_returns_zero_when_no_undelivered_row
test_should_fire_returns_one_when_all_conditions_hold
test_should_fire_returns_zero_when_consumed_marker_present
test_inject_without_confirm_gate_aborts_and_preserves_row
test_inject_idempotency_epoch_outcome_changed_aborts_cleanly
test_inject_consumes_row_and_marks_epoch_on_confirmed_delivery
test_fire_spawns_detached_inject_with_confirm_flag
test_fire_disabled_via_env_var
test_watcher_calls_backstop_on_outcome_rewake
test_watcher_does_not_call_fire_when_conditions_absent
test_surface_nonterminal_stale_paused_uses_long_cadence
test_surface_nonterminal_stale_unpaused_keeps_bare_path
echo "ok - all fm-watch-backstop tests passed"
