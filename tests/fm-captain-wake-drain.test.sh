#!/usr/bin/env bash
# tests/fm-captain-wake-drain.test.sh - chat-router wake-path repair.
#
# Verifies (per the captain's runtime repair brief):
#   1. Wrapper requires explicit primary-pane metadata; missing = fail closed.
#   2. Wrapper requires every metadata field (PRIMARY_SESSION/WINDOW/PANE) non-empty.
#   3. Wrapper contains no tmux send-keys / body injection (defensive static check).
#   4. Inbox row -> wrapper -> outbox received ack lands under flock.
#   5. Duplicate corr+seq is idempotent: re-running wrapper renders nothing new
#      and produces no second terminal received ack for the same corr.
#
# Hermetic: every case uses its own FM_ROOT_OVERRIDE scratch dir under a
# fm_test_tmproot() root; live state/ is never read or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-captain-wake-drain.sh"
INBOX_APPEND="$ROOT/bin/fm-captain-inbox-append.sh"
INBOX_DRAIN="$ROOT/bin/fm-captain-inbox-drain.sh"
OUTBOX_APPEND="$ROOT/bin/fm-captain-outbox-append.sh"

# Sanity: every script under test must exist.
[ -x "$WRAPPER" ] || fail "wrapper not executable: $WRAPPER"
[ -x "$INBOX_APPEND" ] || fail "inbox-append not executable"
[ -x "$INBOX_DRAIN" ] || fail "inbox-drain not executable"
[ -x "$OUTBOX_APPEND" ] || fail "outbox-append not executable"

# ------------------------------------------------------------------
# Case 1: missing primary-pane metadata must fail closed.
# ------------------------------------------------------------------
TMP_ROOT=$(fm_test_tmproot fm-captain-wake-drain)
CASE="$TMP_ROOT/no-meta"
mkdir -p "$CASE/state"
export FM_ROOT_OVERRIDE="$CASE"

set +e
"$WRAPPER" >/dev/null 2>"$TMP_ROOT/case1.err"
rc=$?
set -e

[ "$rc" = "2" ] || fail "1. missing metadata should exit 2, got $rc"
grep -q 'missing primary-pane metadata' "$TMP_ROOT/case1.err" \
  || fail "1. error must mention 'missing primary-pane metadata'; got: $(cat "$TMP_ROOT/case1.err")"
pass "1. wrapper fails closed (exit 2) when metadata missing"

# ------------------------------------------------------------------
# Case 2: empty/malformed metadata must fail closed.
# ------------------------------------------------------------------
CASE="$TMP_ROOT/empty-meta"
mkdir -p "$CASE/state"
export FM_ROOT_OVERRIDE="$CASE"
: > "$CASE/state/.primary-pane"

set +e
"$WRAPPER" >/dev/null 2>"$TMP_ROOT/case2.err"
rc=$?
set -e

[ "$rc" = "2" ] || fail "2. empty metadata should exit 2, got $rc"
grep -q 'empty/missing fields' "$TMP_ROOT/case2.err" \
  || fail "2. error must mention 'empty/missing fields'; got: $(cat "$TMP_ROOT/case2.err")"
pass "2. wrapper fails closed (exit 2) when metadata fields empty"

# ------------------------------------------------------------------
# Case 2b: metadata with one field missing must fail closed and name it.
# ------------------------------------------------------------------
CASE="$TMP_ROOT/partial-meta"
mkdir -p "$CASE/state"
export FM_ROOT_OVERRIDE="$CASE"
cat > "$CASE/state/.primary-pane" <<'META'
PRIMARY_SESSION=firstmate
PRIMARY_WINDOW=0
META

set +e
"$WRAPPER" >/dev/null 2>"$TMP_ROOT/case2b.err"
rc=$?
set -e

[ "$rc" = "2" ] || fail "2b. partial metadata should exit 2, got $rc"
grep -q 'PRIMARY_PANE' "$TMP_ROOT/case2b.err" \
  || fail "2b. error must name PRIMARY_PANE; got: $(cat "$TMP_ROOT/case2b.err")"
pass "2b. wrapper names the missing field"

# ------------------------------------------------------------------
# Case 3: static check - wrapper has no tmux send-keys / body injection.
# ------------------------------------------------------------------
# Exclude comment lines so the documented "we forbid tmux send-keys" doc-comment
# does not trip the guard. Real usage would be a non-comment invocation.
if grep -nE '^[[:space:]]*[^#]*send-keys[[:space:]]' "$WRAPPER" >/dev/null; then
  fail "3. wrapper must not invoke tmux send-keys on a non-comment line; matched: $(grep -nE '^[[:space:]]*[^#]*send-keys' "$WRAPPER")"
fi
pass "3. wrapper has no tmux send-keys on non-comment lines"

