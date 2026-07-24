# Ratchet — Strategy & Fanout Proposal

> **Status:** For deep review. Nothing here is decided or implemented. Two halves:
> **Part 1** is market positioning (researched findings + a positioning proposal).
> **Part 2** is a technical proposal to accelerate the loop with pi subagents.
> Each claim is tagged **[FACT]** (verified from code/docs this session) or
> **[PROPOSAL]** (my recommendation — challenge freely). Sources in the appendix.
>
> **How to read in a fresh session:** this file is self-contained. You should not
> need the prior conversation. Cross-check any `[FACT]` against the repo or the
> cited URL before acting on it.

---

## Part 1 — Market Positioning

### 1.1 What ratchet is (reset)

**[FACT]** Ratchet is an unattended-but-safe agent loop, ~1,400 lines of bash
(`bin/ratchet` 282 + `lib/` ~1,125), zero dependencies beyond bash 3.2+.

It wraps a headless coding agent (pi, claude, codex, aider — any `-p`-style CLI)
**one turn at a time**, with three load-bearing invariants:

1. **Never commits a red tree** — runs the repo's `VERIFY_CMD` before every
   commit; RED blocks the commit.
2. **Survives provider rate limits** — multi-provider fallback chain,
   cheapest-first, with cooldowns for hours-long runs across daily quotas.
3. **Routes human judgment** — plan authoring/review and push/PR are human
   checkpoints; mechanical execution runs unattended between them.

Design posture: **task-agnostic, repo-as-context.** The loop carries no project
knowledge — `AGENTS.md` (protocol), `PLAN.md` (tracker), `.ratchet.conf`
(machine contract, parsed-not-sourced, agent-forbidden) carry it all.

### 1.2 The landscape (direct competitors)

**[FACT]** Three direct competitors surfaced, all "autonomous loop harness for
coding agents." Full comparison:

| Dimension | **ratchet** (yours) | **looper** (nexu-io) | **loop-harness** (lSAAGl) | **ouro-loop** (VictorVVed) |
|---|---|---|---|---|
| Lang / deps | **bash 3.2+, zero deps** | Go (daemon+CLI, curl-install) | bash + jq+gh+curl+claude | Python 3.10+ (pip) |
| Agent scope | **any `-p` CLI** | pluggable (claude/codex/cursor/grok/opencode) | **Claude-locked** | **Claude-locked** (hooks) |
| Rate-limit survival | **fallback chain, cheapest-first** | per-vendor choice, no auto-fallback | none | none |
| Green gate | **your test suite, before every commit** | checks pass → ready for merge | **2nd Claude** verifies (`VERDICT: PASS`) | verify stage + remediation |
| Push/PR | **routed to human** | auto-merge (`--merge`) | auto-push after verify | in-repo |
| Isolation | in-repo (staged) | worktree per loop | worktree per loop | in-repo |
| Knowledge model | **repo-as-context** (task-agnostic) | forge = source of truth (labels/PRs) | injected skills per loop | injected methodology (`program.md`) |
| Tagline | "unattended-but-safe" | "autonomous AI dev team" | "you don't prompt; loops do" | "bounded autonomy" |

### 1.3 What's actually different (verified, not invented)

**[FACT]** Three differentiators no competitor combines:

1. **Rate-limit survival is yours alone.** ouro-loop and loop-harness are
   Claude-locked — one 429 kills the night. looper lets you *pick* a vendor but
   does not *fall across them on quota*. ratchet's cheapest-first fallback chain
   is unique. This is the most relatable pain in the entire category.
2. **Deterministic gate > probabilistic gate.** loop-harness trusts a *second
   LLM* to approve work. ratchet trusts *your test suite*. Cleaner philosophy:
   tests are the spec, the loop enforces them.
3. **Zero-dep, runs anywhere a shell runs.** looper ships Go binaries + a
   daemon. ratchet is one script — drops into CI runners, containers, a
   teammate's fresh laptop. No toolchain.

