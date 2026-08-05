#!/usr/bin/env bash
# tests/fm-fresh-context-executor.test.sh - firstmate P2: fresh-context per task.
#
# Verifies (per the 2026-08-04 P2 spec, codex C* ruling):
#   1. Routing rule: a row with task_type=report_research spawns a fresh
#      worker via fm-spawn and does NOT render the standard inbox block.
#      A row without task_type (or with task_type=chat) renders the block
#      and does NOT spawn.
#   2. Two distinct report_research tasks produce two distinct
#      executor-jobs/<corr>.meta files with distinct session ids (the
#      spec: "Each task starts in its own fresh context").
#   3. spawn-side failure is fail-closed: the inbox row is NOT committed
#      (offset stays put) so the next drain retries — the controller's
#      retry logic depends on the row remaining visible.
#
# The real fm-spawn is heavy (creates a tmux window + claude process). We
# substitute a fake on PATH that records every invocation and echoes a
# deterministic session id. The real firstmate wiring is in
# bin/fm-research-worker-spawn.sh; the test exercises the public surface
# (inbox-drain + spawn helper) end-to-end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INBOX_APPEND="$ROOT/bin/fm-captain-inbox-append.sh"
INBOX_DRAIN="$ROOT/bin/fm-captain-inbox-drain.sh"
SPAWN_HELPER="$ROOT/bin/fm-research-worker-spawn.sh"

# Sanity: the production pieces must exist.
[ -x "$INBOX_APPEND" ]   || fail "inbox-append not executable"
[ -x "$INBOX_DRAIN" ]    || fail "inbox-drain not executable"
[ -x "$SPAWN_HELPER" ]   || fail "research-worker-spawn not executable: $SPAWN_HELPER"

TMP_ROOT=$(fm_test_tmproot fm-fresh-context-executor)

#======================================================================
# Build a fake fm-spawn that:
#   - records every invocation to a log file
#   - writes a fresh executor-jobs/<corr>.meta stub
#   - echoes a unique session id on stdout
#======================================================================
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
cat > "$FAKEBIN/fm-fake-spawn.sh" <<'SH'
#!/usr/bin/env bash
# fake fm-spawn: records every invocation, writes a state/<task-id>.meta
# record (which the real spawn helper reads), and a data/executor-jobs/<corr>.meta
# stub for the test to verify. Echoes the session id on stdout.
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-}}"
TASK_ID="$1"
PROJECT_DIR="$2"
shift 2
LOG="${FM_FAKE_SPAWN_LOG:?}"
META_DIR="${FM_FAKE_SPAWN_META_DIR:?}"
SEED="${FM_FAKE_SPAWN_SEED:-0}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SESSION_ID="spawn-${SEED}-$$-${TASK_ID}"
# Find the first --brief <path> pair.
prev=
brief_path=
for arg in "$@"; do
  case "$prev" in
    --brief) brief_path="$arg" ;;
  esac
  prev="$arg"
done
# Extract the corr from the brief.
corr=unknown
if [ -n "${brief_path:-}" ] && [ -f "$brief_path" ]; then
  corr=$(grep -oE '^corr=[A-Za-z0-9._-]+' "$brief_path" | head -1 | cut -d= -f2-)
  [ -n "$corr" ] || corr=$(basename "$brief_path" .brief.md)
fi
echo "$TS $SESSION_ID $TASK_ID $PROJECT_DIR $(printf '%s ' "$@")" >> "$LOG"
# Mimic real fm-spawn: write state/<task-id>.meta so the helper can read it.
STATE_DIR="${FM_HOME}/state"
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/${TASK_ID}.meta" <<META
session_id=$SESSION_ID
window=fake-window-${TASK_ID}
worktree=$PROJECT_DIR
META
# The real helper writes data/executor-jobs/<corr>.meta from the state
# record. We don't write it here so the test can prove the helper did
# the translation. The test verifies the meta file appears after the
# drain returns.
echo "$SESSION_ID"
SH
chmod +x "$FAKEBIN/fm-fake-spawn.sh"
# The helper reads FM_SPAWN_BIN to find the spawn binary (so tests can
# inject a fake without shadowing the production bin/fm-spawn.sh).
export FM_SPAWN_BIN="$FAKEBIN/fm-fake-spawn.sh"

