# ratchet

**An unattended-but-safe agent loop.** Survives provider rate limits and never commits a red tree.

Runs a coding agent (Pi, Claude, or any `-p` CLI) ONE turn at a time with multi-provider fallback + cooldowns, gating every commit on green. RED blocks the commit.

```bash
# Onboard any repo in 3 commands
ratchet init my-repo
ratchet doctor my-repo  # preflight check
ratchet run my-repo     # unattended until ALL_DONE
```

## What it does

Run a headless coding agent **unattended** (hours, overnight) against any repo, until the work is done — while:

- **Never committing red:** re-runs your test suite before EVERY commit. RED blocks the commit.
- **Surviving rate limits:** multi-provider fallback + cooldowns (hours-long runs across daily quotas).
- **Routing human judgment:** plan authoring, plan review, and PR review are human checkpoints. Mechanical execution runs unattended between them.
- **Staying cheap:** ephemeral turns (~90% per-turn cost cut vs. resumed sessions). The tracker file is the memory.

## One capability

*Unattended-but-safe agent execution.* An agent that can run for hours without a babysitter, yet **cannot** ship unreviewed code or commit a red tree — and that **pulls the human in exactly where judgment matters**.

## Quick start

### 1. Onboard an existing repo

```bash
ratchet init /path/to/your/repo
```

This stamps:
- `.ratchet.conf` — the machine contract (parsed, never sourced; agent-forbidden)
- `AGENTS.md` — agent protocol block (managed markers; edit outside them)
- `PLAN.md` — tracker grammar (`[ ]` → `[IN PROGRESS]` → `[x]`)
- `LEARNINGS.md` — append-only gotchas

```bash
# Review PLAN.md (the one mandatory human step), then:
ratchet doctor /path/to/your/repo  # preflight: conf parses, tracker has work, tokens align
ratchet run /path/to/your/repo     # unattended until ALL_DONE
```

### 2. Scaffold a new repo from an idea

```bash
ratchet new "a CLI that converts CSV→JSON"
```

This:
1. Scaffolds a fresh git repo
2. Drafts `PLAN.md` (Milestone 0 = green walking skeleton first)
3. **Stops for human plan review** (the mandatory checkpoint)
4. After you review: `ratchet run .`

### 3. Watch it run

```bash
# In one terminal:
ratchet run my-repo --models zai/glm,anthropic/claude --verify-cmd "npm test"

# In another (optional):
ratchet watch my-repo  # pretty-print the live session JSONL
```

Output:
```
[00:00] ratchet START  · models: zai/glm anthropic/claude · verify: npm test
[00:00] --- turn 1 | model=zai/glm ---
[00:15]   … working (15s)                      ← heartbeat (liveness proof)
[00:41] --- agent output (last 12 lines) ---
[00:41] STEP_COMPLETE
[00:41] commit gate: running 'npm test' … green → committed turn 1
[00:51] --- turn 2 | model=zai/glm ---
```

**The safety punchline:** force a red turn (break a test) → `commit gate RED — NOT committing; left for next turn to repair.` Nothing bad ships.

## How it works

### The repo contract (4 files)

The engine is task-agnostic. Your repo's contract files carry all project knowledge:

| File | Role | Who writes it |
|---|---|---|
| `.ratchet.conf` | Machine contract — parsed, never sourced. Agent-forbidden. | Human (at `init`) |
| `AGENTS.md` | Agent protocol — versioned/stamped markers + per-repo prose outside | `init` stamps; human adds project rules |
| `PLAN.md` | Tracker — `[ ]`/`[IN PROGRESS]`/`[x]` + optional `trivial\|normal\|hard`, `serial` tags | Strong-model plan turn, human-reviewed |
| `LEARNINGS.md` | Append-only gotchas the agent discovers | Agent (planner-pruned) |

### The four human checkpoints

| # | Checkpoint | When you're needed |
|---|---|---|
| 1 | **Plan authoring** | New repo/feature from an idea — a plan turn drafts `PLAN.md` (Milestone 0 = walking skeleton + green gate first) |
| 2 | **Plan review (mandatory)** | Review/edit `PLAN.md` before any feature turn runs. The one checkpoint the loop never skips. |
| 3 | **Green gate (automatic)** | No human; RED tree never commits. |
| 4 | **PR review** | `--pr` mode: after `ALL_DONE`, the loop opens a PR/MR with completed tasks. You review/merge. |

### One turn at a time (safe default)

The loop runs **one turn, one commit** — sequential, green-gated, easy to bisect/revert. Parallel turns (`--parallel N`) are opt-in for tasks the tracker marks non-`serial`, each in an isolated `git worktree`. Concurrent writers over a shared tree are never safe.

### Token economy (proven in real use)

Ephemeral turns are the DEFAULT: `--no-session --no-extensions` each turn. The tracker + on-disk markdown files are the only memory. Measured **~90% per-turn cost cut** vs. resumed sessions in daily use (mid-2026). Survives hours-long runs across provider daily quotas.

### Model fallback + rate-limit survival

```
--models zai/glm,anthropic/claude,openai/gpt-4
```

