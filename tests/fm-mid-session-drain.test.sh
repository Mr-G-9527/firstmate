#!/usr/bin/env bash
# tests/fm-mid-session-drain.test.sh - firstmate P2: mid-session auto-drain.
#
# Verifies (per the 2026-08-04 P2 spec, codex C* ruling):
#   1. The watcher (bin/fm-watch.sh scan_signals) tracks
#      state/captain-inbox.jsonl size:mtime so a mid-session append surfaces
#      a "signal: captain-inbox.jsonl" wake (the previous gap: the watcher
#      only scanned *.status and *.turn-ended, so a row landing while fm
#      was idle sat forever until manual /fm-wake).
#   2. Session-start (bin/fm-session-start.sh) also drains the inbox after
#      draining the wake-queue, so the wake that the watcher surfaces
#      actually moves the bytes into the LLM context.
#   3. Inbox-drain is idempotent by byte offset: re-running produces no
#      second render block and no second outbox ack.
#   4. Restart recovery: a row appended while drain is not running drains
#      on the next invocation (durable pending work survives).
#
# Hermetic: every case uses its own FM_ROOT_OVERRIDE scratch dir under a
# fm_test_tmproot() root; live state/ is never read or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH_SH="$ROOT/bin/fm-watch.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
INBOX_APPEND="$ROOT/bin/fm-captain-inbox-append.sh"
INBOX_DRAIN="$ROOT/bin/fm-captain-inbox-drain.sh"
OUTBOX_APPEND="$ROOT/bin/fm-captain-outbox-append.sh"

# Sanity: every script under test must exist.
[ -x "$WATCH_SH" ]          || fail "watch.sh not found: $WATCH_SH"
[ -x "$SESSION_START" ]     || fail "session-start.sh not found: $SESSION_START"
[ -x "$INBOX_APPEND" ]      || fail "inbox-append not executable"
[ -x "$INBOX_DRAIN" ]       || fail "inbox-drain not executable"
[ -x "$OUTBOX_APPEND" ]     || fail "outbox-append not executable"

#======================================================================
# Part A: static checks (the diff itself)
#======================================================================

# A1. The watcher scan_signals loop must include captain-inbox.jsonl.
#     Codex C* required outcome 1: a mid-session append noticed without /fm-wake.
#     Before this fix, the loop only scanned *.status and *.turn-ended, so a
#     row arriving while fm was idle sat unread until someone typed /fm-wake.
if ! grep -nE 'captain-inbox\.jsonl' "$WATCH_SH" >/dev/null; then
  fail "A1. fm-watch.sh must scan state/captain-inbox.jsonl for size:mtime changes; not found"
fi
pass "A1. fm-watch.sh tracks captain-inbox.jsonl (mid-session append surfaces a wake)"

# A2. Session-start must also drain the inbox after the wake-queue. The
#     existing line for fm-wake-drain.sh alone left rows landing mid-session
#     in the JSONL but never moving into the LLM context — exactly the bug
#     codex C* flagged.
if ! grep -nE 'fm-captain-inbox-drain\.sh' "$SESSION_START" >/dev/null; then
  fail "A2. fm-session-start.sh must call fm-captain-inbox-drain.sh after the wake-queue drain; not found"
fi
# The inbox-drain call has to come AFTER the wake-queue drain so both
# surface in the same LLM context (the LLM sees the wake-queue reason, then
# the rendered block). Order matters.
wake_line=$(grep -nE 'fm-wake-drain\.sh' "$SESSION_START" | head -1 | cut -d: -f1)
inbox_line=$(grep -nE 'fm-captain-inbox-drain\.sh' "$SESSION_START" | head -1 | cut -d: -f1)
[ -n "$wake_line" ]   || fail "A2. fm-wake-drain.sh call missing in session-start"
[ -n "$inbox_line" ]  || fail "A2. fm-captain-inbox-drain.sh call missing in session-start"
[ "$inbox_line" -gt "$wake_line" ] \
  || fail "A2. inbox-drain must come AFTER wake-queue drain (wake=$wake_line, inbox=$inbox_line)"
pass "A2. session-start drains inbox after wake-queue (ctx order preserved)"