# Also stub supporting tools so the spawn helper never accidentally invokes
# the real worktree machinery. NOTE: jq is NOT stubbed — the inbox-drain
# relies on real jq to parse the row JSON for task_type / corr. Stubbing
# jq here would silently drop rows because the real drain's `jq -r '.corr // empty'`
# would return empty.
fm_fake_exit0 "$FAKEBIN" git tmux
# fm-spawn (no .sh) is the actual binary; the production helper may also
# invoke it via the bin/ path if available, so we shadow the real one with
# our fake earlier. We also need to be sure the helper does not invoke
# `bin/fm-spawn.sh` from outside the repo (some helpers do).

#======================================================================
# Case 1: routing rule
#======================================================================

CASE="$TMP_ROOT/routing"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs"
export FM_ROOT_OVERRIDE="$CASE"
export FM_FAKE_SPAWN_LOG="$CASE/fake-spawn.log"
export FM_FAKE_SPAWN_META_DIR="$CASE/data/executor-jobs"
export FM_FAKE_SPAWN_SEED=1
# Path-shim the fake so the spawn helper finds fake fm-spawn.sh.
export PATH="$FAKEBIN:$PATH"

# 1a. chat row renders block, no spawn.
CORR_CHAT="routing-chat-$RANDOM"
printf '{"body":"hello"}' | "$INBOX_APPEND" --kind chat --corr "$CORR_CHAT" --json >/dev/null \
  || fail "1a. inbox-append failed for chat"

OUT_CHAT=$("$INBOX_DRAIN" 2>&1) || fail "1a. drain failed: $OUT_CHAT"
assert_contains "$OUT_CHAT" "FIRSTMATE CAPTAIN INPUT v1 corr=$CORR_CHAT" \
  "1a. chat row should render block"
[ -f "$CASE/data/executor-jobs/${CORR_CHAT}.meta" ] \
  && fail "1a. chat row must NOT spawn a worker"
pass "1a. chat row renders block, no spawn"

# 1b. report_research row spawns, NO block rendered.
CORR_RES="routing-research-$RANDOM"
BODY='{"task_type":"report_research","must_answer":["Q1","Q2"],"evidence":["/tmp/x"],"ttl_minutes":10}'
# Pass the task_type via --task-type so the inbox row gets the field.
"$INBOX_APPEND" --kind chat --task-type report_research --corr "$CORR_RES" --json <<<"$BODY" >/dev/null \
  || fail "1b. inbox-append failed for report_research (the --task-type flag is the new field)"

# Confirm the row stored the task_type (jsonl proves the schema).
grep -F "\"task_type\":\"report_research\"" "$CASE/state/captain-inbox.jsonl" >/dev/null \
  || fail "1b. inbox row missing task_type field; got: $(cat "$CASE/state/captain-inbox.jsonl")"

# Run drain; assert the report_research block is NOT rendered
# (the LLM context is intentionally NOT polluted with the task body,
# and the spawn meta file IS created).
OUT_RES=$("$INBOX_DRAIN" 2>&1) || fail "1b. drain failed: $OUT_RES"
case "$OUT_RES" in
  *"FIRSTMATE CAPTAIN INPUT v1 corr=$CORR_RES"*)
    fail "1b. report_research should NOT render the block; out: $OUT_RES" ;;
esac
[ -f "$CASE/data/executor-jobs/${CORR_RES}.meta" ] \
  || fail "1b. spawn meta missing for $CORR_RES; out: $OUT_RES"
pass "1b. report_research row spawns worker, does NOT render block"

# 1c. The marker line tells the operator what happened.
assert_contains "$OUT_RES" "task dispatched" \
  "1b. drain must emit a 'task dispatched' marker for report_research"
pass "1c. drain emits a 'task dispatched' marker for report_research"

# The fake-spawn log records what the helper invoked.
grep -F "$CORR_RES" "$CASE/fake-spawn.log" >/dev/null \
  || fail "1c. fake-spawn log missing $CORR_RES; log: $(cat "$CASE/fake-spawn.log")"
pass "1c. spawn helper invoked fm-spawn with the brief"

#======================================================================
# Case 2: two distinct tasks -> two distinct session ids
#======================================================================

CASE="$TMP_ROOT/two-tasks"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs"
export FM_ROOT_OVERRIDE="$CASE"
export FM_FAKE_SPAWN_LOG="$CASE/fake-spawn.log"
export FM_FAKE_SPAWN_META_DIR="$CASE/data/executor-jobs"
export FM_FAKE_SPAWN_SEED=2
export PATH="$FAKEBIN:$PATH"

CORR_A="two-tasks-A-$RANDOM"
CORR_B="two-tasks-B-$RANDOM"

