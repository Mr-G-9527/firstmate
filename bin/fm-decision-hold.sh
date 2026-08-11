#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh list [--all | --by-key <key> | --by-origin <origin>] [--json]
#
# `list` prints the open-decision inventory with one row per captain-held
# decision. Each row carries the full AXI #9 context (id, origin, state, age,
# why-now episode, dependency, what unlocks, hold_reason summary) so a reader
# does not have to chase downstream sources to understand each entry.
# `--by-key <key>` filters by decision-key slug; `--by-origin <origin>` filters
# by owning task-id; `--all` (the default when no filter is given) shows every
# inventoried hold across the active home. The source is the per-origin
# `decision_keys` field of `state/<id>.meta` — the same path `verify` uses to
# enumerate holds — so `list` cannot disagree with `complete --none`'s
# attestation about which decisions are open.
#
# Exit codes (consumed by bin/fm-teardown.sh at the unresolved-decision
# completion gate and by every other caller):
#   0  success (hold or no-op)
#   1  decision unverified: a captain-held backlog item is missing, the wrong
#      kind, not held for the captain, the origin has no completed inventory,
#      or a status-stream open decision has no captain-held inventory entry
#   2  usage error (wrong number of arguments, unknown flag)
#  20  tool unavailable: `tasks-axi` is missing, below the compat floor in
#      bin/fm-tasks-axi-lib.sh, or fails to expose the `--kind captain` contract
#      required to hold a captain decision
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

DECISION_META_LOCK=
DECISION_META_LOCK_HELD=0
decision_hold_cleanup() {
  if [ "$DECISION_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_META_LOCK" || true
    DECISION_META_LOCK_HELD=0
  fi
}
trap decision_hold_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

# Distinct exit code for "the tool we need is not available" (tasks-axi is
# missing or below the compat floor). The unresolved-decision completion gate
# in bin/fm-teardown.sh:2320 treats rc=20 differently from a rc=1 "decision
# unverified" failure: rc=20 means the gate is UNKNOWN (we cannot prove the
# inventory passed) rather than "the inventory is provably absent". Refusing
# teardown on rc=1 because we cannot find a decision when the tool is
# unavailable conflates the two and was the wedge §1.6 of the self-scaffolding
# report caught. Documented in this script's help text above.
fail_tool_unavailable() {
  printf 'fm-decision-hold: tool unavailable: %s\n' "$*" >&2
  exit 20
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail_tool_unavailable "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail_tool_unavailable "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Map a held captain decision's tasks-axi state + body to one of the three
# fleet-visible lifecycle states:
#   pending  - held=yes, no resolution record; awaiting captain decision
#   routed  - held=yes AND at least one dependent task is blocked by this hold;
#             the hold is awaiting captain decision but the work behind it is
#             already wired up
#   resolved - state=done AND the durable "Resolution recorded by
#             fm-decision-hold." body marker is present; the captain decision
#             has been recorded and the dependent work has been unblocked
# A hold that has been resolved but lacks the durable body marker is treated
# as "pending" with a state note rather than "resolved", because the durable
# record is the contract the rest of the fleet reads from. Returning empty
# here means "this id is not a captain decision at all" and the caller skips
# the row.
hold_lifecycle_state() {  # <hold-show>
  local show=$1 state kind body
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$kind" = captain ] || return 1
  case "$state" in
    done)
      case "$body" in
        *"Resolution recorded by fm-decision-hold."*) printf 'resolved' ;;
        *) printf 'pending' ;;
      esac
      ;;
    queued) printf 'pending' ;;
    *) return 1 ;;
  esac
}

# Find the line number of the first status-stream episode that surfaced the
# decision for an origin. The precedence is:
#   1. `needs-decision [key=<key>]: ...` in state/<origin>.status - the original
#      surface where the decision was identified (report-derived decisions
#      that did not come from a status line fall through to step 2)
#   2. `captain-held [key=<key>]: ...` in state/<origin>.status - the line
#      written after command_complete transferred the live status decision to
#      its durable backlog owner
#   3. data/<origin>/report.md - the report that surfaced the decision; emit
#      a generic `<report>:1` because report files do not carry per-decision
#      line markers
#   4. empty - no episode located; the row shows "unknown"
why_now_episode() {  # <origin> <key>
  local origin=$1 key=$2 status_file report_file line ln=0
  status_file="$STATE/$origin.status"
  report_file="$DATA/$origin/report.md"
  if [ -f "$status_file" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ln=$((ln + 1))
      case "$line" in
        "needs-decision [key=$key]:"*|"needs-decision:"*) \
          printf 'state/%s.status:%d' "$origin" "$ln"; return 0 ;;
      esac
    done < "$status_file"
    ln=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ln=$((ln + 1))
      case "$line" in
        "captain-held [key=$key]:"*|"captain-held:"*) \
          printf 'state/%s.status:%d' "$origin" "$ln"; return 0 ;;
      esac
    done < "$status_file"
  fi
  if [ -f "$report_file" ]; then
    printf 'data/%s/report.md:1' "$origin"
    return 0
  fi
  printf 'unknown'
}

