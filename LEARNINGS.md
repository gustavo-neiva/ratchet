# Learnings

> Append-only guardrails the agent discovers while working on this repo.
> Read this before each turn; add new gotchas you hit (one bullet per line).
> A planner turn prunes stale entries periodically. The loop never depends on
> this file — it is advisory memory, not state.

- `grep -c` returns "0" AND exits 1 on no match — `|| echo 0` appends a second 0, breaking arithmetic. Use `n=$(grep -c ...); n=${n:-0}` instead (see tracker.sh:61 comment).
- `cmd_status` node derivation: a `merge-wait` line with `state=MERGED` or `state=CLOSED` means the wait RESOLVED — only `state=OPEN` is an active wait. Matching any `*merge-wait*` line as node=merge-wait made a just-merged PR still show "waiting". Gate the case on `*merge-wait*state=OPEN*`; resolved lines collapse to build.
- DRIFT (unfixed): `PR_SOFT_MAX_LINES` default in `bin/ratchet:211-212` is `800`, but PLAN.md spec (T1.3/T5.3) and all docs (README + templates/ratchet.conf.example) say `400`. Docs match the plan; the code default is wrong. Fix the code default to 400 in a code task (not docs).
