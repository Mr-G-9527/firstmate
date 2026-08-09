#!/usr/bin/env bash
# fm-task-done.test.sh - isolated tests for the per-task done outbox emit.
# Uses FM_ROOT_OVERRIDE to point at a temp dir; does not touch real state.
# Behavior covered (through the public interface, no source bytes):
#   1. fm-task-done.sh appends one row of kind=task-done with the canonical
#      "<task-id> done at <artifact path>" text and a non-empty seq.
#   2. A second call with the same corr and kind returns the existing row
#      and does not append a second one (idempotency on corr+kind).
#   3. --corr override wins over the default (= task-id) so a caller can
#      collapse multiple tasks into one row family.
#   4. --kind ship|scout passes through; --kind banana is rejected.
#   5. Missing or empty/non-data-dir artifact is rejected before any write.
#   6. bin/fm-captain-outbox-append.sh honors its new --idempotent flag
#      directly: two calls with the same (corr, kind) land one row.
#   7. bin/fm-review-submit.sh --task-id <id> --artifact <report> also
#      appends a per-task done row of kind=task-done for the same corr,
#      proving the auto-trigger wires the two helpers end-to-end.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_DONE="$SCRIPT_DIR/../bin/fm-task-done.sh"
OUTBOX_APPEND="$SCRIPT_DIR/../bin/fm-captain-outbox-append.sh"
REVIEW_SUBMIT="$SCRIPT_DIR/../bin/fm-review-submit.sh"

TMP="$(mktemp -d)"
mkdir -p "$TMP/state" "$TMP/data/task-001" "$TMP/data/task-002"
export FM_ROOT_OVERRIDE="$TMP"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
ko() { echo "FAIL: $1"; fail=$((fail+1)); }

OUTBOX="$TMP/state/captain-outbox.jsonl"
WT="$TMP/wt"
mkdir -p "$WT"
git -C "$WT" init -q -b main >/dev/null
git -C "$WT" config user.email "test@example.com"
git -C "$WT" config user.name "test"
touch "$WT/.gitkeep"
git -C "$WT" add -A
git -C "$WT" commit -q -m "init"

# 1. valid first call appends one task-done row with the canonical text.
echo "task report body" > "$TMP/data/task-001/report.md"
ROW1="$("$TASK_DONE" --task-id task-001 --artifact "$TMP/data/task-001/report.md")"
if echo "$ROW1" | jq -e '.kind=="task-done" and .state=="done" and .corr=="task-001" and .text=="task-001 done at '"$TMP/data/task-001/report.md"'" and (.seq|type=="number")' >/dev/null; then
  ok "valid first row shape"
else
  ko "valid first row shape: $ROW1"
fi
if [ "$(wc -l < "$OUTBOX")" = "1" ]; then ok "outbox has one row"; else ko "outbox row count (got $(wc -l < "$OUTBOX"))"; fi

# 2. second call with same corr+kind returns the existing row and skips append.
ROW2="$("$TASK_DONE" --task-id task-001 --artifact "$TMP/data/task-001/report.md")"
if [ "$ROW1" = "$ROW2" ]; then ok "idempotent same row"; else ko "idempotent returned different row: $ROW1 vs $ROW2"; fi
if [ "$(wc -l < "$OUTBOX")" = "1" ]; then ok "no second row on dup"; else ko "second row leaked (got $(wc -l < "$OUTBOX"))"; fi

# 3. --corr override changes corr while kind stays task-done.
ROW3="$("$TASK_DONE" --task-id task-001 --corr corr-other --artifact "$TMP/data/task-001/report.md")"
if echo "$ROW3" | jq -e '.corr=="corr-other" and .kind=="task-done"' >/dev/null; then
  ok "--corr override"
else
  ko "--corr override: $ROW3"
fi
# 3b. re-call with the overridden corr is idempotent on the new key.
ROW3B="$("$TASK_DONE" --task-id task-001 --corr corr-other --artifact "$TMP/data/task-001/report.md")"
if [ "$ROW3" = "$ROW3B" ]; then ok "--corr override idempotent"; else ko "--corr override idempotent failed"; fi

