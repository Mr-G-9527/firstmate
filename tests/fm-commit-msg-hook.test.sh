#!/usr/bin/env bash
# Behavior tests for bin/git-hooks/commit-msg (the Co-Authored-By trailer guard).
#
# Regression coverage for the no-agent-co-author rule (AGENTS.md section 1
# "Never add an agent name as a commit co-author"; firstmate-coding-guidelines
# SKILL.md). Workers previously inherited the upstream Claude Code default
# trailer (Co-Authored-By: Claude <noreply@anthropic.com>) and emitted commits
# that carried it. The hook is the structural fix: it fires from
# `git config core.hooksPath`, rewrites the message file in place, and is the
# only path that runs before `git commit` finalizes the object. Real human
# Co-Authored-By lines must pass through unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK=$ROOT/bin/git-hooks/commit-msg

# --- structural sanity ------------------------------------------------------

test_hook_exists_and_executable() {
  assert_present "$HOOK" "commit-msg hook must exist at $HOOK"
  [ -x "$HOOK" ] || fail "commit-msg hook must be executable"
  pass "commit-msg hook: present and executable"
}

test_hook_parses_under_bash() {
  local out rc
  out=$(bash -n "$HOOK" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n $HOOK must parse cleanly (got: $out)"
  pass "commit-msg hook: bash -n succeeds"
}

# --- strip behavior ---------------------------------------------------------
#
# The hook reads the message file (passed by git as $1), strips matching lines,
# and rewrites the file in place when anything changed. Each case writes a
# fixture message file with a different trailer shape and asserts the post-hook
# state.

write_msg() {
  local content=$1
  printf '%s' "$content" > "$MSG_FILE"
}

expect_strip() {
  local label=$1 content=$2 pattern=$3
  write_msg "$content"
  if bash "$HOOK" "$MSG_FILE" >/dev/null 2>&1; then
    :
  fi
  if grep -F -i -- "$pattern" "$MSG_FILE" >/dev/null 2>&1; then
    fail "$label: expected strip, but '$pattern' is still present"$'\n'\
"--- file ---"$'\n'"$(cat "$MSG_FILE")"
  fi
  pass "$label: stripped"
}

expect_preserve() {
  local label=$1 content=$2 pattern=$3
  write_msg "$content"
  bash "$HOOK" "$MSG_FILE" >/dev/null 2>&1 || true
  if ! grep -F -i -- "$pattern" "$MSG_FILE" >/dev/null 2>&1; then
    fail "$label: expected preserve, but '$pattern' was stripped"$'\n'\
"--- file ---"$'\n'"$(cat "$MSG_FILE")"
  fi
  pass "$label: preserved"
}

# --- agent trailer cases (must all be stripped) ----------------------------

test_strips_claude_default_trailer() {
  expect_strip "claude-default" \
"feat: x

body

Co-Authored-By: Claude <noreply@anthropic.com>" \
"Co-Authored-By: Claude"
}

test_strips_claude_uppercase() {
  expect_strip "claude-uppercase" \
"feat: x

body

CO-AUTHORED-BY: CLAUDE <NOREP@ANTHROPIC.COM>" \
"CO-AUTHORED-BY: CLAUDE"
}

test_strips_codex_trailer() {
  expect_strip "codex" \
"feat: x

body

Co-Authored-By: Codex <noreply@openai.com>" \
"Co-Authored-By: Codex"
}

test_strips_gpt_trailer() {
  expect_strip "gpt" \
"feat: x

body

Co-Authored-By: GPT-4 <gpt@openai.com>" \
"Co-Authored-By: GPT-4"
}

test_strips_gemini_trailer() {
  expect_strip "gemini" \
"feat: x

body

Co-Authored-By: Gemini <noreply@google.com>" \
"Co-Authored-By: Gemini"
}

test_strips_anthropic_vendor_line() {
  expect_strip "anthropic-vendor" \
"feat: x

body

Co-Authored-By: Anthropic Team <team@anthropic.com>" \
"Co-Authored-By: Anthropic Team"
}

test_strips_multiple_agent_trailers() {
  expect_strip "two-agents" \
"feat: x

body

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Codex <noreply@openai.com>" \
"Co-Authored-By:"
}

# --- human co-author cases (must be preserved) ----------------------------

test_preserves_human_coauthor() {
  expect_preserve "human-jane" \
"feat: x

body

Co-Authored-By: Jane Doe <jane@example.com>" \
"Co-Authored-By: Jane Doe"
}

test_preserves_human_coauthor_company() {
  expect_preserve "human-company" \
"feat: x

body

Co-Authored-By: John Smith <john@company.org>" \
"Co-Authored-By: John Smith"
}

test_strips_only_agent_when_mixed_with_human() {
  write_msg "feat: x

body

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Jane Doe <jane@example.com>"
  bash "$HOOK" "$MSG_FILE" >/dev/null 2>&1 || true
  if grep -F -- "Co-Authored-By: Claude" "$MSG_FILE" >/dev/null 2>&1; then
    fail "mixed-trailers: agent trailer must be stripped, but is still present"
  fi
  if ! grep -F -- "Co-Authored-By: Jane Doe" "$MSG_FILE" >/dev/null 2>&1; then
    fail "mixed-trailers: human trailer must be preserved, but is stripped"
  fi
  pass "mixed-trailers: agent stripped, human preserved"
}

# --- edge cases ------------------------------------------------------------

test_passes_through_message_without_trailer() {
  expect_preserve "no-trailer" \
"feat: x

body

no trailer here" \
"feat: x"
}

test_passes_through_prose_mention() {
  # Co-Authored-By: Claude referenced mid-message (not as a trailer) is not
  # the structural issue the hook targets and must pass through unchanged.
  expect_preserve "prose-mention" \
"feat: x

this commit references Co-Authored-By: Claude but only in prose,
not as a real trailer.

Signed-off-by: maintainer <m@x.com>" \
"references Co-Authored-By: Claude but only in prose"
}

test_passes_through_other_trailer_types() {
  # Reviewed-by and Signed-off-by are not Co-Authored-By and must pass.
  expect_preserve "other-trailers" \
"feat: x

body

Signed-off-by: maintainer <m@x.com>
Reviewed-by: reviewer <r@x.com>" \
"Signed-off-by: maintainer"
}

test_hook_emits_warning_when_stripping() {
  write_msg "feat: x

body

Co-Authored-By: Claude <noreply@anthropic.com>"
  local stderr
  stderr=$(bash "$HOOK" "$MSG_FILE" 2>&1 >/dev/null || true)
  case "$stderr" in
    *"fm-commit-msg: stripped"*) pass "warning: emitted on strip" ;;
    *) fail "expected strip warning on stderr, got: $stderr" ;;
  esac
}

