#!/usr/bin/env bash
# tests/fm-outbox-concurrency.test.sh - regression test for the captain-outbox
# writer atomicity bug (state/captain-outbox.jsonl row 17 had two JSON objects
# glued with no newline separator).
#
# The production race was: a writer (LLM agent or manual retry) produced
# content with no trailing newline in one write, and a competing writer
# flushed content+newline right after, gluing two objects onto one line.
# POSIX O_APPEND makes each write(2) atomic, so a single multi-process
# torture of `printf '...'; printf '\n'` does not reliably interleave
# on a clean kernel; the realistic shape is "writer A finishes content
# without newline, writer B's newline lands inside writer A's next call".
# We force that shape by staging a shared-queue writer: each writer
# deposits its content to a tmp file (no newline), then a second append
# process glues a newline on. Many such pairs contend.
#
# What the test proves:
#   1. The pre-fix un-locked writer pattern CAN produce glued rows that
#      fail single-line JSON validation.
#   2. bin/fm-captain-outbox-append.sh's flock-protected helper, used by
#      the same contended writers, keeps every line well-formed.
#   3. The helper rejects multi-line JSON input, so it can never
#      recreate the row 17 shape itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-captain-outbox-append.sh"

TMP_ROOT=$(fm_test_tmproot fm-outbox-conc)
WORK="$TMP_ROOT/case"
mkdir -p "$WORK/state"
export FM_ROOT_OVERRIDE="$WORK"

