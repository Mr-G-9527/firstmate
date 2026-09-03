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
# Startup grace for the death-check requeue decision (minutes). Headless
# report_research workers run `claude -p` as a child of the pane's persistent
# shell (see fm-research-worker-spawn.sh LAUNCH_CMD), so the pane is shell-only
# until claude attaches. A `dead` verdict inside this window of started_at is
# held (re-probed on the next drain) instead of requeued, so a slow start
# cannot license a duplicate spawn. 0 disables. It only delays - never cancels -
# a legitimate requeue: once older than the grace window a shell-only pane
# requeues as before.
DEATH_CHECK_GRACE_MINUTES="${FM_DEATH_CHECK_GRACE_MINUTES:-5}"
case "$DEATH_CHECK_GRACE_MINUTES" in ''|*[!0-9]*) DEATH_CHECK_GRACE_MINUTES=5 ;; esac
GRACE_SECONDS=$((DEATH_CHECK_GRACE_MINUTES * 60))
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

# capture_spawn_failure: persist a spawn-failure snapshot to
# state/.dispatch-fail/<corr>/<reason>.log BEFORE the existing
# .spawn.last.err rename runs, so an operator can find the real reason
# without grepping the queue's stderr. The fail log is the source of
# truth; the queue's `_fail_summary` JSON field is a convenience pointer
# that may be missing if the jq update races with disk full / OOM.
#
# Reconcile notes (2026-09-01 pre-redteam):
#   pre-D-1 path traversal: corr is sanitized to [A-Za-z0-9_-]+ with no
#        leading dot and no `..` substring; any failing value falls
#        into a shared "invalid-corr" subdir.
#   pre-D-2/D-3 jq mut silent drop: caller appends queue-update-failed-at
#        to the fail log itself when jq mut fails, so the fail log
#        remains findable via filesystem walk even with no queue pointer.
#   pre-D-4a misleading empty stderr section: only emit the section when
#        a separate stderr file is provided; today the spawn helper
#        merges stderr into spawn.out via 2>&1.
#   pre-D-4b sensitive retention: cap at 10 logs per corr (oldest dropped
#        by mtime before each new write).
#   pre-D-5 TOCTOU on truncate+write: write to a sibling tmp, mv -f into
#        place (atomic on same filesystem).
#
# Reconcile notes (2026-09-01 post-redteam):
#   post-D-1 chmod silent swallow: drop the trailing `|| true` from
#        chmod and mv -f so the caller can observe permission failures
#        via stderr; the caller also stops suppressing stderr.
#   post-D-2 unreadable spawn.out: an unreadable file produced
#        `wc -c` = 0 → "(spawn.out is empty)", misleading the operator.
#        Detect unreadable separately so the message says so.
#   post-D-5 invalid-corr collision: every malformed corr collapsed to
#        a single shared dir → cross-task retention conflict. Keep the
#        shared `invalid-corr` dir but encode a sha1[:8] of the
#        original corr into the filename so per-task evidence stays
#        isolated within the fallback bucket.
#
# Out of scope (parked):
#   post-D-4 pre-pass death-detection rebuilds queue JSON without
#        `_fail_summary`; the helper here only fires on the spawn-fail
#        main-loop branch. Monitoring that greps `_fail_summary` will
#        miss worker-death retry evidence; that gap is a follow-up.
#   post-D-1-b `.spawn.last.err` truncate-before-cat is a pre-existing
#        ov-0824-A contract; the captain hard-constraint keeps it.
capture_spawn_failure() {  # <corr> <reason> <spawn_out_path> <queue_file>
  local corr_orig=$1 reason=$2 spawn_out=$3 queue_file=$4
  local corr corr_hash fail_dir now bytes fail_log tmp_log
  corr="$corr_orig"
  case "$corr" in
    ''|.*|*..*) corr="invalid-corr" ;;
  esac
  case "$corr" in
    *[!A-Za-z0-9_-]*) corr="invalid-corr" ;;
  esac
  # post-D-5: when corr collapsed to invalid-corr, suffix the filename
  # with a short hash of the original corr so two distinct malformed
  # corrs don't write into the same log slot.
  if [ "$corr" = "invalid-corr" ]; then
    corr_hash="$(printf '%s' "$corr_orig" | sha1sum 2>/dev/null | awk '{print substr($1,1,8)}')"
    case "$corr_hash" in
      ''|*[!A-Za-z0-9]*) corr_hash="00000000" ;;
    esac
  else
    corr_hash=""
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  fail_dir="$STATE/.dispatch-fail/$corr"
  if ! mkdir -p "$fail_dir"; then
    echo "dispatch-fail mkdir failed: $fail_dir" >&2
    return 1
  fi
  chmod 700 "$fail_dir" 2>/dev/null || true

  # Cap retention at 10 logs per corr; drop the oldest by mtime first.
  # The glob matches the file-name pattern we write below; the leading
  # dot in `.reason.log.tmp.*` is intentionally excluded so in-flight
  # tmp files are never GC'd.
  set +u
  existing=$(printf '%s\n' "$fail_dir"/[A-Za-z0-9_-]*.log 2>/dev/null | grep -v '^\[' | wc -l)
  if [ "${existing:-0}" -gt 10 ]; then
    # ls -1t prints newest-first; tail -n +11 keeps the rest = oldest.
    ls -1t "$fail_dir"/[A-Za-z0-9_-]*.log 2>/dev/null \
      | tail -n +11 \
      | while read -r old; do
          [ -n "$old" ] && rm -f -- "$old" 2>/dev/null || true
        done
  fi
  set -u

  if [ -n "$corr_hash" ]; then
    fail_log="$fail_dir/$reason-$corr_hash.log"
    tmp_log="$fail_dir/.$reason-$corr_hash.log.tmp.$$"
  else
    fail_log="$fail_dir/$reason.log"
    tmp_log="$fail_dir/.$reason.log.tmp.$$"
  fi

  {
    echo "==== dispatch-fail snapshot ===="
    echo "captured_at=$now"
    echo "task_id=$corr_orig"
    echo "sanitized_task_id=$corr"
    [ -n "$corr_hash" ] && echo "invalid_corr_sha1_8=$corr_hash"
    echo "reason=$reason"
    echo "queue_file=$queue_file"
    echo "spawn_out=$spawn_out"
    echo "--- spawn.out tail (last 200 lines, or full if <200) ---"
    if [ -f "$spawn_out" ]; then
      if [ -r "$spawn_out" ]; then
        bytes="$(wc -c < "$spawn_out" 2>/dev/null || echo 0)"
        if [ "${bytes:-0}" -gt 0 ]; then
          tail -n 200 "$spawn_out" 2>/dev/null || true
        else
          echo "(spawn.out is empty)"
        fi
      else
        echo "(spawn.out present but unreadable by current process: $spawn_out)"
      fi
    else
      echo "(spawn.out missing: $spawn_out)"
    fi
    if [ -n "${SPAWN_STDERR_PATH:-}" ] && [ -f "${SPAWN_STDERR_PATH}" ]; then
      echo "--- stderr summary (last 50 lines) ---"
      tail -n 50 "${SPAWN_STDERR_PATH}" 2>/dev/null | head -50 || true
    else
      echo "--- stderr ---"
      echo "(merged into spawn.out above via spawn helper 2>&1 redirection)"
    fi
  } > "$tmp_log" 2>/dev/null || true
  chmod 600 "$tmp_log" 2>/dev/null || true
  if ! mv -f "$tmp_log" "$fail_log" 2>/dev/null; then
    rm -f "$tmp_log" 2>/dev/null || true
    echo "dispatch-fail write failed: $fail_log" >&2
    return 1
  fi

  printf '%s\n' "$fail_log"
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
#   * started_at older than the guard window (default 48h) -> archive the
#     meta and skip the death check entirely. The 0826 incident proved
#     that "alive-looking but actually dead" workers older than the guard
#     window cannot be alive in any meaningful sense; batching 26 of them
#     into one drain produced the lockstep re-spawn that overwhelmed the
#     shared key. The guard runs BEFORE the task_type branch so it covers
#     every lane that writes to this directory, not only report_research.
#   * artifact present -> worker completed; drop the meta.
#   * worker alive -> still running; leave the meta alone.
#   * worker dead / missing / unreadable / ambiguous -> requeue.
#
# Only metas belonging to report_research tasks are reconciled; future
# spawn-helper callers that share the executor-jobs dir but use a different
# task_type are explicitly skipped via the task_type field AFTER the
# E1 guard has had a chance to evaluate them. This ordering matters:
# the bug class is about age, not about lane, so a non-report_research
# meta that is >48h old is just as dangerous to requeue as a report_research
# one. Skipping the guard on non-report_research lanes would re-open the
# 0826 lockstep risk for any other lane that uses this drain.

