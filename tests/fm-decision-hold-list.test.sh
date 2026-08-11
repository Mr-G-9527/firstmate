#!/usr/bin/env bash
# Behavior tests for the AXI #9 `list` subcommand added to bin/fm-decision-hold.sh
# and the distinct rc=20 "tool unavailable" exit code (which the unresolved-
# decision completion gate at bin/fm-teardown.sh:2320 now distinguishes from
# the rc=1 "decision unverified" failure it used to conflate with).
#
# Every assertion drives the executable interface end-to-end rather than
# grepping source bytes, per firstmate-coding-guidelines.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECISION_HOLD="$ROOT/bin/fm-decision-hold.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold-list)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$DECISION_HOLD" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

# AXI #5 definitive empty state: an empty inventory is the same shape as
# missing data, but a captain-facing surface must still surface "0 results"
# rather than go silent. The text path prints the literal `0 results`; the
# JSON path prints a parseable `[]`. Both are exercised here.
test_list_with_no_holds_prints_zero_results_not_silent() {
  local home out rc
  home=$(make_home list-empty)
  out=$(run_decisions "$home" list) || fail "list with no holds exited non-zero"
  [ "$out" = "0 results" ] || fail "list with no holds must print '0 results' (AXI #5), got: $out"
  out=$(run_decisions "$home" list --json) || fail "list --json with no holds exited non-zero"
  printf '%s' "$out" | jq -e '. == []' >/dev/null \
    || fail "list --json with no holds must be a parseable empty array: $out"
  pass "list prints '0 results' for an empty inventory, --json prints '[]' (AXI #5)"
}

# Every AXI #9 key documented in the brief must appear on every non-empty
# row, both in the text formatter and in the JSON output. A missing key is a
# silent regression of the contract the captain-facing surface relies on.
test_list_row_contains_every_axi9_key() {
  local home id route_hold access_hold text json rc
  home=$(make_home list-rows)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create origin backlog fixture"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=route]: choose route north or route south\n' \
    > "$home/state/$id.status"
  printf 'needs-decision [key=access]: choose open or restricted sample access\n' \
    >> "$home/state/$id.status"
  printf '# Sample systems review\n\nTwo choices remain unresolved.\n' \
    > "$home/data/$id/report.md"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared completion gate failed"

  text=$(FM_NOW_DATE=2026-08-11 run_decisions "$home" list) \
    || fail "list with holds exited non-zero"
  case "$text" in
    *"$route_hold"*) : ;;
    *) fail "list text output missing $route_hold row: $text" ;;
  esac
  case "$text" in
    *"$access_hold"*) : ;;
    *) fail "list text output missing $access_hold row: $text" ;;
  esac
  # Every AXI #9 key documented in the brief must appear at least once in
  # the text output. The brief's row format shows one row per hold with all
  # eight fields, so each field appears once per hold.
  for field in 'id:' 'origin:' 'state:' 'age:' 'why-now:' 'dependency:' 'unlocks:' 'summary:'; do
    case "$text" in
      *"$field"*) : ;;
      *) fail "list text output missing AXI #9 field '$field': $text" ;;
    esac
  done

  json=$(FM_NOW_DATE=2026-08-11 run_decisions "$home" list --json) \
    || fail "list --json with holds exited non-zero"
  # jq treats dotted keys with hyphens (like `why-now`) as arithmetic
  # subtraction unless indexed via the bracket form, so the schema check
  # uses .["why-now"] / .["dependency"] / .["unlocks"] everywhere.
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    length == 2
      and (.[0] | keys | sort) == ["age","dependency","id","origin","state","summary","unlocks","why-now"]
      and any(.id == $route)
      and any(.id == $access)
      and (.[0].state | IN("pending","routed","resolved"))
      and (.[0]["why-now"] | test("state/.*\\.status:[0-9]+"))
      and (.[0]["dependency"] | type == "string")
      and (.[0]["unlocks"] | type == "string")
      and (.[0].age | test("^[0-9]+d$"))
      and (.[0].summary | length > 0)
  ' >/dev/null || fail "list --json output does not match the AXI #9 schema: $json"

  pass "list output carries every AXI #9 key per row (text and JSON)"
}