- First-available model each turn.
- On `exhausted` (429/quota): bench that model for `--cooldown` seconds (default 4h ≈ daily refresh).
- On `hard` error: strike up to `MAX_TRANSIENT` then bench.
- All benched → sleep `BOTH_WAIT`, reset, retry.

This is how it survives unattended overnight runs.

### Tiered model routing

Route turns by task complexity — heavy models for planning/building, cheap models for trivial work:

| Tier | Config keys | Used for | Example |
|---|---|---|
| PLAN  | `PLAN_MODELS`, `THINKING_PLAN`   | plan-drafting turns only (`ratchet plan`, `ratchet new`) | `anthropic/claude-fable-5,anthropic/claude-opus-4-8` |
| BUILD | `BUILD_MODELS`, `THINKING_BUILD` | `normal` and `hard` tasks (heavy lifting) | `anthropic/claude-sonnet-4-5,zai/glm-5.2` |
| LIGHT | `LIGHT_MODELS`, `THINKING_LIGHT` | `trivial` tasks (search, data collection, mechanical edits) | `zai/glm-5-turbo,zai/glm-4.5-air` with `THINKING_LIGHT=off` |

**Fallback semantics:** Any tier key unset → that tier falls back to the flat `MODELS` chain and global `THINKING`. Tag tasks in `PLAN.md` with `(trivial)`, `(normal)`, or `(hard)` to route them.

**Example `.ratchet.conf`:**

```ini
# Tiered routing: strong models for plans, sonnet for builds, cheap for trivial
PLAN_MODELS="anthropic/claude-fable-5,anthropic/claude-opus-4-8"
THINKING_PLAN="high"

BUILD_MODELS="anthropic/claude-sonnet-4-5,zai/glm-5.2"
THINKING_BUILD="medium"

LIGHT_MODELS="zai/glm-5-turbo"
THINKING_LIGHT="off"

# Flat fallback when tiers unset
MODELS="anthropic/claude-sonnet-4-5,zai/glm-5.2"
THINKING="medium"
```

### Cross-repo parallelism (Tier 0 — free throughput)

Launch N `ratchet` processes on N independent repos. Already supported via `--dir`.

```bash
ratchet run --dir ~/Code/harbor      &
ratchet run --dir ~/Code/ta_justo    &
ratchet run --dir ~/Code/agroclaro   &
wait
```

Free throughput not currently used. **Do this first.** (Same-repo parallel tasks need worktrees — see Tier 2.)

## Installation

```bash
# Clone
git clone https://github.com/YOUR_USERNAME/ratchet.git
cd ratchet

# Put bin/ratchet on PATH (or use ./bin/ratchet)
export PATH="$PWD/bin:$PATH"

# Test
ratchet --selftest
```

**Requirements:**[^deps]
- Bash 3.2+ (macOS/Linux; no `timeout` binary needed)
- Git
- A headless agent: `pi` (default), `claude -p`, or any CLI that accepts `-p "prompt"`
- Configured API keys for your models

[^deps]: **Zero dependencies** for the loop core (pure bash). `ratchet stats` needs python3; `ratchet watch` prefers `jq` (degrades gracefully without it).

## Commands

```
run    [REPO]   Run until ALL_DONE (default)
once   [REPO]   One turn, then exit (testing/debugging)
init   [REPO]   Stamp protocol files (existing repo)
new    "<idea>" Scaffold repo, draft plan, STOP for review
doctor [REPO]   Preflight checks
selftest        Verify logic against fixtures (no API calls)
stats   [REPO]  Parse loop.log and print metrics
watch   [REPO]  Pretty-print live session JSONL (2nd terminal)
```

## Options

### Core

```
-d, --dir DIR          Repo directory (default: $PWD)
-p, --prompt TEXT      Per-turn prompt (default: built-in do-one-step)
-m, --models LIST      Comma-separated fallback chain (provider/id)
--agent-cmd CMD        Headless agent (default: pi; e.g. claude)
--thinking LEVEL       Reasoning level: off|minimal|low|medium|high|xhigh
--turn-timeout N       Max seconds per turn (default: 1800)
--cooldown N           Bench duration for rate-limited models (default: 14400)
```

### Commit-per-turn (green-gated)

```
--commit / --no-commit    Commit each green turn (default: on)
--verify-cmd CMD          Green gate before every commit (RED blocks)
--no-verify-gate          Skip pre-commit re-verify (trust agent's word)
--push                    Push ONCE after ALL_DONE (default: off; human owns push)
--pr                      Push + open PR/MR (gh/glab) after ALL_DONE; human merges
--approve                 Open local diff-review UI before push/PR (opt-in, v1)
```

### Token economy

```
--resume / --no-resume      Default: ephemeral turns (~90% cheaper)
--cache-retention LEVEL     Prompt-cache TTL: long|short|none
--no-sanitize               Don't strip thinking blocks (debug only)
```

### Feedback

```
--tail N                 Lines of agent output to show (default: 12)
--heartbeat N            Seconds between "working" pings (default: 15, 0=off)
--stream                 Live-stream agent's raw output (noisy)
--quiet                  Terminal silent; logs only
-v, --verbose            Verbose logging
```

