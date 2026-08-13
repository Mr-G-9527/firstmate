#!/usr/bin/env bash
# Bounded scout DAG runtime: read scout dependencies from the backlog's
# `(depends: ...)` syntax, fan out leaves in parallel, wait for the frontier,
# and dispatch the next layer. The captain sees one notification per layer
# rather than per scout.
# Usage: fm-scout-dag.sh [options] <root-task-id>
#   --backlog <path>           backlog file (default: $FM_HOME/data/backlog.md)
#   --state <dir>              state directory (default: $FM_HOME/state)
#   --projects <dir>           projects directory (default: $FM_HOME/projects)
#   --spawn-bin <path>         per-scout spawn primitive (default: <this-repo>/bin/fm-spawn.sh)
#                              Tests override this with a stub that simulates completion.
#   --poll-secs <N>            poll cadence while awaiting the frontier (default: 5)
#   --await-timeout-secs <N>   max wait for any single node to leave working (default: 1800)
#   --abort-on-fail            abort the DAG on any node failure (default: manual-replan)
#   --dry-run                  parse + print the layered plan; no dispatch; exit 0
#   --no-dag                   alias for --dry-run (the captain's fall-back flag)
#   --max-parallel <N>         cap frontier parallelism (default: 0 = unbounded)
#   --include-kind <k1,k2,...> only include nodes whose `(kind: ...)` matches; default: scout
#   --help                     print this usage
#
# Fall-back contract: when any node's outcome is failed/blocked/needs-decision
# without --abort-on-fail, the script prints actionable manual-dispatch guidance
# and exits 0 so today's manual dispatch path remains the recovery surface.
# Today's manual path = `bin/fm-spawn.sh <task-id> <projects/<repo>> --scout`
# + read `state/<id>.status` per the always-on watcher.
#
# Idempotence: a node whose `state/<id>.status` already carries a terminal
# (done|failed|blocked|needs-decision) or paused line is treated as already
# settled; it is not re-dispatched. A bare re-run after partial completion
# therefore produces the same dispatch decisions for any unsettled frontier.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKLOG=""
STATE=""
PROJECTS=""
SPAWN_BIN="$ROOT_DEFAULT/bin/fm-spawn.sh"
POLL_SECS=5
AWAIT_TIMEOUT_SECS=1800
ABORT_ON_FAIL=0
DRY_RUN=0
MAX_PARALLEL=0
INCLUDE_KIND="scout"
ROOT_ID=""

# resolve_directory_input <name> <path>: portable absolute resolution with a
# labeled stderr message on failure. Empty input is rejected.
resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    "") echo "error: $name path is empty" >&2; return 1 ;;
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

fm_home_default() {
  if [ -n "${FM_HOME:-}" ]; then
    resolve_directory_input FM_HOME "$FM_HOME"
    return $?
  fi
  printf '%s\n' "$ROOT_DEFAULT"
}

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backlog) [ "$#" -ge 2 ] || { echo "error: --backlog requires a value" >&2; exit 2; }; BACKLOG=$2; shift 2 ;;
    --backlog=*) BACKLOG=${1#*=}; shift ;;
    --state) [ "$#" -ge 2 ] || { echo "error: --state requires a value" >&2; exit 2; }; STATE=$2; shift 2 ;;
    --state=*) STATE=${1#*=}; shift ;;
    --projects) [ "$#" -ge 2 ] || { echo "error: --projects requires a value" >&2; exit 2; }; PROJECTS=$2; shift 2 ;;
    --projects=*) PROJECTS=${1#*=}; shift ;;
    --spawn-bin) [ "$#" -ge 2 ] || { echo "error: --spawn-bin requires a value" >&2; exit 2; }; SPAWN_BIN=$2; shift 2 ;;
    --spawn-bin=*) SPAWN_BIN=${1#*=}; shift ;;
    --poll-secs) [ "$#" -ge 2 ] || { echo "error: --poll-secs requires a value" >&2; exit 2; }; POLL_SECS=$2; shift 2 ;;
    --poll-secs=*) POLL_SECS=${1#*=}; shift ;;
    --await-timeout-secs) [ "$#" -ge 2 ] || { echo "error: --await-timeout-secs requires a value" >&2; exit 2; }; AWAIT_TIMEOUT_SECS=$2; shift 2 ;;
    --await-timeout-secs=*) AWAIT_TIMEOUT_SECS=${1#*=}; shift ;;
    --max-parallel) [ "$#" -ge 2 ] || { echo "error: --max-parallel requires a value" >&2; exit 2; }; MAX_PARALLEL=$2; shift 2 ;;
    --max-parallel=*) MAX_PARALLEL=${1#*=}; shift ;;
    --include-kind) [ "$#" -ge 2 ] || { echo "error: --include-kind requires a value" >&2; exit 2; }; INCLUDE_KIND=$2; shift 2 ;;
    --include-kind=*) INCLUDE_KIND=${1#*=}; shift ;;
    --abort-on-fail) ABORT_ON_FAIL=1; shift ;;
    --dry-run|--no-dag) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$ROOT_ID" ]; then ROOT_ID=$1; shift
      else echo "error: unexpected positional argument: $1" >&2; exit 2
      fi
      ;;
  esac
