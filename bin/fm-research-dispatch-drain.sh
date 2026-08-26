#!/usr/bin/env bash
# fm-research-dispatch-drain.sh - retry durable report_research admissions,
# including post-spawn worker-death detection and requeue.
#
# Two responsibilities per drain run:
#
#   1. Queue dispatch (existing): for every *.json in state/research-dispatch-queue,
#      try the spawn helper; on success the queue file is removed; on failure the
#      attempt count is incremented and <queue>.spawn.last.err carries the last
#      spawn's stderr (the failure-evidence contract fixed by ov-0824-A).
#
#   2. In-flight reconciliation (new): for every executor meta in
#      data/executor-jobs/<corr>.meta left behind by a successful spawn, check
#      whether the worker is still alive. Dead workers without a submitted
#      artifact are requeued: the queue file is rebuilt from the brief's
#      embedded row JSON, attempts are incremented, worker.log is preserved
#      as .worker.last.err, and the meta is dropped so the next round re-spawns.
#
# Why the queue file disappears on spawn success: that is the pre-existing
# contract the rest of firstmate relies on (case 2 of
# fm-research-dispatch-queue.test.sh pins it). Worker-death detection therefore
# reconstructs the queue file from the brief, the durable copy of the row JSON
# the spawn helper embeds for exactly this kind of recovery.
#
# Why we do not introduce a separate in-flight registry: the executor meta is
# already written on every successful spawn (see fm-research-worker-spawn.sh),
# so adding a parallel file would duplicate state without buying anything.
#
# Death detection: drain calls `$DEATH_CHECK <window_target>` once per in-flight
# worker. Production default = `fm_backend_tmux_agent_state` (the same verifier
# bin/fm-watch.sh uses); the env override is a deliberate testing seam so the
# regression suite can simulate worker death without a live tmux pane.
# The verifier returns one token on stdout: `alive` skips the worker, anything
# else (dead/missing/unreadable/ambiguous) triggers requeue.
#
# Args:
#   (none)
#
# Env knobs (production default / test override):
#   FM_RESEARCH_WORKER_SPAWN       spawn helper path
#   FM_RESEARCH_DEATH_CHECK_CMD    worker-death verifier command (default:
#                                  fm_backend_tmux_agent_state)
#   FM_RESEARCH_DISPATCH_QUEUE_DIR queue directory override
#   FM_RESEARCH_DISPATCH_RETRY_MAX attempt budget (default 3)
#   FM_RESEARCH_WORKER_PROJECT_DIR passed through to the spawn helper
#
# Exit:
#   0 always; loop body uses `continue` for per-item short-circuits and
#   leaves the parent's flock intact for the next queue file.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-wake-lib.sh"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${STATE:-$FM_HOME/state}"
QUEUE_DIR="${FM_RESEARCH_DISPATCH_QUEUE_DIR:-$STATE/research-dispatch-queue}"
SPAWN_HELPER="${FM_RESEARCH_WORKER_SPAWN:-$SCRIPT_DIR/fm-research-worker-spawn.sh}"
MAX_ATTEMPTS="${FM_RESEARCH_DISPATCH_RETRY_MAX:-3}"
EXECUTOR_JOBS_DIR="${FM_EXECUTOR_JOBS_DIR:-$FM_HOME/data/executor-jobs}"
DEATH_CHECK="${FM_RESEARCH_DEATH_CHECK_CMD:-fm_backend_tmux_agent_state}"
LOCK="$STATE/.research-dispatch.lock"
mkdir -p "$QUEUE_DIR" "$EXECUTOR_JOBS_DIR"
case "$MAX_ATTEMPTS" in ''|*[!0-9]*) MAX_ATTEMPTS=3 ;; esac
[ "$MAX_ATTEMPTS" -gt 0 ] || MAX_ATTEMPTS=3
exec 9>"$LOCK"
flock 9
shopt -s nullglob

