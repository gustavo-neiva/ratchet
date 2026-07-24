# Changelog

All notable changes to ratchet will be documented in this file.

## [Unreleased]

### Added (v1.1 - Tiered Model Routing)
- ✅ Three-tier routing: PLAN (drafting), BUILD (normal/hard), LIGHT (trivial)
- ✅ `ratchet plan` command for plan-drafting turns
- ✅ Per-tier model chains and thinking levels
- ✅ Tier statistics in `ratchet stats`
- ✅ Parity audit documenting autonomous_loop.sh equivalents
- ✅ `--cheap` flag to force all tiers to LIGHT chain
- ✅ Turn observability: tier, task ID, duration, progress

### Added (v1 - Core Bash Implementation)
- ✅ Complete bash core with all essential modules
- ✅ Commands: `run`, `once`, `init`, `new`, `doctor`, `selftest`, `stats`, `watch`
- ✅ Green-gated commits (RED tree never commits)
- ✅ Multi-provider model fallback with cooldown/bench
- ✅ Ephemeral turn economy (token savings)
- ✅ Session sanitization (cross-provider compatibility)
- ✅ Tracker grammar parser (`[ ]` → `[IN PROGRESS]` → `[x]`)
- ✅ Repo contract (4 files: `.ratchet.conf`, `AGENTS.md`, `PLAN.md`, `LEARNINGS.md`)
- ✅ Comprehensive README with examples
- ✅ MIT LICENSE
- ✅ Working demo-repo (calculator with intentional bug)
- ✅ Self-test suite (19 tests, all passing)
- ✅ Human checkpoints (plan authoring, plan review, PR review)

### Fixed
- parse_args: handle duplicate positional args from pre_scan
- emit/flow: gracefully handle unset LOOP_LOG (before logs are wired)
- commands.sh: fix backtick command execution in messages
- stamp_protocol: fix awk multi-line string handling
- AGENTS.protocol.md: add missing "the token" before ALL_DONE

## Roadmap

### v1.1 - TypeScript Wrapper (Optional Enhancement)
- [ ] `ts/src/cli.ts` - TypeScript CLI wrapper
- [ ] `ts/src/pipeline.ts` - Sequential pipeline runner
- [ ] `ts/src/schedule.ts` - Recurring/one-shot runs (wraps `@pi-agents/loop`)
- [ ] `ts/src/pr.ts` - Push + open PR/MR via `gh`/`glab`
- [ ] `ts/src/approve.ts` - Local diff-review server (opt-in)
- [ ] `ts/src/worktree.ts` - Parallel tasks in isolated worktrees

### v1.2 - Documentation & CI
- [ ] docs/token-economy.md - Detailed cost analysis
- [ ] docs/model-fallback.md - Cooldown/bench mechanics
- [ ] docs/repo-contract.md - The 4-file contract deep-dive
- [ ] docs/human-in-the-loop.md - The 4 checkpoints explained
- [ ] docs/parallelism.md - Single vs N-worktree tradeoffs
- [ ] .github/workflows/ci.yml - Run selftest + any TS tests

### v2.0 - Parallel Execution (Future)
- [ ] `--parallel N` implementation
- [ ] Git worktree isolation for non-`serial` tasks
- [ ] Integration with `pi-subagents` parallel mode
- [ ] Worktree convergence + single commit per worktree

### Artifact 2 - Multi-Lens Review Skill (Separate Effort)
- [ ] `skills/multi-lens-review/SKILL.md` - 5-lens review composition
- [ ] Portable lenses (Senior, Security, Principal, Devil's Advocate, Karpathy)
- [ ] Examples on public code/docs
- [ ] Attribution to `superpowers` lineage
