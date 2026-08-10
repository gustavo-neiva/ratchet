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
- **Staying cheap:** ephemeral turns send only the tracker + files each turn, not a growing session — a fraction of a resumed session's per-turn cost. The tracker file is the memory.

## Quick start

### 1. Onboard an existing repo

```bash
ratchet init /path/to/your/repo
```

This stamps:
- `.ratchet.conf` — the machine contract (parsed, never sourced; agent-forbidden)
- `AGENTS.md` — human/project entrypoint (no loop mechanics; the loop briefs its own turns — see below)
- `PLAN.md` — tracker grammar (`[ ]` → `[IN PROGRESS]` → `[x]`)
- `LEARNINGS.md` — append-only gotchas

```bash
# Review PLAN.md (the one mandatory human step), then:
ratchet doctor /path/to/your/repo  # preflight: conf parses, tracker has work, tokens align
ratchet run /path/to/your/repo     # unattended until ALL_DONE
```

**Authoring the plan:** a good `PLAN.md` is what lets the loop one-shot big work.
The [`ratchet-plan` skill](skills/ratchet-plan/SKILL.md) (`skills/ratchet-plan/`)
teaches the task schema — self-contained tasks, tier tags for model routing, and
Given/When/Then acceptance that becomes the green gate. Symlink it into your
agent's skills dir (`~/.claude/skills/` and/or `~/.pi/agent/skills/`), or install
ratchet as a package (`"skills": ["./skills"]` in `package.json`) to auto-discover it.

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

```
[00:00] ratchet START  · models: zai/glm anthropic/claude · verify: npm test
◐ Step 1/52  [▓░░░░░░░░░ 1%]   M1 · kill the noise  (0/4)
  ▶ T1.1 (normal)  in-place heartbeat, human words     build · glm-5-turbo
  ⏱ turn 1 · 0m15s   avg —   ~51 turns / ETA unknown
     … working (15s)                          ← in-place heartbeat (no byte counter)
  summary                                     ← curated last lines, not a 12-line dump
  STEP_COMPLETE
  commit gate: running 'npm test' … green → committed turn 1
```

**The safety punchline:** force a red turn (break a test) → `commit gate RED — NOT committing; left for next turn to repair.` Nothing bad ships.

#### Feedback / observability

The terminal is a **project-management board, not a log tail**. Every turn it
answers the four questions a human actually has — *what step am I on, what is
it doing right now, how many steps are left, how long until done* — at a glance:

- **PM header** — a `Step D/T [bar PCT%]` line with the milestone + current
  task (`▶ T5.4 … · build · glm-5-turbo`). This is where you are.
- **In-place heartbeat** — a single status line that rewrites in place every
  tick with a human verb (`thinking`, `working`, `running a tool`) and an
  elapsed time. No new line per tick, no byte counter, no scroll spam. (Heart
  beats only print to a TTY; the log stays clean.)
- **Curated summary** — after the turn, the agent's **last few meaningful
  lines**, not its whole inner monologue. Blank lines and tool chatter are
  dropped. (`--summary-lines N`, default 4.)
- **Timing + ETA** — `⏱ turn N · <elapsed> · avg <dur> · ~<rem> turns / ~<left>`.

**The ETA is honestly labelled.** It is a naive `avg_turn_secs ×
remaining_open` estimate — turn durations vary widely, so it is always
prefixed `~` and renders `ETA unknown` until at least one turn has a recorded
duration. Treat it as a rough guide, not a promise; it does not account for
queueing, rate-limit cooldowns, or tasks of differing difficulty.

The machine `loop.log` keeps its frozen key/value lines (turn, took, task
counts); all of the above is a **terminal render layer** on top of that same
data — the log formats are additive-only, and `ratchet stats` still parses
old logs unchanged.

#### The live board (`ratchet status`)

The run terminal shows a per-turn PM header; for the project-management view,
keep a second terminal on `ratchet status` refreshed by native `watch(1)` —
zero new deps:

```bash
watch -n5 bin/ratchet status .   # refresh every 5s
```