# resolve_meta_field: pull a single field from the executor meta.
resolve_meta_field() {  # <meta_file> <field>
  awk -F= -v field="$2" '$1==field{sub(/^[^=]*=/, ""); print; exit}' "$1" 2>/dev/null
}

# extract_row_from_brief: pull the JSON block the spawn helper embedded in the
# brief file (the "Row (verbatim, from controller)" section). Echoes the raw
# row JSON on success, exits 0 with no output when the brief is missing or the
# block cannot be located.
extract_row_from_brief() {  # <brief_path>
  local brief=$1
  [ -f "$brief" ] || return 0
  awk '
    /```json[[:space:]]*$/ { capture=1; next }
    capture && /^```[[:space:]]*$/ { capture=0; exit }
    capture { sub(/^[[:space:]]+/, ""); print }
  ' "$brief"
}

# requeue_worker: rebuild the queue file for a dead worker so the next drain
# round re-spawns it. The queue file is rebuilt from the brief's embedded row
# JSON, with .attempts inherited (incremented). worker.log is preserved as
# .worker.last.err; the executor meta is dropped.
requeue_worker() {  # <meta_file> <corr> <window> <liveness>
  local meta_file=$1 corr=$2 window_target=$3 liveness=$4
  local attempts brief_path next tmp_file
  local worker_log worker_last_err row_json project_dir queue_file

  # Prefer the queue file's attempts (the authoritative counter while
  # the item is queued), then the meta's (the durable bridge after a
  # successful spawn deleted the queue), then zero.
  queue_file="$QUEUE_DIR/$corr.json"
  if [ -f "$queue_file" ]; then
    attempts="$(jq -r '.attempts // 0' "$queue_file" 2>/dev/null || echo 0)"
  else
    attempts="$(resolve_meta_field "$meta_file" attempts || true)"
  fi
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  next=$((attempts + 1))
  brief_path="$(resolve_meta_field "$meta_file" brief || true)"
  row_json="$(extract_row_from_brief "$brief_path")"
  project_dir="${FM_RESEARCH_WORKER_PROJECT_DIR:-$FM_HOME}"

  if [ -z "$row_json" ]; then
    # Without a row JSON we cannot rebuild the queue file. Leave the meta
    # alone so the next drain has another chance, and surface the dead
    # worker so an operator can triage manually.
    echo "dispatch worker death unrecoverable: corr=$corr window=$window_target liveness=$liveness (no row JSON in $brief_path)" >&2
    return 1
  fi

  tmp_file="$(mktemp "$QUEUE_DIR/.retry.XXXXXX")"
  # Write the rebuilt queue file as <corr>.json.requeued. The main loop
  # only processes *.json files, so this drain's main loop will NOT
  # pick it up; the NEXT drain will rename *.json.requeued to *.json
  # at the top of its main loop, then spawn normally. Splitting the
  # requeue from the respawn keeps the state machine observable and
  # makes the death/requeue event visible on its own drain.
  if jq -cn --arg corr "$corr" --argjson row "$row_json" \
      --arg project_dir "$project_dir" --argjson attempts "$next" \
      '{corr:$corr,seq:0,revision_seq:"",project_dir:$project_dir,attempts:$attempts,row:$row}' \
      > "$tmp_file"; then
    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$QUEUE_DIR/$corr.json.requeued"
  else
    rm -f "$tmp_file"
    echo "dispatch worker death requeue failed: corr=$corr (could not write queue file)" >&2
    return 1
  fi

  worker_log="$EXECUTOR_JOBS_DIR/$corr.worker.log"
  worker_last_err="$EXECUTOR_JOBS_DIR/$corr.worker.last.err"
  if [ -f "$worker_log" ]; then
    if ! mv -f "$worker_log" "$worker_last_err" 2>/dev/null; then
      : > "$worker_last_err"
      cat "$worker_log" >>"$worker_last_err" 2>/dev/null || true
      rm -f "$worker_log"
    fi
  fi

  rm -f "$meta_file"

  echo "dispatch worker death: corr=$corr window=$window_target liveness=$liveness" >&2
  if [ "$next" -lt "$MAX_ATTEMPTS" ]; then
    echo "dispatch requeue attempt=$next/$MAX_ATTEMPTS corr=$corr evidence=$worker_last_err" >&2
    fm_wake_append signal research-dispatch "worker-dead corr=$corr" || true
  else
    # Crossing the budget still leaves the requeued file behind with
    # attempts=$next so the main loop's queue-budget guard can surface
    # a `dispatch paused: ... attempts=N/3` line on every subsequent
    # drain until an operator triages.
    echo "dispatch requeue attempt=$next/$MAX_ATTEMPTS corr=$corr evidence=$worker_last_err (budget reached)" >&2
  fi
}