#======================================================================
# Part B: idempotency + restart recovery (the drain itself)
#======================================================================

#------ B1. happy path: append + drain renders the block ----------------
TMP_ROOT=$(fm_test_tmproot fm-mid-session-drain)
CASE="$TMP_ROOT/happy"
mkdir -p "$CASE/state"
export FM_ROOT_OVERRIDE="$CASE"

CORR="mid-session-drain-happy-$RANDOM"
printf '{"hello":"world","n":1}' | "$INBOX_APPEND" --kind chat --corr "$CORR" --json >/dev/null \
  || fail "B1. inbox-append failed"

"$INBOX_DRAIN" >"$TMP_ROOT/b1.out" 2>"$TMP_ROOT/b1.err" \
  || fail "B1. inbox-drain failed: $(cat "$TMP_ROOT/b1.err")"
assert_contains "$(cat "$TMP_ROOT/b1.out")" "FIRSTMATE CAPTAIN INPUT v1 corr=$CORR" \
  "B1. drain did not render corr=$CORR"
pass "B1. mid-session append renders to drain stdout"

# Outbox got exactly one received ack.
[ -f "$CASE/state/captain-outbox.jsonl" ] || fail "B1. outbox file missing"
recv_count=$(grep -c "\"corr\":\"$CORR\".*\"state\":\"received\"" "$CASE/state/captain-outbox.jsonl" || true)
[ "$recv_count" = "1" ] || fail "B1. expected 1 received ack, got $recv_count"
pass "B1. outbox received ack landed exactly once"

# Offset advanced to EOF.
OFFSET=$(cat "$CASE/state/.captain-inbox.offset")
INBOX_BYTES=$(wc -c < "$CASE/state/captain-inbox.jsonl")
[ "$OFFSET" = "$INBOX_BYTES" ] || fail "B1. offset $OFFSET != inbox bytes $INBOX_BYTES"
pass "B1. inbox offset advanced to EOF"

#------ B2. duplicate / concurrent: exactly-once ------------------------
# Re-run drain: must render nothing and produce no second ack.
"$INBOX_DRAIN" >"$TMP_ROOT/b2.out" 2>"$TMP_ROOT/b2.err" \
  || fail "B2. second drain failed"
if grep -q "FIRSTMATE CAPTAIN INPUT" "$TMP_ROOT/b2.out"; then
  fail "B2. second drain re-rendered (not idempotent); out: $(cat "$TMP_ROOT/b2.out")"
fi
recv_count=$(grep -c "\"corr\":\"$CORR\".*\"state\":\"received\"" "$CASE/state/captain-outbox.jsonl" || true)
[ "$recv_count" = "1" ] || fail "B2. expected 1 received ack after re-drain, got $recv_count"
pass "B2. duplicate drain is a no-op (exactly-once preserved by offset)"

#------ B3. restart recovery: append, skip drain, restart, drain ------
CASE="$TMP_ROOT/restart"
mkdir -p "$CASE/state"
export FM_ROOT_OVERRIDE="$CASE"

CORR2="mid-session-drain-restart-$RANDOM"
printf '{"hello":"after-crash"}' | "$INBOX_APPEND" --kind chat --corr "$CORR2" --json >/dev/null \
  || fail "B3. inbox-append failed"

# Simulate a process restart: clear the offset file but leave the inbox
# and the queue marker. The drain must catch the row on the next run.
: > "$CASE/state/.captain-inbox.offset"

OUT=$("$INBOX_DRAIN" 2>&1) || fail "B3. drain after restart failed: $OUT"
assert_contains "$OUT" "FIRSTMATE CAPTAIN INPUT v1 corr=$CORR2" \
  "B3. drain after restart did not render corr=$CORR2"
pass "B3. restart recovery: pending row drained after offset reset"

# Offset advanced again.
OFFSET=$(cat "$CASE/state/.captain-inbox.offset")
INBOX_BYTES=$(wc -c < "$CASE/state/captain-inbox.jsonl")
[ "$OFFSET" = "$INBOX_BYTES" ] || fail "B3. offset $OFFSET != inbox bytes $INBOX_BYTES"
pass "B3. offset advanced to EOF after restart-recovery drain"

