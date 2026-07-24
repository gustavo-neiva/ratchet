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

- [x] T0.1 (trivial, serial) Baseline check: run `bash test/selftest.sh` and confirm 19/19 pass. Fix nothing else. Record the count in LEARNINGS.md.
- [x] T0.2 (normal, serial) Parity audit: read `/Users/gustavo-neiva/Code/archive/pi-autoloop/autonomous_loop.sh` (the battle-tested predecessor) and compare its behaviors against ratchet's lib/*.sh. Write `docs/parity-audit.md` listing every old-loop behavior and its ratchet equivalent (or "MISSING"). Do NOT change any code. If anything is genuinely missing, append a new `[ ]` task for it under Milestone 3 in this file.

## Milestone 1 — tiered routing engine (serial: all tasks touch shared files)

- [x] T1.1 (normal, serial) `lib/tracker.sh`: add `tracker_next_tag` — echo the tag (`trivial|normal|hard`) of the first `[IN PROGRESS]` task, else the first `[ ]` task; echo `normal` when untagged or no task. Pure addition; do not modify existing functions. Add selftest cases: tagged trivial, tagged hard, untagged, empty tracker.
- [x] T1.2 (normal, serial) `lib/contract.sh` + `lib/common.sh`: add the six keys `PLAN_MODELS BUILD_MODELS LIGHT_MODELS THINKING_PLAN THINKING_BUILD THINKING_LIGHT` to `CONTRACT_KEYS` and as empty-string defaults in common.sh (commented like the neighbors). Add selftest: a conf file with `LIGHT_MODELS="a/b"` parses; an unknown key still errors.
- [x] T1.3 (hard, serial) `lib/model-fallback.sh`: add `chain_for_tier TIER` — echo the effective chain for `plan|build|light` with the fallback semantics from the design table (unset tier → `$MODELS`). Add `thinking_for_tier TIER` with the same fallback (including the `hard`-bump rule handled by the caller passing tier `build-hard` → one notch above `THINKING_BUILD`, capped at `high`, only when `THINKING_BUILD` is empty use global `THINKING` untouched). Keep `init_models` working unchanged when called with `$MODELS`. Add selftest cases: unset tiers → flat chain; set tiers → correct chain; ALLOWED_PROVIDERS still filters tier chains.
- [x] T1.4 (hard, serial) `bin/ratchet` run loop: before each turn, call `tracker_next_tag`, map tag→tier (`trivial`→light, `normal`→build, `hard`→build with thinking bump), re-`init_models "$(chain_for_tier …)"` ONLY when the tier changed since the last turn (preserve bench/cooldown state within a tier), and pass the tier thinking to `run_turn`. When the tier chain is fully benched, fall back to `init_models "$MODELS"` for that turn before ever sleeping `BOTH_WAIT`. Log one line per turn: `turn N | tier=build | model=X | thinking=Y` (keep the existing turn log line too — additive). With all tier keys unset the loop must select exactly what it selects today; add an end-to-end selftest with the fake agent proving (a) unset keys → old behavior, (b) a `(trivial)` task routes to `LIGHT_MODELS`.
- [x] T1.5 (normal, serial) `ratchet doctor`: print the three effective tier chains and thinking levels (or "→ MODELS (flat)" when unset). Warn (not fail) when `LIGHT_MODELS` is set but `THINKING_LIGHT` is not `off` (cheap tier should not reason). Add selftest for the warning.

## Milestone 2 — plan turns on existing repos (serial)

- [x] T2.1 (hard, serial) `ratchet plan [REPO]` command: run ONE turn using the PLAN tier (chain_for_tier plan) with a plan-drafting prompt: read the repo, read PLAN.md, draft/refresh open tasks (Milestone-0-walking-skeleton rule, tags on every task), then STOP with a loud "HUMAN: review PLAN.md before running". Never auto-runs the loop after. Reuse the plan-turn machinery from `ratchet new` (extract shared function if needed — smallest possible refactor). Selftest with fake agent: `plan` invokes exactly one turn and does not commit code changes outside PLAN.md/LEARNINGS.md.
- [IN PROGRESS] T2.2 (normal, serial) `ratchet stats`: extend `cmd_stats` (the embedded python in `lib/observability.sh`) to count turns per tier and per model from the `turn N | tier=X | model=Y` log lines (old logs without tier lines must not break stats). Selftest: stats on a fixture log with and without tier lines.

## Milestone 3 — docs + parity follow-ups (parallel-safe)