# Map a hold's tasks-axi `created` YYYY-MM-DD to "Nd" or "unknown" if the
# field is missing or unparseable. FM_NOW_DATE pins "today" so tests can age
# holds deterministically.
hold_age_days() {  # <hold-show>
  local show=$1 created cur days
  created=$(show_field "$show" created)
  [ -n "$created" ] || { printf 'unknown'; return; }
  cur=$(_today_epoch_days) || { printf 'unknown'; return; }
  days=$(_date_epoch_days "$created") || { printf 'unknown'; return; }
  days=$((cur - days))
  [ "$days" -ge 0 ] 2>/dev/null || { printf 'unknown'; return; }
  printf '%dd' "$days"
}

# Find every task whose `blocked_by` carries <hold-id>. Returns one
# "<task-id> (<state>)" pair per dependent, space-separated, in tasks-axi list
# glob order. Empty when no dependents are registered, which the caller renders
# as `no-block`. A dependent's state is read at list time so a row that shows
# "task-done" reflects a follow-up that has already shipped past the hold.
#
# Implementation note: tasks-axi's `blocked_by` is quoted as a single CSV when
# multi-entry ("a,b,c"); the per-task stripping is the same pattern
# command_resolve uses, so a quoted blocked_by that lists the hold as its
# first, middle, or last element all match. We strip the first five fixed
# fields (id, state, kind, repo, title) before consuming blocked_by so the
# quoted CSV in the last field stays intact, instead of splitting on every
# comma and breaking on the inner one.
hold_dependents() {  # <hold-id>
  local hold_id=$1 list_output header rest tmp blocked state id trimmed
  list_output=$(tasks_axi list --fields blocked_by 2>/dev/null) || return 0
  # tasks-axi prints a `count: N` line ahead of the `tasks[N]{fields}:` header
  # and a trailing `help[N]:` block; locate the header so the row-parsing
  # loop below can be a simple line reader.
  header=$(printf '%s\n' "$list_output" | grep -E '^tasks\[[0-9]+\]\{id,' | head -1) || return 0
  [ -n "$header" ] || return 0
  rest=${list_output#*$'\n'}
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      'help['*|count:*) break ;;
    esac
    # tasks-axi list output indents data rows with two leading spaces; trim
    # both ends so the first-field id is the bare task slug, not "  id".
    trimmed=$line
    trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    id=${trimmed%%,*}
    # Strip the first five comma-separated fields (id,state,kind,repo,title);
    # whatever remains is the blocked_by value, possibly quoted.
    tmp=$trimmed
    tmp=${tmp#*,}; tmp=${tmp#*,}; tmp=${tmp#*,}; tmp=${tmp#*,}; tmp=${tmp#*,}
    blocked=$tmp
    case "$blocked" in
      '"'*'"') blocked=${blocked#\"}; blocked=${blocked%\"} ;;
    esac
    case ",$blocked," in
      *,$hold_id,*) : ;;
      *) continue ;;
    esac
    # State is field 2; always a simple token (queued|in_flight|done|held),
    # so a head-of-line trim up to the next comma is sufficient.
    state=${trimmed#*,}; state=${state%%,*}
    [ -n "$state" ] || state=unknown
    printf '%s(%s) ' "$id" "$state"
  done <<EOF
$rest
EOF
}

# Render a single row's `<dependency>` field. Pass an empty string from
# hold_dependents to mean "no dependents registered"; that becomes the literal
# `no-block` so the reader can scan for unblocked holds at a glance.
format_dependency() {  # <dependents-string>
  local deps=${1:-}
  if [ -z "$deps" ]; then
    printf 'no-block'
    return
  fi
  printf '%s' "${deps% }"
}

