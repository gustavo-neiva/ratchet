# Agent context

## Loop vs interactive

The headless `ratchet` loop briefs its own turns via the harness prompt — it
never sees this file. If you're working in a human-led session (`RATCHET_LOOP`
is unset), work normally: make as many edits as needed, run the tests, commit
when ready. The human owns the git history.

## What this repo is

Ratchet is a task-agnostic bash harness for autonomous loops. The engine in
`lib/` and `bin/` holds ZERO project knowledge. The 4 contract files carry it:
- **PLAN.md** (or configured tracker): the task roadmap
- **LEARNINGS.md**: mistakes, gotchas, non-obvious behavior
- **.ratchet.conf**: verify command, tokens, tier models
- **AGENTS.md** (this file): human-facing guidance

This repo dogfoods itself: PLAN.md is the tracker, `bash test/selftest.sh` is
the green gate.

## How to work here

1. Run `ratchet selftest` (or `bash test/selftest.sh`) before marking work done.
2. Add a selftest case with every non-trivial logic change.
3. **Bash 3.2 only** — no assoc arrays, no `mapfile`, no `timeout`.
4. **Agnosticism invariant**: lib/bin/templates contain ZERO project tool names
   (`npm`/`pytest`/`cargo`/`rspec`/`go test`). Selftest greps for violations.
5. **loop.log line formats are frozen** (additive only) — `stats`/`status` parse
   them; never rename/reorder an emitted line.
6. Read **LEARNINGS.md** before working — the repo's mistake ledger.
7. Author plans via the `ratchet-plan` skill (skills/ratchet-plan/SKILL.md).

## Gotchas

- **Never edit `.ratchet.conf`** — the loop rejects turns that touch it.
- **Never bold-wrap a task ID** in PLAN.md — the tracker parser breaks.
- **Boolean shell functions return 0=hit** (success) — early-out must `return 1`.
- **No new dependencies** for the loop core — `python3` is optional (stats only),
  `jq` is optional (watch).
- When confused about a contract file, run `ratchet doctor .` — it validates the
  4 files and explains what's wrong.
