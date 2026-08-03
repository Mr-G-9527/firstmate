# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.
When work, a process-event source, or X-mode relay polling needs supervision at that boundary and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
The mid-turn pull warning uses the model-aware supervision verdict described below, while the turn-end guard keeps the PID-strict watcher predicate.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Guard predicates

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.
An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
Registered `state/procevent/*.source` records also require supervision even though they have no task metadata.
The default cross-harness mode exits silently with no supervision need.
Every mode treats `state/x-watch.check.sh` as supervision need, so X-mode relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same PID-strict identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`: a stale beacon blocks even when a watcher pid is live, and a fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.
The turn-end guard needs that strict check because it fires at the turn boundary, where the auto-arm is bringing a fresh watcher up for the upcoming idle period, and it cooperates with that arm rather than trusting a beacon left by the cycle that just ended.
`bin/fm-guard.sh`, the pull warning, instead uses the model-aware `fm_watcher_supervision_verdict` from the same library, because it fires mid-turn when the auto-arm model runs no watcher at all.
Under the Claude Stop auto-arm model a beacon fresh within grace is healthy even with no live watcher process, and only a beacon stale beyond grace (or absent) alarms.
Under every persistent-watcher harness a live identity-matched watcher with a fresh beacon is still required, so the pull guard keeps the same strict semantics there.
Its banner names the true failing condition, either a missing live watcher process or a genuinely stale beacon with its real age, and keys the once-per-episode dedup on that condition rather than the beacon mtime.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live `autoarm` role owner whose eventual failure must exit 2, or `state/.claude-autoarm-epoch` contains a fresh actionable rewake owned by this event epoch.
Fresh `failed` and `failed-suppressed` outcomes enter or advance the failure progression instead of acting as unconditional recovery proof.
The auto-arm itself rechecks the healthy watcher predicate and retries a bounded number of times before reporting a genuine failure.
The first fresh exhausted-failure epoch preserves its handoff without consuming a blocked-stop count, while later fresh failed epochs advance the same monotonic progression instead of resetting it.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override).
In Claude mode, positive watcher recovery clears the block budget, failure notice, and attended alarm together under the existing budget lock before either hook reports ordinary recovery.
The one loud attended fail-open is available only when the auto-arm has recorded an exhausted failure, its one notice is already consumed, the block budget is exhausted, and a final check finds neither a healthy watcher nor an automatic continuation.
Each epoch identity is accounted at most once under the budget lock.
Whenever both coordination locks are needed, positive auto-arm recovery and the terminal check acquire the auto-arm owner lock before the budget lock.
After that alarm, the Stop auto-arm suppresses further exit-2 continuations until positive watcher recovery, so the final fail-open remains reachable.
The alarm cannot repeat during that failure episode, and a later unhealthy stop blocks again.
A positively verified healthy watcher clears the failure notice, alarm, and block budget for a future independent episode.
A Claude failure notice describes the automatic mechanism as broken and does not direct a routine manual background arm.

OpenCode, Pi, and pi-signed expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session but schedule one bounded follow-up when the predicate blocks.
The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each passive adapter owns a loop latch.
Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

Grok makes exactly one typed capability decision from each running Stop payload.
A boolean `stopHookActive` selects native blocking, including both false on the initial stop and true on the bounded continuation.
The camel-case field has precedence when both spellings appear; when it is absent, a boolean `stop_hook_active` selects the same native path for compatibility.
The native path returns the shared guard's status and stderr to the same Grok process and never starts `grok --resume`.
When both capability spellings are absent, the adapter preserves one pre-native `grok --resume` fallback guarded by `GROK_TURNEND_GUARD_ACTIVE` and intentionally omits `--permission-mode`.
Malformed JSON, a selected field with a non-boolean type, missing `jq`, missing hook prerequisites, or an already-active legacy guard allows the stop without starting either continuation path.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`; genuine pre-native builds can run the same tracked hook from an isolated global hook directory.

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; an idle secondmate endpoint with no X-mode relay poll remains healthy because it has no supervision need.
- The direct-blocking and bounded passive-follow-up split is limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Wake backstop for the daemon+argv session topology

Empirical record (2026-08-03, same machine, same Claude Code 2.1.220, same hook shape; one variable changed - the session topology):

- A bare interactive `claude` from a tmux pane receives `asyncRewake` after a Stop-hook exit 2.
- A firstmate primary under `claude -> claude.exe daemon run --origin transient -> bg-pty-host -> claude.exe --session-id ... -- <prompt>` does NOT. The prompt arrives via `argv` and there is no attached input surface for the rewake to inject into.
- Background Bash task completions DO re-invoke the same idle primary (observed 2/2). The proven delivery branch is therefore "a bash subprocess completes", not "asyncRewake fires".

Consequence: a primary that goes idle while a wake is in flight stays silent indefinitely. `bin/fm-claude-stop-autoarm.sh` writes `outcome=rewake` into `state/.claude-autoarm-epoch`; nothing on the firstmate side then re-evaluates anything once the turn has ended. The watcher closes that gap.

### Shape (chosen to keep ownership clean)

