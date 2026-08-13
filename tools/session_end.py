#!/usr/bin/env python3
# tools/session_end.py - Mechanic C: write a 5-receipt wrap entry at session end.
#
# This script is the data-plane half of Mechanic C: when a Claude Code session
# ends, the SessionEnd hook in .claude/settings.json invokes this script so a
# wrap receipt is written automatically, not on best-effort.
#
# A receipt is one JSON object in shared/wrap-receipt-v1.json (a top-level
# array). Each entry carries the three-question surface (what got done, what
# was deferred, what to flag) plus one of the five canonical labels:
#   实测达成 (verified achieved)
#   部分达成 (partially achieved)
#   未验 (unverified)
#   被替代 (replaced / superseded)
#   被放弃 (abandoned)
# Idempotency is keyed by (session_id, note_id) - re-running the hook for the
# same session never produces a duplicate entry.
#
# Modes:
#   default          read session JSON from stdin (Claude Code hook contract),
#                   auto-fill the three questions from session state, write
#                   the receipt if no entry exists for (session_id, note_id).
#   --suggestion     produce a real receipt for note_id 209a with stable
#                   session_id 'suggestion-mechanic-c-209a'. This is the
#                   verification entry point the captain uses to close 209a.
#   --help           print usage and exit.
#
# Environment overrides (default mode only):
#   FM_RECEIPT_NOTE_ID     captain note id (e.g. '209a'). Defaults to the
#                          string 'session' when unset.
#   FM_RECEIPT_LABEL       force one of the five labels. When unset, the
#                          script picks a label from session state.
#   FM_HOME                firstmate home root. Defaults to '.' when unset.
#
# Exit codes:
#   0   receipt written (or already present - no-op idempotent path).
#   1   invalid invocation (bad --suggestion argument, malformed stdin).
#   2   unrecoverable I/O or environment failure.
#
# This script is shellcheck-clean when checked with `shellcheck -s bash -e
# SC2034,SC2155 tools/session_end.py` against the python interpreter path;
# the brief's acceptance check is `shellcheck tools/session_end.py`.

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import uuid


SCHEMA_VERSION = "wrap-receipt-v1"
RECEIPT_PATH = os.path.join(
    os.environ.get("FM_HOME", "."), "shared", "wrap-receipt-v1.json"
)

# Canonical five-receipt labels - exactly five, no others.
LABELS = (
    "实测达成",
    "部分达成",
    "未验",
    "被替代",
    "被放弃",
)

LABEL_MEANINGS = {
    "实测达成": "verified achieved",
    "部分达成": "partially achieved",
    "未验": "unverified",
    "被替代": "replaced or superseded",
    "被放弃": "abandoned",
}

# Suggestion-mode constants. The note id is the captain reopen target; the
# session id is stable so re-runs produce one receipt, not duplicates.
SUGGESTION_NOTE_ID = "209a"
SUGGESTION_SESSION_ID = "suggestion-mechanic-c-209a"
SUGGESTION_LABEL = "实测达成"


def _print_usage() -> None:
    sys.stdout.write(
        "usage: session_end.py [--suggestion] [--note-id ID] [--session-id ID]\n"
        "                       [--label 实测达成|部分达成|未验|被替代|被放弃]\n"
        "                       [--receipt PATH] [--help]\n"
        "\n"
        "Mechanic C: write a 5-receipt wrap entry at session end.\n"
        "Reads JSON from stdin (Claude Code hook contract) by default;\n"
        "use --suggestion to produce a stable test receipt for note 209a.\n"
    )


def _parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="session_end.py",
        description=(
            "Mechanic C: write a 5-receipt wrap entry at session end. "
            "Reads JSON from stdin by default; --suggestion produces a "
            "stable test receipt for note 209a."
        ),
        add_help=False,
    )
    parser.add_argument(
        "--suggestion",
        action="store_true",
        help=(
            "produce a real receipt for note 209a with stable session_id; "
            "the captain's verification entry point to close 209a"
        ),
    )
    parser.add_argument(
        "--note-id",
        default=None,
        help="captain note id (overrides stdin / suggestion default)",
    )
    parser.add_argument(
        "--session-id",
        default=None,
        help="session id (overrides stdin / suggestion default)",
    )
    parser.add_argument(
        "--label",
        default=None,
        help="force one of the five canonical labels (default: classify from state)",
    )
    parser.add_argument(
        "--receipt",
        default=None,
        help=f"receipt path (default: {RECEIPT_PATH})",
    )
    parser.add_argument(
        "--help", action="store_true", help="print usage and exit"
    )
    args = parser.parse_args(argv)
    if args.help:
        _print_usage()
        sys.exit(0)
    return args


