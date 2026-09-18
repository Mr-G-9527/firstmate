#!/usr/bin/env bash
# tests/fm-research-dispatch-drain-worker-death.test.sh - regression test
# for the post-spawn worker-death detection + requeue path in
# bin/fm-research-dispatch-drain.sh.
#
# Bug observed 2026-08-25: a fresh-context research worker died after a
# successful spawn because MiniMax returned 529 before claude could
# produce any output. The drain script treated spawn success as
# terminal - the queue file was deleted, the executor meta still pointed
# at the dead window, and no retry mechanism requeued the task.
# Operators had to discover the death by inspecting worker.log (1 byte)
# and re-dispatch manually.
#
# Composition smoke: we exercise the real drain against a real queue
# file in the documented format and a real (but stubbed) spawn helper
# and death-check command. The test pins the full state machine:
# fresh spawn (queue gone, meta present), alive worker (skip), dead
# worker (requeue via <corr>.json.requeued, promote + spawn next round),
# artifact completion (meta gone), attempt budget, and the unchanged
# ov-0824-A spawn-failure evidence contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRAIN="$ROOT/bin/fm-research-dispatch-drain.sh"
[ -x "$DRAIN" ] || fail "fm-research-dispatch-drain.sh not executable"

TMP=$(fm_test_tmproot fm-research-dispatch-drain-worker-death)
mkdir -p "$TMP/state/research-dispatch-queue" "$TMP/data/executor-jobs" "$TMP/fakebin"

# Fake spawn helper. Mimics fm-research-worker-spawn.sh's durable
# footprint: writes the executor meta, the embedded-brief with the
# row JSON inside a fenced block, and a tiny worker.log. The drain's
# requeue path extracts the row JSON from the brief to rebuild the
# queue file.
cat > "$TMP/fakebin/spawn-helper" <<'SH'
#!/usr/bin/env bash
# fm-research-dispatch-drain-worker-death fake spawn helper.
corr="${1:?corr required}"
row_json="${2:?row_json required}"
project_dir="${3:?project_dir required}"
meta_dir="${FM_FAKE_META_DIR:?meta dir required}"
art_dir="${FM_FAKE_ARTIFACT_DIR:?artifact dir required}"
meta_file="$meta_dir/$corr.meta"
brief_file="$meta_dir/$corr.brief.md"

# Skip when meta already exists (idempotency, mirroring the real helper).
if [ -f "$meta_file" ]; then
  cat "$meta_file"
  exit 0
fi

# Optionally fail BEFORE writing any durable artifact, so the drain's
# spawn-failure retry path exercises the no-meta contract.
if [ "${FM_FAKE_SPAWN_FAIL:-0}" = "1" ]; then
  printf 'fake spawn failure corr=%s\n' "$corr" >&2
  exit 19
fi

window_target="${FM_FAKE_WINDOW_TARGET:-@99}"
artifact_subpath="${FM_FAKE_ARTIFACT_SUBPATH:-$corr}"
artifact_path="$art_dir/$artifact_subpath/report.md"

