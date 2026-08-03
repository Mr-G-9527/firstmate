#!/usr/bin/env bash
# fm-watch-backstop.sh - the delivery backstop for the daemon+argv session
# topology in which Claude Code's Stop-hook asyncRewake does NOT re-invoke
# the idle primary.
#
# Context (data/handoff-2026-08-03-wake-and-lint.md, item 1; the verified fact
# in data/learnings.md dated 2026-08-03):
#
#   - A bare interactive `claude` from a tmux pane does receive asyncRewake.
#   - A firstmate primary under `claude -> claude.exe daemon run --origin
#     transient -> bg-pty-host -> claude.exe --session-id ... -- <prompt>`
#     does NOT. Same machine, same Claude Code 2.1.220, same hook shape, one
#     variable changed: the session topology.
#   - Background Bash task completions DO re-invoke that same idle session
#     (observed 2/2). The proven delivery branch is therefore "a bash
#     subprocess completes", not "asyncRewake fires".
#
# Shape (watcher is the one armed supervision cycle; this script is delivery
# plumbing, never an arm):
#
#   1. bin/fm-claude-stop-autoarm.sh writes `outcome=rewake` into
#      state/.claude-autoarm-epoch when it has an actionable wake to deliver.
#   2. bin/fm-watch.sh monitors that epoch. Once the row is still unconsumed
#      after FM_WATCH_BACKSTOP_GRACE seconds (default 60s, which clears
#      FM_CLAUDE_AUTOARM_EPOCH_FRESH 15s plus typical background-task
#      notification latency), the watcher spawns THIS script as a detached
#      bash task. asyncRewake is retained as the opportunistic fast path;
#      the backstop is the second line of defense.
#   3. THIS script (re-checks first, then acts):
#        a. Reads state/.claude-autoarm-epoch and confirms `outcome=rewake`.
#           If the file is gone or carries a NEWER outcome, the original
#           asyncRewake already landed and we exit 0 without injecting
#           (idempotency / race window between the 60s expiry and the
#           asyncRewake finally arriving).
#        b. Reads state/.wake-queue and locates the undelivered rewake row:
#           the newest unconsumed row whose epoch >= the auto-arm's
#           updated_at. Removes that row from the queue (consume-then-inject
#           in the same critical section, so a concurrent drain cannot
#           double-fire).
#        c. Re-checks the epoch one more time (the brief's idempotency
#           window - the race is between the watcher's spawn and THIS
#           inject). Skips the inject if the original asyncRewake landed
#           in the meantime.
#        d. Encodes the consumed payload with the watcher-kind
#           operational-input header, resolves the supervisor pane through
#           the same discovery the away-mode daemon uses, and types it via
#           fm_backend_send_text_submit.
#        e. Writes `outcome=consumed` into the epoch ledger so the watcher
#           stops re-firing for this same rewake.
#
# Design decisions settled BEFORE this code was written (recorded in
# docs/turnend-guard.md "Wake backstop for the daemon+argv topology" so
# future readers see them with the design, not buried in variables):
#
#   - "Watcher observed the wake was consumed" is BOUNDED BY TIMEOUT, not
#     by positive confirmation. The wake is the only signal a consume
#     happened, and firstmate can only emit that signal after the rewake
#     has already delivered - so in the failure case the observation never
#     happens. The backstop is a timer, not an oracle. The 60s default
#     clears the synchronous rewake window (15s) plus typical
#     background-task notification latency; tuning it higher increases
#     silence, tuning it lower races asyncRewake.
#   - Idempotency is owned by THIS script, not the watcher, so the re-check
#     happens as close to the inject as possible. A re-check in the
#     watcher is racy with anything that happens between the spawn and the
#     inject.
#
# Subcommands:
#   fm-watch-backstop.sh should-fire   print "1" if the backstop should
#                                       fire, "0" otherwise; nothing else.
#   fm-watch-backstop.sh fire         spawn this script's inject path as a
#                                       detached bash task (used by the
#                                       watcher; never blocks the watcher's
#                                       cycle). Honors
#                                       FM_WATCH_BACKSTOP_DISABLE=1 (default
#                                       off) as an emergency kill switch.
#   fm-watch-backstop.sh inject       run the re-check + consume + inject
#                                       path synchronously. Returns 0 on
#                                       clean abort (consumed by another
#                                       path) or successful inject,
#                                       non-zero on a real failure.
#
# All commands take the state directory as the single positional argument,
# defaulting to ${FM_STATE_OVERRIDE:-$FM_HOME/state}, so a hermetic test
# can drive them against a scratch state without touching the live home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# STATE is set per subcommand by fm_backstop_main (default
# ${FM_STATE_OVERRIDE:-$FM_HOME/state}). Do not resolve it here - a script
# invocation that supplies a subcommand before the state dir would
# otherwise pin STATE to the subcommand word.
STATE=
EPOCH=
FM_WATCH_QUEUE=
FM_WATCH_QUEUE_LOCK=

