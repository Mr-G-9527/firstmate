#!/usr/bin/env bash
# Regression: controller revision feedback must resume a report_research worker,
# never depend on the primary REPL draining a generic chat message.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
APPEND="$ROOT/bin/fm-captain-inbox-append.sh"
DRAIN="$ROOT/bin/fm-captain-inbox-drain.sh"
TMP=$(fm_test_tmproot fm-research-feedback-revision)
mkdir -p "$TMP/state" "$TMP/data/executor-jobs" "$TMP/fakebin"
cat > "$TMP/fakebin/spawn" <<'SH'
#!/usr/bin/env bash
printf 'revision=%s corr=%s\n' "${FM_RESEARCH_WORKER_REVISION_SEQ:-}" "$1" >> "${FM_FAKE_SPAWN_LOG:?}"
printf 'session_id=revision-session\n'
SH
chmod +x "$TMP/fakebin/spawn"
CORR="feedback-revision-$RANDOM"
printf 'corr=%s\nsession_id=original\nbrief=%s/data/executor-jobs/%s.brief.md\n' "$CORR" "$TMP" "$CORR" > "$TMP/data/executor-jobs/$CORR.meta"
printf '# original brief\n' > "$TMP/data/executor-jobs/$CORR.brief.md"
printf '[fm cross-model review]\nRequired: revise Q1.\n' | \
  FM_HOME="$TMP" FM_ROOT_OVERRIDE="$TMP" "$APPEND" --kind chat --corr "$CORR" --json >/dev/null \
  || fail "feedback append failed"
OUT=$(FM_HOME="$TMP" FM_ROOT_OVERRIDE="$TMP" FM_RESEARCH_WORKER_SPAWN="$TMP/fakebin/spawn" FM_FAKE_SPAWN_LOG="$TMP/spawn.log" "$DRAIN" 2>&1) \
  || fail "feedback drain failed: $OUT"
grep -E '^revision=[0-9]+ corr='"$CORR"'$' "$TMP/spawn.log" >/dev/null \
  || fail "feedback did not spawn a revision worker: $OUT"
case "$OUT" in *"FIRSTMATE CAPTAIN INPUT v1 corr=$CORR"*) fail "feedback leaked into the primary REPL: $OUT" ;; esac
pass "review feedback routes to a revision worker, not the primary REPL"
echo "ok - fm research feedback revision regression passed"