Sample board (answers *what step, what's it doing, how many left, ETA*):

```
my-repo ●
Step 33/52  [▓▓▓▓▓▓▓░░░░░ 63%]
   Milestone 1 — safety net      [▓▓▓▓▓▓]  3/3
   Milestone 2 — kill the noise  [▓▓▓▓▓▓]  4/4
▶  Milestone 3 — timing & ETA    [▓▓▓░░░]  2/3
   Milestone 4 — status board    [░░░░░░]  0/2

Current: T3.2 wire ETA into the status block
Tier/Model: build / glm-5-turbo (thinking=medium)
Turn 5: 3m42s
ETA: ~19 turns / ~57m left

Doing: editing lib/render.sh to add the timing line

Loop: running
```

`●` = loop alive; `▶` marks the milestone containing the current task; the ETA
is a naive `avg_turn × remaining` estimate, always shown with `~`.

## How it works

### The repo contract (4 files)

The engine is task-agnostic. Your repo's contract files carry all project knowledge:

| File | Role | Who writes it |
|---|---|---|
| `.ratchet.conf` | Machine contract — parsed, never sourced. Agent-forbidden. | Human (at `init`) |
| `AGENTS.md` | Human/project entrypoint — what the repo is, how to work here, gotchas (NO loop mechanics) | Human (`init` seeds a body); human owns it |
| `PLAN.md` | Tracker — `[ ]`/`[IN PROGRESS]`/`[x]` + optional `trivial\|normal\|hard`, `serial` tags | Strong-model plan turn, human-reviewed |
| `LEARNINGS.md` | Append-only gotchas the agent discovers | Agent (planner-pruned) |

### Loop protocol vs interactive sessions

The loop protocol (do one step, print `STEP_COMPLETE`, gate on green) **travels
in the harness prompt** — it is injected fresh each turn from
`$RATCHET_ROOT/templates`, never read from the repo. So **`AGENTS.md` is the
human/interactive entrypoint only**: what the repo is, how to work here,
gotchas. An interactive agent (you, in Claude/Pi/Cursor) loads `AGENTS.md` and
sees **zero** one-turn/`STEP_COMPLETE`/"don't commit" instructions — work
normally, make as many edits as needed, run the tests, you own the commits.

The only in-loop signal exported to spawned turns is `RATCHET_LOOP=1`. It is
**advisory** — routing/telemetry only, never a security or commit gate (a
future turn that needs to read it as authority must consciously update the
guard test first).

**Migrating an older repo:** pre-split repos carry the protocol *inside*
`AGENTS.md` under `ratchet-protocol:v1` markers. `ratchet init` strips that
marker block (preserving all your prose outside it) and seeds a human body;
`ratchet doctor` flags any leftover block and points at `ratchet init`.

### The four human checkpoints

| # | Checkpoint | When you're needed |
|---|---|---|
| 1 | **Plan authoring** | New repo/feature from an idea — a plan turn drafts `PLAN.md` (Milestone 0 = walking skeleton + green gate first) |
| 2 | **Plan review (mandatory)** | Review/edit `PLAN.md` before any feature turn runs. The one checkpoint the loop never skips. |
| 3 | **Green gate (automatic)** | No human; RED tree never commits. |
| 4 | **PR review** | `--pr` mode: after `ALL_DONE`, the loop opens a PR/MR with completed tasks. You review/merge. |

## PR-gated autonomy (`PR_CADENCE=milestone`)

The default cadence (`PR_CADENCE=done`) opens **one** PR at `ALL_DONE` and is
what the sections above describe. The milestone cadence restructures the whole
loop around **merge gates**: the only human action is the merge button, and the
loop blocks on it between milestones instead of stacking work.

```
 plan PR #0  →  build  →  review  →  PR  →  merge-gate ─┐
      ↑                                              merge │
      └──────────────────────────── next milestone ←──────┘
```

Five nodes:

1. **plan PR #0** — if the tracker isn't ready (`plan_is_ready` fails: seed
   placeholders present, or no tagged task), the loop branches `ratchet/plan`
   off the default branch, runs ONE plan turn, pushes, opens PR #0
   ("ratchet plan: &lt;repo&gt;"), and **blocks until you merge it**. The merge *is*
   the plan review — no separate hard stop in this path. (`ratchet plan` /
   `ratchet new` standalone still hard-stop as before.)
