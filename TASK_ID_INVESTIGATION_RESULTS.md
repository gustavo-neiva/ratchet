# Task ID Investigation Results

## What We Found

The postmortem revealed the cookbook run showed `task=? (normal)` on all 142 turns because the old parser only recognized `T*` IDs like `T1.2`.

## What We Fixed (P1.1)

Extended the task ID parser to recognize:
- `T1.2`, `T5` — classic milestone.task (existing, still works)
- `A1`, `I3` — letter(s) + number (NEW)
- `N-postmortem` — letter + dash + slug (NEW)
- Plain `- [ ] task` — still valid, but gets `?` ID

## Investigation Results

### Files Checked ✓

1. **PLAN.md** — All tasks use proper `T*` IDs
2. **templates/PLAN.seed.md** — All examples use `T*` IDs ✓
3. **skills/ratchet-plan/SKILL.md** — All examples use `T*` IDs ✓
4. **examples/demo-repo/PLAN.md** — Uses `M*` IDs (recognized as letter+number) ✓
5. **POSTMORTEM_FIX_PLAN.md** — All tasks use `T*` IDs ✓

### Documentation Updated ✓

1. **lib/tracker.sh** — Updated grammar comment to list all 4 supported ID formats
2. **AGENTS.md** — Added explicit list of supported ID formats after grammar line

### Verification ✓

```bash
$ ratchet doctor .
# No "task id unresolved" warnings

$ bash test/postmortem-fixes.sh
# All postmortem fix tests passed
```

## How to Fix "task id unresolved" Error

If you see:
```
FAIL task id unresolved on first open task; parser degraded to '?' (see tracker grammar)
```

**Fix:** Add an ID to your first `[ ]` task using any supported format:

```markdown
# Before (causes error)
- [ ] do the thing

# After (any of these work)
- [ ] T1.1 do the thing       # classic
- [ ] A1 do the thing         # action/letter+number
- [ ] I3 do the thing         # issue/letter+number
- [ ] N-postmortem do the thing  # named/slug
```

## Why This Matters

Task IDs feed:
- Commit subjects (`auto(ratchet): turn N model — T1.2 implement parser`)
- Per-task failure tracking
- Turn headers (`▶ T5.4 (normal) heartbeat shows activity`)
- Observability (`task=T1.2 (normal)` vs `task=? (normal)`)

A `?` ID means the loop can't track which task is being worked on, and 142 turns
all showing `task=?` is a red flag the plan structure doesn't match the parser.

## Status: COMPLETE ✓

All plans use recognized IDs, documentation updated, tests pass.