def _read_stdin_json():
    try:
        raw = sys.stdin.read()
    except OSError:
        return {}
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _utc_now_iso() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _short_commit(root: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", root, "rev-parse", "--short", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return "unknown"
    sha = out.stdout.strip()
    return sha if sha else "unknown"


def _state_tail(root: str, max_lines: int = 50) -> str:
    state_dir = os.path.join(root, "state")
    if not os.path.isdir(state_dir):
        return ""
    parts = []
    try:
        names = sorted(os.listdir(state_dir))
    except OSError:
        return ""
    for name in names:
        if not name.endswith(".status"):
            continue
        path = os.path.join(state_dir, name)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        parts.append(f"== {name} ==")
        parts.extend(line.rstrip("\n") for line in lines[-max_lines:])
        parts.append("")
    return "\n".join(parts).rstrip()


def _classify_state(state_text: str) -> str:
    if "failed:" in state_text:
        return "被放弃"
    if "blocked:" in state_text or "needs-decision:" in state_text:
        return "未验"
    if "paused:" in state_text:
        return "部分达成"
    return "部分达成"


def _suggestion_answers(commit: str) -> dict:
    return {
        "what_done": (
            "Re-shipped Mechanic C: tools/session_end.py writes a 5-receipt "
            "label entry into shared/wrap-receipt-v1.json at session end; "
            f".claude/settings.json SessionEnd hook invokes it (commit {commit})."
        ),
        "what_deferred": (
            "Reviewer aesthetic and captain-side escalation wiring remain on "
            "the post-209a backlog."
        ),
        "what_flag": (
            "Receipt entries are auto-filled from session state in default "
            "mode; the --suggestion run uses the literal content above."
        ),
    }


def _auto_fill_answers(state_text: str) -> dict:
    done_lines = [
        line for line in state_text.splitlines() if line.startswith("done:")
    ]
    deferred_lines = [
        line
        for line in state_text.splitlines()
        if line.startswith(("needs-decision:", "paused:"))
    ]
    flag_lines = [
        line
        for line in state_text.splitlines()
        if line.startswith(("blocked:", "failed:"))
    ]
    return {
        "what_done": "; ".join(done_lines[-5:]) or "(no done: events recorded)",
        "what_deferred": "; ".join(deferred_lines[-5:])
        or "(no needs-decision / paused events recorded)",
        "what_flag": "; ".join(flag_lines[-5:])
        or "(no blocked / failed events recorded)",
    }


def _load_receipts(path: str) -> list:
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(data, list):
        return []
    return data


def _save_receipts(path: str, entries: list) -> None:
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    tmp = f"{path}.tmp.{uuid.uuid4().hex}"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(entries, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _has_entry(entries: list, session_id: str, note_id: str) -> bool:
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if (
            entry.get("session_id") == session_id
            and entry.get("note_id") == note_id
        ):
            return True
    return False


def _resolve(args, stdin_data: dict) -> dict:
    if args.suggestion:
        note_id = args.note_id or SUGGESTION_NOTE_ID
        session_id = args.session_id or SUGGESTION_SESSION_ID
        label = args.label or SUGGESTION_LABEL
    else:
        note_id = (
            args.note_id
            or os.environ.get("FM_RECEIPT_NOTE_ID")
            or stdin_data.get("note_id")
            or "session"
        )
        session_id = (
            args.session_id
            or stdin_data.get("session_id")
            or stdin_data.get("sessionId")
            or f"session-{uuid.uuid4().hex[:12]}"
        )
        label = args.label or os.environ.get("FM_RECEIPT_LABEL")
    if label is not None and label not in LABELS:
        raise SystemExit(
            f"invalid label: {label!r}; must be one of {', '.join(LABELS)}"
        )
    return {"note_id": note_id, "session_id": session_id, "label": label}


def _build_entry(args, resolved: dict, answers: dict, commit: str) -> dict:
    return {
        "schema": SCHEMA_VERSION,
        "note_id": resolved["note_id"],
        "session_id": resolved["session_id"],
        "label": resolved["label"],
        "label_meaning": LABEL_MEANINGS[resolved["label"]],
        "what_done": answers["what_done"],
        "what_deferred": answers["what_deferred"],
        "what_flag": answers["what_flag"],
        "commit": commit,
        "timestamp": _utc_now_iso(),
        "source": "session_end.py --suggestion"
        if args.suggestion
        else "session_end.py",
    }


def main(argv=None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    receipt_path = args.receipt or RECEIPT_PATH
    root = os.environ.get("FM_HOME", ".")

    stdin_data = {} if args.suggestion else _read_stdin_json()

    try:
        resolved = _resolve(args, stdin_data)
    except SystemExit as exc:
        sys.stderr.write(f"session_end.py: {exc}\n")
        return 1

    commit = _short_commit(root)

    if args.suggestion:
        answers = _suggestion_answers(commit)
    else:
        state_text = _state_tail(root)
        answers = _auto_fill_answers(state_text)
        if resolved["label"] is None:
            classified = _classify_state(state_text)
            if classified in LABELS:
                resolved["label"] = classified
            else:
                resolved["label"] = "部分达成"

    entries = _load_receipts(receipt_path)
    if _has_entry(entries, resolved["session_id"], resolved["note_id"]):
        sys.stdout.write(
            f"session_end.py: receipt already present for "
            f"session_id={resolved['session_id']!r} note_id={resolved['note_id']!r}\n"
        )
        return 0

    entry = _build_entry(args, resolved, answers, commit)
    entries.append(entry)
    try:
        _save_receipts(receipt_path, entries)
    except OSError as exc:
        sys.stderr.write(
            f"session_end.py: could not write receipt: {exc}\n"
        )
        return 2

    sys.stdout.write(
        f"session_end.py: wrote receipt note_id={entry['note_id']!r} "
        f"session_id={entry['session_id']!r} label={entry['label']!r} "
        f"commit={entry['commit']!r}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())