# Learnings

> Append-only guardrails the agent discovers while working on this repo.
> Read this before each turn; add new gotchas you hit (one bullet per line).
> A planner turn prunes stale entries periodically. The loop never depends on
> this file — it is advisory memory, not state.

- _(example)_ `npm test` must run from the repo root; a nested cwd makes it red.
- T0.1: Baseline confirmed — `bash test/selftest.sh` passes 19/19 (13 turn classification, 1 sanitizer, 1 agnosticism, 4 end-to-end).
