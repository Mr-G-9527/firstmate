#!/usr/bin/env bash
# fm-captain-wake-drain.sh - the /fm-wake entrypoint for the chat-router demo.
#
# Goal: restore one safe, verified captain->fm wake path:
#   Windows stdin -> fm-captain-inbox-append.sh --kind chat --corr <id> --json
#   -> literal /fm-wake into state/.primary-pane
#   -> this script drains inbox -> fm writes captain-outbox terminal row.
#
# Hard rules (chat-router demo):
#   - MUST NOT inject arbitrary captain body content through tmux. The chat-
#     router types only the literal "/fm-wake" into the explicit primary pane;
#     inbox body stays in state/captain-inbox.jsonl.
#   - Primary pane is read from state/.primary-pane; no default fallback.
#     If the metadata file is missing or malformed, fail closed (exit 2).
#   - No polling loop, no body capture, no body echo.
#   - Delegates to fm-captain-inbox-drain.sh which owns flock, print-before-
#     commit, idempotent received ack. Never duplicate those guarantees.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve STATE using the same precedence as fm-wake-lib.sh
# (FM_STATE_OVERRIDE -> STATE env -> $FM_HOME/state).
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
PANE_META="$STATE/.primary-pane"

# Require explicit primary-pane metadata; refuse to run without it.
# No default fallback: "tmux send-keys -t :" or "-t default" would silently
# route to a focused/unrelated pane and is therefore forbidden here.
[ -f "$PANE_META" ] || {
  echo "fm-captain-wake-drain: missing primary-pane metadata at $PANE_META (no default fallback)" >&2
  exit 2
}

# Source the metadata file (bash key=value form).
# shellcheck disable=SC1090
. "$PANE_META"

# Defensive shape check: every field must be present and non-empty.
missing=
for v in PRIMARY_SESSION PRIMARY_WINDOW PRIMARY_PANE; do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    missing="$missing $v"
  fi
done
if [ -n "$missing" ]; then
  echo "fm-captain-wake-drain: empty/missing fields in $PANE_META:$missing" >&2
  exit 2
fi

# Delegate. fm-captain-inbox-drain.sh owns the inbox->render->ack contract;
# print-before-commit guarantees idempotency on crash (re-drain is duplicate,
# never loss).
exec "$SCRIPT_DIR/fm-captain-inbox-drain.sh"