---
name: ratchet-plan
description: Author a ratchet PLAN.md that one-shots big projects. Use when building a plan for the ratchet autonomous loop, tagging tasks for tiered model routing (plan/build/light), writing self-contained tasks with Given/When/Then acceptance, or when the user says "ratchet plan", "make a plan for the loop", or "spec this for autonomous build".
---

# ratchet-plan

Turn a goal into a `PLAN.md` the ratchet loop can execute **unattended and one turn at a time**, with the right model on every task. A good ratchet plan is a spec that a fresh, memoryless agent turn can pick up, do ONE step, and leave green.

## The one fact that shapes everything

Ratchet turns are **ephemeral** — `--no-session --no-extensions`, ~90% cheaper. The agent starts each turn with **no memory of prior turns**. The only memory is the on-disk files: `PLAN.md`, `LEARNINGS.md`, `AGENTS.md`, and the code itself.

Therefore **every task must be self-contained**: name the files, name the functions, state the "why", and state how the loop knows it's done. A task that assumes context from a previous turn will fail, because there is no previous turn.

## Tags are the model-selection contract

The tag on each task routes it to a model tier. This is not decoration — it is how "plan with the strong model, build with the mid model, search with the cheap model" becomes mechanical instead of vibes.

| Tag | Tier | Model class | Use for |
|---|---|---|---|
| `(trivial)` | LIGHT | cheap, thinking off | mechanical edits, search, data collection, doc tweaks, moving text |
| `(normal)` | BUILD | mid (sonnet-class) | real implementation, the bulk of the work |
| `(hard)`   | BUILD + thinking bump | mid with reasoning raised one notch | tricky logic, blast-radius-wide changes, anything needing scouts/review |
| `(serial)` | — | (any tier) | add when the task must NOT run in parallel with siblings (shared files) |

Tag EVERY task. Untagged defaults to `normal` — but decide on purpose. When in doubt between two tiers, pick the cheaper one and add one line justifying it; the green gate is the real safety net, not the model.

## The task schema

Every task is one tracker line plus indented fields. The tracker line is what ratchet parses (`[ ]` → `[IN PROGRESS]` → `[x]`, id, tags). The fields are what the agent reads to do the work in ONE turn.

```
- [ ] T1.4 (hard, serial) <imperative one-line goal — what exists after this task>
      touches: lib/model-fallback.sh, bin/ratchet
      do: <2-4 sentences. What to change, which function, and WHY. Repeat any
          assumption — the turn has no memory. Name paths and functions exactly.>
      snippet:
          thinking_for_tier() { case "$1" in build-hard) ... ;; esac }
      accept:
          Given all tier keys are unset
          When the loop selects a turn
          Then it uses $MODELS and behaves byte-identically to today
      verify: bash test/selftest.sh   (add case: unset≡today, trivial→LIGHT)
      constraints: additive only; bash 3.2; never edit .ratchet.conf
```

Field rules:

- **touches** — exact repo-relative paths the task will edit. This is the parallel-safety signal: two tasks sharing a path must both be `(serial)`.
- **do** — prose, not a checklist. State the change, the function/module by name, and the reason. Over-explain user-visible effects; under-specify incidental details.
- **snippet** — optional. A signature, a case arm, an anchor line. Enough to remove ambiguity, not the whole implementation. Indent it (no nested code fences).
- **accept** — Given/When/Then, phrased as **observable behavior**, not internal attributes. "Then the CLI prints X" not "Then a struct is added". This is the spec the agent codes toward AND the shape of the test that gates it.
- **verify** — the exact command that must pass, plus the new case(s) this task adds to the suite. This is `VERIFY_CMD`; a RED result blocks the commit.
- **constraints** — the non-negotiables for this task (additive-only, language/runtime limits, forbidden files).

**Why prose + Given/When/Then, never pure Gherkin:** measured experiments show Gherkin-*only* prompts generate near-zero working code — the model needs the "why" and the repo context that prose carries. But Given/When/Then is an excellent *oracle*: it maps straight onto a pass/fail test. So prose drives generation; Given/When/Then drives verification. Never invert this.

## PLAN.md structure

```
# PLAN.md — <project>: <what this plan delivers>

Tracker grammar: [ ] open → [IN PROGRESS] → [x] done. Tags: (trivial|normal|hard) and (serial).

## Design constraints (read before ANY task — non-negotiable)
1. <invariant every turn must hold — e.g. zero regressions, additive only>
2. <runtime/style limits>
3. One task per turn. Do the task, add its verify case, run VERIFY_CMD, mark [x], print STEP_COMPLETE.
...

## Milestone 0 — walking skeleton + green gate (serial)
> No feature task runs before this is green. The safety model (no green, no commit) is bootstrapped here.
- [ ] T0.1 (trivial, serial) scaffold + wire VERIFY_CMD
- [ ] T0.2 (normal, serial) first end-to-end test is green
- [ ] T0.3 (normal) thinnest end-to-end slice of real value

## Milestone 1 — <feature> (serial if tasks share files)
- [ ] T1.1 (normal) ... <full task schema>

## Definition of done
- All tasks [x]. VERIFY_CMD green on a clean checkout. <project-specific done-criteria>

## Non-goals
- <what is explicitly OUT of scope>
```

Milestone 0 is mandatory and always first: a green walking skeleton before any feature. It bootstraps the "no green, no commit" safety model. Never skip it.

Living-document memory: decisions and gotchas go in `LEARNINGS.md` (append-only, the agent reads it each turn). Progress lives in the tracker checkboxes. You do not need a separate Decision Log file — `LEARNINGS.md` + the tracker are the ratchet equivalent.

## The authoring flow

Work these phases in order. Interview first — your best plans come from a rich brief, not a vague one.

1. **Rearticulate.** State the goal and non-goals back in 2-3 sentences. Confirm with the user before decomposing. If the goal is vague, do shallow read-only exploration to ground it.
2. **Design constraints.** Write the non-negotiable invariants every turn must hold (regressions, additive-only, runtime limits, forbidden files). These are the "read before ANY task" block.
3. **Milestone 0.** Define the walking skeleton whose VERIFY_CMD is green. Nothing else runs before it.
4. **Decompose.** Break the work into milestones, then tasks. Each task = one discrete step a single turn can finish. If a task can't fit one turn, split it.
5. **Fill the schema.** For each task write touches / do / snippet / accept / verify / constraints. Name real paths and functions — open the files if you must.
6. **Tier pass.** Tag every task. For any non-obvious tag, add one line of justification. Mark `(serial)` on every task that shares a `touches` path with a sibling.
7. **Hand off.** Write `PLAN.md`. Then the human reviews it (mandatory checkpoint) before `ratchet run`. If drafting inside the loop, `ratchet plan` stops loudly for this review — never auto-run.

## Checklist before you hand off

- [ ] Milestone 0 exists and its verify gate is green-able first.
- [ ] Every task has a tag; non-obvious tags are justified in one line.
- [ ] Every task is self-contained — a memoryless turn could do it from the task text alone.
- [ ] Every task names exact paths (`touches`) and the `verify` command + new case.
- [ ] Tasks sharing a `touches` path are all `(serial)`.
- [ ] `accept` is observable behavior (Given/When/Then), not internal attributes.
- [ ] Definition of done and Non-goals are written.

## Reference

The ratchet repo's own `PLAN.md` ("ratchet builds ratchet") is the worked example of this schema — every task carries paths, functions, and its selftest cases inline. Read it when you need a concrete model.