# 4. --kind scout passes through; --kind banana is rejected.
echo "scout report" > "$TMP/data/task-002/report.md"
ROW4="$("$TASK_DONE" --task-id task-002 --kind scout --artifact "$TMP/data/task-002/report.md")"
if echo "$ROW4" | jq -e '.kind=="task-done"' >/dev/null; then ok "scout kind accepted"; else ko "scout kind: $ROW4"; fi
if "$TASK_DONE" --task-id task-002 --kind banana --artifact "$TMP/data/task-002/report.md" 2>/dev/null; then
  ko "banana kind should be rejected"
else
  ok "banana kind rejected"
fi

# 5. missing / empty / outside-data artifact rejection.
if "$TASK_DONE" --task-id task-002 --artifact "$TMP/data/task-002/nope.md" 2>/dev/null; then
  ko "missing artifact should fail"
else
  ok "missing artifact rejected"
fi
: > "$TMP/data/task-002/empty.md"
if "$TASK_DONE" --task-id task-002 --artifact "$TMP/data/task-002/empty.md" 2>/dev/null; then
  ko "empty artifact should fail"
else
  ok "empty artifact rejected"
fi
echo "x" > "$TMP/outside.md"
if "$TASK_DONE" --task-id task-002 --artifact "$TMP/outside.md" 2>/dev/null; then
  ko "outside-data artifact should fail"
else
  ok "outside-data artifact rejected"
fi

# 6. fm-captain-outbox-append.sh honors --idempotent on its own.
DUP_ROW="$("$OUTBOX_APPEND" --idempotent --corr direct-corr --state 'done' --seq 0 --kind chat --text "first")"
DUP_ROW2="$("$OUTBOX_APPEND" --idempotent --corr direct-corr --state 'done' --seq 0 --kind chat --text "second")"
if [ "$DUP_ROW" = "$DUP_ROW2" ]; then ok "outbox --idempotent dedup"; else ko "outbox --idempotent did not dedup"; fi
# A different kind with the same corr must NOT dedup.
DISTINCT="$("$OUTBOX_APPEND" --idempotent --corr direct-corr --state 'done' --seq 0 --kind task-done --text "third")"
if [ "$DISTINCT" != "$DUP_ROW" ]; then ok "outbox --idempotent kind-scoped"; else ko "outbox --idempotent collapsed across kinds"; fi

# 7. fm-review-submit.sh --task-id auto-emits a per-task done row.
REPORT="$TMP/data/task-001/report.md"
# shellcheck disable=SC2034 # SUBM_ROW is asserted by way of outbox state changes below.
SUBM_ROW="$("$REVIEW_SUBMIT" --task-id task-001 --corr sub-corr --reply-to-seq 7 --artifact "$REPORT" --worktree "$WT")"
if [ "$(wc -l < "$OUTBOX")" -lt "3" ]; then ko "submit append failed (outbox lines=$(wc -l < "$OUTBOX"))"; else ok "submit row written"; fi
# The per-task done row should now be in the outbox with kind=task-done.
TASK_DONE_LINES="$(jq -c 'select(.kind=="task-done" and .corr=="sub-corr")' "$OUTBOX" 2>/dev/null | wc -l)"
if [ "$TASK_DONE_LINES" -ge "1" ]; then
  ok "submit auto-emitted per-task done row"
else
  ko "submit did not auto-emit per-task done row (outbox: $(cat "$OUTBOX"))"
fi

# 8. submit's auto-emit is itself idempotent: a second submit on the same
#    corr+kind task-done pair must not double the row.
# shellcheck disable=SC2034 # SUBM_ROW2 is asserted by way of outbox state changes below.
SUBM_ROW2="$("$REVIEW_SUBMIT" --task-id task-001 --corr sub-corr --reply-to-seq 7 --artifact "$REPORT" --worktree "$WT")"
TASK_DONE_LINES2="$(jq -c 'select(.kind=="task-done" and .corr=="sub-corr")' "$OUTBOX" 2>/dev/null | wc -l)"
if [ "$TASK_DONE_LINES" = "$TASK_DONE_LINES2" ]; then
  ok "submit auto-emit is idempotent on corr+kind"
else
  ko "submit auto-emit leaked (was $TASK_DONE_LINES, now $TASK_DONE_LINES2)"
fi

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = "0" ]