# ----- Pre-pass: reconcile every in-flight executor meta --------------------
#
# Iterate data/executor-jobs/*.meta (the in-flight receipts written by
# fm-research-worker-spawn.sh on successful spawn). For each:
#   * artifact present -> worker completed; drop the meta.
#   * worker alive -> still running; leave the meta alone.
#   * worker dead / missing / unreadable / ambiguous -> requeue.
#
# Only metas belonging to report_research tasks are reconciled; future
# spawn-helper callers that share the executor-jobs dir but use a different
# task_type are explicitly skipped via the task_type field.
for META_FILE in "$EXECUTOR_JOBS_DIR"/*.meta; do
  [ -f "$META_FILE" ] || continue
  META_TASK_TYPE="$(resolve_meta_field "$META_FILE" task_type || true)"
  case "$META_TASK_TYPE" in
    report_research) ;;
    *) continue ;;
  esac
  META_CORR="$(resolve_meta_field "$META_FILE" corr || true)"
  META_ARTIFACT="$(resolve_meta_field "$META_FILE" artifact || true)"
  META_WINDOW="$(resolve_meta_field "$META_FILE" window || true)"
  [ -n "$META_CORR" ] || continue

  if [ -n "$META_ARTIFACT" ] && [ -f "$META_ARTIFACT" ]; then
    rm -f "$META_FILE"
    echo "dispatch complete: corr=$META_CORR (artifact present)"
    continue
  fi
  if [ -z "$META_WINDOW" ]; then
    # Corrupt meta with no window - never license a requeue from unreadable
    # state alone. Leave it for an operator to triage manually.
    echo "dispatch pending: corr=$META_CORR (meta missing window)" >&2
    continue
  fi
  LIVENESS="$("$DEATH_CHECK" "$META_WINDOW" 2>/dev/null || true)"
  if [ "$LIVENESS" = "alive" ]; then
    echo "dispatch in-flight: corr=$META_CORR window=$META_WINDOW"
    continue
  fi
  requeue_worker "$META_FILE" "$META_CORR" "$META_WINDOW" "$LIVENESS" || true
done

# ----- Main loop: dispatch queued items ------------------------------------
# Promote any worker-death-rebuilt queue files into the regular queue
# namespace first. These were written as *.json.requeued by the pre-pass
# above to keep this drain's main loop from immediately respawning a
# dead worker; the next drain call promotes and dispatches them.
shopt -s nullglob
for REQUEUED in "$QUEUE_DIR"/*.json.requeued; do
  [ -f "$REQUEUED" ] || continue
  mv -f "$REQUEUED" "${REQUEUED%.requeued}"
done

for QUEUE_FILE in "$QUEUE_DIR"/*.json; do
  [ -f "$QUEUE_FILE" ] || continue
  CORR="$(jq -r '.corr // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  SEQ="$(jq -r '.seq // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  REVISION_SEQ="$(jq -r '.revision_seq // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  ROW_JSON="$(jq -c '.row // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  ATTEMPTS="$(jq -r '.attempts // 0' "$QUEUE_FILE" 2>/dev/null || true)"
  case "$CORR" in ''|*[!A-Za-z0-9._-]*) echo "dispatch queue invalid corr: $QUEUE_FILE" >&2; continue ;; esac
  case "$SEQ" in ''|*[!0-9]*) echo "dispatch queue invalid seq: $QUEUE_FILE" >&2; continue ;; esac
  case "$ATTEMPTS" in ''|*[!0-9]*) ATTEMPTS=0 ;; esac
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "dispatch paused: corr=$CORR seq=$SEQ attempts=$ATTEMPTS/$MAX_ATTEMPTS" >&2
    continue
  fi
  if [ -z "$ROW_JSON" ] || [ ! -x "$SPAWN_HELPER" ]; then
    echo "dispatch pending: corr=$CORR seq=$SEQ (invalid row or missing spawn helper)" >&2
    continue
  fi
  SPAWN_OUT="$QUEUE_FILE.spawn.out"
  if FM_RESEARCH_WORKER_REVISION_SEQ="$REVISION_SEQ" "$SPAWN_HELPER" "$CORR" "$ROW_JSON" "${FM_RESEARCH_WORKER_PROJECT_DIR:-$FM_HOME}" >"$SPAWN_OUT" 2>&1; then
    cat "$SPAWN_OUT"
    rm -f "$SPAWN_OUT" "$QUEUE_FILE"
    # Mirror the queue file's attempts into the executor meta. The
    # worker-death requeue path reads attempts from the meta (not the
    # queue file, which the spawn helper does not write), so this is
    # the durable bridge between successive death cycles.
    META_AFTER="$EXECUTOR_JOBS_DIR/$CORR.meta"
    if [ -f "$META_AFTER" ] && [ "$ATTEMPTS" -gt 0 ]; then
      if grep -q '^attempts=' "$META_AFTER"; then
        awk -v v="$ATTEMPTS" 'BEGIN{r=0} /^attempts=/{sub(/=.*/, "=" v); r=1} {print} END{if(!r) print "attempts=" v}' \
          "$META_AFTER" >"$META_AFTER.tmp" && mv -f "$META_AFTER.tmp" "$META_AFTER" || rm -f "$META_AFTER.tmp"
      else
        printf 'attempts=%s\n' "$ATTEMPTS" >>"$META_AFTER"
      fi
    fi
    echo "dispatch complete: corr=$CORR seq=$SEQ"
    continue
  fi
  NEXT=$((ATTEMPTS + 1))
  TMP_FILE="$(mktemp "$QUEUE_DIR/.retry.XXXXXX")"
  if jq --argjson attempts "$NEXT" '.attempts=$attempts' "$QUEUE_FILE" >"$TMP_FILE"; then
    chmod 600 "$TMP_FILE"
    mv -f "$TMP_FILE" "$QUEUE_FILE"
  else
    rm -f "$TMP_FILE"
  fi
  # Preserve the last failed spawn's stderr as evidence (ov-0824-A).
  # The retry budget can burn silently when three attempts die for the
  # same reason; .spawn.last.err stays next to the queue file until
  # the next attempt overwrites it.
  SPAWN_LAST_ERR="$QUEUE_FILE.spawn.last.err"
  if ! mv -f "$SPAWN_OUT" "$SPAWN_LAST_ERR" 2>/dev/null; then
    : > "$SPAWN_LAST_ERR"
    cat "$SPAWN_OUT" >>"$SPAWN_LAST_ERR" 2>/dev/null || true
    rm -f "$SPAWN_OUT"
  fi
  echo "dispatch retry pending: corr=$CORR seq=$SEQ attempt=$NEXT/$MAX_ATTEMPTS evidence=$SPAWN_LAST_ERR" >&2
  if [ "$NEXT" -lt "$MAX_ATTEMPTS" ]; then
    fm_wake_append signal research-dispatch "retry corr=$CORR seq=$SEQ" || true
  else
    echo "dispatch paused after retry budget: corr=$CORR seq=$SEQ" >&2
  fi
done
flock -u 9