## What this adds to the Pi ecosystem

Pi already provides `pi-subagents` (delegate to child agents) and `@pi-agents/loop` (scheduled/recurring tasks). **ratchet** fills a different gap:

**See [docs/comparison.md](docs/comparison.md)** for a full comparison with looper, loop-harness, and ouro-loop.

| Feature | ratchet | pi-subagents | @pi-agents/loop |
|---|---|---|---|
| **Unattended multi-hour runs** | ✓ (rate-limit survival) | ✗ (synchronous) | ✗ (scheduling only) |
| **Green-gated commits** | ✓ (RED never commits) | ✗ | ✗ |
| **Multi-provider fallback** | ✓ (survives quotas) | ✗ | ✗ |
| **Repo contract (task-agnostic)** | ✓ (4 files) | ✗ | ✗ |
| **Human checkpoints** | ✓ (plan review, PR review) | ✗ | ✗ |
| **Ephemeral turns (cheap)** | ✓ (~90% cost cut) | ✗ | ✗ |

Use **ratchet** for: unattended overnight coding runs, quota-bound long tasks, multi-repo pipelines.  
Use **pi-subagents** for: delegating sub-tasks within an interactive session.  
Use **@pi-agents/loop** for: scheduling periodic prompts (cron-style).

## Uniqueness (5 mechanisms)

1. **Green-gated commit ownership** — the loop re-runs your test suite before EVERY commit; RED blocks.
2. **Model fallback + bench/cooldown** — survives rate limits across multi-provider chains.
3. **Ephemeral turn economy** — tracker file = memory; ~90% per-turn savings (measured).
4. **Session sanitization** — strips prior thinking blocks so any provider can continue any session.
5. **Repo contract + human checkpoints** — 4 files declare ALL project knowledge; plan review is mandatory.

None of these exist in `pi-subagents` or `@pi-agents/loop` — so **ratchet** complements rather than duplicates.

## Project structure

```
ratchet/
├── bin/ratchet              # entrypoint
├── lib/*.sh                 # bash modules
│   ├── common.sh            # output, defaults
│   ├── contract.sh          # parse .ratchet.conf
│   ├── tracker.sh           # PLAN.md grammar
│   ├── model-fallback.sh    # first-available + bench
│   ├── run-turn.sh          # one agent -p call + watchdog
│   ├── classify.sh          # token/error detection
│   ├── commit-gate.sh       # re-verify + stage + commit
│   ├── session-sanitize.sh  # strip thinking blocks
│   ├── observability.sh     # heartbeats, excerpts, watch
│   └── commands.sh          # init/new/doctor
├── templates/               # onboarding files
│   ├── AGENTS.protocol.md   # stamped block
│   ├── PLAN.seed.md         # tracker template
│   ├── LEARNINGS.md         # gotchas
│   └── ratchet.conf.example # machine contract
├── test/
│   ├── selftest.sh          # no-API verification
│   └── fixtures/            # fake-agent + test repo
├── examples/demo-repo/      # toy project (tutorial)
├── docs/                    # deep-dive docs
└── ts/                      # (future) TypeScript wrapper
```

## Evidence base

This is a **clean rebuild** of a harness in daily use (mid-2026). The real script:
- `~/.pi/autonomous_loop.sh` (791 lines, real runs in `autoloop-logs/cookbook/`)
- `~/.pi/autonomous_loop_PLAN_v2.md` (the v2 repo-contract design)

This public repo implements that v2 design, generalized and task-agnostic. No internal code copied.

## Residual risks / honest gaps (v1)

- **Cross-provider sanitize is Pi-session-format-specific.** Works for Pi's JSONL; `claude -p` may differ. Documented, not overclaimed.
- **Approval UI (`--approve`) is unproven.** Inspired by browser-review workflows but not battle-tested in daily use. Flagged as v1.
- **`--pr` mode assumes `gh`/`glab` + a remote.** Falls back to local branch + `--approve` UI when absent. Agent never merges.
- **`--parallel N` is a design, not yet built.** v1 evidence is single-turn only. Future: `--parallel N` with worktrees for non-`serial` tasks.
- **Watchdog relies on bash 3.2 tricks** (`kill -0`, `$SECONDS`). `--selftest` is the correctness proof; run it in CI.

## License

MIT — see LICENSE

## Contributing

Contributions welcome! This is a clean, public, open-source rebuild. No internal or proprietary code.

**Before contributing:**
1. Run `bin/ratchet --selftest` (all must pass)
2. Keep the task-agnostic invariant: zero project knowledge in `lib/`, `bin/`, `templates/`
3. The repo contract (4 files) is the ONLY place project specifics live

## What it proves

Systems thinking about **unattended agents**:
- Rate-limit survival across multi-provider chains
- Green-gated safety (RED never commits)
- Human judgment routed to the right boundaries (plan authoring, plan review, PR review)
- Measured cost engineering (ephemeral turns, ~90% savings)
- Observability (heartbeats, live watch, loop.log)

This is a distinctive **agent infrastructure** signal, not another skill wrapper.

---

**Ship it safely.** Review the plan, run `doctor`, then let it run unattended. A RED tree is never committed.