# Brief with the row JSON embedded in a fenced json block - matches
# the format bin/fm-research-worker-spawn.sh writes so the drain's
# row extractor picks it up.
mkdir -p "$meta_dir"
cat > "$brief_file" <<BRIEF
# Research Task: $corr
## Row (verbatim, from controller)
\`\`\`json
$row_json
\`\`\`
BRIEF

cat > "$meta_file" <<META
corr=$corr
session_id=fake-uuid
window=$window_target
task_id=executor-$corr-0
started_at=2026-08-26T00:00:00Z
task_type=report_research
brief=$brief_file
revision_seq=
revision_of=
artifact=$artifact_path
META

# Fake worker.log: pretend the launch happened but claude produced no
# output before the api crashed. The drain's requeue path renames it
# to .worker.last.err so the death evidence survives.
worker_log="$meta_dir/$corr.worker.log"
printf 'fake-launch shell line\n' > "$worker_log"

# Optionally pre-create the artifact to simulate worker success.
if [ "${FM_FAKE_ARTIFACT_PRESENT:-0}" = "1" ]; then
  mkdir -p "$(dirname "$artifact_path")"
  printf '# report %s\n' "$corr" > "$artifact_path"
fi

printf 'fake-spawn-success corr=%s window=%s\n' "$corr" "$window_target"
SH
chmod +x "$TMP/fakebin/spawn-helper"

# Fake death-check command. Prints `alive` if FM_FAKE_DEATH_VERDICT=alive,
# anything else (default `dead`) triggers requeue. Mirrors the stdout
# contract of fm_backend_tmux_agent_state.
cat > "$TMP/fakebin/death-check" <<'SH'
#!/usr/bin/env bash
# fm-research-dispatch-drain-worker-death fake death verifier.
verdict="${FM_FAKE_DEATH_VERDICT:-dead}"
printf '%s\n' "$verdict"
SH
chmod +x "$TMP/fakebin/death-check"

# Single fake state tree shared across cases for isolation.
CASE="$TMP/case"
mkdir -p "$CASE/state/research-dispatch-queue" "$CASE/data/executor-jobs" "$CASE/fakebin"
cp "$TMP/fakebin/spawn-helper" "$CASE/fakebin/spawn-helper"
cp "$TMP/fakebin/death-check" "$CASE/fakebin/death-check"
export FM_HOME="$CASE"
export FM_ROOT_OVERRIDE="$CASE"
export STATE="$CASE/state"
export FM_EXECUTOR_JOBS_DIR="$CASE/data/executor-jobs"
export FM_RESEARCH_WORKER_SPAWN="$CASE/fakebin/spawn-helper"
export FM_RESEARCH_DEATH_CHECK_CMD="$CASE/fakebin/death-check"
# Pin the clock: fake metas use started_at=2026-08-26T00:00:00Z. Without a
# pinned NOW the wall clock (>48h later) makes the E1 guard archive them
# before the death check runs, silently defeating this regression. 12h age is
# inside the 48h E1 window and past the 5m startup grace, so the
# dead->requeue expectations below still hold.
export FM_E1_GUARD_NOW="2026-08-26T12:00:00Z"
export FM_FAKE_META_DIR="$CASE/data/executor-jobs"
export FM_FAKE_ARTIFACT_DIR="$CASE/data"

# Helper: build a queue file the way fm-captain-inbox-drain.sh does.
seed_queue() {  # <corr> <seq>
  local corr=$1 seq=$2
  local row
  row=$(printf '{"ts":"2026-08-26T00:00:00Z","corr":"%s","kind":"chat","task_type":"report_research","body":"captain brief","seq":%s}' "$corr" "$seq")
  jq -cn --arg corr "$corr" --argjson seq "$seq" --arg project_dir "$CASE" \
    --arg revision_seq "" --argjson row "$row" \
    '{corr:$corr,seq:$seq,revision_seq:$revision_seq,project_dir:$project_dir,attempts:0,row:$row}' \
    > "$CASE/state/research-dispatch-queue/$corr.json" \
    || fail "could not seed queue file for $corr"
}

# Reset shared per-case state between scenarios so attempts / verdict
# leaks don't poison the next assertion.
reset_case() {
  rm -rf "$CASE/state/research-dispatch-queue"
  rm -rf "$CASE/data/executor-jobs"
  mkdir -p "$CASE/state/research-dispatch-queue" "$CASE/data/executor-jobs"
}

# ----- Case 1: fresh spawn deletes the queue file and writes the meta ----
# The success-path semantic (queue file gone) is unchanged from main;
# the new meta is the in-flight receipt the next drain reconciles.
reset_case
CORR="death-fresh-$RANDOM"
seed_queue "$CORR" 101
unset FM_FAKE_DEATH_VERDICT FM_FAKE_ARTIFACT_PRESENT FM_FAKE_SPAWN_FAIL FM_FAKE_WINDOW_TARGET
export FM_FAKE_WINDOW_TARGET="@10"
OUT=$("$DRAIN" 2>&1) || true
grep -q "dispatch complete: corr=$CORR seq=101" <<<"$OUT" \
  || fail "fresh spawn should print complete line: $OUT"
[ ! -f "$CASE/state/research-dispatch-queue/$CORR.json" ] \
  || fail "fresh spawn must delete the queue file (existing success-path contract)"
[ -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "fresh spawn must leave the executor meta as the in-flight receipt"
[ -f "$CASE/data/executor-jobs/$CORR.worker.log" ] \
  || fail "fresh spawn must leave the worker.log from the launch"
pass "1. fresh spawn keeps the success-path semantic and writes the in-flight meta"

# ----- Case 2: alive worker drains silently with no state change -----
reset_case
CORR="death-alive-$RANDOM"
seed_queue "$CORR" 102
export FM_FAKE_WINDOW_TARGET="@20"
"$DRAIN" >/dev/null 2>&1 || true
[ -f "$CASE/state/research-dispatch-queue/$CORR.json" ] \
  && fail "case 2 precondition: queue file should be gone after spawn"
export FM_FAKE_DEATH_VERDICT=alive
OUT=$("$DRAIN" 2>&1) || true
grep -q "dispatch in-flight: corr=$CORR window=@20" <<<"$OUT" \
  || fail "alive worker must print in-flight line: $OUT"
[ -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "alive worker must keep the executor meta"
pass "2. alive worker is skipped without state change"

# ----- Case 3: dead worker triggers requeue + immediate respawn -----
# Same-drain respawn is intentional: the drain detects the death,
# rebuilds the queue file as <corr>.json.requeued, promotes it back to
# <corr>.json in the same drain, and re-spawns so the worker can
# recover without waiting for the next minute boundary. The pre-pass
# drops the dead meta before the respawn helper writes a new one.
reset_case
CORR="death-dead-$RANDOM"
seed_queue "$CORR" 103
export FM_FAKE_WINDOW_TARGET="@30"
"$DRAIN" >/dev/null 2>&1 || true
# Force a recognisable tail on worker.log so we can prove the evidence
# is the actual death-context bytes, not a stray empty file.
printf 'final-claude-line: api error 529 overloaded\n' \
  >> "$CASE/data/executor-jobs/$CORR.worker.log"
export FM_FAKE_DEATH_VERDICT=dead
OUT=$("$DRAIN" 2>&1) || true
grep -q "dispatch worker death: corr=$CORR window=@30 liveness=dead" <<<"$OUT" \
  || fail "dead worker must surface death verdict in stderr: $OUT"
grep -q "dispatch requeue attempt=1/3 corr=$CORR evidence=" <<<"$OUT" \
  || fail "dead worker must print requeue line with evidence path: $OUT"
grep -q "dispatch complete: corr=$CORR seq=0" <<<"$OUT" \
  || fail "drain must respawn in the same round (no minute boundary wait): $OUT"
[ -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "respawned worker must have a fresh meta (in-flight receipt)"
attempts_in_meta=$(awk -F= '/^attempts=/{print $2; exit}' "$CASE/data/executor-jobs/$CORR.meta")
[ "$attempts_in_meta" = "1" ] \
  || fail "fresh meta must carry the attempts bridge from the requeued file, got $attempts_in_meta"
[ ! -f "$CASE/state/research-dispatch-queue/$CORR.json" ] \
  || fail "dead-worker round must end with no pending queue file"
[ ! -f "$CASE/state/research-dispatch-queue/$CORR.json.requeued" ] \
  || fail "dead-worker round must consume the .requeued file in the same drain"
[ -f "$CASE/data/executor-jobs/$CORR.worker.last.err" ] \
  || fail "dead-worker round must leave .worker.last.err behind as evidence"
grep -q "final-claude-line: api error 529 overloaded" \
  "$CASE/data/executor-jobs/$CORR.worker.last.err" \
  || fail "evidence file must preserve the worker.log tail: $(cat "$CASE/data/executor-jobs/$CORR.worker.last.err")"
pass "3. dead worker triggers requeue + immediate respawn in the same drain, .worker.last.err preserved"

# ----- Case 5: artifact present short-circuits to completion ---------
# Even with a death verdict, an artifact present means the worker
# died AFTER submitting its report - do not mistakenly requeue.
reset_case
CORR="death-done-$RANDOM"
seed_queue "$CORR" 105
export FM_FAKE_WINDOW_TARGET="@50"
export FM_FAKE_ARTIFACT_PRESENT=1
"$DRAIN" >/dev/null 2>&1 || true
unset FM_FAKE_ARTIFACT_PRESENT
export FM_FAKE_DEATH_VERDICT=dead
OUT=$("$DRAIN" 2>&1) || true
grep -q "dispatch complete: corr=$CORR (artifact present)" <<<"$OUT" \
  || fail "completed worker must print artifact-present completion line: $OUT"
[ ! -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "completed worker must delete executor meta"
[ -f "$CASE/state/research-dispatch-queue/$CORR.json" ] \
  && fail "completed worker must not rebuild a queue file"
[ -f "$CASE/state/research-dispatch-queue/$CORR.json.requeued" ] \
  && fail "completed worker must not write a .requeued file"
pass "5. artifact present short-circuits to completion regardless of liveness"

# ----- Case 6: budget exhausted after repeated death requeues -----
# Same-drain respawn means one drain call performs one death requeue:
# the pre-pass drops the meta, writes <corr>.json.requeued with the
# incremented attempts, then the main loop promotes and re-spawns.
# Three death drains cross the budget of 3 attempts; the fourth drain
# must short-circuit with `dispatch paused` without re-running the
# death verifier or moving the evidence file.
reset_case
CORR="death-budget-$RANDOM"
seed_queue "$CORR" 106
export FM_FAKE_WINDOW_TARGET="@60"
# First drain: fresh spawn (queue gone, meta present, attempts unset).
"$DRAIN" >/dev/null 2>&1 || true
[ -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "initial spawn must write meta"
export FM_FAKE_DEATH_VERDICT=dead
for expected in 1 2; do
  # Death drain: detect death, write .requeued, promote, respawn.
  OUT=$("$DRAIN" 2>&1) || true
  grep -q "dispatch requeue attempt=$expected/3 corr=$CORR evidence=" <<<"$OUT" \
    || fail "death round $expected must surface attempts=$expected/3: $OUT"
  attempts_in_meta=$(awk -F= '/^attempts=/{print $2; exit}' "$CASE/data/executor-jobs/$CORR.meta")
  [ "$attempts_in_meta" = "$expected" ] \
    || fail "death round $expected: meta attempts bridge should be $expected, got $attempts_in_meta"
  [ ! -f "$CASE/state/research-dispatch-queue/$CORR.json.requeued" ] \
    || fail "death round $expected: .requeued must be consumed in the same drain"
done
# Third death drain: requeue brings attempts to 3 (the budget). The
# requeued queue file is left behind (the main loop then hits the
# queue-budget guard), and the meta is dropped because nothing was
# respawned.
OUT=$("$DRAIN" 2>&1) || true
grep -q "dispatch requeue attempt=3/3 corr=$CORR evidence=" <<<"$OUT" \
  || fail "third death drain must still print requeue line: $OUT"
grep -q "dispatch paused: corr=$CORR seq=0 attempts=3/3" <<<"$OUT" \
  || fail "third death drain must surface the queue-budget paused line: $OUT"
[ ! -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "after third death, meta must be dropped (no respawn past budget)"
attempts_in_queue=$(jq -r '.attempts' "$CASE/state/research-dispatch-queue/$CORR.json")
[ "$attempts_in_queue" = "3" ] \
  || fail "after third death, queue file attempts should be 3, got $attempts_in_queue"
# Post-budget drain: queue file with attempts=3 hits the main loop's
# budget guard. The pre-pass has no meta to scan (already dropped), so
# the death verifier is NOT re-invoked and the evidence file's mtime
# stays put.
evidence_mtime_before=$(stat -c %Y "$CASE/data/executor-jobs/$CORR.worker.last.err")
sleep 1
OUT=$("$DRAIN" 2>&1) || true
grep -q "dispatch paused: corr=$CORR seq=0 attempts=3/3" <<<"$OUT" \
  || fail "post-budget drain must short-circuit with paused line: $OUT"
evidence_mtime_after=$(stat -c %Y "$CASE/data/executor-jobs/$CORR.worker.last.err")
[ "$evidence_mtime_before" = "$evidence_mtime_after" ] \
  || fail "post-budget drain must NOT re-run the death verifier (mtime changed)"
pass "6. three death cycles hit the requeue budget, next drain pauses without re-running the verifier"

# ----- Case 7: spawn failure path is unchanged ------------------------
# The 2026-08-24 failure-evidence contract (ov-0824-A) still holds:
# a failing spawn helper writes <queue>.spawn.last.err and increments
# attempts without dropping the queue file. This is regression coverage
# to prove the new pre-pass did not break the existing failure path.
reset_case
CORR="death-spawn-fail-$RANDOM"
seed_queue "$CORR" 107
export FM_FAKE_SPAWN_FAIL=1
OUT=$("$DRAIN" 2>&1) || true
grep -q "dispatch retry pending: corr=$CORR seq=107 attempt=1/3" <<<"$OUT" \
  || fail "spawn-failure retry line missing: $OUT"
[ -f "$CASE/state/research-dispatch-queue/$CORR.json.spawn.last.err" ] \
  || fail "spawn-failure evidence file must exist (ov-0824-A contract)"
[ -f "$CASE/state/research-dispatch-queue/$CORR.json" ] \
  || fail "spawn-failure must preserve queue file for retry"
[ ! -f "$CASE/data/executor-jobs/$CORR.meta" ] \
  || fail "spawn-failure must NOT write a meta file"
pass "7. spawn-failure path keeps the ov-0824-A evidence contract and does not write a meta"

echo "ok - fm-research-dispatch-drain worker-death regression passed"