# Render a single row's `<unlocks>` field. The action is the exact
# `command_resolve` invocation the captain runs to close the hold, and the
# downstream list mirrors the registered dependents so the reader sees what
# ships after the decision lands.
format_unlocks() {  # <origin> <key> <dependents-string>
  local origin=$1 key=$2 deps=${3:-}
  local action="fm-decision-hold.sh resolve ${origin} ${key} --decision-file <path> --routed-to <task-id>"
  if [ -z "$deps" ]; then
    printf '%s + no downstream tasks currently registered' "$action"
    return
  fi
  printf '%s + unblocks: %s' "$action" "${deps% }"
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Parse a YYYY-MM-DD (or YYYY-M-D, etc.) date into days-since-epoch using
# portable `date -d` / `date -j` for Linux and macOS respectively. Returns empty
# on parse failure so callers can fall back to an unknown-age display.
_date_epoch_days() {  # <date-string>
  local d=$1 epoch
  case "$d" in
    '') return 1 ;;
  esac
  if epoch=$(date -d "$d" +%s 2>/dev/null); then :; \
  elif epoch=$(date -j -f '%Y-%m-%d' "$d" +%s 2>/dev/null); then :; \
  else return 1; fi
  printf '%s' "$((epoch / 86400))"
}

# today_epoch_days: today's date (UTC) expressed as days since epoch, so the
# age column can subtract hold-creation days without time-of-day drift. Honors
# FM_NOW_DATE override so tests can pin "today" deterministically.
_today_epoch_days() {
  local now
  if [ -n "${FM_NOW_DATE:-}" ]; then
    _date_epoch_days "${FM_NOW_DATE%T*}" || { echo 0; return; }
    return
  fi
  now=$(date -u +%Y-%m-%d)
  _date_epoch_days "$now" || { echo 0; return; }
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  # fm friction #3 (2026-08-05): tasks_axi rejects parens in --reason. Detect
  # early + tell the user to rephrase (e.g. cite line ranges as L513-517, not
  # (controller:513-517)) rather than failing inscrutably downstream.
  case "$reason" in
    *'('*|*')'*)
      fail "--reason cannot contain parentheses (tasks_axi rejects them). Rephrase without parens; cite line ranges as L513-517 or 'controller 513-517', not (controller:513-517). Got: $reason" ;;
  esac
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

# Build one row of AXI #9 context for a single hold. Prints four
# "<key>=<value>" assignments in stable order, one per line, so a JSON
# assembler can concatenate rows with commas and the text formatter can
# pick fields by name without positional drift. Empty keys (no dependents)
# are emitted as their sentinel token (`no-block`) so the reader can scan
# for unblocked holds at a glance.
list_row_for() {  # <origin> <key> <hold-show>
  local origin=$1 key=$2 show=$3 state dependents age why_now dep unlocks summary
  state=$(hold_lifecycle_state "$show") || return 0
  dependents=$(hold_dependents "$(hold_id "$origin" "$key")")
  # "routed" means the hold has at least one dependent registered, even
  # while still awaiting the captain decision. A pending hold with zero
  # dependents stays "pending"; resolved stays "resolved" regardless of
  # dependents because the durable record already closed the lifecycle.
  if [ "$state" = pending ] && [ -n "$dependents" ]; then
    state=routed
  fi
  age=$(hold_age_days "$show")
  why_now=$(why_now_episode "$origin" "$key")
  dep=$(format_dependency "$dependents")
  unlocks=$(format_unlocks "$origin" "$key" "$dependents")
  summary=$(show_field "$show" hold_reason)
  [ -n "$summary" ] || summary='<no hold_reason recorded>'
  printf 'id=%s\norigin=%s\nstate=%s\nage=%s\nwhy-now=%s\ndependency=%s\nunlocks=%s\nsummary=%s\n' \
    "$(hold_id "$origin" "$key")" "$origin" "$state" "$age" "$why_now" "$dep" "$unlocks" "$summary"
}

