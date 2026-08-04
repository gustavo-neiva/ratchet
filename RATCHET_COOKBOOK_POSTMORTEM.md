# Ratchet × Cookbook — Deep Postmortem & Next Steps

Analysis of every ratchet run against `../cookbook`, drawn from
`~/.ratchet/logs/cookbook-335653/loop.log` (1783 lines, 7 runs, 2026-07-24 →
2026-08-03), the pi session JSONLs (333 files, 61 MB), the repo's git history,
and the ratchet source in `lib/`.

---

## TL;DR

**In 7 runs / 142 turns / ~10.2 h of agent compute, ratchet committed exactly
ONE turn to cookbook.** The other 141 turns produced zero committed progress.
Task count moved 0→4 of 52 over the whole period — and even that "4" came from
manual human commits, not the loop.

The loop was **not** failing because the models can't code. In most turns the
agent did real, correct work (`bin/cookbook verify --path … green`). It failed
because of **harness misconfiguration** that discarded good work at the commit
gate, plus **memory/orientation gaps** that made every model re-derive the same
facts from scratch every turn.

The headline number: **88 of 142 turns hit the commit gate RED, and 41 of those
reds were a single wrong config value** (`VERIFY_CMD=npm test` in a repo with no
`package.json`). Good work, thrown away, 41 times.

---

## The runs at a glance

| Run | Date | Turns | Models | Net committed progress |
|----:|------|------:|--------|------------------------|
| 1 | 07-24 12:01 | 7 | sonnet-4-5, glm-5.2 | 0 |
| 2 | 07-24 14:36 | 9 | kimi-for-coding + 5 fallbacks | 0 |
| 3 | 07-24 15:38 | 7 | same 6-chain | 0 |
| 4 | 07-25 01:41 | 97 | same 6-chain | 0 |
| 5 | 07-26 23:05 | 1 | same 6-chain | 0 (preflight abort) |
| 6 | 08-03 15:25 | 17 | same 6-chain | 0 |
| 7 | 08-03 22:53 | 4 | same 6-chain | **1 commit** |

Turn-outcome distribution (all runs):

```
exhausted (rate-limit/quota) 67   ← 47%
step (work done)             45   ← but only 1 survived the gate
transient (blip/empty)       21
done (ALL_DONE)               3   ← all premature/false
hard (auth/4xx)               3
timeout (past cap)            1
```

Commit gate: **41 "commit gate RED", 47 "RED at commit gate" = 88 reds, 1 green.**

---

## Root causes, ranked by damage

### 1. The green gate was pointed at the wrong command (41 turns wasted)

`.ratchet.conf` had `VERIFY_CMD=npm test` for runs 1–6. Cookbook has **no
`package.json`**. Every commit gate died identically:

```
npm error code ENOENT
npm error path /Users/.../cookbook/package.json
commit gate RED — NOT committing; leaving work for next turn to repair.
```

The agent's actual work was **green** (`bin/cookbook verify --path … green` in
the turn summary), but the harness ran the wrong gate and reverted everything.
Run 7 finally set `VERIFY_CMD=bash test/changed-entries.sh` — and produced the
only commit in the entire history. The gate was the bottleneck, not the model.

**This is the single biggest finding.** Six runs, ~9 hours, ~40 turns of correct
work, discarded by one stale config line. `ratchet doctor` did not catch it —
preflight validates that `VERIFY_CMD` is set, not that it can execute in the repo.

### 2. Dual-tracker conflict: ratchet read `PLAN.md`, agent wrote `COOKBOOK_PLAN.md`

`.ratchet.conf` says `TRACKER_FILE=PLAN.md`. But `AGENTS.md` tells the agent:
> "Read `COOKBOOK_PLAN.md` first; find `[IN PROGRESS]` or the first `[ ]`."

So the loop's progress display, task selection, and "next task" prompt all read
a **different file** than the one the agent actually maintained. Consequences
visible in the log:

- The loop fed task "A1" to the agent for 20+ turns; the agent repeatedly
  reported "A1 is already `[x]` complete" and had to re-derive the real current
  task from `COOKBOOK_PLAN.md` every single turn.
- The one successful commit (run 7 turn 3) landed with the message
  **"A4. Add a `playbooks/scope-guide.md` stub"** while the turn actually built
  **`playbooks/backup-dr/`**. The commit subject is drawn from the wrong tracker
  and is simply false.

### 3. Task-ID parser latched onto a checklist template, not a task

`lib/tracker.sh` picks "the first `[IN PROGRESS]` else first `[ ]`" line. In
cookbook's `PLAN.md`, the first unchecked box (line 504) is **not a task** — it's
a *done-definition checklist* item:

```
- [ ] 🔧 `bin/cookbook verify` passes for this entry — `run-tests.sh` exits 0.
```