done

[ -n "$ROOT_ID" ] || { echo "error: root task id required" >&2; exit 2; }

FM_HOME=$(fm_home_default) || exit 1
[ -n "$BACKLOG" ] || BACKLOG="$FM_HOME/data/backlog.md"
[ -n "$STATE" ] || STATE="$FM_HOME/state"
[ -n "$PROJECTS" ] || PROJECTS="$FM_HOME/projects"

BACKLOG=$(resolve_directory_input backlog "$BACKLOG") || exit 1
STATE=$(resolve_directory_input state "$STATE") || exit 1
PROJECTS=$(resolve_directory_input projects "$PROJECTS") || exit 1

# Source the leaf-state classifier. The watcher and daemon both import this;
# the DAG runtime reads the same verbs so a node's "done:" / "failed:" /
# "paused:" classification never drifts.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

# sdag_classify <status-line> -> done|failed|blocked|needs-decision|paused|working
# Pure read of <line>; never touches disk. Empty input maps to working so a
# node that has never been polled is treated as still in-flight.
sdag_classify() {
  local line=$1 verb
  if [ -z "$line" ]; then
    printf 'working\n'
    return 0
  fi
  verb=$(status_line_verb "$line")
  case "$verb" in
    done) printf 'done\n' ;;
    failed) printf 'failed\n' ;;
    blocked) printf 'blocked\n' ;;
    needs-decision) printf 'needs-decision\n' ;;
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") printf 'paused\n' ;;
    working) printf 'working\n' ;;
    *) printf 'working\n' ;;
  esac
}

