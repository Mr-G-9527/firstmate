#!/usr/bin/env bash
# Behavior regressions for tools/session_end.py (Mechanic C wrap-receipt writer).
#
# Covers the contract the captain reopens 209a against:
#   - --suggestion produces a real receipt at $RECEIPT
#   - re-running --suggestion is idempotent (no duplicate entries)
#   - jq can extract the entry by note_id
#   - default mode reads stdin JSON, derives session_id, and writes a receipt
#   - --help exits 0 with usage
#   - --label rejects an off-schema label
# These all run as plain subprocess calls into the Python script so the script
# stays the single source of truth for behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/tools/session_end.py"
TMP_ROOT=$(fm_test_tmproot fm-session-end)
fake_home="$TMP_ROOT/home"

# Invoke via python3 explicitly so the test does not depend on the file's
# executable bit - mirrors the .claude/settings.json SessionEnd hook command.
run_session_end() {
  FM_HOME="$fake_home" python3 "$SCRIPT" "$@"
}

test_help_exits_zero() {
  local out
  out=$(run_session_end --help 2>&1) || fail "--help exited nonzero"
  assert_contains "$out" "session_end.py" "--help missing program name"
  assert_contains "$out" "--suggestion" "--help missing --suggestion flag"
  pass "--help exits 0 and shows usage"
}

test_suggestion_writes_receipt() {
  local receipt="$TMP_ROOT/suggestion.json"
  run_session_end --suggestion --receipt "$receipt" >/dev/null \
    || fail "--suggestion exited nonzero"
  [ -f "$receipt" ] || fail "receipt file was not written"
  local count
  count=$(jq 'length' "$receipt") || fail "jq failed on receipt"
  [ "$count" = "1" ] || fail "expected 1 receipt, got $count"
  local note
  note=$(jq -r '.[0].note_id' "$receipt") || fail "jq .[0].note_id failed"
  [ "$note" = "209a" ] || fail "expected note_id 209a, got $note"
  local label
  label=$(jq -r '.[0].label' "$receipt") || fail "jq .[0].label failed"
  case "$label" in
    实测达成|部分达成|未验|被替代|被放弃) : ;;
    *) fail "label $label is not one of the 5 canonical labels" ;;
  esac
  local session_id
  session_id=$(jq -r '.[0].session_id' "$receipt") || fail "jq session_id failed"
  [ "$session_id" = "suggestion-mechanic-c-209a" ] \
    || fail "expected stable suggestion session_id, got $session_id"
  pass "--suggestion writes a receipt (1 entry, note_id 209a, canonical label)"
}

test_suggestion_is_idempotent() {
  local receipt="$TMP_ROOT/idempotent.json"
  run_session_end --suggestion --receipt "$receipt" >/dev/null \
    || fail "first --suggestion exited nonzero"
  run_session_end --suggestion --receipt "$receipt" >/dev/null \
    || fail "second --suggestion exited nonzero"
  local count
  count=$(jq 'length' "$receipt") || fail "jq length failed"
  [ "$count" = "1" ] || fail "idempotent re-run duplicated entry: count=$count"
  pass "second --suggestion does not duplicate the entry"
}

test_suggestion_filters_by_note_id() {
  local receipt="$TMP_ROOT/filter.json"
  run_session_end --suggestion --receipt "$receipt" >/dev/null \
    || fail "--suggestion exited nonzero"
  local hit
  hit=$(jq '.[] | select(.note_id == "209a")' "$receipt") \
    || fail "jq select failed"
  case "$hit" in
    *"\"note_id\": \"209a\""*) : ;;
    *) fail "jq select for 209a returned no hit: $hit" ;;
  esac
  pass "jq select .note_id == \"209a\" returns the new entry"
}

test_default_mode_reads_stdin_and_writes_receipt() {
  local receipt="$TMP_ROOT/default.json"
  printf '{"session_id":"abc123","note_id":"captain-x"}' \
    | run_session_end --receipt "$receipt" >/dev/null \
    || fail "default mode exited nonzero"
  [ -f "$receipt" ] || fail "default mode did not write receipt"
  local count
  count=$(jq 'length' "$receipt") || fail "jq length failed"
  [ "$count" = "1" ] || fail "expected 1 receipt from default mode, got $count"
  local session_id
  session_id=$(jq -r '.[0].session_id' "$receipt") || fail "jq session_id failed"
  [ "$session_id" = "abc123" ] \
    || fail "default mode ignored stdin session_id, got $session_id"
  local note_id
  note_id=$(jq -r '.[0].note_id' "$receipt") || fail "jq note_id failed"
  [ "$note_id" = "captain-x" ] \
    || fail "default mode ignored stdin note_id, got $note_id"
  pass "default mode honors stdin session_id and note_id"
}

test_default_mode_auto_fills_from_state() {
  local state_home="$TMP_ROOT/home-state"
  mkdir -p "$state_home/shared" "$state_home/state"
  printf 'done: implementation shipped\n' > "$state_home/state/ship-x.status"
  printf 'blocked: needs captain decision\n' >> "$state_home/state/ship-x.status"
  local receipt="$state_home/shared/wrap-receipt-v1.json"
  printf '{"session_id":"def456","note_id":"y"}' \
    | FM_HOME="$state_home" python3 "$SCRIPT" --receipt "$receipt" >/dev/null \
    || fail "default mode exited nonzero"
  local what_done what_flag
  what_done=$(jq -r '.[0].what_done' "$receipt") || fail "jq what_done failed"
  what_flag=$(jq -r '.[0].what_flag' "$receipt") || fail "jq what_flag failed"
  assert_contains "$what_done" "implementation shipped" \
    "default mode did not pick up done: line from state/*.status"
  assert_contains "$what_flag" "needs captain decision" \
    "default mode did not pick up blocked: line from state/*.status"
  pass "default mode auto-fills the 3-question surface from state/*.status"
}

test_invalid_label_rejected() {
  local receipt="$TMP_ROOT/invalid.json"
  local rc=0
  run_session_end --suggestion --label "nonsense" --receipt "$receipt" \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" = "1" ] || fail "expected rc=1 on invalid label, got $rc"
  [ ! -f "$receipt" ] || fail "invalid label should not have created a receipt"
  pass "off-schema --label is rejected and writes nothing"
}

test_help_exits_zero
test_suggestion_writes_receipt
test_suggestion_is_idempotent
test_suggestion_filters_by_note_id
test_default_mode_reads_stdin_and_writes_receipt
test_default_mode_auto_fills_from_state
test_invalid_label_rejected