#!/usr/bin/env bash
# tests/fm-research-worker-spawn.test.sh - direct tmux+claude spawn path
# (P3 2026-08-04 Puti spec: bypass treehouse, fresh tmux pane + fresh claude).
#
# Verifies the post-rewrite bin/fm-research-worker-spawn.sh:
#   1. Idempotency: a second invocation with the same <corr> skips the
#      spawn (no new tmux/claude call) and re-cats the existing meta.
#   2. Direct tmux path: the helper calls tmux new-window with the
#      project_dir (NOT a treehouse worktree path) and launches claude
#      --dangerously-skip-permissions with the brief as the initial prompt.
#   3. Session-id capture: the helper discovers the new claude's
#      session_id by polling ~/.claude/projects/<encoded-cwd>/ for a new
#      *.jsonl file (no fm-spawn.sh involvement, no treehouse get).
#   4. Distinct sessions per task: two distinct <corr> values produce two
#      distinct session_ids in their executor-jobs/<corr>.meta files
#      (the P2 spec's "each task starts in its own fresh context").
#   5. Fail-closed: a spawn that yields no session_id within the wait
#      budget exits non-zero WITHOUT writing executor-jobs/<corr>.meta,
#      so a re-drain can retry.
#
# Stubbing strategy: fake tmux + fake claude on PATH. The fake claude
# creates a fake session jsonl in $CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/
# to match the helper's polling location.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN_HELPER="$ROOT/bin/fm-research-worker-spawn.sh"
INBOX_DRAIN="$ROOT/bin/fm-captain-inbox-drain.sh"

[ -x "$SPAWN_HELPER" ] || fail "research-worker-spawn not executable"
[ -x "$INBOX_DRAIN" ]  || fail "captain-inbox-drain not executable"

TMP_ROOT=$(fm_test_tmproot fm-research-worker-spawn)

#======================================================================
# Build the fake bin. fake tmux records every invocation; fake claude
# creates a session jsonl in the helper's expected poll location.
#======================================================================
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
# Fake tmux: minimal commands used by fm_backend_tmux_container_ensure
# + fm_backend_tmux_create_task. Records every invocation.
echo "tmux $*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "$1" in
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  list-windows) exit 0 ;;
  new-window)
    if [ "${FM_FAKE_TMUX_FAIL_NEW_WINDOW:-0}" = "1" ]; then
      exit 7
    fi
    # Print a stable window id (matching tmux's @N format).
    printf '%s\n' "@1"
    exit 0
    ;;
  set-window-option) exit 0 ;;
  send-keys)
    # The production adapter submits a shell command into the new tmux
    # window. Execute that command in the fake so this test exercises the
    # session-file boundary instead of merely asserting a send-keys call.
    shift
    if [ "${1:-}" = "-t" ]; then shift 2; fi
    text="${1:-}"
    case "$text" in
      *" claude "*) bash -c "$text" ;;
    esac
    exit 0
    ;;
  kill-window) exit 0 ;;
  display-message) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
# Fake claude: require the production launch contract to preallocate a
# session id, then materialize exactly that session file. This makes the test
# catch both missing --session-id and wrong encoded-cwd lookup without racing
# on whichever concurrent worker happens to create a jsonl first.
proj_dir="${FM_FAKE_CLAUDE_PROJECT_DIR:?}"
session_id=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--session-id" ]; then session_id="$arg"; break; fi
  prev="$arg"
done
[ -n "$session_id" ] || { echo "fake claude: --session-id required" >&2; exit 64; }
session_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$proj_dir" | tr '/.' '--')"
mkdir -p "$session_dir"
printf '%s\n' "$*" >> "${FM_FAKE_CLAUDE_LOG:?}"
echo "{\"sessionId\":\"$session_id\",\"type\":\"start\"}" > "$session_dir/$session_id.jsonl"
exit 0
SH
chmod +x "$FAKEBIN/claude"

# Stub the rest of fm_backend_tmux_create_task's command set so the helper
# never accidentally invokes a real binary that we forgot.
fm_fake_exit0 "$FAKEBIN" git

#======================================================================
# Case 1: idempotency on re-drain
#======================================================================
CASE="$TMP_ROOT/idempotent"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs" "$CASE/.claude/projects"
export FM_HOME="$CASE"
export FM_ROOT_OVERRIDE="$CASE"
export CLAUDE_CONFIG_DIR="$CASE/.claude"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_TMUX_LOG="$CASE/fake-tmux.log"
export FM_FAKE_CLAUDE_LOG="$CASE/fake-claude.log"
export FM_FAKE_CLAUDE_PROJECT_DIR="$CASE"
export FM_RESEARCH_WORKER_SESSION_WAIT=5