# sdag_parse_task <backlog-file> <task-id>: echo "<repo>|<deps>" or exit 1.
# <deps> is a comma-separated list (no surrounding parens), possibly empty.
sdag_parse_task() {
  local f=$1 id=$2 line rest
  line=$(awk -v k="$id" 'index($0, "- [ ] " k " -") == 1 || index($0, "- [x] " k " -") == 1 { print; exit }' "$f" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  rest=${line#*- [ ]}
  rest=${rest#*- [x]}
  local repo deps
  repo=$(printf '%s\n' "$rest" | sed -n 's/.*(repo:[[:space:]]*\([^)]*\)).*/\1/p' | head -n 1)
  deps=$(printf '%s\n' "$rest" | sed -n 's/.*(depends:[[:space:]]*\([^)]*\)).*/\1/p' | head -n 1)
  printf '%s|%s\n' "${repo:-}" "${deps:-}"
}

# sdag_build_dag <backlog-file> <root-id> <include-kind-csv> <out-file>:
# BFS-expands `(depends: ...)` from <root-id>, writes "<id>|<project>|<deps>"
# lines (one per node) to <out-file>, filtering by (kind: ...) match.
# Missing (repo: ...) on a node is NOT raised here; sdag_validate owns that
# check so the missing-dependency check (which precedes it) runs first.
sdag_build_dag() {
  local f=$1 root=$2 kinds=$3 out=$4
  : > "$out"
  local frontier=$root next seen id rest deps dep
  seen="$root"
  printf '%s||\n' "$root" >> "$out"
  while [ -n "$frontier" ]; do
    next=
    for id in $frontier; do
      rest=$(sdag_parse_task "$f" "$id") || continue
      deps=${rest#*|}
      IFS=',' read -r -a dep_arr <<EOF
$deps
EOF
      for dep in "${dep_arr[@]}"; do
        dep=$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$dep" ] || continue
        case " $seen " in
          *" $dep "*) continue ;;
        esac
        seen="$seen $dep"
        next="$next $dep"
        printf '%s||\n' "$dep" >> "$out"
      done
    done
    frontier=$next
  done
  # Second pass: fill (repo: ...) and (kind: ...), filter by INCLUDE_KIND.
  # Nodes that sdag_parse_task could not find (e.g. missing in the backlog)
  # get an empty repo field; sdag_validate decides what to do with that.
  local tmp; tmp=$(mktemp)
  local repo kind
  while IFS='|' read -r id _ _; do
    [ -n "$id" ] || continue
    rest=$(sdag_parse_task "$f" "$id") || rest="|"
    repo=${rest%%|*}
    deps=${rest#*|}
    deps=${deps%%|*}
    kind=$(awk -v k="$id" 'index($0, "- [ ] " k " -") == 1 || index($0, "- [x] " k " -") == 1 { print; exit }' "$f" 2>/dev/null \
      | sed -n 's/.*(kind:[[:space:]]*\([^ )]*\).*/\1/p')
    case ",$kinds," in
      *",$kind,"*) printf '%s|%s|%s\n' "$id" "$repo" "$deps" >> "$tmp" ;;
      *) : ;;
    esac
  done < "$out"
  mv "$tmp" "$out"
}

# sdag_detect_cycle <dag-file>: return 0 if acyclic, 1 if a cycle exists.
# DFS with on-stack tracking; reports the offending node.
sdag_detect_cycle() {
  local f=$1
  local dag; dag=$(cat "$f")
  local id seen=""
  while IFS='|' read -r id _ _; do
    [ -n "$id" ] || continue
    case " $seen " in *" $id "*) continue ;; esac
    if ! sdag__dfs_cycle_from "$dag" "$id"; then
      return 1
    fi
    seen="$seen $id"
  done <<EOF
$dag
EOF
  return 0
}
sdag__dfs_cycle_from() {
  local dag=$1 id=$2
  local stack=${3:-}
  local d deps
  case " $stack " in
    *" $id "*) echo "error: cyclic dependency involving node: $id" >&2; return 1 ;;
  esac
  deps=$(printf '%s\n' "$dag" | awk -F'|' -v k="$id" '$1==k {print $3; exit}')
  IFS=',' read -r -a dep_arr <<EOF
$deps
EOF
  for d in "${dep_arr[@]}"; do
    d=$(printf '%s' "$d" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$d" ] || continue
    sdag__dfs_cycle_from "$dag" "$d" "$stack $id" || return 1
  done
  return 0
}

# sdag_validate <dag-file>: every node has project + every dep references an
# existing id. Echoes one error line and returns nonzero on first failure.
sdag_validate() {
  local f=$1
  local dag; dag=$(cat "$f")
  local id repo deps dep
  while IFS='|' read -r id repo deps; do
    [ -n "$id" ] || continue
    [ -n "$deps" ] || continue
    IFS=',' read -r -a dep_arr <<EOF
$deps
EOF
    for dep in "${dep_arr[@]}"; do
      dep=$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$dep" ] || continue
      if ! printf '%s\n' "$dag" | awk -F'|' -v k="$dep" '$1==k {found=1; exit} END{exit !found}' >/dev/null 2>&1; then
        echo "error: node $id depends on unknown id: $dep" >&2
        return 1
      fi
    done
    if [ -z "$repo" ]; then
      echo "error: node $id has no (repo: ...)" >&2
      return 1
    fi
  done <<EOF
$dag
EOF
  return 0
}

# sdag_compute_layers <dag-file> <out-file>: compute topological layers and
# write them as "<id>|<layer>" lines (one node per line, layer is 0-based).
# Pure computation; no state-file reads.
sdag_compute_layers() {
  local f=$1 out=$2
  local tmp_done; tmp_done=$(mktemp)
  local tmp_layer; tmp_layer=$(mktemp)
  local layer=0
  while :; do
    local added=0
    : > "$tmp_layer"
    while IFS='|' read -r id _ deps; do
      [ -n "$id" ] || continue
      if awk -F'|' -v k="$id" '$1==k {found=1; exit} END{exit !found}' "$tmp_done" >/dev/null 2>&1; then continue; fi
      local ready=1 d
      [ -n "$deps" ] || {
        printf '%s\n' "$id" >> "$tmp_layer"
        added=1
        continue
      }
      ready=1
      IFS=',' read -r -a dep_arr <<EOF
$deps
EOF
      for d in "${dep_arr[@]}"; do
        d=$(printf '%s' "$d" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$d" ] || continue
        if ! awk -F'|' -v k="$d" '$1==k {found=1; exit} END{exit !found}' "$tmp_done" >/dev/null 2>&1; then ready=0; break; fi
      done
      if [ "$ready" -eq 1 ]; then
        printf '%s\n' "$id" >> "$tmp_layer"
        added=1
      fi
    done < "$f"
    [ "$added" -eq 0 ] && break
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      printf '%s|%s\n' "$id" "$layer" >> "$out"
      printf '%s|\n' "$id" >> "$tmp_done"
    done < "$tmp_layer"
    layer=$((layer + 1))
    [ "$layer" -ge 10000 ] && break
  done
  rm -f "$tmp_done" "$tmp_layer"
}

# sdag_find_ready <dag-file> <state-dir>: echo one node id per line whose deps
# are all terminal-done AND whose own state file is empty (no working line).
# A node already at done/failed/blocked/needs-decision/paused is not in the
# frontier; it has already been settled.
sdag_find_ready() {
  local f=$1 sdir=$2 id project deps dep last outcome all_done
  while IFS='|' read -r id project deps; do
    [ -n "$id" ] || continue
    last=$(last_status_line "$sdir/$id.status" 2>/dev/null) || last=
    if [ -n "$last" ]; then
      outcome=$(sdag_classify "$last")
      case "$outcome" in
        done|failed|blocked|needs-decision|paused) continue ;;
      esac
    fi
    all_done=1
    IFS=',' read -r -a dep_arr <<EOF
$deps
EOF
    for dep in "${dep_arr[@]}"; do
      dep=$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$dep" ] || continue
      last=$(last_status_line "$sdir/$dep.status" 2>/dev/null) || last=
      [ "$(sdag_classify "$last")" = "done" ] || { all_done=0; break; }
    done
    [ "$all_done" -eq 1 ] && printf '%s\n' "$id"
  done < "$f"
}

# sdag_dispatch <id> <project> <state-dir>: launch spawn-bin in background.
# Returns 0 if the spawn was kicked off (or skipped because already settled).
# Returns 4 if the project dir does not exist (manual dispatch required).
sdag_dispatch() {
  local id=$1 project=$2 sdir=$3 last outcome repo_path
  last=$(last_status_line "$sdir/$id.status" 2>/dev/null) || last=
  if [ -n "$last" ]; then
    outcome=$(sdag_classify "$last")
    case "$outcome" in
      done|failed|blocked|needs-decision|paused) return 0 ;;
    esac
  fi
  repo_path="$PROJECTS/$project"
  if [ ! -d "$repo_path" ]; then
    echo "warning: $id project dir not found: $repo_path" >&2
    printf 'failed: project dir not found: %s\n' "$repo_path" >> "$sdir/$id.status"
    return 4
  fi
  "$SPAWN_BIN" "$id" "$repo_path" --scout >/dev/null 2>&1 &
  disown || true
  return 0
}