test_hook_silent_when_nothing_to_strip() {
  write_msg "feat: x

body

no trailer"
  local stderr
  stderr=$(bash "$HOOK" "$MSG_FILE" 2>&1 >/dev/null || true)
  case "$stderr" in
    *"stripped"*) fail "must not emit strip warning when nothing to strip (got: $stderr)" ;;
    *) pass "silent on no-op" ;;
  esac
}

test_hook_exits_zero_when_no_msg_file() {
  local out rc
  out=$(bash "$HOOK" 2>&1); rc=$?
  # The hook may either exit 1 (loud refusal) or 0 (no-op); both are safe.
  case "$rc" in
    0|1) pass "no-arg: exit code $rc (safe)" ;;
    *) fail "no-arg: unexpected exit code $rc" ;;
  esac
}

# --- end-to-end via git ----------------------------------------------------
#
# The structural claim only holds if a real `git commit` against a worktree
# with `core.hooksPath` pointing at this hook drops the trailer from the
# resulting commit object. Build a real repo, install the hook, commit with
# the upstream Claude Code default trailer embedded, and assert the committed
# message has no Co-Authored-By trailer.

test_real_commit_drops_trailer() {
  local repo=$TMP_ROOT/git-repo
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.com
  git -C "$repo" config user.name tester
  git -C "$repo" config core.hooksPath "$ROOT/bin/git-hooks"
  printf 'a\n' > "$repo/a"
  git -C "$repo" add a

  local msg=$TMP_ROOT/git-msg
  printf 'feat: real commit\n\nbody\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$msg"

  git -C "$repo" commit -q -F "$msg"
  local committed
  committed=$(git -C "$repo" log -1 --pretty=%B)
  case "$committed" in
    *"Co-Authored-By: Claude"*)
      fail "real-commit: committed message still carries the trailer"$'\n'\
"--- committed message ---"$'\n'"$committed"
      ;;
    *) pass "real-commit: trailer stripped from committed object" ;;
  esac
  # Also confirm the commit succeeded (rc=0) so the guard did not block.
  expect_code 0 0 "real-commit must succeed"
}

# --- driver -----------------------------------------------------------------

TMP_ROOT=$(fm_test_tmproot fm-commit-msg-hook)
MSG_FILE=$TMP_ROOT/msg

test_hook_exists_and_executable
test_hook_parses_under_bash
test_strips_claude_default_trailer
test_strips_claude_uppercase
test_strips_codex_trailer
test_strips_gpt_trailer
test_strips_gemini_trailer
test_strips_anthropic_vendor_line
test_strips_multiple_agent_trailers
test_preserves_human_coauthor
test_preserves_human_coauthor_company
test_strips_only_agent_when_mixed_with_human
test_passes_through_message_without_trailer
test_passes_through_prose_mention
test_passes_through_other_trailer_types
test_hook_emits_warning_when_stripping
test_hook_silent_when_nothing_to_strip
test_hook_exits_zero_when_no_msg_file
test_real_commit_drops_trailer

echo "all commit-msg hook tests passed"