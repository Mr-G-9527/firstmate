#!/usr/bin/env bash
# test_fm-research-dispatch-drain-fail.sh - covers the spawn-failure
# observability path added in batch-0901-06-dispatch-obs:
#   * failing spawn → state/.dispatch-fail/<corr>/<reason>.log created
#   * failing spawn → queue JSON carries _fail_summary pointing to it
#   * failing spawn → .spawn.last.err still preserved (ov-0824-A contract)
#   * happy path → no fail log written, queue removed, dispatch complete
#   * path-traversal corr → falls into invalid-corr subdir, no escape
#
# Each case uses its own TMP_HOME so the queue and state directories
# are isolated; otherwise one case's leftover queue file would feed the
# next case's drain loop.
#
# Run: bash bin/test_fm-research-dispatch-drain-fail.sh
# Exit: 0 on success, non-zero on first assertion failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAIN="$SCRIPT_DIR/fm-research-dispatch-drain.sh"

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }

# Build the failing and passing mock spawn helpers inside a per-case
# TMP_HOME so they live as long as the case does.
setup_case() {
  local case_home=$1
  mkdir -p "$case_home/state/research-dispatch-queue" "$case_home/data/executor-jobs" "$case_home/bin-mock"

  cat > "$case_home/bin-mock/spawn-fail.sh" <<'EOSPAWN'
#!/usr/bin/env bash
echo "[fail-mock] corr=$1 project_dir=$3"
echo "[fail-mock] spawning backend claude-prod"
echo "[fail-mock] error: backend refused connection after 30s"
echo "[fail-mock] hint: check FM_RESEARCH_BACKEND and ANTHROPIC_API_KEY"
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf 'stack-frame-%02d at 0xdeadbeef\n' "$i"
done
exit 1
EOSPAWN
  chmod +x "$case_home/bin-mock/spawn-fail.sh"

  cat > "$case_home/bin-mock/spawn-pass.sh" <<'EOSPAWN'
#!/usr/bin/env bash
exit 0
EOSPAWN
  chmod +x "$case_home/bin-mock/spawn-pass.sh"
}

run_drain() {
  local case_home=$1 spawn_helper=$2 out_path=$3 err_path=$4
  FM_HOME="$case_home" \
    STATE="$case_home/state" \
    FM_RESEARCH_DISPATCH_QUEUE_DIR="$case_home/state/research-dispatch-queue" \
    FM_RESEARCH_WORKER_SPAWN="$spawn_helper" \
    FM_RESEARCH_DEATH_CHECK_CMD="true" \
    FM_RESEARCH_DISPATCH_RETRY_MAX=3 \
    FM_EXECUTOR_JOBS_DIR="$case_home/data/executor-jobs" \
    bash "$DRAIN" >"$out_path" 2>"$err_path"
}

# ---------- Case 1: failing spawn ----------------------------------------
echo "=== case 1: failing spawn ==="
CASE1_HOME="$(mktemp -d /tmp/fm-drain-fail-test1.XXXXXX)"
trap 'rm -rf "$CASE1_HOME" /tmp/drain-case*.{stdout,stderr}' EXIT
setup_case "$CASE1_HOME"
CORR1="t-$(date +%s)-fail"
QUEUE1="$CASE1_HOME/state/research-dispatch-queue/$CORR1.json"
cat > "$QUEUE1" <<EOJSON
{
  "corr": "$CORR1",
  "seq": 7,
  "revision_seq": "",
  "project_dir": "$CASE1_HOME",
  "attempts": 0,
  "row": {"corr": "$CORR1", "query": "smoke-test-fail"}
}
EOJSON
chmod 600 "$QUEUE1"

run_drain "$CASE1_HOME" "$CASE1_HOME/bin-mock/spawn-fail.sh" /tmp/drain-case1.stdout /tmp/drain-case1.stderr

if [ ! -f "$QUEUE1" ]; then
  fail "case1: queue file was deleted (success path ran by mistake)"
fi
ATTEMPTS1="$(jq -r '.attempts // 0' "$QUEUE1" 2>/dev/null || echo 0)"
if [ "$ATTEMPTS1" != "1" ]; then
  fail "case1: expected attempts=1, got '$ATTEMPTS1'"
fi
FS1="$(jq -r '._fail_summary.reason // empty' "$QUEUE1" 2>/dev/null || true)"
if [ "$FS1" != "spawn-fail-attempt-1" ]; then
  fail "case1: expected _fail_summary.reason=spawn-fail-attempt-1, got '$FS1'"
fi
FS_LOG="$(jq -r '._fail_summary.evidence_log // empty' "$QUEUE1" 2>/dev/null || true)"
if [ -z "$FS_LOG" ]; then
  fail "case1: _fail_summary.evidence_log is empty"
fi
if [ ! -f "$FS_LOG" ]; then
  fail "case1: evidence log not on disk: $FS_LOG"
fi

if ! grep -q 'fail-mock' "$FS_LOG" 2>/dev/null; then
  fail "case1: fail log missing spawn.out tail marker (grep fail-mock)"
fi
if ! grep -q '^captured_at=' "$FS_LOG" 2>/dev/null; then
  fail "case1: fail log missing captured_at header"
fi
if ! grep -q "^task_id=$CORR1$" "$FS_LOG" 2>/dev/null; then
  fail "case1: fail log missing original task_id in header (expected task_id=$CORR1)"
fi
if ! grep -q '^reason=spawn-fail-attempt-1$' "$FS_LOG" 2>/dev/null; then
  fail "case1: fail log missing reason header"
fi

if [ ! -f "$QUEUE1.spawn.last.err" ]; then
  fail "case1: .spawn.last.err not preserved"
fi