# Read-only sources. Source-bin the backstop has no test override, so the
# watcher supplies the same libs the daemon and the wake-drain use.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

# Tunables. Default 60s clears the 15s synchronous-rewake window plus typical
# background-task notification latency. Override only with care: a value
# below the synchronous window races asyncRewake; a value above leaves the
# idle session silent for that long. Both are bad, so the default is the
# one the 2026-08-03 evidence supported.
FM_WATCH_BACKSTOP_GRACE=${FM_WATCH_BACKSTOP_GRACE:-60}

# state_under_test_for_logging: the brief asks the constraint self-check to
# be recorded; this script's logs include the state path it acted on so a
# failure in the live home is distinguishable from a failure in a scratch
# probe.
log_backstop() {
  printf 'fm-watch-backstop[%s]: %s\n' "${STATE}" "$*" >&2
}

# epoch_outcome / epoch_seq / epoch_updated_at: read the four-field ledger
# written by bin/fm-claude-stop-autoarm.sh's write_epoch (no schema change
# here; the backstop reads exactly what the auto-arm writes). All three
# return 0 on a clean parse, 1 on missing or malformed, and print the value
# to stdout. The watcher treats an absent epoch as "no rewake pending".
epoch_outcome() {
  local outcome
  outcome=$(sed -n 's/^epoch=[0-9][0-9]* owner_pid=[0-9][0-9]* outcome=\([^ ]*\) updated_at=[0-9][0-9]*$/\1/p' "$EPOCH" 2>/dev/null | head -1) || outcome=
  case "$outcome" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s\n' "$outcome"
}
epoch_seq() {
  local seq
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null | head -1) || seq=
  case "$seq" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$seq"
}
epoch_updated_at() {
  local updated
  updated=$(sed -n 's/.* updated_at=\([0-9][0-9]*\)$/\1/p' "$EPOCH" 2>/dev/null | head -1) || updated=
  case "$updated" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$updated"
}

# find_undelivered_row <updated_at>: print the most recent unconsumed wake
# row whose epoch is at or after the auto-arm's updated_at, on stdout as
# one TAB-separated line. Returns 0 on a hit, 1 on no matching row. The
# matcher is "epoch >= updated_at" rather than exact equality so a wake
# appended in the same wall-clock second as the auto-arm's claim still
# counts (epoch granularity is one second; an exact match would be racy).
# Read under the same queue lock fm_wake_append uses so a concurrent
# append cannot be observed half-written.
find_undelivered_row() {
  local cutoff=$1 row_epoch row_seq row_key row_payload
  fm_lock_acquire_wait "$FM_WATCH_QUEUE_LOCK"
  while IFS="$(printf '\t')" read -r row_epoch row_seq row_kind row_key row_payload; do
    [ -n "$row_epoch" ] || continue
    case "$row_epoch" in
      *[!0-9]*) continue ;;
    esac
    [ "$row_epoch" -lt "$cutoff" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$row_epoch" "$row_seq" "$row_kind" "$row_key" "$row_payload"
    fm_lock_release "$FM_WATCH_QUEUE_LOCK"
    return 0
  done < <(awk -F '\t' 'NF >= 5 { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }' "$FM_WATCH_QUEUE" 2>/dev/null | sort -t "$(printf '\t')" -k1,1n -k2,2nr)
  fm_lock_release "$FM_WATCH_QUEUE_LOCK"
  return 1
}