- [ ] T3.1 (trivial) README.md: add a "Tiered model routing" section with the design table above and a copy-paste `.ratchet.conf` example (fable/opus plan, sonnet/glm build, glm-turbo light with thinking off).
- [ ] T3.2 (trivial) CHANGELOG.md: add v1.1 entry (tiered routing, `ratchet plan`, tier stats, parity audit).
- [ ] T3.3 (trivial) templates: add the six commented tier keys to the `.ratchet.conf` template stamped by `ratchet init`.
- (T0.2 may append parity-gap tasks here.)

## Milestone 4 — run health & correctness (serial: found in the 2026-07-24 run postmortem)

- [x] T4.1 (trivial, serial) Secret-scan regression test: the private-key pattern used an empty alternation `(DSA |)` that BSD grep -E rejects (`grep: empty (sub)expression`) — the check silently no-oped on EVERY commit. The regex is already fixed in `lib/commit-gate.sh`. Add selftest cases: (a) a staged diff containing `-----BEGIN OPENSSH PRIVATE KEY-----` blocks the commit, (b) a bare `-----BEGIN PRIVATE KEY-----` (no algo prefix) also blocks, (c) the gate run produces NO stderr noise (assert `grep:` never appears in gate output).
- [ ] T4.2 (normal, serial) `ratchet doctor` + run preflight: FAIL when the repo is mid-operation — `.git/rebase-merge`, `.git/rebase-apply`, `.git/MERGE_HEAD`, or `.git/CHERRY_PICK_HEAD` exists. The 2026-07-24 run committed 8 turns inside a stalled interactive rebase; one `git rebase --abort` would have destroyed them all. Selftest: fake repo with a `.git/rebase-merge` dir → doctor fails with a message naming the state and the safe exit (`--quit` vs `--abort`).
- [x] T4.3 (trivial, serial) Startup staged-changes check: if `git diff --cached --quiet` fails at loop start, warn LOUDLY (`staged changes from a previous killed run — they will ride the next commit`). Do not block (the next green gate covers safety). Selftest: staged file at startup → warning line appears in loop.log.

## Milestone 5 — observability & UX (serial: all touch bin/ratchet + observability.sh)

> Postmortem: watching a run today you can't tell WHAT task is running, HOW
> LONG it took, WHAT the agent is doing during the 15s heartbeats, or WHAT is
> next. All additions below are additive log lines (constraint 2 — never
> change existing line formats; `stats` on old logs must not break).

- [ ] T5.1 (normal, serial) Turn header shows the work: extend the additive tier line to `turn N | tier=X | model=Y | thinking=Z | task=T2.1 (hard) <first 60 chars of task text>`. Needs `tracker_next_id_and_text` helper in `lib/tracker.sh` (pure addition next to `tracker_next_tag`). Selftest: line contains `task=` for a tagged tracker; untagged tracker → `task=? (normal)`.
- [x] T5.2a (trivial, serial) Turn summary line: emitted after classify — `turn N end | class=step | took=222s | task=T2.1` (done by hand, selftested).
- [ ] T5.2b (normal, serial) Extend `cmd_stats` to report avg/max turn duration from the `took=` lines (old logs without them → skip section, no crash). Selftest: stats parses a fixture log with and without `took=` lines.
- [x] T5.3 (trivial, serial) Progress line each turn: `tasks: 7 done / 14 total | next: T2.2 …` before the turn header (done by hand, selftested).
- [x] T5.4 (normal, serial) Heartbeat shows activity: `... working (45s, model=X) | <last non-empty output line, ANSI/CR-stripped, 80ch>` (done by hand; display-only, verified visually).
- [ ] T5.5 (hard, serial) `ratchet status [REPO]` command: one-shot snapshot for a second terminal (complement to `watch` which needs --resume sessions): reads loop.log + tracker + last_turn.out → prints current/last turn number, task, model+tier, elapsed (running) or took (finished), tasks done/total, last 5 output lines, and whether the loop process is alive (pgrep on the loop pid file — write `$LOG_DIR/loop.pid` at start, additive). Selftest: status against a fixture LOG_DIR renders all fields; no pid file → `not running`.
- [x] T5.6 (trivial, serial) `--cheap` flag: force ALL tiers to the LIGHT chain for this run (`LIGHT_MODELS` if set, else `MODELS`) — the one-word way to run the loop on the cheap model overnight: `ratchet run --cheap`. Log `cheap mode: all tiers → <chain>` in the startup banner. Document `-m/--models` next to it in `--help` as the explicit override. Selftest: `--cheap` with LIGHT_MODELS set routes a `(hard)` task to the light chain.

## Milestone 6 — strategy: fanout + proof (from docs/STRATEGY.md, human-reviewed)