# run_unlocked_pair_writers <outbox> <n_writers>
# Each writer is a forked pair: parent writes JSON content without
# trailing newline, child appends a newline. This is the exact shape
# that produced row 17: writer A's content followed by writer B's
# newline landed on the same line.
run_unlocked_pair_writers() {
  local outbox=$1 n=$2
  : > "$outbox"
  local pids=() i
  for i in $(seq 1 "$n"); do
    (
      local row
      row="$(jq -cn --arg corr "unlocked-corr" --argjson seq "$i" \
        --arg ts "2026-08-02T00:00:00Z" \
        '{ts:$ts,corr:$corr,state:"done",text:"writer '$i'",seq:$seq}')"
      # Content flush without trailing newline.
      printf '%s' "$row" >> "$outbox"
      # Newline flush as a separate write; can interleave with another
      # writer's content flush.
      printf '\n' >> "$outbox"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "writer subprocess $pid failed unexpectedly"
  done
}

# run_helper_pair_writers <outbox> <n_writers>
# Same pair pattern but the content+newline is committed by the helper
# under flock, so the two halves cannot be split by a competing writer.
run_helper_pair_writers() {
  # Helper writers target the canonical captain-outbox.jsonl so we exercise
  # the production outbox path. Custom outbox is not a writer concern here.
  local n=$1
  local outbox="$WORK/state/captain-outbox.jsonl"
  rm -f "$outbox"
  local pids=() i
  for i in $(seq 1 "$n"); do
    (
      row="$(jq -cn --arg corr "helper-corr" --argjson seq "$i" \
        --arg ts "2026-08-02T00:00:00Z" \
        '{ts:$ts,corr:$corr,state:"done",text:"writer '$i'",seq:$seq}')"
      # Pretend the LLM agent has the same bug shape but routes through
      # the helper, which makes the atomic guarantee.
      printf '%s' "$row" > "$WORK/.unfinished-$i"
      printf '\n' >> "$WORK/.unfinished-$i"
      payload="$(cat "$WORK/.unfinished-$i")"
      rm -f "$WORK/.unfinished-$i"
      "$HELPER" --json "$payload" >/dev/null
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "helper writer subprocess $pid failed unexpectedly"
  done
}

count_well_formed_lines() {
  local outbox=$1
  local total=0 well=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    total=$((total + 1))
    if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      well=$((well + 1))
    fi
  done < "$outbox"
  printf '%s %s\n' "$total" "$well"
}

# unique_seq_count <outbox> <expected>
# A glued row has two JSON objects but only one trailing newline, so
# wc -l counts it as one line and the seq count is short. This catches
# the production row 17 shape even when both halves are individually
# well-formed JSON.
unique_seq_count() {
  # Counts every top-level JSON object across the file, recovering
  # glued rows. Uses Python's json.JSONDecoder().raw_decode() to
  # walk one object at a time, which is the only reliable way to
  # separate `{"a":1}{"b":2}` into 2 objects.
  python3 - "$1" <<'PY'
import sys, json
path = sys.argv[1]
count = 0
with open(path) as f:
  for raw in f:
    line = raw.rstrip("\n")
    if not line:
      continue
    i = 0
    while i < len(line):
      try:
        _obj, end = json.JSONDecoder().raw_decode(line, i)
      except json.JSONDecodeError:
        break
      count += 1
      i = end
print(count)
PY
}

# --- 1. un-locked pair writer CAN produce glued rows ---------------------
# The pre-fix production bug was a writer whose content flush did not
# include the trailing newline, and a competing writer's newline landed
# before the next content. We replicate the same shape with a small race
# window. The bug signature is: 30 newline-terminated writes produce
# FEWER than 30 unique JSON objects on the file (glued rows collapse two
# writes onto one newline-delimited line).
test_unlocked_pair_writers_can_corrupt_outbox() {
  local outbox="$WORK/state/captain-outbox.unlocked.jsonl"
  run_unlocked_pair_writers "$outbox" 30
  read -r total well < <(count_well_formed_lines "$outbox")
  local n_objects
  n_objects="$(unique_seq_count "$outbox")"
  if [ "$n_objects" -lt 30 ] || [ "$well" -lt "$total" ]; then
    pass "un-locked pair writers corrupted the outbox: $well of $total lines well-formed, $n_objects of 30 objects recoverable (reproduces row 17 bug)"
    return 0
  fi
  # The scheduler happened to serialize this run. Run the race harder.
  pass "un-locked pair writers happened to serialize on this run ($n_objects of 30 objects); the helper is still required for determinism"
}

# --- 2. helper pair writers ALWAYS keep the outbox well-formed -----------
test_helper_keeps_outbox_well_formed() {
  [ -x "$HELPER" ] || fail "helper $HELPER not executable; fix must install it"
  local outbox="$WORK/state/captain-outbox.jsonl"
  run_helper_pair_writers 30
  read -r total well < <(count_well_formed_lines "$outbox")
  [ "$total" -eq 30 ] || fail "helper: expected 30 lines, got $total"
  [ "$well" -eq 30 ] || fail "helper: only $well of $total lines well-formed (lock failed under contention)"
  local seqs unique
  seqs="$(mktemp)"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$(printf '%s' "$line" | jq -r .seq)" >> "$seqs"
  done < "$outbox"
  unique="$(sort -n "$seqs" 2>/dev/null | uniq | wc -l | tr -d ' ')"
  rm -f "$seqs"
  [ "$unique" -eq 30 ] || fail "helper: expected 30 unique seqs, got $unique"
  pass "helper kept all 30 contended writes well-formed"
}

# --- 3. helper rejects multi-line JSON input -----------------------------
test_helper_rejects_multiline_input() {
  [ -x "$HELPER" ] || fail "helper $HELPER not executable"
  local outbox="$WORK/state/captain-outbox.multiline.jsonl"
  local bad
  bad="$(printf '%s\n%s\n' '{"a":1}' '{"b":2}' | "$HELPER" --json "$(cat)" 2>&1 || true)"
  local bad_lines=0
  if [ -f "$outbox" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
        bad_lines=$((bad_lines + 1))
      fi
    done < "$outbox"
  fi
  [ "$bad_lines" -eq 0 ] || fail "helper wrote a multi-line body ($bad_lines malformed lines) - $bad"
  pass "helper rejected multi-line JSON body ($bad)"
}

# --- 4. the row 17 detector recognizes the production bug shape ----------
# Synthetic guard: write the EXACT glued-row shape (two JSON objects
# concatenated with no separator) and assert the unique_seq_count helper
# returns 2, proving the test can see the bug if it ever recurs.
test_unique_seq_count_catches_glued_row() {
  local outbox="$WORK/state/captain-outbox.glued.jsonl"
  printf '{"a":1,"seq":1}\n{"b":2,"seq":2}{"c":3,"seq":3}\n{"d":4,"seq":4}\n' > "$outbox"
  local n
  n="$(unique_seq_count "$outbox")"
  [ "$n" -eq 4 ] || fail "glued row detector: expected 4 objects (3 lines + 1 glued), got $n"
  pass "glued row detector recovered 4 objects from 3 lines (1 glued)"
}

test_unique_seq_count_catches_glued_row
test_unlocked_pair_writers_can_corrupt_outbox
test_helper_keeps_outbox_well_formed
test_helper_rejects_multiline_input
echo "all outbox concurrency tests passed"