for c in "$CORR_A" "$CORR_B"; do
  "$INBOX_APPEND" --kind chat --task-type report_research --corr "$c" --json <<<"{\"task_type\":\"report_research\",\"must_answer\":[\"Q\"]}" >/dev/null \
    || fail "2. inbox-append failed for $c"
done

OUT=$("$INBOX_DRAIN" 2>&1) || fail "2. drain failed: $OUT"

# Each corr has its own meta file with a session id.
for c in "$CORR_A" "$CORR_B"; do
  [ -f "$CASE/data/executor-jobs/${c}.meta" ] \
    || fail "2. meta missing for $c: $(ls "$CASE/data/executor-jobs" 2>/dev/null)"
done
pass "2a. two distinct report_research tasks -> two meta files"

ID_A=$(grep '^session_id=' "$CASE/data/executor-jobs/${CORR_A}.meta" | cut -d= -f2-)
ID_B=$(grep '^session_id=' "$CASE/data/executor-jobs/${CORR_B}.meta" | cut -d= -f2-)
[ -n "$ID_A" ] && [ -n "$ID_B" ] \
  || fail "2. session ids missing: A=$ID_A B=$ID_B"
[ "$ID_A" != "$ID_B" ] \
  || fail "2. session ids must be distinct (fresh context per task); both=$ID_A"
pass "2b. session ids distinct -> each task ran in its own fresh context"

# Both task ids appear in the fake-spawn log (proves two independent invocations).
occ=$(grep -cE "($CORR_A|$CORR_B)" "$CASE/fake-spawn.log" || true)
[ "$occ" -ge 2 ] || fail "2. expected >=2 fake-spawn invocations, got $occ"
pass "2c. spawn helper invoked twice (one per task)"

#======================================================================
# Case 3: spawn-side failure is fail-closed (offset NOT advanced)
#======================================================================

CASE="$TMP_ROOT/fail-closed"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs"
export FM_ROOT_OVERRIDE="$CASE"
export FM_FAKE_SPAWN_LOG="$CASE/fake-spawn.log"
export FM_FAKE_SPAWN_META_DIR="$CASE/data/executor-jobs"
export FM_FAKE_SPAWN_SEED=3

# Build a fake fm-spawn that ALWAYS fails (exit 1).
FAILBIN=$(fm_fakebin "$TMP_ROOT/fail")
cat > "$FAILBIN/fm-fake-spawn.sh" <<'SH'
#!/usr/bin/env bash
echo "fake-spawn: simulating failure" >&2
exit 1
SH
chmod +x "$FAILBIN/fm-fake-spawn.sh"
fm_fake_exit0 "$FAILBIN" git tmux
export FM_SPAWN_BIN="$FAILBIN/fm-fake-spawn.sh"

CORR_FAIL="routing-fail-$RANDOM"
"$INBOX_APPEND" --kind chat --task-type report_research --corr "$CORR_FAIL" --json <<<"{\"task_type\":\"report_research\"}" >/dev/null \
  || fail "3. inbox-append failed"

# Capture the inbox size before drain.
INBOX_BYTES=$(wc -c < "$CASE/state/captain-inbox.jsonl")

set +e
OUT=$("$INBOX_DRAIN" 2>&1)
rc=$?
set -e

# Drain must exit non-zero so the watcher (or session-start) keeps the
# wake until the next drain retries. The fail-closed contract per the
# 2026-08-04 P2 spec: spawn failure -> row stays on the inbox -> next
# drain retries -> controller's submission_timeout pauses on persisted failure.
[ "$rc" != "0" ] || fail "3. drain must exit non-zero on spawn failure (row stays for retry); rc=$rc"
assert_contains "$OUT" "spawn failed" \
  "3. drain must emit a 'spawn failed' marker on failure"
pass "3a. drain exits non-zero on spawn failure (row stays for retry)"

# Offset MUST NOT advance — the row must remain visible for retry.
OFFSET=$(cat "$CASE/state/.captain-inbox.offset" 2>/dev/null || echo 0)
[ "$OFFSET" = "0" ] || [ "$OFFSET" -lt "$INBOX_BYTES" ] \
  || fail "3. offset $OFFSET advanced to $INBOX_BYTES despite spawn failure"
if [ "$OFFSET" = "$INBOX_BYTES" ]; then
  fail "3. offset advanced to EOF despite spawn failure — row lost"
fi
pass "3b. offset NOT advanced on spawn failure (retry boundary preserved)"