# sdag_wait_layer <state-dir> <ids-file> <outcomes-file>: poll each id's status
# file until every id leaves working/empty, then write "<id>|<outcome>|<line>"
# rows to <outcomes-file>. Bounded by AWAIT_TIMEOUT_SECS.
sdag_wait_layer() {
  local sdir=$1 ids=$2 outcomes=$3 deadline id total last outcome done_count recorded
  deadline=$(( $(date +%s) + AWAIT_TIMEOUT_SECS ))
  : > "$outcomes"
  recorded=$(mktemp)
  while :; do
    done_count=0
    total=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      total=$((total + 1))
      if grep -Fx -- "$id" "$recorded" >/dev/null 2>&1; then
        done_count=$((done_count + 1))
        continue
      fi
      last=$(last_status_line "$sdir/$id.status" 2>/dev/null) || last=
      outcome=$(sdag_classify "$last")
      case "$outcome" in
        done|failed|blocked|needs-decision|paused)
          printf '%s|%s|%s\n' "$id" "$outcome" "$last" >> "$outcomes"
          printf '%s\n' "$id" >> "$recorded"
          done_count=$((done_count + 1))
          ;;
      esac
    done < "$ids"
    if [ "$total" -gt 0 ] && [ "$done_count" -eq "$total" ]; then rm -f "$recorded"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "warning: await timeout ($AWAIT_TIMEOUT_SECS s) reached" >&2
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        if grep -Fx -- "$id" "$recorded" >/dev/null 2>&1; then continue; fi
        last=$(last_status_line "$sdir/$id.status" 2>/dev/null) || last=
        outcome=$(sdag_classify "$last")
        printf '%s|%s|%s\n' "$id" "$outcome" "$last" >> "$outcomes"
        printf '%s\n' "$id" >> "$recorded"
      done < "$ids"
      rm -f "$recorded"
      return 0
    fi
    sleep "$POLL_SECS" 2>/dev/null || sleep 1
  done
}