CORR="rws-idemp-$RANDOM"
ROW_JSON='{"task_type":"report_research","must_answer":["Q1"]}'

# First invocation: spawns a worker.
set +e
OUT_FIRST="$(bash "$SPAWN_HELPER" "$CORR" "$ROW_JSON" "$CASE" 2>&1)"
RC_FIRST=$?
set -e
[ "$RC_FIRST" = "0" ] || fail "1. first spawn failed rc=$RC_FIRST: $OUT_FIRST"
[ -f "$CASE/data/executor-jobs/$CORR.meta" ] || fail "1. meta missing after first spawn: $OUT_FIRST"
SESSION_FIRST="$(grep '^session_id=' "$CASE/data/executor-jobs/$CORR.meta" | cut -d= -f2-)"
[ -n "$SESSION_FIRST" ] || fail "1. session_id missing from first meta: $(cat "$CASE/data/executor-jobs/$CORR.meta")"
FAKE_TMUX_BEFORE="$(wc -l < "$CASE/fake-tmux.log")"
pass "1-pre. first spawn wrote meta (session=$SESSION_FIRST, tmux-calls=$FAKE_TMUX_BEFORE)"

# Second invocation: idempotency must skip the spawn entirely.
set +e
OUT_SECOND="$(bash "$SPAWN_HELPER" "$CORR" "$ROW_JSON" "$CASE" 2>&1)"
RC_SECOND=$?
set -e
[ "$RC_SECOND" = "0" ] || fail "1. second spawn failed rc=$RC_SECOND: $OUT_SECOND"
FAKE_TMUX_AFTER="$(wc -l < "$CASE/fake-tmux.log")"
[ "$FAKE_TMUX_AFTER" = "$FAKE_TMUX_BEFORE" ] \
  || fail "1. helper re-spawned on re-invocation (idempotency leaked): before=$FAKE_TMUX_BEFORE after=$FAKE_TMUX_AFTER"
SESSION_SECOND="$(grep '^session_id=' "$CASE/data/executor-jobs/$CORR.meta" | cut -d= -f2-)"
[ "$SESSION_SECOND" = "$SESSION_FIRST" ] \
  || fail "1. session_id changed on re-invocation: first=$SESSION_FIRST second=$SESSION_SECOND"
pass "1. idempotency: re-invocation skips spawn, meta unchanged"

#======================================================================
# Case 2: direct tmux path (NOT treehouse worktree, NOT fm-spawn)
#======================================================================
CASE="$TMP_ROOT/direct-tmux"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs" "$CASE/.claude/projects"
export FM_HOME="$CASE"
export FM_ROOT_OVERRIDE="$CASE"
export CLAUDE_CONFIG_DIR="$CASE/.claude"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_TMUX_LOG="$CASE/fake-tmux.log"
export FM_FAKE_CLAUDE_LOG="$CASE/fake-claude.log"
export FM_FAKE_CLAUDE_PROJECT_DIR="$CASE"
export FM_RESEARCH_WORKER_SESSION_WAIT=5

CORR="rws-direct-$RANDOM"
ROW_JSON='{"task_type":"report_research","must_answer":["Q1"]}'

bash "$SPAWN_HELPER" "$CORR" "$ROW_JSON" "$CASE" >/dev/null 2>&1 \
  || fail "2. spawn failed: $(cat "$CASE/data/executor-jobs/$CORR.spawn.out" 2>/dev/null)"

# The tmux log must show the new-window call with the project_dir (NOT a
# treehouse worktree path).
grep -E "new-window.*-c.*$CASE" "$CASE/fake-tmux.log" >/dev/null \
  || fail "2. tmux new-window was not called with project_dir=$CASE; log: $(cat "$CASE/fake-tmux.log")"
pass "2a. tmux new-window invoked with project_dir (NOT treehouse worktree)"

# No treehouse invocation should appear anywhere.
grep -E "(^|\\s)treehouse(\\s|$)" "$CASE/fake-tmux.log" >/dev/null \
  && fail "2. helper called treehouse; should bypass it: $(cat "$CASE/fake-tmux.log")"
pass "2b. treehouse NOT invoked (bypass path verified)"