# consume_undelivered_row <seq>: rewrite the queue without the row whose
# seq matches. Atomic under the queue lock so a concurrent drain cannot
# observe a half-empty queue. The print-then-mv discipline mirrors
# fm-wake-drain.sh's no-loss boundary. Returns 0 on a clean consume, 1 if
# the row was not present (another consumer won the race; idempotency
# already covered this case before the call).
consume_undelivered_row() {
  local seq=$1 tmp
  [ -n "$seq" ] || return 1
  fm_lock_acquire_wait "$FM_WATCH_QUEUE_LOCK"
  if ! awk -F '\t' -v s="$seq" 'NR == 1 && $2 == s { found=1 } END { exit !found }' "$FM_WATCH_QUEUE" 2>/dev/null; then
    fm_lock_release "$FM_WATCH_QUEUE_LOCK"
    return 1
  fi
  tmp="$FM_WATCH_QUEUE.consume.$$"
  awk -F '\t' -v s="$seq" 'NF >= 5 && $2 == s { next } { print }' "$FM_WATCH_QUEUE" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$FM_WATCH_QUEUE_LOCK"
    return 1
  }
  mv -f "$tmp" "$FM_WATCH_QUEUE" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$FM_WATCH_QUEUE_LOCK"
    return 1
  }
  fm_lock_release "$FM_WATCH_QUEUE_LOCK"
  return 0
}

# restore_undelivered_row <row-line>: re-append a previously-consumed row
# to the queue. The mirror of consume_undelivered_row. Used by the
# unconfirmed-inject branch so a verdict != empty retries on the next
# backstop cycle. The row is re-appended at the END of the queue (the
# same way fm_wake_append does), which means the seq is fresh and the
# backstop's next should_fire will see it as a new "most recent row"
# candidate. Returns 0 on a clean re-append, 1 on lock failure.
restore_undelivered_row() {
  local row=$1 tmp seq_file
  [ -n "$row" ] || return 1
  fm_lock_acquire_wait "$FM_WATCH_QUEUE_LOCK"
  seq_file="$STATE/.wake-queue.seq"
  local new_seq
  new_seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$new_seq" in ''|*[!0-9]*) new_seq=0 ;; esac
  new_seq=$((new_seq + 1))
  # Substitute the original seq with a fresh one so the row is append-
  # safe (a duplicate seq would not break the queue but is unnecessary
  # noise). The replace is awk-driven so the rest of the line (kind,
  # key, payload) is preserved byte-for-byte.
  local restored
  restored=$(printf '%s' "$row" | awk -F '\t' -v s="$new_seq" 'NF >= 5 { $2 = s; print } OFS="\t"')
  printf '%s\n' "$restored" >> "$FM_WATCH_QUEUE" 2>/dev/null || {
    fm_lock_release "$FM_WATCH_QUEUE_LOCK"
    return 1
  }
  printf '%s\n' "$new_seq" > "$seq_file" 2>/dev/null || true
  fm_lock_release "$FM_WATCH_QUEUE_LOCK"
  return 0
}

# mark_epoch_consumed: rewrite the epoch ledger with outcome=consumed so
# the watcher stops re-firing for the same rewake. Same write discipline
# as bin/fm-claude-stop-autoarm.sh's write_epoch (no schema change; we
# reuse the same four-field format with a different outcome value).
mark_epoch_consumed() {
  local seq tmp
  seq=$(epoch_seq 2>/dev/null) || seq=0
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  tmp="$EPOCH.consumed.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "consumed" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# should_fire: print 1 if the backstop trigger conditions all hold, 0
# otherwise. Used by the watcher at the top of each cycle to decide
# whether to spawn the detached inject. Pure read; no side effects.
should_fire() {
  local outcome updated_at now consumed_marker
  outcome=$(epoch_outcome 2>/dev/null) || { printf '0\n'; return 0; }
  [ "$outcome" = rewake ] || { printf '0\n'; return 0; }
  updated_at=$(epoch_updated_at 2>/dev/null) || { printf '0\n'; return 0; }
  case "$updated_at" in ''|*[!0-9]*) printf '0\n'; return 0 ;; esac
  consumed_marker="$STATE/.watch-backstop-consumed-$updated_at"
  [ -e "$consumed_marker" ] && { printf '0\n'; return 0; }
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) printf '0\n'; return 0 ;; esac
  if [ $(( now - updated_at )) -lt "$FM_WATCH_BACKSTOP_GRACE" ]; then
    printf '0\n'; return 0
  fi
  find_undelivered_row "$updated_at" >/dev/null 2>&1 || { printf '0\n'; return 0; }
  printf '1\n'
}

