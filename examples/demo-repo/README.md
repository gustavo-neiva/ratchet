# Ratchet Demo Project

This is a minimal demo project that shows ratchet in action.

## The Setup

A simple calculator module with **intentional bugs**:
- `multiply()` incorrectly adds instead of multiplying
- Tests fail, making the tree RED

## What ratchet will do

1. Detect the RED gate (`npm test` fails)
2. Fix the bug to make tests pass
3. Commit ONLY when the tree is green
4. Continue with remaining tasks in PLAN.md

## Try it

```bash
# From the ratchet repo root:
bin/ratchet init examples/demo-repo
bin/ratchet doctor examples/demo-repo
bin/ratchet once examples/demo-repo  # One turn to fix the RED gate

# Or run until all tasks are done:
bin/ratchet run examples/demo-repo
```

## Expected output

```
[00:00] ratchet START
[00:00] --- turn 1 | model=pi ---
[00:15]   … working
[00:30] commit gate: running 'npm test' … RED (fixing this is the agent's task)
[00:45] STEP_COMPLETE
[00:45] commit gate: running 'npm test' … green → committed turn 1
```

The key punchline: **the agent cannot commit a RED tree**. It MUST fix the tests first.