# No meta file should be created for the failed spawn.
[ -f "$CASE/data/executor-jobs/${CORR_FAIL}.meta" ] \
  && fail "3. meta file created despite spawn failure"
pass "3c. no meta file on spawn failure"

#======================================================================
# Case 4: spawn helper is idempotent on re-drain
#======================================================================
# Puti's decision doc (Data point 1.5, 1 要固化的细节): a previously
# dispatched task's <corr>.meta tells the spawn helper to skip re-spawn.
# This prevents duplicate short-lived workers when the inbox offset is
# reset (e.g. recovery from an earlier drain abort) and the same row
# is re-read. The offset still advances normally so the row is
# consumed cleanly once.
CASE="$TMP_ROOT/idempotent"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs"
export FM_ROOT_OVERRIDE="$CASE"
export FM_FAKE_SPAWN_LOG="$CASE/fake-spawn.log"
export FM_FAKE_SPAWN_META_DIR="$CASE/data/executor-jobs"
export FM_FAKE_SPAWN_SEED=4
# Restore the success fake (case 3 re-pointed FM_SPAWN_BIN at the always-fail
# fake in FAILBIN; idempotency case needs the success fake back).
export FM_SPAWN_BIN="$FAKEBIN/fm-fake-spawn.sh"
export PATH="$FAKEBIN:$PATH"

CORR_IDEMP="routing-idemp-$RANDOM"
"$INBOX_APPEND" --kind chat --task-type report_research --corr "$CORR_IDEMP" --json <<<"{\"task_type\":\"report_research\"}" >/dev/null \
  || fail "4. inbox-append failed"

# First drain: spawn happens, meta is created.
OUT_FIRST=$("$INBOX_DRAIN" 2>&1) || fail "4. first drain failed: $OUT_FIRST"
[ -f "$CASE/data/executor-jobs/${CORR_IDEMP}.meta" ] \
  || fail "4. meta missing after first drain: $OUT_FIRST"
ORIG_SESSION=$(grep '^session_id=' "$CASE/data/executor-jobs/${CORR_IDEMP}.meta" | cut -d= -f2-)
[ -n "$ORIG_SESSION" ] || fail "4. session id missing from meta"
FIRST_LOG_LINES=$(wc -l < "$CASE/fake-spawn.log")
pass "4-pre. first drain spawned worker (session=$ORIG_SESSION, log=$FIRST_LOG_LINES)"

# Reset the inbox offset to simulate a recovery that re-reads the row.
: > "$CASE/state/.captain-inbox.offset"

# Second drain: idempotency must skip the spawn invocation.
OUT_SECOND=$("$INBOX_DRAIN" 2>&1) || fail "4. second drain failed: $OUT_SECOND"
SECOND_LOG_LINES=$(wc -l < "$CASE/fake-spawn.log")
[ "$SECOND_LOG_LINES" = "$FIRST_LOG_LINES" ] \
  || fail "4. spawn helper re-invoked on re-drain (idempotency leaked); first=$FIRST_LOG_LINES second=$SECOND_LOG_LINES"
pass "4a. spawn helper skipped on re-drain (idempotency: log lines unchanged)"

# Meta file is unchanged (still the original session id, not re-written).
NEW_SESSION=$(grep '^session_id=' "$CASE/data/executor-jobs/${CORR_IDEMP}.meta" | cut -d= -f2-)
[ "$NEW_SESSION" = "$ORIG_SESSION" ] \
  || fail "4. meta session id changed on re-drain: orig=$ORIG_SESSION new=$NEW_SESSION"
pass "4b. meta file untouched (original session id preserved)"

# Drain emits an idempotent marker so the operator sees what happened.
assert_contains "$OUT_SECOND" "task dispatched" \
  "4c. drain must emit a 'task dispatched' marker on idempotent re-drain"
pass "4c. drain emits task-dispatched marker (idempotent path surfaces to LLM)"

# Offset still advances after the idempotent re-drain so the row is consumed.
OFFSET=$(cat "$CASE/state/.captain-inbox.offset")
INBOX_BYTES=$(wc -c < "$CASE/state/captain-inbox.jsonl")
[ "$OFFSET" = "$INBOX_BYTES" ] \
  || fail "4. offset $OFFSET != inbox bytes $INBOX_BYTES after idempotent re-drain"
pass "4d. offset advanced after idempotent re-drain (row consumed)"

echo "ok - all fm-fresh-context-executor tests passed"
