#!/usr/bin/env bash
# tests/fm-research-dispatch-drain-death-check-hold.test.sh
# Clock-pinned regression for the death-check HOLD semantics in
# bin/fm-research-dispatch-drain.sh. Complements the worker-death test by
# pinning FM_E1_GUARD_NOW so the fake metas (started_at=2026-08-26T00:00:00Z)
# stay inside the 48h E1 window and actually reach the death check.
#
# Pins the new contract:
#   1. verdict 'unreadable' (transient tmux read) -> HOLD, never requeue.
#      The verifier's contract: only a confident negative licenses a re-spawn.
#   2. verdict 'dead' within the startup grace window -> HOLD (slow start:
#      headless 'claude -p' runs as a child of the pane's persistent shell,
#      so the pane is shell-only until claude attaches).
#   3. verdict 'dead' past the grace window -> requeue (unchanged behavior).
#   4. verdict 'alive' -> in-flight (unchanged).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRAIN="$ROOT/bin/fm-research-dispatch-drain.sh"
[ -x "$DRAIN" ] || { echo "not ok - drain not executable"; exit 1; }

pass(){ echo "ok - $1"; }
fail(){ echo "not ok - $1"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CASE="$TMP/case"
mkdir -p "$CASE/state/research-dispatch-queue" "$CASE/data/executor-jobs" "$CASE/fakebin"

# Fake spawn helper: writes the executor meta (fixed started_at) + brief with
# the row JSON embedded in a fenced block (the shape the real helper writes).
cat > "$CASE/fakebin/spawn-helper" <<'SH'
#!/usr/bin/env bash
corr="${1:?}"; row_json="${2:?}"; project_dir="${3:?}"
meta_dir="${FM_FAKE_META_DIR:?}"; art_dir="${FM_FAKE_ARTIFACT_DIR:?}"
meta_file="$meta_dir/$corr.meta"; brief_file="$meta_dir/$corr.brief.md"
if [ -f "$meta_file" ]; then cat "$meta_file"; exit 0; fi
window_target="${FM_FAKE_WINDOW_TARGET:-@99}"
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
artifact=$art_dir/$corr/report.md
META
printf 'fake-launch\n' > "$meta_dir/$corr.worker.log"
printf 'fake-spawn-success corr=%s\n' "$corr"
SH
chmod +x "$CASE/fakebin/spawn-helper"

# Fake death-check: echoes FM_FAKE_DEATH_VERDICT (mirrors the stdout contract).
cat > "$CASE/fakebin/death-check" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_DEATH_VERDICT:-dead}"
SH
chmod +x "$CASE/fakebin/death-check"

export FM_HOME="$CASE" FM_ROOT_OVERRIDE="$CASE" STATE="$CASE/state"
export FM_EXECUTOR_JOBS_DIR="$CASE/data/executor-jobs"
export FM_RESEARCH_DISPATCH_QUEUE_DIR="$CASE/state/research-dispatch-queue"
export FM_RESEARCH_WORKER_SPAWN="$CASE/fakebin/spawn-helper"
export FM_RESEARCH_DEATH_CHECK_CMD="$CASE/fakebin/death-check"
export FM_FAKE_META_DIR="$CASE/data/executor-jobs"
export FM_FAKE_ARTIFACT_DIR="$CASE/data"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP/archive"

seed_queue(){ # <corr> <seq>
  local corr=$1 seq=$2 row
  row=$(printf '{"ts":"2026-08-26T00:00:00Z","corr":"%s","kind":"chat","task_type":"report_research","body":"b","seq":%s}' "$corr" "$seq")
  jq -cn --arg corr "$corr" --argjson seq "$seq" --arg project_dir "$CASE" --arg revision_seq "" --argjson row "$row" \
    '{corr:$corr,seq:$seq,revision_seq:$revision_seq,project_dir:$project_dir,attempts:0,row:$row}' \
    > "$CASE/state/research-dispatch-queue/$corr.json" || fail "seed $corr"
}
reset_case(){
  rm -rf "$CASE/state/research-dispatch-queue" "$CASE/data/executor-jobs"
  mkdir -p "$CASE/state/research-dispatch-queue" "$CASE/data/executor-jobs"
}
# spawn_phase: seed + fresh-spawn drain so a meta exists for the eval drain.
spawn_phase(){ # <corr> <now>
  local corr=$1 now=$2
  reset_case
  seed_queue "$corr" 1
  export FM_FAKE_WINDOW_TARGET="@7"
  unset FM_FAKE_DEATH_VERDICT
  FM_E1_GUARD_NOW="$now" "$DRAIN" >/dev/null 2>&1 || true
  [ -f "$CASE/data/executor-jobs/$corr.meta" ] || fail "$corr: spawn phase left no meta"
}

