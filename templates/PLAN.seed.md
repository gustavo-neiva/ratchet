# Plan

> Tracker grammar: status `[ ]` open · `[IN PROGRESS]` · `[x]` done, plus an
> optional id and optional tags `(trivial|normal|hard)` and/or `serial`.
> The loop takes the `[IN PROGRESS]` task, else the first `[ ]`.

## Milestone 0 — Walking skeleton + green gate
> No feature task runs before this milestone is green. The loop's safety model
> (no green, no commit) is bootstrapped right here.

- [ ] T0.1 (trivial) scaffold the project and wire the verify command
- [ ] T0.2 (normal) first end-to-end test is green (`VERIFY_CMD` passes)
- [ ] T0.3 (normal) thinnest end-to-end slice of real value

## Milestone 1 — _(replace with your feature milestones)_
- [ ] T1.1 (normal) _first real task_
- [ ] T1.2 (hard, serial) _a task that must not run in parallel_

## Definition of done
- All tasks `[x]`.
- `VERIFY_CMD` green on a clean checkout.
- _(add your own done-criteria here)_

## Non-goals
- _(explicitly list what is OUT of scope)_
