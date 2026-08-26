#!/usr/bin/env bash
# fm-research-worker-spawn.sh - spawn one fresh-context worker for a
# report_research task dequeued from the captain inbox.
#
# P2 (2026-08-04 codex C*): each dequeued report_research task starts in its
# own fresh Claude REPL/context, instead of being dumped into the live
# interaction. This helper is the spawn side of that split:
#   1. Idempotency: if data/executor-jobs/<corr>.meta already exists, skip
#      re-spawn (a re-drain must not duplicate short-lived workers).
#   2. Build a brief under data/executor-jobs/<corr>.brief.md from the row.
#   3. Spawn a NEW tmux window in <project_dir> (the spec's "temporary
#      project_dir", defaults to $FM_HOME) via fm_backend_tmux_create_task,
#      then launch a fresh `claude` process inside that window with the brief
#      as its initial prompt. The fresh REPL gives each task its own clean
#      LLM context (P2 spec: "Each task starts in its own fresh context").
#   4. Capture the new claude session_id deterministically: preallocate a UUID
#      before launch and pass it as `claude --session-id <uuid>`. This is an
#      identity, not a launch receipt: Claude's opaque jsonl store may lag, so
#      a successful tmux dispatch is durably recorded without waiting on it.
#   5. Translate that session_id into state/<task-id>.meta (window, no
#      worktree) + data/executor-jobs/<corr>.meta (the long-lived record).
#
# Why we DO NOT go through bin/fm-spawn.sh: that helper depends on
# `treehouse get` to allocate a disposable git worktree. `treehouse get`
# invokes `git fetch origin` as part of its worktree-add prep, which hangs
# indefinitely in this home's environment (2026-08-04, blocked egress).
# Puti's 2026-08-04 P3 spec explicitly authorizes bypassing treehouse:
# the fresh-context requirement is satisfied by a new tmux pane + new claude
# process, NOT by git worktree isolation.
#
# Args:
#   <corr>        inbox row corr (also the meta/brief basename)
#   <row_json>    the verbatim inbox row JSON (one line)
#   [project_dir] defaults to $FM_HOME (firstmate repo as the temporary host;
#                 the runtime receipt phase picks a tighter project per task).
#                 Override with FM_RESEARCH_WORKER_PROJECT_DIR.
#
# Env knobs (testing seam):
#   CLAUDE_CONFIG_DIR             forwarded to the spawned claude so it
#                                 reuses firstmate's resolved store (matches
#                                 bin/fm-spawn.sh's env-forward contract).
#
# Exit:
#   0  spawn succeeded (or was already-done idempotent) -- meta is readable
#   1  spawn failed -- meta is NOT written; inbox-drain keeps offset put
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source tmux >/dev/null || {
  echo "fm-research-worker-spawn: failed to source tmux backend adapter" >&2
  exit 1
}

CORR="${1:-}"
ROW_JSON="${2:-}"
PROJECT_DIR="${3:-${FM_RESEARCH_WORKER_PROJECT_DIR:-${FM_ROOT:-${FM_ROOT_OVERRIDE:-}}}}"

[ -n "$CORR" ]     || { echo "fm-research-worker-spawn: <corr> required" >&2; exit 2; }
[ -n "$ROW_JSON" ] || { echo "fm-research-worker-spawn: <row_json> required" >&2; exit 2; }
[ -n "$PROJECT_DIR" ] || { echo "fm-research-worker-spawn: <project_dir> required" >&2; exit 2; }

PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P || printf '%s' "$PROJECT_DIR")"

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
META_DIR="${FM_EXECUTOR_JOBS_DIR:-$FM_HOME/data/executor-jobs}"
REVISION_SEQ="${FM_RESEARCH_WORKER_REVISION_SEQ:-}"
RUN_KEY="$CORR"
ORIGINAL_BRIEF=
mkdir -p "$META_DIR"