# AXI #9 state semantics: a hold with no dependents is `pending`; once at
# least one task is blocked by it, it becomes `routed`; once the resolution
# record lands in the body and state=closed, it becomes `resolved`. Each
# transition is exercised end-to-end through the executable interface, with
# the state read back from `list --json` rather than from a parsed body.
test_list_state_transitions_pending_routed_resolved() {
  local home id hold json rc
  home=$(make_home list-states)
  id=sample-state-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate state transitions" --kind scout --repo sample --start >/dev/null \
    || fail "could not create origin backlog fixture"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=alpha]: captain must pick alpha\n' > "$home/state/$id.status"
  printf '# Sample state review\n\nAlpha is the only open decision.\n' > "$home/data/$id/report.md"

  hold=$(run_decisions "$home" hold "$id" alpha \
    --title "Pick alpha" --reason "captain alpha choice pending" --repo sample) \
    || fail "could not register alpha hold"
  run_decisions "$home" complete "$id" alpha >/dev/null || fail "completion gate failed"
  json=$(FM_NOW_DATE=2026-08-11 run_decisions "$home" list --json) \
    || fail "list pending --json exited non-zero"
  printf '%s' "$json" | jq -e --arg h "$hold" '
    any(.id == $h and .state == "pending" and .["dependency"] == "no-block")
  ' >/dev/null || fail "alpha hold should be pending with no dependents: $json"

  tasks_in "$home" add dep-alpha-1 "Implement alpha-1" --kind ship --repo sample >/dev/null \
    || fail "could not create dependent dep-alpha-1"
  tasks_in "$home" add dep-alpha-2 "Implement alpha-2" --kind ship --repo sample >/dev/null \
    || fail "could not create dependent dep-alpha-2"
  tasks_in "$home" block dep-alpha-1 --by "$hold" >/dev/null || fail "could not block dep-alpha-1"
  tasks_in "$home" block dep-alpha-2 --by "$hold" >/dev/null || fail "could not block dep-alpha-2"
  json=$(FM_NOW_DATE=2026-08-11 run_decisions "$home" list --json) \
    || fail "list routed --json exited non-zero"
  printf '%s' "$json" | jq -e --arg h "$hold" '
    any(.id == $h and .state == "routed"
        and (.["dependency"] | test("dep-alpha-1\\(queued\\)"))
        and (.["dependency"] | test("dep-alpha-2\\(queued\\)")))
  ' >/dev/null || fail "alpha hold should be routed with both dependents: $json"

  # Drive the resolution through the executable interface so the state
  # transition is exercised via the real `resolve` path, not by editing the
  # backlog body. dep-alpha-1 is the routed-to target.
  printf 'Pick alpha: north.\n' > "$home/alpha-decision.txt"
  run_decisions "$home" resolve "$id" alpha --decision-file "$home/alpha-decision.txt" \
    --routed-to dep-alpha-1 >/dev/null || fail "resolution failed"
  json=$(FM_NOW_DATE=2026-08-11 run_decisions "$home" list --json) \
    || fail "list resolved --json exited non-zero"
  printf '%s' "$json" | jq -e --arg h "$hold" '
    any(.id == $h and .state == "resolved")
  ' >/dev/null || fail "alpha hold should be resolved after resolve: $json"

  pass "list --json state transitions: pending -> routed -> resolved (via real resolve path)"
}

# Filter contract: --by-origin restricts the inventory to one origin,
# --by-key restricts to one decision-key, --by-key + --by-origin is a usage
# error. An out-of-filter row must never appear in the output.
test_list_filters_by_origin_and_by_key() {
  local home id1 id2 hold_a hold_b json rc
  home=$(make_home list-filters)
  id1=sample-origin-a
  id2=sample-origin-b
  mkdir -p "$home/data/$id1" "$home/data/$id2"
  tasks_in "$home" add "$id1" "Origin A" --kind scout --repo sample --start >/dev/null || fail "add $id1"
  tasks_in "$home" add "$id2" "Origin B" --kind scout --repo sample --start >/dev/null || fail "add $id2"
  write_origin_meta "$home" "$id1"
  write_origin_meta "$home" "$id2"
  printf 'needs-decision [key=route]: pick route\n' > "$home/state/$id1.status"
  printf 'needs-decision [key=access]: pick access\n' > "$home/state/$id2.status"
  printf '# A\n' > "$home/data/$id1/report.md"
  printf '# B\n' > "$home/data/$id2/report.md"

  hold_a=$(run_decisions "$home" hold "$id1" route \
    --title "A route" --reason "captain a route pending" --repo sample) \
    || fail "could not hold A route"
  hold_b=$(run_decisions "$home" hold "$id2" access \
    --title "B access" --reason "captain b access pending" --repo sample) \
    || fail "could not hold B access"
  run_decisions "$home" complete "$id1" route >/dev/null || fail "complete A"
  run_decisions "$home" complete "$id2" access >/dev/null || fail "complete B"

  json=$(run_decisions "$home" list --by-origin "$id1" --json) || fail "list --by-origin exited non-zero"
  printf '%s' "$json" | jq -e --arg a "$hold_a" --arg b "$hold_b" '
    length == 1 and (.[0].id == $a) and (any(.id == $b) | not)
  ' >/dev/null || fail "--by-origin filter let the wrong row through: $json"

  json=$(run_decisions "$home" list --by-key access --json) || fail "list --by-key exited non-zero"
  printf '%s' "$json" | jq -e --arg a "$hold_a" --arg b "$hold_b" '
    length == 1 and (.[0].id == $b) and (any(.id == $a) | not)
  ' >/dev/null || fail "--by-key filter let the wrong row through: $json"

  set +e
  run_decisions "$home" list --by-key access --by-origin "$id1" \
    > "$home/mutual.out" 2> "$home/mutual.err"
  rc=$?
  set -e
  [ "$rc" = 2 ] || fail "mutually-exclusive filter flags must exit rc=2, got $rc: $(cat "$home/mutual.err")"
  pass "list filters: --by-origin and --by-key narrow the inventory; combining them is a usage error"
}