# sdag_print_replan <dag-file> <message>: print the manual-replan guidance.
sdag_print_replan() {
  local f=$1
  echo "manual replan:"
  echo "  1. Inspect state/<id>.status for failure / decision context."
  echo "  2. Re-dispatch: $SPAWN_BIN <id> $PROJECTS/<repo> --scout"
  echo "  3. Re-run: fm-scout-dag.sh $ROOT_ID"
  local id project deps dep last oc
  while IFS='|' read -r id project deps; do
    [ -n "$id" ] || continue
    last=$(last_status_line "$STATE/$id.status" 2>/dev/null) || last=
    oc=$(sdag_classify "$last")
    case "$oc" in
      failed|blocked|needs-decision)
        echo "  stuck: $id ($project) -> $last"
        IFS=',' read -r -a dep_arr <<EOF
$deps
EOF
        for dep in "${dep_arr[@]}"; do
          dep=$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          [ -n "$dep" ] || continue
          echo "    dependent: $dep (will not auto-dispatch until $id is done)"
        done
        ;;
    esac
  done < "$f"
}

# sdag_run <dag-file>: main loop. Computes the frontier, dispatches it,
# waits, classifies outcomes, and either advances or replans.
sdag_run() {
  local f=$1 layer=0 iter=0 ready outcomes id project oc note
  local failed_count blocked_count paused_count
  while :; do
    ready=$(mktemp)
    sdag_find_ready "$f" "$STATE" > "$ready"
    if [ ! -s "$ready" ]; then
      # No ready nodes. Decide among three states:
      #   1. all settled (done/failed/blocked/needs-decision/paused) -> return 0
      #   2. a failed/blocked/needs-decision ancestor is blocking dispatch -> rc 1 + replan
      #   3. only paused/unstarted deps are blocking -> paused wait; rc 0 + notice
      local pending=0 stuck=0 pid poc
      while IFS='|' read -r pid _ _; do
        [ -n "$pid" ] || continue
        poc=$(sdag_classify "$(last_status_line "$STATE/$pid.status" 2>/dev/null)")
        case "$poc" in
          done|failed|blocked|needs-decision|paused) : ;;
          *) pending=$((pending + 1)) ;;
        esac
      done < "$f"
      rm -f "$ready"
      if [ "$pending" -eq 0 ]; then return 0; fi
      # Walk the DAG: for every pending node, check whether any of its deps
      # has reached a hard failure verb. If yes, the DAG is stuck on a failed
      # dep and we must surface the manual-replan path.
      while IFS='|' read -r pid _ deps; do
        [ -n "$pid" ] || continue
        poc=$(sdag_classify "$(last_status_line "$STATE/$pid.status" 2>/dev/null)")
        case "$poc" in
          done|paused|working|"") : ;;  # node itself is not yet a failure
          failed|blocked|needs-decision) stuck=$((stuck + 1)) ;;
        esac
        [ -n "$deps" ] || continue
        local d
        IFS=',' read -r -a dep_arr <<EOF
