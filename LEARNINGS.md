# Learnings

> Append-only guardrails the agent discovers while working on this repo.
> Read this before each turn; add new gotchas you hit (one bullet per line).
> A planner turn prunes stale entries periodically. The loop never depends on
> this file — it is advisory memory, not state.

- _(example)_ `npm test` must run from the repo root; a nested cwd makes it red.
- **Task IDs:** Never wrap IDs in bold/italic markdown (`**T1.2**` breaks parser). Use plain `T1.2`, `A1`, or `N-slug`. Causes "task id unresolved" warning and `task=?` on all turns.
- **Boolean shell funcs:** `builtin_secret_scan`/`conf_tampered` return 0=hit/block. Any early-out must `return 1` (clean), never `return 0` — an empty-diff `return 0` false-blocks every no-op turn with an empty reason and dead-loops the task.
## auto-captured
[2026-08-05 00:42:45]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T03:42:45Z
## auto-captured
[2026-08-05 00:54:42]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T03:54:42Z
## auto-captured
[2026-08-05 01:35:22]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T04:35:22Z

[baseline] loop/human split baseline: selftest 207/207 green (anchoring additive, zero-regression invariant for M2 deletions)
## auto-captured
[2026-08-05 11:51:32]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T14:51:33Z
## auto-captured
[2026-08-05 11:52:36]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T14:52:36Z
## auto-captured
[2026-08-05 12:01:58]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T15:01:58Z
## auto-captured
[2026-08-05 12:48:36]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T15:48:36Z
## auto-captured
[2026-08-05 13:08:07]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T16:08:07Z
## auto-captured
[2026-08-05 13:39:29]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T16:39:29Z
## auto-captured
[2026-08-05 18:15:27]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T21:15:27Z
## auto-captured
[2026-08-05 18:16:35]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T21:16:35Z
## auto-captured
[2026-08-05 18:19:45]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T21:19:45Z
## auto-captured
[2026-08-05 18:21:24]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T21:21:24Z
## auto-captured
[2026-08-05 18:25:52]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-05T21:25:52Z
## auto-captured
[2026-08-07 17:05:03]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-07T20:05:03Z
## auto-captured
[2026-08-07 19:42:54]   commit gate RED — NOT committing; leaving work for next turn to repair.  # 2026-08-07T22:42:54Z