# rc=20 distinct from rc=1: when tasks-axi is missing, every verify/complete
# call must exit rc=20 (tool unavailable), not rc=1 (decision unverified).
# The §1.6 self-scaffolding note this fix pins recorded the wedge: a
# missing tasks-axi was indistinguishable from a missing decision inventory,
# and bin/fm-teardown.sh misreported the gate as failed when the tool itself
# was the problem. Each subcommand is exercised through the executable
# interface with a stubbed fakebin.
test_rc_20_when_tasks_axi_unavailable() {
  local home out rc
  home=$(make_home unavailable-hold)
  # Replace the real tasks-axi stub with one that always exits 127 so the
  # bin/fm-tasks-axi-lib.sh probe declares the tool unavailable.
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  write_origin_meta "$home" sample

  set +e
  run_decisions "$home" verify sample > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" = 20 ] || fail "verify with tasks-axi unavailable must exit rc=20, got $rc: $(cat "$home/verify.err")"

  set +e
  run_decisions "$home" complete sample --none > "$home/complete.out" 2> "$home/complete.err"
  rc=$?
  set -e
  [ "$rc" = 20 ] || fail "complete with tasks-axi unavailable must exit rc=20, got $rc: $(cat "$home/complete.err")"

  set +e
  run_decisions "$home" list > "$home/list.out" 2> "$home/list.err"
  rc=$?
  set -e
  [ "$rc" = 20 ] || fail "list with tasks-axi unavailable must exit rc=20, got $rc: $(cat "$home/list.err")"

  pass "rc=20 is the distinct exit code for tasks-axi unavailable (verify, complete, list)"
}

# The completion gate in bin/fm-teardown.sh must surface rc=20 distinctly
# from rc=1: rc=20 means the gate is UNKNOWN (tool unavailable), rc=1 means
# the gate truly failed (decision unverified). Both still refuse teardown
# because the gate status is not green; only the diagnostic differs so the
# captain can act on the right surface. The two paths are exercised against
# real teardown runs.
test_teardown_distinguishes_rc20_from_rc1() {
  local home id out rc
  home=$(make_home teardown-rc20-vs-rc1)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id" scout
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"

  # rc=20 path: stub tasks-axi as unavailable.
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" > "$home/teardown-rc20.out" 2> "$home/teardown-rc20.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown accepted a scout task when the gate was unknown (rc=20 path)"
  assert_present "$home/state/$id.meta" "rc=20 path teardown must preserve investigation metadata"
  assert_grep "tool unavailable (rc=20)" "$home/teardown-rc20.err" \
    "rc=20 path teardown must surface the distinct tool-unavailable diagnostic"
  # The legacy "missing decision" message must NOT appear here: a single
  # diagnostic per refusal keeps the captain's response surface unambiguous.
  if grep -F "has not passed the unresolved-decision completion gate" "$home/teardown-rc20.err" >/dev/null; then
    fail "rc=20 path teardown must not emit the legacy 'completion gate' message"
  fi

  # rc=1 path: real tasks-axi (the bin/fm-fakebin exit-0 stub does not block
  # the real tool, since fm-decision-hold.sh invokes it directly) and a meta
  # without decisions_reviewed=1, so verify fails for the genuine "decision
  # unverified" reason. The legacy diagnostic must appear unchanged.
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
exec "$TASKS_AXI_BIN" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" > "$home/teardown-rc1.out" 2> "$home/teardown-rc1.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown accepted a scout task when the gate genuinely failed (rc=1 path)"
  assert_grep "has not passed the unresolved-decision completion gate" "$home/teardown-rc1.err" \
    "rc=1 path teardown must keep the legacy 'completion gate' diagnostic"
  if grep -F "tool unavailable (rc=20)" "$home/teardown-rc1.err" >/dev/null; then
    fail "rc=1 path teardown must not emit the rc=20 'tool unavailable' diagnostic"
  fi

  pass "fm-teardown.sh distinguishes rc=20 tool-unavailable from rc=1 decision-unverified"
}

test_list_with_no_holds_prints_zero_results_not_silent
test_list_row_contains_every_axi9_key
test_list_state_transitions_pending_routed_resolved
test_list_filters_by_origin_and_by_key
test_rc_20_when_tasks_axi_unavailable
test_teardown_distinguishes_rc20_from_rc1