EXPECTED_DIR="$CASE1_HOME/state/.dispatch-fail/$CORR1"
if [ ! -d "$EXPECTED_DIR" ]; then
  fail "case1: expected fail dir $EXPECTED_DIR not created"
fi
DIR_MODE="$(stat -c '%a' "$EXPECTED_DIR" 2>/dev/null || echo 0)"
if [ "$DIR_MODE" != "700" ]; then
  fail "case1: fail dir permissions not 700 (got '$DIR_MODE')"
fi
EXPECTED_LOG="$EXPECTED_DIR/spawn-fail-attempt-1.log"
if [ "$FS_LOG" != "$EXPECTED_LOG" ]; then
  fail "case1: evidence_log path '$FS_LOG' != expected '$EXPECTED_LOG'"
fi

if compgen -G "$EXPECTED_DIR/.[A-Za-z0-9_-]*.log.tmp.*" >/dev/null 2>&1; then
  fail "case1: orphan tmp file left behind"
fi

if ! grep -q "fail_log=$EXPECTED_LOG" /tmp/drain-case1.stderr; then
  fail "case1: stderr retry-pending line missing fail_log=... (see /tmp/drain-case1.stderr)"
fi

# ---------- Case 2: happy path -------------------------------------------
echo "=== case 2: happy path ==="
CASE2_HOME="$(mktemp -d /tmp/fm-drain-fail-test2.XXXXXX)"
setup_case "$CASE2_HOME"
CORR2="t-$(date +%s)-pass"
QUEUE2="$CASE2_HOME/state/research-dispatch-queue/$CORR2.json"
cat > "$QUEUE2" <<EOJSON
{
  "corr": "$CORR2",
  "seq": 8,
  "revision_seq": "",
  "project_dir": "$CASE2_HOME",
  "attempts": 0,
  "row": {"corr": "$CORR2", "query": "smoke-test-pass"}
}
EOJSON
chmod 600 "$QUEUE2"

run_drain "$CASE2_HOME" "$CASE2_HOME/bin-mock/spawn-pass.sh" /tmp/drain-case2.stdout /tmp/drain-case2.stderr

if [ -f "$QUEUE2" ]; then
  fail "case2: queue file not removed on success"
fi
if [ -e "$CASE2_HOME/state/.dispatch-fail" ]; then
  fail "case2: state/.dispatch-fail created on success path"
fi
if ! grep -q "dispatch complete: corr=$CORR2 seq=8" /tmp/drain-case2.stdout; then
  fail "case2: success path did not emit 'dispatch complete'"
fi

# ---------- Case 3: path-traversal sanitization --------------------------
echo "=== case 3: path traversal corr ==="
CASE3_HOME="$(mktemp -d /tmp/fm-drain-fail-test3.XXXXXX)"
setup_case "$CASE3_HOME"
# The script's main-loop case-statement at line 223 rejects any corr
# containing chars outside [A-Za-z0-9._-], which blocks `/`. The main
# loop's `*.json` glob does not match dotfiles by default, so a corr
# starting with `.` is never picked up. The remaining attack surface is
# a corr that the glob CAN see but contains `..` somewhere inside -
# the helper must sanitize such a corr into the invalid-corr subdir so
# it cannot write to `$STATE/x..y/` etc.
CORR3='x..traversal'
QUEUE3="$CASE3_HOME/state/research-dispatch-queue/$CORR3.json"
cat > "$QUEUE3" <<EOJSON
{
  "corr": "$CORR3",
  "seq": 9,
  "revision_seq": "",
  "project_dir": "$CASE3_HOME",
  "attempts": 0,
  "row": {"corr": "$CORR3", "query": "smoke-test-traverse"}
}
EOJSON
chmod 600 "$QUEUE3"

run_drain "$CASE3_HOME" "$CASE3_HOME/bin-mock/spawn-fail.sh" /tmp/drain-case3.stdout /tmp/drain-case3.stderr

# The helper should have sanitized to invalid-corr; nothing escaped.
if [ -d "$CASE3_HOME/state/x..traversal" ]; then
  fail "case3: helper wrote outside state/.dispatch-fail (escaped via x..traversal)"
fi
INVALID_DIR="$CASE3_HOME/state/.dispatch-fail/invalid-corr"
if [ ! -d "$INVALID_DIR" ]; then
  fail "case3: invalid-corr fallback dir not created"
fi
# post-D-5 reconcile encodes a 8-char sha1 suffix into the filename so
# distinct invalid corrs don't share a single log slot. Glob for the
# expected pattern instead of asserting a literal name.
INV_LOG_GLOB=$(printf '%s\n' "$INVALID_DIR"/spawn-fail-attempt-1-*.log 2>/dev/null \
  | head -1)
if [ -z "$INV_LOG_GLOB" ] || [ ! -f "$INV_LOG_GLOB" ]; then
  fail "case3: invalid-corr fallback log not written (expected $INVALID_DIR/spawn-fail-attempt-1-<sha1>.log)"
fi
INV_LOG="$INV_LOG_GLOB"
if ! grep -q '^task_id=x\.\.traversal$' "$INV_LOG" 2>/dev/null; then
  fail "case3: invalid-corr log should preserve original task_id x..traversal in header"
fi
if ! grep -q '^invalid_corr_sha1_8=[0-9a-f]\{8\}$' "$INV_LOG" 2>/dev/null; then
  fail "case3: invalid-corr log should record invalid_corr_sha1_8=<8hex>"
fi

# ---------- Summary ------------------------------------------------------
if [ "$fail_count" -gt 0 ]; then
  echo "RESULT: $fail_count assertion(s) failed"
  exit 1
fi
echo "RESULT: all assertions passed"