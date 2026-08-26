#!/usr/bin/env bash
# redteam-skill-drift-check.sh - detect SKILL.md drift between WSL symlink and Windows canonical.
# Installed 2026-08-22 after v5.1 merge redteam F0/P-1: symlink was replaced by a
# regular file during fm tactical override, killing the structural anti-drift
# guarantee. This check restores observability: symlink broken OR content
# divergence exits nonzero with a machine-readable line.
# Owner: puti. Run from fm session-start or patrol; zero output = healthy.
set -u
LINK="$HOME/.claude/skills/red-team/SKILL.md"
CANON="/mnt/c/Users/westwell/.claude/skills/red-team/SKILL.md"
if [ ! -L "$LINK" ]; then
  echo "redteam-skill-drift: NOT-A-SYMLINK $LINK"
  exit 1
fi
if [ ! -f "$CANON" ]; then
  echo "redteam-skill-drift: CANONICAL-MISSING $CANON"
  exit 2
fi
a="$(sha256sum "$LINK" | cut -d' ' -f1)"
b="$(sha256sum "$CANON" | cut -d' ' -f1)"
if [ "$a" != "$b" ]; then
  echo "redteam-skill-drift: CONTENT-DIVERGED link=$a canon=$b"
  exit 3
fi
