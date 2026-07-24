# Comparison

> How ratchet compares to other autonomous loop harnesses for coding agents.

## Direct Competitors

Three direct competitors surfaced, all "autonomous loop harness for coding agents":

| Dimension | **ratchet** | **looper** (nexu-io) | **loop-harness** (lSAAGl) | **ouro-loop** (VictorVVed) |
|---|---|---|---|---|
| Lang / deps | **bash 3.2+, zero deps** | Go (daemon+CLI, curl-install) | bash + jq+gh+curl+claude | Python 3.10+ (pip) |
| Agent scope | **any `-p` CLI** | pluggable (claude/codex/cursor/grok/opencode) | **Claude-locked** | **Claude-locked** (hooks) |
| Rate-limit survival | **fallback chain, cheapest-first** | per-vendor choice, no auto-fallback | none | none |
| Green gate | **your test suite, before every commit** | checks pass → ready for merge | **2nd Claude** verifies (`VERDICT: PASS`) | verify stage + remediation |
| Push/PR | **routed to human** | auto-merge (`--merge`) | auto-push after verify | in-repo |
| Isolation | in-repo (staged) | worktree per loop | worktree per loop | in-repo |
| Knowledge model | **repo-as-context** (task-agnostic) | forge = source of truth (labels/PRs) | injected skills per loop | injected methodology (`program.md`) |
| Tagline | "unattended-but-safe" | "autonomous AI dev team" | "you don't prompt; loops do" | "bounded autonomy" |

## What's Different

### Rate-limit survival

**Ratchet alone survives provider rate limits.** ouro-loop and loop-harness are Claude-locked — one 429 kills the night. looper lets you *pick* a vendor but does not *fall across them on quota*. ratchet's cheapest-first fallback chain is unique. This is the most relatable pain in the entire category.

### Deterministic gate over probabilistic gate

**Ratchet trusts your test suite, not a second LLM.** loop-harness uses a *second Claude invocation* to approve work. ratchet runs *your `VERIFY_CMD`* before every commit. Cleaner philosophy: tests are the spec, the loop enforces them.

### Zero dependencies

**Ratchet runs anywhere a shell runs.** looper ships Go binaries + a daemon. ratchet is one script — drops into CI runners, containers, a teammate's fresh laptop. No toolchain. bash 3.2+ only (macOS default).

### Human at the boundary

**Most conservative push posture.** looper auto-merges (`--merge`), loop-harness auto-pushes after verify. ratchet routes push/PR to human judgment — the loop never pushes without `--push`.

### Agent-forbidden contract

**The agent cannot rewrite the loop's rules.** `.ratchet.conf` is parsed-not-sourced, hash-checked on every turn. The agent literally cannot rewrite the loop's contract. None of the competitors emphasize this.