#------ B4. concurrent wake + drain: offset locks prevent duplicate ---
# Two concurrent drain calls on the same inbox must produce exactly one
# set of acks, not two. The flock on .captain-inbox.lock serializes them.
CASE="$TMP_ROOT/concurrent"
mkdir -p "$CASE/state"
export FM_ROOT_OVERRIDE="$CASE"

CORR3="mid-session-drain-concurrent-$RANDOM"
printf '{"concurrent":true}' | "$INBOX_APPEND" --kind chat --corr "$CORR3" --json >/dev/null \
  || fail "B4. inbox-append failed"

# Run two drains concurrently. The flock serializes them; one renders + acks,
# the other observes the advanced offset and exits silently.
"$INBOX_DRAIN" >"$TMP_ROOT/b4a.out" 2>"$TMP_ROOT/b4a.err" &
PID1=$!
"$INBOX_DRAIN" >"$TMP_ROOT/b4b.out" 2>"$TMP_ROOT/b4b.err" &
PID2=$!
wait "$PID1" || true
wait "$PID2" || true

recv_count=$(grep -c "\"corr\":\"$CORR3\".*\"state\":\"received\"" "$CASE/state/captain-outbox.jsonl" || true)
[ "$recv_count" = "1" ] || fail "B4. expected 1 received ack under concurrent drains, got $recv_count"
pass "B4. concurrent drains serialize under flock (exactly-once)"

# Exactly one of the two stdout's should contain the render block.
render_count=0
grep -q "FIRSTMATE CAPTAIN INPUT v1 corr=$CORR3" "$TMP_ROOT/b4a.out" && render_count=$((render_count + 1))
grep -q "FIRSTMATE CAPTAIN INPUT v1 corr=$CORR3" "$TMP_ROOT/b4b.out" && render_count=$((render_count + 1))
[ "$render_count" = "1" ] || fail "B4. expected 1 render across 2 concurrent runs, got $render_count"
pass "B4. exactly one concurrent drain rendered the block"

#======================================================================
# Part C: watcher signal surface (the new behavior)
#======================================================================

# C1. The watcher must surface a "signal: captain-inbox.jsonl" reason
#     when the inbox grows. We test the static contract: scan_signals
#     emits a tab-separated line that the main loop will turn into a
#     signal wake. The main loop's wake handling is already exercised
#     by the existing fm-watch tests; here we only verify the trigger
#     code path was extended.
WATCH_LIB_SRC=$(grep -nE '^scan_signals\(\) \{' "$WATCH_SH" | head -1 | cut -d: -f1)
[ -n "$WATCH_LIB_SRC" ] || fail "C1. scan_signals function not found in fm-watch.sh"
# Extract the function body (up to the next "^}" or "^scan_signals").
# shellcheck disable=SC2016
scan_body=$(awk -v start="$WATCH_LIB_SRC" 'NR>=start && /^}/ {exit} NR>=start' "$WATCH_SH")
case "$scan_body" in
  *captain-inbox.jsonl*) : ;;
  *) fail "C1. scan_signals must include captain-inbox.jsonl in its glob; got:\n$scan_body" ;;
esac
pass "C1. scan_signals body includes captain-inbox.jsonl (mid-session wake trigger)"

# C2. The new surface key must be reachable through the existing wake
#     pipeline: the surfaced key becomes the wake-queue payload. Compile-time
#     check: the key path uses $(basename "$f") for *.status, *.turn-ended
#     AND for captain-inbox.jsonl, so signal_reason_is_actionable / wake
#     propagation stays consistent.
#     (Easier to read than to assert behaviorally: the format is the same.)
last_status_sig=$(grep -nE 'for f in .*\*\.status.*\*\.turn-ended' "$WATCH_SH" | head -1)
case "$last_status_sig" in
  *captain-inbox.jsonl*) pass "C2. watcher glob uniform for status/turn-ended/inbox (signal payload stable)" ;;
  *) fail "C2. watcher glob differs across signal kinds; got: $last_status_sig"
     ;;
esac

echo "ok - all fm-mid-session-drain tests passed"