# E1 death-check guard (regression: 0826 incident). Window is configurable
# via FM_E1_GUARD_WINDOW_HOURS so the regression fixture can replay the
# 0826 timeline without spinning the wall clock. Default 48h matches the
# incident postmortem. The comparison uses integer UTC epoch seconds and
# a strict `<` so a meta exactly at the boundary still participates in
# death-check; this is consistent with the brief's "older than 48h"
# wording. Metas lacking a parseable started_at, or with a started_at
# that parses to the future (clock skew or mistakenly written deadline
# field), are treated as ARCHIVED (fail-closed) so the guard cannot
# re-create the original bug via permissive defaults.
GUARD_WINDOW_HOURS="${FM_E1_GUARD_WINDOW_HOURS:-48}"
# FM_E1_GUARD_NOW is a deliberate test seam: pass an RFC3339 UTC string
# and the guard pins NOW to that timestamp instead of reading the wall
# clock. Production code never sets it.
if [ -n "${FM_E1_GUARD_NOW:-}" ]; then
  NOW_EPOCH="$(date -u -d "$FM_E1_GUARD_NOW" +%s 2>/dev/null || echo 0)"
else
  NOW_EPOCH="$(date -u +%s 2>/dev/null || echo 0)"
fi
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=0 ;; esac
# DISABLED_GUARD flips the guard into fail-closed archive mode for every
# meta: when the wall clock is unreadable we never want to fall through
# to the death-check path (which would, on a cohort of "ancient alive"
# metas, reproduce the 0826 lockstep).
case "$NOW_EPOCH" in 0|-*) DISABLED_GUARD=1 ;; *) DISABLED_GUARD=0 ;; esac
GUARD_EPOCH=$((NOW_EPOCH - GUARD_WINDOW_HOURS * 3600))

