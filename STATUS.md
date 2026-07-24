# Project Status

**Last updated:** 2026-07-23  
**Status:** ✅ v1 Core Complete — Ready for Use

## Summary

The **ratchet** autonomous agent loop is complete and functional. All core features are implemented, tested, and documented. The project is ready for real-world use.

## Completed (Artifact 1 - Core Bash Implementation)

### ✅ Core Engine
- **Green-gated commits** — RED tree never commits, re-verifies before every commit
- **Multi-provider fallback** — survives rate limits with cooldown/bench mechanism
- **Ephemeral turns** — tracker-as-memory, ~90% token savings
- **Session sanitization** — cross-provider compatibility
- **Turn classification** — token detection, error categorization
- **Watchdog** — timeout detection, hung process cleanup
- **Heartbeats** — liveness proof during long turns

### ✅ Repo Contract (4 files)
- `.ratchet.conf` — parsed machine contract (agent-forbidden)
- `AGENTS.md` — versioned protocol with managed markers
- `PLAN.md` — tracker grammar (`[ ]` → `[IN PROGRESS]` → `[x]`)
- `LEARNINGS.md` — append-only gotchas

### ✅ Commands
- `run` — unattended until ALL_DONE
- `once` — single turn (testing/debugging)
- `init` — onboard existing repo
- `new` — scaffold from idea (with plan review checkpoint)
- `doctor` — preflight checks
- `selftest` — 19 tests, no API calls required
- `stats` — parse loop.log metrics
- `watch` — live session JSONL viewer

### ✅ Documentation
- **README.md** — comprehensive guide with examples, comparisons, evidence
- **LICENSE** — MIT
- **CHANGELOG.md** — v1 features + roadmap
- **CONTRIBUTING.md** — development guide
- **Demo repo** — examples/demo-repo with intentional bug

### ✅ Testing
- **19 selftests** — all passing
- **Turn classification suite** — token/error detection
- **Session sanitizer suite** — thinking block removal
- **Agnosticism check** — zero project knowledge in core
- **End-to-end test** — fake agent, no API keys needed

## Bugs Fixed (from last session)

1. ✅ **parse_args** — handle duplicate positional args from pre_scan
2. ✅ **emit/flow** — gracefully handle unset LOOP_LOG  
3. ✅ **backtick execution** — fix command execution in messages
4. ✅ **awk multi-line** — fix stamp_protocol string handling
5. ✅ **template token** — add missing "the token" before ALL_DONE

## What Makes It Unique

Five mechanisms not in `pi-subagents` or `@pi-agents/loop`:

1. **Green-gated commit ownership** — loop re-runs tests before EVERY commit
2. **Model fallback + bench/cooldown** — survives rate limits across providers
3. **Ephemeral turn economy** — ~90% per-turn savings (measured)
4. **Session sanitization** — cross-provider compatibility
5. **Repo contract + human checkpoints** — 4 files, plan review mandatory

## Ready to Use

```bash
# Quick start
git clone <repo-url>
cd ratchet
bin/ratchet --selftest          # verify: 19 tests pass

# Try the demo
bin/ratchet doctor examples/demo-repo
bin/ratchet once examples/demo-repo  # one turn (needs real agent)

# Onboard your repo
bin/ratchet init /path/to/your/repo
bin/ratchet doctor /path/to/your/repo
bin/ratchet run /path/to/your/repo
```

## Future Work (Optional Enhancements)

### v1.1 - TypeScript Wrapper
- CLI wrapper
- Pipeline runner (sequential harness runs)
- Schedule integration (`@pi-agents/loop` cron)
- PR automation (`gh`/`glab`)
- Local approval UI
- Worktree parallelism

### v1.2 - Extended Documentation
- docs/token-economy.md
- docs/model-fallback.md
- docs/repo-contract.md
- docs/human-in-the-loop.md
- docs/parallelism.md
- GitHub Actions CI

### v2.0 - Parallel Execution
- `--parallel N` with git worktrees
- Non-`serial` task isolation
- Worktree convergence

### Artifact 2 - Multi-Lens Review Skill
- 5-lens review composition
- Portable to any subagent runtime
- Attributed to `superpowers` lineage

## Evidence Base

This is a **clean rebuild** of a harness in daily use:
- Real script: `~/.pi/autonomous_loop.sh` (791 lines)
- Real logs: `~/.pi/autoloop-logs/cookbook/loop.log`
- V2 design: `~/.pi/autonomous_loop_PLAN_v2.md`

No internal code copied. All generalized and task-agnostic.

## Ship Checklist

- [x] Core bash implementation complete
- [x] All selftests passing (19/19)
- [x] README with examples
- [x] MIT LICENSE
- [x] Demo repo functional
- [x] CHANGELOG documenting v1
- [x] CONTRIBUTING guide
- [ ] GitHub repository created (public)
- [ ] Initial release tagged
- [ ] Pinned to profile

## Next Steps

1. **Create GitHub repo** (public)
2. **Push code** to GitHub
3. **Tag v1.0.0** release
4. **Pin to profile**
5. **(Optional)** Record demo video/gif
6. **(Optional)** Write blog post
7. **(Later)** Build Artifact 2 (multi-lens-review skill)

---

**The core work is done.** Ship it, use it, iterate based on real feedback.