# Wrapper must not echo/capture the captain body content either.
if grep -nE 'CAPTAIN_BODY|\$BODY|\$\{BODY[^}]*\}|cat.*body' "$WRAPPER" >/dev/null; then
  fail "3b. wrapper must not reference captain body"
fi
pass "3b. wrapper has no captain-body reference"

# ------------------------------------------------------------------
# Case 4: happy path - inbox row -> wrapper -> outbox received ack.
# ------------------------------------------------------------------
CASE="$TMP_ROOT/happy"
mkdir -p "$CASE/state"
export FM_ROOT_OVERRIDE="$CASE"

# Pin the metadata so the wrapper accepts the run.
cat > "$CASE/state/.primary-pane" <<'META'
PRIMARY_SESSION=firstmate
PRIMARY_WINDOW=0
PRIMARY_PANE=0
META

# Append a chat row via the production inbox-append helper (body on stdin).
CORR="chat-router-preflight-test-$RANDOM"
printf '{"hello":"world","n":1}' | "$INBOX_APPEND" --kind chat --corr "$CORR" --json >/dev/null \
  || fail "4. inbox-append failed"

# Run the wrapper; capture render output to a file.
"$WRAPPER" >"$TMP_ROOT/case4.out" 2>"$TMP_ROOT/case4.err" || fail "4. wrapper exited non-zero"
grep -q "FIRSTMATE CAPTAIN INPUT v1 corr=$CORR" "$TMP_ROOT/case4.out" \
  || fail "4. drain did not render corr=$CORR; out: $(cat "$TMP_ROOT/case4.out")"
pass "4a. drain rendered the captain-inbox block"

# Outbox must contain exactly one received ack for this corr.
[ -f "$CASE/state/captain-outbox.jsonl" ] || fail "4b. outbox file missing"
recv_count=$(grep -c "\"corr\":\"$CORR\".*\"state\":\"received\"" "$CASE/state/captain-outbox.jsonl" || true)
[ "$recv_count" = "1" ] || fail "4b. expected exactly 1 received ack for $CORR, got $recv_count"
pass "4b. outbox received ack landed exactly once"

# Inbox offset must have advanced (otherwise next drain would re-render).
[ -f "$CASE/state/.captain-inbox.offset" ] || fail "4c. offset file missing"
OFFSET=$(cat "$CASE/state/.captain-inbox.offset")
INBOX_BYTES=$(wc -c < "$CASE/state/captain-inbox.jsonl")
[ "$OFFSET" = "$INBOX_BYTES" ] || fail "4c. offset $OFFSET != inbox bytes $INBOX_BYTES"
pass "4c. inbox offset advanced to EOF"

# ------------------------------------------------------------------
# Case 5: duplicate corr+seq is idempotent (re-running wrapper is a no-op).
# ------------------------------------------------------------------
# Re-run wrapper; should render nothing and produce no second ack.
"$WRAPPER" >"$TMP_ROOT/case5.out" 2>"$TMP_ROOT/case5.err" || fail "5. second wrapper run failed"
if grep -q "FIRSTMATE CAPTAIN INPUT" "$TMP_ROOT/case5.out"; then
  fail "5. second drain re-rendered (not idempotent); out: $(cat "$TMP_ROOT/case5.out")"
fi
pass "5a. second drain produced no render block (offset advanced)"

recv_count=$(grep -c "\"corr\":\"$CORR\".*\"state\":\"received\"" "$CASE/state/captain-outbox.jsonl" || true)
[ "$recv_count" = "1" ] || fail "5b. expected 1 received ack after re-drain, got $recv_count"
pass "5b. no duplicate received ack for same corr+seq"

# ------------------------------------------------------------------
# Case 6: empty inbox is a quiet no-op (no ack row, no error).
# ------------------------------------------------------------------
CASE="$TMP_ROOT/empty"
mkdir -p "$CASE/state"
export FM_ROOT_OVERRIDE="$CASE"
cat > "$CASE/state/.primary-pane" <<'META'
PRIMARY_SESSION=firstmate
PRIMARY_WINDOW=0
PRIMARY_PANE=0
META

set +e
"$WRAPPER" >"$TMP_ROOT/case6.out" 2>"$TMP_ROOT/case6.err"
rc=$?
set -e

[ "$rc" = "0" ] || fail "6. empty inbox should exit 0, got $rc"
[ ! -s "$TMP_ROOT/case6.out" ] || fail "6. empty inbox should produce no stdout"
[ ! -e "$CASE/state/captain-outbox.jsonl" ] \
  || [ ! -s "$CASE/state/captain-outbox.jsonl" ] \
  || fail "6. empty inbox must not produce outbox rows"
pass "6. empty inbox is a quiet no-op"

echo "ok - all fm-captain-wake-drain tests passed"