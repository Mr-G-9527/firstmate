#!/usr/bin/env bash
# fm-review-submit.test.sh - isolated tests for the submission helper.
# Uses FM_ROOT_OVERRIDE to point at a temp dir; does not touch real state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../bin/fm-review-submit.sh"
INBOX_APPEND="$SCRIPT_DIR/../bin/fm-captain-inbox-append.sh"

TMP="$(mktemp -d)"
mkdir -p "$TMP/state" "$TMP/data/job-001" "$TMP/data/job-002"
export FM_ROOT_OVERRIDE="$TMP"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
ko() { echo "FAIL: $1"; fail=$((fail+1)); }

# 1. valid row
echo "real report content here" > "$TMP/data/job-001/report.md"
ROW="$("$HELPER" --corr job-001 --reply-to-seq 5 --artifact "$TMP/data/job-001/report.md")"
if echo "$ROW" | jq -e '.kind=="report-submission" and .state=="done" and .seq==5 and (.artifact_sha256|length==64) and (.submission_id|startswith("sub_"))' >/dev/null; then ok "valid row"; else ko "valid row: $ROW"; fi

OUTBOX="$TMP/state/captain-outbox.jsonl"
if [ "$(wc -l < "$OUTBOX")" = "1" ]; then ok "outbox one row"; else ko "outbox one row (got $(wc -l < "$OUTBOX"))"; fi

# 2. missing file
if "$HELPER" --corr job-001 --reply-to-seq 6 --artifact "$TMP/data/job-001/nope.md" 2>/dev/null; then ko "missing file should fail"; else ok "missing file rejected"; fi

# 3. outside-data path rejected
echo "x" > "$TMP/outside.md"
if "$HELPER" --corr job-001 --reply-to-seq 7 --artifact "$TMP/outside.md" 2>/dev/null; then ko "outside-data should fail"; else ok "outside-data rejected"; fi

# 4. .env* rejected
echo "secret" > "$TMP/data/job-001/.env"
if "$HELPER" --corr job-001 --reply-to-seq 8 --artifact "$TMP/data/job-001/.env" 2>/dev/null; then ko ".env should fail"; else ok ".env rejected"; fi

# 5. duplicate corr+seq+hash idempotent (same row returned, no second outbox line)
ROW2="$("$HELPER" --corr job-001 --reply-to-seq 5 --artifact "$TMP/data/job-001/report.md")"
if [ "$ROW" = "$ROW2" ]; then ok "dup idempotent (same row)"; else ko "dup idempotent"; fi
if [ "$(wc -l < "$OUTBOX")" = "1" ]; then ok "no second row on dup"; else ko "no second row on dup (got $(wc -l < "$OUTBOX"))"; fi

# 6. revised submission (different seq) appends a second row
echo "revised report content" > "$TMP/data/job-001/report.md"
ROW3="$("$HELPER" --corr job-001 --reply-to-seq 9 --artifact "$TMP/data/job-001/report.md")"
if [ "$(wc -l < "$OUTBOX")" = "2" ]; then ok "revised submission appends"; else ko "revised appends (got $(wc -l < "$OUTBOX"))"; fi
if echo "$ROW3" | jq -e '.seq==9' >/dev/null; then ok "revised seq is 9"; else ko "revised seq"; fi

# 7. inbox --json output
JOUT="$("$INBOX_APPEND" --kind chat --corr test-corr --json <<< "hello body")"
if echo "$JOUT" | jq -e '.corr=="test-corr" and .kind=="chat" and (.seq|type=="number")' >/dev/null; then ok "inbox --json"; else ko "inbox --json: $JOUT"; fi

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = "0" ]