- The already-running watcher is the one armed supervision cycle. The backstop is NOT a second cycle. The watcher calls `bin/fm-watch-backstop.sh should-fire` at the start of every cycle; on a 1 verdict it calls `bin/fm-watch-backstop.sh fire`, which spawns a detached `inject` bash task via `setsid + &`. The watcher's own loop is never blocked.
- The detached bash task (the delivery plumbing, not an arm): re-checks `state/.claude-autoarm-epoch` for `outcome=rewake`, reads `state/.wake-queue` for the undelivered rewake row, consumes that row under the same lock `bin/fm-wake-drain.sh` uses, encodes the payload with the canonical watcher-kind operational-input envelope (`bin/fm-operational-input.sh`), resolves the supervisor pane through the same discovery the away-mode daemon uses (`bin/fm-supervisor-target-lib.sh`), and types it via `bin/fm-backend.sh`'s `fm_backend_send_text_submit` (the same primitive `bin/fm-supervise-daemon.sh`'s `inject_msg` uses). On confirmed delivery the epoch is rewritten with `outcome=consumed` so the watcher stops re-firing for the same rewake.

`asyncRewake` is retained as the opportunistic fast path. The backstop is the second line of defense, not a replacement.

### Design decisions settled before the code was written

- **"Watcher observed the wake was consumed" is bounded by TIMEOUT, not by positive confirmation.** The wake is the only signal that a consume happened, and firstmate can only emit that signal after the rewake has already delivered - so in the failure case the observation never occurs. The backstop is a timer, not an oracle. The default grace is `FM_WATCH_BACKSTOP_GRACE=60` seconds, which clears `FM_CLAUDE_AUTOARM_EPOCH_FRESH` (15s) plus typical background-task notification latency. A value below the synchronous window races `asyncRewake`; a value above leaves the idle session silent for that long. Both are bad, so the default is the one the 2026-08-03 evidence supported.
- **Idempotency is owned by the bash task, not the watcher.** The watcher can only check once at spawn time; the race window between the watcher's spawn and the bash task's inject is owned by the task itself. The task re-checks the epoch TWICE - once after locating the row, once immediately before consuming it - so an `asyncRewake` that lands in the same window aborts the inject cleanly. The watcher never re-fires for the same `updated_at` because the task writes a `.watch-backstop-consumed-<updated_at>` marker on confirmed delivery.
- **Test isolation is fail-closed.** The inject path requires `FM_WATCH_BACKSTOP_CONFIRM_INJECT=1` before it will actually call the backend send primitive. The watcher's `fire` always sets this; a probe that supplies a non-live state must opt in explicitly. A probe that forgets to mock the backend and leaves the confirm flag unset will abort at the gate with a clear log rather than deliver a real wake to the captain. (The 2026-08-03 incident that motivated this change was exactly that mistake: a probe against a scratch state dir with the default `firstmate:0` target.)
- **One supervision cycle is preserved.** `bin/fm-watch-arm.sh` is not called by the backstop. The bash task is delivery plumbing: a child process of the already-armed watcher, never a separate arm. `bin/fm-watch-arm.sh` still exits non-zero on a second arm attempt.

### Operational tuning

- `FM_WATCH_BACKSTOP_GRACE` (default 60) - seconds of `outcome=rewake` survival before the backstop fires. Lowering this races `asyncRewake`; raising it lengthens the silence window.
- `FM_WATCH_BACKSTOP_DISABLE=1` - emergency kill switch. Suppresses the `fire` subcommand entirely; the watcher continues to monitor and absorb.
- `FM_WATCH_BACKSTOP_CONFIRM_INJECT=1` - opt-in gate for the inject's send step. The watcher's `fire` sets this; tests that drive the inject directly must set it themselves with a mocked backend.
- `FM_WATCH_BACKSTOP_BIN` (default `bin/fm-watch-backstop.sh`) - override the helper location. The watcher uses this to allow a hermetic test to point at a stub.

### Constraint self-check

- One supervision cycle - satisfied: the watcher is the cycle; the bash task is delivery plumbing, not an arm.
- Stop-hook ownership not duplicated - satisfied: `bin/fm-turnend-guard.sh` keeps sole ownership of the Stop emit; the backstop only adds a delivery attempt after the preferred one demonstrably failed.
- `AGENTS.md` section 1 - satisfied: this is firstmate shared tracked material; the change ships through the repo's own delivery path (a local-only fast-forward merge), never by firstmate directly.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the live-lock and fresh-beacon guard predicate, the cooperative `--claude` claim wait, monotonic failed-epoch progression, bounded attended fail-open, post-alarm continuation suppression, positive recovery reset, epoch allow, re-block budget, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, Grok native and legacy selection, typed field precedence, malformed input, and exactly-one-path safety.
`tests/fm-guard-stale-banner.test.sh` covers the pull-guard predicate, including the persistent-model fresh-leftover-beacon negative control, the auto-arm model's healthy fresh-beacon-without-a-watcher case and its stale-beacon alarm, the true-reason banner wording, and the reason-keyed episode dedup surviving a beacon mtime change.
`tests/fm-watch-backstop.test.sh` covers the wake-backstop trigger conditions, idempotency re-checks, the paused-defect routing, the `FM_WATCH_BACKSTOP_CONFIRM_INJECT` test-isolation gate, and the `fire` subcommand's confirm-flag pass-through.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
