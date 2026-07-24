# Learnings

> Append-only guardrails the agent discovers while working on this repo.
> Read this before each turn; add new gotchas you hit (one bullet per line).
> A planner turn prunes stale entries periodically. The loop never depends on
> this file — it is advisory memory, not state.

- _(example)_ `npm test` must run from the repo root; a nested cwd makes it red.
- T0.1: Baseline confirmed — `bash test/selftest.sh` passes 19/19 (13 turn classification, 1 sanitizer, 1 agnosticism, 4 end-to-end).
- T0.2: Parity audit complete — ZERO gaps found. All old-loop behaviors are present in ratchet (security hardening + enhancements are additive). No Milestone 3 tasks needed.
- T1.1: Added `tracker_next_tag` function + 7 selftest cases. Selftest now passes 26/26 (12 turn classification, 1 deadline, 7 tracker tag extraction, 1 sanitizer, 1 agnosticism, 4 end-to-end).