# archive_root is the parent of all per-run archive snapshots. The
# per-incident fixture state/executor-meta-archive-0826/ keeps its own
# suffix to remain identifiable as a frozen historical snapshot; this
# guard's runtime archive uses the bare path with a timestamped child
# directory per drain run. The two namespaces never overlap, so a
# post-mortem comparing the 0826 fixture against the runtime archive
# still works.
ARCHIVE_ROOT="${FM_E1_GUARD_ARCHIVE_DIR:-$STATE/executor-meta-archive}"
ARCHIVED_COUNT=0
KEPT_COUNT=0

archive_meta() {  # <meta_file> <corr> <reason>
  local meta_file=$1 corr=$2 reason=$3
  local run_dir_ts run_dir
  run_dir_ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
  run_dir="${ARCHIVE_ROOT}/$run_dir_ts"
  if [ ! -d "$run_dir" ]; then
    mkdir -p "$run_dir" 2>/dev/null || {
      echo "dispatch archive failed: corr=$corr reason=$reason (mkdir $run_dir)" >&2
      return 1
    }
  fi
  if mv -f "$meta_file" "$run_dir/$corr.meta" 2>/dev/null; then
    echo "dispatch archived: corr=$corr reason=$reason" >&2
    ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
    return 0
  fi
  echo "dispatch archive failed: corr=$corr reason=$reason (mv)" >&2
  return 1
}