2. **build** — the normal green-gated turn loop, on a `ratchet/m-&lt;milestone&gt;`
   branch cut fresh off the (just-ff'd) default branch each milestone.
3. **review** — when a milestone's last task goes `[x]`, ONE advisory review
   turn runs on the `review` tier over `git diff &lt;base&gt;..HEAD`. It prints
   `REVIEW_PASS` or appends must-fix `[ ]` tasks and prints `REVIEW_FAIL`
   (bounded by `MAX_REVIEW_CYCLES`, default 2; then `notify_human` + stop).
   The green gate still gates every commit — review gates the *PR* only.
4. **PR** — `gh pr create` with this milestone's completed tasks + diffstat +
   the review verdict; a diff over `PR_SOFT_MAX_LINES` (default 400) prepends a
   ⚠ large-PR warning to the body (soft — never blocks).
5. **merge-gate** — `wait_for_merge` polls `gh pr view` every `MERGE_POLL_SECS`
   (default 300s). MERGED → ff the default branch, cut the next milestone
   branch off it (so PRs **never stack**). CLOSED → stop (human rejected the
   work). Over `MERGE_WAIT_TIMEOUT` (default 72h) → `notify_human` + clean stop.

### Why the loop waits instead of stacking

The loop faces a trilemma — **sequential work + small PRs + no stacking** —
and a merge-gate is the clean way to satisfy all three. Each milestone PR is a
self-contained, reviewable diff off a clean base; the wait *is* the
human-in-the-loop. The rejected alternatives (stacked PRs, auto-merge,
worktree fan-out while a PR is open) are all listed under Non-goals in
`PLAN.md`.

### Notifying the human

`notify_human` prints `HUMAN NEEDED: &lt;msg&gt;`, rings the terminal bell on a
TTY, and — if `NOTIFY_CMD` is set — runs it in the background with the message
as `$1`. **`NOTIFY_CMD` is deliberately NOT on the repo-conf allowlist**
(ratchet rejects it as an unknown key): a repo conf is agent-adjacent and
parsed, not sourced, so an attacker-controlled repo must never be able to run
a command. Set it only in the **trusted, sourced global conf** (`~/.ratchet/conf`):

```sh
# ~/.ratchet/conf  (sourced; trusted; applies to every repo)
NOTIFY_CMD='afplay /System/Library/Sounds/Glass.aiff'                          # macOS: sound
NOTIFY_CMD='osascript -e "display notification \"$1\" with title \"ratchet\""'   # macOS: banner
NOTIFY_CMD='notify-send ratchet "$1"'                                           # Linux
```

### Inspecting the derived rank (`ratchet models rank`)

Derived ranks are snapshotted to `$RATCHET_HOME/rank.derived` on first use so
tiers don't reshuffle mid-project when the model catalog churns. Inspect or
force a refresh:

```bash
ratchet models rank           # effective rank: explicit MODEL_RANK or derived snapshot
ratchet models rank refresh   # re-derive from live pi + models.dev caches, rewrite snapshot
```
`ratchet doctor` reports the rank source (`explicit | derived-snapshot | none`)
and the count of unranked no-join models.

### New conf keys (milestone cadence)

All default to off/`done`-equivalent — `PR_CADENCE=done` is byte-identical to
today's behavior. See `templates/ratchet.conf.example` for commented examples.

| Key | Default | Role |
|---|---|---|
| `PR_CADENCE` | `done` | `done` = today; `milestone` = the 5-node flow above |
| `MAX_REVIEW_CYCLES` | `2` | fail→fix cycles before `notify_human` + stop |
| `MERGE_POLL_SECS` | `300` | how often `wait_for_merge` polls `gh pr view` |
| `MERGE_WAIT_TIMEOUT` | `259200` (72h) | after this, stop + notify |
| `PR_SOFT_MAX_LINES` | `400` | diff lines that trigger the ⚠ large-PR warning |
| `NOTIFY_CMD` | *(global conf only)* | command run with the message as `$1` |

### One turn at a time (safe default)

The loop runs **one turn, one commit** — sequential, green-gated, easy to bisect/revert.

**Parallel fanout (Milestone 8):** When `PARALLEL=1`, `ratchet fanout` runs independent milestones concurrently in isolated git worktrees (one per milestone). Tag a milestone's first open task with `(independent)` to opt in. Each worktree runs its own `ratchet run` loop; creation is serial (to avoid `config.lock` races), execution is concurrent (bounded by `FANOUT_MAX`, default 4).

`ratchet fanout-clean` sweeps completed worktrees after fanout, removing clean+pushed+merged trees while KEEPING:
- Trees with stash entries (shared stash hazard)
- Trees with unpushed commits
- Dirty trees (git refuses removal without `--force`, which we never use)

Every gate that cannot answer (grep/git error) fails toward KEEP. `git worktree prune` runs automatically at the start of every `ratchet run` to drop stale admin entries. **ponytail:** coarse per-repo sweep; upgrade path = age-based retention if worktrees outlive their PRs.

### Token economy

Ephemeral turns are the DEFAULT: `--no-session --no-extensions` each turn. The
tracker + on-disk markdown files are the only memory, so each turn sends a small
fixed context instead of a session that grows every turn. Per-turn cost stays
flat and low over hours-long runs, which is what lets it survive provider daily
quotas. (No token benchmark is shipped here; the saving is structural, not a
measured figure.)

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

#### Automatic selection (minimal config)

You don't have to hand-write three tier chains. Set **one** line — `MODEL_RANK` —
listing models strongest→weakest, and ratchet slices the plan/build/light tiers
from it for any tier you leave unset:

```ini
# One line → ratchet derives all three tiers.
# strongest first; ratchet picks the top as PLAN, bottom as LIGHT, middle as BUILD.
MODEL_RANK="anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air"

# Leave PLAN_MODELS/BUILD_MODELS/LIGHT_MODELS all unset → each is derived.
# Set any of them to override just that tier; the rest still derive.
```

Where the inputs come from:

- **Availability** — `pi --list-models`, auth-aware (24h cache). A model must
  be authenticated *now* to land in a chain; a stale id is silently dropped.
- **Cost / capability** — [models.dev](https://models.dev) (vendor-neutral,
  no key, 24h cache, best-effort). Used only to order models you did *not* put
  in `MODEL_RANK` (cheapest last) and to show `$in/$out` in `ratchet models
  list`. A model with no models.dev join is never dropped — it just shows no
  price.
- **Your ranking** — `MODEL_RANK` is the one calibration knob. No free API
  ranks coding skill (price isn't a proxy: a pricier model can be
  creative-writing-only), so the human ordering is the skill signal.

**Override precedence (unchanged):** an explicit tier key always wins, then the
flat `MODELS` chain, then the `MODEL_RANK` derivation, then (only with nothing
set) the existing "no models configured" guard. Every repo with a `MODELS=` line
keeps behaving exactly as before.

**Honest caveat:** ratchet only automates availability, cost display, and
slicing tiers from your order — it does not *judge* which model is best at a
task. A wrong auto-pick strikes on the verify gate and falls through the normal
cascade, so a bad guess costs one turn, never a bad commit.

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

### Editing model chains (`ratchet models`)

Model ids churn fast (glm 5.1→5.2, sonnet 4.5→4.6, new providers). Instead of
hand-editing comma strings, use `ratchet models` — every id is validated
against pi's live registry (`pi --list-models`, 24h cache) before it lands:

```bash
ratchet models list                                  # effective chains, ✓/UNKNOWN per model
ratchet models add kimi-coding/k3 --pos last         # append to MODELS (global conf)
ratchet models add zai/glm-5-turbo --tier light --pos first
ratchet models remove zai/glm-5.1 --tier light       # churned id out
ratchet models thinking off --tier light             # cheap tier shouldn't reason
ratchet models add anthropic/claude-opus-4-8 --tier plan --repo   # repo contract
```

Edits target the global `~/.ratchet/conf` by default, `--repo` targets the repo's
`.ratchet.conf` (and re-stamps the doctor conf-hash, so ratchet's own edit is
never flagged as tampering). `add` on an id already in the chain moves it —
`add X --pos 2` is also your reorder. Unknown ids are refused (`--force`
overrides); `doctor` fails on configured ids missing from the registry cache.

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
git clone https://github.com/gustavo-neiva/ratchet.git
cd ratchet

# Install globally: symlink onto PATH (bin/ratchet self-locates lib/ through
# the symlink, so the clone can live anywhere and still be updated with git pull)
ln -sf "$PWD/bin/ratchet" /usr/local/bin/ratchet   # or ~/.local/bin/ratchet

# ...or just add bin/ to PATH for this shell only
export PATH="$PWD/bin:$PATH"

# Test
ratchet selftest
```

**Requirements:**[^deps]
- Bash 3.2+ (macOS/Linux; no `timeout` binary needed)
- Git
- A headless agent: `pi` (default), `claude -p`, or any CLI that accepts `-p "prompt"`
- Configured API keys for your models

[^deps]: **Zero dependencies** for the loop core (pure bash). `ratchet stats` needs python3; `ratchet watch` prefers `jq` (degrades gracefully without it).

### Agent environment (PATH & version managers)

ratchet spawns the agent **non-interactively** — it does *not* source your
`.zshrc` / `.bashrc`. Anything your interactive shell puts on `PATH` is
invisible to agent turns: version managers whose shims live off the default
`PATH` (asdf, mise, pyenv, nvm, …) won't be found, and multi-language verify
gates fail with `go: command not found` / `python: command not found` / `mix:
command not found` — even though the toolchain is installed. (Interactive runs
from your own terminal are unaffected; this only bites detached/loop contexts.)

Fix: put the export in **`~/.ratchet/conf`**. Unlike the repo's `.ratchet.conf`
(which is *parsed* and allowlist-checked, so rejects unknown keys), the global
conf is **sourced** at startup (`bin/ratchet`), so `export`s flow into every
spawned turn. asdf example:

```sh
# ~/.ratchet/conf  (sourced; trusted; applies to every repo)
export ASDF_DATA_DIR="$HOME/.asdf"
export PATH="$ASDF_DATA_DIR/shims:$PATH"   # shims must precede Homebrew
```

Sanity check — each should resolve under your version manager, not
`/opt/homebrew/bin`:

```sh
for t in python go rustc cargo elixir mix ruby bundle node; do command -v "$t"; done
```

## Commands

```
run          [REPO]   Run until ALL_DONE (default)
once         [REPO]   One turn, then exit (testing/debugging)
init         [REPO]   Stamp protocol files (existing repo)
new          "<idea>" Scaffold repo, draft plan, STOP for review
doctor       [REPO]   Preflight checks
selftest              Verify logic against fixtures (no API calls)
stats        [REPO]   Parse loop.log and print metrics
watch        [REPO]   Pretty-print live session JSONL (2nd terminal)
models                List/add/remove/validate model chains (--tier, --pos, --repo)
fanout       [REPO]   Parallel fanout: run independent milestones concurrently
fanout-clean [REPO]   Sweep completed worktrees (fail-safe, keeps dirty/unpushed/stashed)
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
                          Multi-toolchain tip: verify only changed entries
                          (e.g. 'bash changed-entries.sh') so pre-existing
                          environmental reds don't block good turns
--no-verify-gate          Skip pre-commit re-verify (trust agent's word)
--push                    Push ONCE after ALL_DONE (default: off; human owns push)
--pr                      Push + open PR/MR (gh/glab) after ALL_DONE; human merges
--approve                 Open local diff-review UI before push/PR (opt-in, v1)
```

### Token economy

```
--resume / --no-resume      Default: ephemeral turns (flat, low per-turn cost)
--cache-retention LEVEL     Prompt-cache TTL: long|short|none
--no-sanitize               Don't strip thinking blocks (debug only)
```

### Feedback

```
--summary-lines N        Curated agent summary lines after each turn (default: 4)
--heartbeat N            Seconds between in-place activity pings (default: 15, 0=off)
--stream                 Live-stream agent's raw output (noisy)
--quiet                  Terminal silent; logs only
-v, --verbose            Verbose logging
```

## What this adds to the Pi ecosystem

Pi already provides `pi-subagents` (delegate to child agents) and `@pi-agents/loop` (scheduled/recurring tasks). **ratchet** fills a different gap:

| Feature | ratchet | pi-subagents | @pi-agents/loop |
|---|---|---|---|
| **Unattended multi-hour runs** | ✓ (rate-limit survival) | ✗ (synchronous) | ✗ (scheduling only) |
| **Green-gated commits** | ✓ (RED never commits) | ✗ | ✗ |
| **Multi-provider fallback** | ✓ (survives quotas) | ✗ | ✗ |
| **Repo contract (task-agnostic)** | ✓ (4 files) | ✗ | ✗ |
| **Human checkpoints** | ✓ (plan review, PR review) | ✗ | ✗ |
| **Ephemeral turns (cheap)** | ✓ (flat per-turn context) | ✗ | ✗ |

Use **ratchet** for: unattended overnight coding runs, quota-bound long tasks, multi-repo pipelines.  
Use **pi-subagents** for: delegating sub-tasks within an interactive session.  
Use **@pi-agents/loop** for: scheduling periodic prompts (cron-style).

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
└── examples/demo-repo/      # toy project (tutorial)
```

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

---

**Ship it safely.** Review the plan, run `doctor`, then let it run unattended. A RED tree is never committed.