# No fm-spawn.sh invocation either (the old helper called it).
ls "$CASE/data/executor-jobs/$CORR.spawn.out" 2>/dev/null && \
  grep -E "fm-spawn" "$CASE/data/executor-jobs/$CORR.spawn.out" 2>/dev/null \
  && fail "2. spawn.out references fm-spawn (should be empty on success): $(cat "$CASE/data/executor-jobs/$CORR.spawn.out" 2>/dev/null)"
pass "2c. fm-spawn.sh NOT called (direct path)"

grep -E -- "--permission-mode bypassPermissions.*--session-id" "$CASE/fake-claude.log" >/dev/null \
  || fail "2d. direct worker launch must use bypassPermissions + preallocated session id: $(cat "$CASE/fake-claude.log")"
pass "2d. direct worker launch preallocates its session id"

#======================================================================
# Case 3: session_id capture from $CLAUDE_CONFIG_DIR/projects/<encoded>/
#======================================================================
CASE="$TMP_ROOT/session-capture"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs" "$CASE/.claude/projects"
export FM_HOME="$CASE"
export FM_ROOT_OVERRIDE="$CASE"
export CLAUDE_CONFIG_DIR="$CASE/.claude"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_TMUX_LOG="$CASE/fake-tmux.log"
export FM_FAKE_CLAUDE_LOG="$CASE/fake-claude.log"
export FM_FAKE_CLAUDE_PROJECT_DIR="$CASE"
export FM_RESEARCH_WORKER_SESSION_WAIT=5

CORR="rws-capture-$RANDOM"
ROW_JSON='{"task_type":"report_research","must_answer":["Q1"]}'

bash "$SPAWN_HELPER" "$CORR" "$ROW_JSON" "$CASE" >/dev/null 2>&1 \
  || fail "3. spawn failed: $(cat "$CASE/data/executor-jobs/$CORR.spawn.out" 2>/dev/null)"

# session_id must appear in the meta and the state file.
SESSION_ID="$(grep '^session_id=' "$CASE/data/executor-jobs/$CORR.meta" | cut -d= -f2-)"
[ -n "$SESSION_ID" ] || fail "3. session_id missing from meta"
grep -E "^session_id=$SESSION_ID" "$CASE/state/executor-$CORR-"*.meta >/dev/null 2>&1 \
  || fail "3. session_id missing from state meta: $(ls "$CASE/state/" 2>/dev/null)"
pass "3a. session_id captured from $CLAUDE_CONFIG_DIR/projects/<encoded>/"

# state meta MUST NOT include a worktree= line (P3 spec: no worktree).
grep -E "^worktree=" "$CASE/state/executor-$CORR-"*.meta >/dev/null 2>&1 \
  && fail "3. state meta contains worktree= (spec says no worktree)"
pass "3b. state meta has no worktree= line (per P3 spec)"

#======================================================================
# Case 4: distinct sessions per task
#======================================================================
CASE="$TMP_ROOT/distinct"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs" "$CASE/.claude/projects"
export FM_HOME="$CASE"
export FM_ROOT_OVERRIDE="$CASE"
export CLAUDE_CONFIG_DIR="$CASE/.claude"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_TMUX_LOG="$CASE/fake-tmux.log"
export FM_FAKE_CLAUDE_LOG="$CASE/fake-claude.log"
export FM_FAKE_CLAUDE_PROJECT_DIR="$CASE"
export FM_RESEARCH_WORKER_SESSION_WAIT=5

CORR_A="rws-distinct-A-$RANDOM"
CORR_B="rws-distinct-B-$RANDOM"

bash "$SPAWN_HELPER" "$CORR_A" '{"task_type":"report_research"}' "$CASE" >/dev/null 2>&1 \
  || fail "4. spawn A failed: $(cat "$CASE/data/executor-jobs/$CORR_A.spawn.out" 2>/dev/null)"
bash "$SPAWN_HELPER" "$CORR_B" '{"task_type":"report_research"}' "$CASE" >/dev/null 2>&1 \
  || fail "4. spawn B failed: $(cat "$CASE/data/executor-jobs/$CORR_B.spawn.out" 2>/dev/null)"

SESSION_A="$(grep '^session_id=' "$CASE/data/executor-jobs/$CORR_A.meta" | cut -d= -f2-)"
SESSION_B="$(grep '^session_id=' "$CASE/data/executor-jobs/$CORR_B.meta" | cut -d= -f2-)"
[ -n "$SESSION_A" ] && [ -n "$SESSION_B" ] \
  || fail "4. session_ids missing: A=$SESSION_A B=$SESSION_B"