> Decisions taken: Tier 0 = document now. Tier 1 = build behind `FANOUT` key,
> default off, gated on `(hard)` tags, reviewers advisory-only. Tier 2 = out of
> scope. Subagents NEVER touch git — only ratchet commits.

- [ ] T6.1 (trivial) README.md: document Tier 0 cross-repo parallelism (N ratchet processes on N repos via `--dir`, backgrounded + `wait`) as the free-throughput pattern. Copy the snippet from docs/STRATEGY.md §2.4.
- [ ] T6.2 (hard, serial) `FANOUT` contract key (`off|scout|scout+review`, default/empty = `off`): add to `CONTRACT_KEYS` + common.sh default. When `FANOUT != off` AND the current task tag is `hard`, `run_turn` drops `--no-extensions` (subagent tool loads) and exports `RATCHET_FANOUT`, `RATCHET_SCOUT_MODELS=$LIGHT_MODELS` env for the agent. When `off` or task not hard: byte-identical invocation to today. Selftests (the claim-guards): (a) FANOUT unset → agent invocation line contains `--no-extensions` (parity proof), (b) `FANOUT=scout` + `(hard)` task → invocation lacks `--no-extensions` and env is exported, (c) `FANOUT=scout` + `(normal)` task → still `--no-extensions` (gating proof).
- [ ] T6.3 (normal, serial) Fanout protocol block in `templates/AGENTS.protocol.md` (and the ratchet repo's own AGENTS.md): when `RATCHET_FANOUT != off` and the task is `(hard)` — spawn ≤3 read-only scouts on `$RATCHET_SCOUT_MODELS` (blast radius, reuse patterns, coverage), implement the ONE write yourself, then (if `scout+review`) ≤2 advisory reviewers; reviewers advise, YOU decide, the green gate is the only real gate. Subagents never run git commands. Selftest: template contains the block; `ratchet init` stamps it.
- [ ] T6.4 (hard, serial) Benchmark harness `test/bench.sh` (not in selftest; run manually + before releases) — makes the speed/efficiency claims falsifiable: with the fake agent, measure (a) token-seen → turn-end latency (claim: early-kill fires within one 3s poll + kill grace; assert < 10s), (b) wall-clock of a 3-task run, (c) turns-on-cheap-model % from stats. Prints a comparison table vs a committed `test/bench-baseline.txt`; exits nonzero on >20% regression of (a) or (b). This is the regression tripwire for 'faster/more efficient'.
- [ ] T6.5 (normal) One `FANOUT=scout` A/B experiment on a real `(hard)` task: run the same task once with `FANOUT=off` and once with `scout`, record wall-clock + token cost in LEARNINGS.md. If scout is not clearly better, keep the key but note the finding — do NOT default it on.
- [ ] T6.6 (trivial) docs/comparison.md: the §1.2 competitor table from docs/STRATEGY.md (looper, loop-harness, ouro-loop), one paragraph per differentiator. Link from README.
- [ ] T6.7 (trivial) README repositioning: lead with 'survives provider rate limits + never commits a red tree'; add the 'zero deps' footnote (loop core is bash-only; `stats` needs python3, `watch` prefers jq).

## How to finish this plan (dogfood — ratchet builds ratchet)

Everything still open is loop-work. Order is top-down as written: M2 (plan
command + stats) → M3 (docs) → M4 (T4.2 doctor mid-rebase guard) → M5
(observability: task-in-header, took=, progress, heartbeat activity, `status`)
→ M6 (FANOUT + bench + positioning docs). M5 lands the UI/UX you'll use to
WATCH the expensive M6 tasks run — do not reorder M6 before M5.

From the repo root:

    bin/ratchet run .                  # full run on the conf's MODELS/tier chains
    bin/ratchet run . --cheap          # same plan, ALL tiers on the LIGHT chain
    bin/ratchet once .                 # one supervised turn (dip a toe first)

Overnight:

    nohup bin/ratchet run . >/dev/null 2>&1 &
    tail -f ~/.ratchet/logs/ratchet/loop.log

Human checkpoints that remain yours: review `ratchet plan` output (T2.1 stops
loudly), the M6.5 A/B verdict, and every push (`git push` when you're happy —
the loop never pushes without --push).

## Done means

`bash test/selftest.sh` green with ALL new cases; unset tier keys ≡ today's
behavior; `(trivial)` tasks provably run on the light chain; `ratchet plan`
drafts and stops for human review; `FANOUT` unset ≡ today's invocation
byte-for-byte; a killed run leaves a state the next start explains out loud;
you can glance at a running loop and know the task, the elapsed time, the
progress, and what's next; `ratchet run --cheap` is all it takes to pick the
cheap chain.