# inject (the worker's body): the full re-check, consume, encode, send,
# mark-consumed path. The consume step is intentionally LAST so any
# earlier guard failure (epoch re-check, encode, target, confirm gate)
# leaves the row in the queue for the next backstop attempt. Only the
# confirmed-inject path owns the consume.
inject() {
  local outcome_now updated_at row epoch_seq_val epoch_payload encoded target backend retries sleep_s verdict consumed_marker
  # Idempotency (design point 2): re-check the epoch. The watcher saw
  # `outcome=rewake` >= grace seconds ago, but the original asyncRewake
  # can land in the same window. Any of these three is "already
  # consumed, abort cleanly": file removed; outcome changed; seq advanced.
  outcome_now=$(epoch_outcome 2>/dev/null) || outcome_now=missing
  if [ "$outcome_now" != rewake ]; then
    log_backstop "aborting inject: outcome is '$outcome_now' (asyncRewake already landed or epoch gone)"
    return 0
  fi
  updated_at=$(epoch_updated_at 2>/dev/null) || { log_backstop "aborting inject: malformed updated_at"; return 0; }
  consumed_marker="$STATE/.watch-backstop-consumed-$updated_at"
  if [ -e "$consumed_marker" ]; then
    log_backstop "aborting inject: consumed marker exists for updated_at=$updated_at"
    return 0
  fi
  # Locate the undelivered rewake row. We read the wake row's seq for the
  # consume step and its payload for the inject; the row's kind and key are
  # surfaced by the wake-lib's append contract but the backstop only needs
  # the seq (for consume) and the payload (for inject), so we discard them.
  row=$(find_undelivered_row "$updated_at" 2>/dev/null) || {
    log_backstop "aborting inject: no undelivered row with epoch >= $updated_at"
    return 0
  }
  IFS="$(printf '\t')" read -r _ epoch_seq_val _ _ epoch_payload <<< "$row"
  # Second re-check (design point 2 verbatim: "Immediately before
  # injecting, the Bash task MUST re-check ... and skip the inject if the
  # original asyncRewake landed"). Between the first re-check above and
  # this point, asyncRewake may have finally fired and the Stop guard
  # may have appended `outcome=consumed` (we just used its value above,
  # so the safe check is "still rewake").
  outcome_now=$(epoch_outcome 2>/dev/null) || outcome_now=missing
  if [ "$outcome_now" != rewake ]; then
    log_backstop "aborting inject: outcome changed to '$outcome_now' between check and inject (asyncRewake landed mid-flight)"
    return 0
  fi
  # Encode the payload with the canonical watcher-kind operational-input
  # envelope. This is the same envelope bin/fm-supervise-daemon.sh's
  # inject_msg uses; the away-mode daemon already classifies it, and the
  # primary's own harness treats it as the watcher wake it would have
  # received through the failed asyncRewake.
  if ! fm_operational_input_encode watcher "$epoch_payload" encoded 2>/dev/null; then
    log_backstop "aborting inject: failed to encode payload as watcher-kind operational input"
    return 0
  fi
  # Resolve the supervisor pane through the SAME discovery the away-mode
  # daemon uses, so the inject lands in the captain's primary pane and
  # not in some inherited or guessed window.
  target=$(discover_supervisor_target 2>/dev/null) || target=$FM_SUPERVISOR_TARGET_DEFAULT
  backend=$(discover_supervisor_backend 2>/dev/null) || backend=$FM_SUPERVISOR_BACKEND_DEFAULT
  [ -n "$target" ] && [ -n "$backend" ] || {
    log_backstop "aborting inject: no supervisor target (target='$target' backend='$backend')"
    return 0
  }
  # Compose the inject: type-once + Enter + confirm. The send primitive
  # echoes a proof-carrying verdict; we accept only exact "empty" as a
  # confirmed delivery so a swallowed Enter (Pending/Unknown) preserves
  # the consumed row's record for the next cycle or the catch-up path.
  #
  # Test-isolation guard: a probe that supplies FM_STATE_OVERRIDE without
  # also pinning the supervisor target would default to the live primary
  # and deliver a real wake to the captain (the 2026-08-03 incident that
  # motivated this commit's brief). The watcher always sets
  # FM_WATCH_BACKSTOP_CONFIRM_INJECT=1 through `fire`; a probe that
  # explicitly wants to drive the send step must do the same. This
  # fail-closed gate keeps the live home safe even if a future test
  # forgets to mock tmux.
  if [ "${FM_WATCH_BACKSTOP_CONFIRM_INJECT:-0}" != "1" ]; then
    log_backstop "aborting inject: FM_WATCH_BACKSTOP_CONFIRM_INJECT not set (refusing to send to a real pane from a non-live state)"
    return 0
  fi
  # Consume the row ONLY at this last possible moment, so any earlier
  # guard failure (epoch check, encode, target, confirm gate) leaves the
  # row in the queue for the next backstop attempt. The race with
  # fm-wake-drain is bounded: the drain only removes what its
  # fm_wake_queued_keys_locked already saw, and consume_undelivered_row's
  # lock + mv covers the same critical section.
  consume_undelivered_row "$epoch_seq_val" || {
    log_backstop "aborting inject: row seq=$epoch_seq_val already consumed by another path"
    return 0
  }
  retries=${FM_INJECT_CONFIRM_RETRIES:-3}
  sleep_s=${FM_INJECT_CONFIRM_SLEEP:-0.5}
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$encoded" "$retries" "$sleep_s" "$sleep_s" 2>/dev/null || echo unknown)
  case "$verdict" in
    empty)
      # Mark the epoch consumed (covers both the success path and the
      # idempotency-after-asyncRewake path on subsequent cycles).
      : > "$consumed_marker"
      mark_epoch_consumed
      log_backstop "injected rewake seq=$epoch_seq_val to $backend:$target"
      return 0
      ;;
    *)
      # Restore the consumed row so a later attempt can re-fire.
      # The requeue writes it back to the queue; the backstop will see
      # it on the next cycle and try again. The consumed marker stays
      # absent so the watcher can re-fire.
      restore_undelivered_row "$row" || log_backstop "restore_undelivered_row failed (verdict=$verdict); row will be re-derived from a future status write"
      log_backstop "inject verdict=$verdict (unconfirmed); restored row seq=$epoch_seq_val for retry"
      return 1
      ;;
  esac
}