Two quieter ones: **human-at-the-boundary** (most conservative push posture —
looper auto-merges, loop-harness auto-pushes), and the **agent-forbidden
`.ratchet.conf`** (parsed-not-sourced, hash-checked — the agent literally cannot
rewrite the loop's contract; none of the competitors emphasize this).

### 1.4 The crack to fill

**[PROPOSAL]** Two nested cracks. Win the small one first.

**Beachhead — the pi ecosystem has zero unattended loops.**
**[FACT]** Scanned the top 50 of 5,328 pi packages (pi.dev/packages). Nearest
neighbors, none of which is a commit-gated overnight loop:
- `@narumitw/pi-goal` — autonomous *single-goal* completion
- `@mjasnikovs/pi-task` — deterministic task pipelines w/ verify gates
- `pi-crew` / `@quintinshaw/pi-dynamic-workflows` — team/worktree orchestration

Nobody owns "run pi unattended, gate every commit on green, survive rate
limits." That slot is empty. ratchet is already pi-native (global `AGENTS.md`,
the protocol block). Pre-qualified audience, zero competition.

**Expansion — "the loop that survives the night."** Generalize the `-p` story to
claude/codex/aider and own rate-limit survival across the whole category.

### 1.5 Proposed positioning

**[PROPOSAL]**

> For devs who run coding agents unattended, ratchet is the loop harness that
> **survives provider rate limits and never commits a red tree** — unlike
> looper/loop-harness/ouro-loop, it's provider-agnostic, zero-dependency, and
> trusts your test suite over a second LLM.

The name does real work: **ratchet = only moves forward, never backslides.**
That *is* the green-gate philosophy. Lean into it.

Marketing hooks, ranked by pull:
1. **"Loops that survive the night."** (rate-limit survival — lead with this)
2. **"Never commits a red tree."** (the deterministic gate)
3. **"Bring your own agent."** (provider-agnostic)
4. **"Autonomous in the worktree. Human at the boundary."** (safety posture)

### 1.6 Honest gaps to close before marketing

**[FACT/PROPOSAL]** Where ratchet is currently exposed vs competitors:

- **Weak-suite exposure:** the gate is only as strong as `VERIFY_CMD`. An empty
  verify is already a loud warning (good); consider making "verify must exist +
  non-empty" a hard `doctor` fail for marketed/safe-by-default posture.
- **No 2nd-agent verification:** loop-harness catches "tests pass but the change
  is wrong." ratchet does not. Defensible (trust the tests) but should be named
  explicitly as a choice. *(Note: Part 2's Tier 1 review-fanout can close this
  without making the reviewer authoritative.)*
