---
description: Drain firstmate wake queue + captain inbox, handle captain messages
---

Run `bash bin/fm-captain-wake-drain.sh`. This drains the firstmate wake queue and any pending captain inbox messages, printing them to stdout.

Handle any `=== FIRSTMATE CAPTAIN INPUT v1 corr=<corr> kind=<kind> seq=<seq> ===` blocks surfaced as captain instructions:
- Read the `corr` / `kind` / `seq` header.
- The line after the header is the body as a JSON string; JSON-parse it to get the real (possibly multi-line) body.
- `kind` is one of: `chat` (free-form instruction), `authorize` (grant discard/merge/destructive authority), `decision-reply` (answer to a needs-decision you raised), `cancel-request` (cancel pending unstarted work or pause/reconcile an active worker — never discard/kill/teardown).
- Act on the captain's message.

When you finish acting on a message (or hit a terminal outcome), append one row to `state/captain-outbox.jsonl` with the matching `corr` and `seq`.

**Do NOT use `printf '...' >> state/captain-outbox.jsonl` directly.** Always route through the shared helper, which holds the flock that prevents the row 17-style "two JSON objects glued without a newline" corruption:

```bash
bash bin/fm-captain-outbox-append.sh \
  --corr "$CORR" \
  --state "done" \
  --text "PR X ready, decide whether to merge" \
  --seq "$CURRENT_CAPTAIN_SEQ"
```

The helper accepts either structured args (above) or a prebuilt `--json '<row>'` body. It rejects multi-line bodies, validates the row is single-line JSON, and serializes every append on `state/.captain-outbox.lock`.

Allowed `state` values: `done | blocked | rejected | needs-decision | accepted`.
`text` must be captain-facing outcomes ("PR X ready, decide whether to merge"), never internal mechanics (wake/watcher/seq/pane-id).
`state=needs-decision` if you need captain/user input.

### Enrolled review jobs (report_research)

When acting on a captain message whose task is an enrolled review job (task_type=report_research), final completion must emit a hash-bound submission instead of a free-form `done` row. Call the submission helper:

`bash bin/fm-review-submit.sh --corr "$CORR" --reply-to-seq "$CURRENT_CAPTAIN_SEQ" --artifact "$REPORT_PATH"`

- `$CORR` is the enrolled job corr.
- `$CURRENT_CAPTAIN_SEQ` is the seq of the captain inbox message you are completing.
- `$REPORT_PATH` is the absolute path to your report artifact under `data/`.
- The helper computes SHA-256, dedups, appends a `kind=report-submission` `done` row to `state/captain-outbox.jsonl`, and best-effort pushes it.
- Do NOT also append a plain `done` row for the same corr+seq.
- Do NOT add heartbeat, `ROUND`, or `FINAL` files — the controller infers nothing from mtime; only the helper event marks completion.

Idempotency: if a `corr+seq` you already actioned resurfaces (duplicate after a crash), check `state/captain-outbox.jsonl` for a prior terminal result with that corr; if present, do not re-act — just acknowledge the duplicate.

If no inbox messages are surfaced (empty render), no chat response is needed — just stop.
