# Investigation: Task ID Pattern Compliance

## Context
The postmortem revealed that the cookbook run showed `task=? (normal)` on all 142 turns because the parser only recognized `T*` IDs. We just implemented P1.1 which now recognizes:
- `T1.2`, `A5`, `I3` — letter(s) + number + optional `.N`
- `N-postmortem` — letter + dash + slug

## Investigation Tasks

### 1. Find all plan/tracker files in the repo
```bash
find . -name "*.md" -type f | xargs grep -l "^\- \[[ x]\]" | grep -vE "node_modules|\.git"
```

### 2. For each plan file, check for tasks without recognized IDs
```bash
# Pattern: open tasks without T*/A*/I*/N-* prefix
grep "^- \[ \]" FILE.md | grep -v "^- \[ \] [A-Za-z]+[0-9]" | grep -v "^- \[ \] [A-Za-z]+-"
```

### 3. Verify the new parser recognizes existing IDs
```bash
# Test with actual plan content
REPO_DIR=. TRACKER_FILE=PLAN.md bash -c '. lib/tracker.sh; tracker_next_id_and_text'
```

### 4. Check documentation for ID pattern examples
```bash
grep -r "- \[ \]" README.md AGENTS.md skills/ templates/ | grep -E "T[0-9]|example|pattern"
```

### 5. Update any templates/examples to show the new patterns
Focus on:
- `templates/PLAN.md` (if exists)
- `README.md` examples
- `AGENTS.md` protocol description
- Skill documentation that references task IDs

## Expected Fixes

### Fix Pattern 1: Plain tasks → add IDs
```markdown
# Before
- [ ] implement the feature
- [ ] write tests

# After
- [ ] T1.1 implement the feature
- [ ] T1.2 write tests
```

### Fix Pattern 2: Update docs to show all supported patterns
```markdown
Supported task ID formats:
- `T1.2` — classic milestone.task (most common)
- `A1` — single-letter + number (e.g., Action items)
- `I3` — single-letter + number (e.g., Issues)
- `N-postmortem` — letter-dash-slug (e.g., Named tasks)
- Plain `- [ ] task` — valid but gets `?` ID (avoid for main work)
```

### Fix Pattern 3: Ensure doctor catches unresolved IDs
The new P1.2 check already warns:
```
FAIL task id unresolved on first open task; parser degraded to '?' (see tracker grammar)
```

## Acceptance

- [ ] All plan files use recognized ID patterns on first open task
- [ ] `ratchet doctor .` passes without "task id unresolved" warning
- [ ] Documentation shows all 4 supported ID patterns with examples
- [ ] Templates use the standard `T1.2` pattern by default
- [ ] test/selftest.sh includes cases for A*/I*/N-* patterns (already done in P1.1)

## Files to Check

1. PLAN.md (current tracker)
2. POSTMORTEM_FIX_PLAN.md (if it has tasks)
3. README.md (examples)
4. AGENTS.md (protocol description)
5. templates/PLAN.md (if exists)
6. skills/ratchet-plan/SKILL.md (if exists)
7. Any example/*.md files

Run: `bash test/selftest.sh && ratchet doctor .` after all fixes.
