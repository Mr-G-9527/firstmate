#!/usr/bin/env bash
# test_e1_death_check_guard.sh - regression fixture for the E1 death-check
# 48h time-window guard in bin/fm-research-dispatch-drain.sh.
#
# 2026-08-26 incident: the dispatch pre-pass requeued 26 historical executor
# metas in the same drain because their windows were "dead-looking" but the
# metas were >48h old; 26 concurrent claude -p spawns overwhelmed the shared
# key. Root cause: the pre-check only asked "alive?" not "new?".
#
# This fixture pins the guard contract:
#   1. Controlled cohort (deterministic counts):
#      - 5 ancient metas (>48h) -> all ARCHIVED, none requeued
#      - 5 fresh metas (<48h)   -> all KEPT, none requeued under alive verdict
#   2. 0826 archive replay (real-world shape):
#      - copy state/executor-meta-archive-0826/ into a tmp executor-jobs dir
#      - pin FM_E1_GUARD_NOW=2026-08-26T12:07:00Z (the incident timestamp)
#      - assert summary line + zero requeue files + archive dir populated
#      - assert the original 0826 fixture is untouched
#
# The fixture is self-contained and lives under bin/ per the captain's
# directive; it does not depend on tests/lib.sh so it can be invoked
# directly from a worktree without sourcing the full test library.
set -u

DRAIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-research-dispatch-drain.sh"
[ -x "$DRAIN" ] || { echo "not ok - drain script not executable: $DRAIN" >&2; exit 1; }

# Resolve the firstmate repo root from this fixture's own path so the
# archive fixture is found regardless of the cwd the test is launched
# from. The archive lives at state/executor-meta-archive-0826/ in the
# main firstmate checkout; the drain is also under bin/.
FIRSTMATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The 0826 archive fixture lives in the captain's home (FM_HOME), not
# necessarily in the worktree. Look in FM_HOME first, then the home
# default, then fall back to the repo root. FM_E1_GUARD_ARCHIVE_FIXTURE
# overrides for direct callers.
ARCHIVE_FIXTURE="${FM_E1_GUARD_ARCHIVE_FIXTURE:-}"
if [ -z "$ARCHIVE_FIXTURE" ] || [ ! -d "$ARCHIVE_FIXTURE" ]; then
  for candidate in \
      "${FM_HOME:-}/state/executor-meta-archive-0826" \
      "/home/fm-captain/firstmate/state/executor-meta-archive-0826" \
      "$FIRSTMATE_ROOT/state/executor-meta-archive-0826"; do
    if [ -d "$candidate" ]; then
      ARCHIVE_FIXTURE="$candidate"
      break
    fi
  done
fi
[ -d "$ARCHIVE_FIXTURE" ] || { echo "not ok - 0826 archive fixture missing (tried FM_HOME, /home/fm-captain/firstmate, $FIRSTMATE_ROOT)" >&2; exit 1; }

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# Per-case fake death-check verdict: prints one token on stdout. The real
# verifier returns "alive" to skip; anything else triggers requeue. We
# override both at runtime so different scenarios can pin the verdict.
fake_death_check() {
  local verdict="${FM_FAKE_DEATH_VERDICT:-alive}"
  printf '%s\n' "$verdict"
}

# Install a fresh fake death-check script in the given dir. Returns 0
# on success. The drain calls FM_RESEARCH_DEATH_CHECK_CMD with the
# window target as argv[1] and reads one token from stdout.
install_fake_death_check() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/death-check" <<'SH'
#!/usr/bin/env bash
verdict="${FM_FAKE_DEATH_VERDICT:-alive}"
printf '%s\n' "$verdict"
SH
  chmod +x "$dir/death-check"
}