# Emit the full `list` payload. Walks every state/<id>.meta (the same source
# `verify` uses to enumerate holds for one origin), looks up each inventoried
# hold via task_show, and yields AXI #9 rows. The output is sorted by
# (origin, key) for deterministic captain-facing presentation; the JSON path
# uses the same ordering so consumers can rely on it.
command_list() {
  local mode=all by_key='' by_origin='' as_json=0 meta origin keys key show
  local rows_holder=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) mode=all ;;
      --by-key) shift; by_key=${1:-}; [ -n "$by_key" ] || fail "--by-key requires a value" ;;
      --by-origin) shift; by_origin=${1:-}; [ -n "$by_origin" ] || fail "--by-origin requires a value" ;;
      --json) as_json=1 ;;
      *) fail "unknown list flag: $1" ;;
    esac
    shift
  done
  # Reject mutually-exclusive filter flags up front so a confused caller
  # gets a clean diagnostic instead of one filter silently masking another.
  # This is a usage error (rc=2), not a "decision unverified" failure (rc=1).
  if [ -n "$by_key" ] && [ -n "$by_origin" ]; then
    usage >&2
    exit 2
  fi
  case "$mode" in
    all) ;;
    *) fail "unknown list filter mode: $mode" ;;
  esac
  require_tasks_axi
  if [ "$as_json" = 1 ]; then
    command -v jq >/dev/null 2>&1 || fail "--json output requires jq"
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    origin=$(basename "$meta" .meta)
    [ -n "$by_origin" ] && [ "$origin" != "$by_origin" ] && continue
    keys=$(meta_value "$meta" decision_keys)
    [ -n "$keys" ] || continue
    for key in $(printf '%s' "$keys" | tr ',' ' '); do
      [ -n "$key" ] || continue
      [ -n "$by_key" ] && [ "$key" != "$by_key" ] && continue
      show=$(task_show "$(hold_id "$origin" "$key")") || continue
      rows_holder="${rows_holder}$(list_row_for "$origin" "$key" "$show")"$'\x1e'
    done
  done

  list_render_rows "$rows_holder" "$as_json"
}

# Format the row buffer either as human-readable text (default) or as a JSON
# array (--json). The buffer uses \x1e (US) as the per-row separator; each row
# itself is exactly 8 lines of `key=value`, in the fixed order list_row_for
# documents. Splitting on \x1e gives one row per hold; fields are then read by
# name so a future field addition or reorder does not break consumers.
list_render_rows() {  # <rows-buffer> <as-json-0-or-1>
  local rows=$1 as_json=$2 first=1 row key value
  if [ -z "$rows" ]; then
    if [ "$as_json" = 1 ]; then
      printf '[]\n'
    else
      printf '0 results\n'
    fi
    return 0
  fi
  if [ "$as_json" = 1 ]; then printf '[\n'; fi
  while IFS= read -r -d $'\x1e' row; do
    [ -n "$row" ] || continue
    if [ "$first" = 1 ]; then
      first=0
    elif [ "$as_json" = 1 ]; then
      printf ',\n'
    else
      printf '\n'
    fi
    if [ "$as_json" = 1 ]; then
      printf '{'
      local i=0
      while IFS= read -r line; do
        i=$((i + 1))
        key=${line%%=*}
        value=${line#*=}
        if [ "$i" -gt 1 ]; then printf ', '; else printf ' '; fi
        printf '"%s": "%s"' "$(json_escape "$key")" "$(json_escape "$value")"
      done <<EOF
$row
EOF
      printf '\n}'
    else
      while IFS= read -r line; do
        key=${line%%=*}
        value=${line#*=}
        printf '  %-12s %s\n' "$key:" "$value"
      done <<EOF
$row
EOF
    fi
  done <<EOF
$rows
EOF
  if [ "$as_json" = 1 ]; then printf '\n]\n'; fi
}

# Escape a value for inclusion in a JSON string. The script's input surface
# validates --reason as a single ASCII line with no parens, and field values
# inherit that constraint, so the only escapes we need are the JSON-mandatory
# ones (backslash, double quote, control characters).
json_escape() {  # <value>
  local v=$1 out='' c nl cr tab bs
  nl=$(printf '\n_'); nl=${nl%_}
  cr=$(printf '\r_'); cr=${cr%_}
  tab=$(printf '\t_'); tab=${tab%_}
  # The case pattern below matches a single literal backslash, which is
  # the JSON escape character we want to expand to '\\'. Building it via
  # printf avoids shellcheck flagging the literal backslash in source.
  # shellcheck disable=SC1003
  bs=$(printf '%s' '\\')
  while IFS= read -r -n1 c || [ -n "$c" ]; do
    case "$c" in
      '') : ;;
      "$bs")      out="${out}\\\\" ;;
      '"')        out="${out}\\\"" ;;
      "$nl")      out="${out}\\n" ;;
      "$cr")      out="${out}\\r" ;;
      "$tab")     out="${out}\\t" ;;
      *)          out="${out}$c" ;;
    esac
  done <<EOF
$v
EOF
  printf '%s' "$out"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  list) shift; command_list "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