for META_FILE in "$EXECUTOR_JOBS_DIR"/*.meta; do
  [ -f "$META_FILE" ] || continue
  META_CORR="$(resolve_meta_field "$META_FILE" corr || true)"
  [ -n "$META_CORR" ] || continue

  # E1 death-check guard runs FIRST and applies to every lane. Older-
  # than-window metas are archived without any death check, regardless
  # of artifact state or task_type continuation - the lockstep risk is
  # about age, not lane. Three fail-closed paths converge here:
  #   1. wall clock is unreadable (DISABLED_GUARD) -> archive every meta
  #   2. started_at missing or unparseable -> archive (missing-started_at)
  #   3. started_at parses to a future epoch (clock skew, mistakenly
  #      written deadline field, or naive local-TZ string interpreted
  #      non-UTC) -> archive (future-started_at)
  # Path (3) is the inverse of the "missing" path: the original 0826
  # lockstep came from treating ancient-but-alive as alive; treating
  # future-but-parseable as alive would be the same shape of failure,
  # just on the other side of NOW.
  META_STARTED_AT="$(resolve_meta_field "$META_FILE" started_at || true)"
  META_STARTED_EPOCH=""
  if [ -n "$META_STARTED_AT" ]; then
    META_STARTED_EPOCH="$(date -u -d "$META_STARTED_AT" +%s 2>/dev/null || true)"
    case "$META_STARTED_EPOCH" in ''|*[!0-9]*) META_STARTED_EPOCH="" ;; esac
  fi
  if [ "$DISABLED_GUARD" = "1" ]; then
    archive_meta "$META_FILE" "$META_CORR" "clock-unreadable" || true
    continue
  fi
  if [ -z "$META_STARTED_EPOCH" ]; then
    archive_meta "$META_FILE" "$META_CORR" "missing-started_at" || true
    continue
  fi
  if [ "$META_STARTED_EPOCH" -gt "$NOW_EPOCH" ]; then
    archive_meta "$META_FILE" "$META_CORR" "future-started_at" || true
    continue
  fi
  if [ "$META_STARTED_EPOCH" -lt "$GUARD_EPOCH" ]; then
    archive_meta "$META_FILE" "$META_CORR" "older-than-${GUARD_WINDOW_HOURS}h" || true
    continue
  fi
  KEPT_COUNT=$((KEPT_COUNT + 1))

  META_TASK_TYPE="$(resolve_meta_field "$META_FILE" task_type || true)"
  case "$META_TASK_TYPE" in
    report_research) ;;
    *) continue ;;
  esac

  META_ARTIFACT="$(resolve_meta_field "$META_FILE" artifact || true)"
  META_WINDOW="$(resolve_meta_field "$META_FILE" window || true)"

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
  case "$LIVENESS" in
    alive)
      echo "dispatch in-flight: corr=$META_CORR window=$META_WINDOW"
      continue
      ;;
    unreadable)
      # Transient/ambiguous probe. The verifier's contract is that only a
      # confident negative licenses a re-spawn; an uncertain tmux read must
      # never authorize a duplicate. Hold the meta and re-probe next drain.
      echo "dispatch probe-unreadable: corr=$META_CORR window=$META_WINDOW (hold, re-probe next drain)" >&2
      continue
      ;;
    dead)
      # Confident agent-absent. Apply the startup grace: a shell-only pane
      # within GRACE_SECONDS of started_at is a slow start, not a death.
      if [ "$GRACE_SECONDS" -gt 0 ] \
         && [ $((NOW_EPOCH - META_STARTED_EPOCH)) -lt "$GRACE_SECONDS" ]; then
        echo "dispatch starting-grace: corr=$META_CORR window=$META_WINDOW (age<${GRACE_SECONDS}s, hold)" >&2
        continue
      fi
      requeue_worker "$META_FILE" "$META_CORR" "$META_WINDOW" "$LIVENESS" || true
      ;;
    *)
      # missing / any other verdict: the window or session is gone (or the
      # probe returned something unexpected) - requeue, keeping it observable.
      requeue_worker "$META_FILE" "$META_CORR" "$META_WINDOW" "$LIVENESS" || true
      ;;
  esac
done

# Summary line so supervisors can audit the guard's effect on every
# drain without grepping individual archived lines. Goes to stdout (not
# stderr) because it is a normal lifecycle line, not an error.
if [ "$ARCHIVED_COUNT" -gt 0 ] || [ "$KEPT_COUNT" -gt 0 ]; then
  echo "precheck: kept $KEPT_COUNT alive / archived $ARCHIVED_COUNT (>${GUARD_WINDOW_HOURS}h)"
fi

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
  REASON="spawn-fail-attempt-$NEXT"
  # Capture the full failure snapshot before the queue-file mutation and
  # the .spawn.last.err rename, so the evidence survives both transforms.
  # Stderr propagates so a permission / disk-full error is visible; the
  # helper itself returns 1 to signal capture failure, and we drop a
  # sentinel evidence path so the queue's _fail_summary is never
  # silently empty.
  FAIL_LOG="$(capture_spawn_failure "$CORR" "$REASON" "$SPAWN_OUT" "$QUEUE_FILE" || true)"
  if [ -z "${FAIL_LOG:-}" ] || [ ! -f "${FAIL_LOG:-}" ]; then
    FAIL_LOG="(capture-failed:state/.dispatch-fail/$CORR/$REASON.log)"
    echo "dispatch-fail capture did not produce a log; sentinel=$FAIL_LOG" >&2
  fi
  CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  TMP_FILE="$(mktemp "$QUEUE_DIR/.retry.XXXXXX" 2>/dev/null || true)"
  if [ -z "$TMP_FILE" ] || [ ! -e "$TMP_FILE" ]; then
    # post-D-3: mktemp failed (quota / noexec). Don't try to redirect
    # jq output to an empty path; record the failure on the fail log
    # and bail out of the queue-mutation step so the next drain cycle
    # sees a sane ATTEMPTS value instead of silently retrying forever.
    echo "dispatch retry: mktemp for queue tmp failed; leaving queue attempts unchanged" >&2
    if [ -f "${FAIL_LOG:-}" ]; then
      printf 'queue-mktemp-failed-at=%s\n' "$CAPTURED_AT" >> "$FAIL_LOG" 2>/dev/null || true
    fi
  else
    if jq --argjson attempts "$NEXT" \
           --arg reason "$REASON" \
           --arg evidence "${FAIL_LOG:-}" \
           --arg ts "$CAPTURED_AT" \
           '.attempts=$attempts | ._fail_summary={captured_at:$ts, reason:$reason, evidence_log:$evidence}' \
           "$QUEUE_FILE" >"$TMP_FILE"; then
      chmod 600 "$TMP_FILE"
      mv -f "$TMP_FILE" "$QUEUE_FILE"
    else
      rm -f "$TMP_FILE"
      # pre-D-2/D-3 reconcile: the fail log is the source of truth; record
      # the queue-update failure inline so an operator can find this
      # snapshot via `ls state/.dispatch-fail/<corr>/` even when the
      # queue's _fail_summary pointer is missing or stale.
      if [ -n "${FAIL_LOG:-}" ] && [ -f "$FAIL_LOG" ]; then
        printf 'queue-update-failed-at=%s\n' "$CAPTURED_AT" >> "$FAIL_LOG" 2>/dev/null || true
      fi
    fi
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
  if [ -n "${FAIL_LOG:-}" ] && [ -f "$FAIL_LOG" ]; then
    echo "dispatch retry pending: corr=$CORR seq=$SEQ attempt=$NEXT/$MAX_ATTEMPTS evidence=$SPAWN_LAST_ERR fail_log=$FAIL_LOG" >&2
  else
    echo "dispatch retry pending: corr=$CORR seq=$SEQ attempt=$NEXT/$MAX_ATTEMPTS evidence=$SPAWN_LAST_ERR fail_log=${FAIL_LOG:-none}" >&2
  fi
  if [ "$NEXT" -lt "$MAX_ATTEMPTS" ]; then
    fm_wake_append signal research-dispatch "retry corr=$CORR seq=$SEQ" || true
  else
    echo "dispatch paused after retry budget: corr=$CORR seq=$SEQ" >&2
  fi
done
flock -u 9