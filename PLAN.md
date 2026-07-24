# PLAN.md — ratchet builds ratchet: tiered model routing (v1.1)

Tracker grammar: `[ ]` open → `[IN PROGRESS]` → `[x]` done.
Tags: `(trivial|normal|hard)` and `(serial)`.

## Design constraints (read before ANY task — these are non-negotiable)

1. **ZERO regressions.** The old autonomous loop worked; ratchet is its proven
   successor. Every task must keep `bash test/selftest.sh` green (currently
   19/19). New behavior is ONLY active when new config keys are set — with all
   tier keys unset, the loop must behave byte-identically to today (flat
   `MODELS` chain, single `THINKING`).
2. **Additive only.** Do not rename, remove, or change the meaning of any
   existing config key, function, flag, token, or log line format. New keys and
   new functions only.
3. **One task per turn.** Do the task, add/extend its selftest, run
   `bash test/selftest.sh`, mark the task `[x]`, print STEP_COMPLETE.
4. **bash 3.2 compatible** (macOS default): no associative arrays, no
   `${var,,}`, no `mapfile`. Follow the existing style in lib/.
5. Never edit `.ratchet.conf` (agent-forbidden; the commit gate rejects it).
6. Discovered gotchas go in LEARNINGS.md (append-only).

## The feature: tiered model routing

Three model tiers, each an independent fallback chain with its own thinking
level. Route each turn by the tag of the next actionable task:

| Tier | Config keys | Used for | Example |
|---|---|---|---|
| PLAN  | `PLAN_MODELS`, `THINKING_PLAN`   | plan-drafting turns only (`ratchet plan`, `ratchet new`) | `anthropic/claude-fable-5,anthropic/claude-opus-4-8` |
| BUILD | `BUILD_MODELS`, `THINKING_BUILD` | `normal` and `hard` tasks (heavy lifting) | `anthropic/claude-sonnet-4-5,zai/glm-5.2` |
| LIGHT | `LIGHT_MODELS`, `THINKING_LIGHT` | `trivial` tasks (search, data collection, mechanical edits) | `zai/glm-5-turbo,zai/glm-4.5-air` with `THINKING_LIGHT=off` |

Fallback semantics (conservative): any tier key unset → that tier falls back to
the flat `MODELS` chain and global `THINKING`. Tier chain fully benched → fall
back to `MODELS` before sleeping `BOTH_WAIT`. `hard` tasks use the BUILD chain
but bump thinking one notch above `THINKING_BUILD` (max `high`) unless
`THINKING_BUILD` is explicitly set.

## Milestone 0 — safety net first (serial)

- [ ] T0.1 (trivial, serial) Baseline check: run `bash test/selftest.sh` and confirm 19/19 pass. Fix nothing else. Record the count in LEARNINGS.md.
- [ ] T0.2 (normal, serial) Parity audit: read `/Users/gustavo-neiva/Code/archive/pi-autoloop/autonomous_loop.sh` (the battle-tested predecessor) and compare its behaviors against ratchet's lib/*.sh. Write `docs/parity-audit.md` listing every old-loop behavior and its ratchet equivalent (or "MISSING"). Do NOT change any code. If anything is genuinely missing, append a new `[ ]` task for it under Milestone 3 in this file.

## Milestone 1 — tiered routing engine (serial: all tasks touch shared files)

- [ ] T1.1 (normal, serial) `lib/tracker.sh`: add `tracker_next_tag` — echo the tag (`trivial|normal|hard`) of the first `[IN PROGRESS]` task, else the first `[ ]` task; echo `normal` when untagged or no task. Pure addition; do not modify existing functions. Add selftest cases: tagged trivial, tagged hard, untagged, empty tracker.
- [ ] T1.2 (normal, serial) `lib/contract.sh` + `lib/common.sh`: add the six keys `PLAN_MODELS BUILD_MODELS LIGHT_MODELS THINKING_PLAN THINKING_BUILD THINKING_LIGHT` to `CONTRACT_KEYS` and as empty-string defaults in common.sh (commented like the neighbors). Add selftest: a conf file with `LIGHT_MODELS="a/b"` parses; an unknown key still errors.
- [ ] T1.3 (hard, serial) `lib/model-fallback.sh`: add `chain_for_tier TIER` — echo the effective chain for `plan|build|light` with the fallback semantics from the design table (unset tier → `$MODELS`). Add `thinking_for_tier TIER` with the same fallback (including the `hard`-bump rule handled by the caller passing tier `build-hard` → one notch above `THINKING_BUILD`, capped at `high`, only when `THINKING_BUILD` is empty use global `THINKING` untouched). Keep `init_models` working unchanged when called with `$MODELS`. Add selftest cases: unset tiers → flat chain; set tiers → correct chain; ALLOWED_PROVIDERS still filters tier chains.
- [ ] T1.4 (hard, serial) `bin/ratchet` run loop: before each turn, call `tracker_next_tag`, map tag→tier (`trivial`→light, `normal`→build, `hard`→build with thinking bump), re-`init_models "$(chain_for_tier …)"` ONLY when the tier changed since the last turn (preserve bench/cooldown state within a tier), and pass the tier thinking to `run_turn`. When the tier chain is fully benched, fall back to `init_models "$MODELS"` for that turn before ever sleeping `BOTH_WAIT`. Log one line per turn: `turn N | tier=build | model=X | thinking=Y` (keep the existing turn log line too — additive). With all tier keys unset the loop must select exactly what it selects today; add an end-to-end selftest with the fake agent proving (a) unset keys → old behavior, (b) a `(trivial)` task routes to `LIGHT_MODELS`.
- [ ] T1.5 (normal, serial) `ratchet doctor`: print the three effective tier chains and thinking levels (or "→ MODELS (flat)" when unset). Warn (not fail) when `LIGHT_MODELS` is set but `THINKING_LIGHT` is not `off` (cheap tier should not reason). Add selftest for the warning.

## Milestone 2 — plan turns on existing repos (serial)

- [ ] T2.1 (hard, serial) `ratchet plan [REPO]` command: run ONE turn using the PLAN tier (chain_for_tier plan) with a plan-drafting prompt: read the repo, read PLAN.md, draft/refresh open tasks (Milestone-0-walking-skeleton rule, tags on every task), then STOP with a loud "HUMAN: review PLAN.md before running". Never auto-runs the loop after. Reuse the plan-turn machinery from `ratchet new` (extract shared function if needed — smallest possible refactor). Selftest with fake agent: `plan` invokes exactly one turn and does not commit code changes outside PLAN.md/LEARNINGS.md.
- [ ] T2.2 (trivial, serial) `ratchet stats`: extend to count turns per tier and per model from the new `tier=` log lines (old logs without tier lines must not break stats). Selftest: stats on a fixture log with and without tier lines.

## Milestone 3 — docs + parity follow-ups (parallel-safe)

- [ ] T3.1 (trivial) README.md: add a "Tiered model routing" section with the design table above and a copy-paste `.ratchet.conf` example (fable/opus plan, sonnet/glm build, glm-turbo light with thinking off).
- [ ] T3.2 (trivial) CHANGELOG.md: add v1.1 entry (tiered routing, `ratchet plan`, tier stats, parity audit).
- [ ] T3.3 (trivial) templates: add the six commented tier keys to the `.ratchet.conf` template stamped by `ratchet init`.
- (T0.2 may append parity-gap tasks here.)

## Done means

`bash test/selftest.sh` green with ALL new cases; unset tier keys ≡ today's
behavior; `(trivial)` tasks provably run on the light chain; `ratchet plan`
drafts and stops for human review.