# Revision feedback is a new, fresh worker run for the same corr. It must not
# overwrite or idempotently suppress the original worker receipt.
if [ -n "$REVISION_SEQ" ]; then
  case "$REVISION_SEQ" in ''|*[!0-9]*) echo "fm-research-worker-spawn: revision seq must be an integer" >&2; exit 2 ;; esac
  ORIGINAL_META="$META_DIR/$CORR.meta"
  [ -f "$ORIGINAL_META" ] || { echo "fm-research-worker-spawn: original receipt missing for revision $CORR" >&2; exit 1; }
  ORIGINAL_BRIEF="$(awk -F= '/^brief=/{sub(/^[^=]*=/, ""); print; exit}' "$ORIGINAL_META")"
  [ -f "$ORIGINAL_BRIEF" ] || { echo "fm-research-worker-spawn: original brief missing for revision $CORR" >&2; exit 1; }
  RUN_KEY="$CORR.revision-$REVISION_SEQ"
fi
REVISION_CONTEXT=
if [ -n "$REVISION_SEQ" ]; then
  printf -v REVISION_CONTEXT 'This is revision feedback for corr=%s (feedback seq=%s). Read the original frozen brief at `%s`, revise its declared artifact in place, then submit using the feedback row sequence.\n' "$CORR" "$REVISION_SEQ" "$ORIGINAL_BRIEF"
fi

# ----- 0.5 pre-spawn guard (Wave-3 SOP 2026-08-20) ------------------
# Fail-fast against WSL/Win dual-repo drift AND unverifiable commit refs
# in the brief we're about to write. Both checks are no-ops if the
# helper / brief don't exist, so this is safe to keep on for production
# spawns while remaining a quiet seam for tests.
PRE_SPAWN_GUARD="${CSW_PRE_SPAWN_GUARD:-/mnt/c/Users/westwell/carbon-silicon-workshop/bin/fm-pre-spawn-guard.sh}"
if [ -x "$PRE_SPAWN_GUARD" ]; then
  bash "$PRE_SPAWN_GUARD" --sync-check || {
    rc=$?
    echo "fm-research-worker-spawn: pre-spawn sync-check failed rc=$rc" >&2
    exit $rc
  }
else
  echo "fm-research-worker-spawn: pre-spawn guard not found at $PRE_SPAWN_GUARD (skipping sync check)" >&2
fi

# ----- 1. idempotency -----------------------------------------------------
# A re-drain must not duplicate the same normal or revision worker run.
if [ -f "$META_DIR/$RUN_KEY.meta" ]; then
  cat "$META_DIR/$RUN_KEY.meta"
  exit 0
fi

# ----- 2. build brief -----------------------------------------------------
extract_row_artifact() {
  python3 - "$ROW_JSON" <<'PY'
import json, re, sys
try:
    row = json.loads(sys.argv[1])
except json.JSONDecodeError:
    raise SystemExit(0)

candidate = row.get("artifact_path")
if not candidate:
    body = row.get("body") or row.get("text") or ""
    match = re.search(r'--artifact\s+(?:"([^"]+)"|\'([^\']+)\'|(\S+))', body)
    if match:
        candidate = next(value for value in match.groups() if value is not None)
if candidate:
    print(candidate)
PY
}

normalize_artifact_path() {
  python3 - "$FM_HOME" "$1" <<'PY'
import os, sys
home, candidate = sys.argv[1:]
root = os.path.abspath(os.path.join(home, "data"))
candidate = os.path.expanduser(candidate)
if not os.path.isabs(candidate):
    candidate = os.path.join(home, candidate)
path = os.path.abspath(candidate)
try:
    allowed = os.path.commonpath((root, path)) == root
except ValueError:
    allowed = False
if not allowed:
    raise SystemExit("artifact must stay under %s: %s" % (root, path))
print(path)
PY
}

