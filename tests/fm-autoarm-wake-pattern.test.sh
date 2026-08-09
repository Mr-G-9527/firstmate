#!/usr/bin/env bash
# Cross-file invariant for the actionable wake-prefix regex shared by
# bin/fm-claude-stop-autoarm.sh and bin/fm-watch-arm.sh (the captain Stop
# auto-arm and its arm wrapper). Both scripts classify the same family of
# wake prefixes from the watcher's stdout; if the two patterns drift apart
# the actionable gate on one side and the reason classifier on the other
# will disagree, producing a "watcher auto-arm FAILED" notice for an
# actually-actionable wake (the failure mode the captain chased at
# 2026-08-09 ~23:00). This test pins the invariant: the constant must
# carry the same canonical value in both files AND must match the literal
# set of wake prefixes the watcher can emit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-autoarm-wake-pattern)
fm_git_identity fmtest fmtest@example.invalid

AUTOARM="$ROOT/bin/fm-claude-stop-autoarm.sh"
ARM="$ROOT/bin/fm-watch-arm.sh"

assert_present "$AUTOARM" "auto-arm script must exist"
assert_present "$ARM" "arm script must exist"

# 1. The shared constant must be defined in BOTH files with the same value.
# Anything else is the exact drift the captain reported.
test_wake_pattern_constant_is_shared() {
  local pattern_auto pattern_arm
  pattern_auto=$(grep -oE "^FM_AUTOARM_WAKE_PATTERN='[^']*'" "$AUTOARM" | head -1 || true)
  pattern_arm=$(grep -oE "^FM_AUTOARM_WAKE_PATTERN='[^']*'" "$ARM" | head -1 || true)
  [ -n "$pattern_auto" ] || fail "fm-claude-stop-autoarm.sh must define FM_AUTOARM_WAKE_PATTERN as a script-local constant"
  [ -n "$pattern_arm" ] || fail "fm-watch-arm.sh must define FM_AUTOARM_WAKE_PATTERN as a script-local constant"
  [ "$pattern_auto" = "$pattern_arm" ] \
    || fail "FM_AUTOARM_WAKE_PATTERN drifted between files: autoarm=$pattern_auto arm=$pattern_arm"
  pass "auto-arm: FM_AUTOARM_WAKE_PATTERN is identical in autoarm + watch-arm"
}

# 2. The pattern must match every wake prefix the watcher actually emits.
# Adding a new wake prefix in fm-watch.sh without extending this list (and
# updating the shared constant) would silently bypass the actionable gate,
# which is the same failure mode we are hardening against.
test_wake_pattern_matches_every_emitted_prefix() {
  local pattern tmpfile
  pattern=$(grep -oE "^FM_AUTOARM_WAKE_PATTERN='[^']*'" "$AUTOARM" | head -1 | sed -e "s/^FM_AUTOARM_WAKE_PATTERN='//" -e "s/'$//")
  [ -n "$pattern" ] || fail "could not extract FM_AUTOARM_WAKE_PATTERN"
  tmpfile=$(mktemp "$TMP_ROOT/wake-prefix.XXXXXX") || fail "mktemp failed"
  # Each line is a literal example from fm-watch.sh's wake call sites.
  cat > "$tmpfile" <<'WAKE'
signal: /home/captain/firstmate/state/foo.status
stale: firstmate:0
stale: firstmate:0 (paused 600s, awaiting external - declared pause, immediate surface so a live wait is not hidden behind the long cadence; confirm the wait still holds)
stale: firstmate:0 (idle 35s, possible wedge, escalation 2)
check: /home/captain/firstmate/state/x-watch.check.sh: merged status
check: process-event result captured: procevent:abc123
check: rejected unauthenticated state checks: /tmp/foo.check.sh
heartbeat
heartbeat: extra text
inbox-drain rc=0: dispatch paused: corr=demo seq=1 attempts=1/3
WAKE
  if ! grep -Eq "$pattern" "$tmpfile" 2>/dev/null; then
    fail "FM_AUTOARM_WAKE_PATTERN must match every emitted wake prefix; sample input:"
  fi
  rm -f "$tmpfile" 2>/dev/null || true
  pass "auto-arm: FM_AUTOARM_WAKE_PATTERN matches every emitted wake prefix"
}

# 3. The pattern must NOT match arm status lines (so a non-actionable close
# remains a typed failure rather than a false-positive rewake). Drift on
# this side would make the auto-arm re-claim a successful cycle as
# actionable and emit a redundant rewake banner while the synchronous
# guard was still mid-cycle.
test_wake_pattern_rejects_arm_status_lines() {
  local pattern tmpfile match_count
  pattern=$(grep -oE "^FM_AUTOARM_WAKE_PATTERN='[^']*'" "$AUTOARM" | head -1 | sed -e "s/^FM_AUTOARM_WAKE_PATTERN='//" -e "s/'$//")
  [ -n "$pattern" ] || fail "could not extract FM_AUTOARM_WAKE_PATTERN"
  tmpfile=$(mktemp "$TMP_ROOT/arm-status.XXXXXX") || fail "mktemp failed"
  cat > "$tmpfile" <<'ARM'
watcher: started pid=1234 (beacon fresh)
watcher: attached pid=1234 (beacon 2s)
watcher: FAILED - no live watcher with a fresh beacon
watcher: FAILED - cycle ended without an actionable reason
watcher: FAILED - watcher cycle exited 1 without an actionable reason
Terminated                 sleep "$POLL"
ARM
  match_count=$(grep -Ec "$pattern" "$tmpfile" 2>/dev/null || true)
  [ "$match_count" -eq 0 ] \
    || fail "FM_AUTOARM_WAKE_PATTERN must not match arm status lines, but it matched $match_count times"
  rm -f "$tmpfile" 2>/dev/null || true
  pass "auto-arm: FM_AUTOARM_WAKE_PATTERN rejects arm status / non-wake lines"
}

# 4. The pattern must tolerate a trailing newline and not require extra
# escaping (so a future refactor that grep -v or pipes the output cannot
# silently turn a positive match into a negative one). Cheap invariant
# smoke test: a single-line file whose only line is an emitted wake prefix.
test_wake_pattern_smoke_matches_single_line_files() {
  local pattern tmpfile needle
  pattern=$(grep -oE "^FM_AUTOARM_WAKE_PATTERN='[^']*'" "$AUTOARM" | head -1 | sed -e "s/^FM_AUTOARM_WAKE_PATTERN='//" -e "s/'$//")
  needle="inbox-drain rc=0: a single-line payload"
  tmpfile=$(mktemp "$TMP_ROOT/smoke.XXXXXX") || fail "mktemp failed"
  printf '%s\n' "$needle" > "$tmpfile"
  grep -Eq "$pattern" "$tmpfile" 2>/dev/null \
    || fail "FM_AUTOARM_WAKE_PATTERN must match a single newline-terminated line"
  rm -f "$tmpfile" 2>/dev/null || true
  pass "auto-arm: FM_AUTOARM_WAKE_PATTERN matches single newline-terminated files"
}

test_wake_pattern_constant_is_shared
test_wake_pattern_matches_every_emitted_prefix
test_wake_pattern_rejects_arm_status_lines
test_wake_pattern_smoke_matches_single_line_files
