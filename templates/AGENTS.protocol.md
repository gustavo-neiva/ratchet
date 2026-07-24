<!-- ratchet-protocol:v1:begin (managed by `ratchet init`; edit OUTSIDE the markers) -->
## Autonomous loop protocol

You are driven one turn at a time by an outer loop (`ratchet`). Each turn you do
exactly ONE discrete step of work, then hand control back.

1. Read `{{TRACKER_FILE}}` and find the `[IN PROGRESS]` task; if none, take the
   first `[ ]` (open) task. That is your work for this turn.
2. If the verify command (`{{VERIFY_CMD}}`) is currently RED, **fixing that red
   gate IS your task this turn** — nothing else ships until the tree is green.
3. Do ONE task only. Keep outputs in files; do not echo large content into your
   reply.
4. Read `LEARNINGS.md` before working; append any new gotcha you hit.
5. When the step is complete: tick the finished task `[x]`, mark the next task
   `[IN PROGRESS]`, and print the token `{{STEP_TOKEN}}` on its own line.
6. If there is absolutely no remaining open task, print the token `{{DONE_TOKEN}}` on its
   own line instead.
7. Do NOT run `git commit` / `git push` — the loop owns the commit and gates it
   on green. Do NOT edit `.ratchet.conf` (the loop will reject the turn).

Tracker grammar: status `[ ]` open · `[IN PROGRESS]` · `[x]` done, plus an
optional id and optional tags `(trivial|normal|hard)` and/or `serial`. Example:
`- [ ] T1.2 (normal, serial) design the schema`.

## Fanout strategy (hard tasks only)

When `RATCHET_FANOUT != off` and your current task is tagged `(hard)`:

1. **Scout** (≤3 read-only subagents on `$RATCHET_SCOUT_MODELS`): spawn scouts to
   map blast radius, find reuse patterns, and assess coverage. Scouts read only.
2. **Implement**: YOU write the ONE implementation — subagents advise, you decide.
3. **Review** (if `RATCHET_FANOUT=scout+review`, ≤2 advisory reviewers): spawn
   reviewers to critique your implementation. Reviewers advise, YOU decide whether
   to revise. The green gate (`{{VERIFY_CMD}}`) is the only real gate.

**Subagents never run git commands** — only ratchet commits.
<!-- ratchet-protocol:v1:end -->

## Project notes

<!-- Add per-project rules, glossary, and conventions BELOW this line. Anything
     above, inside the markers, is managed by `ratchet init` and will be
     re-stamped on upgrade. -->