- **In-place vs worktree isolation:** looper & loop-harness worktree-isolate per
  loop; ratchet works in-repo (staged). Either defend it ("simpler, your
  checkout is the state") or add opt-in worktree mode. A reviewer will push here.
- **Remediation story:** ouro-loop has an explicit self-fix playbook. ratchet
  routes "red gate IS your task" via the tracker — works, less articulated. One
  sentence in docs closes it.

### 1.7 Concrete next moves (positioning)

**[PROPOSAL]**
1. Publish as a pi package (`pi install npm:ratchet`) — fill the empty slot.
2. Rewrite README to lead with rate-limit survival, not "unattended-but-safe."
3. Write `docs/comparison.md` — ouro-loop has one, table-stakes in this category.
4. One killer proof log: "8h run, 3 providers, 0 429-deaths, tree never red."
5. Decide the isolation gap (defend in-place or add opt-in worktree).

---

## Part 2 — Accelerating the Loop with Subagents

### 2.1 The two facts that decide everything

**[FACT]** 1. **Subagents are OFF by default.** `lib/run-turn.sh` runs ephemeral
turns with `--no-session --no-extensions` (~90% cheaper per turn). The
pi-subagents tool only loads under `--resume` (`RESUME_SESSION=1`). So "add
subagents" is really "selectively pay for extensions." This reframes the entire
question.

**[FACT]** 2. **Model tiers already exist.** The contract allowlist
(`lib/contract.sh`) already defines `PLAN_MODELS` / `BUILD_MODELS` /
`LIGHT_MODELS` plus `THINKING_PLAN/BUILD/LIGHT`. The machinery for "cheap model
for parallel scouts, expensive for the writer" is already built — reuse it, do
not rebuild it.

### 2.2 The principle

**[PROPOSAL]** **Parallelize the reads, serialize the writes. The `PLAN.md` task
is the atomic unit — not the agent.**

This maps exactly onto ratchet's existing invariants:
- Green-gate stays serial — only one staged change is ever gated, from one parent.
- One-task-per-turn stays intact — a turn still does ONE `[IN PROGRESS]` task; it
  just uses parallelism to *understand and verify* that task.
- Human-at-boundary stays — push/PR untouched.

**The one rule that must never bend: subagents never touch git. Only ratchet
commits.** Everything else is negotiable.

### 2.3 The quota reality (the real constraint)

**[FACT]** Gustavo's #1 pain is 429 rate limits (documented in global
`AGENTS.md`: "keep cheaper model FIRST in the fallback chain; only fall back to
Opus when glm is exhausted").

**[PROPOSAL]** Fanning out 5 agents on Opus burns quota 5× faster and *worsens*
the 429 problem. Therefore parallel work **must run on `LIGHT_MODELS` (glm)**,
writers on `BUILD_MODELS`. Parallelism that targets the cheap tier is
quota-neutral-to-positive: scouts on glm spare the Opus budget for the write.
This is exactly the tier split already in the contract.

### 2.4 Three tiers of acceleration

#### Tier 0 — cross-repo parallelism (free, works today)

**[PROPOSAL / no code change]** Launch N `ratchet` processes on N independent
repos. Already supported via `--dir`.

```bash
ratchet run --dir ~/Code/harbor      &
ratchet run --dir ~/Code/ta_justo    &
ratchet run --dir ~/Code/agroclaro   &
wait
```

Free throughput not currently used. **Do this first.** (Same-repo parallel tasks
need worktrees — see Tier 2.)

#### Tier 1 — intra-turn scout + review (cheap, minimal change) ← THE WIN

**[PROPOSAL]** Within a single turn, the parent fans out **read-only** subagents
on the cheap tier:

```
pi turn (BUILD_MODEL) ──┬─► scout A (LIGHT): map blast radius (callers of fn)
                        ├─► scout B (LIGHT): find existing reuse patterns
                        ├─► scout C (LIGHT): coverage gap on target files
                        │  [parent synthesizes, implements the ONE write]
                        ├─► review: correctness (LIGHT, forked context)
                        ├─► review: security  (LIGHT, forked context)
                        └─► review: ponytail/over-engineering (LIGHT)
[parent reconciles → stages ONE change → ratchet green-gates]
```

- **Safe:** scouts/reviewers are read-only, forked-context, never write, never
  commit. Green-gate sees exactly one change. Serial-commit invariant holds.
- **Cheap:** scouts/reviewers run on `LIGHT_MODELS`. The single write stays on
  `BUILD_MODELS`. Faster wall-clock (research is the slow part of most steps),
  modest glm spend, Opus quota spared.
- **Closes the "no 2nd-agent verification" gap** (§1.6) *without* making the
  reviewer authoritative.

#### Tier 2 — parallel writers in worktrees (expensive, defer)

**[PROPOSAL — defer]** Only for tasks that decompose into file-disjoint slices.
Each writer subagent gets a worktree (`pi-subagents` supports `worktree:true`),
parent merges → ratchet green-gates **one merged commit**.

This is what looper & loop-harness do. It is a real feature but a big one:
worktree lifecycle, merge, conflict resolution — and it fights ratchet's "the
checkout is the state" simplicity. **Propose only after Tier 1 proves the
model.** Likely never worth it for solo-repo workflow.

### 2.5 Tier 1 tradeoffs (honest)

**[PROPOSAL]**
- **Accelerates understanding, not typing.** Big win on IO-bound research/review
  steps; no win on pure codegen. The protocol should gate fanout on task
  *difficulty* (e.g. only when `[IN PROGRESS]` is tagged `(hard)`), not always-on.
- **Cost ceiling:** a `(hard)` task with 4 scouts + 3 reviewers ≈ 7× the read
  tokens, on glm. Cheap, not free.
- **Reviewer-veto danger:** a wrong reviewer can block a good change. Resolution:
  **reviewers advise, the parent decides, the green-gate is the only real gate.**
  Never let an LLM override the test suite.

### 2.6 Minimal implementation surface (Tier 1)

**[PROPOSAL]** Two changes, both small:

1. **New contract key** `FANOUT=off|scout|scout+review` (default `off` → current
   behavior + cost unchanged). When `FANOUT!=off`: `run_turn` drops
   `--no-extensions` (loads the subagent tool) and exports tier models so the
   agent knows "scouts → `LIGHT_MODELS`, you → `BUILD_MODELS`." ~15 lines across
   `lib/run-turn.sh` + `lib/contract.sh`.
2. **Fanout protocol section** in `templates/AGENTS.protocol.md`. The actual
   intelligence lives here, not in code: when `[IN PROGRESS]` is tagged `(hard)`,
   spawn ≤3 read-only scouts on `LIGHT_MODELS`, implement, spawn ≤2 reviewers,
   reconcile, done. **Subagents never commit.**

ratchet does not *orchestrate* subagents — pi does. ratchet **permits and
constrains.** Correct Unix layering. Keeping it to one contract key + one
protocol block is the discipline that stops this from bloating into "ratchet
becomes an orchestrator" (it should not).

---

## Part 3 — Decisions for You to Make

Review these explicitly. Each is independent.

**Positioning**
- [ ] Lead with "survives the night" (rate limits) vs "never commits red" (gate)?
- [ ] Beachhead in pi ecosystem first, then generalize? Or go broad immediately?
- [ ] Publish as pi package now, or after README rewrite + proof log?
- [ ] Defend in-place isolation, or commit to building opt-in worktree mode?
- [ ] Make empty-`VERIFY_CMD` a hard `doctor` fail (safe-by-default) or keep warning?

**Fanout**
- [ ] Tier 0 (cross-repo) — adopt as a documented pattern now? (zero cost)
- [ ] Tier 1 (scout/review subagents) — build it? Or run a manual one-off first to
      measure wall-clock vs token cost before adding `FANOUT`?
- [ ] If Tier 1: gate fanout on `(hard)` tag only, or always-on when `FANOUT!=off`?
- [ ] Reviewer posture: advisory-only (recommended) vs blocking?
- [ ] Tier 2 (parallel writers / worktrees) — ever? Or explicitly out of scope?

**Sequencing suggestion (if useful)**
1. Tier 0 today (free).
2. One manual fanout experiment (no code) to measure cost/benefit.
3. If it pays off: add `FANOUT` key + protocol section.
4. In parallel: README rewrite + `docs/comparison.md` + proof log for positioning.

---

## Appendix — Sources

**Competitors (read in full this session):**
- looper — https://github.com/nexu-io/looper (Go, daemon+CLI, forge-native)
- loop-harness — https://github.com/lSAAGl/loop-harness (bash, 2nd-agent verify)
- ouro-loop — https://github.com/nickwarters/ouro-loop (Python, bounded autonomy)
- Claude Code headless/SDK — https://code.claude.com/docs/en/headless

**Pi ecosystem:**
- Package catalog — https://pi.dev/packages (5,328 packages scanned, top 50 reviewed)
- pi-subagents — https://github.com/nicobailon/pi-subagents
- pi packages docs — https://github.com/earendil-works/pi/tree/main/packages/coding-agent/docs/packages.md

**Internal (verified against repo this session):**
- `lib/run-turn.sh` — `--no-extensions` default, `--resume` enables extensions
- `lib/contract.sh` — `CONTRACT_KEYS` allowlist incl. `PLAN_MODELS`/`BUILD_MODELS`/`LIGHT_MODELS` + `THINKING_*` tiers
- `README.md`, `bin/ratchet`, `lib/*.sh` — ~1,400 LOC, bash 3.2+, zero deps