$deps
EOF
        for d in "${dep_arr[@]}"; do
          d=$(printf '%s' "$d" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          [ -n "$d" ] || continue
          local doc
          doc=$(sdag_classify "$(last_status_line "$STATE/$d.status" 2>/dev/null)")
          case "$doc" in
            failed|blocked|needs-decision) stuck=$((stuck + 1)) ;;
          esac
        done
      done < "$f"
      if [ "$stuck" -gt 0 ]; then
        echo "error: $pending node(s) pending with no ready frontier (a dep failed)" >&2
        sdag_print_replan "$f"
        return 1
      fi
      # No failed/blocked/needs-decision dep. The DAG is paused on a
      # declared-external-wait leaf; surface the pause and exit 0 so
      # manual dispatch (resume the leaf, then re-run) remains the path.
      echo "notice: $pending node(s) waiting on a paused leaf (manual resume required)" >&2
      return 0
    fi
    if [ "$MAX_PARALLEL" -gt 0 ]; then
      local capped; capped=$(mktemp)
      head -n "$MAX_PARALLEL" "$ready" > "$capped"
      mv "$capped" "$ready"
    fi
    # Dispatch every ready node in parallel (each via its own backgrounded
    # spawn-bin call). A spawned fm-spawn.sh returns quickly; the actual scout
    # runs detached, so this does not serialize within the layer.
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      project=$(awk -F'|' -v k="$id" '$1==k {print $2; exit}' "$f")
      sdag_dispatch "$id" "$project" "$STATE" || true
    done < "$ready"
    outcomes=$(mktemp)
    sdag_wait_layer "$STATE" "$ready" "$outcomes"
    failed_count=0
    blocked_count=0
    paused_count=0
    while IFS='|' read -r id oc note; do
      [ -n "$id" ] || continue
      case "$oc" in
        done) : ;;
        failed)
          failed_count=$((failed_count + 1))
          echo "node $id failed: $note" >&2
          ;;
        blocked|needs-decision)
          blocked_count=$((blocked_count + 1))
          echo "node $id needs captain decision: $note" >&2
          ;;
        paused)
          paused_count=$((paused_count + 1))
          echo "node $id paused: $note" >&2
          ;;
      esac
    done < "$outcomes"
    if [ "$ABORT_ON_FAIL" -eq 1 ] && [ "$failed_count" -gt 0 ]; then
      echo "error: --abort-on-fail set; $failed_count node(s) failed" >&2
      sdag_print_replan "$f"
      rm -f "$ready" "$outcomes"
      return 5
    fi
    if [ "$failed_count" -gt 0 ] || [ "$blocked_count" -gt 0 ]; then
      sdag_print_replan "$f"
      rm -f "$ready" "$outcomes"
      return 0
    fi
    rm -f "$ready" "$outcomes"
    layer=$((layer + 1))
    iter=$((iter + 1))
    if [ "$iter" -ge 1000 ]; then
      echo "error: runaway iteration (>1000 layers); aborting" >&2
      return 2
    fi
  done
}

# ---- main ----

[ -f "$BACKLOG" ] || { echo "error: backlog not found: $BACKLOG" >&2; exit 2; }
[ -d "$STATE" ] || mkdir -p "$STATE"

DAG=$(mktemp)
trap 'rm -f "$DAG" 2>/dev/null || true' EXIT

if ! sdag_build_dag "$BACKLOG" "$ROOT_ID" "$INCLUDE_KIND" "$DAG"; then
  exit 3
fi
sdag_detect_cycle "$DAG" || exit 3
sdag_validate "$DAG" || exit 3

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DAG rooted at: $ROOT_ID"
  echo "Plan:"
  layers=$(mktemp)
  sdag_compute_layers "$DAG" "$layers"
  awk -F'|' '{print "Layer " $2 ":"; print "  " $1}' "$layers"
  rm -f "$layers"
  exit 0
fi

sdag_run "$DAG"
exit $?