#!/usr/bin/env bash
# Regression: durable intake must ACK only after queue persistence, while
# worker spawn failures remain retryable without blocking later inbox rows.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
APPEND="$ROOT/bin/fm-captain-inbox-append.sh"
DRAIN="$ROOT/bin/fm-captain-inbox-drain.sh"
TMP=$(fm_test_tmproot fm-research-dispatch-queue)
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/spawn" <<'SH'
#!/usr/bin/env bash
count_file="${FM_FAKE_SPAWN_COUNT:?}"
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf 'revision=%s corr=%s attempt=%s\n' "${FM_RESEARCH_WORKER_REVISION_SEQ:-}" "$1" "$count" >> "${FM_FAKE_SPAWN_LOG:?}"
if [ "${FM_FAKE_SPAWN_FAIL_ONCE:-0}" = 1 ] && [ "$count" = 1 ]; then exit 7; fi
printf 'session_id=fake-%s\n' "$count"
SH
chmod +x "$TMP/fakebin/spawn"

CASE="$TMP/case"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs"
export FM_HOME="$CASE" FM_ROOT_OVERRIDE="$CASE"
export FM_RESEARCH_WORKER_SPAWN="$TMP/fakebin/spawn"
export FM_FAKE_SPAWN_COUNT="$TMP/spawn.count" FM_FAKE_SPAWN_LOG="$TMP/spawn.log"
export FM_FAKE_SPAWN_FAIL_ONCE=1
CORR="typed-queue-$RANDOM"
printf '{"objective":"research"}' | "$APPEND" --kind chat --task-type report_research --corr "$CORR" --json >/dev/null
CHAT="chat-after-queue-$RANDOM"
printf '{"hello":"still-drainable"}' | "$APPEND" --kind chat --corr "$CHAT" --json >/dev/null
OUT1=$("$DRAIN" 2>&1) || fail "first drain failed: $OUT1"
grep -q "task queued: corr=$CORR" <<<"$OUT1" || fail "typed task was not durably queued: $OUT1"
grep -q "FIRSTMATE CAPTAIN INPUT v1 corr=$CHAT" <<<"$OUT1" || fail "chat after failed worker was head-of-line blocked: $OUT1"
if grep -q "FIRSTMATE CAPTAIN INPUT v1 corr=$CORR" <<<"$OUT1"; then fail "typed Work Order leaked to primary"; fi
[ "$(grep -c "\"corr\":\"$CORR\".*\"state\":\"received\"" "$CASE/state/captain-outbox.jsonl")" = 1 ] || fail "typed task did not receive exactly one ACK"
[ "$(find "$CASE/state/research-dispatch-queue" -name '*.json' | wc -l)" = 1 ] || fail "failed spawn queue item was lost"
[ "$(cat "$CASE/state/.captain-inbox.offset")" = "$(wc -c < "$CASE/state/captain-inbox.jsonl")" ] || fail "offset did not advance after durable queue commit"
[ "$(grep -c "\"corr\":\"$CHAT\".*\"state\":\"received\"" "$CASE/state/captain-outbox.jsonl")" = 1 ] || fail "chat after typed task did not receive ACK"
pass "1. durable queue commits ACK+offset before worker spawn and preserves chat throughput"

OUT2=$("$DRAIN" 2>&1) || fail "retry drain failed: $OUT2"
[ "$(find "$CASE/state/research-dispatch-queue" -name '*.json' | wc -l)" = 0 ] || fail "successful retry did not clear queue item"
[ "$(grep -c "corr=$CORR" "$FM_FAKE_SPAWN_LOG")" = 2 ] || fail "expected one failed + one successful spawn"
[ "$(grep -c "\"corr\":\"$CORR\".*\"state\":\"received\"" "$CASE/state/captain-outbox.jsonl")" = 1 ] || fail "retry duplicated received ACK"
pass "2. pending queue retries on a later drain without duplicate ACK"

# Typed feedback is worker-exclusive and retains its feedback sequence.
REV="typed-feedback-$RANDOM"
mkdir -p "$CASE/data/executor-jobs"
printf 'corr=%s\nsession_id=original\nbrief=%s/data/executor-jobs/%s.brief.md\n' "$REV" "$CASE" "$REV" > "$CASE/data/executor-jobs/$REV.meta"
printf '# original\n' > "$CASE/data/executor-jobs/$REV.brief.md"
printf '[fm cross-model review]\nRevise Q1.\n' | "$APPEND" --kind chat --task-type report_research --corr "$REV" --json >/dev/null
OUT3=$("$DRAIN" 2>&1) || fail "typed feedback drain failed: $OUT3"
grep -q "revision=[0-9][0-9]* corr=$REV" "$FM_FAKE_SPAWN_LOG" || fail "typed feedback was not sent to revision worker"
if grep -q 'FIRSTMATE CAPTAIN INPUT' <<<"$OUT3"; then fail "typed feedback leaked to primary"; fi
pass "3. typed feedback is revision-worker exclusive"

set +e
"$ROOT/bin/fm-captain-outbox-append.sh" --corr governance-test --state accepted --text nope --seq 1 >/dev/null 2>"$TMP/accepted.err"
ACCEPTED_RC=$?
set -e
[ "$ACCEPTED_RC" -ne 0 ] || fail "FM outbox allowed captain-only state=accepted"
grep -q 'captain/controller-only' "$TMP/accepted.err" || fail "accepted rejection did not explain authority"
pass "4. FM cannot self-accept captain/controller decisions"

echo "ok - research dispatch queue regression passed"