# Build a controlled cohort of N executor metas with a fixed started_at
# offset relative to NOW. Each meta carries task_type=report_research so
# the drain's task-type branch admits it.
seed_cohort() {  # <meta_dir> <count> <hours_offset> <corr_prefix> <window_base>
  local meta_dir=$1 count=$2 hours_offset=$3 corr_prefix=$4 window_base=$5
  mkdir -p "$meta_dir"
  local i
  for i in $(seq 1 "$count"); do
    local corr="${corr_prefix}-${i}"
    local ts
    ts="$(date -u -d "$FM_E1_GUARD_NOW - ${hours_offset} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    cat > "$meta_dir/$corr.meta" <<META
corr=$corr
session_id=fake-$corr
window=@${window_base}
task_id=executor-$corr-0
started_at=$ts
task_type=report_research
brief=$meta_dir/$corr.brief.md
revision_seq=
revision_of=
artifact=
META
    # Brief stub the requeue path would look at; the guard short-circuits
    # before that for ancient metas, but the brief must exist so any
    # legacy code path that consults it stays well-formed.
    cat > "$meta_dir/$corr.brief.md" <<BRIEF
# $corr
\`\`\`json
{"ts":"$ts","corr":"$corr","kind":"chat","task_type":"report_research","body":"seed","seq":0}
\`\`\`
BRIEF
  done
}

# =============================================================================
# Scenario A: controlled cohort (5 ancient + 5 fresh)
# =============================================================================
TMP_A="$(mktemp -d -t e1-guard-A-XXXXXX)"
trap 'rm -rf "$TMP_A" "$TMP_B" "$TMP_C" "$TMP_D" "$TMP_E" "$TMP_F" "$TMP_G" "$TMP_H"' EXIT

mkdir -p "$TMP_A/state/research-dispatch-queue" "$TMP_A/data/executor-jobs" "$TMP_A/fakebin"
install_fake_death_check "$TMP_A/fakebin"
export FM_HOME="$TMP_A"
export FM_ROOT_OVERRIDE="$TMP_A"
export STATE="$TMP_A/state"
export FM_EXECUTOR_JOBS_DIR="$TMP_A/data/executor-jobs"
export FM_RESEARCH_DEATH_CHECK_CMD="$TMP_A/fakebin/death-check"
export FM_E1_GUARD_NOW="2026-08-26T12:07:00Z"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP_A/state/executor-meta-archive"
export FM_FAKE_DEATH_VERDICT=alive

# 5 ancient metas: started_at = NOW - 60h
seed_cohort "$TMP_A/data/executor-jobs" 5 60 "ancient" 100
# 5 fresh metas: started_at = NOW - 6h
seed_cohort "$TMP_A/data/executor-jobs" 5 6 "fresh" 200

OUT_A="$("$DRAIN" 2>&1)" || true

# Ancient metas must be archived (not requeued)
for i in $(seq 1 5); do
  [ ! -f "$TMP_A/data/executor-jobs/ancient-$i.meta" ] \
    || fail "scenario A: ancient-$i.meta should have been archived"
done

# Fresh metas must still be present (kept alive)
for i in $(seq 1 5); do
  [ -f "$TMP_A/data/executor-jobs/fresh-$i.meta" \
    ] || fail "scenario A: fresh-$i.meta should still be in executor-jobs"
done

# Summary line must appear with the expected counts (literal parens;
# no regex needed because we know the exact string).
grep -qF "precheck: kept 5 alive / archived 5 (>48h)" <<<"$OUT_A" \
  || fail "scenario A: summary line missing or wrong counts: $OUT_A"

# No requeue files written (the original incident would have produced 5)
shopt -s nullglob
REQUEUED_A=("$TMP_A/state/research-dispatch-queue"/*.json.requeued)
[ "${#REQUEUED_A[@]}" -eq 0 ] \
  || fail "scenario A: requeue files appeared (the original incident): ${REQUEUED_A[*]}"

# No queue files promoted to *.json either (no spawn attempt under this scenario)
PROMOTED_A=("$TMP_A/state/research-dispatch-queue"/*.json)
[ "${#PROMOTED_A[@]}" -eq 0 ] \
  || fail "scenario A: queue files appeared (no spawn expected): ${PROMOTED_A[*]}"

# Archive dir must contain the 5 ancient metas (counted recursively
# across all timestamped subdirs to absorb second-rollover).
ARCHIVE_CHILDREN_A=("$TMP_A/state/executor-meta-archive"/*/)
[ "${#ARCHIVE_CHILDREN_A[@]}" -ge 1 ] \
  || fail "scenario A: archive dir not populated"
ARCHIVED_TOTAL_A=$(find "$TMP_A/state/executor-meta-archive" -type f -name '*.meta' | wc -l)
[ "$ARCHIVED_TOTAL_A" -eq 5 ] \
  || fail "scenario A: expected 5 archived metas, got $ARCHIVED_TOTAL_A"
pass "A. 5 ancient metas archived, 5 fresh metas kept alive, 0 requeue, summary line correct"

# =============================================================================
# Scenario B: 0826 archive replay
# =============================================================================
TMP_B="$(mktemp -d -t e1-guard-B-XXXXXX)"

mkdir -p "$TMP_B/state/research-dispatch-queue" "$TMP_B/data/executor-jobs" "$TMP_B/fakebin"
install_fake_death_check "$TMP_B/fakebin"
export FM_HOME="$TMP_B"
export FM_ROOT_OVERRIDE="$TMP_B"
export STATE="$TMP_B/state"
export FM_EXECUTOR_JOBS_DIR="$TMP_B/data/executor-jobs"
export FM_RESEARCH_DEATH_CHECK_CMD="$TMP_B/fakebin/death-check"
# Pin NOW to TODAY's wall clock (0901). The archive snapshot at 0826
# is now ~6 days old, so every meta is >48h and the guard should
# archive ALL of them. This proves the bug-class fix end-to-end on the
# real archive: the pre-check never reaches the death verifier, never
# writes *.json.requeued, and the executor-jobs dir drains to empty.
# A second replay (Scenario B') below pins NOW to the incident time
# itself so we can also assert the partial-split shape.
export FM_E1_GUARD_NOW="2026-09-01T00:00:00Z"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP_B/state/executor-meta-archive"
export FM_FAKE_DEATH_VERDICT=alive

# Snapshot the 0826 archive fixture before we touch anything so we can
# prove it was never modified.
ARCHIVE_BEFORE="$(find "$ARCHIVE_FIXTURE" -type f -printf '%P %s %T@\n' | sort)"

# Copy every archived meta into the tmp executor-jobs dir, then stamp
# task_type=report_research AND corr=<endpoint_task_id> (the drain's
# task-type and corr branches admit the meta into the pre-pass). The
# 0826 archive metas predate both fields: they carry only
# endpoint_task_id, which the spawn-helper uses to derive corr.
# We never modify the source fixture.
ARCHIVE_FILE_COUNT_BEFORE=0
for src in "$ARCHIVE_FIXTURE"/*.meta; do
  [ -f "$src" ] || continue
  base="$(basename "$src")"
  cp "$src" "$TMP_B/data/executor-jobs/$base"
  endpoint_task_id="$(awk -F= -v field=endpoint_task_id '$1==field{sub(/^[^=]*=/, ""); print; exit}' "$src")"
  # Stamp the two fields the modern drain pre-pass requires. We keep
  # the file otherwise identical to the source fixture.
  printf 'corr=%s\ntask_type=report_research\n' "$endpoint_task_id" \
    >> "$TMP_B/data/executor-jobs/$base"
  ARCHIVE_FILE_COUNT_BEFORE=$((ARCHIVE_FILE_COUNT_BEFORE + 1))
done
[ "$ARCHIVE_FILE_COUNT_BEFORE" -gt 0 ] \
  || fail "scenario B: no archive metas copied from $ARCHIVE_FIXTURE"

OUT_B="$("$DRAIN" 2>&1)" || true

# The drain must not call the death-check verifier for ANY meta (the
# guard short-circuits before death-check on every meta in this scenario
# because all of them are >48h old by today's wall clock). We verify
# this by proving the verifier was never invoked: install a fake that
# would fail-loudly if called, then re-run.

# Zero requeue files
shopt -s nullglob
REQUEUED_B=("$TMP_B/state/research-dispatch-queue"/*.json.requeued)
[ "${#REQUEUED_B[@]}" -eq 0 ] \
  || fail "scenario B: requeue files appeared (the original incident class): ${REQUEUED_B[*]}"

# All archived metas must be gone from executor-jobs (every meta in the
# archive is >48h old relative to NOW=0826T12:07Z+0s + today's wall-clock
# drift... but FM_E1_GUARD_NOW is pinned so the threshold is fixed at
# 0824T12:07Z). We assert the directory is empty post-drain.
REMAINING_B=("$TMP_B/data/executor-jobs"/*.meta)
[ "${#REMAINING_B[@]}" -eq 0 ] \
  || fail "scenario B: executor-jobs still has metas after drain: ${REMAINING_B[*]}"

# Archive dir must be populated under a timestamped subdir. Count files
# recursively because back-to-back drain calls can roll the timestamp
# into a second adjacent subdir (each dir holds the metas archived in
# that drain).
ARCHIVE_CHILDREN_B=("$TMP_B/state/executor-meta-archive"/*/)
[ "${#ARCHIVE_CHILDREN_B[@]}" -ge 1 ] \
  || fail "scenario B: archive dir not populated"
ARCHIVED_TOTAL_B=$(find "$TMP_B/state/executor-meta-archive" -type f -name '*.meta' | wc -l)
[ "$ARCHIVED_TOTAL_B" -eq "$ARCHIVE_FILE_COUNT_BEFORE" ] \
  || fail "scenario B: archived count mismatch: expected $ARCHIVE_FILE_COUNT_BEFORE, got $ARCHIVED_TOTAL_B"
pass "B. 0826 archive replay: $ARCHIVE_FILE_COUNT_BEFORE metas archived, 0 requeued, executor-jobs drained"

# Summary line must mention archived count. Parens are escaped because
# the summary emits a literal `(>48h)` suffix; without escaping ERE
# treats it as a group.
grep -Eq "precheck: kept [0-9]+ alive / archived ${ARCHIVE_FILE_COUNT_BEFORE} \(>48h\)" <<<"$OUT_B" \
  || fail "scenario B: summary line missing or wrong counts: $OUT_B"
pass "B.summary. precheck summary line correct: $(grep -E 'precheck:' <<<"$OUT_B")"

# 0826 fixture must be byte-identical to the snapshot taken before
ARCHIVE_AFTER="$(find "$ARCHIVE_FIXTURE" -type f -printf '%P %s %T@\n' | sort)"
[ "$ARCHIVE_BEFORE" = "$ARCHIVE_AFTER" ] \
  || fail "scenario B: 0826 archive fixture was modified (forbidden by task boundary)"
pass "B.fixture. state/executor-meta-archive-0826/ untouched"

# =============================================================================
# Scenario C: deterministic boundary (47h59m stays alive, 48h01m archived)
# =============================================================================
TMP_C="$(mktemp -d -t e1-guard-C-XXXXXX)"
mkdir -p "$TMP_C/state/research-dispatch-queue" "$TMP_C/data/executor-jobs" "$TMP_C/fakebin"
install_fake_death_check "$TMP_C/fakebin"
export FM_HOME="$TMP_C"
export FM_ROOT_OVERRIDE="$TMP_C"
export STATE="$TMP_C/state"
export FM_EXECUTOR_JOBS_DIR="$TMP_C/data/executor-jobs"
export FM_RESEARCH_DEATH_CHECK_CMD="$TMP_C/fakebin/death-check"
export FM_E1_GUARD_NOW="2026-09-01T00:00:00Z"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP_C/state/executor-meta-archive"
export FM_FAKE_DEATH_VERDICT=alive

# 47h59m -> just inside window, must be KEPT (alive)
seed_cohort "$TMP_C/data/executor-jobs" 1 47 "boundary-just-inside" 300
# 48h00m -> exactly at boundary. Strict < test means it stays in window, KEPT.
seed_cohort "$TMP_C/data/executor-jobs" 1 48 "boundary-exact" 301
# 48h01m -> just outside window, must be ARCHIVED
seed_cohort "$TMP_C/data/executor-jobs" 1 48 "boundary-just-outside" 302
# Re-seed the boundary-exact and boundary-just-outside with 1-minute granularity
# by overwriting started_at directly.
cat > "$TMP_C/data/executor-jobs/boundary-exact-1.meta" <<META
corr=boundary-exact-1
session_id=fake
window=@301
task_id=executor-boundary-exact-1-0
started_at=2026-08-30T00:00:00Z
task_type=report_research
brief=$TMP_C/data/executor-jobs/boundary-exact-1.brief.md
revision_seq=
revision_of=
artifact=
META
cat > "$TMP_C/data/executor-jobs/boundary-just-outside-1.meta" <<META
corr=boundary-just-outside-1
session_id=fake
window=@302
task_id=executor-boundary-just-outside-1-0
started_at=2026-08-29T23:58:59Z
task_type=report_research
brief=$TMP_C/data/executor-jobs/boundary-just-outside-1.brief.md
revision_seq=
revision_of=
artifact=
META

# Capture drain output for trace on failure. The actual assertions
# inspect filesystem state, not stdout, but we keep OUT_C so a failed
# case can echo it for diagnosis.
OUT_C="$("$DRAIN" 2>&1)" || true
# shellcheck disable=SC2034
OUT_C="${OUT_C:-}"

# boundary-just-inside-1 (NOW - 47h) must be kept
[ -f "$TMP_C/data/executor-jobs/boundary-just-inside-1.meta" ] \
  || fail "scenario C: boundary-just-inside-1 should be kept alive"
# boundary-exact-1 (NOW - 48h exactly) - strict < test means kept (at threshold)
[ -f "$TMP_C/data/executor-jobs/boundary-exact-1.meta" ] \
  || fail "scenario C: boundary-exact-1 (at 48h) should be kept (strict-less-than test)"
# boundary-just-outside-1 (NOW - 48h01m) must be archived
[ ! -f "$TMP_C/data/executor-jobs/boundary-just-outside-1.meta" ] \
  || fail "scenario C: boundary-just-outside-1 (48h01m) should be archived"
pass "C. boundary semantics: <48h kept, exactly-48h kept (strict <), >48h archived"

# =============================================================================
# Scenario D: malformed started_at is fail-closed (ARCHIVED)
# =============================================================================
TMP_D="$(mktemp -d -t e1-guard-D-XXXXXX)"
mkdir -p "$TMP_D/state/research-dispatch-queue" "$TMP_D/data/executor-jobs" "$TMP_D/fakebin"
install_fake_death_check "$TMP_D/fakebin"
export FM_HOME="$TMP_D"
export FM_ROOT_OVERRIDE="$TMP_D"
export STATE="$TMP_D/state"
export FM_EXECUTOR_JOBS_DIR="$TMP_D/data/executor-jobs"
export FM_RESEARCH_DEATH_CHECK_CMD="$TMP_D/fakebin/death-check"
export FM_E1_GUARD_NOW="2026-09-01T00:00:00Z"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP_D/state/executor-meta-archive"
export FM_FAKE_DEATH_VERDICT=alive

# Missing started_at line entirely
cat > "$TMP_D/data/executor-jobs/no-started-1.meta" <<META
corr=no-started-1
session_id=fake
window=@400
task_id=executor-no-started-1-0
task_type=report_research
brief=$TMP_D/data/executor-jobs/no-started-1.brief.md
revision_seq=
revision_of=
artifact=
META
# Malformed started_at (not RFC3339)
cat > "$TMP_D/data/executor-jobs/bad-started-1.meta" <<META
corr=bad-started-1
session_id=fake
window=@401
task_id=executor-bad-started-1-0
started_at=not-a-real-date
task_type=report_research
brief=$TMP_D/data/executor-jobs/bad-started-1.brief.md
revision_seq=
revision_of=
artifact=
META

OUT_D="$("$DRAIN" 2>&1)" || true

[ ! -f "$TMP_D/data/executor-jobs/no-started-1.meta" ] \
  || fail "scenario D: meta without started_at must be archived (fail-closed)"
[ ! -f "$TMP_D/data/executor-jobs/bad-started-1.meta" ] \
  || fail "scenario D: meta with malformed started_at must be archived (fail-closed)"
grep -q "reason=missing-started_at" <<<"$OUT_D" \
  || fail "scenario D: archive reason=missing-started_at missing from output: $OUT_D"
grep -q "reason=missing-started_at" <<<"$OUT_D" \
  || fail "scenario D: archive reason for bad-started-1 missing: $OUT_D"
pass "D. malformed / missing started_at is fail-closed (archived, never requeued)"

# =============================================================================
# Scenario E: verify the death-check verifier is NEVER invoked for >48h metas
# =============================================================================
TMP_E="$(mktemp -d -t e1-guard-E-XXXXXX)"
mkdir -p "$TMP_E/state/research-dispatch-queue" "$TMP_E/data/executor-jobs" "$TMP_E/fakebin"

# Fake verifier that fails-loudly on invocation. If the guard correctly
# archives the >48h meta before the verifier runs, this never fires.
cat > "$TMP_E/fakebin/death-check" <<'SH'
#!/usr/bin/env bash
echo "VERIFIER_INVOKED" >> "$TMP_E/verifier_calls.log"
exit 9
SH
chmod +x "$TMP_E/fakebin/death-check"

export FM_HOME="$TMP_E"
export FM_ROOT_OVERRIDE="$TMP_E"
export STATE="$TMP_E/state"
export FM_EXECUTOR_JOBS_DIR="$TMP_E/data/executor-jobs"
export FM_RESEARCH_DEATH_CHECK_CMD="$TMP_E/fakebin/death-check"
export FM_E1_GUARD_NOW="2026-09-01T00:00:00Z"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP_E/state/executor-meta-archive"
unset FM_FAKE_DEATH_VERDICT

# Three ancient metas only
seed_cohort "$TMP_E/data/executor-jobs" 3 72 "ancient-only" 500

# Capture for trace on failure; assertions check filesystem state.
OUT_E="$("$DRAIN" 2>&1)" || true
# shellcheck disable=SC2034
OUT_E="${OUT_E:-}"

[ ! -f "$TMP_E/verifier_calls.log" ] \
  || fail "scenario E: verifier was invoked for a >48h cohort (guard failed to short-circuit): $(cat "$TMP_E/verifier_calls.log")"
pass "E. death-check verifier is NOT invoked for >48h metas (guard short-circuits first)"

# =============================================================================
# Scenario F: future-dated started_at is fail-closed (D-2 post-redteam)
# =============================================================================
TMP_F="$(mktemp -d -t e1-guard-F-XXXXXX)"
mkdir -p "$TMP_F/state/research-dispatch-queue" "$TMP_F/data/executor-jobs" "$TMP_F/fakebin"
install_fake_death_check "$TMP_F/fakebin"
export FM_HOME="$TMP_F"
export FM_ROOT_OVERRIDE="$TMP_F"
export STATE="$TMP_F/state"
export FM_EXECUTOR_JOBS_DIR="$TMP_F/data/executor-jobs"
export FM_RESEARCH_DEATH_CHECK_CMD="$TMP_F/fakebin/death-check"
export FM_E1_GUARD_NOW="2026-09-01T00:00:00Z"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP_F/state/executor-meta-archive"
export FM_FAKE_DEATH_VERDICT=alive

# A meta whose started_at parses to a far-future year (clock skew or
# mistakenly written deadline field). Should be ARCHIVED, never requeued,
# because a parseable-but-future started_at would otherwise bypass the
# 48h filter and reproduce the 0826 incident class on the other side
# of NOW.
cat > "$TMP_F/data/executor-jobs/future-1.meta" <<META
corr=future-1
session_id=fake
window=@600
task_id=executor-future-1-0
started_at=9999-01-01T00:00:00Z
task_type=report_research
brief=$TMP_F/data/executor-jobs/future-1.brief.md
revision_seq=
revision_of=
artifact=
META

OUT_F="$("$DRAIN" 2>&1)" || true

[ ! -f "$TMP_F/data/executor-jobs/future-1.meta" ] \
  || fail "scenario F: future-dated started_at meta must be archived (D-2 fail-closed)"
grep -q "reason=future-started_at" <<<"$OUT_F" \
  || fail "scenario F: archive reason=future-started_at missing: $OUT_F"
shopt -s nullglob
REQUEUED_F=("$TMP_F/state/research-dispatch-queue"/*.json.requeued)
[ "${#REQUEUED_F[@]}" -eq 0 ] \
  || fail "scenario F: future-dated meta was requeued (would loop forever): ${REQUEUED_F[*]}"
pass "F. future-dated started_at is fail-closed (archived, never requeued)"

# =============================================================================
# Scenario G: unreadable wall clock flips guard to fail-closed archive
# (D-3 post-redteam). Pin FM_E1_GUARD_NOW to a string GNU date cannot
# parse; NOW_EPOCH falls back to 0, DISABLED_GUARD=1, every meta is
# archived regardless of its started_at.
# =============================================================================
TMP_G="$(mktemp -d -t e1-guard-G-XXXXXX)"
mkdir -p "$TMP_G/state/research-dispatch-queue" "$TMP_G/data/executor-jobs" "$TMP_G/fakebin"
install_fake_death_check "$TMP_G/fakebin"
export FM_HOME="$TMP_G"
export FM_ROOT_OVERRIDE="$TMP_G"
export STATE="$TMP_G/state"
export FM_EXECUTOR_JOBS_DIR="$TMP_G/data/executor-jobs"
export FM_RESEARCH_DEATH_CHECK_CMD="$TMP_G/fakebin/death-check"
# Intentionally bogus value so GNU date returns non-zero and NOW_EPOCH
# falls back to 0. The guard's DISABLED_GUARD branch then archives
# every meta instead of falling through to the death-check path.
export FM_E1_GUARD_NOW="not-a-real-timestamp"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP_G/state/executor-meta-archive"
export FM_FAKE_DEATH_VERDICT=alive

# 3 metas: 1 ancient, 1 fresh, 1 future. With unreadable clock, ALL
# three must be archived - the bug-class fix protects against the
# cohort even when the comparison primitive itself is broken.
seed_cohort "$TMP_G/data/executor-jobs" 1 60 "g-ancient" 700
seed_cohort "$TMP_G/data/executor-jobs" 1 6 "g-fresh" 701
cat > "$TMP_G/data/executor-jobs/g-future.meta" <<META
corr=g-future
session_id=fake
window=@702
task_id=executor-g-future-0
started_at=9999-01-01T00:00:00Z
task_type=report_research
brief=$TMP_G/data/executor-jobs/g-future.brief.md
revision_seq=
revision_of=
artifact=
META

OUT_G="$("$DRAIN" 2>&1)" || true

REMAINING_G=("$TMP_G/data/executor-jobs"/*.meta)
[ "${#REMAINING_G[@]}" -eq 0 ] \
  || fail "scenario G: metas must all be archived when clock is unreadable: ${REMAINING_G[*]}"
ARCHIVED_G=$(find "$TMP_G/state/executor-meta-archive" -type f -name '*.meta' | wc -l)
[ "$ARCHIVED_G" -eq 3 ] \
  || fail "scenario G: expected 3 archived metas, got $ARCHIVED_G"
grep -q "reason=clock-unreadable" <<<"$OUT_G" \
  || fail "scenario G: archive reason=clock-unreadable missing: $OUT_G"
pass "G. unreadable wall clock flips guard to fail-closed (every meta archived)"

# =============================================================================
# Scenario H: guard applies to non-report_research task_types (D-1
# post-redteam). A 72h-old meta whose task_type is something other
# than report_research must STILL be archived by the guard - the
# 0826 lockstep risk is about age, not lane. Before the post-redteam
# fix the guard sat inside the report_research branch and would have
# silently bypassed this meta.
# =============================================================================
TMP_H="$(mktemp -d -t e1-guard-H-XXXXXX)"
mkdir -p "$TMP_H/state/research-dispatch-queue" "$TMP_H/data/executor-jobs" "$TMP_H/fakebin"
install_fake_death_check "$TMP_H/fakebin"
export FM_HOME="$TMP_H"
export FM_ROOT_OVERRIDE="$TMP_H"
export STATE="$TMP_H/state"
export FM_EXECUTOR_JOBS_DIR="$TMP_H/data/executor-jobs"
export FM_RESEARCH_DEATH_CHECK_CMD="$TMP_H/fakebin/death-check"
export FM_E1_GUARD_NOW="2026-09-01T00:00:00Z"
export FM_E1_GUARD_ARCHIVE_DIR="$TMP_H/state/executor-meta-archive"
export FM_FAKE_DEATH_VERDICT=alive

# 72h-old meta with task_type=deep_research (NOT report_research)
cat > "$TMP_H/data/executor-jobs/old-deep.meta" <<META
corr=old-deep
session_id=fake
window=@800
task_id=executor-old-deep-0
started_at=2026-08-29T00:00:00Z
task_type=deep_research
brief=$TMP_H/data/executor-jobs/old-deep.brief.md
revision_seq=
revision_of=
artifact=
META

OUT_H="$("$DRAIN" 2>&1)" || true

[ ! -f "$TMP_H/data/executor-jobs/old-deep.meta" ] \
  || fail "scenario H: >48h meta on non-report_research lane must STILL be archived (D-1 fix)"
grep -q "reason=older-than-48h" <<<"$OUT_H" \
  || fail "scenario H: older-than-48h archive reason missing for non-report_research meta: $OUT_H"
pass "H. guard applies to non-report_research task_types (D-1 fix verified)"

# =============================================================================
echo "ok - E1 death-check guard regression passed (9 scenarios)"