# ---- Case 1: unreadable -> HOLD, no requeue, meta kept ----
CORR="dc-unread-$RANDOM"
spawn_phase "$CORR" "2026-08-26T00:10:00Z"
export FM_FAKE_DEATH_VERDICT=unreadable
OUT=$(FM_E1_GUARD_NOW="2026-08-26T00:10:00Z" "$DRAIN" 2>&1 || true)
grep -q "probe-unreadable: corr=$CORR" <<<"$OUT" || fail "1 unreadable hold line missing: $OUT"
grep -q "requeue" <<<"$OUT" && fail "1 unreadable must NOT requeue: $OUT"
[ -f "$CASE/data/executor-jobs/$CORR.meta" ] || fail "1 unreadable must keep the meta"
[ ! -f "$CASE/state/research-dispatch-queue/$CORR.json.requeued" ] || fail "1 unreadable must not write .requeued"
pass "1. unreadable verdict holds without requeue"

# ---- Case 2: dead within startup grace -> HOLD ----
# meta started_at=2026-08-26T00:00:00Z; pin NOW=+2m (age 120s < 300s grace).
CORR="dc-grace-$RANDOM"
spawn_phase "$CORR" "2026-08-26T00:02:00Z"
export FM_FAKE_DEATH_VERDICT=dead
OUT=$(FM_E1_GUARD_NOW="2026-08-26T00:02:00Z" "$DRAIN" 2>&1 || true)
grep -q "starting-grace: corr=$CORR" <<<"$OUT" || fail "2 grace hold line missing: $OUT"
grep -q "requeue" <<<"$OUT" && fail "2 grace must NOT requeue: $OUT"
[ -f "$CASE/data/executor-jobs/$CORR.meta" ] || fail "2 grace must keep the meta"
pass "2. dead within startup grace holds (slow start, no duplicate spawn)"

# ---- Case 3: dead past grace -> requeue (unchanged) ----
# pin NOW=+10m (age 600s > 300s grace): a confident death still requeues.
CORR="dc-dead-$RANDOM"
spawn_phase "$CORR" "2026-08-26T00:10:00Z"
export FM_FAKE_DEATH_VERDICT=dead
OUT=$(FM_E1_GUARD_NOW="2026-08-26T00:10:00Z" "$DRAIN" 2>&1 || true)
grep -q "dispatch worker death: corr=$CORR window=@7 liveness=dead" <<<"$OUT" || fail "3 death line missing: $OUT"
grep -q "dispatch requeue attempt=1/3 corr=$CORR" <<<"$OUT" || fail "3 requeue line missing: $OUT"
pass "3. dead past the grace window still requeues (behavior unchanged)"

# ---- Case 4: alive -> in-flight (unchanged) ----
CORR="dc-alive-$RANDOM"
spawn_phase "$CORR" "2026-08-26T00:10:00Z"
export FM_FAKE_DEATH_VERDICT=alive
OUT=$(FM_E1_GUARD_NOW="2026-08-26T00:10:00Z" "$DRAIN" 2>&1 || true)
grep -q "dispatch in-flight: corr=$CORR window=@7" <<<"$OUT" || fail "4 in-flight line missing: $OUT"
[ -f "$CASE/data/executor-jobs/$CORR.meta" ] || fail "4 alive must keep the meta"
pass "4. alive worker is in-flight (behavior unchanged)"

echo "ok - death-check hold regression passed"