This is why the loop showed `task=? (normal)` on **all 142 turns** — it never
resolved a real task ID. The agent was handed a checklist row as its "current
task" and had to guess the actual work. The parser assumes T-prefixed IDs
(`T1.2`) and a flat task list; cookbook uses `A1`/`I3`/`N-postmortem` IDs mixed
with prose checklists, and the parser silently degrades to `?`.

### 4. Ephemeral turns + weak memory ⇒ the same facts re-derived every turn

Ratchet's cost model is "ephemeral turns: no session replay, the tracker + md
files are the memory" (`run-turn.sh`). That's the right idea, but the memory
files didn't carry the hard-won facts, so **every turn re-paid the discovery
cost**:

- The "**missing `path` field in `catalog.json`**" gotcha was rediscovered from
  scratch in ≥4 separate turns (each time: add entry → gate fails → "the issue
  is `e["path"]`" → fix). It was never written to `LEARNINGS.md` or `AGENTS.md`.
- The "**`catalog.json` re-serialized to escaped-ASCII `\u2192`**" regression
  appears 7 times. One turn spent most of its budget just restoring UTF-8 that a
  previous turn had mangled — pure churn, net-zero progress.
- `LEARNINGS.md` has only 3 bullets, none covering the two most-repeated traps.
  The advisory-memory channel exists but nothing feeds it, so it can't pay off.

Because each turn starts cold, a 200–500s turn is spent 60–70% on re-orientation
(re-reading AGENTS.md, PLAN, catalog, an example entry) before any real edit.

### 5. Rate limits dominate wall-clock; the fallback chain thrashes

67 of 142 turns ended `exhausted`. The 6-model chain
(`kimi-for-coding → glm-5-turbo → sonnet-4-5 → kimi-highspeed → k3-256k → k3`)
burned through providers fast, then hit `both-wait: 14400s` — **4-hour sleeps**,
five of them logged. Several fallbacks returned in <15s with an instant quota
error (`turn 1 end | class=exhausted | took=12s`), meaning the chain includes
models that were already dry, so it just walks the list to the cooldown floor.

### 6. Stall/deadline kills burn real time on hung requests

18 `stall-300s` kills + 4 `deadline-1800s` kills + 13 `token-seen` late-hangs.
The stall killer is doing its job (a hung streaming request is cheaper to kill
than to wait out 1800s), but 41 turns still ran >5 min, and the longest
`exhausted` turn was **1866 s** — a full deadline spent producing nothing
committable.

### 7. Agent kept trying to edit human-owned files (6 forced reds)

6 turns were force-reverted because the agent edited `.ratchet.conf` or the
`AGENTS.md` protocol markers. The guard worked (nothing bad shipped), but each
was a wasted turn — the agent wasn't told clearly enough which regions are
off-limits, so it "helpfully" tweaked protocol text and lost the turn.

### 8. Premature / false `ALL_DONE`

3 turns emitted `ALL_DONE` with 48 tasks still open — triggered by the A1-already-
done confusion (agent reads the wrong tracker, sees its assigned task is `[x]`,
concludes everything is finished). Only the commit gate / task-count sanity kept
the loop from stopping on a false done.

### 9. Toolchain-not-installed makes "green" ambiguous

Multiple turns hit missing global tools (`pytest` absent → "113 errors", .NET
SDK/JRE absent for C#/Java snippets → entries created "staged, non-exec"). The
agent correctly reasoned "these failures are pre-existing, my entry is green,"
but the **full** `bin/cookbook verify` was red for environmental reasons. This is
exactly why the per-entry gate (`--path`, added in run 7 as
`test/changed-entries.sh`) matters: a repo-wide gate that depends on N language
toolchains being installed will be red for reasons unrelated to the turn's work,
and ratchet's binary green/red gate can't tell the difference.

---

## Token / spend habits that produced no passing code

- **~10.2 h of agent wall-time, ~9 h of it committed nothing.** The `took=` sum
  is 36,557 s across 140 measured turns (avg 261 s).
- **41 turns of correct, green-per-entry work reverted** by the wrong gate
  command — the highest-value waste, because the tokens *did* produce passing
  code that was then thrown away.
- **Re-orientation tax on every ephemeral turn:** each turn re-reads AGENTS.md +
  PLAN + catalog + a reference entry before editing. With no carried memory,
  that's paid 142 times.
- **Duplicated discovery:** the `path`-field bug (≥4×) and the `\u2192`
  re-serialization (7×) are the same tokens spent repeatedly on facts a
  one-line `LEARNINGS.md` entry would have prevented.
- **Cooldown dead-time:** five 14,400 s (4 h) both-exhausted sleeps. Not token
  spend, but it's why "10 days of runs" yielded so little — most of the calendar
  was cooldown, and most of the compute was reverted.

Net: the expensive turns were not the ones that failed to code — they were the
ones that **coded correctly and got discarded**, and the ones that **re-learned
the same thing**.

---

## How the loop gets stuck / how models get lost

1. **Stuck-red loop:** wrong `VERIFY_CMD` ⇒ every turn RED ⇒ "next turn will
   repair" ⇒ next turn does more good work ⇒ RED again. The loop's self-repair
   premise assumes red means *the agent's work is broken*; here red meant *the
   harness is broken*, which the agent cannot fix (and is forbidden from fixing —
   `.ratchet.conf` is human-owned). Infinite no-progress until a human edits conf.
2. **Lost-orientation:** wrong tracker + checklist-as-task ⇒ agent spends the
   first half of each turn figuring out what to even do, often concluding its
   assigned task is already done.
3. **Cold-start amnesia:** ephemeral turns with empty `LEARNINGS.md` ⇒ same traps
   re-hit, sometimes *undoing* a prior turn's cleanup (the `\u2192` churn).
4. **Provider thrash → 4 h sleep:** dead models in the chain drain to the
   cooldown floor, then the loop naps for hours.

---

## Proposed next steps (ordered by ROI)

### P0 — Stop discarding good work

1. **`ratchet doctor` must dry-run `VERIFY_CMD`.** Before any run, execute the
   gate against a clean tree (or at least resolve arg[0] on `$PATH` / verify the
   file exists). `npm test` with no `package.json` should be a hard preflight
   failure, not 41 silent reverts. *(This one change would have saved 6 runs.)*
2. **Single source of truth for the tracker.** `doctor` should fail if
   `TRACKER_FILE` in `.ratchet.conf` disagrees with the tracker named in
   `AGENTS.md`. Pick one file; make the mismatch impossible to run with.

### P1 — Fix orientation

3. **Feed the resolved task into the prompt.** Today the prompt is generic
   ("Do ONE discrete step … following AGENTS.md") and the agent self-discovers
   the task. Inject the actual current task line (title + body) that the loop
   already parsed, so the agent and the loop agree on "what am I doing."
4. **Harden the task-ID parser** (`lib/tracker.sh`): skip lines under a
   done-checklist / "DONE when" heading, support non-`T` IDs (`A1`, `N-foo`), and
   if it can only resolve `? (normal)`, **warn in doctor** rather than silently
   shipping a bogus task. `task=?` on 142/142 turns should have been a loud alarm.

### P2 — Make memory actually compound

5. **Auto-append gate failures to `LEARNINGS.md`.** When a turn fixes a gate
   failure, capture the one-line cause→fix. The `path`-field and `\u2192` traps
   would have been written once and never re-paid. Optionally have the plan-tier
   turn curate/dedupe it.
6. **Carry a tiny "last-turn note" forward.** One or two lines of state
   (what the previous turn touched, any staged-but-unregistered work) appended to
   the prompt would kill the "re-derive the repo state" tax without abandoning
   the cheap ephemeral model.

### P3 — Gate & environment realism

7. **Standardize on the changed-entry gate.** Run 7's `test/changed-entries.sh`
   (verify only what this turn touched) is the pattern that worked — it sidesteps
   the "113 pre-existing errors from a missing global tool" problem. Make
   per-change gating the documented default for multi-toolchain repos.
8. **Declare required toolchains and check them in `doctor`.** If a repo's
   entries need `pytest`/.NET/JRE, doctor should list what's missing so turns
   don't create "staged, non-exec" entries that can never go green locally.

### P4 — Spend & fallback hygiene

9. **Prune dead models from the chain / add a short circuit-breaker.** A model
   that returns quota-error in <15 s should be benched immediately and not
   retried until cooldown, so the chain doesn't just walk to the 4 h floor.
10. **Consider a shorter cooldown with backoff** (e.g. 30 m → 1 h → 4 h) instead
    of jumping straight to 14,400 s, so a transient daily-limit blip doesn't cost
    a 4 h nap.

### P5 — Guardrail UX

11. **Tell the agent the off-limits regions in the prompt**, not just via the
    post-hoc revert. 6 forced reds for editing `AGENTS.md` markers /
    `.ratchet.conf` were avoidable turns.
12. **Sanity-gate `ALL_DONE`** against open task count in the (correct) tracker:
    if tasks remain, treat `ALL_DONE` as `STEP_COMPLETE` and log a warning
    (partially done via `MAX_DONE_GATE_FAILS`, but it fired on the wrong tracker).

---

## The one-line verdict

Ratchet's safety machinery worked perfectly — **nothing bad ever shipped.** The
problem is the inverse: its correctness machinery was so strict, and its config
validation so thin, that **it also shipped almost nothing good.** Fix the gate
dry-run and the tracker single-source-of-truth (P0) and this same log would show
~40 commits instead of 1, with no model change at all.