if [ -n "$REVISION_SEQ" ]; then
  ARTIFACT_CANDIDATE="$(awk -F= '/^artifact=/{sub(/^[^=]*=/, ""); print; exit}' "$ORIGINAL_META")"
  if [ -z "$ARTIFACT_CANDIDATE" ]; then
    ARTIFACT_CANDIDATE="$(sed -nE 's/^[[:space:]]*--artifact[[:space:]]+"([^"]+)".*/\1/p' "$ORIGINAL_BRIEF" | head -n1)"
  fi
else
  ARTIFACT_CANDIDATE="$(extract_row_artifact)"
fi
ARTIFACT_CANDIDATE="${ARTIFACT_CANDIDATE:-$FM_HOME/data/$CORR/report.md}"
ARTIFACT_PATH="$(normalize_artifact_path "$ARTIFACT_CANDIDATE")" || {
  echo "fm-research-worker-spawn: invalid artifact path: $ARTIFACT_CANDIDATE" >&2
  exit 2
}
mkdir -p "$(dirname "$ARTIFACT_PATH")"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The executor-jobs copy is the long-lived record (the meta cites it).
# We keep the brief at $META_DIR/<corr>.brief.md (no separate FM_HOME copy;
# the spawn no longer goes through fm-spawn, which used to require
# $FM_HOME/data/<task-id>/brief.md as the canonical path).
TASK_ID="executor-${CORR}${REVISION_SEQ:+-r$REVISION_SEQ}-$(date +%s)"
DATA_BRIEF="$META_DIR/$RUN_KEY.brief.md"
META_BRIEF="$DATA_BRIEF"
mkdir -p "$META_DIR"
cat > "$DATA_BRIEF" <<EOF
# Research Task: $CORR

corr: $CORR
task_type: report_research
enqueued_at: $TS
task_id: $TASK_ID

## Row (verbatim, from controller)
\`\`\`json
$ROW_JSON
\`\`\`

## Setup (gh research — only if cloning/fetching github.com or reading raw.githubusercontent.com)
If this task needs GitHub read access, source the read-only proxy env first:
```
source /home/fm-captain/firstmate/bin/fm-proxy-env.sh
```
Exports http_proxy/https_proxy to Windows host proxy:7890 (WSL2 NAT gateway, resolved dynamically). No credentials, read-only. For push, do NOT attempt locally — escalate to captain (B2 path: fm produces commits, captain pushes via Windows gh-axi).

## Worker runtime contract
You are a report-research worker, not a primary Firstmate session. Do NOT run
\`bin/fm-session-start.sh\`, \`bin/fm-lock.sh\`, bootstrap, wake drain, watcher
arming, or fleet operations: the primary owns that lock and those mutations.
Your allowed shared-state operation is the declared \`fm-review-submit.sh\` call.

## What you do
You are a fresh-context worker. The row JSON above is the task spec from
the controller. Extract \`must_answer\`, \`evidence.windows_roots\`,
\`windows_roots\`, and any contract fields the schema declares, then run
the bounded research and produce a report.

## Output
Write \`$ARTIFACT_PATH\` following the
codex-review-standard.md §2 minimum packet format (status header,
Question, Background, Current Truth Read, Q1..QN, Verification,
Known Tradeoffs, Need Codex Decision, Completion / Cleanup).

## Submit
Once the report is on disk, submit via the review-submit helper so the
controller's review pipeline can pick it up:

\`\`\`
bash bin/fm-review-submit.sh \\
  --corr "$CORR" \\
  --reply-to-seq <seq-from-row-json> \\
  --artifact "$ARTIFACT_PATH"
\`\`\`

(Extract the seq from the row JSON; if the controller did not include
one, fall back to 0 and the captain will reconcile.)

## Revision mode
$REVISION_CONTEXT

## Boundaries
- Do not modify the controller, P3, or the preserved job25 paused evidence.
- Do not resume or re-enroll anything; this is a one-shot bounded job.
- Stay within the windows_roots the contract declares; do not read or
  write outside the listed evidence paths.
EOF

# ----- 2.5 verify brief commit refs (Wave-3 SOP 2026-08-20) --------------
if [ -x "$PRE_SPAWN_GUARD" ]; then
  bash "$PRE_SPAWN_GUARD" --brief-commit-verify "$DATA_BRIEF" || {
    rc=$?
    echo "fm-research-worker-spawn: brief commit-verify failed rc=$rc" >&2
    exit $rc
  }
fi

# ----- 3. spawn worker (direct tmux + claude, NO treehouse) ---------------
SPAWN_OUT="$META_DIR/$RUN_KEY.spawn.out"
SPAWN_RC=0

# 3a. Allocate this worker's session id before launch. Claude supports
# --session-id, so this avoids racing concurrent workers by inferring an id
# from whichever jsonl file appears next in a shared project directory.
TMUX_SESSION="$(fm_backend_tmux_container_ensure)"
WINDOW_NAME="fm-executor-${RUN_KEY}"
SESSION_ID="$(cat /proc/sys/kernel/random/uuid)"
WORKER_LOG="$META_DIR/$RUN_KEY.worker.log"

# 3b. Create the dedicated worker window. Preserve the backend adapter failure
# code; `if ! command; then $?` would only observe the status of `!` (zero).
if WINDOW_ID="$(fm_backend_tmux_create_task "$TMUX_SESSION" "$WINDOW_NAME" "$PROJECT_DIR")"; then
  :
else
  SPAWN_RC=$?
  rm -f "$DATA_BRIEF"
  echo "fm-research-worker-spawn: tmux create failed rc=$SPAWN_RC" >&2
  exit 1
fi
WINDOW_TARGET="${WINDOW_ID:-${TMUX_SESSION}:${WINDOW_NAME}}"

# 3c-prime. Wait for the new window's interactive shell to actually be reading
# input. A freshly-created window can exist before its startup files and line
# editor are ready to accept Enter as a submit (verified live on a nested tmux
# setup: the first send-keys silently dropped the command, leaving the pane at
# a blank prompt with no worker process ever started). The probe mirrors the
# warm-up loop in tests/fm-backend-tmux-smoke.test.sh: a tiny printf the shell
# can only run after it has accepted input and produced output.
#
# The probe count and sleep are env-tunable so the tests can shorten them
# without weakening the production path. Defaults are 50 attempts of 0.1s
# = up to 5s of waiting before fail-closed.
PROBE_ATTEMPTS="${FM_RESEARCH_WORKER_SHELL_READY_ATTEMPTS:-50}"
PROBE_SLEEP="${FM_RESEARCH_WORKER_SHELL_READY_SLEEP:-0.1}"
case "$PROBE_ATTEMPTS" in ''|*[!0-9]*) PROBE_ATTEMPTS=50 ;; esac
case "$PROBE_SLEEP" in
  ''|*[!0-9.]*) PROBE_SLEEP=0.1 ;;
  *) [ "$(awk "BEGIN{print ($PROBE_SLEEP <= 0)}")" = "1" ] && PROBE_SLEEP=0.1 ;;
esac
PROBE_TOKEN="fm-rws-shell-ready-$$"
SHELL_READY=0
for _ in $(seq 1 "$PROBE_ATTEMPTS"); do
  tmux send-keys -t "$WINDOW_TARGET" C-c >/dev/null 2>&1 || true
  tmux send-keys -t "$WINDOW_TARGET" -l "printf '${PROBE_TOKEN}\\n'" >/dev/null 2>&1 || true
  tmux send-keys -t "$WINDOW_TARGET" Enter >/dev/null 2>&1 || true
  if fm_backend_tmux_capture "$WINDOW_TARGET" 200 2>/dev/null | grep -q "$PROBE_TOKEN"; then
    SHELL_READY=1
    break
  fi
  sleep "$PROBE_SLEEP"
done
if [ "$SHELL_READY" -ne 1 ]; then
  tmux kill-window -t "$WINDOW_TARGET" 2>/dev/null || true
  rm -f "$DATA_BRIEF"
  echo "fm-research-worker-spawn: tmux window $WINDOW_TARGET shell did not become ready for input within $((PROBE_ATTEMPTS * 100 / 10))ms" >&2
  exit 1
fi

# 3c. Launch a one-shot fresh worker. Pass the task through stdin rather than
# typing its full content into tmux: task text cannot be reinterpreted as shell
# syntax. The launch command does NOT use `exec`: claude -p runs as a child
# of the persistent shell, so the pane stays alive until claude itself exits,
# and the watcher can clean up the window via kill-window once the worker
# submits. (Earlier revisions used `exec` to short-circuit the shell, but on
# a nested tmux setup the parent shell's exit closed the pane before claude
# had a chance to bind to the controlling tty, so we let the shell stick
# around.) A sent command is the worker receipt; jsonl persistence is
# intentionally not a readiness gate.
#
# Why literal + sleep + send_key Enter instead of fm_backend_tmux_send_text_line:
# a freshly-created window's interactive shell can exist before its startup
# files and line editor are ready to accept Enter as a submit (verified live
# on a nested tmux setup: the first send-keys with text+Enter in one call
# silently dropped the command, leaving the pane at a blank prompt with no
# claude -p process ever started). fm-spawn.sh's launch command already uses
# this 3-step pattern for the same reason; we mirror it here.
printf -v Q_SESSION '%q' "$SESSION_ID"
printf -v Q_BRIEF '%q' "$DATA_BRIEF"
printf -v Q_LOG '%q' "$WORKER_LOG"
LAUNCH_CMD="env FM_RESEARCH_WORKER=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false MAX_THINKING_TOKENS=32000 claude -p --permission-mode bypassPermissions --session-id $Q_SESSION < $Q_BRIEF > $Q_LOG 2>&1"
if fm_backend_tmux_send_literal "$WINDOW_TARGET" "$LAUNCH_CMD"; then
  sleep 0.3
  if fm_backend_tmux_send_key "$WINDOW_TARGET" Enter; then
    :
  else
    SPAWN_RC=$?
    tmux kill-window -t "$WINDOW_TARGET" 2>/dev/null || true
    rm -f "$DATA_BRIEF"
    echo "fm-research-worker-spawn: send_key Enter to $WINDOW_TARGET failed rc=$SPAWN_RC" >&2
    exit 1
  fi
else
  SPAWN_RC=$?
  tmux kill-window -t "$WINDOW_TARGET" 2>/dev/null || true
  rm -f "$DATA_BRIEF"
  echo "fm-research-worker-spawn: send_literal to $WINDOW_TARGET failed rc=$SPAWN_RC" >&2
  exit 1
fi

# ----- 4. translate meta --------------------------------------------------
# state/<task-id>.meta mirrors fm-spawn's shape so downstream consumers
# (busy-state readers, watch hooks) keep working. We deliberately OMIT
# worktree= since the spec says no worktree is created.
META_FILE="$FM_HOME/state/$TASK_ID.meta"
mkdir -p "$(dirname "$META_FILE")"
cat > "$META_FILE" <<META
window=$WINDOW_TARGET
endpoint_task_id=$TASK_ID
project=$PROJECT_DIR
harness=claude
kind=mate
mode=primary
yolo=off
model=default
effort=default
session_id=$SESSION_ID
started_at=$TS
META

cat > "$META_DIR/$RUN_KEY.meta" <<META
corr=$CORR
session_id=$SESSION_ID
window=$WINDOW_TARGET
task_id=$TASK_ID
started_at=$TS
task_type=report_research
brief=$META_BRIEF
revision_seq=$REVISION_SEQ
revision_of=$([ -z "$REVISION_SEQ" ] || printf '%s' "$CORR")
artifact=$ARTIFACT_PATH
META

cat "$META_DIR/$RUN_KEY.meta"
