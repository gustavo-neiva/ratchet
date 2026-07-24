# Changelog

All notable changes to ratchet will be documented in this file.

## [Unreleased]

### Added (v1.2 - Model config UX)
- ✅ `ratchet models` command family: `list` (effective chains with registry ✓/UNKNOWN marks), `add`/`remove` (`--tier`, `--pos first|last|N`, `--repo`, `--force`), `thinking`
- ✅ Every added id validated against `pi --list-models` (24h cache in `$RATCHET_HOME/models.registry`); unknown ids refused unless `--force`
- ✅ `ratchet doctor` fails on configured models missing from the registry cache (typo/churn guard, preflight before any quota burns)
- ✅ Conf write-back upserts a single `KEY=value` line, preserving all comments; `--repo` edits re-stamp the doctor conf-hash

### Added (v1.1 - Tiered Model Routing)
- ✅ Three-tier routing: PLAN (drafting), BUILD (normal/hard), LIGHT (trivial)
- ✅ `ratchet plan` command for plan-drafting turns
- ✅ Per-tier model chains and thinking levels
- ✅ Tier statistics in `ratchet stats`
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
- ✅ Self-test suite (no API calls required)
- ✅ Human checkpoints (plan authoring, plan review, PR review)

### Fixed
- parse_args: handle duplicate positional args from pre_scan
- emit/flow: gracefully handle unset LOOP_LOG (before logs are wired)
- commands.sh: fix backtick command execution in messages
- stamp_protocol: fix awk multi-line string handling
- AGENTS.protocol.md: add missing "the token" before ALL_DONE

## Roadmap

### v2.0 - Parallel Execution (Future)
- [ ] `--parallel N` implementation
- [ ] Git worktree isolation for non-`serial` tasks
- [ ] Worktree convergence + single commit per worktree

### Documentation & CI
- [ ] .github/workflows/ci.yml - Run selftest in CI