# fire (the watcher's entry point): spawn the inject path as a detached
# bash task so the watcher's loop never blocks. uses setsid so the
# child is not in the watcher's process group; the watcher's exit does
# not signal the child. Returns 0 immediately after spawn; the
# detached child's own log is the only signal of its success.
fire() {
  if [ "${FM_WATCH_BACKSTOP_DISABLE:-0}" = "1" ]; then
    log_backstop "fire suppressed by FM_WATCH_BACKSTOP_DISABLE=1"
    return 0
  fi
  local state_arg=$STATE
  if [ "${1:-}" ]; then state_arg=$1; fi
  # setsid gives the child its own session so a SIGHUP sent to the
  # watcher's group on its own exit (the Stop hook async path) does
  # not reach the child. </dev/null + setsid + & is the established
  # one-shot background fork pattern; the child is not a Claude Code
  # background task itself, but its completion is observable to Claude
  # the same way every other Claude-owned async subprocess's exit is.
  FM_STATE_OVERRIDE="$state_arg" FM_WATCH_BACKSTOP_CONFIRM_INJECT=1 setsid bash "$SCRIPT_DIR/fm-watch-backstop.sh" inject "$state_arg" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  log_backstop "spawned detached inject pid=$!"
}

fm_backstop_usage() {
  sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'
  printf '\nUsage:\n  fm-watch-backstop.sh <should-fire|inject|fire> [state-dir]\n'
}

fm_backstop_main() {
  local cmd=${1:-} state_arg=${2:-}
  # Resolve the per-call state dir: explicit positional arg wins, then
  # FM_STATE_OVERRIDE (testing), then the live home. All paths are
  # re-derived from the resolved STATE so a caller can drive the backstop
  # against a scratch state dir without touching the firstmate home.
  STATE=${state_arg:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}
  EPOCH="$STATE/.claude-autoarm-epoch"
  FM_WATCH_QUEUE="$STATE/.wake-queue"
  FM_WATCH_QUEUE_LOCK="$STATE/.wake-queue.lock"
  case "$cmd" in
    should-fire)
      should_fire
      return $?
      ;;
    inject)
      inject
      return $?
      ;;
    fire)
      fire "$state_arg"
      return $?
      ;;
    -h|--help|help)
      fm_backstop_usage
      return 0
      ;;
    *)
      fm_backstop_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_backstop_main "$@"
fi