[ "$SESSION_A" != "$SESSION_B" ] \
  || fail "4. session_ids must be distinct (fresh context per task); both=$SESSION_A"
pass "4. two distinct report_research tasks -> two distinct session_ids"

#======================================================================
# Case 5: tmux window creation failure must stop before launch
#======================================================================
CASE="$TMP_ROOT/tmux-create-fail"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs" "$CASE/.claude/projects"
export FM_HOME="$CASE"
export FM_ROOT_OVERRIDE="$CASE"
export CLAUDE_CONFIG_DIR="$CASE/.claude"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_TMUX_LOG="$CASE/fake-tmux.log"
export FM_FAKE_CLAUDE_LOG="$CASE/fake-claude.log"
export FM_FAKE_CLAUDE_PROJECT_DIR="$CASE"
export FM_RESEARCH_WORKER_SESSION_WAIT=2
export FM_FAKE_TMUX_FAIL_NEW_WINDOW=1

CORR="rws-tmux-fail-$RANDOM"
set +e
OUT="$(bash "$SPAWN_HELPER" "$CORR" '{"task_type":"report_research"}' "$CASE" 2>&1)"
RC=$?
set -e
unset FM_FAKE_TMUX_FAIL_NEW_WINDOW

[ "$RC" != "0" ] || fail "5. helper must fail when tmux new-window fails; out=$OUT"
case "$OUT" in
  *"tmux create failed rc=1"*) ;;
  *) fail "5. helper did not fail closed on tmux create failure: $OUT" ;;
esac
[ ! -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "5. meta written after tmux create failure"
pass "5. tmux create failure is fail-closed before claude launch"

#======================================================================
# Case 6: fail-closed when no session_id is captured
#======================================================================
CASE="$TMP_ROOT/fail-closed"
mkdir -p "$CASE/state" "$CASE/data/executor-jobs" "$CASE/.claude/projects"
export FM_HOME="$CASE"
export FM_ROOT_OVERRIDE="$CASE"
export CLAUDE_CONFIG_DIR="$CASE/.claude"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_TMUX_LOG="$CASE/fake-tmux.log"
export FM_FAKE_CLAUDE_LOG="$CASE/fake-claude.log"
export FM_FAKE_CLAUDE_PROJECT_DIR="$CASE"
export FM_RESEARCH_WORKER_SESSION_WAIT=2  # tight wait so the test fails fast

# Fake claude that does NOT write a session jsonl (simulates a slow
# / never-starting claude).
cat > "$FAKEBIN/claude-no-session" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/claude-no-session"
# Make the helper invoke the no-session fake by pointing CLAUDE at it
# via PATH (it sits before the real fake in PATH... no wait, we need
# the no-session one to be the one that runs). Simplest: replace claude
# in the fakebin with the no-session one for this case.
cp "$FAKEBIN/claude-no-session" "$FAKEBIN/claude"
chmod +x "$FAKEBIN/claude"

CORR="rws-fail-$RANDOM"
ROW_JSON='{"task_type":"report_research","must_answer":["Q1"]}'

set +e
OUT="$(bash "$SPAWN_HELPER" "$CORR" "$ROW_JSON" "$CASE" 2>&1)"
RC=$?
set -e
[ "$RC" != "0" ] || fail "6. helper must exit non-zero when session_id not captured (rc=$RC)"
grep -E "session_id capture failed" "$CASE/data/executor-jobs/$CORR.spawn.out" >/dev/null \
  || fail "6. spawn.out missing 'session_id capture failed' marker; out=$OUT; spawn.out=$(cat "$CASE/data/executor-jobs/$CORR.spawn.out" 2>/dev/null)"
pass "6a. helper exits non-zero when no session_id is captured"

# Critically: NO executor-jobs/<corr>.meta file.
[ ! -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "5. meta file written despite spawn failure: $(cat "$CASE/data/executor-jobs/$CORR.meta")"
pass "6b. no executor-jobs/<corr>.meta on failure (fail-closed contract)"

# No state/<task-id>.meta either.
shopt -s nullglob
state_metas=("$CASE/state/executor-$CORR-"*.meta)
shopt -u nullglob
[ "${#state_metas[@]}" -eq 0 ] \
  || fail "5. state meta written despite spawn failure: ${state_metas[*]}"
pass "6c. no state/<task-id>.meta on failure"

echo "ok - all fm-research-worker-spawn tests passed"
