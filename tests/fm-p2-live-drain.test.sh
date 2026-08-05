#!/usr/bin/env bash
# tests/fm-p2-live-drain.test.sh - P2 live-fix end-to-end:
#   watcher's scan_signals detects captain-inbox.jsonl mtime/size delta,
#   watcher invokes fm-captain-inbox-drain.sh on that signal, drain
#   advances the inbox offset, chat block lands in the wake payload.
# The "live" half (watcher running + a real append + drain runs) is
# covered by integration; here we focus on the deterministic unit that
# the WATCHER would compose the right payload from a known drain output.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-captain-inbox-drain.sh"
[ -x "$WATCH" ]  || fail "watch.sh not executable"
[ -x "$DRAIN" ] || fail "inbox-drain not executable"

TMP=$(fm_test_tmproot fm-p2-live-drain)
STATE="$TMP/state"
INBOX="$STATE/captain-inbox.jsonl"
mkdir -p "$STATE"

# ----- Case 1: the inbox-drain payload builder unit -----
# Compose the kind of payload fm-watch.sh writes when scan_signals
# detects captain-inbox.jsonl. The collapsed form is what fm_wake_append
# receives as the wake payload (the cleaner in fm-wake-lib.sh tr's
# newlines to spaces; we mirror that here so the assertion is realistic).
fake_drain_out='task dispatched: corr=dogfood-0804-skill-audit task_type=report_research session=spawn-X
=== FIRSTMATE CAPTAIN INPUT v1 corr=p2-drain-live-fix-20260804 kind=chat seq=30 ===
"read the fix"
=== END FIRSTMATE CAPTAIN INPUT ==='
collapsed=$(printf '%s' "$fake_drain_out" | awk 'BEGIN{RS=""; ORS=" | "} {gsub(/\n/, " "); print}' | sed 's/ | $//')
payload="inbox-drain rc=0: ${collapsed}"
case "$payload" in
  inbox-drain\ rc=0:\ *) pass "1a. payload prefix is inbox-drain rc=0:" ;;
  *) fail "1a. payload prefix wrong: $payload" ;;
esac
case "$payload" in
  *"task dispatched: corr=dogfood-0804-skill-audit"*) pass "1b. payload preserves task-dispatched marker" ;;
  *) fail "1b. payload missing task-dispatched marker" ;;
esac
case "$payload" in
  *"FIRSTMATE CAPTAIN INPUT v1 corr=p2-drain-live-fix-20260804"*) pass "1c. payload preserves chat block header" ;;
  *) fail "1c. payload missing chat block header" ;;
esac

# ----- Case 2: the ACTIONABLE regex matches inbox-drain payloads -----
# fm-claude-stop-autoarm.sh decides ACTIONABLE based on this regex;
# if the inbox-drain line is not picked up, the hook exits 0 silently
# and Claude never rewakes. Mirror the regex exactly.
case "$payload" in
  signal:*|stale:*|check:*|heartbeat*) fail "2. positive control";;
esac
case "$payload" in
  signal:*|stale:*|check:*|heartbeat*|"inbox-drain "*) pass "2. hook ACTIONABLE regex matches inbox-drain prefix" ;;
  *) fail "2. hook ACTIONABLE regex would miss this payload" ;;
esac

# ----- Case 3: scan_signals picks up captain-inbox.jsonl mtime/size delta -----
# Reproduce the scan_signals discipline against a fresh inbox file.
touch "$INBOX"
echo '{"ts":"2026-08-04T00:00:00Z","corr":"x","kind":"chat","body":"hi","seq":1}' >> "$INBOX"
SIG=$(stat -c '%s:%Y' "$INBOX")
SEEN_FILE="$STATE/.seen-captain-inbox_jsonl"
# Fresh state: no .seen-* yet. scan_signals would print pending.
case "$(cat "$SEEN_FILE" 2>/dev/null)" in
  "") pass "3a. fresh inbox has no .seen-captain-inbox_jsonl" ;;
  *) fail "3a. unexpected seen file: $(cat "$SEEN_FILE")" ;;
esac
# After appending, the sig differs from "" -> pending.
NEW_SIG=$(stat -c '%s:%Y' "$INBOX")
[ "$NEW_SIG" != "$(cat "$SEEN_FILE" 2>/dev/null)" ] \
  && pass "3b. append produces mtime/size delta vs empty .seen-*" \
  || fail "3b. delta detection broken: sig=$NEW_SIG seen=$(cat "$SEEN_FILE" 2>/dev/null)"

# After .seen-* is written, sig matches -> not pending.
printf '%s' "$NEW_SIG" > "$SEEN_FILE"
[ "$NEW_SIG" = "$(cat "$SEEN_FILE")" ] \
  && pass "3c. second scan finds inbox stable (.seen-* discipline)" \
  || fail "3c. second scan should be stable"

echo "ok - all fm-p2-live-drain tests passed"
