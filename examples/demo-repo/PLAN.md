# Demo Project Plan

> Tracker grammar: status `[ ]` open · `[IN PROGRESS]` · `[x]` done, plus an
> optional id and optional tags `(trivial|normal|hard)` and/or `serial`.
> The loop takes the `[IN PROGRESS]` task, else the first `[ ]`.

## Milestone 0 — Green gate
> The verify command (`npm test`) must be green before any feature work starts.
> This milestone bootstraps the loop's safety model (no green, no commit).

- [ ] M0.1 (normal) Fix the RED test suite — the multiply function has a bug

## Milestone 1 — Feature: add a power function
- [ ] M1.1 (normal) Add `power(base, exponent)` function to calculator.js
- [ ] M1.2 (normal) Add tests for the power function
- [ ] M1.3 (trivial) Update README.md to document the power function

## Definition of done
- All tasks `[x]`.
- `npm test` passes (all tests green).
